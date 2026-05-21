#include "qoz_runtime.h"
#include <stdio.h>
#include <string.h>
#include <inttypes.h>

tgc_t qoz_gc;

void qoz_init(int *stack_anchor) {
    tgc_start(&qoz_gc, stack_anchor);
}

void qoz_shutdown(void) {
    tgc_stop(&qoz_gc);
}

void *qoz_alloc(int64_t size) {
    return tgc_alloc(&qoz_gc, (size_t)size);
}

void *qoz_calloc(int64_t size) {
    void *p = tgc_alloc(&qoz_gc, (size_t)size);
    if (p != NULL) memset(p, 0, (size_t)size);
    return p;
}

void *qoz_realloc(void *ptr, int64_t size) {
    return tgc_realloc(&qoz_gc, ptr, (size_t)size);
}

bool qoz_string_eq(qoz_string a, qoz_string b) {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    return memcmp(a.data, b.data, (size_t)a.len) == 0;
}

uint64_t qoz_string_hash(qoz_string s) {
    /* FNV-1a 64-bit. */
    uint64_t h = 14695981039346656037ULL;
    for (int64_t i = 0; i < s.len; i++) {
        h ^= (uint8_t)s.data[i];
        h *= 1099511628211ULL;
    }
    return h;
}

void qoz_print_str(qoz_string s) {
    fwrite(s.data, 1, (size_t)s.len, stdout);
}

void qoz_print_cstr(const char *s) {
    fputs(s, stdout);
}

void qoz_print_i64(int64_t v) {
    printf("%" PRId64, v);
}

void qoz_print_i32(int32_t v) {
    printf("%" PRId32, v);
}

void qoz_print_f64(double v) {
    printf("%g", v);
}

void qoz_print_bool(bool v) {
    fputs(v ? "true" : "false", stdout);
}

void qoz_print_sep(void) {
    fputc(' ', stdout);
}

void qoz_print_nl(void) {
    fputc('\n', stdout);
}
