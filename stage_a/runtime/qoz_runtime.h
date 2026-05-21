#ifndef QOZ_RUNTIME_H
#define QOZ_RUNTIME_H

#include <stdint.h>
#include <stdbool.h>
#include "tgc.h"

extern tgc_t qoz_gc;

typedef struct {
    const char *data;
    int64_t len;
} qoz_string;

void qoz_init(int *stack_anchor);
void qoz_shutdown(void);

/* Allocation */
void *qoz_alloc(int64_t size);
void *qoz_calloc(int64_t size);
void *qoz_realloc(void *ptr, int64_t size);

/* String helpers */
bool     qoz_string_eq(qoz_string a, qoz_string b);
uint64_t qoz_string_hash(qoz_string s);

/* Print primitives. The generated code emits a sequence of these per
 * `fmt.println(args...)` call: one print per argument, separators in between,
 * and a newline at the end.
 */
void qoz_print_str(qoz_string s);
void qoz_print_cstr(const char *s);
void qoz_print_i64(int64_t v);
void qoz_print_i32(int32_t v);
void qoz_print_f64(double v);
void qoz_print_bool(bool v);
void qoz_print_sep(void);
void qoz_print_nl(void);

#define QOZ_STR_LIT(s) ((qoz_string){ (s), (int64_t)(sizeof(s) - 1) })

#endif
