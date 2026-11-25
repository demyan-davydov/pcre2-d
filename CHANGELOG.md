# Changelog

## 0.1.3 (unreleased)

- `MatchData` that is not tied to a `Regex`: `MatchData.create(ok)` / `create(ovectorGroups, ok)` (`ok` last, as in the other `create`s), then
  `match(re, text)`, `matches(re, text)`, `matchLossy(re, text)`, `matchesLossy(re, text)`. One per thread is enough for any
  number of regexes: the limits of `re` are applied per call, the ovector grows when `re` has more groups, the JIT stack
  is made at the first JIT pattern. A range ends with `error` if another regex is used meanwhile. The old calls
  (`createFromPattern`, `match(text)`, ...) are unchanged. `MatchData.valid` now means "has storage".

## 0.1.2 (2026-11-25)

- `matchLossy` / `matchesLossy`: a text without any surrogate unit is matched without the UTF check (through
  `pcre2_jit_match` for a JIT-compiled pattern). Results are the same; short valid texts match much faster.
  The text is scanned for surrogates only from where PCRE2 can read it (`start` minus the longest look-behind).
  So a lone surrogate lying before that part of the text is neither seen nor repaired: PCRE2 does not read it either,
  and the result does not change.

Known issues (open):

- Nothing in the tests shows that the fast path of `matchLossy` / `matchesLossy` is really taken: the tests compare
  answers only, so a change that validates every text again would pass them and lose the speed-up silently.
  Deferred: it needs a hook in the library for the unittest build or a benchmark kept outside the test run.

## 0.1.1 (2026-11-25)

- `Regex.this(this)`, `Regex.~this()` and `MatchData.~this()` are `pure nothrow @nogc`: `pure` code (constructors, `dup`)
  can hold a `Regex` by value, so dependents can drop class wrappers around it. Dependents that rely on this should require `~>0.1.1`: `~>0.1.0` also accepts 0.1.0, which has no `pure`.
- Names follow the C functions: `match` (was `search`), `getErrorMessage`, `getStartchar`, `substringNumberFromName`,
  `createFromPattern`, `config(ConfigWhat)`; the old names stay as aliases.
- New `MatchData.matchLossy` and `matchesLossy`: lone surrogates are read as U+FFFD, offsets stay those of the subject.
- New `MatchStatus.badOffset` (start past the end or inside a surrogate pair; both used to come back as `error`, and with
  `noUtfCheck` the pair case went unchecked); invalid `Regex`/`MatchData` return error values
  instead of dereferencing null; a `matchesLossy` range ends with `error` if its buffer was rewritten.
- `build.sh` copes with spaces in the path and rebuilds when sljit sources change; the C types are no longer re-exported
  from `import pcre2;`.
- New `Regex.id`: process-unique number of a compiled pattern.
- New `Flags.ucp` (PCRE2_UCP) and `Flags.matchInvalidUtf` (PCRE2_MATCH_INVALID_UTF).
- Fix: stepping over an empty match no longer skips a valid character after a lone high surrogate.
- Documented: `matches()` returns an empty range with `status == badUtf` before any element; limits behaviour.

## 0.1.0

- First version: PCRE2 10.49, 16-bit, `@nogc nothrow`.
