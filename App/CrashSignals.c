//  CrashSignals.c — see CrashSignals.h. Everything a handler does here is async-signal-safe:
//  a pre-opened descriptor, a stack buffer, write(2), time(3), sigaction(2), raise(3).

#include "CrashSignals.h"
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

static int g_fd = -1;
static struct sigaction g_previous[NSIG];
static const int g_signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP };
static volatile sig_atomic_t g_handling = 0;

static int put_str(char *buf, int n, int cap, const char *s) {
    while (*s && n < cap) buf[n++] = *s++;
    return n;
}

static int put_long(char *buf, int n, int cap, long v) {
    char d[24];
    int k = 0;
    int neg = v < 0;
    unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
    do { d[k++] = (char)('0' + u % 10); u /= 10; } while (u && k < 23);
    if (neg && n < cap) buf[n++] = '-';
    while (k && n < cap) buf[n++] = d[--k];
    return n;
}

static void handler(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;
    if (!g_handling) {
        g_handling = 1;
        if (g_fd >= 0) {
            char buf[128];
            int n = 0;
            n = put_str(buf, n, (int)sizeof buf, "signal ");
            n = put_long(buf, n, (int)sizeof buf, sig);
            n = put_str(buf, n, (int)sizeof buf, " code ");
            n = put_long(buf, n, (int)sizeof buf, info ? info->si_code : 0);
            n = put_str(buf, n, (int)sizeof buf, " time ");
            n = put_long(buf, n, (int)sizeof buf, (long)time(NULL));
            n = put_str(buf, n, (int)sizeof buf, "\n");
            (void)write(g_fd, buf, (size_t)n);
        }
    }
    // Hand it back: the previous disposition (normally the default, so the process dies and
    // macOS writes its crash report with the original state).
    if (sig > 0 && sig < NSIG) sigaction(sig, &g_previous[sig], NULL);
    // A fault re-executes the faulting instruction on return and dies there; a signal sent by
    // raise/abort/kill has to be sent again.
    if (info == NULL || info->si_code == SI_USER || sig == SIGABRT) raise(sig);
}

int dotstudio_crash_signals_install(const char *markerPath) {
    if (markerPath == NULL) return -1;
    int fd = open(markerPath, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    g_fd = fd;

    // Its own stack, so a stack overflow can still be recorded.
    static char *altstack = NULL;
    if (altstack == NULL) {
        size_t size = 64 * 1024;
        altstack = malloc(size);
        if (altstack) {
            stack_t ss;
            ss.ss_sp = altstack;
            ss.ss_size = size;
            ss.ss_flags = 0;
            sigaltstack(&ss, NULL);
        }
    }
    for (size_t i = 0; i < sizeof g_signals / sizeof g_signals[0]; i++) {
        int sig = g_signals[i];
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = handler;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);
        sigaction(sig, &sa, &g_previous[sig]);
    }
    return 0;
}

void dotstudio_crash_signals_note(const char *text) {
    if (g_fd < 0 || text == NULL) return;
    (void)write(g_fd, text, strlen(text));
}
