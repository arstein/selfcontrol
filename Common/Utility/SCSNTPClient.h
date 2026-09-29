#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Network time sources used in priority order. Fallbacks improve reachability;
/// they are not a quorum and do not protect against an on-path attacker.
FOUNDATION_EXPORT NSArray<NSString*>* SCTimeSourceHosts(void);

@interface SCSNTPClient : NSObject

/// Builds a client request whose transmit timestamp (bytes 40-47) carries
/// `nonce`, which must be exactly 8 bytes. A valid server reply echoes it in
/// its originate timestamp (bytes 24-31).
+ (NSData*)makeRequestPacketWithNonce:(NSData*)nonce;

/// Returns 8 random bytes suitable for `makeRequestPacketWithNonce:`.
+ (NSData*)randomNonce;

/// Parses a mode-4 (server) reply. Returns nil unless the reply's originate
/// timestamp exactly matches `nonce` and the packet is otherwise sane.
+ (nullable NSDate*)dateFromResponsePacket:(NSData*)packet expectedNonce:(NSData*)nonce;

/// Synchronously queries each configured host over UDP/123 until one answers,
/// spending at most roughly `timeoutSecs` in total across every host and
/// resolved address (DNS resolution itself is not hard-bounded). On success,
/// `outReading` (if non-NULL) receives the SCTrustedClock reading captured
/// immediately after the reply arrived. Call this method off the main thread.
+ (nullable NSDate*)fetchNetworkTimeWithTimeout:(NSTimeInterval)timeoutSecs
                              readingAtResponse:(NSDictionary* _Nullable __autoreleasing * _Nullable)outReading;

@end

NS_ASSUME_NONNULL_END
