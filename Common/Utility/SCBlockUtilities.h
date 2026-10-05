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

@end

NS_ASSUME_NONNULL_END
