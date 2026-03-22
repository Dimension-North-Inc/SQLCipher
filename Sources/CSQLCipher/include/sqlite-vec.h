#ifndef SQLITE_VEC_H
#define SQLITE_VEC_H

// Always use our local sqlite3.h to avoid conflicts with system headers.
// The system sqlite3ext.h may not have the same FTS5 extensions compiled in.
#include "sqlite3.h"

#ifdef SQLITE_VEC_STATIC
  #define SQLITE_VEC_API
#else
  #ifdef _WIN32
    #define SQLITE_VEC_API __declspec(dllexport)
  #else
    #define SQLITE_VEC_API
  #endif
#endif

#define SQLITE_VEC_VERSION "v0.2.0"

#define SQLITE_VEC_DATE "2024-01-01"
#define SQLITE_VEC_SOURCE "static-build"


#define SQLITE_VEC_VERSION_MAJOR 0
#define SQLITE_VEC_VERSION_MINOR 2
#define SQLITE_VEC_VERSION_PATCH 0

#ifdef __cplusplus
extern "C" {
#endif

SQLITE_VEC_API int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg,
                  const sqlite3_api_routines *pApi);

#ifdef __cplusplus
}  /* end of the 'extern "C"' block */
#endif

#endif /* ifndef SQLITE_VEC_H */
