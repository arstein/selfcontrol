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
/// The record's timing in the regular block's settings-key shape, so the
/// existing trusted-timing functions apply unchanged.
+ (NSDictionary*)timingSnapshotForRecord:(nullable id)record;
/// Applies trustedTimingDecisionForSettings: writes (regular-block keys) to a record.
+ (NSDictionary*)record:(nullable id)record byApplyingTimingWrites:(NSDictionary*)writes;
@end

NS_ASSUME_NONNULL_END
