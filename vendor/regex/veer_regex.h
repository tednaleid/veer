/* ABOUTME: Thin C wrapper around POSIX regex for Zig interop. */
/* ABOUTME: Needed because regex_t is opaque in glibc's @cImport translation. */

#ifndef VEER_REGEX_H
#define VEER_REGEX_H

/* Returns 1 if text matches pattern (POSIX extended regex), 0 otherwise. */
int veer_regex_match(const char *pattern, const char *text);

#endif
