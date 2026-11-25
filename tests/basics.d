/// A table of everyday regular expressions that must work: one case per construct. Each case runs with the JIT
/// and with the interpreter, and both must agree.
module basics;

import pcre2;

private struct Case
{
    wstring pattern;
    wstring subject;
    long begin; // of the first match, or -1: no match
    long end;
    Flags flags = Flags.utf;
}

private enum none = -1;

private immutable Case[] matchCases = [
    // literals, alternation, classes
    Case(`abc`, "xxabcxx", 2, 5),
    Case(`cat|dog`, "hotdog", 3, 6),
    Case(`[a-c]+`, "xxabcabd", 2, 7),
    Case(`[^a-c]+`, "abxyzc", 2, 5),
    Case(`[[:alpha:]]+`, "12ab3", 2, 4),
    Case(`\s+`, "a \t b", 1, 4),
    Case(`\bfoo\b`, "a foo b", 2, 5),
    Case(`\bfoo\b`, "afoo b", none, none),
    // quantifiers
    Case(`a{2,3}`, "caaaa", 1, 4),
    Case(`a{2}`, "aaa", 0, 2),
    Case(`a{2,}`, "baaaa", 1, 5),
    Case(`colou?r`, "color", 0, 5),
    Case(`a.*?b`, "xaabab", 1, 4),
    Case(`a.*b`, "xaabab", 1, 6),
    Case(`a++a`, "aaa", none, none),
    Case(`(?>a+)a`, "aaa", none, none),
    Case(`(?:ab)+`, "xababab", 1, 7),
    Case(`(a|ab)(c|bcd)(d*)`, "abcd", 0, 4),
    // anchors
    Case(`^`, "", 0, 0),
    Case(`^$`, "", 0, 0),
    Case(``, "abc", 0, 0),
    Case(`.*`, "", 0, 0),
    Case(`\Aa`, "ab", 0, 1),
    Case(`b\z`, "ab\n", none, none),
    Case(`b\Z`, "ab\n", 1, 2),
    Case(`(?m)^b`, "a\nb", 2, 3),
    Case(`^b`, "a\nb", none, none),
    Case(`\R`, "a\r\nb", 1, 3),
    // references, lookaround, groups
    Case(`(\w)\1`, "abccd", 2, 4),
    Case(`(?<x>\w)\k<x>`, "abccd", 2, 4),
    Case(`(?<=\$)\d+`, "cost $42", 6, 8),
    Case(`(?<!\$)\b\d+`, "$4 5", 3, 4),
    Case(`foo(?=bar)`, "foobaz foobar", 7, 10),
    Case(`(a)?(?(1)b|c)`, "c", 0, 1),
    Case(`(a)?(?(1)b|c)`, "ab", 0, 2),
    Case(`\((?:[^()]|(?R))*\)`, "x(a(b)c)y", 1, 8),
    // inline flags and quoting
    Case(`(?i)abc`, "xABC", 1, 4),
    Case(`a(?i)b`, "aB", 0, 2),
    Case(`a(?i)b`, "AB", none, none),
    Case(`\Q.*\E`, "a.*b", 1, 3),
    Case(`(?s)a.b`, "a\nb", 0, 3),
    Case(`a.b`, "a\nb", none, none),
    // Unicode
    Case(`\p{L}+`, "12жук34", 2, 5),
    Case(`\p{Lu}`, "abЖ", 2, 3),
    Case(`\x{41}`, "zA", 1, 2),
    Case(`\x{1F600}`, "a😀", 1, 3),
    Case(`😀+`, "a😀😀b", 1, 5),
    Case(`ÉCOLE`, "école", 0, 5, Flags.utf | Flags.caseless),
    Case(`ÉCOLE`, "école", none, none),
    Case(`\w+`, "жук abc", 4, 7, Flags.utf),
    Case(`\w+`, "жук abc", 0, 3, Flags.utf | Flags.ucp),
    // things that appear in logs
    Case(`\d{3}-\d{4}`, "call 555-1234 now", 5, 13),
    Case(`[\w.]+@[\w.]+\.\w+`, "mail a.b@c.org!", 5, 14),
    Case(`(\d+)\s*(ms|s)`, "took 250 ms", 5, 11),
    Case(`\[(?:ERROR|WARN)\]`, "x [WARN] y", 2, 8),
    Case(`error: .*$`, "a error: boom", 2, 13),
];

private long[2] firstMatch(wstring pattern, wstring subject, Flags flags)
{
    long[2] res = [-2, -2];
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        CompileError e;
        auto re = Regex.compile(pattern, flags | jitOff, e);
        assert(re.valid, "does not compile");
        bool ok;
        auto md = MatchData.createFromPattern(re, ok);
        assert(ok);
        long[2] cur = [-1, -1];
        const st = md.match(subject);
        assert(st == MatchStatus.match || st == MatchStatus.noMatch);
        if (st == MatchStatus.match)
            cur = [cast(long) md.group(0).begin, cast(long) md.group(0).end];
        assert(res[0] == -2 || res == cur, "JIT and interpreter disagree");
        res = cur;
    }
    return res;
}

unittest // the table of everyday expressions
{
    foreach (ref c; matchCases)
    {
        const got = firstMatch(c.pattern, c.subject, c.flags);
        if (got != [c.begin, c.end])
        {
            import std.stdio : stderr;

            stderr.writefln("case failed: /%s/ on \"%s\": got %s, want [%s, %s]", c.pattern, c.subject, got, c.begin, c.end);
        }
        assert(got == [c.begin, c.end]);
    }
}

unittest // groups of everyday expressions
{
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        CompileError e;
        auto re = Regex.compile(`(\d+)-(\d+)`w, Flags.utf | jitOff, e);
        bool ok;
        auto md = MatchData.createFromPattern(re, ok);
        assert(md.match("a 10-20"w) == MatchStatus.match);
        assert(md.group(0) == Capture(2, 7, true));
        assert(md.group(1) == Capture(2, 4, true));
        assert(md.group(2) == Capture(5, 7, true));
        assert(md.groupCount == 3);

        auto named = Regex.compile(`(?<k>\w+)=(?<v>\w*)`w, Flags.utf | jitOff, e);
        auto md2 = MatchData.createFromPattern(named, ok);
        assert(md2.match("x a=b"w) == MatchStatus.match);
        assert(md2.group(named, "k"w) == Capture(2, 3, true));
        assert(md2.group(named, "v"w) == Capture(4, 5, true));
        assert(md2.match("k="w) == MatchStatus.match);
        assert(md2.group(named, "v"w) == Capture(2, 2, true), "an empty group took part");

        auto alt = Regex.compile(`(a)|(b)`w, Flags.utf | jitOff, e);
        auto md3 = MatchData.createFromPattern(alt, ok);
        assert(md3.match("b"w) == MatchStatus.match);
        assert(!md3.group(1).participated && md3.group(2) == Capture(0, 1, true));
    }
}

unittest // every match of an everyday expression, in order
{
    foreach (jitOff; [Flags.none, Flags.noJit])
    {
        CompileError e;
        auto re = Regex.compile(`\b\w+\b`w, Flags.utf | jitOff, e);
        bool ok;
        auto md = MatchData.createFromPattern(re, ok);
        size_t[2][] all;
        for (auto r = md.matches("one, two;three"w); !r.empty; r.popFront())
            all ~= [r.front.begin, r.front.end];
        assert(all == [[0, 3], [5, 8], [9, 14]]);
    }
}

unittest // patterns that must be rejected at compile time
{
    foreach (bad; [`(`w, `)`w, `[a`w, `*a`w, `a{2,1}`w, `(?<n>a)(?<n>b)`w, `\`w, `(?z)`w, `(?<=a+)b`w, `\p{Nope}`w, `\k<nope>`w])
    {
        CompileError e;
        auto re = Regex.compile(bad, Flags.utf, e);
        assert(!re.valid, "should not compile");
        assert(e.code != 0);
    }
}
