#import <XCTest/XCTest.h>
#import "SCTediumChallenge.h"
#import "SCTediumConfig.h"

@interface SCTediumChallengeTests : XCTestCase
@end

@implementation SCTediumChallengeTests

// Challenge whose digits cycle 0,1,2,... so tests know the expected digit.
- (SCTediumChallenge*)challengeWithRequired:(NSInteger)n {
    SCTediumChallenge* c = [[SCTediumChallenge alloc] initWithRequiredEntries: n];
    __block NSInteger counter = 0;
    c.digitProvider = ^NSInteger{ return (counter++) % 10; };
    [c beginAtUptime: 1000.0];
    return c;
}

- (void)testCorrectEntriesIncrementAndComplete {
    SCTediumChallenge* c = [self challengeWithRequired: 3];
    NSTimeInterval t = 1000.0;
    for (NSInteger i = 0; i < 2; i++) {
        t += 2.0;
        XCTAssertEqual([c submitDigit: c.expectedDigit atUptime: t], SCTediumSubmitAccepted);
        XCTAssertEqual(c.progress, i + 1);
    }
    t += 2.0;
    XCTAssertEqual([c submitDigit: c.expectedDigit atUptime: t], SCTediumSubmitComplete);
    XCTAssertEqual(c.progress, 3);
}

- (void)testWrongDigitAppliesPenaltyWithFloorAndIssuesNewDigit {
    SCTediumChallenge* c = [self challengeWithRequired: 300];
    NSTimeInterval t = 1000.0;
    for (NSInteger i = 0; i < 5; i++) { t += 2.0; [c submitDigit: c.expectedDigit atUptime: t]; }
    XCTAssertEqual(c.progress, 5);
    NSInteger before = c.expectedDigit;
    NSInteger wrong = (before + 1) % 10;
    t += 2.0;
    XCTAssertEqual([c submitDigit: wrong atUptime: t], SCTediumSubmitWrongDigit);
    XCTAssertEqual(c.progress, 0); // 5 - SC_TEDIUM_WRONG_ENTRY_PENALTY floored at 0
    // wrong entry still rotates the digit (deterministic provider: it advanced)
    t += 2.0;
    XCTAssertEqual([c submitDigit: c.expectedDigit atUptime: t], SCTediumSubmitAccepted);
}

- (void)testPenaltySubtractsTwentyWhenAboveFloor {
    SCTediumChallenge* c = [self challengeWithRequired: 300];
    NSTimeInterval t = 1000.0;
    for (NSInteger i = 0; i < 25; i++) { t += 2.0; [c submitDigit: c.expectedDigit atUptime: t]; }
    XCTAssertEqual(c.progress, 25);
    t += 2.0;
    [c submitDigit: (c.expectedDigit + 1) % 10 atUptime: t];
    XCTAssertEqual(c.progress, 25 - SC_TEDIUM_WRONG_ENTRY_PENALTY);
}

- (void)testTooFastEntriesAreIgnoredWithoutPenaltyOrDigitChange {
    SCTediumChallenge* c = [self challengeWithRequired: 300];
    NSTimeInterval t = 1002.0;
    XCTAssertEqual([c submitDigit: c.expectedDigit atUptime: t], SCTediumSubmitAccepted);
    NSInteger digitAfter = c.expectedDigit;
    // 0.5s later: ignored, even though the digit is correct
    XCTAssertEqual([c submitDigit: digitAfter atUptime: t + 0.5], SCTediumSubmitIgnoredTooFast);
    XCTAssertEqual(c.progress, 1);
    XCTAssertEqual(c.expectedDigit, digitAfter);
    // ...and a wrong digit too fast is also ignored (double-Enter safety)
    XCTAssertEqual([c submitDigit: (digitAfter + 1) % 10 atUptime: t + 0.9], SCTediumSubmitIgnoredTooFast);
    XCTAssertEqual(c.progress, 1);
    // at exactly the interval, it counts again
    XCTAssertEqual([c submitDigit: digitAfter atUptime: t + SC_TEDIUM_MIN_ENTRY_INTERVAL_SECS], SCTediumSubmitAccepted);
    XCTAssertEqual(c.progress, 2);
}

- (void)testIgnoredEntriesDoNotExtendTheRateWindow {
    // spamming must not push the acceptance window forward forever
    SCTediumChallenge* c = [self challengeWithRequired: 300];
    NSTimeInterval t = 1002.0;
    [c submitDigit: c.expectedDigit atUptime: t]; // counted
    [c submitDigit: c.expectedDigit atUptime: t + 0.3]; // ignored
    [c submitDigit: c.expectedDigit atUptime: t + 0.6]; // ignored
    XCTAssertEqual([c submitDigit: c.expectedDigit atUptime: t + 1.0], SCTediumSubmitAccepted);
}

- (void)testIdleExpiryResetsProgressButSessionContinues {
    SCTediumChallenge* c = [self challengeWithRequired: 300];
    NSTimeInterval t = 1000.0;
    for (NSInteger i = 0; i < 30; i++) { t += 2.0; [c submitDigit: c.expectedDigit atUptime: t]; }
    XCTAssertEqual(c.progress, 30);
    // walk away for > SC_TEDIUM_IDLE_EXPIRY_SECS
    t += SC_TEDIUM_IDLE_EXPIRY_SECS + 1.0;
    XCTAssertEqual([c submitDigit: c.expectedDigit atUptime: t], SCTediumSubmitAccepted);
    XCTAssertEqual(c.progress, 1); // reset to 0, then this entry counted
}

- (void)testBeginResumesExistingProgressAndAppliesIdleExpiry {
    SCTediumChallenge* c = [self challengeWithRequired: 300];
    NSTimeInterval t = 1000.0;
    for (NSInteger i = 0; i < 4; i++) { t += 2.0; [c submitDigit: c.expectedDigit atUptime: t]; }
    [c beginAtUptime: t + 60.0]; // reopened the sheet a minute later
    XCTAssertEqual(c.progress, 4); // resumed, not reset
    [c beginAtUptime: t + 60.0 + SC_TEDIUM_IDLE_EXPIRY_SECS + 1.0];
    XCTAssertEqual(c.progress, 0); // idle-expired
}

- (void)testDefaultDigitProviderStaysInRange {
    SCTediumChallenge* c = [[SCTediumChallenge alloc] initWithRequiredEntries: 5];
    [c beginAtUptime: 0];
    for (int i = 0; i < 50; i++) {
        XCTAssertGreaterThanOrEqual(c.expectedDigit, 0);
        XCTAssertLessThanOrEqual(c.expectedDigit, 9);
        [c submitDigit: c.expectedDigit atUptime: 10.0 * (i + 1)];
    }
}

@end
