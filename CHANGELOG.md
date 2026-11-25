# Changelog

## 0.1.1 (2026-11-25)

- `Regex.this(this)`, `Regex.~this()` and `MatchData.~this()` are `pure nothrow @nogc`: `pure` code (constructors, `dup`)
  can hold a `Regex` by value, so dependents can drop class wrappers around it. Dependents may raise `~>0.1.0` to `~>0.1.1`.
- New `Regex.id`: process-unique number of a compiled pattern.
- New `Flags.ucp` (PCRE2_UCP) and `Flags.matchInvalidUtf` (PCRE2_MATCH_INVALID_UTF).
- Fix: stepping over an empty match no longer skips a valid character after a lone high surrogate.
- Documented: `matches()` returns an empty range with `status == badUtf` before any element; limits behaviour.

## 0.1.0

- First version: PCRE2 10.49, 16-bit, `@nogc nothrow`.
