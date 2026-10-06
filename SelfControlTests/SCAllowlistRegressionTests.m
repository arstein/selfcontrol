#import <XCTest/XCTest.h>
#import "BlockManager.h"
#import "PacketFilter.h"
#import "SCPFTestSupport.h"

@interface BlockManager (AllowlistRegressionTesting)
- (void)addGoogleIPsToPF;
@end

@interface SCAllowlistRegressionTests : XCTestCase
@end

@implementation SCAllowlistRegressionTests

// Phase 1 manual test #5: an allowlist containing a Google domain blocked nothing
// because pf rejected the whole anchor over one malformed Google range.
- (void)testAllowlistWithGoogleRangesIsAcceptedByPF {
    BlockManager* bm = [[BlockManager alloc] initAsAllowlist: YES];
    [bm addGoogleIPsToPF];
    PacketFilter* pf = [bm valueForKey: @"pf"];
    NSString* output = nil;
    int status = SCPFParseStatus([pf configurationText], &output);
    XCTAssertEqual(status, 0, @"pfctl rejected the allowlist anchor: %@", output);
}

// Sinkhole addresses (what /etc/hosts maps blocked domains to) are dropped only
// as single hosts; a range the user typed that starts at one is kept.
- (void)testSinkholeDropKeepsRanges {
    XCTAssertTrue([BlockManager isSinkholeAddress: @"0.0.0.0" maskLen: 0]);
    XCTAssertTrue([BlockManager isSinkholeAddress: @"0.0.0.0" maskLen: 32]);
    XCTAssertTrue([BlockManager isSinkholeAddress: @"::" maskLen: 0]);
    XCTAssertTrue([BlockManager isSinkholeAddress: @"::" maskLen: 128]);
    XCTAssertTrue([BlockManager isSinkholeAddress: @"127.0.0.1" maskLen: 0]);
    XCTAssertTrue([BlockManager isSinkholeAddress: @"::1" maskLen: 128]);
    XCTAssertFalse([BlockManager isSinkholeAddress: @"0.0.0.0" maskLen: 1]);
    XCTAssertFalse([BlockManager isSinkholeAddress: @"::" maskLen: 1]);
    XCTAssertFalse([BlockManager isSinkholeAddress: @"0.0.0.0" maskLen: 128]);
    XCTAssertFalse([BlockManager isSinkholeAddress: @"93.184.216.34" maskLen: 0]);
    XCTAssertFalse([BlockManager isSinkholeAddress: nil maskLen: 0]);
}

- (void)testPlainAllowlistIsAcceptedByPF {
    PacketFilter* pf = [[PacketFilter alloc] initAsAllowlist: YES];
    [pf addRuleWithIP: @"93.184.216.34" port: 0 maskLen: 0];
    NSString* output = nil;
    XCTAssertEqual(SCPFParseStatus([pf configurationText], &output), 0, @"%@", output);
}

@end

@interface SCPacketFilterStatusTests : XCTestCase
@end

@implementation SCPacketFilterStatusTests

// Sample `pfctl -s info` output (run as root).
- (void)testInfoOutputEnabled {
    NSString* out = @"No ALTQ support in kernel\nALTQ related functions disabled\n"
                     "Status: Enabled for 0 days 01:02:03           Debug: Urgent\n\n"
                     "State Table                          Total             Rate\n"
                     "  current entries                       12               \n";
    XCTAssertTrue([PacketFilter infoOutputShowsEnabled:out]);
}
- (void)testInfoOutputDisabled {
    NSString* out = @"Status: Disabled for 0 days 00:00:41          Debug: Urgent\n";
    XCTAssertFalse([PacketFilter infoOutputShowsEnabled:out]);
}
- (void)testInfoOutputErrorOrEmpty {
    XCTAssertFalse([PacketFilter infoOutputShowsEnabled:@"pfctl: /dev/pf: Permission denied\n"]);
    XCTAssertFalse([PacketFilter infoOutputShowsEnabled:@""]);
    XCTAssertFalse([PacketFilter infoOutputShowsEnabled:nil]);
}

// Sample `pfctl -a org.eyebeam -s rules` output.
- (void)testRulesOutputWithRules {
    NSString* out = @"No ALTQ support in kernel\nALTQ related functions disabled\n"
                     "pass out quick proto udp from any to any port = 123 no state\n"
                     "block return out proto tcp from any to 93.184.216.34\n";
    XCTAssertTrue([PacketFilter rulesOutputHasRules:out]);
    XCTAssertTrue([PacketFilter rulesOutputHasRules:@"  block drop out all\n"]);
}
- (void)testRulesOutputWithoutRules {
    XCTAssertFalse([PacketFilter rulesOutputHasRules:@""]);
    XCTAssertFalse([PacketFilter rulesOutputHasRules:nil]);
    XCTAssertFalse([PacketFilter rulesOutputHasRules:@"No ALTQ support in kernel\nALTQ related functions disabled\n\n"]);
    XCTAssertFalse([PacketFilter rulesOutputHasRules:@"pfctl: Anchor does not exist.\n"]);
    XCTAssertFalse([PacketFilter rulesOutputHasRules:@"pfctl: /dev/pf: Permission denied\n"]);
}

// pf.conf: adding and detecting/removing agree on what "our lines" are.
static NSString* const kAnchorLine = @"anchor \"org.eyebeam\"";
static NSString* const kLoadLine = @"load anchor \"org.eyebeam\" from \"/etc/pf.anchors/org.eyebeam\"";

static NSUInteger SCCountLines(NSString* text, NSString* line) {
    NSUInteger n = 0;
    for (NSString* l in [text componentsSeparatedByString:@"\n"]) if ([l isEqualToString:line]) n++;
    return n;
}

- (void)testConfAddsBothLinesToCleanConf {
    NSString* conf = @"scrub-anchor \"com.apple/*\"\nanchor \"com.apple/*\"\nload anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\"\n";
    XCTAssertFalse([PacketFilter confTextContainsSelfControlLines:conf]);
    NSString* added = [PacketFilter confTextByAddingSelfControlLines:conf];
    XCTAssertEqual(SCCountLines(added, kAnchorLine), 1u);
    XCTAssertEqual(SCCountLines(added, kLoadLine), 1u);
    XCTAssertTrue([added hasPrefix:conf]);
    XCTAssertTrue([PacketFilter confTextContainsSelfControlLines:added]);
    // Idempotent.
    XCTAssertEqualObjects([PacketFilter confTextByAddingSelfControlLines:added], added);
    // Removing gives back the Apple lines only.
    NSString* removed = [PacketFilter confTextByRemovingSelfControlLines:added];
    XCTAssertFalse([PacketFilter confTextContainsSelfControlLines:removed]);
    XCTAssertTrue([removed containsString:@"anchor \"com.apple/*\""]);
}

- (void)testConfAddsOnlyTheMissingLine {
    NSString* onlyLoad = [NSString stringWithFormat:@"anchor \"com.apple/*\"\n%@\n", kLoadLine];
    XCTAssertTrue([PacketFilter confTextContainsSelfControlLines:onlyLoad]);
    NSString* fixed = [PacketFilter confTextByAddingSelfControlLines:onlyLoad];
    XCTAssertEqual(SCCountLines(fixed, kAnchorLine), 1u);
    XCTAssertEqual(SCCountLines(fixed, kLoadLine), 1u);

    NSString* onlyAnchor = [NSString stringWithFormat:@"anchor \"com.apple/*\"\n%@\n", kAnchorLine];
    XCTAssertTrue([PacketFilter confTextContainsSelfControlLines:onlyAnchor]);
    NSString* fixed2 = [PacketFilter confTextByAddingSelfControlLines:onlyAnchor];
    XCTAssertEqual(SCCountLines(fixed2, kAnchorLine), 1u);
    XCTAssertEqual(SCCountLines(fixed2, kLoadLine), 1u);
}

- (void)testConfOtherAnchorsAreNotOurs {
    NSString* conf = @"anchor \"com.apple/*\"\nanchor \"org.eyebeamish\"\n# org.eyebeam mentioned in a comment\n";
    // Prefix match is on the exact quoted anchor name.
    XCTAssertFalse([PacketFilter confTextContainsSelfControlLines:conf]);
    XCTAssertEqualObjects([PacketFilter confTextByRemovingSelfControlLines:conf], conf);
}

- (void)testConfNilIsNeverReplacedWithEmpty {
    XCTAssertNil([PacketFilter confTextByAddingSelfControlLines:nil]);
    XCTAssertNil([PacketFilter confTextByRemovingSelfControlLines:nil]);
    XCTAssertFalse([PacketFilter confTextContainsSelfControlLines:nil]);
}

@end
