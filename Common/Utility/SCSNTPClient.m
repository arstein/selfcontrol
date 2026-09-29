#import "SCSNTPClient.h"

#import "SCTrustedClock.h"

#import <errno.h>
#import <math.h>
#import <netdb.h>
#import <netinet/in.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

static const uint64_t kNTPUnixEpochOffset = 2208988800ull;
#define kNTPNonceLength 8
// A zero timeval means "block forever" for SO_RCVTIMEO/SO_SNDTIMEO, so every
// socket timeout is clamped to at least this value.
static const NSTimeInterval kMinSocketTimeoutSecs = 0.2;

NSArray<NSString*>* SCTimeSourceHosts(void) {
    return @[@"time.apple.com", @"time.cloudflare.com", @"time.google.com"];
}

// Monotonic seconds used only to enforce the overall fetch deadline; immune to
// wall-clock changes.
static NSTimeInterval SCSNTPMonotonicNow(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static void SCSNTPSetSocketTimeout(int socketFD, NSTimeInterval secs) {
    if (!(secs >= kMinSocketTimeoutSecs)) secs = kMinSocketTimeoutSecs; // also catches NaN
    struct timeval timeout = {
        .tv_sec = (time_t)floor(secs),
        .tv_usec = (suseconds_t)((secs - floor(secs)) * 1000000.0),
    };
    if (timeout.tv_sec == 0 && timeout.tv_usec == 0) timeout.tv_usec = 200000;
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

@interface SCSNTPClient ()
+ (nullable NSDate*)queryHost:(NSString*)host
                     deadline:(NSTimeInterval)deadline
            readingAtResponse:(NSDictionary* _Nullable __autoreleasing * _Nullable)outReading;
@end

@implementation SCSNTPClient

+ (NSData*)randomNonce {
    uint8_t nonce[kNTPNonceLength];
    arc4random_buf(nonce, sizeof(nonce));
    return [NSData dataWithBytes:nonce length:sizeof(nonce)];
}

+ (NSData*)makeRequestPacketWithNonce:(NSData*)nonce {
    uint8_t packet[48] = {0};
    packet[0] = 0x23; // LI=0, version=4, mode=3 (client)
    if (nonce.length == kNTPNonceLength) {
        // Transmit timestamp; the server copies it into its originate field.
        memcpy(packet + 40, nonce.bytes, kNTPNonceLength);
    }
    return [NSData dataWithBytes:packet length:sizeof(packet)];
}

+ (NSDate*)dateFromResponsePacket:(NSData*)packet expectedNonce:(NSData*)nonce {
    if (packet.length < 48 || nonce.length != kNTPNonceLength) return nil;

    const uint8_t* bytes = packet.bytes;
    uint8_t leapIndicator = (bytes[0] >> 6) & 0x03;
    uint8_t mode = bytes[0] & 0x07;
    uint8_t stratum = bytes[1];
    // Only unicast server replies (mode 4) answer our request.
    if (leapIndicator == 3 || mode != 4 || stratum == 0 || stratum > 15) {
        return nil;
    }

    // The originate timestamp must echo the transmit timestamp we sent.
    if (memcmp(bytes + 24, nonce.bytes, kNTPNonceLength) != 0) return nil;

    uint32_t seconds = ((uint32_t)bytes[40] << 24) |
                       ((uint32_t)bytes[41] << 16) |
                       ((uint32_t)bytes[42] << 8) |
                       (uint32_t)bytes[43];
    uint32_t fraction = ((uint32_t)bytes[44] << 24) |
                        ((uint32_t)bytes[45] << 16) |
                        ((uint32_t)bytes[46] << 8) |
                        (uint32_t)bytes[47];
    if (seconds == 0) return nil;

    // RFC 4330 section 3: if the most significant bit is clear, the timestamp
    // belongs to NTP era 1 (on or after 2036-02-07T06:28:16Z).
    uint64_t eraSeconds = (uint64_t)seconds;
    if ((seconds & 0x80000000u) == 0) eraSeconds += 0x100000000ull;

    NSTimeInterval unixSeconds = (NSTimeInterval)eraSeconds - (NSTimeInterval)kNTPUnixEpochOffset +
                                 ((NSTimeInterval)fraction / 4294967296.0);
    return [NSDate dateWithTimeIntervalSince1970:unixSeconds];
}

+ (NSDate*)fetchNetworkTimeWithTimeout:(NSTimeInterval)timeoutSecs
                     readingAtResponse:(NSDictionary* __autoreleasing *)outReading {
    if (outReading != NULL) *outReading = nil;
    if (!(timeoutSecs > 0)) return nil;

    NSTimeInterval deadline = SCSNTPMonotonicNow() + timeoutSecs;
    for (NSString* host in SCTimeSourceHosts()) {
        if (SCSNTPMonotonicNow() >= deadline) break;
        NSDictionary* reading = nil;
        NSDate* date = [self queryHost:host deadline:deadline readingAtResponse:&reading];
        if (date != nil && reading != nil) {
            if (outReading != NULL) *outReading = reading;
            return date;
        }
    }
    return nil;
}

+ (NSDate*)queryHost:(NSString*)host
            deadline:(NSTimeInterval)deadline
   readingAtResponse:(NSDictionary* __autoreleasing *)outReading {
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;

    struct addrinfo* results = NULL;
    if (getaddrinfo(host.UTF8String, "123", &hints, &results) != 0 || results == NULL) {
        return nil;
    }

    NSDate* date = nil;
    for (struct addrinfo* address = results; address != NULL && date == nil; address = address->ai_next) {
        NSTimeInterval remaining = deadline - SCSNTPMonotonicNow();
        if (remaining <= 0) break;

        int socketFD = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketFD < 0) continue;
        SCSNTPSetSocketTimeout(socketFD, remaining);

        // Connecting a UDP socket restricts received datagrams to the queried peer.
        if (connect(socketFD, address->ai_addr, address->ai_addrlen) == 0) {
            NSData* nonce = [self randomNonce];
            NSData* request = [self makeRequestPacketWithNonce:nonce];
            if (send(socketFD, request.bytes, request.length, 0) == (ssize_t)request.length) {
                uint8_t reply[48];
                ssize_t received;
                for (;;) {
                    received = recv(socketFD, reply, sizeof(reply), 0);
                    if (received >= 0 || errno != EINTR) break;
                    NSTimeInterval retryRemaining = deadline - SCSNTPMonotonicNow();
                    if (retryRemaining <= 0) break;
                    SCSNTPSetSocketTimeout(socketFD, retryRemaining);
                }
                if (received >= 48) {
                    // Capture the monotonic reading as close to the reply as
                    // possible so it pairs exactly with the verified time.
                    NSDictionary* reading = [SCTrustedClock currentReading];
                    date = [self dateFromResponsePacket:[NSData dataWithBytes:reply length:(NSUInteger)received]
                                          expectedNonce:nonce];
                    if (date != nil && outReading != NULL) *outReading = reading;
                }
            }
        }
        close(socketFD);
    }
    freeaddrinfo(results);
    return date;
}

@end
