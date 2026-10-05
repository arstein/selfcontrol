#import <XCTest/XCTest.h>
#import "SCRuleCompiler.h"
#import "SCDeepBlockDecision.h"
#import "SCPFTestSupport.h"

@interface SCRuleCompilerTests : XCTestCase
@end

@implementation SCRuleCompilerTests

static NSDictionary* S(NSString* ip, NSInteger mask, NSInteger port) {
    return [SCRuleCompiler specWithIP:ip maskLen:mask port:port];
}

static void AssertParses(SCRuleCompilerTests* self, NSString* text) {
    NSString* output = nil;
    XCTAssertEqual(SCPFParseStatus(text, &output), 0, @"pfctl rejected:\n%@\n---\n%@", output, text);
}

- (void)testAddressValidation {
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"1.2.3.4", 0, 0)], @"1.2.3.4");
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"10.0.0.0", 8, 0)], @"10.0.0.0/8");
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"2001:db8::", 32, 0)], @"2001:db8::/32");
    XCTAssertNil([SCRuleCompiler addressForSpec:S(@"23.236.48.0", 240, 0)]);   // the Task 1 bug class
    XCTAssertNil([SCRuleCompiler addressForSpec:S(@"2001:db8::", 129, 0)]);
    XCTAssertNil([SCRuleCompiler addressForSpec:S(@"1.2.3.4; pass all", 0, 0)]);
    XCTAssertNil([SCRuleCompiler addressForSpec:S(nil, 0, 0)]);
}

- (void)testInfrastructureAlwaysFirstAndQuick {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(nil, 0, 0)]]]];
    NSRange ntp = [t rangeOfString:@"pass out quick proto udp from any to any port 123"];
    NSRange dns = [t rangeOfString:@"pass out quick proto { tcp udp } from any to any port 53"];
    NSRange dhcp = [t rangeOfString:@"pass out quick proto { tcp udp } from any to any port { 67 68 5353 }"];
    NSRange firstBlock = [t rangeOfString:@"block "];
    XCTAssertNotEqual(ntp.location, NSNotFound);
    XCTAssertNotEqual(dns.location, NSNotFound);
    XCTAssertNotEqual(dhcp.location, NSNotFound);
    XCTAssertLessThan(dhcp.location, firstBlock.location);
    AssertParses(self, t);
}

- (void)testMarker {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[
        [SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(@"1.2.3.4", 0, 0)]],
        [SCRuleLayer layerWithName:SCLayerDeep isAllowlist:YES allowLocal:NO specs:@[S(@"5.6.7.8", 0, 0)]]]];
    XCTAssertTrue([t hasPrefix:@"# sc-layers: base,deep\n"]);
    XCTAssertEqualObjects([SCRuleCompiler layerNamesFromAnchorText:t], (@[SCLayerBase, SCLayerDeep]));
    XCTAssertEqualObjects([SCRuleCompiler layerNamesFromAnchorText:@"# sc-layers: \nset skip on lo0\n"], @[]);
    XCTAssertNil([SCRuleCompiler layerNamesFromAnchorText:@"# Options\nset block-policy drop\n"]);
    XCTAssertNil([SCRuleCompiler layerNamesFromAnchorText:nil]);
}

- (void)testBlocklistLayer {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[
        S(@"1.2.3.4", 0, 0), S(@"10.0.0.0", 8, 0), S(@"1.2.3.4", 0, 0), S(@"9.9.9.9", 0, 443), S(@"23.236.48.0", 240, 0)]]]];
    XCTAssertTrue([t containsString:@"table <sc_base> persist { 1.2.3.4, 10.0.0.0/8 }"]);
    XCTAssertTrue([t containsString:@"block return out quick proto { tcp udp } from any to <sc_base>"]);
    XCTAssertTrue([t containsString:@"block return out quick proto { tcp udp } from any to 9.9.9.9 port 443"]);
    XCTAssertFalse([t containsString:@"/240"]);
    AssertParses(self, t);
}

- (void)testStarEntries {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(nil, 0, 0), S(nil, 0, 25)]]]];
    XCTAssertTrue([t containsString:@"block return out quick proto { tcp udp } from any to any\n"]);
    XCTAssertTrue([t containsString:@"block return out quick proto { tcp udp } from any to any port 25\n"]);
    AssertParses(self, t);
}

- (void)testAllowlistLayerIgnoresPortsAndAddsLocalRanges {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerDeep isAllowlist:YES allowLocal:YES specs:@[S(@"1.2.3.4", 0, 443), S(@"2001:db8::", 32, 0)]]]];
    XCTAssertTrue([t containsString:@"table <sc_deep> persist { 1.2.3.4, 2001:db8::/32, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"]);
    XCTAssertTrue([t containsString:@"block return out quick proto { tcp udp } from any to ! <sc_deep>"]);
    XCTAssertFalse([t containsString:@"port 443"]);
    AssertParses(self, t);
}

- (void)testEmptyAllowlistBlocksEverything {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerDeep isAllowlist:YES allowLocal:NO specs:@[]]]];
    XCTAssertTrue([t containsString:@"table <sc_deep> persist\n"]);
    XCTAssertTrue([t containsString:@"from any to ! <sc_deep>"]);
    AssertParses(self, t);
}

- (void)testAllowlistStarMeansNoRestriction {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerDeep isAllowlist:YES allowLocal:NO specs:@[S(nil, 0, 0)]]]];
    XCTAssertFalse([t containsString:@"<sc_deep>"]);
    AssertParses(self, t);
}

- (void)testBothLayersTogetherParse {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[
        [SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(@"1.2.3.4", 0, 0)]],
        [SCRuleLayer layerWithName:SCLayerDeep isAllowlist:YES allowLocal:YES specs:@[S(@"5.6.7.8", 0, 0)]]]];
    XCTAssertTrue([t containsString:@"to <sc_base>"]);
    XCTAssertTrue([t containsString:@"to ! <sc_deep>"]);
    AssertParses(self, t);
}

- (void)testNoLayersStillParses {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[]];
    XCTAssertTrue([t hasPrefix:@"# sc-layers: \n"]);
    XCTAssertFalse([t containsString:@"block "]);
    AssertParses(self, t);
}

- (void)testDeepPayloadRoundTrip {
    SCRuleLayer* deep = [SCRuleLayer layerWithName:SCLayerDeep isAllowlist:YES allowLocal:NO specs:@[S(@"1.2.3.4", 0, 0)]];
    deep.payload = @{@"blocklist": @[@"docs.google.com", @"github.com"], @"isAllowlist": @YES};
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[deep]];
    XCTAssertEqualObjects([SCRuleCompiler deepPayloadFromAnchorText:t], (@{@"blocklist": @[@"docs.google.com", @"github.com"], @"isAllowlist": @YES}));
    XCTAssertNil([SCRuleCompiler deepPayloadFromAnchorText:@"# sc-deep: !!!notbase64\n"]);
    XCTAssertNil([SCRuleCompiler deepPayloadFromAnchorText:nil]);
    AssertParses(self, t);
}

@end
