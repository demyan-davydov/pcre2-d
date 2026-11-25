/// Pins the semantics Log Tracy relies on. Every case runs with JIT and with the interpreter.
module semantics;

import pcre2;
import core.stdc.stdio : printf;
import std.typecons : tuple;
import pcre2.c_api : PCRE2_ERROR_MATCHLIMIT, PCRE2_ERROR_NULL, PCRE2_ERROR_DEPTHLIMIT;

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
    auto m = MatchData.createFromPattern(re, ok);
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
        if (md.match(subj) == MatchStatus.match)
            cur = [cast(long) md.group(0).begin, cast(long) md.group(0).end];
        assert(jitOff == Flags.none || cur == res, "JIT and interpreter disagree");
        res = cur;
    }
    return res;
}

@("ASCII-only \\d \\w \\s \\b (no UCP)")
unittest
{
    assert(find(`\d+`w, "x١٢٣ 42"w) == [5, 7]); // Arabic-Indic digits do not match
    assert(find(`\w+`w, "éé abc"w) == [3, 6]);
    assert(find(`\s`w, "a  b"w) == [2, 3]); // NBSP is not \s
    assert(find(`a\b`w, "aé"w) == [0, 1]); // \b between 'a' and non-ASCII é
}

@("caseless: Unicode simple case folding in UTF mode")
unittest
{
    assert(find(`straße`w, "STRASSE"w, Flags.utf | Flags.caseless) == [-1, -1]); // simple folding only
    assert(find(`é`w, "É"w, Flags.utf | Flags.caseless) == [0, 1]);
    assert(find(`ж`w, "Ж"w, Flags.utf | Flags.caseless) == [0, 1]);
    assert(find(`abc`w, "ABC"w, Flags.utf | Flags.caseless) == [0, 3]);
    assert(find(`é`w, "É"w, Flags.utf) == [-1, -1]);
}

@("dot, dotAll")
unittest
{
    assert(find(`a.b`w, "a\nb"w) == [-1, -1]);
    assert(find(`a.b`w, "a\rb"w) == [0, 3]); // only \n is a newline (build-time LF)
    assert(find(`a.b`w, "a\nb"w, Flags.utf | Flags.dotAll) == [0, 3]);
    assert(find(`^.$`w, "😀"w) == [0, 2]); // astral char: one `.`, two code units
}

@("$ and ^")
unittest
{
    assert(find(`a$`w, "a\n"w, Flags.utf | Flags.dollarEndOnly) == [-1, -1]);
    assert(find(`a$`w, "a\n"w, Flags.utf) == [0, 1]); // without DOLLAR_ENDONLY, $ also before final \n
    assert(find(`a$`w, "a\nb"w, Flags.utf | Flags.dollarEndOnly) == [-1, -1]);
    assert(find(`a$`w, "a\nb"w, Flags.utf | Flags.dollarEndOnly | Flags.multiline) == [0, 1]);
    assert(find(`^b`w, "a\nb"w, Flags.utf | Flags.multiline) == [2, 3]);
    assert(find(`^b`w, "a\nb"w) == [-1, -1]);
}

@("lookahead, lazy quantifiers")
unittest
{
    assert(find(`foo(?=bar)`w, "foobaz foobar"w) == [7, 10]);
    assert(find(`foo(?!bar)`w, "foobar foobaz"w) == [7, 10]);
    assert(find(`<.+?>`w, "<a><b>"w) == [0, 3]);
    assert(find(`<.+>`w, "<a><b>"w) == [0, 6]);
}

@("groups: participation vs empty, named groups")
unittest
{
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`(a)|(b)(c*)(?<tail>d)?`w, Flags.utf | jitOff);
        assert(re.captureCount == 4);
        auto md = scratch(re);
        assert(md.match("xb"w) == MatchStatus.match);
        assert(md.group(0) == Capture(1, 2, true));
        assert(!md.group(1).participated); // group 1 did not participate
        assert(md.group(2) == Capture(1, 2, true));
        assert(md.group(3).participated && md.group(3).length == 0); // empty but participated
        assert(!md.group(4).participated);
        assert(re.substringNumberFromName("tail"w) == 4);
        assert(re.substringNumberFromName("nope"w) == -1);
        assert(md.match("bccd"w) == MatchStatus.match);
        assert(md.group(re, "tail"w) == Capture(3, 4, true));
        assert(re.namedGroupCount == 1);
        uint num;
        assert(re.namedGroup(0, num) == "tail"w && num == 4);
    }
}

@("compile errors carry the pattern offset")
unittest
{
    CompileError e;
    auto re = Regex.compile(`ab(c`w, Flags.utf, e);
    assert(!re.valid);
    assert(e.code != 0 && e.offset == 4);
    char[256] buf;
    assert(getErrorMessage(e.code, buf[]).length > 0);
    auto re2 = Regex.compile(`a[`w, Flags.utf, e);
    assert(!re2.valid && e.offset == 2);
}

@("UTF validity: a lone surrogate in the subject is an error, not a crash")
unittest
{
    wchar[3] s = ['a', 0xD800, 'b']; // lone high surrogate
    wchar[3] t = ['a', 0xDC00, 'b']; // lone low surrogate
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`b`w, Flags.utf | jitOff);
        auto md = scratch(re);
        assert(md.match(s[]) == MatchStatus.badUtf);
        assert(md.getStartchar == 1);
        assert(md.match(t[]) == MatchStatus.badUtf);
        // valid pair is fine
        assert(md.match("a😀b"w) == MatchStatus.match);
        assert(md.group(0) == Capture(3, 4, true));
    }
}

@("positions are UTF-16 code units; start offset")
unittest
{
    auto re = mk(`é+`w, Flags.utf);
    auto md = scratch(re);
    assert(md.match("😀ééé"w) == MatchStatus.match);
    assert(md.group(0) == Capture(2, 5, true));
    assert(md.match("éxé"w, 1) == MatchStatus.match);
    assert(md.group(0).begin == 2);
}

@("iteration over all matches, including empty matches")
unittest
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

@("iteration reports a UTF error and stops")
unittest
{
    wchar[3] s = ['a', 0xD800, 'a'];
    auto re = mk(`a`w, Flags.utf);
    auto md = scratch(re);
    auto r = md.matches(s[]);
    assert(r.empty && r.status == MatchStatus.badUtf);
}

@("limits: a catastrophic pattern ends with an error value")
unittest
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
        auto st = md.match(bad[]);
        assert(st == MatchStatus.matchLimit, "catastrophic backtracking must hit the match limit");
        assert(md.errorCode == PCRE2_ERROR_MATCHLIMIT);
        // the same scratch still works afterwards
        assert(md.match(subj[]) == MatchStatus.match);
    }
}

@("depth limit (interpreter): nested lookaheads are nested matches")
unittest
{
    CompileError e;
    enum nested = `(?=(?=(?=(?=(?=(?=(?=(?=(?=(?=a))))))))))a`w;
    auto re = Regex.compile(nested, Flags.utf | Flags.noJit, e, Limits(10_000_000, 3, 20_000_000));
    assert(re.valid);
    auto md = scratch(re);
    assert(md.match("a"w) == MatchStatus.depthLimit);
    assert(md.errorCode == PCRE2_ERROR_DEPTHLIMIT);
    auto re2 = Regex.compile(nested, Flags.utf | Flags.noJit, e);
    auto md2 = scratch(re2);
    assert(md2.match("a"w) == MatchStatus.match);
}

@("JIT availability is reported and the interpreter is a working fallback")
unittest
{
    CompileError e;
    auto a = Regex.compile(`a+`w, Flags.utf, e);
    auto b = Regex.compile(`a+`w, Flags.utf | Flags.noJit, e);
    assert(a.jitEnabled == libraryHasJit() || !a.jitEnabled); // JIT may fail at runtime (e.g. no W^X permission)
    assert(!b.jitEnabled);
    auto md = scratch(b);
    assert(md.match("baa"w) == MatchStatus.match && md.group(0) == Capture(1, 3, true));
    version (unittest) printf("JIT in this build: %d\n", cast(int) a.jitEnabled);
}

@("the same Regex matched from several threads")
unittest
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
            auto md = MatchData.createFromPattern(local, ok);
            if (!ok) return;
            bool good = true;
            foreach (k; 0 .. 20_000)
            {
                if (md.match("abc 123-x def"w) != MatchStatus.match || md.group(0) != Capture(4, 8, true)
                    || md.group(1) != Capture(4, 7, true))
                    good = false;
                if (md.match("abc 123-y"w) != MatchStatus.noMatch)
                    good = false;
            }
            if (good) atomicOp!"+="(okCount, 1);
        });
        ths[i].start();
    }
    foreach (t; ths) t.join();
    assert(atomicLoad(okCount) == N);
}

@("the whole API is @nogc nothrow and allocates nothing on the GC heap while matching")
unittest
{
    import core.memory : GC;

    static void body() @nogc nothrow
    {
        CompileError e;
        auto re = Regex.compile(`(?<w>\w+)@(\w+)`w, Flags.utf | Flags.caseless, e);
        assert(re.valid);
        bool ok;
        auto md = MatchData.createFromPattern(re, ok);
        assert(ok);
        size_t n;
        for (auto r = md.matches("a@b c@d x"w); !r.empty; r.popFront())
            ++n;
        assert(n == 2);
        char[128] buf;
        CompileError e2;
        auto bad = Regex.compile(`(`w, Flags.utf, e2);
        assert(!bad.valid && getErrorMessage(e2.code, buf[]).length);
    }

    const before = GC.stats().usedSize;
    body();
    assert(GC.stats().usedSize == before);
}

@("Flags.ucp: Unicode \\d \\w \\s \\b")
unittest
{
    assert(find(`\w+`w, "éé abc"w, Flags.utf | Flags.ucp) == [0, 2]);
    assert(find(`\w+`w, "жук"w, Flags.utf | Flags.ucp) == [0, 3]);
    assert(find(`\d`w, "x٣"w, Flags.utf | Flags.ucp) == [1, 2]);
    assert(find(`a\b`w, "aé"w, Flags.utf | Flags.ucp) == [-1, -1]); // é is now a word character
    assert(find(`ж`w, "Ж"w, Flags.utf | Flags.ucp | Flags.caseless) == [0, 1]);
}

@("Flags.matchInvalidUtf: a lone surrogate is not an error, offsets are the original ones")
unittest
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
        assert(md0.getStartchar == 3);

        auto re = mk(`ok`w, Flags.utf | Flags.matchInvalidUtf | jitOff);
        auto md = scratch(re);
        size_t[2][] all;
        auto r = md.matches(subj);
        for (; !r.empty; r.popFront())
            all ~= [r.front.begin, r.front.end];
        assert(r.status == MatchStatus.noMatch);
        assert(all == [[0, 2], [5, 7]]);
        assert(md.match(subj) == MatchStatus.match);

        auto dots = mk(`.`w, Flags.utf | Flags.matchInvalidUtf | jitOff);
        auto md2 = scratch(dots);
        size_t[2][] dotPairs;
        for (auto q = md2.matches("a"w ~ high ~ "b"w); !q.empty; q.popFront())
            dotPairs ~= [q.front.begin, q.front.end];
        assert(dotPairs == [[0, 1], [2, 3]], "an invalid unit matches nothing; offsets are the original ones");
    }
}

@("Regex.id is unique per compile and shared by copies")
unittest
{
    auto a = mk(`a`w, Flags.utf);
    auto b = mk(`a`w, Flags.utf);
    auto a2 = a;
    assert(a.id != 0 && a.id != b.id && a.id == a2.id);
    assert(Regex.init.id == 0);
}

@("Regex and MatchData can be held by value in pure code")
unittest
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
    useMatchData(MatchData.createFromPattern(h.re, ok));
}

@("the former names stay as aliases")
unittest
{
    auto re = mk(`(?<k>a)`w, Flags.utf);
    auto md = scratch(re);
    assert(md.search("xa"w) == MatchStatus.match);
    assert(re.groupIndex("k"w) == 1);
    CompileError e;
    char[64] buf;
    Regex.compile(`(`w, Flags.utf, e);
    assert(errorMessage(e.code, buf[]) == getErrorMessage(e.code, buf[]));
    bool ok;
    auto md2 = MatchData.create(re, ok);
    assert(ok && libraryHasJit() == (config(ConfigWhat.jit) == 1));
    assert(config(ConfigWhat.unicode) == 1);
}

@("matchLossy / matchesLossy: a lone surrogate reads as U+FFFD, offsets are the original ones")
unittest
{
    immutable wchar high = 0xD800, low = 0xDC00;
    immutable subj = "ok "w ~ high ~ " ok "w ~ low ~ " end"w;
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`ok`w, Flags.utf | jitOff);
        auto md = scratch(re);
        size_t[2][] all;
        auto r = md.matchesLossy(subj);
        for (; !r.empty; r.popFront())
            all ~= [r.front.begin, r.front.end];
        assert(r.status == MatchStatus.noMatch);
        assert(all == [[0, 2], [5, 7]]);

        assert(md.matchLossy(subj) == MatchStatus.match);
        assert(md.group(0) == Capture(0, 2, true));
        assert(md.matchLossy(subj, 3) == MatchStatus.match);
        assert(md.group(0) == Capture(5, 7, true));

        // U+FFFD is an ordinary character: `.` takes the lone surrogate (not so with matchInvalidUtf)
        auto dot = mk(`^a.b$`w, Flags.utf | jitOff);
        auto md2 = scratch(dot);
        assert(md2.match("a"w ~ high ~ "b"w) == MatchStatus.badUtf);
        assert(md2.matchLossy("a"w ~ high ~ "b"w) == MatchStatus.match);
        assert(md2.group(0) == Capture(0, 3, true));
        assert(md2.matchLossy("a"w ~ low ~ "b"w) == MatchStatus.match);
        // a valid pair next to broken ones stays a pair
        assert(md2.matchLossy("a😀b"w) == MatchStatus.match && md2.group(0).end == 4);
        auto dots = mk(`^.{3}$`w, Flags.utf | jitOff);
        auto md3 = scratch(dots);
        assert(md3.matchLossy("a"w ~ high ~ high ~ low ~ "b"w) == MatchStatus.noMatch); // a, FFFD, pair, b = 4 chars
        assert(md3.matchLossy("a"w ~ low ~ low) == MatchStatus.match); // a, FFFD, FFFD

        auto inv = mk(`^a.b$`w, Flags.utf | Flags.matchInvalidUtf | jitOff);
        auto md4 = scratch(inv);
        assert(md4.match("a"w ~ high ~ "b"w) == MatchStatus.noMatch); // an invalid unit matches nothing
    }
}

@("matchLossy with limits: the status is still reported")
unittest
{
    import std.array : replicate;
    import std.conv : to;

    auto re = mk(`(a+)+b`w, Flags.utf);
    auto md = scratch(re);
    const text = ("a".replicate(5000) ~ "!b").to!wstring;
    assert(md.matchLossy(text) == MatchStatus.matchLimit);
    auto r = md.matchesLossy(text);
    assert(r.empty && r.status == MatchStatus.matchLimit);
    const withBad = ("a".replicate(5000) ~ "!b").to!wstring ~ cast(wchar) 0xD800;
    r = md.matchesLossy(withBad);
    assert(r.empty && r.status == MatchStatus.matchLimit);
}

@("matchInvalidUtf together with noUtfCheck, exact offsets")
unittest
{
    immutable wchar high = 0xD800;
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`.`w, Flags.utf | Flags.matchInvalidUtf | Flags.noUtfCheck | jitOff);
        auto md = scratch(re);
        size_t[2][] all;
        for (auto r = md.matches("a"w ~ high ~ "b"w); !r.empty; r.popFront())
            all ~= [r.front.begin, r.front.end];
        assert(all == [[0, 1], [2, 3]]);
    }
}

@("a Regex copied and destroyed from pure code by many threads keeps its refcount right")
unittest
{
    import core.thread : Thread;

    static Regex copyAround(Regex r) pure nothrow @nogc @trusted
    {
        Regex c = r;
        Regex d = c;
        return d;
    }

    auto re = mk(`a+`w, Flags.utf);
    Thread[] ths;
    foreach (t; 0 .. 8)
    {
        ths ~= new Thread({
            foreach (i; 0 .. 200_000)
            {
                auto c = copyAround(re);
                assert(c.valid);
            }
        });
        ths[$ - 1].start();
    }
    foreach (t; ths)
        t.join();
    bool ok;
    auto md = MatchData.createFromPattern(re, ok);
    assert(ok && md.match("caab"w) == MatchStatus.match && md.group(0) == Capture(1, 3, true));
}

@("an invalid Regex or MatchData gives values, not a null dereference")
unittest
{
    Regex none;
    assert(!none.valid && none.captureCount == 0 && none.namedGroupCount == 0 && none.id == 0);
    uint number = 7;
    assert(none.namedGroup(0, number) is null && number == 0);
    assert(none.substringNumberFromName("x"w) == -1);

    MatchData blank;
    assert(!blank.valid && blank.groupCount == 0 && blank.getStartchar == 0);
    assert(blank.match("a"w) == MatchStatus.error && blank.errorCode == PCRE2_ERROR_NULL);
    assert(blank.matchLossy("a"w) == MatchStatus.error);
    auto r = blank.matches("a"w);
    assert(r.empty && r.status == MatchStatus.error);
    auto r2 = blank.matchesLossy("a"w);
    assert(r2.empty && r2.status == MatchStatus.error);
    assert(!blank.group(0).participated);
}

@("a start offset past the end or inside a surrogate pair is badOffset")
unittest
{
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`x`w, Flags.utf | jitOff);
        auto md = scratch(re);
        assert(md.match("a😀x"w, 2) == MatchStatus.badOffset); // between the halves of the pair
        assert(md.match("ab"w, 5) == MatchStatus.badOffset);
        assert(md.match("a😀x"w, 3) == MatchStatus.match);
    }
}

@("the Lossy functions validate even when the regex has noUtfCheck")
unittest
{
    immutable wchar high = 0xD800;
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`^a.b$`w, Flags.utf | Flags.noUtfCheck | jitOff);
        auto md = scratch(re);
        assert(md.matchLossy("a"w ~ high ~ "b"w) == MatchStatus.match);
        assert(md.group(0) == Capture(0, 3, true));
        auto r = md.matchesLossy("a"w ~ high ~ "b"w);
        assert(!r.empty && r.front == Capture(0, 3, true));
    }
}

@("a Lossy range ends with an error if another Lossy call rewrote its buffer")
unittest
{
    immutable wchar high = 0xD800;
    auto re = mk(`a`w, Flags.utf);
    auto md = scratch(re);
    const text = "a"w ~ high ~ "a"w ~ high ~ "a"w;
    auto r = md.matchesLossy(text);
    assert(!r.empty);
    size_t n;
    for (; !r.empty; r.popFront())
    {
        ++n;
        if (n == 1)
            md.matchLossy("aaaaaaaaaaaaaaaaaaaaaaaa"w ~ high ~ "a"w); // longer: realloc, buffer rewritten
    }
    assert(n == 1 && r.status == MatchStatus.error);

    // without interference the whole text is walked
    n = 0;
    auto r2 = md.matchesLossy(text);
    for (; !r2.empty; r2.popFront())
        ++n;
    assert(n == 3 && r2.status == MatchStatus.noMatch);
}

@("noUtfCheck does not let a start offset inside a surrogate pair through, with or without JIT")
unittest
{
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto re = mk(`.`w, Flags.utf | Flags.noUtfCheck | jitOff);
        auto md = scratch(re);
        assert(md.match("a😀x"w, 2) == MatchStatus.badOffset);
        assert(md.match("a😀x"w, 1) == MatchStatus.match && md.group(0) == Capture(1, 3, true));
        assert(md.match("a😀x"w, 3) == MatchStatus.match && md.group(0) == Capture(3, 4, true));
        assert(md.match("ab"w, 5) == MatchStatus.badOffset);
    }
}

@("the Lossy functions allocate nothing on the GC heap, not even when they repair a text")
unittest
{
    import core.memory : GC;

    static void body() @nogc nothrow
    {
        CompileError e;
        auto re = Regex.compile(`a.b`w, Flags.utf, e);
        assert(re.valid);
        bool ok;
        auto md = MatchData.createFromPattern(re, ok);
        assert(ok);
        wchar[3] bad = ['a', 0xD800, 'b'];
        foreach (round; 0 .. 3) // the first round grows the buffer, the others reuse it
        {
            assert(md.matchLossy(bad[]) == MatchStatus.match);
            size_t n;
            for (auto r = md.matchesLossy(bad[]); !r.empty; r.popFront())
                ++n;
            assert(n == 1);
        }
    }

    const before = GC.stats().usedSize;
    body();
    assert(GC.stats().usedSize == before);
}

@("a Lossy range survives a Lossy call that did not rewrite the buffer, and plain matches do not touch it")
unittest
{
    immutable wchar high = 0xD800;
    auto re = mk(`a`w, Flags.utf);
    auto md = scratch(re);
    const text = "a"w ~ high ~ "a"w ~ high ~ "a"w;
    auto r = md.matchesLossy(text);
    size_t n;
    for (; !r.empty; r.popFront())
    {
        ++n;
        assert(md.matchLossy("aaa"w) == MatchStatus.match); // valid text: no repair, no rewrite
    }
    assert(n == 3 && r.status == MatchStatus.noMatch);

    // a plain `match` on another text does not rewrite the repair buffer either (it only changes the groups)
    auto r2 = md.matchesLossy(text);
    assert(!r2.empty);
    md.match("zzz"w);
    r2.popFront();
    assert(r2.status != MatchStatus.error);
}

@("pcre2_jit_match accepts PCRE2_NO_UTF_CHECK: the fast path of the Lossy functions depends on it")
unittest
{
    import pcre2.c_api;

    if (!libraryHasJit())
        return;
    int ec;
    size_t eo;
    static immutable wchar[5] pat = ['E', 'R', 'R', 'O', 'R'];
    auto code = pcre2_compile_16(pat.ptr, pat.length, PCRE2_UTF, &ec, &eo, null);
    assert(code !is null);
    assert(pcre2_jit_compile_16(code, PCRE2_JIT_COMPLETE) == 0);
    auto md = pcre2_match_data_create_from_pattern_16(code, null);
    auto mc = pcre2_match_context_create_16(null);
    static immutable wchar[8] text = ['a', ' ', 'E', 'R', 'R', 'O', 'R', ' '];
    const rc = pcre2_jit_match_16(code, text.ptr, text.length, 0, PCRE2_NO_UTF_CHECK, md, mc);
    assert(rc > 0, "jit_match with PCRE2_NO_UTF_CHECK");
    assert(pcre2_get_ovector_pointer_16(md)[0] == 2 && pcre2_get_ovector_pointer_16(md)[1] == 7);
    pcre2_match_context_free_16(mc);
    pcre2_match_data_free_16(md);
    pcre2_code_free_16(code);
}

@("matchLossy and matchesLossy: same answers and offsets for texts with no surrogate, a valid pair, a lone surrogate")
unittest
{
    immutable wchar high = 0xD800, low = 0xDC00;
    immutable wstring plain = "xx ERROR yy"w;
    immutable wstring paired = "xx 😀 ERROR yy"w;
    immutable wstring lone = "xx "w ~ high ~ " ERROR "w ~ low ~ " yy"w;
    foreach (flags; [Flags.utf, Flags.utf | Flags.noUtfCheck])
        foreach (jitOff; [Flags.none, Flags.noJit])
        {
            auto re = mk(`\bERROR\b`w, flags | jitOff);
            auto md = scratch(re);
            // (text, begin, end) of the match, which lie in the text as it is
            foreach (t; [tuple(plain, 3, 8), tuple(paired, 6, 11), tuple(lone, 5, 10)])
            {
                assert(md.matchLossy(t[0]) == MatchStatus.match);
                assert(md.group(0) == Capture(t[1], t[2], true));
                auto r = md.matchesLossy(t[0]);
                assert(!r.empty && r.front == Capture(t[1], t[2], true));
                r.popFront();
                assert(r.empty && r.status == MatchStatus.noMatch);
                assert(md.matchLossy(t[0], t[2]) == MatchStatus.noMatch);
            }
            assert(md.matchLossy(""w) == MatchStatus.noMatch);
            assert(md.matchLossy("ERROR"w, 5) == MatchStatus.noMatch);
            assert(md.matchLossy("ERROR"w, 6) == MatchStatus.badOffset);
        }
}

@("matchLossy scans for surrogates only from where PCRE2 can read: the start minus the look-behind")
unittest
{
    immutable wchar high = 0xD800;
    foreach (flags; [Flags.utf, Flags.utf | Flags.noUtfCheck])
        foreach (jitOff; [Flags.none, Flags.noJit])
        {
            // a lone surrogate far before `start` is never read: the answer is the same as before
            auto re = mk(`ERROR`w, flags | jitOff);
            auto md = scratch(re);
            const far = "x"w ~ high ~ " ........ ERROR"w;
            assert(md.matchLossy(far, 6) == MatchStatus.match && md.group(0) == Capture(12, 17, true));
            auto r = md.matchesLossy(far, 6);
            assert(!r.empty && r.front == Capture(12, 17, true));

            // inside the look-behind a lone surrogate is read, so it is repaired: `.` takes it
            auto lb = mk(`(?<=.)b`w, flags | jitOff);
            auto md2 = scratch(lb);
            assert(md2.matchLossy(high ~ "b"w, 1) == MatchStatus.match && md2.group(0) == Capture(1, 2, true));
            auto r2 = md2.matchesLossy(high ~ "b"w, 1);
            assert(!r2.empty && r2.front == Capture(1, 2, true));

            // `\b` looks one character back as well
            auto wb = mk(`\bb`w, flags | jitOff);
            auto md3 = scratch(wb);
            assert(md3.matchLossy(high ~ "b"w, 1) == MatchStatus.match);
        }
}

@("matchLossy: boundaries of the scanned region (start at the end, past the end, empty text, surrogate at index 0)")
unittest
{
    immutable wchar high = 0xD800, low = 0xDC00;
    foreach (flags; [Flags.utf, Flags.utf | Flags.noUtfCheck])
        foreach (jitOff; [Flags.none, Flags.noJit])
        {
            auto re = mk(`(?<=.)$`w, flags | jitOff);
            auto md = scratch(re);
            // a lone surrogate right before the end is read by the look-behind: repaired, `.` takes it
            foreach (lone; [high, low])
            {
                immutable wstring t = "a"w ~ lone;
                assert(md.matchLossy(t, 2) == MatchStatus.match && md.group(0) == Capture(2, 2, true));
                auto r = md.matchesLossy(t, 2);
                assert(!r.empty && r.front == Capture(2, 2, true));
                assert(md.matchLossy(t, 3) == MatchStatus.badOffset);
                auto r2 = md.matchesLossy(t, 3);
                assert(r2.empty && r2.status == MatchStatus.badOffset);
            }
            // a surrogate at index 0, the look-behind from index 1 reads it
            auto lb = mk(`(?<=.)b`w, flags | jitOff);
            auto md2 = scratch(lb);
            assert(md2.matchLossy(low ~ "b"w, 1) == MatchStatus.match && md2.group(0) == Capture(1, 2, true));
            // empty text, start 0 and past the end
            auto any = mk(`x*`w, flags | jitOff);
            auto md3 = scratch(any);
            assert(md3.matchLossy(""w) == MatchStatus.match && md3.group(0) == Capture(0, 0, true));
            assert(md3.matchLossy(""w, 1) == MatchStatus.badOffset);
            auto r3 = md3.matchesLossy(""w);
            assert(!r3.empty && r3.front == Capture(0, 0, true));
            r3.popFront();
            assert(r3.empty && r3.status == MatchStatus.noMatch);
        }
}

@("an unbound MatchData serves any number of regexes, growing its ovector")
unittest
{
    import std.conv : to;

    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        bool ok;
        auto md = MatchData.create(ok, 1); // room for group 0 only
        assert(ok && md.valid && md.groupCount == 0);
        // more regexes than the old cache had slots, with 0..24 groups each
        foreach (round; 0 .. 2)
            foreach (n; 0 .. 25)
            {
                wstring pat;
                foreach (g; 0 .. n)
                    pat ~= "(x" ~ g.to!wstring ~ ")"w;
                auto re = mk(pat ~ "end"w, Flags.utf | jitOff);
                wstring text = "a "w;
                foreach (g; 0 .. n)
                    text ~= "x"w ~ g.to!wstring;
                text ~= "end"w;
                assert(md.match(re, text) == MatchStatus.match);
                assert(md.groupCount == n + 1);
                assert(md.group(0) == Capture(2, text.length, true));
                if (n > 0)
                {
                    assert(md.group(1) == Capture(2, 4, true));
                    assert(md.group(n).participated && md.group(n).end == text.length - 3);
                }
            }
    }
}

@("an unbound MatchData applies the limits of each regex, and a JIT stack only when one is needed")
unittest
{
    wchar[40] bad = 'a';
    bad[39] = 'b';
    CompileError e;
    auto tight = Regex.compile(`(a+)+$`w, Flags.utf, e, Limits(10_000, 10_000, 20_000_000));
    auto loose = mk(`a+b`w, Flags.utf);
    auto interp = mk(`a+b`w, Flags.utf | Flags.noJit);
    bool ok;
    auto md = MatchData.create(ok);
    assert(ok);
    foreach (round; 0 .. 3)
    {
        assert(md.match(tight, bad[]) == MatchStatus.matchLimit);
        assert(md.match(loose, bad[]) == MatchStatus.match && md.group(0) == Capture(0, 40, true));
        assert(md.match(interp, bad[]) == MatchStatus.match);
        assert(md.match(tight, bad[]) == MatchStatus.matchLimit, "the limit comes back with its regex");
    }
}

@("an unbound MatchData: matches, matchLossy and matchesLossy take the regex too")
unittest
{
    immutable wchar high = 0xD800;
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        auto a = mk(`a`w, Flags.utf | jitOff);
        auto dot = mk(`^a.b$`w, Flags.utf | jitOff);
        bool ok;
        auto md = MatchData.create(ok);
        size_t[2][] all;
        for (auto r = md.matches(a, "xaxa"w); !r.empty; r.popFront())
            all ~= [r.front.begin, r.front.end];
        assert(all == [[1, 2], [3, 4]]);

        assert(md.matchLossy(dot, "a"w ~ high ~ "b"w) == MatchStatus.match);
        assert(md.group(0) == Capture(0, 3, true));
        all = null;
        for (auto r = md.matchesLossy(a, "a"w ~ high ~ "a"w); !r.empty; r.popFront())
            all ~= [r.front.begin, r.front.end];
        assert(all == [[0, 1], [2, 3]]);
        assert(md.match(dot, "a"w ~ high ~ "b"w) == MatchStatus.badUtf);
        assert(md.getStartchar == 1);
    }
}

@("a range ends with an error when another regex is put into its MatchData, not when the same one is")
unittest
{
    auto a = mk(`a`w, Flags.utf);
    auto b = mk(`b`w, Flags.utf);
    bool ok;
    auto md = MatchData.create(ok);
    size_t n;
    auto r = md.matches(a, "aaaa"w);
    for (; !r.empty; r.popFront())
    {
        ++n;
        assert(md.match(a, "zz a"w) == MatchStatus.match); // the same regex: the range goes on
    }
    assert(n == 4 && r.status == MatchStatus.noMatch);

    n = 0;
    auto r2 = md.matches(a, "aaaa"w);
    for (; !r2.empty; r2.popFront())
    {
        ++n;
        md.match(b, "b"w); // another regex: the range is stale
    }
    assert(n == 1 && r2.status == MatchStatus.error);
}

@("an unbound MatchData keeps no reference: the regex may die between calls, and an invalid one is an error")
unittest
{
    bool ok;
    auto md = MatchData.create(ok);
    foreach (i; 0 .. 50) // a regex made and freed again and again, perhaps at the same address
    {
        auto re = mk(`(a)(b)`w, Flags.utf);
        assert(md.match(re, "xab"w) == MatchStatus.match);
        assert(md.group(2) == Capture(2, 3, true));
    }
    Regex none;
    assert(md.match(none, "a"w) == MatchStatus.error && md.errorCode == PCRE2_ERROR_NULL);
    assert(md.matchLossy(none, "a"w) == MatchStatus.error);
    auto r = md.matches(none, "a"w);
    assert(r.empty && r.status == MatchStatus.error);
    auto r2 = md.matchesLossy(none, "a"w);
    assert(r2.empty && r2.status == MatchStatus.error);

    MatchData blank;
    auto a = mk(`a`w, Flags.utf);
    assert(blank.match(a, "a"w) == MatchStatus.error);
    assert(blank.matches(a, "a"w).empty);
}

@("a MatchData made for a regex keeps working with it after being used with others")
unittest
{
    auto a = mk(`(a)`w, Flags.utf);
    auto b = mk(`(b)(b)`w, Flags.utf);
    bool ok;
    auto md = MatchData.createFromPattern(a, ok);
    assert(ok && md.match("xa"w) == MatchStatus.match && md.groupCount == 2);
    assert(md.match(b, "xbb"w) == MatchStatus.match && md.groupCount == 3);
    assert(md.match("xa"w) == MatchStatus.match && md.groupCount == 2 && md.group(1) == Capture(1, 2, true));
}

@("the unbound API allocates nothing on the GC heap")
unittest
{
    import core.memory : GC;

    static void body() @nogc nothrow
    {
        CompileError e;
        auto a = Regex.compile(`a.b`w, Flags.utf, e);
        auto b = Regex.compile(`(x)(y)(z)`w, Flags.utf | Flags.noJit, e);
        assert(a.valid && b.valid);
        bool ok;
        auto md = MatchData.create(ok, 1);
        assert(ok);
        wchar[3] bad = ['a', 0xD800, 'b'];
        foreach (round; 0 .. 3)
        {
            assert(md.match(b, "xyz"w) == MatchStatus.match && md.groupCount == 4);
            assert(md.matchLossy(a, bad[]) == MatchStatus.match);
            size_t n;
            for (auto r = md.matchesLossy(a, bad[]); !r.empty; r.popFront())
                ++n;
            assert(n == 1);
        }
    }

    const before = GC.stats().usedSize;
    body();
    assert(GC.stats().usedSize == before);
}
