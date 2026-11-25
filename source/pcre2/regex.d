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
    /// Unicode properties for `\d \w \s \b` and POSIX classes (PCRE2_UCP).
    ucp = 1 << 7,
    /// A subject with invalid UTF-16 (a lone surrogate) is matched instead of failing with
    /// `MatchStatus.badUtf`: the invalid units simply never match a character. Requires `utf`.
    /// Offsets stay in code units of the original subject. `noUtfCheck` is then irrelevant, and
    /// matching always goes through `pcre2_match`, which scans the subject for invalid units on every
    /// call: iterating a long subject with many matches costs O(length) per match. For that, or if you
    /// want the units read as U+FFFD, use `MatchData.matchLossy` / `matchesLossy` instead.
    matchInvalidUtf = 1 << 8,
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
    badUtf, /// subject is not valid UTF-16 (e.g. a lone surrogate); see `MatchData.getStartchar`
    error, /// anything else; see `MatchData.errorCode`
    badOffset, /// `start` is past the end of the subject, or inside a surrogate pair (PCRE2_ERROR_BADOFFSET / BADUTFOFFSET)
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
/// (`pcre2_get_error_message`)
const(char)[] getErrorMessage(int code, char[] buf) nothrow @nogc @trusted
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

/// Former name of `getErrorMessage`.
alias errorMessage = getErrorMessage;

/// What `config` asks about the linked PCRE2 library (`PCRE2_CONFIG_*`).
enum ConfigWhat : uint
{
    jit = PCRE2_CONFIG_JIT, /// 1 if built with the JIT compiler
    newline = PCRE2_CONFIG_NEWLINE, /// the default newline convention (a `PCRE2_NEWLINE_*` value)
    unicode = PCRE2_CONFIG_UNICODE, /// 1 if built with Unicode support
}

/// Value of a numeric build-time option of the linked library, or -1 on error (`pcre2_config`).
int config(ConfigWhat what) nothrow @nogc @trusted
{
    int v;
    return pcre2_config_16(what, &v) == 0 ? v : -1;
}

/// True if the linked PCRE2 was built with the JIT compiler (`config(ConfigWhat.jit) == 1`).
bool libraryHasJit() nothrow @nogc @trusted
{
    return config(ConfigWhat.jit) == 1;
}

private shared size_t lastRegexId;

version (unittest)
{
    /// Compiled patterns alive right now (counted only in the unittest build): the tests check that every copy,
    /// every `MatchData` and every range lets go of its reference, so that the count returns to where it was.
    shared size_t livePayloads;
}

private struct Payload
{
    shared size_t refs;
    size_t id; // unique per compiled Regex in this process, never 0
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

// The reference counting, the C free functions and `free` are not `pure`, but a compiled `Regex` is
// immutable and its sharing is not observable through the type system, so `this(this)` and `~this()`
// are declared `pure` by casting these helpers to `pure` function types. This lets `pure` code
// (constructors, `dup`) hold a `Regex` by value.
private void retainPayload(Payload* pl) nothrow @nogc @trusted
{
    atomicFetchAdd(pl.refs, 1);
}

private void releasePayload(Payload* pl) nothrow @nogc @trusted
{
    if (atomicFetchSub(pl.refs, 1) == 1)
    {
        pcre2_code_free_16(pl.code);
        free(pl);
        version (unittest) atomicFetchSub(livePayloads, 1);
    }
}

private alias PurePayloadFn = void function(Payload*) pure nothrow @nogc;
private alias PureMatchDataFn = void function(MatchData*) pure nothrow @nogc;

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
        if (flags & Flags.ucp) opts |= PCRE2_UCP;
        if (flags & Flags.matchInvalidUtf) opts |= PCRE2_MATCH_INVALID_UTF;
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
        version (unittest) atomicFetchAdd(livePayloads, 1);
        pl.refs = 1;
        pl.id = atomicFetchAdd(lastRegexId, 1) + 1;
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

    this(this) pure nothrow @nogc @trusted
    {
        if (p) (cast(PurePayloadFn) &retainPayload)(p);
    }

    ~this() pure nothrow @nogc @trusted
    {
        if (p) (cast(PurePayloadFn) &releasePayload)(p);
        p = null;
    }

    /// Process-unique number of the compiled pattern (copies share it; never 0, 0 if `!valid`).
    /// Handy as a key for a per-thread cache of `MatchData`.
    @property size_t id() const pure nothrow @nogc @safe { return p ? p.id : 0; }

    @property bool valid() const pure nothrow @nogc @safe { return p !is null; }
    /// True if matching runs JIT compiled code (false: interpreter).
    @property bool jitEnabled() const pure nothrow @nogc @safe { return p !is null && p.jit; }
    /// Number of capture groups, not counting the whole match (group 0).
    @property uint captureCount() const pure nothrow @nogc @safe { return p ? p.captureCount : 0; }

    /// Number of the first group with this name, or -1. `name` is compared as UTF-16 code units.
    /// (`pcre2_substring_number_from_name`)
    int substringNumberFromName(const(wchar)[] name) const nothrow @nogc @trusted
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

    /// Former name of `substringNumberFromName`.
    alias groupIndex = substringNumberFromName;

    /// Number of named groups, and the i-th (in table order, i.e. sorted by name) name / group number.
    @property uint namedGroupCount() const pure nothrow @nogc @safe { return p ? p.nameCount : 0; }

    /// Name of the i-th named group as a slice of the compiled pattern's table (valid while a copy of
    /// the `Regex` lives), and its group number via `number`.
    const(wchar)[] namedGroup(uint i, out uint number) const nothrow @nogc @trusted
    {
        number = 0;
        if (p is null || i >= p.nameCount)
            return null;
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
        wchar* fixBuf; // repaired copy of a subject for the Lossy functions (malloc'd, reused)
        size_t fixCap;
        size_t fixGen; // bumped every time the repair buffer is rewritten; ranges over it check it
    }

    @disable this(this);

    /// Creates scratch for `re` (keeps `re` alive). Returns false in `ok` on out-of-memory.
    /// (`pcre2_match_data_create_from_pattern`, plus the match context and the JIT stack)
    static MatchData createFromPattern(ref const Regex re, out bool ok) nothrow @nogc @trusted
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

    /// Former name of `createFromPattern`.
    alias create = createFromPattern;

    ~this() pure nothrow @nogc @trusted
    {
        (cast(PureMatchDataFn) &destroyMatchData)(&this);
    }

    private static void destroyMatchData(MatchData* m) nothrow @nogc @trusted
    {
        m.release();
        if (m.pl) releasePayload(m.pl);
        m.pl = null;
    }

    private void release() nothrow @nogc @trusted
    {
        if (stack) pcre2_jit_stack_free_16(stack);
        if (mc) pcre2_match_context_free_16(mc);
        if (md) pcre2_match_data_free_16(md);
        if (fixBuf) free(fixBuf);
        stack = null; mc = null; md = null; fixBuf = null; fixCap = 0;
    }

    @property bool valid() const pure nothrow @nogc @safe { return pl !is null; }

    /// Matches `subject` from code unit offset `start` (`pcre2_match`). Groups are then available.
    MatchStatus match(const(wchar)[] subject, size_t start = 0) nothrow @nogc @trusted
    {
        if (pl is null)
            return nullStatus();
        return run(subject, start, (pl.noUtfCheck && !(pl.options & PCRE2_MATCH_INVALID_UTF)) ? PCRE2_NO_UTF_CHECK : 0);
    }

    // an invalid (default or failed-to-create) MatchData: an error value instead of a null dereference
    private MatchStatus nullStatus() nothrow @nogc @safe
    {
        rc = 0;
        err = PCRE2_ERROR_NULL;
        return MatchStatus.error;
    }

    /// Former name of `match`.
    alias search = match;

    private MatchStatus run(const(wchar)[] subject, size_t start, uint opts) nothrow @nogc @trusted
    {
        static immutable wchar[1] nul = [0];
        auto s = subject.length ? subject.ptr : nul.ptr;
        // A start past the end, and (with the UTF check skipped, when PCRE2 does not look at `start`) one inside a
        // surrogate pair, are rejected here in O(1), as the checking path would.
        if (start > subject.length
            || ((opts & PCRE2_NO_UTF_CHECK) && (pl.options & PCRE2_UTF) && start > 0 && start < subject.length
                && subject[start] >= 0xDC00 && subject[start] <= 0xDFFF
                && subject[start - 1] >= 0xD800 && subject[start - 1] <= 0xDBFF))
        {
            rc = start > subject.length ? PCRE2_ERROR_BADOFFSET : PCRE2_ERROR_BADUTFOFFSET;
            err = rc;
            return MatchStatus.badOffset;
        }
        // pcre2_jit_match does no UTF validation, so it is only used when the check is skipped;
        // otherwise pcre2_match (which still runs the JIT code, after validating the subject).
        // (with PCRE2_MATCH_INVALID_UTF the subject is scanned inside the match: always pcre2_match)
        rc = (pl.jit && (opts & PCRE2_NO_UTF_CHECK) && !(pl.options & PCRE2_MATCH_INVALID_UTF))
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
        case PCRE2_ERROR_BADOFFSET: case PCRE2_ERROR_BADUTFOFFSET:
            return MatchStatus.badOffset;
        default: return MatchStatus.error;
        }
    }

    /// PCRE2 error code of the last matching call (`match`, `matchLossy`, a step of a range), 0 if it did not fail.
    @property int errorCode() const pure nothrow @nogc @safe { return err; }

    /// After `MatchStatus.badUtf`: code unit offset of the offending unit (`pcre2_get_startchar`).
    @property size_t getStartchar() nothrow @nogc @trusted { return md ? pcre2_get_startchar_16(md) : 0; }

    /// Same as `getStartchar`, under a name that says what it is used for.
    alias badUtfOffset = getStartchar;

    /// Number of groups (including 0) the last match could report: `regex.captureCount + 1`.
    @property uint groupCount() const pure nothrow @nogc @trusted { return pl ? pl.captureCount + 1 : 0; }

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
        const n = re.substringNumberFromName(name);
        return n < 0 ? Capture(0, 0, false) : group(cast(uint) n);
    }

    /// `match` that reads each lone surrogate of `subject` as U+FFFD (an ordinary character: `.` and `[^a]` take
    /// it, unlike with `Flags.matchInvalidUtf`, where an invalid unit matches nothing). The text is copied
    /// only if it is not valid UTF-16; the copy has the same length, so every offset is that of `subject`.
    /// Returns `MatchStatus.error` if the copy cannot be allocated. The copy lives in this `MatchData` until
    /// the next Lossy call. With `Flags.matchInvalidUtf` nothing is ever repaired (that flag already accepts
    /// the subject).
    MatchStatus matchLossy(const(wchar)[] subject, size_t start = 0) nothrow @nogc @trusted
    {
        if (pl is null)
            return nullStatus();
        // the subject is validated here even for a regex compiled with `noUtfCheck`: that is the point
        auto st = run(subject, start, 0);
        if (st != MatchStatus.badUtf)
            return st;
        const fixed = repaired(subject);
        if (fixed is null)
        {
            err = PCRE2_ERROR_NOMEMORY;
            return MatchStatus.error;
        }
        return match(fixed, start);
    }

    /// `matches` that reads lone surrogates as U+FFFD, like `matchLossy`. The subject given to the range is
    /// the copy while one is needed. Another Lossy call on this `MatchData` rewrites that copy, so it ends the
    /// range at once: the range becomes empty with `status == MatchStatus.error` (never a stale read).
    Matches matchesLossy(const(wchar)[] subject, size_t start = 0) return nothrow @nogc @trusted
    {
        auto r = matchesChecked(subject, start);
        if (r.status != MatchStatus.badUtf)
            return r;
        const fixed = repaired(subject);
        if (fixed is null)
        {
            err = PCRE2_ERROR_NOMEMORY;
            r.status = MatchStatus.error;
            return r;
        }
        auto fr = matches(fixed, start);
        fr.gen = fixGen;
        return fr;
    }

    // `matches` that validates the subject even when the regex has `noUtfCheck`
    private Matches matchesChecked(const(wchar)[] subject, size_t start) return nothrow @nogc @trusted
    {
        auto r = Matches(&this, subject, start);
        r.forceCheck = true;
        r.advance();
        return r;
    }

    // `subject` with each lone surrogate replaced by U+FFFD, in the buffer of this MatchData; null if out of memory
    private const(wchar)[] repaired(const(wchar)[] subject) nothrow @nogc @trusted
    {
        import core.stdc.stdlib : realloc;

        if (fixCap < subject.length)
        {
            auto grown = cast(wchar*) realloc(fixBuf, subject.length * wchar.sizeof);
            if (grown is null)
                return null;
            fixBuf = grown;
            fixCap = subject.length;
        }
        ++fixGen;
        auto o = fixBuf[0 .. subject.length];
        foreach (i, unit; subject)
        {
            const high = unit >= 0xD800 && unit <= 0xDBFF, low = unit >= 0xDC00 && unit <= 0xDFFF;
            o[i] = unit;
            if (high && !(i + 1 < subject.length && subject[i + 1] >= 0xDC00 && subject[i + 1] <= 0xDFFF))
                o[i] = 0xFFFD;
            else if (low && !(i > 0 && subject[i - 1] >= 0xD800 && subject[i - 1] <= 0xDBFF
                    && o[i - 1] == subject[i - 1]))
                o[i] = 0xFFFD;
        }
        return o;
    }

    /// Lazy range over all non-overlapping matches in `subject` (front = whole match, `Capture`).
    /// The `MatchData` holds the groups of the current match. Check `status` after iteration:
    /// `noMatch` is normal completion, anything else is an error that ended the iteration.
    ///
    /// The first search runs inside this call, so the range is already positioned on the first match.
    /// If the subject is not valid UTF-16 (and `Flags.matchInvalidUtf` / `noUtfCheck` are not set),
    /// the range is returned empty with `status == MatchStatus.badUtf` before any element was
    /// produced (`getStartchar` says where); a caller may then repair the text and call again. The
    /// subject is validated once; later steps skip the check (not with `Flags.matchInvalidUtf`, see there). A limit stop (`matchLimit`, ...) is
    /// reported the same way: an empty range or a range that ends early, with that `status`.
    Matches matches(const(wchar)[] subject, size_t start = 0) return nothrow @nogc @trusted
    {
        auto r = Matches(&this, subject, start);
        r.advance();
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
    private bool forceCheck; // validate the first subject even if the regex has noUtfCheck
    private size_t gen; // not 0: the subject is the repair buffer of the MatchData, valid while its fixGen is this
    /// `noMatch` after normal exhaustion; otherwise the status that stopped the iteration.
    MatchStatus status = MatchStatus.noMatch;

    private this(MatchData* m, const(wchar)[] subject, size_t pos) nothrow @nogc
    {
        this.m = m; this.subject = subject; this.pos = pos;
        if (m.pl is null) // invalid MatchData: an empty range with an error status
        {
            done = true;
            status = m.nullStatus();
        }
    }

    @property bool empty() const pure nothrow @nogc @safe { return done; }
    @property Capture front() const pure nothrow @nogc @safe { return m.group(0); }
    void popFront() nothrow @nogc @safe { advance(); }

    private void advance() nothrow @nogc @trusted
    {
        if (done)
            return;
        if (gen && m.fixGen != gen) // the repair buffer was rewritten by another Lossy call
        {
            done = true;
            status = MatchStatus.error;
            return;
        }
        // After the first successful call the subject is known valid: skip re-validation (avoids O(n^2)).
        const invalidOk = (m.pl.options & PCRE2_MATCH_INVALID_UTF) != 0;
        uint extra = 0;
        if (!invalidOk && (started || (m.pl.noUtfCheck && !forceCheck)))
            extra = PCRE2_NO_UTF_CHECK;
        if (emptyPrev)
            extra |= PCRE2_NOTEMPTY_ATSTART | PCRE2_ANCHORED;
        auto st = m.run(subject, pos, extra);
        if (st == MatchStatus.noMatch && emptyPrev)
        {
            // no non-empty match at this position: step one character and search normally
            if (pos >= subject.length) { done = true; status = MatchStatus.noMatch; return; }
            pos += (m.pl.options & PCRE2_UTF) && subject[pos] >= 0xD800 && subject[pos] < 0xDC00
                && pos + 1 < subject.length && subject[pos + 1] >= 0xDC00 && subject[pos + 1] < 0xE000 ? 2 : 1;
            emptyPrev = false;
            st = m.run(subject, pos, invalidOk ? 0 : PCRE2_NO_UTF_CHECK);
        }
        if (st != MatchStatus.match) { done = true; status = st; return; }
        started = true;
        const c = m.group(0);
        emptyPrev = c.begin == c.end;
        pos = c.end;
    }
}
