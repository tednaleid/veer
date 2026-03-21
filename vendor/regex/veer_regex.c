/* ABOUTME: Thin C wrapper around POSIX regex for Zig interop. */
/* ABOUTME: Needed because regex_t is opaque in glibc's @cImport translation. */

#include <stddef.h>
#include <regex.h>
#include "veer_regex.h"

int veer_regex_match(const char *pattern, const char *text) {
    regex_t regex;
    if (regcomp(&regex, pattern, REG_EXTENDED | REG_NOSUB) != 0) {
        return 0;
    }
    int result = regexec(&regex, text, 0, NULL, 0) == 0 ? 1 : 0;
    regfree(&regex);
    return result;
}
