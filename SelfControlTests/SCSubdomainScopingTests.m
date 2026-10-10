#import <XCTest/XCTest.h>
#import "BlockManager.h"

@interface SCSubdomainScopingTests : XCTestCase
@end

@implementation SCSubdomainScopingTests

- (BlockManager*)blocklistManager {
    return [[BlockManager alloc] initAsAllowlist: NO allowLocal: YES includeCommonSubdomains: YES includeLinkedDomains: NO];
}

// .invalid never resolves, so these touch no real network.
- (void)testDeepEntriesBlockOnlyThatAddress {
    NSArray<NSDictionary*>* specs = nil;
    NSArray<NSString*>* domains = nil;
    [[self blocklistManager] resolveEntries: @[@"www.example.invalid", @"cooking.example.invalid"]
                                      specs: &specs hostDomains: &domains];
    NSArray* expected = @[@"cooking.example.invalid", @"www.example.invalid"];
    XCTAssertEqualObjects(domains, expected);
    XCTAssertEqual(specs.count, 0u);
}

- (void)testRegistrableEntryKeepsBroadBlocking {
    NSArray<NSDictionary*>* specs = nil;
    NSArray<NSString*>* domains = nil;
    [[self blocklistManager] resolveEntries: @[@"example.invalid"] specs: &specs hostDomains: &domains];
    NSArray* expected = @[@"example.invalid", @"www.example.invalid"];
    XCTAssertEqualObjects(domains, expected);
}

@end
