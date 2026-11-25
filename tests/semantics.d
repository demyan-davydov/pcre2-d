/// Pins the semantics Log Tracy relies on. Every case runs with JIT and with the interpreter.
module semantics;

import pcre2;
import core.stdc.stdio : printf;
import pcre2.c_api : PCRE2_ERROR_MATCHLIMIT;

private struct T
{
    Regex re;
    MatchData md;
}

/// Compiles `pat`; asserts success.
private Regex mk(const(wchar)[] pat, Flags f)
{
    CompileError e;
    auto r = Regex.compile(pat, f, e);
    assert(r.valid, "compile failed");
    return r;
}

private MatchData scratch(ref Regex re)
{
    bool ok;
    auto m = MatchData.create(re, ok);
    assert(ok);
    return m;
}

/// Returns [begin, end] of the first match or [-1,-1].
private long[2] find(const(wchar)[] pat, const(wchar)[] subj, Flags f = Flags.utf)
{
    long[2] res = [-1, -1];
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(pat, f | jitOff);
        assert(jitOff == Flags.none || !re.jitEnabled);
        auto md = scratch(re);
        long[2] cur = [-1, -1];
        if (md.search(subj) == MatchStatus.match)
            cur = [cast(long) md.group(0).begin, cast(long) md.group(0).end];
        assert(jitOff == Flags.none || cur == res, "JIT and interpreter disagree");
        res = cur;
    }
    return res;
}

unittest // ASCII-only \d \w \s \b (no UCP)
{
    assert(find(`\d+`w, "x١٢٣ 42"w) == [5, 7]); // Arabic-Indic digits do not match
    assert(find(`\w+`w, "éé abc"w) == [3, 6]);
    assert(find(`\s`w, "a  b"w) == [2, 3]); // NBSP is not \s
    assert(find(`a\b`w, "aé"w) == [0, 1]); // \b between 'a' and non-ASCII é
}

unittest // caseless: Unicode simple case folding in UTF mode
{
    assert(find(`straße`w, "STRASSE"w, Flags.utf | Flags.caseless) == [-1, -1]); // simple folding only
    assert(find(`é`w, "É"w, Flags.utf | Flags.caseless) == [0, 1]);
    assert(find(`ж`w, "Ж"w, Flags.utf | Flags.caseless) == [0, 1]);
    assert(find(`abc`w, "ABC"w, Flags.utf | Flags.caseless) == [0, 3]);
    assert(find(`é`w, "É"w, Flags.utf) == [-1, -1]);
}

unittest // dot, dotAll
{
    assert(find(`a.b`w, "a\nb"w) == [-1, -1]);
    assert(find(`a.b`w, "a\rb"w) == [0, 3]); // only \n is a newline (build-time LF)
    assert(find(`a.b`w, "a\nb"w, Flags.utf | Flags.dotAll) == [0, 3]);
    assert(find(`^.$`w, "😀"w) == [0, 2]); // astral char: one `.`, two code units
}

unittest // $ and ^
{
    assert(find(`a$`w, "a\n"w, Flags.utf | Flags.dollarEndOnly) == [-1, -1]);
    assert(find(`a$`w, "a\n"w, Flags.utf) == [0, 1]); // without DOLLAR_ENDONLY, $ also before final \n
    assert(find(`a$`w, "a\nb"w, Flags.utf | Flags.dollarEndOnly) == [-1, -1]);
    assert(find(`a$`w, "a\nb"w, Flags.utf | Flags.dollarEndOnly | Flags.multiline) == [0, 1]);
    assert(find(`^b`w, "a\nb"w, Flags.utf | Flags.multiline) == [2, 3]);
    assert(find(`^b`w, "a\nb"w) == [-1, -1]);
}

unittest // lookahead, lazy quantifiers
{
    assert(find(`foo(?=bar)`w, "foobaz foobar"w) == [7, 10]);
    assert(find(`foo(?!bar)`w, "foobar foobaz"w) == [7, 10]);
    assert(find(`<.+?>`w, "<a><b>"w) == [0, 3]);
    assert(find(`<.+>`w, "<a><b>"w) == [0, 6]);
}

unittest // groups: participation vs empty, named groups
{
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`(a)|(b)(c*)(?<tail>d)?`w, Flags.utf | jitOff);
        assert(re.captureCount == 4);
        auto md = scratch(re);
        assert(md.search("xb"w) == MatchStatus.match);
        assert(md.group(0) == Capture(1, 2, true));
        assert(!md.group(1).participated); // group 1 did not participate
        assert(md.group(2) == Capture(1, 2, true));
        assert(md.group(3).participated && md.group(3).length == 0); // empty but participated
        assert(!md.group(4).participated);
        assert(re.groupIndex("tail"w) == 4);
        assert(re.groupIndex("nope"w) == -1);
        assert(md.search("bccd"w) == MatchStatus.match);
        assert(md.group(re, "tail"w) == Capture(3, 4, true));
        assert(re.namedGroupCount == 1);
        uint num;
        assert(re.namedGroup(0, num) == "tail"w && num == 4);
    }
}

unittest // compile errors carry the pattern offset
{
    CompileError e;
    auto re = Regex.compile(`ab(c`w, Flags.utf, e);
    assert(!re.valid);
    assert(e.code != 0 && e.offset == 4);
    char[256] buf;
    assert(errorMessage(e.code, buf[]).length > 0);
    auto re2 = Regex.compile(`a[`w, Flags.utf, e);
    assert(!re2.valid && e.offset == 2);
}

unittest // UTF validity: a lone surrogate in the subject is an error, not a crash
{
    wchar[3] s = ['a', 0xD800, 'b']; // lone high surrogate
    wchar[3] t = ['a', 0xDC00, 'b']; // lone low surrogate
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`b`w, Flags.utf | jitOff);
        auto md = scratch(re);
        assert(md.search(s[]) == MatchStatus.badUtf);
        assert(md.badUtfOffset == 1);
        assert(md.search(t[]) == MatchStatus.badUtf);
        // valid pair is fine
        assert(md.search("a😀b"w) == MatchStatus.match);
        assert(md.group(0) == Capture(3, 4, true));
    }
}

unittest // positions are UTF-16 code units; start offset
{
    auto re = mk(`é+`w, Flags.utf);
    auto md = scratch(re);
    assert(md.search("😀ééé"w) == MatchStatus.match);
    assert(md.group(0) == Capture(2, 5, true));
    assert(md.search("éxé"w, 1) == MatchStatus.match);
    assert(md.group(0).begin == 2);
}

unittest // iteration over all matches, including empty matches
{
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`\d+`w, Flags.utf | jitOff);
        auto md = scratch(re);
        size_t n;
        size_t[3] begins;
        auto r = md.matches("a1bb22ccc333"w);
        for (; !r.empty; r.popFront())
        {
            begins[n++] = r.front.begin;
        }
        assert(r.status == MatchStatus.noMatch);
        assert(n == 3 && begins == [1, 4, 9]);

        auto re2 = mk(`x*`w, Flags.utf | jitOff);
        auto md2 = scratch(re2);
        size_t count;
        for (auto q = md2.matches("axxb😀"w); !q.empty; q.popFront()) ++count;
        // empty at 0, "xx" at 1, empty at 3, empty at 4, empty at 6
        assert(count == 5);
    }
}

unittest // iteration reports a UTF error and stops
{
    wchar[3] s = ['a', 0xD800, 'a'];
    auto re = mk(`a`w, Flags.utf);
    auto md = scratch(re);
    auto r = md.matches(s[]);
    assert(r.empty && r.status == MatchStatus.badUtf);
}

unittest // limits: a catastrophic pattern ends with an error value
{
    wchar[40] subj = 'a';
    wchar[41] bad = 'a';
    bad[40] = 'b';
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        CompileError e;
        auto re = Regex.compile(`(a+)+$`w, Flags.utf | jitOff, e, Limits(10_000, 10_000, 20_000_000));
        assert(re.valid);
        auto md = scratch(re);
        auto st = md.search(bad[]);
        assert(st == MatchStatus.matchLimit, "catastrophic backtracking must hit the match limit");
        assert(md.errorCode == PCRE2_ERROR_MATCHLIMIT);
        // the same scratch still works afterwards
        assert(md.search(subj[]) == MatchStatus.match);
    }
}

unittest // depth limit (interpreter)
{
    wchar[200] s = 'a';
    CompileError e;
    auto re = Regex.compile(`(?:a|b)*c`w, Flags.utf | Flags.noJit, e, Limits(10_000_000, 5, 20_000_000));
    auto md = scratch(re);
    auto st = md.search(s[]);
    assert(st == MatchStatus.depthLimit || st == MatchStatus.noMatch, "depth limit status");
}

unittest // JIT availability is reported and the interpreter is a working fallback
{
    CompileError e;
    auto a = Regex.compile(`a+`w, Flags.utf, e);
    auto b = Regex.compile(`a+`w, Flags.utf | Flags.noJit, e);
    assert(a.jitEnabled == libraryHasJit() || !a.jitEnabled); // JIT may fail at runtime (e.g. no W^X permission)
    assert(!b.jitEnabled);
    auto md = scratch(b);
    assert(md.search("baa"w) == MatchStatus.match && md.group(0) == Capture(1, 3, true));
    version (unittest) printf("JIT in this build: %d\n", cast(int) a.jitEnabled);
}

unittest // the same Regex matched from several threads
{
    import core.thread : Thread;
    import core.atomic : atomicOp, atomicLoad;

    shared int okCount;
    CompileError e;
    auto re = Regex.compile(`(?<n>\d+)-(?=x)`w, Flags.utf, e);
    assert(re.valid);
    enum N = 8;
    Thread[N] ths;
    foreach (i; 0 .. N)
    {
        ths[i] = new Thread({
            auto local = re; // refcounted copy
            bool ok;
            auto md = MatchData.create(local, ok);
            if (!ok) return;
            bool good = true;
            foreach (k; 0 .. 20_000)
            {
                if (md.search("abc 123-x def"w) != MatchStatus.match || md.group(0) != Capture(4, 8, true)
                    || md.group(1) != Capture(4, 7, true))
                    good = false;
                if (md.search("abc 123-y"w) != MatchStatus.noMatch)
                    good = false;
            }
            if (good) atomicOp!"+="(okCount, 1);
        });
        ths[i].start();
    }
    foreach (t; ths) t.join();
    assert(atomicLoad(okCount) == N);
}

unittest // the whole API is @nogc nothrow and allocates nothing on the GC heap while matching
{
    import core.memory : GC;

    static void body() @nogc nothrow
    {
        CompileError e;
        auto re = Regex.compile(`(?<w>\w+)@(\w+)`w, Flags.utf | Flags.caseless, e);
        assert(re.valid);
        bool ok;
        auto md = MatchData.create(re, ok);
        assert(ok);
        size_t n;
        for (auto r = md.matches("a@b c@d x"w); !r.empty; r.popFront())
            ++n;
        assert(n == 2);
        char[128] buf;
        CompileError e2;
        auto bad = Regex.compile(`(`w, Flags.utf, e2);
        assert(!bad.valid && errorMessage(e2.code, buf[]).length);
    }

    const before = GC.stats().usedSize;
    body();
    assert(GC.stats().usedSize == before);
}

unittest // Flags.ucp: Unicode \d \w \s \b
{
    assert(find(`\w+`w, "éé abc"w, Flags.utf | Flags.ucp) == [0, 2]);
    assert(find(`\w+`w, "жук"w, Flags.utf | Flags.ucp) == [0, 3]);
    assert(find(`\d`w, "x٣"w, Flags.utf | Flags.ucp) == [1, 2]);
    assert(find(`a\b`w, "aé"w, Flags.utf | Flags.ucp) == [-1, -1]); // é is now a word character
    assert(find(`ж`w, "Ж"w, Flags.utf | Flags.ucp | Flags.caseless) == [0, 1]);
}

unittest // Flags.matchInvalidUtf: a lone surrogate is not an error, offsets are the original ones
{
    immutable wchar high = 0xD800, low = 0xDC00;
    immutable subj = "ok "w ~ high ~ " ok "w ~ low ~ " end"w;
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        // default: badUtf, before the first element
        auto plain = mk(`ok`w, Flags.utf | jitOff);
        auto md0 = scratch(plain);
        auto r0 = md0.matches(subj);
        assert(r0.empty && r0.status == MatchStatus.badUtf);
        assert(md0.badUtfOffset == 3);

        auto re = mk(`ok`w, Flags.utf | Flags.matchInvalidUtf | jitOff);
        auto md = scratch(re);
        size_t[2][] all;
        auto r = md.matches(subj);
        for (; !r.empty; r.popFront())
            all ~= [r.front.begin, r.front.end];
        assert(r.status == MatchStatus.noMatch);
        assert(all == [[0, 2], [5, 7]]);
        assert(md.search(subj) == MatchStatus.match);

        auto dots = mk(`.`w, Flags.utf | Flags.matchInvalidUtf | jitOff);
        auto md2 = scratch(dots);
        size_t n;
        for (auto q = md2.matches("a"w ~ high ~ "b"w); !q.empty; q.popFront())
            ++n;
        assert(n >= 2); // a and b at least; the offsets stay in the original text
    }
}

unittest // Regex.id is unique per compile and shared by copies
{
    auto a = mk(`a`w, Flags.utf);
    auto b = mk(`a`w, Flags.utf);
    auto a2 = a;
    assert(a.id != 0 && a.id != b.id && a.id == a2.id);
    assert(Regex.init.id == 0);
}

unittest // Regex and MatchData can be held by value in pure code
{
    static struct Holder
    {
        Regex re;
    }

    static Holder make(Holder h) pure nothrow @nogc @safe
    {
        Holder copy = h; // postblit
        return copy; // destructors of temporaries
    }

    static void useMatchData(MatchData m) pure nothrow @nogc @safe
    {
    }

    auto h = Holder(mk(`a`w, Flags.utf));
    auto h2 = make(h);
    assert(h2.re.valid && h2.re.id == h.re.id);
    bool ok;
    useMatchData(MatchData.create(h.re, ok));
}
