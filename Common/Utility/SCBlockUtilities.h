//
//  SCBlockUtilities.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keys in the dictionary returned by trustedTimingDecisionForSettings:...
FOUNDATION_EXPORT NSString* const SCTrustedTimingSettingsWritesKey;   // NSDictionary: settings key -> new value
FOUNDATION_EXPORT NSString* const SCTrustedTimingShouldRemoveBlockKey; // NSNumber (BOOL)
FOUNDATION_EXPORT NSString* const SCTrustedTimingStartWasCorrectedKey; // NSNumber (BOOL)

// SCKillerHelper exits with this status (and prints the marker line on stdout,
// which is the only channel AuthorizationExecuteWithPrivileges gives the app)
// when it refuses to clear a block because network time does not confirm that
// the block has expired.
FOUNDATION_EXPORT const int SCKillerExitStatusExpiryNotVerified;
FOUNDATION_EXPORT NSString* const SCKillerExpiryNotVerifiedMarker;

@interface SCBlockUtilities : NSObject

// uses the below methods as well as filesystem checks to see if the block is REALLY running or not
+ (BOOL)anyBlockIsRunning;
+ (BOOL)modernBlockIsRunning;
// Whether the current block allows emergency unlock, given the raw SCSettings
// "EmergencyUnlockEnabled" value. Missing or non-NSNumber means YES, so blocks
// started before the setting existed behave as before.
+ (BOOL)emergencyUnlockAllowedForSettingsValue:(nullable id)value;
+ (BOOL)legacyBlockIsRunning;

+ (BOOL)currentBlockIsExpired;
+ (nullable NSNumber*)trustedRemainingBlockDurationSecs;

/// Remaining seconds for any block's timing snapshot (regular-block key shape);
/// nil when it can't be determined. Never falls back to the wall clock.
+ (nullable NSNumber*)trustedRemainingSecsForTimingSnapshot:(NSDictionary*)snapshot reading:(NSDictionary*)reading;

/// The running deep block's record (SCSettings "DeepBlock"), or nil.
+ (nullable NSDictionary*)deepBlockRecord;
/// YES when a deep-block record exists. Enforcement also continues while the deep
/// layer's rules are installed without a record (see installedLayerNames).
+ (BOOL)deepBlockIsRunning;
+ (nullable NSNumber*)trustedRemainingDeepBlockSecs;
/// Does not sync; callers sync.
+ (void)removeDeepBlockFromSettings;

/// Which layers' rules are on the system now. Reads files (pf.conf, the anchor,
/// and hosts when the anchor is absent), so it is not free. An anchor without a
/// "# sc-layers:" marker counts as the regular block. A hosts-only remnant counts
/// as the regular block unless a deep record exists (documented trade-off: exploiting
/// it requires settings tampering, and it avoids a spurious regular-block self-heal
/// from a deep blocklist's own hosts entries).
+ (NSArray<NSString*>*)installedLayerNames;
+ (NSArray<NSString*>*)installedLayerNamesForAnchorPresent:(BOOL)anchorPresent
                                              hostsPresent:(BOOL)hostsPresent
                                                anchorText:(nullable NSString*)anchorText
                                         deepRecordPresent:(BOOL)deepRecordPresent;
/// The regular block's rules specifically (not just any SelfControl rules).
+ (BOOL)baseRulesFoundOnSystem;

/// Emergency unlock follows the regular block's captured setting when one is
/// running, otherwise the deep block's.
+ (BOOL)emergencyUnlockAllowedForCurrentBlocks;
/// Pure decision. With no regular block and no deep record, an installed deep
/// layer (rules without a record) disallows unlock unless `deepPayload` (from the
/// anchor) carries emergencyUnlockEnabled = YES - except when `deepPayload` is nil:
/// with neither record nor payload the layer can never be rebuilt or expire, so
/// unlock is allowed (no permanent block). With nothing installed it is allowed.
+ (BOOL)emergencyUnlockAllowedWithBaseRunning:(BOOL)baseRunning baseValue:(nullable id)baseValue deepRecord:(nullable NSDictionary*)deepRecord
                           deepLayerInstalled:(BOOL)deepLayerInstalled deepPayload:(nullable NSDictionary*)deepPayload;

+ (NSArray<NSString*>*)blocklistByRemovingTimeSources:(NSArray<NSString*>*)blocklist;

/// Returns the stored block start as a usable date, or nil when the value is
/// missing, not a date, or the SCSettings default ([NSDate distantPast]).
+ (nullable NSDate*)effectiveBlockStartWallFromSettingsValue:(nullable id)value;

/// The settings consulted by trustedTimingDecisionForSettings:..., read from
/// SCSettings (BlockStartWall, BlockStartIsVerified, BlockDurationSecs,
/// TrustedClockState). Missing values are omitted.
+ (NSDictionary*)trustedTimingSettingsSnapshot;

/// Pure decision for a freshly verified network time. Given a settings snapshot
/// and the SCTrustedClock reading captured when `verifiedNow` arrived, corrects
/// an unverified start (verifiedNow - monotonic elapsed, which can only move
/// the start later than the true start), rebases the clock state on the
/// verified time, and decides whether the block has genuinely ended.
/// Returns nil (take no action; the block stays) when the snapshot lacks the
/// trusted-timing state needed to decide.
+ (nullable NSDictionary*)trustedTimingDecisionForSettings:(NSDictionary*)settingsSnapshot
                                               verifiedNow:(NSDate*)verifiedNow
                                                   reading:(NSDictionary*)reading;

+ (BOOL)blockRulesFoundOnSystem;

/// Clears the fork's trusted-timing keys from SCSettings.
+ (void)clearTrustedTimingSettings;

+ (void)removeBlockFromSettings;

// The successive end dates for extending a block from `fromEnd` to `toEnd`, each
// at most `maxStepSecs` after the previous one; the last is `toEnd`. Empty when
// `toEnd` isn't later. (The helper accepts at most a day per extension.)
+ (NSArray<NSDate*>*)extensionStepsFromEndDate:(NSDate*)fromEnd toEndDate:(NSDate*)toEnd maxStepSecs:(NSTimeInterval)maxStepSecs;

@end

NS_ASSUME_NONNULL_END
