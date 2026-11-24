/* dlopen for cffi's ABI mode on WASI, where nothing is loaded at run time:
   the Worker is one module, its native code linked in statically. dlopen
   gives the C library (NULL, "libc.so.6", "libm.so.6", ...), whose
   functions dlsym finds in a table of libc's and libm's common ones;
   any other library fails as a missing one would. cffi calls these for
   dlopen, dlsym, dlclose and dlerror (see recipes/cffi.sh). */
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
  const char *name;
  void *addr;
} sym;

/* Sorted by name, for bsearch. */
static const sym libc_syms[] = {
  {"abs", (void *)&abs},
  {"acos", (void *)&acos},
  {"acosh", (void *)&acosh},
  {"asin", (void *)&asin},
  {"asinh", (void *)&asinh},
  {"atan", (void *)&atan},
  {"atan2", (void *)&atan2},
  {"atanh", (void *)&atanh},
  {"atof", (void *)&atof},
  {"atoi", (void *)&atoi},
  {"atol", (void *)&atol},
  {"atoll", (void *)&atoll},
  {"bsearch", (void *)&bsearch},
  {"calloc", (void *)&calloc},
  {"cbrt", (void *)&cbrt},
  {"ceil", (void *)&ceil},
  {"ceilf", (void *)&ceilf},
  {"copysign", (void *)&copysign},
  {"cos", (void *)&cos},
  {"cosf", (void *)&cosf},
  {"cosh", (void *)&cosh},
  {"erf", (void *)&erf},
  {"erfc", (void *)&erfc},
  {"exp", (void *)&exp},
  {"exp2", (void *)&exp2},
  {"expf", (void *)&expf},
  {"expm1", (void *)&expm1},
  {"fabs", (void *)&fabs},
  {"fabsf", (void *)&fabsf},
  {"floor", (void *)&floor},
  {"floorf", (void *)&floorf},
  {"fmax", (void *)&fmax},
  {"fmin", (void *)&fmin},
  {"fmod", (void *)&fmod},
  {"free", (void *)&free},
  {"getenv", (void *)&getenv},
  {"hypot", (void *)&hypot},
  {"isalnum", (void *)&isalnum},
  {"isalpha", (void *)&isalpha},
  {"isdigit", (void *)&isdigit},
  {"islower", (void *)&islower},
  {"isspace", (void *)&isspace},
  {"isupper", (void *)&isupper},
  {"labs", (void *)&labs},
  {"lgamma", (void *)&lgamma},
  {"llabs", (void *)&llabs},
  {"log", (void *)&log},
  {"log10", (void *)&log10},
  {"log1p", (void *)&log1p},
  {"log2", (void *)&log2},
  {"logf", (void *)&logf},
  {"malloc", (void *)&malloc},
  {"memchr", (void *)&memchr},
  {"memcmp", (void *)&memcmp},
  {"memcpy", (void *)&memcpy},
  {"memmove", (void *)&memmove},
  {"memset", (void *)&memset},
  {"pow", (void *)&pow},
  {"powf", (void *)&powf},
  {"printf", (void *)&printf},
  {"puts", (void *)&puts},
  {"qsort", (void *)&qsort},
  {"rand", (void *)&rand},
  {"realloc", (void *)&realloc},
  {"round", (void *)&round},
  {"roundf", (void *)&roundf},
  {"sin", (void *)&sin},
  {"sinf", (void *)&sinf},
  {"sinh", (void *)&sinh},
  {"snprintf", (void *)&snprintf},
  {"sprintf", (void *)&sprintf},
  {"sqrt", (void *)&sqrt},
  {"sqrtf", (void *)&sqrtf},
  {"srand", (void *)&srand},
  {"strcasecmp", (void *)&strcasecmp},
  {"strcat", (void *)&strcat},
  {"strchr", (void *)&strchr},
  {"strcmp", (void *)&strcmp},
  {"strcpy", (void *)&strcpy},
  {"strdup", (void *)&strdup},
  {"strerror", (void *)&strerror},
  {"strlen", (void *)&strlen},
  {"strncasecmp", (void *)&strncasecmp},
  {"strncat", (void *)&strncat},
  {"strncmp", (void *)&strncmp},
  {"strncpy", (void *)&strncpy},
  {"strndup", (void *)&strndup},
  {"strnlen", (void *)&strnlen},
  {"strrchr", (void *)&strrchr},
  {"strstr", (void *)&strstr},
  {"strtod", (void *)&strtod},
  {"strtof", (void *)&strtof},
  {"strtok", (void *)&strtok},
  {"strtol", (void *)&strtol},
  {"strtoll", (void *)&strtoll},
  {"strtoul", (void *)&strtoul},
  {"strtoull", (void *)&strtoull},
  {"tan", (void *)&tan},
  {"tanf", (void *)&tanf},
  {"tanh", (void *)&tanh},
  {"tgamma", (void *)&tgamma},
  {"time", (void *)&time},
  {"tolower", (void *)&tolower},
  {"toupper", (void *)&toupper},
  {"trunc", (void *)&trunc},
};

static const char *const libc_names[] = {"libc.so", "libc.so.6", "libm.so", "libm.so.6", "c", "m"};
static char err[512];
static int has_err;

static void set_err(const char *a, const char *b) {
  snprintf(err, sizeof err, "%s%s", a, b);
  has_err = 1;
}

void *ffi_wasi_dlopen(const char *file, int flags) {
  (void)flags;
  if (!file) return (void *)libc_syms;
  for (size_t i = 0; i < sizeof libc_names / sizeof *libc_names; i++)
    if (!strcmp(file, libc_names[i])) return (void *)libc_syms;
  set_err(file, ": cannot open shared object file: a WASI Worker loads no libraries at run "
                "time; link native code into the Worker as a package (packages/README.md)");
  return NULL;
}

static int by_name(const void *k, const void *e) { return strcmp(k, ((const sym *)e)->name); }

void *ffi_wasi_dlsym(void *handle, const char *name) {
  const sym *s = handle == libc_syms
                     ? bsearch(name, libc_syms, sizeof libc_syms / sizeof *libc_syms, sizeof *s, by_name)
                     : NULL;
  if (s) return s->addr;
  set_err("undefined symbol: ", name);
  return NULL;
}

int ffi_wasi_dlclose(void *handle) { return handle == libc_syms ? 0 : (set_err("invalid handle", ""), 1); }

char *ffi_wasi_dlerror(void) {
  if (!has_err) return NULL;
  has_err = 0;
  return err;
}
