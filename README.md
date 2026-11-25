# pcre2 (pcre2-d)

D binding for [PCRE2](https://github.com/PCRE2Project/pcre2): the **16-bit** library only, so patterns and
subjects are UTF-16 (`wchar`) and all positions are UTF-16 code unit offsets. The whole API is `@nogc nothrow`.
PCRE2 is bundled and compiled on your machine; nothing is downloaded at build time.

- **Bundled engine:** PCRE2 **10.49**, see [VENDOR.md](VENDOR.md)
- **Built with:** Unicode support, newline = LF, JIT where sljit supports the CPU (macOS arm64/x64, Linux, Windows);
  at runtime `Regex` falls back to the interpreter if JIT compilation is unavailable or fails.
- **License:** this binding BSD-3-Clause ([LICENSE](LICENSE)). PCRE2 is BSD-3-Clause (with an exception for
  certain binary redistributions), its JIT (sljit) is BSD-2-Clause; both licence files are in `vendor/pcre2/`.
  Keep them with any binary distribution notices as the licences require.

## Use

```sdl
dependency "pcre2" path="path/to/pcre2-d"
```

```d
import pcre2;

CompileError err;
auto re = Regex.compile(`(?<key>\w+)=(\d+)`w, Flags.utf | Flags.caseless, err);
if (!re.valid) { /* err.code, err.offset (code units in the pattern); errorMessage(err.code, buf) */ }

bool ok;
auto md = MatchData.create(re, ok);          // one per (thread, regex): reuse it
for (auto m = md.matches("a=1 B=22"w); !m.empty; m.popFront())
{
    auto whole = m.front;                    // Capture{begin, end, participated}
    auto value = md.group(2);
}
// MatchStatus: match, noMatch, matchLimit, depthLimit, heapLimit, jitStackLimit, badUtf, error
```

- `Flags`: `caseless dotAll multiline dollarEndOnly utf noUtfCheck noJit ucp matchInvalidUtf`. `Limits{match, depth, heap}` bound the work;
  a catastrophic pattern returns `MatchStatus.matchLimit`, never hangs.
- A group that did not participate has `participated == false`; an empty one has `participated == true`, `begin == end`.
- Semantics (pinned by `tests/semantics.d`): `\d \w \s \b` are ASCII (no UCP); `caseless` uses Unicode simple case folding
  in UTF mode; `.` is any character except `\n`; `$` only at the very end with `dollarEndOnly` (unless `multiline`);
  lookahead, lazy quantifiers, named groups work; a lone surrogate gives `MatchStatus.badUtf` (offset via `badUtfOffset`)
  unless `noUtfCheck` is set (then the caller guarantees valid UTF-16).
- With JIT, matching uses `pcre2_match` (validates UTF, runs JIT code) normally and `pcre2_jit_match` when UTF checking is
  skipped (`noUtfCheck`, and for follow-up matches inside `matches`, which validates only once to stay O(n)).
- `Flags.ucp` makes `\d \w \s \b` Unicode-aware (needs `utf`). `Flags.matchInvalidUtf` (PCRE2_MATCH_INVALID_UTF) matches
  subjects with lone surrogates instead of returning `badUtf`; offsets stay in units of the original subject, and
  matching then always goes through `pcre2_match` (no `pcre2_jit_match`).
- `MatchData.matches` runs the first search inside the call: for an invalid subject the range comes back **empty**
  with `status == MatchStatus.badUtf` before any element; the same holds for limit stops (`status` tells which).
- `Regex.id` is a process-unique number of a compiled pattern (copies share it), usable as a key for a per-thread
  cache of `MatchData`. `Regex`'s postblit and destructor, and `MatchData`'s destructor, are `pure nothrow @nogc`,
  so `pure` code can hold them by value.
- Ownership and threading: [OWNERSHIP.md](OWNERSHIP.md). `Regex` is shared and immutable; `MatchData` is per thread.

## Limits and runaway patterns

`Limits.match` counts backtracking steps in both the interpreter and the JIT (the JIT counts differently, so the same
pattern may stop at slightly different points). `Limits.depth` and `Limits.heap` apply to the interpreter only. When a
limit is hit the match call returns `matchLimit` / `depthLimit` / `heapLimit` (`jitStackLimit` if the JIT stack of
1 MiB runs out) as a `MatchStatus` value, with no exception and no hang; there is no partial result. `(a+)+b` on 5000
`a` ends this way (pinned in `tests/semantics.d`). For `Matches` the status is in `Matches.status` once the range ends.

## Build options (chosen by the dependent at build time)

Environment variables read by `scripts/build.sh` / `build.ps1` (part of the rebuild stamp, so changing one rebuilds):

| Variable | Values | Default |
|---|---|---|
| `PCRE2_JIT` | `auto`, `on`, `off` | `auto` |
| `PCRE2_NEWLINE` | `LF CR CRLF ANY ANYCRLF NUL` | `LF` |
| `PCRE2_MATCH_LIMIT` | number | upstream 10000000 |
| `PCRE2_EXTRA_CFLAGS` | C flags | none |

`CC`, `AR`, `CFLAGS` are honored. DUB configurations: `static` (default), `static-nojit` (no JIT in the library),
`library` (compiles the D binding, for CI), `unittest`. Use `subConfiguration "pcre2" "static-nojit"` to pick one.
After changing options, a dependent may need `dub build --force` to relink.

## Platforms

| Platform | Status |
|---|---|
| macOS arm64 (ldc 1.43, `dub test`, JIT on and `PCRE2_JIT=off`) | verified |
| macOS x86_64, Linux x86_64/arm64, Windows x86_64 (MSVC) | scripts and CI ready, **not verified yet** |

macOS hardened runtime: JIT maps writable+executable memory. A notarized app with the hardened runtime needs the
`com.apple.security.cs.allow-jit` entitlement, otherwise `jit_compile` fails and `Regex` silently uses the interpreter
(`re.jitEnabled == false`), which is slower but correct.

Requirements: DUB, a D compiler (ldc2 tested), a C compiler (`cc`; MSVC on Windows). No CMake.
Tests: `dub test --compiler=ldc2`.
