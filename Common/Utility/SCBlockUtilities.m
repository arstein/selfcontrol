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

@implementation SCBlockUtilities

+ (BOOL)anyBlockIsRunning {
    BOOL blockIsRunning = [SCBlockUtilities modernBlockIsRunning] || [SCBlockUtilities legacyBlockIsRunning];

    return blockIsRunning;
}

+ (BOOL)modernBlockIsRunning {
    SCSettings* settings = [SCSettings sharedSettings];
    
    return [settings boolForKey: @"BlockIsRunning"];
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
    SCSettings* settings = [SCSettings sharedSettings];
    NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
    NSNumber* duration = [settings valueForKey:@"BlockDurationSecs"];
    NSDate* start = [settings valueForKey:@"BlockStartWall"];
    if (clockState.count == 0 || duration.doubleValue <= 0 || start == nil) return nil;

    NSDictionary* reading = [SCTrustedClock currentReading];
    if ([settings boolForKey:@"BlockStartIsVerified"]) {
        NSDate* trustedNow = [SCTrustedClock trustedNowForState:clockState reading:reading];
        NSDate* end = [start dateByAddingTimeInterval:duration.doubleValue];
        return @([end timeIntervalSinceDate:trustedNow]);
    }
    return @(duration.doubleValue - [SCTrustedClock elapsedSecsForState:clockState reading:reading]);
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
    [settings setValue: nil forKey: @"BlockStartWall"];
    [settings setValue: @NO forKey: @"BlockStartIsVerified"];
    [settings setValue: nil forKey: @"BlockDurationSecs"];
    [settings setValue: nil forKey: @"TrustedClockState"];
    [settings setValue: @NO forKey: @"TrustedClockNeedsVerification"];
}

@end
