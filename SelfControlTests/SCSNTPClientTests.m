#import <XCTest/XCTest.h>

#import "SCSNTPClient.h"

@interface SCSNTPClientTests : XCTestCase
@end

@implementation SCSNTPClientTests

- (void)testRequestPacketShape {
    NSData* packet = [SCSNTPClient makeRequestPacket];
    XCTAssertEqual(packet.length, 48);
    const uint8_t* bytes = packet.bytes;
    XCTAssertEqual(bytes[0], 0x23);
}

- (void)testParseTransmitTimestamp {
    uint8_t raw[48] = {0};
    raw[0] = 0x24;
    raw[1] = 2;
    uint32_t ntpSeconds = 3976214400u; // 2026-01-01T00:00:00Z
    raw[40] = (ntpSeconds >> 24) & 0xFF;
    raw[41] = (ntpSeconds >> 16) & 0xFF;
    raw[42] = (ntpSeconds >> 8) & 0xFF;
    raw[43] = ntpSeconds & 0xFF;
    NSDate* date = [SCSNTPClient dateFromResponsePacket:
        [NSData dataWithBytes:raw length:sizeof(raw)]];
    XCTAssertNotNil(date);
    XCTAssertEqualWithAccuracy(date.timeIntervalSince1970, 1767225600.0, 1.0);
}

- (void)testParseRejectsInvalidPackets {
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:[NSData data]]);

    uint8_t client[48] = {0};
    client[0] = 0x23;
    client[1] = 2;
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:
        [NSData dataWithBytes:client length:sizeof(client)]]);

    uint8_t unsynchronized[48] = {0};
    unsynchronized[0] = 0xE4; // LI=3
    unsynchronized[1] = 2;
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:
        [NSData dataWithBytes:unsynchronized length:sizeof(unsynchronized)]]);

    uint8_t kissOfDeath[48] = {0};
    kissOfDeath[0] = 0x24;
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:
        [NSData dataWithBytes:kissOfDeath length:sizeof(kissOfDeath)]]);

    uint8_t zeroTimestamp[48] = {0};
    zeroTimestamp[0] = 0x24;
    zeroTimestamp[1] = 2;
    XCTAssertNil([SCSNTPClient dateFromResponsePacket:
        [NSData dataWithBytes:zeroTimestamp length:sizeof(zeroTimestamp)]]);
}

@end
