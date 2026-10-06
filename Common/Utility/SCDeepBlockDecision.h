#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SCLayerBase;   // @"base": the regular block
FOUNDATION_EXPORT NSString* const SCLayerDeep;   // @"deep": the deep block

typedef NS_ENUM(NSInteger, SCDeepAction) {
    SCDeepActionNone = 0,            // no record, nothing installed
    SCDeepActionInstall,             // record present, deep layer missing -> install (tighten, no network)
    SCDeepActionSteady,              // installed and verified
    SCDeepActionSeekVerifiedStart,   // start unverified / re-verification flagged
    SCDeepActionSeekVerifiedExpiry,  // trusted-expired -> verified time is the only removal site
    SCDeepActionHeal                 // can't determine the end (or record missing under installed rules)
};

@interface SCDeepBlockDecision : NSObject
+ (BOOL)durationSecsIsValid:(NSTimeInterval)secs;
/// Why a deep-block start must be refused, or 0 to proceed. In order: 325 a deep
/// block is already enforced (record present OR its rules installed), 326 duration
/// out of range, 302 empty blocklist (an empty allowlist is fine), 327 no clock reading.
+ (NSInteger)startRefusalCodeWithDeepEnforced:(BOOL)deepEnforced
                                 durationSecs:(NSTimeInterval)durationSecs
                                   entryCount:(NSUInteger)entryCount
                                  isAllowlist:(BOOL)isAllowlist
                                clockReadable:(BOOL)clockReadable;
/// Ordered layer names that should be installed. The regular block is lifted only
/// by an override, and an override never lifts it while a deep block is enforced.
/// deepShouldEnforce: YES while the deep block's record exists OR its rules are
/// installed (a tampered-away record must not relax enforcement). Callers removing
/// the deep block on a verified path pass NO explicitly.
+ (NSArray<NSString*>*)desiredLayersWithBaseRunning:(BOOL)baseRunning
                                     overrideActive:(BOOL)overrideActive
                                       deepShouldEnforce:(BOOL)deepShouldEnforce;
+ (SCDeepAction)actionForRecordPresent:(BOOL)recordPresent
                        timingComplete:(BOOL)timingComplete
                        remainingKnown:(BOOL)remainingKnown
                               expired:(BOOL)expired
                       startIsVerified:(BOOL)startIsVerified
                     needsVerification:(BOOL)needsVerification
                        layerInstalled:(BOOL)layerInstalled;
/// YES when the record has a finite duration in (0, SC_DEEP_MAX_SECS], a non-empty clock
/// state, and (if startIsVerified) a usable startWall.
+ (BOOL)recordTimingIsComplete:(nullable NSDictionary*)record;
/// YES when the record's list can be enforced as stored: "blocklist" is an array of
/// strings and "isAllowlist" is an NSNumber. A record failing this is unusable for
/// building rules (callers fall back to the anchor payload, else hold).
+ (BOOL)recordListIsUsable:(nullable NSDictionary*)record;
/// The record's timing in the regular block's settings-key shape, so the
/// existing trusted-timing functions apply unchanged.
+ (NSDictionary*)timingSnapshotForRecord:(nullable id)record;
/// Applies trustedTimingDecisionForSettings: writes (regular-block keys) to a record.
+ (NSDictionary*)record:(nullable id)record byApplyingTimingWrites:(NSDictionary*)writes;
/// YES when a heal is still needed: the record is gone while its layer is installed,
/// or the record's end can't be determined.
+ (BOOL)healNeededForRecord:(nullable NSDictionary*)record
             remainingKnown:(BOOL)remainingKnown
             layerInstalled:(BOOL)layerInstalled;
/// The record a heal writes: verified start of `verifiedNow`, the maximum length, and
/// list/options from the record, filling gaps from the anchor payload. Emergency unlock
/// stays on only if neither source turns it off and one of them says so. nil when
/// there is neither a record nor a payload (nothing to rebuild from).
+ (nullable NSDictionary*)healedRecordFromRecord:(nullable NSDictionary*)record
                                         payload:(nullable NSDictionary*)payload
                                     verifiedNow:(NSDate*)verifiedNow
                                      clockState:(NSDictionary*)clockState;
/// Why a running deep block's list can't take additions: 328 when there's no usable
/// record (none, or tampered/awaiting heal), 329 for an allowlist (adding would
/// loosen it), else 0.
+ (NSInteger)addRefusalCodeForRecord:(nullable NSDictionary*)record;
/// Ordered union: `current` order kept, new entries appended, no duplicates.
+ (NSArray<NSString*>*)blocklist:(NSArray<NSString*>*)current byAdding:(NSArray<NSString*>*)additions;
/// YES when there's nothing to fix: no usable record, or the installed payload's
/// blocklist contains every entry of the record's. NO when a usable record has an
/// entry the payload lacks (including a nil or malformed payload).
+ (BOOL)installedPayload:(nullable NSDictionary*)payload coversRecord:(nullable NSDictionary*)record;
@end

NS_ASSUME_NONNULL_END
