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

+ (NSTimeInterval)minimumIntervalAfterSuccess {
    return 5.0;
}

- (void)requestVerificationWithCompletion:(void (^)(NSDate*, NSDictionary*, NSUInteger))completion {
    __block NSUInteger requestGeneration;
    @synchronized(self) {
        NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
        if (self.fetchInFlight || uptime < self.nextAttemptUptime) return;
        self.fetchInFlight = YES;
        requestGeneration = self.generation;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary* reading = nil;
        NSDate* verified = [SCSNTPClient fetchNetworkTimeWithTimeout:3.0 readingAtResponse:&reading];
        BOOL succeeded = verified != nil && reading != nil;
        @synchronized(self) {
            if (requestGeneration != self.generation) {
                return;
            }
            NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
            if (!succeeded) {
                NSTimeInterval backoff = [SCBlockEndVerifier
                    retryIntervalForFailureCount:self.consecutiveFailures];
                self.consecutiveFailures += 1;
                self.nextAttemptUptime = uptime + backoff;
                NSLog(@"Time verification failed (%lu consecutive); retrying in %.0fs",
                      (unsigned long)self.consecutiveFailures, backoff);
            } else {
                self.consecutiveFailures = 0;
                self.nextAttemptUptime = uptime + [SCBlockEndVerifier minimumIntervalAfterSuccess];
            }
            self.fetchInFlight = NO;
        }
        if (succeeded) completion(verified, reading, requestGeneration);
    });
}

- (BOOL)isCurrentGeneration:(NSUInteger)generation {
    @synchronized(self) {
        return generation == self.generation;
    }
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
