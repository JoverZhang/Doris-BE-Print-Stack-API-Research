#define UNW_LOCAL_ONLY
#include <libunwind.h>

int unw_backtrace(void **buffer, int size) {
  unw_context_t context;
  unw_cursor_t cursor;
  unw_word_t ip;
  int n = 0;

  if (size <= 0 || unw_getcontext(&context) < 0 ||
      unw_init_local(&cursor, &context) < 0) {
    return 0;
  }
  while (n < size && unw_step(&cursor) > 0) {
    if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0) {
      break;
    }
    buffer[n++] = (void *)ip;
  }
  return n;
}
