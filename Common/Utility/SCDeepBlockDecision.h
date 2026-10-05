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
/// by an override, and an override never lifts it while a deep block exists.
+ (NSArray<NSString*>*)desiredLayersWithBaseRunning:(BOOL)baseRunning
                                     overrideActive:(BOOL)overrideActive
                                        deepPresent:(BOOL)deepPresent;
+ (SCDeepAction)actionForRecordPresent:(BOOL)recordPresent
                        timingComplete:(BOOL)timingComplete
                        remainingKnown:(BOOL)remainingKnown
                               expired:(BOOL)expired
                       startIsVerified:(BOOL)startIsVerified
                     needsVerification:(BOOL)needsVerification
                        layerInstalled:(BOOL)layerInstalled;
/// YES when the record has a positive duration and a non-empty clock state.
+ (BOOL)recordTimingIsComplete:(nullable NSDictionary*)record;
/// The record's timing in the regular block's settings-key shape, so the
/// existing trusted-timing functions apply unchanged.
+ (NSDictionary*)timingSnapshotForRecord:(NSDictionary*)record;
/// Applies trustedTimingDecisionForSettings: writes (regular-block keys) to a record.
+ (NSDictionary*)record:(NSDictionary*)record byApplyingTimingWrites:(NSDictionary*)writes;
@end

NS_ASSUME_NONNULL_END
