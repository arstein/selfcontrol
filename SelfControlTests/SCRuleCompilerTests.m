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
    output = nil;
    XCTAssertEqual(SCPFAnchorParseStatus(text, &output), 0, @"pfctl (anchor mode) rejected:\n%@\n---\n%@", output, text);
}

- (void)testAddressValidation {
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"1.2.3.4", 0, 0)], @"1.2.3.4");
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"10.0.0.0", 8, 0)], @"10.0.0.0/8");
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"2001:db8::", 32, 0)], @"2001:db8::/32");
    XCTAssertNil([SCRuleCompiler addressForSpec:S(@"23.236.48.0", 240, 0)]);   // the Task 1 bug class
    XCTAssertNil([SCRuleCompiler addressForSpec:S(@"2001:db8::", 129, 0)]);
    XCTAssertNil([SCRuleCompiler addressForSpec:S(@"1.2.3.4; pass all", 0, 0)]);
    XCTAssertNil([SCRuleCompiler addressForSpec:S(nil, 0, 0)]);
    for (NSString* bad in @[@"deadbeef", @"abc", @"1.2.3", @"1.2.3.4.5", @"1..2", @":::", @"1.2.3.4:80", @"cafe.ee"]) {
        XCTAssertNil([SCRuleCompiler addressForSpec:S(bad, 0, 0)], @"%@", bad);
    }
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"::1", 0, 0)], @"::1");
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"fe80::1", 0, 0)], @"fe80::1");
    XCTAssertEqualObjects([SCRuleCompiler addressForSpec:S(@"192.168.1.1", 24, 0)], @"192.168.1.1/24");
    XCTAssertNil([SCRuleCompiler addressForSpec:S(@"1.2.3.4", -1, 0)]);
    XCTAssertNil([SCRuleCompiler addressForSpec:S(@"1.2.3.4", 33, 0)]);
}

- (void)testLoopbackPassesFirstAndNoSetOptions {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(nil, 0, 0)]]]];
    NSRange lo = [t rangeOfString:@"pass quick on lo0 all"];
    NSRange firstBlock = [t rangeOfString:@"block "];
    XCTAssertNotEqual(lo.location, NSNotFound);
    XCTAssertLessThan(lo.location, firstBlock.location);
    for (NSString* line in [t componentsSeparatedByString:@"\n"]) XCTAssertFalse([line hasPrefix:@"set "], @"%@", line);
}

- (void)testAllowlistStarWithPortIsIgnored {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerDeep isAllowlist:YES allowLocal:NO specs:@[S(nil, 0, 443), S(@"1.2.3.4", 0, 0)]]]];
    XCTAssertTrue([t containsString:@"table <sc_deep> persist { 1.2.3.4 }"]);
    XCTAssertTrue([t containsString:@"to ! <sc_deep>"]);
    AssertParses(self, t);
}

- (void)testBadAndDuplicateLayerNamesSkipped {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[
        [SCRuleLayer layerWithName:@"de,ep" isAllowlist:NO allowLocal:NO specs:@[S(@"7.7.7.7", 0, 0)]],
        [SCRuleLayer layerWithName:@"" isAllowlist:NO allowLocal:NO specs:@[S(@"7.7.7.8", 0, 0)]],
        [SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(@"1.2.3.4", 0, 0)]],
        [SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(@"5.6.7.8", 0, 0)]]]];
    XCTAssertTrue([t hasPrefix:@"# sc-layers: base\n"]);
    XCTAssertEqual([t componentsSeparatedByString:@"table <sc_base>"].count, 2u);
    XCTAssertFalse([t containsString:@"7.7.7"]);
    XCTAssertFalse([t containsString:@"5.6.7.8"]);
    AssertParses(self, t);
}

- (void)testBlocklistOnlyPortSpecsEmitsNoTable {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(@"9.9.9.9", 0, 443), S(@"8.8.8.8", 32, 80)]]]];
    XCTAssertFalse([t containsString:@"table <sc_base>"]);
    XCTAssertTrue([t containsString:@"to 9.9.9.9 port 443\n"]);
    XCTAssertTrue([t containsString:@"to 8.8.8.8/32 port 80\n"]);
    AssertParses(self, t);
}

- (void)testHostnameInputsDroppedFromBlocklist {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[
        S(@"facebook.com", 0, 0), S(@"www.example.org", 0, 443), S(@"cafe.ee", 0, 0), S(@"deadbeef", 0, 0), S(@"1.2.3.4", 0, 0)]]]];
    XCTAssertTrue([t containsString:@"table <sc_base> persist { 1.2.3.4 }"]);
    XCTAssertFalse([t containsString:@"facebook"]);
    XCTAssertFalse([t containsString:@"example"]);
    XCTAssertFalse([t containsString:@"cafe"]);
    XCTAssertFalse([t containsString:@"deadbeef"]);
    AssertParses(self, t);
}

- (void)testInfrastructureAlwaysFirstAndQuick {
    NSString* t = [SCRuleCompiler anchorTextForLayers:@[[SCRuleLayer layerWithName:SCLayerBase isAllowlist:NO allowLocal:NO specs:@[S(nil, 0, 0)]]]];
    NSRange ntp = [t rangeOfString:@"pass out quick proto udp from any to any port 123"];
    NSRange dns = [t rangeOfString:@"pass out quick proto { tcp udp } from any to any port 53"];
    NSRange dhcp = [t rangeOfString:@"pass out quick proto udp from any to any port { 67 68 546 547 5353 }"];
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
    XCTAssertTrue([t containsString:@"table <sc_deep> persist { 1.2.3.4, 2001:db8::/32, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, fe80::/10, fc00::/7 }"]);
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
