// SCTediumChallenge — daemon-held state machine for the tedium override.
// Pure with respect to time: callers pass a monotonic uptime into every call,
// so tests fabricate clocks. Not thread-safe; callers serialize (daemon lock).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCTediumSubmitOutcome) {
    SCTediumSubmitAccepted = 0,     // correct digit counted; new digit issued
    SCTediumSubmitWrongDigit = 1,   // wrong digit; penalty applied; new digit issued
    SCTediumSubmitIgnoredTooFast = 2, // arrived < min interval after last counted entry; nothing changed
    SCTediumSubmitComplete = 3      // correct digit counted AND progress reached requiredEntries
};

@interface SCTediumChallenge : NSObject

@property (nonatomic, readonly) NSInteger requiredEntries;
@property (nonatomic, readonly) NSInteger progress;
@property (nonatomic, readonly) NSInteger expectedDigit; // 0-9, the digit currently shown
// Injectable for tests. Default: arc4random_uniform(10).
@property (nonatomic, copy) NSInteger (^digitProvider)(void);

- (instancetype)initWithRequiredEntries:(NSInteger)requiredEntries;

// Starts a fresh session, or resumes the existing one (progress kept) after
// applying idle expiry. Always (re)issues expectedDigit.
- (void)beginAtUptime:(NSTimeInterval)uptime;

// Applies idle expiry, then the rate floor, then judges the digit.
- (SCTediumSubmitOutcome)submitDigit:(NSInteger)digit atUptime:(NSTimeInterval)uptime;

@end

NS_ASSUME_NONNULL_END
