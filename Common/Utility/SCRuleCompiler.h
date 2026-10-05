#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface SCRuleLayer : NSObject
@property (nonatomic, copy) NSString* name;        // SCLayerBase / SCLayerDeep
@property (nonatomic) BOOL isAllowlist;
@property (nonatomic) BOOL allowLocal;             // allowlist only: allow RFC 1918 + link-local
@property (nonatomic, copy) NSArray<NSDictionary*>* specs;
/// Written as a "# sc-deep:" line so a tampered-away deep record can be rebuilt.
@property (nonatomic, copy, nullable) NSDictionary* payload;
+ (instancetype)layerWithName:(NSString*)name isAllowlist:(BOOL)isAllowlist allowLocal:(BOOL)allowLocal specs:(NSArray<NSDictionary*>*)specs;
@end

@interface SCRuleCompiler : NSObject
+ (NSDictionary*)specWithIP:(nullable NSString*)ip maskLen:(NSInteger)maskLen port:(NSInteger)port;
/// "ip" or "ip/mask"; nil when the spec is `*` or malformed (never emitted).
/// The IP must be a valid IPv4 or IPv6 literal (inet_pton); hostnames and
/// partial addresses are rejected. Mask 0 = bare host; negative or above 32
/// (IPv4) / 128 (IPv6) is rejected.
+ (nullable NSString*)addressForSpec:(NSDictionary*)spec;
/// Full text of /etc/pf.anchors/org.eyebeam. Every block rule is `quick`, so
/// layer order never matters: a packet passes only if no layer blocks it.
/// Loopback and infrastructure (NTP, DNS, DHCP/DHCPv6, mDNS) pass first and
/// can never be blocked. No `set` options are emitted (pf ignores them in an
/// anchor). Layers with a name that is not non-empty lowercase [a-z]+, or that
/// repeats an earlier name, are skipped. Allowlist: a portless `*` spec lifts
/// the restriction; a `*:port` spec is ignored.
+ (NSString*)anchorTextForLayers:(NSArray<SCRuleLayer*>*)layers;
/// Layer names from the "# sc-layers:" marker; nil when there is no marker.
+ (nullable NSArray<NSString*>*)layerNamesFromAnchorText:(nullable NSString*)text;
/// The deep payload ({blocklist: [String], isAllowlist: Bool}, plus emergencyUnlockEnabled
/// when the payload carries it as a number/boolean); nil if absent or unreadable.
+ (nullable NSDictionary*)deepPayloadFromAnchorText:(nullable NSString*)text;
@end

NS_ASSUME_NONNULL_END
