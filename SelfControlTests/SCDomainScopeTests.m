#import <XCTest/XCTest.h>
#import "SCDomainScope.h"

@interface SCDomainScopeTests : XCTestCase
@end

@implementation SCDomainScopeTests

- (void)testRegistrableDomain {
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"nytimes.com"], @"nytimes.com");
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"www.nytimes.com"], @"nytimes.com");
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"a.b.substack.com"], @"substack.com");
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"www.bbc.co.uk"], @"bbc.co.uk");
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"bbc.co.uk"], @"bbc.co.uk");
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"foo.com.au"], @"foo.com.au");
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"WWW.NYTimes.com."], @"nytimes.com");
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"localhost"], @"localhost");
    XCTAssertEqualObjects([SCDomainScope registrableDomainForHostname: @"co.uk"], @"co.uk");
}

- (void)testAddressOnlyEntries {
    NSArray* yes = @[@"www.nytimes.com", @"cooking.nytimes.com", @"danieldrezner.substack.com",
                     @"www.bbc.co.uk", @"mail.google.com"];
    for (NSString* e in yes) {
        XCTAssertTrue([SCDomainScope isAddressOnlyEntry: e], @"%@ should be address-only", e);
    }
}

- (void)testNotAddressOnlyEntries {
    NSArray* no = @[@"nytimes.com", @"bbc.co.uk", @"*", @"1.2.3.4", @"10.0.0.0/8", @"::1",
                    @"www.nytimes.com:443", @"localhost", @""];
    for (NSString* e in no) {
        XCTAssertFalse([SCDomainScope isAddressOnlyEntry: e], @"%@ should not be address-only", e);
    }
    XCTAssertFalse([SCDomainScope isAddressOnlyEntry: nil]);
    XCTAssertFalse([SCDomainScope isAddressOnlyBlockEntry: nil]);
}

// SCBlockEntry splits on "/" and ":" so a pasted URL parses as host "https"
// (one label); the UI strips URLs before they reach the list. Pin that here.
- (void)testURLStyleEntryIsNotAddressOnly {
    XCTAssertFalse([SCDomainScope isAddressOnlyEntry: @"https://www.nytimes.com/section"]);
}

@end
