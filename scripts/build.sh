#!/usr/bin/env sh
# Builds the vendored PCRE2 (16-bit library only) into build/lib/libpcre2d.a.
# Usage: build.sh [static] [nojit]
# Honors CC, AR, CFLAGS and the build options below (all part of the rebuild stamp):
#   PCRE2_JIT=auto|on|off   JIT compiler (auto: on for x86_64/arm64 and other sljit CPUs we know)
#   PCRE2_NEWLINE=LF|CR|CRLF|ANY|ANYCRLF|NUL   default newline convention (default LF)
#   PCRE2_MATCH_LIMIT=N     compiled-in default match limit (default upstream 10000000)
#   PCRE2_EXTRA_CFLAGS=...  extra C compiler flags
set -eu

MODE="${1:-static}"
[ "${2:-}" = nojit ] && PCRE2_JIT=off
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/pcre2/src"
OUT="$ROOT/build/lib"
OBJ="$ROOT/build/obj-$MODE"
CC="${CC:-cc}"
AR="${AR:-ar}"

[ "$MODE" = static ] || { echo "usage: $0 [static] [nojit]" >&2; exit 2; }

JIT="${PCRE2_JIT:-auto}"
if [ "$JIT" = auto ]; then
  case "$(uname -m)" in
    x86_64|amd64|arm64|aarch64|i?86|ppc64*|riscv64|s390x|loongarch64) JIT=on ;;
    *) JIT=off ;;
  esac
fi
case "$JIT" in on|off) ;; *) echo "PCRE2_JIT must be auto|on|off" >&2; exit 2 ;; esac

case "${PCRE2_NEWLINE:-LF}" in
  CR) NL=1 ;; LF) NL=2 ;; CRLF) NL=3 ;; ANY) NL=4 ;; ANYCRLF) NL=5 ;; NUL) NL=6 ;;
  *) echo "PCRE2_NEWLINE must be LF|CR|CRLF|ANY|ANYCRLF|NUL" >&2; exit 2 ;;
esac

DEFS="-DHAVE_CONFIG_H -DPCRE2_CODE_UNIT_WIDTH=16 -DPCRE2_STATIC -DNEWLINE_DEFAULT=$NL"
[ "$JIT" = on ] && DEFS="$DEFS -DPCRE2D_JIT"
[ -n "${PCRE2_MATCH_LIMIT:-}" ] && DEFS="$DEFS -DMATCH_LIMIT=$PCRE2_MATCH_LIMIT"
ALL_CFLAGS="-std=gnu11 -O2 -fPIC -fvisibility=hidden -Wno-unused-parameter $DEFS ${PCRE2_EXTRA_CFLAGS:-} ${CFLAGS:-}"
TARGET="$OUT/libpcre2d.a"

SOURCES=$(ls "$SRC"/pcre2_*.c)
HEADERS="$SRC/*.h $ROOT/config/config.h"
STAMP="$OBJ/flags.stamp"
mkdir -p "$OUT" "$OBJ"

NEW_STAMP="$("$CC" --version 2>&1 | head -n 1) | $ALL_CFLAGS | $AR"
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$NEW_STAMP" ]; then
  rm -f "$OBJ"/*.o "$TARGET"
  printf '%s' "$NEW_STAMP" > "$STAMP"
fi

NEED_LINK=0
[ -f "$TARGET" ] || NEED_LINK=1
for s in $SOURCES; do
  o="$OBJ/$(basename "$s" .c).o"
  rebuild=0
  [ -f "$o" ] || rebuild=1
  if [ $rebuild = 0 ]; then
    [ "$s" -nt "$o" ] && rebuild=1
    for h in $HEADERS; do [ "$h" -nt "$o" ] && rebuild=1; done
  fi
  if [ $rebuild = 1 ]; then
    echo "CC  $(basename "$s")"
    # shellcheck disable=SC2086
    "$CC" $ALL_CFLAGS -I"$ROOT/config" -I"$SRC" -c "$s" -o "$o"
    NEED_LINK=1
  fi
done

if [ $NEED_LINK = 1 ]; then
  rm -f "$TARGET"
  echo "AR  libpcre2d.a (JIT=$JIT newline=${PCRE2_NEWLINE:-LF})"
  "$AR" rcs "$TARGET" "$OBJ"/*.o
fi
