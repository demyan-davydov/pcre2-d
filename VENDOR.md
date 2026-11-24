# Vendored upstream

- Project: PCRE2, https://github.com/PCRE2Project/pcre2
- Release: pcre2-10.49 (PCRE2_DATE 2026-09-28)
- Source: https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.gz
- SHA-256 of the tarball: `929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae`
  (the release publishes only a GPG `.sig`, no checksum file; gpg was not available when vendoring,
  so the signature was NOT verified, only the hash recorded. Verify with the maintainers' key when updating if you can.)
- Location: `vendor/pcre2/`
  - `src/`: the library sources from the CMake `PCRE2_SOURCES` list (`pcre2_*.c`, no pcre2grep/pcre2test/posix/dftables/fuzz/jit_test),
    the headers they include, `pcre2.h` (= upstream `pcre2.h.generic`, unchanged), `config.h.generic` (unchanged, defaults only),
    `pcre2_chartables.c` (= upstream `pcre2_chartables.c.dist`: default "C" locale tables).
  - `deps/sljit/`: the JIT back end (`pcre2_jit_compile.c` includes `../deps/sljit/sljit_src/sljitLir.c`).
  - `LICENCE.md`, `COPYING`, `AUTHORS.md`, `ChangeLog`.
  - Removed: docs, tests, testdata, autotools/cmake files, tools.
- Our own build config: `config/config.h` (replaces the generated `config.h`: Unicode on, JIT via `-DPCRE2D_JIT`).
- Flags (`scripts/build.sh` / `build.ps1`): `-DHAVE_CONFIG_H -DPCRE2_CODE_UNIT_WIDTH=16 -DPCRE2_STATIC -DNEWLINE_DEFAULT=2 (LF)`,
  `-DPCRE2D_JIT` when JIT is on. Only the 16-bit library is built (`libpcre2d.a` / `pcre2d.lib`).
- To update: download the new release, replace `vendor/pcre2` with the same file set (diff the CMake `PCRE2_SOURCES`
  list against `scripts/build.sh`, which compiles every `src/pcre2_*.c`), update the version/hash above and
  `description` in `dub.sdl`, diff `pcre2.h` against `source/pcre2/c_api.d`, run `dub test`.
