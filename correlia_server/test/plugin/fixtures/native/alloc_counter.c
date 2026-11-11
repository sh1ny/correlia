#include <openssl/crypto.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>

static _Atomic uint64_t live_allocations;

static void *counted_malloc(size_t size, const char *file, int line) {
  (void)file;
  (void)line;
  void *result = malloc(size);
  if (result != NULL) atomic_fetch_add(&live_allocations, 1);
  return result;
}

static void counted_free(void *pointer, const char *file, int line) {
  (void)file;
  (void)line;
  if (pointer == NULL) return;
  atomic_fetch_sub(&live_allocations, 1);
  free(pointer);
}

static void *counted_realloc(void *pointer, size_t size, const char *file, int line) {
  if (pointer == NULL) return counted_malloc(size, file, line);
  if (size == 0) {
    counted_free(pointer, file, line);
    return NULL;
  }
  return realloc(pointer, size);
}

int probe_install_allocation_hooks(void) {
  return CRYPTO_set_mem_functions(counted_malloc, counted_realloc, counted_free);
}

uint64_t probe_live_allocations(void) {
  return atomic_load(&live_allocations);
}
