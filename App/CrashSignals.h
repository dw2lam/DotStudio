//  CrashSignals.h — the crash reporter's async-signal-safe layer (CrashSignals.c, app only).

#ifndef DOTSTUDIO_CRASH_SIGNALS_H
#define DOTSTUDIO_CRASH_SIGNALS_H

/// Opens (and empties) `markerPath` now, and installs handlers for SIGSEGV, SIGBUS, SIGILL,
/// SIGABRT, SIGFPE and SIGTRAP that write one line ("signal <n> code <c> time <unix s>") to it
/// with nothing but write(2), then hand the signal back to the system (the previous handler,
/// normally the default: macOS still writes its .ips report). Returns 0 on success.
int dotstudio_crash_signals_install(const char *markerPath);

/// Appends `text` to the marker (from ordinary code — an exception about to end the process).
void dotstudio_crash_signals_note(const char *text);

/// Records every Objective-C exception as it is raised (name, reason, raising stack) to `path`,
/// each overwriting the last (CrashExceptions.m). AppKit traps on an exception it caught
/// itself, which no uncaught-exception handler sees.
void dotstudio_crash_exceptions_install(const char *path);

#endif
