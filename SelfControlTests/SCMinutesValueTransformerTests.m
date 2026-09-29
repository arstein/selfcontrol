//
//  SCMinutesValueTransformerTests.m
//  SelfControlTests
//
//  Regression tests for the block-duration slider freeze: the transformer must
//  support reverse transformation, or dragging the slider raises and wedges the
//  window's mouse-event handling.
//

#import <XCTest/XCTest.h>
#import "SCMinutesValueTransformer.h"

@interface SCMinutesValueTransformerTests : XCTestCase
@end

@implementation SCMinutesValueTransformerTests

- (void)testAllowsReverseTransformation {
    // The whole bug: a read-write, continuously-updating slider binding needs
    // this to be YES or the write-back raises.
    XCTAssertTrue([SCMinutesValueTransformer allowsReverseTransformation]);
}

- (void)testForwardRoundsToWholeMinutes {
    SCMinutesValueTransformer* t = [SCMinutesValueTransformer new];
    XCTAssertEqualObjects([t transformedValue: @(4.4)], @4);
    XCTAssertEqualObjects([t transformedValue: @(4.6)], @5);
    XCTAssertEqualObjects([t transformedValue: @120], @120);
}

- (void)testReverseRoundsToWholeMinutesAndDoesNotRaise {
    SCMinutesValueTransformer* t = [SCMinutesValueTransformer new];
    XCTAssertNoThrow([t reverseTransformedValue: @(4.4)]);
    XCTAssertEqualObjects([t reverseTransformedValue: @(4.4)], @4);
    XCTAssertEqualObjects([t reverseTransformedValue: @(4.6)], @5);
}

- (void)testNonNumericInputsAreSafe {
    SCMinutesValueTransformer* t = [SCMinutesValueTransformer new];
    XCTAssertEqualObjects([t transformedValue: nil], @0);
    XCTAssertEqualObjects([t reverseTransformedValue: nil], @0);
    XCTAssertEqualObjects([t reverseTransformedValue: @"not a number"], @0);
}

@end
