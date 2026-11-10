// tools/perf/hooks.c — counters for the perf harness, built as a dylib the harness links
// (dyld honours __interpose only in dylibs).
//   • allocations: libmalloc's malloc_logger hook — every malloc/calloc/realloc/zone alloc,
//     counted process-wide and on the main thread (where the harness makes its frame calls, so a
//     frame's own allocations can be told apart from Metal's and Core Animation's threads; not
//     thread-local storage — a dylib's TLV is allocated with malloc on first use, which recurses).
//   • file system: stat/lstat/fstatat/getattrlist/open/openat/access whose path starts with
//     one of the watched prefixes (perf_hooks_watch: the temp store, the fixtures), and
//     read/pread on descriptors opened from them.
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/types.h>
#include <pthread.h>
#include <execinfo.h>

typedef void (*malloc_logger_t)(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3,
                                uintptr_t result, uint32_t skip);
static _Atomic uint64_t g_allocs;
static _Atomic uint64_t t_allocs;
static pthread_t g_main;

// Optional stack capture of main-thread allocations (perf_trace_begin/end): return addresses only
// (backtrace() doesn't allocate), symbolized afterwards by the harness.
#define TRACE_DEPTH 14
#define TRACE_MAX 200000
static void *g_trace[TRACE_MAX][TRACE_DEPTH];
static int g_traceDepth[TRACE_MAX];
static _Atomic int g_traceN;
static volatile int g_tracing;

static void perf_logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3,
                        uintptr_t result, uint32_t skip) {
    // MALLOC_LOG_TYPE_ALLOCATE = 2 (a realloc logs allocate|deallocate: one new block)
    if (type & 2) {
        atomic_fetch_add_explicit(&g_allocs, 1, memory_order_relaxed);
        if (pthread_self() == g_main) {
            atomic_fetch_add_explicit(&t_allocs, 1, memory_order_relaxed);
            if (g_tracing) {
                int i = atomic_fetch_add(&g_traceN, 1);
                if (i < TRACE_MAX) g_traceDepth[i] = backtrace(g_trace[i], TRACE_DEPTH);
            }
        }
    }
}

int perf_hooks_install(void) {
    malloc_logger_t *slot = (malloc_logger_t *)dlsym(RTLD_DEFAULT, "malloc_logger");
    if (!slot) return 0;
    g_main = pthread_self();
    *slot = perf_logger;
    return 1;
}
uint64_t perf_allocs_total(void) { return atomic_load_explicit(&g_allocs, memory_order_relaxed); }
uint64_t perf_allocs_thread(void) { return atomic_load_explicit(&t_allocs, memory_order_relaxed); }   // main thread

void perf_trace_begin(void) { atomic_store(&g_traceN, 0); g_tracing = 0; }
void perf_trace_begin_resume(void) { g_tracing = 1; }
void perf_trace_pause(void) { g_tracing = 0; }
int perf_trace_end(void) { g_tracing = 0; int n = atomic_load(&g_traceN); return n < TRACE_MAX ? n : TRACE_MAX; }
int perf_trace_depth(int i) { return g_traceDepth[i]; }
void *perf_trace_frame(int i, int k) { return g_trace[i][k]; }

// ---- file system ----
#define MAXW 4
static char g_watch[MAXW][1024];
static int g_nwatch;
static _Atomic uint64_t g_stats, g_opens, g_reads, g_readBytes;
static _Atomic int g_watchedFD[4096];

void perf_hooks_watch(const char *prefix) {
    if (g_nwatch < MAXW && prefix && *prefix) {
        strncpy(g_watch[g_nwatch], prefix, 1023);
        g_nwatch++;
    }
}
static int watched(const char *p) {
    if (!p) return 0;
    for (int i = 0; i < g_nwatch; i++)
        if (strncmp(p, g_watch[i], strlen(g_watch[i])) == 0) return 1;
    return 0;
}
uint64_t perf_fs_stats(void) { return atomic_load(&g_stats); }
uint64_t perf_fs_opens(void) { return atomic_load(&g_opens); }
uint64_t perf_fs_reads(void) { return atomic_load(&g_reads); }
uint64_t perf_fs_read_bytes(void) { return atomic_load(&g_readBytes); }

static int my_stat(const char *p, struct stat *b) {
    if (watched(p)) atomic_fetch_add(&g_stats, 1);
    return stat(p, b);
}
static int my_lstat(const char *p, struct stat *b) {
    if (watched(p)) atomic_fetch_add(&g_stats, 1);
    return lstat(p, b);
}
static int my_fstatat(int fd, const char *p, struct stat *b, int f) {
    if (watched(p)) atomic_fetch_add(&g_stats, 1);
    return fstatat(fd, p, b, f);
}
static int my_getattrlist(const char *p, void *al, void *buf, size_t sz, unsigned int opts) {
    if (watched(p)) atomic_fetch_add(&g_stats, 1);
    return getattrlist(p, al, buf, sz, opts);
}
static int my_access(const char *p, int m) {
    if (watched(p)) atomic_fetch_add(&g_stats, 1);
    return access(p, m);
}
static void note_open(const char *p, int fd) {
    if (fd < 0) return;
    int w = watched(p);
    if (w) atomic_fetch_add(&g_opens, 1);
    if (fd < 4096) atomic_store(&g_watchedFD[fd], w);
}
static int my_open(const char *p, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    int fd = open(p, flags, mode);
    note_open(p, fd);
    return fd;
}
static int my_openat(int dfd, const char *p, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    int fd = openat(dfd, p, flags, mode);
    note_open(p, fd);
    return fd;
}
static ssize_t my_read(int fd, void *b, size_t n) {
    ssize_t r = read(fd, b, n);
    if (fd >= 0 && fd < 4096 && atomic_load(&g_watchedFD[fd])) {
        atomic_fetch_add(&g_reads, 1);
        if (r > 0) atomic_fetch_add(&g_readBytes, (uint64_t)r);
    }
    return r;
}
static ssize_t my_pread(int fd, void *b, size_t n, off_t o) {
    ssize_t r = pread(fd, b, n, o);
    if (fd >= 0 && fd < 4096 && atomic_load(&g_watchedFD[fd])) {
        atomic_fetch_add(&g_reads, 1);
        if (r > 0) atomic_fetch_add(&g_readBytes, (uint64_t)r);
    }
    return r;
}

#define INTERPOSE(rep, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } _ip_##orig \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&rep, (const void *)(unsigned long)&orig };
INTERPOSE(my_stat, stat)
INTERPOSE(my_lstat, lstat)
INTERPOSE(my_fstatat, fstatat)
INTERPOSE(my_getattrlist, getattrlist)
INTERPOSE(my_access, access)
INTERPOSE(my_open, open)
INTERPOSE(my_openat, openat)
INTERPOSE(my_read, read)
INTERPOSE(my_pread, pread)
