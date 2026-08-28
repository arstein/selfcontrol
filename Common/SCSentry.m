//
//  SCSentry.m
//  SelfControl
//
//  Fork: Sentry telemetry removed. All methods are intentional no-ops
//  (log-only) so the ~123 call sites don't need to change.
//

#import "SCSentry.h"

@implementation SCSentry

+ (void)startSentry:(NSString*)componentId {
    // no-op: telemetry removed in fork
}

+ (void)addBreadcrumb:(NSString*)message category:(NSString*)category {
    // no-op: telemetry removed in fork
}

+ (void)captureError:(NSError*)error {
    NSLog(@"SCSentry(stub) captured error: %@", error);
}

+ (void)captureMessage:(NSString*)message withScopeBlock:(nullable void (^)(SentryScope* _Nonnull))block {
    NSLog(@"SCSentry(stub) captured message: %@", message);
}

+ (void)captureMessage:(NSString*)message {
    NSLog(@"SCSentry(stub) captured message: %@", message);
}

+ (BOOL)showErrorReportingPromptIfNeeded {
    return NO;
}

@end
