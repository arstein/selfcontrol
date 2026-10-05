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

- (void)testPlainAllowlistIsAcceptedByPF {
    PacketFilter* pf = [[PacketFilter alloc] initAsAllowlist: YES];
    [pf addRuleWithIP: @"93.184.216.34" port: 0 maskLen: 0];
    NSString* output = nil;
    XCTAssertEqual(SCPFParseStatus([pf configurationText], &output), 0, @"%@", output);
}

@end
