#import "SCSNTPClient.h"

#import <netdb.h>
#import <netinet/in.h>
#import <math.h>
#import <sys/socket.h>
#import <unistd.h>

static const uint64_t kNTPUnixEpochOffset = 2208988800ull;

NSArray<NSString*>* SCTimeSourceHosts(void) {
    return @[@"time.apple.com", @"time.cloudflare.com", @"time.google.com"];
}

@interface SCSNTPClient ()
+ (nullable NSDate*)queryHost:(NSString*)host timeout:(NSTimeInterval)timeoutSecs;
@end

@implementation SCSNTPClient

+ (NSData*)makeRequestPacket {
    uint8_t packet[48] = {0};
    packet[0] = 0x23; // LI=0, version=4, mode=3 (client)
    return [NSData dataWithBytes:packet length:sizeof(packet)];
}

+ (NSDate*)dateFromResponsePacket:(NSData*)packet {
    if (packet.length < 48) return nil;

    const uint8_t* bytes = packet.bytes;
    uint8_t leapIndicator = (bytes[0] >> 6) & 0x03;
    uint8_t mode = bytes[0] & 0x07;
    uint8_t stratum = bytes[1];
    if (leapIndicator == 3 || (mode != 4 && mode != 5) || stratum == 0 || stratum > 15) {
        return nil;
    }

    uint32_t seconds = ((uint32_t)bytes[40] << 24) |
                       ((uint32_t)bytes[41] << 16) |
                       ((uint32_t)bytes[42] << 8) |
                       (uint32_t)bytes[43];
    uint32_t fraction = ((uint32_t)bytes[44] << 24) |
                        ((uint32_t)bytes[45] << 16) |
                        ((uint32_t)bytes[46] << 8) |
                        (uint32_t)bytes[47];
    if (seconds == 0) return nil;

    NSTimeInterval unixSeconds = (NSTimeInterval)seconds - (NSTimeInterval)kNTPUnixEpochOffset +
                                 ((NSTimeInterval)fraction / 4294967296.0);
    return [NSDate dateWithTimeIntervalSince1970:unixSeconds];
}

+ (NSDate*)fetchNetworkTimeWithTimeout:(NSTimeInterval)timeoutSecs {
    for (NSString* host in SCTimeSourceHosts()) {
        NSDate* date = [self queryHost:host timeout:timeoutSecs];
        if (date != nil) return date;
    }
    return nil;
}

+ (NSDate*)queryHost:(NSString*)host timeout:(NSTimeInterval)timeoutSecs {
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
        int socketFD = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketFD < 0) continue;

        struct timeval timeout = {
            .tv_sec = (int)timeoutSecs,
            .tv_usec = (int)((timeoutSecs - floor(timeoutSecs)) * 1000000.0),
        };
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        // Connecting a UDP socket restricts received datagrams to the queried peer.
        if (connect(socketFD, address->ai_addr, address->ai_addrlen) == 0) {
            NSData* request = [self makeRequestPacket];
            if (send(socketFD, request.bytes, request.length, 0) == (ssize_t)request.length) {
                uint8_t reply[48];
                ssize_t received = recv(socketFD, reply, sizeof(reply), 0);
                if (received >= 48) {
                    date = [self dateFromResponsePacket:
                        [NSData dataWithBytes:reply length:(NSUInteger)received]];
                }
            }
        }
        close(socketFD);
    }
    freeaddrinfo(results);
    return date;
}

@end
