#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCBlockEndVerifier : NSObject

+ (instancetype)sharedVerifier;
+ (NSTimeInterval)retryIntervalForFailureCount:(NSUInteger)failures;
+ (BOOL)verifiedTime:(NSDate*)verifiedNow
    satisfiesEndForStart:(NSDate*)startWall
            durationSecs:(NSTimeInterval)durationSecs;

- (void)requestVerificationWithCompletion:(void (^)(NSDate* _Nullable verifiedNow))completion;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
