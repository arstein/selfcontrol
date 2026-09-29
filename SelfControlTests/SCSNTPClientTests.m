#import <XCTest/XCTest.h>

#import "SCSNTPClient.h"

@interface SCSNTPClientTests : XCTestCase
@end

@implementation SCSNTPClientTests

static NSData* SCTestNonce(void) {
    const uint8_t nonce[8] = {0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x23, 0x45, 0x67};
    return [NSData dataWithBytes:nonce length:sizeof(nonce)];
}

// Builds a server reply with the given header byte, stratum and transmit
// seconds, echoing `nonce` in the originate timestamp when non-nil.
static NSData* SCTestReply(uint8_t header, uint8_t stratum, uint32_t ntpSeconds, NSData* nonce) {
    uint8_t raw[48] = {0};
    raw[0] = header;
    raw[1] = stratum;
    if (nonce != nil) memcpy(raw + 24, nonce.bytes, 8);
    raw[40] = (ntpSeconds >> 24) & 0xFF;
    raw[41] = (ntpSeconds >> 16) & 0xFF;
    raw[42] = (ntpSeconds >> 8) & 0xFF;
    raw[43] = ntpSeconds & 0xFF;
    return [NSData dataWithBytes:raw length:sizeof(raw)];
}

- (void)testRequestPacketShape {
    NSData* nonce = SCTestNonce();
    NSData* packet = [SCSNTPClient makeRequestPacketWithNonce:nonce];
    XCTAssertEqual(packet.length, 48);
    const uint8_t* bytes = packet.bytes;
    XCTAssertEqual(bytes[0], 0x23);
    XCTAssertEqual(memcmp(bytes + 40, nonce.bytes, 8), 0);
}

- (void)testRandomNoncesDiffer {
    NSData* a = [SCSNTPClient randomNonce];
    NSData* b = [SCSNTPClient randomNonce];
    XCTAssertEqual(a.length, 8);
    XCTAssertNotEqualObjects(a, b);
}

- (void)testParseTransmitTimestamp {
    NSData* nonce = SCTestNonce();
    uint32_t ntpSeconds = 3976214400u; // 2026-01-01T00:00:00Z
    NSDate* date = [SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 2, ntpSeconds, nonce)
                                          expectedNonce:nonce];
    XCTAssertNotNil(date);
    XCTAssertEqualWithAccuracy(date.timeIntervalSince1970, 1767225600.0, 1.0);
}

- (void)testParseHandlesNTPEraRollover {
    NSData* nonce = SCTestNonce();
    // Era 1 begins 2036-02-07T06:28:16Z (Unix 2085978496). Seconds field 100
    // has its MSB clear, so it must map to 100s after that, not to 1900.
    NSDate* date = [SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 2, 100, nonce)
                                          expectedNonce:nonce];
    XCTAssertNotNil(date);
    XCTAssertEqualWithAccuracy(date.timeIntervalSince1970, 2085978596.0, 0.001);

    // The last second of era 0 is still interpreted as era 0.
    date = [SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 2, 0xFFFFFFFFu, nonce)
                                  expectedNonce:nonce];
    XCTAssertEqualWithAccuracy(date.timeIntervalSince1970, 2085978495.0, 0.001);
}

- (void)testParseRejectsInvalidPackets {
    NSData* nonce = SCTestNonce();
    uint32_t goodSeconds = 3976214400u;
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:[NSData data] expectedNonce:nonce]);

    // mode 3 (client)
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0x23, 2, goodSeconds, nonce)
                                        expectedNonce:nonce]);
    // mode 5 (broadcast) is not an answer to our request
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0x25, 2, goodSeconds, nonce)
                                        expectedNonce:nonce]);
    // LI=3 (unsynchronized)
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0xE4, 2, goodSeconds, nonce)
                                        expectedNonce:nonce]);
    // stratum 0 (kiss-of-death)
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 0, goodSeconds, nonce)
                                        expectedNonce:nonce]);
    // stratum 16
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 16, goodSeconds, nonce)
                                        expectedNonce:nonce]);
    // zero transmit timestamp
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 2, 0, nonce)
                                        expectedNonce:nonce]);
}

- (void)testParseRejectsNonceMismatch {
    NSData* nonce = SCTestNonce();
    uint32_t goodSeconds = 3976214400u;
    // no originate timestamp echoed
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 2, goodSeconds, nil)
                                        expectedNonce:nonce]);
    // a different nonce echoed
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 2, goodSeconds, [SCSNTPClient randomNonce])
                                        expectedNonce:nonce]);
    // malformed expected nonce
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:SCTestReply(0x24, 2, goodSeconds, nonce)
                                        expectedNonce:[NSData data]]);
}

- (void)testFetchWithNonPositiveTimeoutFailsImmediately {
    NSDictionary* reading = @{@"sentinel": @YES};
    XCTAssertNil([SCSNTPClient fetchNetworkTimeWithTimeout:0 readingAtResponse:&reading]);
    XCTAssertNil(reading);
}

@end
