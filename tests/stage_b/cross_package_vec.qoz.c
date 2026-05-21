#include "qoz_runtime.h"

typedef struct qoz_Vec__int64_t qoz_Vec__int64_t;


struct qoz_Vec__int64_t {
    int64_t* data;
    int64_t len;
    int64_t cap;
};

extern void* qoz_alloc(int64_t);
extern void* qoz_calloc(int64_t);
extern void* qoz_realloc(void*, int64_t);
qoz_Vec__int64_t qoz_vec_make__int64_t();
void qoz_vec_push__int64_t(qoz_Vec__int64_t* v, int64_t x);
void qoz_vec_grow__int64_t(qoz_Vec__int64_t* v);

int main(int argc, char **argv) {
    qoz_set_argv(argc, argv);
    int qoz_stack_anchor;
    qoz_init(&qoz_stack_anchor);
    qoz_Vec__int64_t v = qoz_vec_make__int64_t(); qoz_vec_push__int64_t(&v, 1); qoz_vec_push__int64_t(&v, 2); qoz_vec_push__int64_t(&v, 3); int64_t qoz_main_result = ((v.data[0] + v.data[1]) + v.data[2]);
    qoz_shutdown();
    return (int)qoz_main_result;
}
qoz_Vec__int64_t qoz_vec_make__int64_t() {
    return ((qoz_Vec__int64_t){ .data = NULL, .len = 0, .cap = 0 });
}

void qoz_vec_push__int64_t(qoz_Vec__int64_t* v, int64_t x) {
    if (v->len == v->cap) { qoz_vec_grow__int64_t(v); } v->data[v->len] = x; return v->len = (v->len + 1);
}

void qoz_vec_grow__int64_t(qoz_Vec__int64_t* v) {
    int64_t new_cap = ((v->cap == 0) ? ({ 8; }) : ({ (v->cap * 2); })); int64_t new_data = mem_realloc(v->data, (new_cap * (int64_t)sizeof(int64_t))); v->data = new_data; return v->cap = new_cap;
}

