#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ============================================================
// Reference counting
// ============================================================
// Every heap-allocated Kō object has an i64 RC header before the data.
// Memory layout: [ i64 rc ][ ... user data ... ]
// The pointer passed around in Kō code points to the user data (after the header).

#define RC_OFFSET 8

// Allocate a heap object with RC header. Returns pointer to user data area.
// user_size = size of the user data (excluding the RC header).
void *ko_alloc(int64_t user_size) {
    void *raw = malloc(RC_OFFSET + user_size);
    if (!raw) {
        fprintf(stderr, "ko: out of memory\n");
        exit(1);
    }
    int64_t *rc_ptr = (int64_t *)raw;
    *rc_ptr = 1; // initial refcount = 1
    return (char *)raw + RC_OFFSET;
}

// Increment reference count.
void *ko_incref(void *ptr) {
    if (!ptr) return ptr;
    int64_t *rc_ptr = (int64_t *)((char *)ptr - RC_OFFSET);
    (*rc_ptr)++;
    return ptr;
}

// Decrement reference count. Free if it reaches 0.
void ko_decref(void *ptr) {
    if (!ptr) return;
    int64_t *rc_ptr = (int64_t *)((char *)ptr - RC_OFFSET);
    (*rc_ptr)--;
    if (*rc_ptr <= 0) {
        free(rc_ptr);
    }
}

// Get current reference count (for debugging).
int64_t ko_get_rc(void *ptr) {
    if (!ptr) return 0;
    int64_t *rc_ptr = (int64_t *)((char *)ptr - RC_OFFSET);
    return *rc_ptr;
}

int64_t println(int64_t val) {
    printf("%ld\n", val);
    return 0;
}

int64_t print(int64_t val) {
    printf("%ld", val);
    return 0;
}

// Type tags for inspect:
// 0=int, 1=float, 2=bool, 3=char, 4=string, 5=unit,
// 6=constructor, 7=record, 8=function, 9=tuple, 100=unknown
int64_t inspect(int64_t val, int64_t type_tag, const char *name_ptr) {
    switch (type_tag) {
        case 0: printf("%ld", val); break;
        case 1: {
            double f;
            memcpy(&f, &val, sizeof(double));
            printf("%f", f);
            break;
        }
        case 2: printf("%s", val == 0 ? "False" : "True"); break;
        case 3: printf("'%c'", (char)val); break;
        case 4: printf("\"%s\"", (const char *)(intptr_t)val); break;
        case 5: printf("()"); break;
        case 6:
            if (name_ptr) printf("%s", name_ptr);
            else printf("Constructor(%ld)", val);
            break;
        case 7:
            if (name_ptr) printf("%s { ... }", name_ptr);
            else printf("Record(%ld)", val);
            break;
        case 8: printf("<fn>"); break;
        case 9: printf("(%ld)", val); break;
        default: printf("%ld", val); break;
    }
    return val;
}
