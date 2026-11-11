//  CrashExceptions.m — the crash reporter's exception record (see CrashSignals.h).
//
//  AppKit catches an exception raised inside its display cycle or event handling and then
//  crashes on it itself (a trap, not an uncaught-exception abort), so neither
//  NSSetUncaughtExceptionHandler nor -reportException: sees it. An exception preprocessor sees
//  every exception as it is raised: each one's name, reason and raising stack go to a file,
//  overwritten by the next. After a crash, the reporter uses the record only when it was
//  written moments before the crash (one caught and handled long before is not the cause).

#import <Foundation/Foundation.h>
#import <objc/objc-exception.h>
#include "CrashSignals.h"

static NSString *gExceptionPath = nil;
static objc_exception_preprocessor gPrevious = NULL;
static volatile int gWriting = 0;

static id dotstudio_preprocess(id exception) {
    if (gExceptionPath != nil && !gWriting && [exception isKindOfClass:[NSException class]]) {
        gWriting = 1;
        @try {
            NSException *e = exception;
            NSMutableString *s = [NSMutableString stringWithFormat:@"%@: %@\n", e.name, e.reason ?: @"(no reason)"];
            if (e.userInfo.count > 0) [s appendFormat:@"userInfo: %@\n", e.userInfo];
            NSArray<NSString *> *stack = [NSThread callStackSymbols];
            if (stack.count > 80) stack = [stack subarrayWithRange:NSMakeRange(0, 80)];
            [s appendString:[stack componentsJoinedByString:@"\n"]];
            [s writeToFile:gExceptionPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        } @catch (id ignored) {
        }
        gWriting = 0;
    }
    return gPrevious ? gPrevious(exception) : exception;
}

void dotstudio_crash_exceptions_install(const char *path) {
    if (path == NULL || gExceptionPath != nil) return;
    gExceptionPath = [[NSString alloc] initWithUTF8String:path];
    gPrevious = objc_setExceptionPreprocessor(dotstudio_preprocess);
}
