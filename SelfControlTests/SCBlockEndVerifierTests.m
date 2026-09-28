#import <XCTest/XCTest.h>

#import "SCBlockEndVerifier.h"

@interface SCBlockEndVerifierTests : XCTestCase
@end

@implementation SCBlockEndVerifierTests

- (void)testBackoffSchedule {
    XCTAssertEqual([SCBlockEndVerifier retryIntervalForFailureCount:0], 5);
    XCTAssertEqual([SCBlockEndVerifier retryIntervalForFailureCount:1], 10);
    XCTAssertEqual([SCBlockEndVerifier retryIntervalForFailureCount:2], 30);
    XCTAssertEqual([SCBlockEndVerifier retryIntervalForFailureCount:3], 60);
    XCTAssertEqual([SCBlockEndVerifier retryIntervalForFailureCount:4], 300);
    XCTAssertEqual([SCBlockEndVerifier retryIntervalForFailureCount:99], 300);
}

- (void)testVerifiedEndDecision {
    NSDate* start = [NSDate dateWithTimeIntervalSince1970:1000];
    XCTAssertFalse([SCBlockEndVerifier
        verifiedTime:[NSDate dateWithTimeIntervalSince1970:1599]
        satisfiesEndForStart:start
        durationSecs:600]);
    XCTAssertTrue([SCBlockEndVerifier
        verifiedTime:[NSDate dateWithTimeIntervalSince1970:1600]
        satisfiesEndForStart:start
        durationSecs:600]);
}

@end
