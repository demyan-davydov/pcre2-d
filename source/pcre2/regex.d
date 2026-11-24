/// Thin @nogc nothrow wrapper over the 16-bit PCRE2 library.
///
/// * `Regex`: compiled pattern, reference counted (atomically), immutable after `compile`,
///   safe to copy to and use from many threads at once.
/// * `MatchData`: per-thread scratch (ovector, match context, JIT stack). Not thread safe,
///   not copyable; matching with it allocates nothing on the GC heap and takes no lock.
/// All inputs are `const(wchar)[]` (UTF-16 code units) and all outputs are offsets / slices
/// of the caller's data or of caller-provided buffers. Nothing here uses the GC.
module pcre2.regex;

import core.atomic : atomicFetchAdd, atomicFetchSub;
import core.stdc.stdlib : free, malloc;
import pcre2.c_api;

/// Compile-time options (bit flags).
enum Flags : uint
{
    none = 0,
    caseless = 1 << 0, /// Unicode simple case folding in UTF mode
    dotAll = 1 << 1, /// `.` also matches `\n`
    multiline = 1 << 2, /// `^`/`$` match at line boundaries
    dollarEndOnly = 1 << 3, /// `$` matches only at the very end (unless multiline)
    utf = 1 << 4, /// treat pattern and subject as UTF-16 (surrogate pairs, Unicode case folding)
    noUtfCheck = 1 << 5, /// caller guarantees valid UTF-16 subjects: skip the validity check
    noJit = 1 << 6, /// do not JIT compile even if the library supports it
}

/// Resource limits applied to every match; a runaway pattern ends with `MatchStatus.matchLimit` etc.
struct Limits
{
    uint match = 10_000_000; /// backtracking steps (also honoured by JIT)
    uint depth = 10_000_000; /// nested backtrack depth (interpreter only)
    uint heap = 20_000_000; /// KiB of heap for the interpreter's backtrack frames
}

/// Result of a match attempt.
enum MatchStatus : ubyte
{
    match, /// matched; groups are available in `MatchData`
    noMatch,
    matchLimit, /// `Limits.match` exceeded
    depthLimit,
    heapLimit,
    jitStackLimit, /// the JIT stack ran out
    badUtf, /// subject is not valid UTF-16 (e.g. a lone surrogate); see `MatchData.badUtfOffset`
    error, /// anything else; see `MatchData.errorCode`
}

/// Half-open range of UTF-16 code unit offsets. `participated == false`: the group did not take part
/// in the match (distinct from an empty group, which has `participated == true` and `begin == end`).
struct Capture
{
    size_t begin;
    size_t end;
    bool participated;
    @property size_t length() const pure nothrow @nogc @safe { return end - begin; }
}

/// Failure of `Regex.compile`; `offset` is the code unit offset in the pattern.
struct CompileError
{
    int code;
    size_t offset;
}

/// Writes the PCRE2 message for `code` into `buf` (ASCII narrowed to char) and returns the used slice.
const(char)[] errorMessage(int code, char[] buf) nothrow @nogc @trusted
{
    wchar[256] tmp = void;
    const n = pcre2_get_error_message_16(code, tmp.ptr, tmp.length);
    if (n < 0)
        return null;
    size_t i = 0;
    for (; i < n && i < buf.length; ++i)
        buf[i] = tmp[i] < 0x80 ? cast(char) tmp[i] : '?';
    return buf[0 .. i];
}

/// True if the linked PCRE2 was built with the JIT compiler.
bool libraryHasJit() nothrow @nogc @trusted
{
    int v;
    return pcre2_config_16(PCRE2_CONFIG_JIT, &v) == 0 && v == 1;
}

private struct Payload
{
    shared size_t refs;
    pcre2_code_16* code;
    uint options; // compile options incl. flags (UTF etc.)
    bool noUtfCheck;
    bool jit;
    uint captureCount;
    Limits limits;
    uint nameCount;
    uint nameEntrySize;
    const(wchar)* nameTable;
}

/// Compiled pattern. Copying shares the compiled code (atomic refcount).
struct Regex
{
    private Payload* p;

    /// Compiles `pattern`. On failure returns an empty `Regex` (`!re.valid`) and fills `err`.
    static Regex compile(const(wchar)[] pattern, Flags flags, out CompileError err,
        Limits limits = Limits.init) nothrow @nogc @trusted
    {
        uint opts = 0;
        if (flags & Flags.caseless) opts |= PCRE2_CASELESS;
        if (flags & Flags.dotAll) opts |= PCRE2_DOTALL;
        if (flags & Flags.multiline) opts |= PCRE2_MULTILINE;
        if (flags & Flags.dollarEndOnly) opts |= PCRE2_DOLLAR_ENDONLY;
        if (flags & Flags.utf) opts |= PCRE2_UTF;
        int ec;
        size_t eo;
        // a null pointer with length 0 is invalid for PCRE2; use an empty literal
        static immutable wchar[1] nul = [0];
        auto code = pcre2_compile_16(pattern.length ? pattern.ptr : nul.ptr, pattern.length, opts, &ec, &eo, null);
        if (code is null)
        {
            err = CompileError(ec, eo);
            return Regex.init;
        }
        auto pl = cast(Payload*) malloc(Payload.sizeof);
        if (pl is null)
        {
            pcre2_code_free_16(code);
            err = CompileError(PCRE2_ERROR_NOMEMORY, 0);
            return Regex.init;
        }
        *pl = Payload.init;
        pl.refs = 1;
        pl.code = code;
        pl.options = opts;
        pl.noUtfCheck = (flags & Flags.noUtfCheck) != 0;
        pl.limits = limits;
        pcre2_pattern_info_16(code, PCRE2_INFO_CAPTURECOUNT, &pl.captureCount);
        pcre2_pattern_info_16(code, PCRE2_INFO_NAMECOUNT, &pl.nameCount);
        pcre2_pattern_info_16(code, PCRE2_INFO_NAMEENTRYSIZE, &pl.nameEntrySize);
        pcre2_pattern_info_16(code, PCRE2_INFO_NAMETABLE, &pl.nameTable);
        if (!(flags & Flags.noJit) && libraryHasJit())
            pl.jit = pcre2_jit_compile_16(code, PCRE2_JIT_COMPLETE) == 0; // else: interpreter fallback
        Regex r;
        r.p = pl;
        return r;
    }

    this(this) nothrow @nogc @trusted
    {
        if (p) atomicFetchAdd(p.refs, 1);
    }

    ~this() nothrow @nogc @trusted
    {
        if (p && atomicFetchSub(p.refs, 1) == 1)
        {
            pcre2_code_free_16(p.code);
            free(p);
        }
        p = null;
    }

    @property bool valid() const pure nothrow @nogc @safe { return p !is null; }
    /// True if matching runs JIT compiled code (false: interpreter).
    @property bool jitEnabled() const pure nothrow @nogc @safe { return p !is null && p.jit; }
    /// Number of capture groups, not counting the whole match (group 0).
    @property uint captureCount() const pure nothrow @nogc @safe { return p.captureCount; }

    /// Number of the first group with this name, or -1. `name` is compared as UTF-16 code units.
    int groupIndex(const(wchar)[] name) const nothrow @nogc @trusted
    {
        if (p is null) return -1;
        const(wchar)* e = p.nameTable;
        foreach (_; 0 .. p.nameCount)
        {
            const(wchar)* n = e + 1;
            size_t i = 0;
            while (i < name.length && n[i] == name[i]) ++i;
            if (i == name.length && n[i] == 0)
                return e[0];
            e += p.nameEntrySize;
        }
        return -1;
    }

    /// Number of named groups, and the i-th (in table order, i.e. sorted by name) name / group number.
    @property uint namedGroupCount() const pure nothrow @nogc @safe { return p ? p.nameCount : 0; }

    /// Name of the i-th named group as a slice of the compiled pattern's table (valid while a copy of
    /// the `Regex` lives), and its group number via `number`.
    const(wchar)[] namedGroup(uint i, out uint number) const nothrow @nogc @trusted
    {
        const(wchar)* e = p.nameTable + cast(size_t) i * p.nameEntrySize;
        number = e[0];
        size_t n = 0;
        while (e[1 + n]) ++n;
        return e[1 .. 1 + n];
    }

    private inout(Payload)* payload() inout pure nothrow @nogc @safe { return p; }
}

/// Per-thread matching scratch for one `Regex`. Create one per (thread, regex) and reuse it.
struct MatchData
{
    private
    {
        Payload* pl;
        pcre2_match_data_16* md;
        pcre2_match_context_16* mc;
        pcre2_jit_stack_16* stack;
        int rc; // last pcre2_match result (> 0: matched, count of groups incl. 0)
        int err; // last error code (< 0), 0 if none
        size_t* ov;
    }

    @disable this(this);

    /// Creates scratch for `re` (keeps `re` alive). Returns false in `ok` on out-of-memory.
    static MatchData create(ref const Regex re, out bool ok) nothrow @nogc @trusted
    {
        MatchData m;
        ok = false;
        if (!re.valid) return m;
        auto pl = cast(Payload*) re.payload;
        m.md = pcre2_match_data_create_from_pattern_16(pl.code, null);
        m.mc = pcre2_match_context_create_16(null);
        if (m.md is null || m.mc is null) { m.release(); return m; }
        pcre2_set_match_limit_16(m.mc, pl.limits.match);
        pcre2_set_depth_limit_16(m.mc, pl.limits.depth);
        pcre2_set_heap_limit_16(m.mc, pl.limits.heap);
        if (pl.jit)
        {
            m.stack = pcre2_jit_stack_create_16(32 * 1024, 1024 * 1024, null);
            if (m.stack is null) { m.release(); return m; }
            pcre2_jit_stack_assign_16(m.mc, null, m.stack);
        }
        m.ov = pcre2_get_ovector_pointer_16(m.md);
        atomicFetchAdd(pl.refs, 1);
        m.pl = pl;
        ok = true;
        return m;
    }

    ~this() nothrow @nogc @trusted
    {
        release();
        if (pl && atomicFetchSub(pl.refs, 1) == 1)
        {
            pcre2_code_free_16(pl.code);
            free(pl);
        }
        pl = null;
    }

    private void release() nothrow @nogc @trusted
    {
        if (stack) pcre2_jit_stack_free_16(stack);
        if (mc) pcre2_match_context_free_16(mc);
        if (md) pcre2_match_data_free_16(md);
        stack = null; mc = null; md = null;
    }

    @property bool valid() const pure nothrow @nogc @safe { return pl !is null; }

    /// Searches `subject` from code unit offset `start`. `extraOptions` is for internal use.
    MatchStatus search(const(wchar)[] subject, size_t start = 0) nothrow @nogc @trusted
    {
        return run(subject, start, pl.noUtfCheck ? PCRE2_NO_UTF_CHECK : 0);
    }

    private MatchStatus run(const(wchar)[] subject, size_t start, uint opts) nothrow @nogc @trusted
    {
        static immutable wchar[1] nul = [0];
        auto s = subject.length ? subject.ptr : nul.ptr;
        // pcre2_jit_match does no UTF validation, so it is only used when the check is skipped;
        // otherwise pcre2_match (which still runs the JIT code, after validating the subject).
        rc = (pl.jit && (opts & PCRE2_NO_UTF_CHECK))
            ? pcre2_jit_match_16(pl.code, s, subject.length, start, opts, md, mc)
            : pcre2_match_16(pl.code, s, subject.length, start, opts, md, mc);
        err = 0;
        if (rc > 0 || rc == 0) // rc == 0: ovector too small, cannot happen (created from pattern)
            return MatchStatus.match;
        err = rc;
        switch (rc)
        {
        case PCRE2_ERROR_NOMATCH: err = 0; return MatchStatus.noMatch;
        case PCRE2_ERROR_MATCHLIMIT: return MatchStatus.matchLimit;
        case PCRE2_ERROR_DEPTHLIMIT: return MatchStatus.depthLimit;
        case PCRE2_ERROR_HEAPLIMIT: return MatchStatus.heapLimit;
        case PCRE2_ERROR_JIT_STACKLIMIT: return MatchStatus.jitStackLimit;
        case PCRE2_ERROR_UTF16_ERR1: case PCRE2_ERROR_UTF16_ERR2: case PCRE2_ERROR_UTF16_ERR3:
            return MatchStatus.badUtf;
        default: return MatchStatus.error;
        }
    }

    /// PCRE2 error code of the last failed `search` (0 if none).
    @property int errorCode() const pure nothrow @nogc @safe { return err; }

    /// After `MatchStatus.badUtf`: code unit offset of the offending unit.
    @property size_t badUtfOffset() nothrow @nogc @trusted { return pcre2_get_startchar_16(md); }

    /// Number of groups (including 0) the last match could report: `regex.captureCount + 1`.
    @property uint groupCount() const pure nothrow @nogc @trusted { return pl.captureCount + 1; }

    /// Group `i` of the last successful match. Out-of-range or non-participating: `participated == false`.
    Capture group(uint i) const pure nothrow @nogc @trusted
    {
        if (rc <= 0 || i > pl.captureCount || i >= cast(uint) rc)
            return Capture(0, 0, false);
        const b = ov[2 * i], e = ov[2 * i + 1];
        if (b == PCRE2_UNSET)
            return Capture(0, 0, false);
        return Capture(b, e, true);
    }

    /// Group by name; unknown name gives a non-participating capture.
    Capture group(ref const Regex re, const(wchar)[] name) const nothrow @nogc @trusted
    {
        const n = re.groupIndex(name);
        return n < 0 ? Capture(0, 0, false) : group(cast(uint) n);
    }

    /// Lazy range over all non-overlapping matches in `subject` (front = whole match, `Capture`).
    /// The `MatchData` holds the groups of the current match. Check `status` after iteration:
    /// `noMatch` is normal completion, anything else is an error that ended the iteration.
    Matches matches(const(wchar)[] subject, size_t start = 0) return nothrow @nogc @trusted
    {
        auto r = Matches(&this, subject, start);
        r.advance(false);
        return r;
    }
}

/// Input range returned by `MatchData.matches`. Holds a pointer to the `MatchData`.
struct Matches
{
    private MatchData* m;
    private const(wchar)[] subject;
    private size_t pos;
    private bool emptyPrev;
    private bool started;
    private bool done;
    /// `noMatch` after normal exhaustion; otherwise the status that stopped the iteration.
    MatchStatus status = MatchStatus.noMatch;

    private this(MatchData* m, const(wchar)[] subject, size_t pos) nothrow @nogc
    {
        this.m = m; this.subject = subject; this.pos = pos;
    }

    @property bool empty() const pure nothrow @nogc @safe { return done; }
    @property Capture front() const pure nothrow @nogc @safe { return m.group(0); }
    void popFront() nothrow @nogc @safe { advance(true); }

    private void advance(bool) nothrow @nogc @trusted
    {
        // After the first successful call the subject is known valid: skip re-validation (avoids O(n^2)).
        uint extra = started ? PCRE2_NO_UTF_CHECK : (m.pl.noUtfCheck ? PCRE2_NO_UTF_CHECK : 0);
        if (emptyPrev)
            extra |= PCRE2_NOTEMPTY_ATSTART | PCRE2_ANCHORED;
        auto st = m.run(subject, pos, extra);
        if (st == MatchStatus.noMatch && emptyPrev)
        {
            // no non-empty match at this position: step one character and search normally
            if (pos >= subject.length) { done = true; status = MatchStatus.noMatch; return; }
            pos += (m.pl.options & PCRE2_UTF) && subject[pos] >= 0xD800 && subject[pos] < 0xDC00
                && pos + 1 < subject.length ? 2 : 1;
            emptyPrev = false;
            st = m.run(subject, pos, PCRE2_NO_UTF_CHECK);
        }
        if (st != MatchStatus.match) { done = true; status = st; return; }
        started = true;
        const c = m.group(0);
        emptyPrev = c.begin == c.end;
        pos = c.end;
    }
}
