#pragma once

#include <stdio.h>

void phdr_cache_clear_filters(void);
void phdr_cache_omit_main(int enabled);
void phdr_cache_omit_substring(const char *needle);
int phdr_cache_update(void);
int phdr_cache_poison_substring(const char *needle);
void phdr_cache_dump(FILE *out);
