#import "SCTediumChallenge.h"
#import "SCTediumConfig.h"

@interface SCTediumChallenge ()
@property (nonatomic, readwrite) NSInteger requiredEntries;
@property (nonatomic, readwrite) NSInteger progress;
@property (nonatomic, readwrite) NSInteger expectedDigit;
// uptime of the last COUNTED entry (accepted or wrong) or of begin; rate floor
// and idle expiry both measure from here. Ignored entries never touch it.
@property (nonatomic) NSTimeInterval lastCountedUptime;
@property (nonatomic) BOOL hasCountedEntry;
@end

@implementation SCTediumChallenge

- (instancetype)initWithRequiredEntries:(NSInteger)requiredEntries {
    if (self = [super init]) {
        _requiredEntries = MAX(1, requiredEntries);
        _progress = 0;
        _digitProvider = ^NSInteger{ return (NSInteger)arc4random_uniform(10); };
    }
    return self;
}

- (BOOL)applyIdleExpiryAtUptime:(NSTimeInterval)uptime {
    if (self.hasCountedEntry && (uptime - self.lastCountedUptime) > SC_TEDIUM_IDLE_EXPIRY_SECS) {
        self.progress = 0;
        return YES;
    }
    return NO;
}

- (void)beginAtUptime:(NSTimeInterval)uptime {
    BOOL idleExpired = [self applyIdleExpiryAtUptime: uptime];
    self.expectedDigit = self.digitProvider();
    // On a fresh session, or when idle expiry just fired, re-anchor the rate
    // floor to this begin so the first digit after an idle-expired reopen is
    // rate-floored just like every other first digit. A submit-triggered idle
    // reset intentionally does NOT re-anchor here (see submitDigit:atUptime:) -
    // an in-panel post-idle entry must still count immediately.
    if (!self.hasCountedEntry || idleExpired) {
        self.hasCountedEntry = YES;
        self.lastCountedUptime = uptime;
    }
}

- (SCTediumSubmitOutcome)submitDigit:(NSInteger)digit atUptime:(NSTimeInterval)uptime {
    [self applyIdleExpiryAtUptime: uptime];

    // Rate floor: the whole point of the feature is that it takes real time.
    // Ignored entries change nothing — a double-Enter can never hurt progress.
    if (self.hasCountedEntry && (uptime - self.lastCountedUptime) < SC_TEDIUM_MIN_ENTRY_INTERVAL_SECS) {
        return SCTediumSubmitIgnoredTooFast;
    }

    self.hasCountedEntry = YES;
    self.lastCountedUptime = uptime;

    if (digit == self.expectedDigit) {
        self.progress += 1;
        self.expectedDigit = self.digitProvider();
        return (self.progress >= self.requiredEntries) ? SCTediumSubmitComplete : SCTediumSubmitAccepted;
    } else {
        self.progress = MAX(0, self.progress - SC_TEDIUM_WRONG_ENTRY_PENALTY);
        self.expectedDigit = self.digitProvider();
        return SCTediumSubmitWrongDigit;
    }
}

@end
