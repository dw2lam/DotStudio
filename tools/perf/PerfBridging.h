// The app's bridging header plus the perf harness's counters (hooks.c).
#include "../../Shared/Bridging.h"
#include <stdint.h>
int perf_hooks_install(void);
uint64_t perf_allocs_total(void);
uint64_t perf_allocs_thread(void);
void perf_hooks_watch(const char *prefix);
uint64_t perf_fs_stats(void);
uint64_t perf_fs_opens(void);
uint64_t perf_fs_reads(void);
uint64_t perf_fs_read_bytes(void);
void perf_trace_begin(void);
int perf_trace_end(void);
int perf_trace_depth(int i);
void *perf_trace_frame(int i, int k);
void perf_trace_begin_resume(void);
void perf_trace_pause(void);
