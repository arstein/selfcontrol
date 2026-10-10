#import <XCTest/XCTest.h>
#import "BlockManager.h"
#import <objc/runtime.h>

// Fake resolver for the tests below: fixed documentation-range addresses, no network.
@implementation BlockManager (SCSubdomainScopingTestResolver)
+ (NSArray*)sc_test_ipAddressesForDomainName:(NSString*)domainName {
    if ([domainName isEqualToString: @"example.invalid"]) return @[@"192.0.2.1"];
    if ([domainName isEqualToString: @"www.example.invalid"]) return @[@"192.0.2.2"];
    if ([domainName isEqualToString: @"cooking.example.invalid"]) return @[@"192.0.2.3"];
    return @[];
}
@end

@interface SCSubdomainScopingTests : XCTestCase
@end

@implementation SCSubdomainScopingTests

- (void)setUp {
    method_exchangeImplementations(class_getClassMethod([BlockManager class], @selector(ipAddressesForDomainName:)),
                                   class_getClassMethod([BlockManager class], @selector(sc_test_ipAddressesForDomainName:)));
}

- (void)tearDown {
    method_exchangeImplementations(class_getClassMethod([BlockManager class], @selector(ipAddressesForDomainName:)),
                                   class_getClassMethod([BlockManager class], @selector(sc_test_ipAddressesForDomainName:)));
}

- (NSArray<NSString*>*)ipsInSpecs:(NSArray<NSDictionary*>*)specs {
    NSMutableArray* ips = [NSMutableArray array];
    for (NSDictionary* spec in specs) if ([spec[@"ip"] isKindOfClass: [NSString class]]) [ips addObject: spec[@"ip"]];
    return [ips sortedArrayUsingSelector: @selector(compare:)];
}

- (BlockManager*)blocklistManager {
    return [[BlockManager alloc] initAsAllowlist: NO allowLocal: YES includeCommonSubdomains: YES includeLinkedDomains: NO];
}

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

// A registrable entry's automatic www. twin is part of "the whole site": it gets
// firewall rules too, as it did before address-only entries existed.
- (void)testRegistrableEntryFirewallsItsWwwTwin {
    NSArray<NSDictionary*>* specs = nil;
    NSArray<NSString*>* domains = nil;
    [[self blocklistManager] resolveEntries: @[@"example.invalid"] specs: &specs hostDomains: &domains];
    NSArray* expected = @[@"192.0.2.1", @"192.0.2.2"];
    XCTAssertEqualObjects([self ipsInSpecs: specs], expected);
}

@end
