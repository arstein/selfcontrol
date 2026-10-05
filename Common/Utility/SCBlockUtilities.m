//
//  SCBlockUtilities.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import "SCBlockUtilities.h"
#import "HostFileBlocker.h"
#import "PacketFilter.h"
#import "SCBlockEntry.h"
#import "SCSNTPClient.h"
#import "SCTrustedClock.h"
#import "SCRuleCompiler.h"
#import "SCDeepBlockDecision.h"

NSString* const SCTrustedTimingSettingsWritesKey = @"SettingsWrites";
NSString* const SCTrustedTimingShouldRemoveBlockKey = @"ShouldRemoveBlock";
NSString* const SCTrustedTimingStartWasCorrectedKey = @"StartWasCorrected";
const int SCKillerExitStatusExpiryNotVerified = 75; // EX_TEMPFAIL
NSString* const SCKillerExpiryNotVerifiedMarker = @"SC_KILLER_REFUSED_EXPIRY_NOT_VERIFIED";

@implementation SCBlockUtilities

+ (BOOL)anyBlockIsRunning {
    BOOL blockIsRunning = [SCBlockUtilities modernBlockIsRunning] || [SCBlockUtilities legacyBlockIsRunning];

    return blockIsRunning;
}

+ (BOOL)modernBlockIsRunning {
    SCSettings* settings = [SCSettings sharedSettings];
    
    return [settings boolForKey: @"BlockIsRunning"];
}

+ (BOOL)emergencyUnlockAllowedForSettingsValue:(id)value {
    if (![value isKindOfClass: [NSNumber class]]) return YES;
    return [value boolValue];
}

+ (BOOL)legacyBlockIsRunning {
    // first see if there's a legacy settings file from v3.x
    // which could be in any user's home folder
    NSError* homeDirErr = nil;
    NSArray<NSURL *>* homeDirectoryURLs = [SCMiscUtilities allUserHomeDirectoryURLs: &homeDirErr];
    if (homeDirectoryURLs != nil) {
        for (NSURL* homeDirURL in homeDirectoryURLs) {
            NSString* relativeSettingsPath = [NSString stringWithFormat: @"/Library/Preferences/%@", SCSettings.settingsFileName];
            NSURL* settingsFileURL = [homeDirURL URLByAppendingPathComponent: relativeSettingsPath isDirectory: NO];
            
            if ([SCMigrationUtilities legacyBlockIsRunningInSettingsFile: settingsFileURL]) {
                return YES;
            }
        }
    }

    // nope? OK, how about a lock file from pre-3.0?
    if ([SCMigrationUtilities legacyLockFileExists]) {
        return YES;
    }
    
    // we don't check defaults anymore, though pre-3.0 blocks did
    // have data stored there. That should be covered by the lockfile anyway
    
    return NO;
}

+ (BOOL)currentBlockIsExpired {
    SCSettings* settings = [SCSettings sharedSettings];
    NSNumber* remaining = [self trustedRemainingBlockDurationSecs];
    if (remaining != nil) return remaining.doubleValue <= 0;

    // A block created by the upstream app has no trusted-clock state. Preserve
    // the legacy comparison so upgrading cannot create a permanent block.
    NSDate* endDate = [settings valueForKey:@"BlockEndDate"];
    return endDate == nil || [endDate timeIntervalSinceNow] <= 0;
}

+ (NSNumber*)trustedRemainingBlockDurationSecs {
    return [self trustedRemainingSecsForTimingSnapshot:[self trustedTimingSettingsSnapshot]
                                               reading:[SCTrustedClock currentReading]];
}

+ (NSNumber*)trustedRemainingSecsForTimingSnapshot:(NSDictionary*)snapshot reading:(NSDictionary*)reading {
    NSDictionary* clockState = snapshot[@"TrustedClockState"];
    NSNumber* duration = snapshot[@"BlockDurationSecs"];
    if (![clockState isKindOfClass:[NSDictionary class]] || clockState.count == 0 ||
        ![duration isKindOfClass:[NSNumber class]] || duration.doubleValue <= 0) {
        return nil;
    }

    NSDate* start = [self effectiveBlockStartWallFromSettingsValue:snapshot[@"BlockStartWall"]];
    if ([snapshot[@"BlockStartIsVerified"] boolValue] && start != nil) {
        NSDate* trustedNow = [SCTrustedClock trustedNowForState:clockState reading:reading];
        NSDate* end = [start dateByAddingTimeInterval:duration.doubleValue];
        return @([end timeIntervalSinceDate:trustedNow]);
    }
    // Unverified start (or a verified one whose start was lost): elapsed time
    // since the clock state's anchor never exceeds true time since block start,
    // so this over-estimates what remains. Never fall back to the wall clock.
    return @(duration.doubleValue - [SCTrustedClock elapsedSecsForState:clockState reading:reading]);
}

+ (NSDictionary*)deepBlockRecord {
    id record = [[SCSettings sharedSettings] valueForKey:@"DeepBlock"];
    return [record isKindOfClass:[NSDictionary class]] ? record : nil;
}

+ (BOOL)deepBlockIsRunning {
    return [self deepBlockRecord] != nil;
}

+ (NSNumber*)trustedRemainingDeepBlockSecs {
    NSDictionary* record = [self deepBlockRecord];
    if (record == nil) return nil;
    return [self trustedRemainingSecsForTimingSnapshot:[SCDeepBlockDecision timingSnapshotForRecord:record]
                                               reading:[SCTrustedClock currentReading]];
}

+ (void)removeDeepBlockFromSettings {
    [[SCSettings sharedSettings] setValue:nil forKey:@"DeepBlock"];
}

+ (NSArray<NSString*>*)installedLayerNames {
    BOOL anchorPresent = [PacketFilter blockFoundInPF];
    BOOL hostsPresent = [HostFileBlocker blockFoundInHostsFile];
    NSString* text = anchorPresent ? [NSString stringWithContentsOfFile:@"/etc/pf.anchors/org.eyebeam" encoding:NSUTF8StringEncoding error:nil] : nil;
    return [self installedLayerNamesForAnchorPresent:anchorPresent hostsPresent:hostsPresent
                                          anchorText:text deepRecordPresent:[self deepBlockIsRunning]];
}

+ (NSArray<NSString*>*)installedLayerNamesForAnchorPresent:(BOOL)anchorPresent
                                              hostsPresent:(BOOL)hostsPresent
                                                anchorText:(NSString*)anchorText
                                         deepRecordPresent:(BOOL)deepRecordPresent {
    if (anchorPresent) {
        // Rules written before layers existed belong to the regular block.
        return [SCRuleCompiler layerNamesFromAnchorText:anchorText] ?: @[SCLayerBase];
    }
    if (hostsPresent) return deepRecordPresent ? @[] : @[SCLayerBase];
    return @[];
}

+ (BOOL)baseRulesFoundOnSystem {
    return [[self installedLayerNames] containsObject:SCLayerBase];
}

+ (BOOL)emergencyUnlockAllowedForCurrentBlocks {
    return [self emergencyUnlockAllowedWithBaseRunning:[self modernBlockIsRunning]
                                             baseValue:[[SCSettings sharedSettings] valueForKey:@"EmergencyUnlockEnabled"]
                                            deepRecord:[self deepBlockRecord]];
}

+ (BOOL)emergencyUnlockAllowedWithBaseRunning:(BOOL)baseRunning baseValue:(id)baseValue deepRecord:(NSDictionary*)deepRecord {
    if (baseRunning) return [self emergencyUnlockAllowedForSettingsValue:baseValue];
    if (deepRecord != nil) return [self emergencyUnlockAllowedForSettingsValue:deepRecord[@"emergencyUnlockEnabled"]];
    return YES;
}

+ (NSDate*)effectiveBlockStartWallFromSettingsValue:(id)value {
    if (![value isKindOfClass:[NSDate class]]) return nil;
    NSDate* date = value;
    if ([date timeIntervalSinceDate:[NSDate distantPast]] <= 0) return nil;
    return date;
}

+ (NSDictionary*)trustedTimingSettingsSnapshot {
    SCSettings* settings = [SCSettings sharedSettings];
    NSMutableDictionary* snapshot = [NSMutableDictionary dictionary];
    for (NSString* key in @[@"BlockStartWall", @"BlockStartIsVerified", @"BlockDurationSecs", @"TrustedClockState"]) {
        id value = [settings valueForKey:key];
        if (value != nil) snapshot[key] = value;
    }
    return snapshot;
}

+ (NSDictionary*)trustedTimingDecisionForSettings:(NSDictionary*)settingsSnapshot
                                      verifiedNow:(NSDate*)verifiedNow
                                          reading:(NSDictionary*)reading {
    if (![verifiedNow isKindOfClass:[NSDate class]] || reading.count == 0 ||
        ![reading[@"mach"] isKindOfClass:[NSNumber class]] || reading[@"boot"] == nil) {
        return nil;
    }
    NSDictionary* clockState = settingsSnapshot[@"TrustedClockState"];
    NSNumber* duration = settingsSnapshot[@"BlockDurationSecs"];
    if (![clockState isKindOfClass:[NSDictionary class]] || clockState.count == 0 ||
        ![duration isKindOfClass:[NSNumber class]] || duration.doubleValue <= 0) {
        return nil;
    }

    BOOL startIsVerified = [settingsSnapshot[@"BlockStartIsVerified"] boolValue];
    NSDate* start = [self effectiveBlockStartWallFromSettingsValue:settingsSnapshot[@"BlockStartWall"]];
    // Once verified, the clock state is rebased on every verification, so the
    // start can no longer be reconstructed from elapsed time. Without it we
    // cannot decide; keep the block.
    if (startIsVerified && start == nil) return nil;

    // The daemon re-anchors at launch after a reboot. A caller that bypasses
    // the daemon (SCKillerHelper) may hold state from an earlier boot; re-anchor
    // it the same conservative way so prior-boot time is credited only from the
    // monotonic checkpoint and the unknown gap counts as zero.
    if (![clockState[@"bootSessionID"] isEqual:reading[@"boot"]]) {
        clockState = [SCTrustedClock reanchoredStateAfterBootChange:clockState reading:reading];
    }

    NSMutableDictionary* writes = [NSMutableDictionary dictionary];
    BOOL correctStart = !startIsVerified;
    if (correctStart) {
        // Monotonic elapsed never exceeds true elapsed, so this start is never
        // earlier than the true start: correction can only lengthen the block.
        start = [SCTrustedClock correctedStartForState:clockState verifiedNow:verifiedNow reading:reading];
        writes[@"BlockStartWall"] = start;
        writes[@"BlockEndDate"] = [start dateByAddingTimeInterval:duration.doubleValue];
    }
    writes[@"BlockStartIsVerified"] = @YES;

    // Rebase the local estimate on every successful verification. This makes
    // post-reboot countdowns accurate without ever trusting a wall-clock gap.
    NSMutableDictionary* verifiedReading = [reading mutableCopy];
    verifiedReading[@"wall"] = verifiedNow;
    writes[@"TrustedClockState"] = [SCTrustedClock freshStateWithReading:verifiedReading];
    writes[@"TrustedClockNeedsVerification"] = @NO;

    BOOL shouldRemove = [verifiedNow timeIntervalSinceDate:start] >= duration.doubleValue;
    return @{
        SCTrustedTimingSettingsWritesKey: writes,
        SCTrustedTimingShouldRemoveBlockKey: @(shouldRemove),
        SCTrustedTimingStartWasCorrectedKey: @(correctStart),
    };
}

+ (NSArray<NSString*>*)blocklistByRemovingTimeSources:(NSArray<NSString*>*)blocklist {
    NSSet<NSString*>* timeSources = [NSSet setWithArray:SCTimeSourceHosts()];
    NSMutableArray<NSString*>* filtered = [NSMutableArray arrayWithCapacity:blocklist.count];
    for (NSString* rawEntry in blocklist) {
        SCBlockEntry* entry = [SCBlockEntry entryFromString:rawEntry];
        NSString* hostname = entry.hostname.lowercaseString;
        while ([hostname hasSuffix:@"."]) {
            hostname = [hostname substringToIndex:hostname.length - 1];
        }
        if (hostname != nil && [timeSources containsObject:hostname]) continue;
        [filtered addObject:rawEntry];
    }
    return filtered;
}

+ (BOOL)blockRulesFoundOnSystem {
    return [PacketFilter blockFoundInPF] || [HostFileBlocker blockFoundInHostsFile];
}

+ (void) removeBlockFromSettings {
    SCSettings* settings = [SCSettings sharedSettings];
    [settings setValue: @NO forKey: @"BlockIsRunning"];
    [settings setValue: nil forKey: @"BlockEndDate"];
    [settings setValue: nil forKey: @"ActiveBlocklist"];
    [settings setValue: nil forKey: @"ActiveBlockAsWhitelist"];
    // Stale override state must not outlive its block.
    [settings setValue: nil forKey: @"OverrideState"];
    [settings setValue: nil forKey: @"OverridePolicy"];
    [settings setValue: nil forKey: @"EmergencyUnlockEnabled"];
    [settings setValue: nil forKey: @"ActivationTimeZone"];
    [self clearTrustedTimingSettings];
}

+ (void)clearTrustedTimingSettings {
    SCSettings* settings = [SCSettings sharedSettings];
    [settings setValue: nil forKey: @"BlockStartWall"];
    [settings setValue: @NO forKey: @"BlockStartIsVerified"];
    [settings setValue: nil forKey: @"BlockDurationSecs"];
    [settings setValue: nil forKey: @"TrustedClockState"];
    [settings setValue: @NO forKey: @"TrustedClockNeedsVerification"];
}

@end
