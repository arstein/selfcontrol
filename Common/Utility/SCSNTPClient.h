#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Network time sources used in priority order. Fallbacks improve reachability;
/// they are not a quorum and do not protect against an on-path attacker.
FOUNDATION_EXPORT NSArray<NSString*>* SCTimeSourceHosts(void);

@interface SCSNTPClient : NSObject

+ (NSData*)makeRequestPacket;
+ (nullable NSDate*)dateFromResponsePacket:(NSData*)packet;

/// Synchronously queries each configured host over UDP/123 until one answers.
/// Call this method off the main thread.
+ (nullable NSDate*)fetchNetworkTimeWithTimeout:(NSTimeInterval)timeoutSecs;

@end

NS_ASSUME_NONNULL_END
