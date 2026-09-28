#import "SCBlockEndVerifier.h"

#import "SCSNTPClient.h"

@interface SCBlockEndVerifier ()
@property(nonatomic) BOOL fetchInFlight;
@property(nonatomic) NSUInteger consecutiveFailures;
@property(nonatomic) NSTimeInterval nextAttemptUptime;
@property(nonatomic) NSUInteger generation;
@end

@implementation SCBlockEndVerifier

+ (instancetype)sharedVerifier {
    static SCBlockEndVerifier* verifier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        verifier = [SCBlockEndVerifier new];
    });
    return verifier;
}

+ (NSTimeInterval)retryIntervalForFailureCount:(NSUInteger)failures {
    static const NSTimeInterval schedule[] = {5, 10, 30, 60, 300};
    return schedule[MIN(failures, (NSUInteger)4)];
}

+ (BOOL)verifiedTime:(NSDate*)verifiedNow
    satisfiesEndForStart:(NSDate*)startWall
            durationSecs:(NSTimeInterval)durationSecs {
    return [verifiedNow timeIntervalSinceDate:startWall] >= durationSecs;
}

- (void)requestVerificationWithCompletion:(void (^)(NSDate* _Nullable))completion {
    __block NSUInteger requestGeneration;
    @synchronized(self) {
        NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
        if (self.fetchInFlight || uptime < self.nextAttemptUptime) return;
        self.fetchInFlight = YES;
        requestGeneration = self.generation;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDate* verified = [SCSNTPClient fetchNetworkTimeWithTimeout:3.0];
        @synchronized(self) {
            if (requestGeneration != self.generation) {
                return;
            }
            if (verified == nil) {
                NSTimeInterval backoff = [SCBlockEndVerifier
                    retryIntervalForFailureCount:self.consecutiveFailures];
                self.consecutiveFailures += 1;
                self.nextAttemptUptime = NSProcessInfo.processInfo.systemUptime + backoff;
                NSLog(@"Time verification failed (%lu consecutive); retrying in %.0fs",
                      (unsigned long)self.consecutiveFailures, backoff);
            } else {
                self.consecutiveFailures = 0;
                self.nextAttemptUptime = 0;
            }
            self.fetchInFlight = NO;
        }
        completion(verified);
    });
}

- (void)reset {
    @synchronized(self) {
        self.generation += 1;
        self.fetchInFlight = NO;
        self.consecutiveFailures = 0;
        self.nextAttemptUptime = 0;
    }
}

@end
