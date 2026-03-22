//
//  vec_init.c
//  CSQLCipher
//
//  Static initialization for sqlite-vec extension.
//

#include "sqlite-vec.h"

/*
** The关键的来了: we need to call sqlite3_auto_extension() to register
** the vec0 virtual table and its SQL functions. We use a constructor
** attribute so this runs automatically when the library is loaded.
**
** Note: We don't link against vec0 directly - we just tell SQLite
** where to find the entry point. The entry point is sqlite3_vec_init.
*/
int register_vec_extension(void) {
    return sqlite3_auto_extension((void (*)(void))sqlite3_vec_init);
}

/* Constructor - runs when library is loaded into the process */
__attribute__((constructor))
static void vec_library_init(void) {
    register_vec_extension();
}
