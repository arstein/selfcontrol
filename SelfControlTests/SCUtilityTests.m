//
//  BlockDateUtilitiesTests.m
//  SelfControlTests
//
//  Created by Charles Stigler on 17/07/2018.
//

#import <XCTest/XCTest.h>
#import "SCUtility.h"
#import "SCSentry.h"
#import "SCErr.h"
#import "SCSettings.h"
#import "SCTrustedClock.h"
#import "SCBlockUtilities.h"
#import "SCConstants.h"

@interface SCUtilityTests : XCTestCase

@end

// Static dictionaries of block values to test against

NSDictionary* activeBlockLegacyDict; // Active (started 5 minutes ago, duration 10 min)
NSDictionary* expiredBlockLegacyDict; // Expired (started 10 minutes 10 seconds ago, duration 10 min)
NSDictionary* noBlockLegacyDict; // start date is distantFuture
NSDictionary* noBlockLegacyDict2; // start date is nil
NSDictionary* emptyLegacyDict; // literally an empty dictionary
NSDictionary* futureStartDateLegacyDict; // start date is in the future
NSDictionary* negativeBlockDurationLegacyDict; // block duration is negative
NSDictionary* veryLongBlockLegacyDict; // year-long block, one day in

@implementation SCUtilityTests

- (NSUserDefaults*)testDefaults {
    return [[NSUserDefaults alloc] initWithSuiteName: @"BlockDateUtilitiesTests"];
}

+ (void)setUp {
    // SCSettings shouldn't be readOnly during our tests
    // so we can test changing values
    [SCSettings sharedSettings].readOnly = NO;
    
    // Initialize the sample legacy setting dictionaries
    activeBlockLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: -300], // 5 minutes ago
        @"BlockDuration": @10 // 10 minutes
    };
    expiredBlockLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: -610], // 10 min 10 seconds ago
        @"BlockDuration": @10 // 10 minutes
    };
    noBlockLegacyDict = @{
        @"BlockStartedDate": [NSDate distantFuture],
        @"BlockDuration": @300 // 6 hours
    };
    noBlockLegacyDict2 = @{
        @"BlockDuration": @300 // 6 hours
    };
    futureStartDateLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: 600], // 10 min from now
        @"BlockDuration": @300 // 6 hours
    };
    negativeBlockDurationLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: -600], // 10 min ago
        @"BlockDuration": @-15 // negative 15 minutes
    };
    veryLongBlockLegacyDict = @{
        @"BlockStartedDate": [NSDate dateWithTimeIntervalSinceNow: -86400], // 1 day ago
        @"BlockDuration": @432000 // 300 days
    };
    emptyLegacyDict = @{
    };
}

- (void)setUp {
    [super setUp];

    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void) testCleanBlocklistEntries {
    // ignores weird invalid entries
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: nil].count == 0);
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: @""].count == 0);
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: @"      "].count == 0);
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: @"  \n\n   \n***!@#$%^*()+=<>,/?| "].count == 0);
    XCTAssert([SCMiscUtilities cleanBlocklistEntry: @"://}**"].count == 0);
    
    // can take a plain hostname
    NSArray* cleaned = [SCMiscUtilities cleanBlocklistEntry: @"selfcontrolapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"selfcontrolapp.com"]);
    
    // and lowercase it
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"selfcontrolapp.com"]);
    
    // with subdomains
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"www.selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com"]);
    
    // with http scheme
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"http://www.selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com"]);
    
    // with https scheme
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"https://www.selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com"]);
    
    // with ftp scheme
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"ftp://www.selFconTROLapp.com"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com"]);
    
    // with port
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"https://www.selFconTROLapp.com:73"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"www.selfcontrolapp.com:73"]);
    
    // strips username/password
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"http://charlie:mypass@cnn.com:54"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"cnn.com:54"]);
    
    // strips path etc
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"http://mysite.com/my/path/is/very/long.php?querystring=ydfjkl&otherquerystring=%40%80%20#cool"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"mysite.com"]);
    
    // CIDR IP ranges
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"127.0.0.1/20"];
    XCTAssert(cleaned.count == 1 && [[cleaned firstObject] isEqualToString: @"127.0.0.1/20"]);
    
    // can split entries by newlines
    cleaned = [SCMiscUtilities cleanBlocklistEntry: @"http://charlie:mypass@cnn.com:54\nhttps://selfcontrolAPP.com\n192.168.1.1/24\ntest.com\n{}*&\nhttps://reader.google.com/mypath/is/great.php"];
    XCTAssert(cleaned.count == 5);
    XCTAssert([cleaned[0] isEqualToString: @"cnn.com:54"]);
    XCTAssert([cleaned[1] isEqualToString: @"selfcontrolapp.com"]);
    XCTAssert([cleaned[2] isEqualToString: @"192.168.1.1/24"]);
    XCTAssert([cleaned[3] isEqualToString: @"test.com"]);
    XCTAssert([cleaned[4] isEqualToString: @"reader.google.com"]);
}

- (void)testTimeSourcesAreRemovedFromBlocklists {
    NSArray* filtered = [SCBlockUtilities blocklistByRemovingTimeSources:@[
        @"example.com", @"time.apple.com", @"TIME.CLOUDFLARE.COM.", @"time.google.com:123"
    ]];
    XCTAssertEqualObjects(filtered, (@[@"example.com"]));
}

- (void) testModernBlockDetection {
    SCSettings* settings = [SCSettings sharedSettings];

    XCTAssert(![SCBlockUtilities modernBlockIsRunning]);
    XCTAssert([SCBlockUtilities currentBlockIsExpired]);

    // test a block that should have expired 5 minutes ago
    [settings setValue: @YES forKey: @"BlockIsRunning"];
    [settings setValue: @[ @"facebook.com", @"reddit.com" ] forKey: @"ActiveBlocklist"];
    [settings setValue: @NO forKey: @"ActiveBlockAsWhitelist"];
    [settings setValue: [NSDate dateWithTimeIntervalSinceNow: -300] forKey: @"BlockEndDate"];

    XCTAssert([SCBlockUtilities modernBlockIsRunning]);
    XCTAssert([SCBlockUtilities currentBlockIsExpired]);

    // test block that should still be running
    [settings setValue: [NSDate dateWithTimeIntervalSinceNow: 300] forKey: @"BlockEndDate"];
    XCTAssert([SCBlockUtilities modernBlockIsRunning]);
    XCTAssert(![SCBlockUtilities currentBlockIsExpired]);

    // test removing a block
    [SCBlockUtilities removeBlockFromSettings];
    XCTAssert(![SCBlockUtilities modernBlockIsRunning]);
    XCTAssert([SCBlockUtilities currentBlockIsExpired]);
}

- (void) testLegacyBlockDetection {
    // test blockIsRunningInLegacyDictionary
    // the block is "running" even if it's expired, since it hasn't been removed
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: activeBlockLegacyDict]);
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: expiredBlockLegacyDict]);
    XCTAssert(![SCMigrationUtilities blockIsRunningInLegacyDictionary: noBlockLegacyDict]);
    XCTAssert(![SCMigrationUtilities blockIsRunningInLegacyDictionary: noBlockLegacyDict2]);
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: futureStartDateLegacyDict]);
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: negativeBlockDurationLegacyDict]); // negative still might be running?
    XCTAssert([SCMigrationUtilities blockIsRunningInLegacyDictionary: veryLongBlockLegacyDict]);
    XCTAssert(![SCMigrationUtilities blockIsRunningInLegacyDictionary: emptyLegacyDict]);
}

#pragma mark - Trusted timing decision

static NSDictionary* SCTTReading(NSTimeInterval wall, NSTimeInterval mach, NSString* boot) {
    return @{@"wall": [NSDate dateWithTimeIntervalSince1970:wall], @"mach": @(mach), @"boot": boot};
}

static NSDate* SCTTDate(NSTimeInterval secs) {
    return [NSDate dateWithTimeIntervalSince1970:secs];
}

static NSDictionary* SCTTSnapshot(NSDictionary* clockState, NSTimeInterval startWall, BOOL verified, NSTimeInterval duration) {
    return @{@"TrustedClockState": clockState,
             @"BlockStartWall": SCTTDate(startWall),
             @"BlockStartIsVerified": @(verified),
             @"BlockDurationSecs": @(duration)};
}

- (void)testDecisionCorrectsRolledBackUnverifiedStart {
    // The clock was rolled back ~1h before the block started: wall said 1000
    // but true time was 5000. Duration is 600s.
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCTTReading(1000, 50, @"A")];
    NSDictionary* decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 1000, NO, 600)
                             verifiedNow:SCTTDate(5100)
                                 reading:SCTTReading(1100, 150, @"A")];
    XCTAssertNotNil(decision);
    NSDictionary* writes = decision[SCTrustedTimingSettingsWritesKey];
    XCTAssertTrue([decision[SCTrustedTimingStartWasCorrectedKey] boolValue]);
    XCTAssertEqualWithAccuracy([writes[@"BlockStartWall"] timeIntervalSince1970], 5000, 0.001);
    XCTAssertEqualWithAccuracy([writes[@"BlockEndDate"] timeIntervalSince1970], 5600, 0.001);
    XCTAssertEqualObjects(writes[@"BlockStartIsVerified"], @YES);
    XCTAssertEqualObjects(writes[@"TrustedClockNeedsVerification"], @NO);
    // The wall-clock end (1600) would already be past; the corrected one is not.
    XCTAssertFalse([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
    // Rebased state is anchored on the verified time and the response reading.
    NSDictionary* rebased = writes[@"TrustedClockState"];
    XCTAssertEqualWithAccuracy([rebased[@"wallAnchor"] timeIntervalSince1970], 5100, 0.001);
    XCTAssertEqualWithAccuracy([rebased[@"machAnchorSecs"] doubleValue], 150, 0.001);
}

- (void)testDecisionCorrectionNeverShortensBlock {
    // A clock rolled FORWARD before start: the correction moves the stored
    // start earlier, but the block still lasts its full monotonic duration.
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCTTReading(9000, 50, @"A")];
    NSDictionary* decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 9000, NO, 600)
                             verifiedNow:SCTTDate(5599)
                                 reading:SCTTReading(9599, 649, @"A")];
    XCTAssertEqualWithAccuracy([decision[SCTrustedTimingSettingsWritesKey][@"BlockStartWall"] timeIntervalSince1970],
                               5000, 0.001);
    XCTAssertFalse([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
}

- (void)testDecisionAfterRebootWhileUnverified {
    // True start 5000. 300s ran before reboot (checkpointed), 200s powered
    // off, then 50s in the new boot. The gap is uncredited, so the corrected
    // start is 200s late: fail closed, the block runs longer.
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCTTReading(1000, 50, @"A")];
    state = [SCTrustedClock checkpointState:state reading:SCTTReading(1300, 350, @"A")];
    state = [SCTrustedClock reanchoredStateAfterBootChange:state reading:SCTTReading(1500, 10, @"B")];
    NSDictionary* decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 1000, NO, 600)
                             verifiedNow:SCTTDate(5550)
                                 reading:SCTTReading(1550, 60, @"B")];
    NSDictionary* writes = decision[SCTrustedTimingSettingsWritesKey];
    XCTAssertEqualWithAccuracy([writes[@"BlockStartWall"] timeIntervalSince1970], 5200, 0.001);
    XCTAssertFalse([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
}

- (void)testDecisionReanchorsStateFromEarlierBoot {
    // A caller that bypasses the daemon (the killer) may see state that was
    // never re-anchored. Prior-boot time comes only from the checkpoint.
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCTTReading(1000, 50, @"A")];
    state = [SCTrustedClock checkpointState:state reading:SCTTReading(1300, 350, @"A")];
    NSDictionary* decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 1000, NO, 600)
                             verifiedNow:SCTTDate(9000)
                                 reading:SCTTReading(1000, 400, @"B")];
    // elapsed = 300 (prior boot) + 0 (fresh anchor) -> start 8700, not expired
    XCTAssertEqualWithAccuracy([decision[SCTrustedTimingSettingsWritesKey][@"BlockStartWall"] timeIntervalSince1970],
                               8700, 0.001);
    XCTAssertFalse([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
}

- (void)testDecisionAfterRebootWhileVerified {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCTTReading(5000, 50, @"A")];
    state = [SCTrustedClock reanchoredStateAfterBootChange:state reading:SCTTReading(5000, 5, @"B")];
    NSDictionary* decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 5000, YES, 600)
                             verifiedNow:SCTTDate(5700)
                                 reading:SCTTReading(5010, 15, @"B")];
    NSDictionary* writes = decision[SCTrustedTimingSettingsWritesKey];
    XCTAssertFalse([decision[SCTrustedTimingStartWasCorrectedKey] boolValue]);
    XCTAssertNil(writes[@"BlockStartWall"]);
    XCTAssertNil(writes[@"BlockEndDate"]);
    XCTAssertTrue([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
}

- (void)testDecisionHonorsExtendedDuration {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCTTReading(5000, 50, @"A")];
    // Originally 600s, extended to 1200s; verified time is 700s after start.
    NSDictionary* decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 5000, YES, 1200)
                             verifiedNow:SCTTDate(5700)
                                 reading:SCTTReading(5700, 750, @"A")];
    XCTAssertFalse([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);

    // Unverified start with an extended duration: end date uses the new duration.
    decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 5000, NO, 1200)
                             verifiedNow:SCTTDate(5700)
                                 reading:SCTTReading(5700, 750, @"A")];
    XCTAssertEqualWithAccuracy([decision[SCTrustedTimingSettingsWritesKey][@"BlockEndDate"] timeIntervalSince1970],
                               6200, 0.001);
    XCTAssertFalse([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
}

- (void)testDecisionExpiredAndNotExpired {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCTTReading(5000, 50, @"A")];
    NSDictionary* expired = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 5000, YES, 600)
                             verifiedNow:SCTTDate(5600)
                                 reading:SCTTReading(5600, 650, @"A")];
    XCTAssertTrue([expired[SCTrustedTimingShouldRemoveBlockKey] boolValue]);

    NSDictionary* running = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 5000, YES, 600)
                             verifiedNow:SCTTDate(5599)
                                 reading:SCTTReading(5599, 649, @"A")];
    XCTAssertFalse([running[SCTrustedTimingShouldRemoveBlockKey] boolValue]);

    // Unverified block started offline: clearable once monotonic elapsed
    // reaches the duration, regardless of the stored wall start.
    NSDictionary* offline = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 1, NO, 600)
                             verifiedNow:SCTTDate(90000)
                                 reading:SCTTReading(0, 650, @"A")];
    XCTAssertTrue([offline[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
    offline = [SCBlockUtilities
        trustedTimingDecisionForSettings:SCTTSnapshot(state, 1, NO, 600)
                             verifiedNow:SCTTDate(90000)
                                 reading:SCTTReading(0, 649, @"A")];
    XCTAssertFalse([offline[SCTrustedTimingShouldRemoveBlockKey] boolValue]);
}

- (void)testDecisionRequiresTrustedState {
    NSDictionary* state = [SCTrustedClock freshStateWithReading:SCTTReading(5000, 50, @"A")];
    NSDate* now = SCTTDate(99999);
    NSDictionary* reading = SCTTReading(99999, 99999, @"A");
    XCTAssertNil([SCBlockUtilities trustedTimingDecisionForSettings:@{} verifiedNow:now reading:reading]);
    XCTAssertNil([SCBlockUtilities trustedTimingDecisionForSettings:SCTTSnapshot(@{}, 5000, YES, 600)
                                                        verifiedNow:now reading:reading]);
    XCTAssertNil([SCBlockUtilities trustedTimingDecisionForSettings:SCTTSnapshot(state, 5000, YES, 0)
                                                        verifiedNow:now reading:reading]);
    // A verified start that reads as the SCSettings default is unusable.
    NSMutableDictionary* noStart = [SCTTSnapshot(state, 5000, YES, 600) mutableCopy];
    noStart[@"BlockStartWall"] = [NSDate distantPast];
    XCTAssertNil([SCBlockUtilities trustedTimingDecisionForSettings:noStart verifiedNow:now reading:reading]);
    XCTAssertNil([SCBlockUtilities trustedTimingDecisionForSettings:SCTTSnapshot(state, 5000, YES, 600)
                                                        verifiedNow:now reading:@{}]);
}

- (void)testEffectiveBlockStartWall {
    XCTAssertNil([SCBlockUtilities effectiveBlockStartWallFromSettingsValue:nil]);
    XCTAssertNil([SCBlockUtilities effectiveBlockStartWallFromSettingsValue:[NSDate distantPast]]);
    XCTAssertNil([SCBlockUtilities effectiveBlockStartWallFromSettingsValue:@"2026-01-01"]);
    XCTAssertNil([SCBlockUtilities effectiveBlockStartWallFromSettingsValue:@12345]);
    NSDate* real = SCTTDate(1767225600);
    XCTAssertEqualObjects([SCBlockUtilities effectiveBlockStartWallFromSettingsValue:real], real);
}

- (void)testEmergencyUnlockAllowedForSettingsValue {
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedForSettingsValue: nil]);
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedForSettingsValue: @YES]);
    XCTAssertFalse([SCBlockUtilities emergencyUnlockAllowedForSettingsValue: @NO]);
    XCTAssertTrue([SCBlockUtilities emergencyUnlockAllowedForSettingsValue: @"NO"]);
}

- (void)testOverrideSoundDefaultsToSubmarine {
    // The defaults store an index into systemSoundNames; keep it pointing at Submarine.
    NSUInteger index = [SCConstants.defaultUserDefaults[@"OverrideSound"] unsignedIntegerValue];
    XCTAssertEqualObjects(SCConstants.systemSoundNames[index], @"Submarine");
    XCTAssertEqualObjects(SCConstants.defaultUserDefaults[@"OverrideSoundShouldPlay"], @YES);
}

- (void)testExtensionStepsSplitIntoDayLongSteps {
    NSDate* from = [NSDate dateWithTimeIntervalSince1970: 1000000];
    NSDate* to = [from dateByAddingTimeInterval: 2.5 * 86400];
    NSArray<NSDate*>* steps = [SCBlockUtilities extensionStepsFromEndDate: from toEndDate: to maxStepSecs: 86400];
    NSArray<NSDate*>* expected = @[[from dateByAddingTimeInterval: 86400], [from dateByAddingTimeInterval: 2 * 86400], to];
    XCTAssertEqualObjects(steps, expected);
}

- (void)testExtensionStepsShortOrEmpty {
    NSDate* from = [NSDate dateWithTimeIntervalSince1970: 1000000];
    NSDate* hourLater = [from dateByAddingTimeInterval: 3600];
    XCTAssertEqualObjects([SCBlockUtilities extensionStepsFromEndDate: from toEndDate: hourLater maxStepSecs: 86400], @[hourLater]);
    XCTAssertEqualObjects([SCBlockUtilities extensionStepsFromEndDate: from toEndDate: from maxStepSecs: 86400], @[]);
    XCTAssertEqualObjects([SCBlockUtilities extensionStepsFromEndDate: hourLater toEndDate: from maxStepSecs: 86400], @[]);
}

@end
