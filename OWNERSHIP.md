# Ownership and threading rules

| Type | Owns | Copy | Destroy |
|---|---|---|---|
| `Regex` | compiled `pcre2_code` (+ JIT code) in a malloc'd block | atomic refcount++ | refcount--, free at 0 |
| `MatchData` | `pcre2_match_data`, match context, JIT stack, a malloc'd repair buffer for `matchLossy`/`matchesLossy`; one reference on its `Regex` only if made by `createFromPattern` (an unbound one, from `create`, keeps none) | not copyable | frees scratch, refcount-- |
| `Matches` (range) | nothing; points to a `MatchData` (and, from `matchesLossy`, into its repair buffer) | plain copy | nothing |

- Nothing uses the GC: all of the API is `@nogc nothrow`. Compile errors and match failures are values
  (`CompileError`, `MatchStatus`); inputs are `const(wchar)[]` borrowed for the call; outputs are offsets
  (`Capture`) into the caller's subject, or slices of caller buffers (`errorMessage`). The one exception to
  "slice of a caller buffer": `Regex.namedGroup` returns a slice of the compiled pattern's name table
  (valid while any copy of that `Regex` lives).
- `Regex` is immutable after `compile` and may be copied to and matched from any number of threads.
- `MatchData` is single-threaded: one per (thread, regex). Matching takes no lock and does not allocate on the GC heap
  (PCRE2 itself may malloc for large backtracking in the interpreter, bounded by `Limits.heap`).
- `Matches` and the `MatchData` it points to must not outlive each other's use; the subject slice must stay alive
  and unchanged during iteration.
- `Regex.id` is a process-unique number given at `compile`; copies share it.
- The repair buffer of a `MatchData` is rewritten by every `matchLossy` / `matchesLossy` call on it. A range made by
  `matchesLossy` notices this and ends with `MatchStatus.error` instead of reading the rewritten (or freed) buffer;
  it is freed with the `MatchData`.
- `Regex`'s postblit and destructor, and `MatchData`'s destructor, are `pure` by an explicit cast of the (impure) refcount
  and free functions: sharing a compiled, immutable `Regex` is not observable through the type system.
