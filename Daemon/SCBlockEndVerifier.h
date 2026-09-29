#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCBlockEndVerifier : NSObject

+ (instancetype)sharedVerifier;
+ (NSTimeInterval)retryIntervalForFailureCount:(NSUInteger)failures;
+ (BOOL)verifiedTime:(NSDate*)verifiedNow
    satisfiesEndForStart:(NSDate*)startWall
            durationSecs:(NSTimeInterval)durationSecs;

/// Minimum spacing between network fetches after a successful one, so a local
/// estimate that runs ahead of verified time cannot hammer the time servers.
+ (NSTimeInterval)minimumIntervalAfterSuccess;

/// Starts a background SNTP fetch unless one is in flight or backoff/rate
/// limits apply. The completion runs off the main thread only on success and
/// only if no reset happened meanwhile; it receives the verified time, the
/// SCTrustedClock reading captured when the reply arrived, and the generation
/// the request belonged to. Callers must re-check the generation with
/// isCurrentGeneration: under the daemon lock before acting.
- (void)requestVerificationWithCompletion:(void (^)(NSDate* verifiedNow,
                                                    NSDictionary* readingAtResponse,
                                                    NSUInteger generation))completion;
- (BOOL)isCurrentGeneration:(NSUInteger)generation;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
