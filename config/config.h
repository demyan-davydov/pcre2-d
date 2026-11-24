/* Build configuration for the vendored PCRE2 (16-bit library only). Used instead of the
 * upstream generated config.h; defaults for everything not set here come from the pristine
 * vendor/pcre2/src/config.h.generic. Tunables are passed by scripts/build.* as -D flags
 * (see README "Build options"). */
#ifndef PCRE2D_CONFIG_H
#define PCRE2D_CONFIG_H

#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_MEMMOVE 1
#define HAVE_STRERROR 1
#define SUPPORT_UNICODE 1
#ifdef PCRE2D_JIT
#define SUPPORT_JIT 1
#endif

#include "../vendor/pcre2/src/config.h.generic"
#endif
