// ko_runtime.c — Minimal C runtime stub for AOT linking
//
// All Kō builtins are now generated as LLVM IR by stdlib_codegen.zig.
// This file exists only to provide libc linkage during AOT compilation.
// The only external symbols needed are from libc: printf, malloc, free, etc.

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

// Empty stub — all Kō functions are now LLVM IR.
// This file is compiled by gcc and linked with the object file to provide libc.

// String builtins
int64_t ko_string_contains(const char* haystack, const char* needle) {
    if (!haystack || !needle) return 0;
    return strstr(haystack, needle) != NULL;
}

int64_t ko_string_char_at(const char* str, int64_t index) {
    if (!str || index < 0) return 0;
    int64_t len = strlen(str);
    if (index >= len) return 0;
    return (int64_t)(unsigned char)str[index];
}

const char* ko_string_to_upper(const char* str) {
    if (!str) return str;
    int64_t len = strlen(str);
    char* result = malloc(len + 1);
    if (!result) return str;
    for (int64_t i = 0; i < len; i++) {
        result[i] = toupper((unsigned char)str[i]);
    }
    result[len] = '\0';
    return result;
}

const char* ko_string_to_lower(const char* str) {
    if (!str) return str;
    int64_t len = strlen(str);
    char* result = malloc(len + 1);
    if (!result) return str;
    for (int64_t i = 0; i < len; i++) {
        result[i] = tolower((unsigned char)str[i]);
    }
    result[len] = '\0';
    return result;
}

const char* ko_string_trim(const char* str) {
    if (!str) return str;
    int64_t len = strlen(str);
    int64_t start = 0;
    while (start < len && isspace((unsigned char)str[start])) {
        start++;
    }
    int64_t end = len - 1;
    while (end >= start && isspace((unsigned char)str[end])) {
        end--;
    }
    int64_t new_len = end - start + 1;
    if (new_len <= 0) {
        char* empty = malloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }
    char* result = malloc(new_len + 1);
    if (!result) return str;
    memcpy(result, str + start, new_len);
    result[new_len] = '\0';
    return result;
}

const char* ko_string_replace(const char* str, const char* from, const char* to) {
    if (!str || !from || !to) return str;
    int64_t from_len = strlen(from);
    if (from_len == 0) return str;
    
    // Count occurrences
    int64_t count = 0;
    const char* pos = str;
    while ((pos = strstr(pos, from)) != NULL) {
        count++;
        pos += from_len;
    }
    if (count == 0) return str;
    
    int64_t str_len = strlen(str);
    int64_t to_len = strlen(to);
    int64_t new_len = str_len + count * (to_len - from_len);
    char* result = malloc(new_len + 1);
    if (!result) return str;
    
    char* dst = result;
    const char* src = str;
    const char* match;
    while ((match = strstr(src, from)) != NULL) {
        int64_t segment_len = match - src;
        memcpy(dst, src, segment_len);
        dst += segment_len;
        memcpy(dst, to, to_len);
        dst += to_len;
        src = match + from_len;
    }
    strcpy(dst, src);
    return result;
}
