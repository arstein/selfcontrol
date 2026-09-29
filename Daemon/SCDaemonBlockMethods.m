//
//  SCDaemonBlockMethods.m
//  org.eyebeam.selfcontrold
//
//  Created by Charlie Stigler on 7/4/20.
//

#import "SCDaemonBlockMethods.h"
#import "SCSettings.h"
#import "SCHelperToolUtilities.h"
#import "PacketFilter.h"
#import "BlockManager.h"
#import "SCDaemon.h"
#import "LaunchctlHelper.h"
#import "HostFileBlockerSet.h"
#import "SCBlockEndVerifier.h"
#import "SCTrustedClock.h"
#import "SCTediumChallenge.h"
#import "SCTediumConfig.h"
#import "SCEnforcementDecision.h"
#import "SCEnforcementConfig.h"

NSTimeInterval METHOD_LOCK_TIMEOUT = 5.0;
NSTimeInterval CHECKUP_LOCK_TIMEOUT = 0.5; // use a shorter lock timeout for checkups, because we'd prefer not to have tons pile up

@interface SCDaemonBlockMethods ()
+ (void)handleVerifiedTime:(NSDate*)verifiedNow
                   reading:(NSDictionary*)reading
                generation:(NSUInteger)generation;
+ (void)handleSelfHealVerifiedTime:(NSDate*)verifiedNow
                           reading:(NSDictionary*)reading
                        generation:(NSUInteger)generation;
@end

// Single daemon-held tedium override challenge instance. All access is
// serialized under daemonMethodLock (see startTediumChallengeWithReply: and
// submitTediumEntry:reply:).
static SCTediumChallenge* tediumChallenge = nil;

@implementation SCDaemonBlockMethods

+ (NSLock*)daemonMethodLock {
    static NSLock* lock = nil;
    if (lock == nil) {
        lock = [[NSLock alloc] init];
    }
    return lock;
}

+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply timeout:(NSTimeInterval)timeout {
    // only run one request at a time, so we avoid weird situations like trying to run a checkup while we're starting a block
    if (![self.daemonMethodLock lockBeforeDate: [NSDate dateWithTimeIntervalSinceNow: timeout]]) {
        // if we couldn't get a lock within 10 seconds, something is weird
        // but we probably shouldn't still run, because that's just unexpected at that point
        // don't capture this error on Sentry because it's very usual for checkups to timeout
        NSError* err = [SCErr errorWithCode: 300];
        NSLog(@"ERROR: Timed out acquiring request lock (after %f seconds)", timeout);

        if (reply != nil) {
            reply(err);
        }
        return NO;
    }
    return YES;
}
+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply {
    return [self lockOrTimeout: reply timeout: METHOD_LOCK_TIMEOUT];
}


+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    // we reset at the _end_ of every method, but we'll also reset at the _start_ here
    // because startBlock can sometimes take a while, and it'd be a shame if the daemon killed itself
    // before we were done
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    
    [SCSentry addBreadcrumb: @"Daemon method startBlock called" category: @"daemon"];
    
    if ([SCBlockUtilities anyBlockIsRunning]) {
        NSLog(@"ERROR: Can't start block since a block is already running");
        NSError* err = [SCErr errorWithCode: 301];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    // A new block starting means any tedium override progress against the
    // old block (if any) can never carry forward.
    [SCDaemonBlockMethods invalidateTediumChallenge];

    // clear any legacy block information - no longer useful and could potentially confuse things
    // but first, copy it over one more time (this should've already happened once in the app, but you never know)
    if ([SCMigrationUtilities legacySettingsFoundForUser: controllingUID]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults: controllingUID];
        [SCMigrationUtilities clearLegacySettingsForUser: controllingUID];
        
        // if we had legacy settings, there's a small chance the old helper tool could still be around
        // make sure it's dead and gone
        [LaunchctlHelper unloadLaunchdJobWithPlistAt: @"/Library/LaunchDaemons/org.eyebeam.SelfControl.plist"];
    }

    SCSettings* settings = [SCSettings sharedSettings];
    NSArray<NSString*>* filteredBlocklist = [SCBlockUtilities blocklistByRemovingTimeSources:blocklist];
    if (filteredBlocklist.count != blocklist.count) {
        NSLog(@"WARNING: removed trusted time-source hostnames from requested blocklist");
    }
    // update SCSettings with the blocklist and end date that've been requested
    [settings setValue: filteredBlocklist forKey: @"ActiveBlocklist"];
    [settings setValue: @(isAllowlist) forKey: @"ActiveBlockAsWhitelist"];
    [settings setValue: endDate forKey: @"BlockEndDate"];

    NSDictionary* clockReading = [SCTrustedClock currentReading];
    NSDate* startWall = clockReading[@"wall"];
    NSTimeInterval durationSecs = [endDate timeIntervalSinceDate:startWall];
    if (durationSecs < 0) durationSecs = 0;
    [settings setValue:startWall forKey:@"BlockStartWall"];
    [settings setValue:@(durationSecs) forKey:@"BlockDurationSecs"];
    [settings setValue:@NO forKey:@"BlockStartIsVerified"];
    [settings setValue:[SCTrustedClock freshStateWithReading:clockReading] forKey:@"TrustedClockState"];
    [settings setValue:@YES forKey:@"TrustedClockNeedsVerification"];
    [[SCBlockEndVerifier sharedVerifier] reset];
    
    // update all the settings for the block, which we're basically just copying from defaults to settings
    [settings setValue: blockSettings[@"ClearCaches"] forKey: @"ClearCaches"];
    [settings setValue: blockSettings[@"AllowLocalNetworks"] forKey: @"AllowLocalNetworks"];
    [settings setValue: blockSettings[@"EvaluateCommonSubdomains"] forKey: @"EvaluateCommonSubdomains"];
    [settings setValue: blockSettings[@"IncludeLinkedDomains"] forKey: @"IncludeLinkedDomains"];
    [settings setValue: blockSettings[@"BlockSoundShouldPlay"] forKey: @"BlockSoundShouldPlay"];
    [settings setValue: blockSettings[@"BlockSound"] forKey: @"BlockSound"];
    [settings setValue: blockSettings[@"EnableErrorReporting"] forKey: @"EnableErrorReporting"];

    if ((filteredBlocklist.count <= 0 && !isAllowlist) || [SCBlockUtilities currentBlockIsExpired]) {
        NSLog(@"ERROR: Blocklist is empty, or block end date is in the past");
        NSLog(@"Block End Date: %@ (%@), vs now is %@", [settings valueForKey: @"BlockEndDate"], [[settings valueForKey: @"BlockEndDate"] class], [NSDate date]);
        // Don't leave trusted-timing state behind for a block that never started.
        [SCBlockUtilities clearTrustedTimingSettings];
        NSError* err = [SCErr errorWithCode: 302];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSLog(@"Adding firewall rules...");
    [SCHelperToolUtilities installBlockRulesFromSettings];
    [settings setValue: @YES forKey: @"BlockIsRunning"];
    
    NSError* syncErr = [settings syncSettingsAndWait: 5]; // synchronize ASAP since BlockIsRunning is a really important one
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after starting block", syncErr);
        [SCSentry captureError: syncErr];
    }

    NSLog(@"Firewall rules added!");
    
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon added block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully added.");
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [[SCDaemon sharedDaemon] startCheckupTimer];
    [self.daemonMethodLock unlock];
}

+ (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlocklist called" category: @"daemon"];
    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update blocklist because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 303];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update blocklist since block isn't running");
        NSError* err = [SCErr errorWithCode: 304];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
        
    if ([settings boolForKey: @"ActiveBlockAsWhitelist"]) {
        NSLog(@"ERROR: Attempting to update active blocklist, but this is not possible with an allowlist block");
        NSError* err = [SCErr errorWithCode: 305];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    NSArray<NSString*>* filteredBlocklist = [SCBlockUtilities blocklistByRemovingTimeSources:newBlocklist];
    if (filteredBlocklist.count != newBlocklist.count) {
        NSLog(@"WARNING: removed trusted time-source hostnames from blocklist update");
    }
    NSArray* activeBlocklist = [settings valueForKey: @"ActiveBlocklist"];
    NSMutableArray* added = [NSMutableArray arrayWithArray: filteredBlocklist];
    [added removeObjectsInArray: activeBlocklist];
    NSMutableArray* removed = [NSMutableArray arrayWithArray: activeBlocklist];
    [removed removeObjectsInArray: filteredBlocklist];
    
    // throw a warning if something got removed for some reason, since we ignore them
    if (removed.count > 0) {
        NSLog(@"WARNING: Active blocklist has removed items; these will not be updated. Removed items are %@", removed);
    }
    
    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist: [settings boolForKey: @"ActiveBlockAsWhitelist"]
                                                            allowLocal: [settings boolForKey: @"EvaluateCommonSubdomains"]
                                               includeCommonSubdomains: [settings boolForKey: @"AllowLocalNetworks"]
                                                  includeLinkedDomains: [settings boolForKey: @"IncludeLinkedDomains"]];
    [blockManager enterAppendMode];
    [blockManager addBlockEntriesFromStrings: added];
    [blockManager finishAppending];
    
    // Preserve active entries even if a caller omitted them; mid-block edits
    // are tighten-only.
    NSMutableArray* storedBlocklist = [activeBlocklist mutableCopy];
    [storedBlocklist addObjectsFromArray:added];
    [settings setValue:storedBlocklist forKey:@"ActiveBlocklist"];
    
    // make sure everyone knows about our new list
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after updating blocklist", syncErr);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon updated blocklist successfully" category: @"daemon"];
    NSLog(@"INFO: Blocklist successfully updated.");
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlockEndDate called" category: @"daemon"];

    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 306];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date since block isn't running");
        NSError* err = [SCErr errorWithCode: 307];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
    
    // this can only be used to *extend* the block end date - not shorten it!
    // and we also won't let them extend by more than 24 hours at a time, for safety...
    // TODO: they should be able to extend up to MaxBlockLength minutes, right?
    NSDate* currentEndDate = [settings valueForKey: @"BlockEndDate"];
    if ([newEndDate timeIntervalSinceDate: currentEndDate] < 0) {
        NSLog(@"ERROR: Can't update block end date to an earlier date");
        NSError* err = [SCErr errorWithCode: 308];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if ([newEndDate timeIntervalSinceDate: currentEndDate] > 86400) { // 86400 seconds = 1 day
        NSLog(@"ERROR: Can't extend block end date by more than 1 day at a time");
        NSError* err = [SCErr errorWithCode: 309];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSTimeInterval extensionSecs = [newEndDate timeIntervalSinceDate:currentEndDate];
    [settings setValue: newEndDate forKey: @"BlockEndDate"];
    NSNumber* trustedDuration = [settings valueForKey:@"BlockDurationSecs"];
    if (trustedDuration.doubleValue > 0) {
        [settings setValue:@(trustedDuration.doubleValue + extensionSecs) forKey:@"BlockDurationSecs"];
    }
    
    // make sure everyone knows about our new end date
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after extending block", syncErr);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    [SCSentry addBreadcrumb: @"Daemon extended block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully extended.");
    reply(nil);
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)checkupBlock {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkupBlock called" category: @"daemon"];

    NSTimeInterval integrityCheckIntervalSecs = 15.0;
    static NSDate* lastBlockIntegrityCheck;
    if (lastBlockIntegrityCheck == nil) {
        lastBlockIntegrityCheck = [NSDate distantPast];
    }

    SCSettings* settings = [SCSettings sharedSettings];

    // --- Resolve enforcement inputs (all reads, no side effects). ---
    BOOL rulesInstalled = [SCBlockUtilities blockRulesFoundOnSystem];
    BOOL modernRunning = [SCBlockUtilities modernBlockIsRunning];
    BOOL legacyRunning = [SCBlockUtilities legacyBlockIsRunning];

    // TRUSTED expiry only. Never the local-clock fallback for modern blocks.
    NSNumber* remaining = [SCBlockUtilities trustedRemainingBlockDurationSecs];
    BOOL trustedRemainingKnown = (remaining != nil);
    BOOL expired = trustedRemainingKnown ? (remaining.doubleValue <= 0) : NO;

    // Modern pedigree = any fork-era trusted-timing footprint. Distinguishes a
    // tampered modern block (heal/re-arm) from a genuine legacy one (local removal).
    NSNumber* durationValue = [settings valueForKey:@"BlockDurationSecs"];
    BOOL durationPresent = [durationValue isKindOfClass:[NSNumber class]] && durationValue.doubleValue > 0;
    NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
    BOOL clockStatePresent = [clockState isKindOfClass:[NSDictionary class]] && clockState.count > 0;
    BOOL startWallPresent = ([SCBlockUtilities effectiveBlockStartWallFromSettingsValue:[settings valueForKey:@"BlockStartWall"]] != nil);
    BOOL hasModernPedigree = durationPresent || clockStatePresent || startWallPresent;

    BOOL startIsVerified = [settings boolForKey:@"BlockStartIsVerified"];
    BOOL needsReVerification = [settings boolForKey:@"TrustedClockNeedsVerification"];

    SCEnforcementAction action =
        [SCEnforcementDecision actionForRulesInstalled:rulesInstalled
                                         modernRunning:modernRunning
                                         legacyRunning:legacyRunning
                                     hasModernPedigree:hasModernPedigree
                                 trustedRemainingKnown:trustedRemainingKnown
                                               expired:expired
                                       startIsVerified:startIsVerified
                                   needsReVerification:needsReVerification];

    BOOL shouldRunIntegrityCheck = NO;

    switch (action) {
        case SCEnforcementActionStopNoBlock: {
            NSLog(@"INFO: Checkup ran; no block in settings and no rules on system; stopping checkups.");
            [SCDaemonBlockMethods invalidateTediumChallenge];
            // once the checkups stop, the daemon will clear itself in a while due to inactivity
            [[SCDaemon sharedDaemon] stopCheckupTimer];
            break;
        }
        case SCEnforcementActionLegacyExpireCheck: {
            // Genuine pre-fork block only: upstream local-clock removal on expiry
            // (anti-permablock for old blocks). Otherwise leave checkups running.
            if ([SCBlockUtilities currentBlockIsExpired]) {
                NSLog(@"INFO: Legacy block expired; preserving upstream removal behavior.");
                [SCHelperToolUtilities removeBlock];
                [SCDaemonBlockMethods invalidateTediumChallenge];
                [[SCDaemon sharedDaemon] stopCheckupTimer];
            }
            break;
        }
        case SCEnforcementActionReArm: {
            // Rules present and trusted end known, but the running flag is off
            // (sudo flip / crash mid-write). Re-assert the flag; keep the end.
            // Neutral/tightening -> no network needed.
            NSLog(@"WARNING: Rules present but BlockIsRunning was off; re-asserting.");
            [settings setValue:@YES forKey:@"BlockIsRunning"];
            [settings syncSettingsAndWait:5];
            [SCHelperToolUtilities sendConfigurationChangedNotification];
            break;
        }
        case SCEnforcementActionHeal: {
            // Rules up but the trusted clock can't yield an end. Heal to verified
            // now + N (online) or hold (offline); never remove on the local clock.
            NSLog(@"WARNING: Block rules present but end-date undeterminable; attempting self-heal.");
            [[SCBlockEndVerifier sharedVerifier]
                requestVerificationWithCompletion:^(NSDate* verifiedNow, NSDictionary* reading, NSUInteger generation) {
                    [SCDaemonBlockMethods handleSelfHealVerifiedTime:verifiedNow reading:reading generation:generation];
                }];
            break;
        }
        case SCEnforcementActionInstall: {
            // Tightening: rules should be up but aren't. Install immediately (no network).
            NSLog(@"INFO: Desired enforcement on but rules missing; installing.");
            [SCHelperToolUtilities installBlockRulesFromSettings];
            [SCHelperToolUtilities sendConfigurationChangedNotification];
            break;
        }
        case SCEnforcementActionSeekVerifiedExpiry: {
            // Trusted-expired: ask for verified time. handleVerifiedTime remains
            // the ONLY place expiry removes rules. No integrity check (about to remove).
            [[SCBlockEndVerifier sharedVerifier]
                requestVerificationWithCompletion:^(NSDate* verifiedNow, NSDictionary* reading, NSUInteger generation) {
                    [SCDaemonBlockMethods handleVerifiedTime:verifiedNow reading:reading generation:generation];
                }];
            break;
        }
        case SCEnforcementActionSeekVerifiedStart: {
            // Start not yet verified / re-verification flagged: ask for verified time.
            [[SCBlockEndVerifier sharedVerifier]
                requestVerificationWithCompletion:^(NSDate* verifiedNow, NSDictionary* reading, NSUInteger generation) {
                    [SCDaemonBlockMethods handleVerifiedTime:verifiedNow reading:reading generation:generation];
                }];
            if ([[NSDate date] timeIntervalSinceDate:lastBlockIntegrityCheck] > integrityCheckIntervalSecs) {
                lastBlockIntegrityCheck = [NSDate date];
                shouldRunIntegrityCheck = YES;
            }
            break;
        }
        case SCEnforcementActionSteady: {
            // Enforced, installed, verified. Periodic integrity check only.
            if ([[NSDate date] timeIntervalSinceDate:lastBlockIntegrityCheck] > integrityCheckIntervalSecs) {
                lastBlockIntegrityCheck = [NSDate date];
                shouldRunIntegrityCheck = YES;
            }
            break;
        }
    }

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
    
    // if we need to run an integrity check, we need to do it at the very end after we give up our lock
    // because checkBlockIntegrity requests its own lock, and we don't want it to deadlock
    if (shouldRunIntegrityCheck) {
        [SCDaemonBlockMethods checkBlockIntegrity];
    }
}

+ (void)handleVerifiedTime:(NSDate*)verifiedNow
                   reading:(NSDictionary*)reading
                generation:(NSUInteger)generation {
    if (![SCDaemonBlockMethods lockOrTimeout:nil timeout:CHECKUP_LOCK_TIMEOUT]) {
        // Safe to drop: the verifier's backoff was already reset by the
        // successful fetch, so a later checkup will simply fetch again.
        NSLog(@"WARNING: Dropped verified network time because the daemon lock timed out.");
        return;
    }

    // A reset (startBlock, or a removal) between the fetch completing and us
    // acquiring the lock means this result belongs to a block that is gone.
    if (![SCBlockUtilities modernBlockIsRunning] ||
        ![[SCBlockEndVerifier sharedVerifier] isCurrentGeneration:generation]) {
        [self.daemonMethodLock unlock];
        return;
    }

    NSDictionary* decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:[SCBlockUtilities trustedTimingSettingsSnapshot]
                             verifiedNow:verifiedNow
                                 reading:reading];
    if (decision == nil) {
        NSLog(@"WARNING: Verified network time received, but trusted-timing state is incomplete; keeping block.");
        [self.daemonMethodLock unlock];
        return;
    }

    SCSettings* settings = [SCSettings sharedSettings];
    NSDictionary* writes = decision[SCTrustedTimingSettingsWritesKey];
    for (NSString* key in writes) {
        [settings setValue:writes[key] forKey:key];
    }
    BOOL correctedStart = [decision[SCTrustedTimingStartWasCorrectedKey] boolValue];
    if (correctedStart) NSLog(@"INFO: Corrected block start against verified network time.");

    if ([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]) {
        NSLog(@"INFO: Block expiry verified against network time; removing block.");
        [SCHelperToolUtilities removeBlock];
        [SCDaemonBlockMethods invalidateTediumChallenge];
        [[SCBlockEndVerifier sharedVerifier] reset];
        [[SCDaemon sharedDaemon] stopCheckupTimer];
        [SCSentry addBreadcrumb:@"Daemon verified and cleared expired block" category:@"daemon"];
    } else {
        NSError* syncError = [settings syncSettingsAndWait:5];
        if (syncError != nil) NSLog(@"WARNING: failed to persist verified time: %@", syncError);
        if (correctedStart) [SCHelperToolUtilities sendConfigurationChangedNotification];
    }

    [self.daemonMethodLock unlock];
}

+ (void)handleSelfHealVerifiedTime:(NSDate*)verifiedNow
                           reading:(NSDictionary*)reading
                        generation:(NSUInteger)generation {
    if (![SCDaemonBlockMethods lockOrTimeout:nil timeout:CHECKUP_LOCK_TIMEOUT]) return;

    // Only heal if rules are genuinely still on the system (never over a
    // legitimate teardown) and this result belongs to the current generation.
    if (![SCBlockUtilities blockRulesFoundOnSystem] ||
        ![[SCBlockEndVerifier sharedVerifier] isCurrentGeneration:generation]) {
        [self.daemonMethodLock unlock];
        return;
    }

    SCSettings* settings = [SCSettings sharedSettings];
    NSDate* healedEnd = [verifiedNow dateByAddingTimeInterval:SC_SELFHEAL_BLOCK_SECS];
    [settings setValue:@YES forKey:@"BlockIsRunning"];
    [settings setValue:healedEnd forKey:@"BlockEndDate"];
    [settings setValue:@(SC_SELFHEAL_BLOCK_SECS) forKey:@"BlockDurationSecs"];
    // BlockStartWall must be set: trustedTimingSettingsSnapshot reads it, and with
    // BlockStartIsVerified=YES a nil start makes trustedTimingDecisionForSettings
    // return nil (keep block) forever - so the healed block would never verify-
    // expire. Anchoring the start to verifiedNow makes it self-expire at +N.
    [settings setValue:verifiedNow forKey:@"BlockStartWall"];
    // I1: anchor the trusted-clock state to verifiedNow (not the raw reading's
    // wall), mirroring SCBlockUtilities' verifiedReading construction. Otherwise
    // the healed state's wall lags the healed start and the countdown is skewed.
    NSMutableDictionary* verifiedReading = [reading mutableCopy];
    verifiedReading[@"wall"] = verifiedNow;
    [settings setValue:[SCTrustedClock freshStateWithReading:verifiedReading] forKey:@"TrustedClockState"];
    [settings setValue:@YES forKey:@"BlockStartIsVerified"];
    [settings setValue:nil forKey:@"TrustedClockNeedsVerification"];

    NSError* syncError = [settings syncSettingsAndWait:5];
    if (syncError != nil) NSLog(@"WARNING: failed to persist self-heal: %@", syncError);

    [SCHelperToolUtilities sendConfigurationChangedNotification];
    NSLog(@"INFO: Self-healed block end to verified now + %.0fs.", SC_SELFHEAL_BLOCK_SECS);

    [self.daemonMethodLock unlock];
}

+ (void)checkBlockIntegrity {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkBlockIntegrity called" category: @"daemon"];

    SCSettings* settings = [SCSettings sharedSettings];
    PacketFilter* pf = [[PacketFilter alloc] init];
    HostFileBlockerSet* hostFileBlockerSet = [[HostFileBlockerSet alloc] init];
    if(![pf containsSelfControlBlock] || (![settings boolForKey: @"ActiveBlockAsWhitelist"] && ![hostFileBlockerSet.defaultBlocker containsSelfControlBlock])) {
        NSLog(@"INFO: Block is missing in PF or hosts, re-adding...");
        // The firewall is missing at least the block header.  Let's clear everything
        // before we re-add to make sure everything goes smoothly.

        [pf stopBlock: false];

        [hostFileBlockerSet removeSelfControlBlock];
        BOOL success = [hostFileBlockerSet writeNewFileContents];
        // Revert the host file blocker's file contents to disk so we can check
        // whether or not it still contains the block after our write (aka we messed up).
        [hostFileBlockerSet revertFileContentsToDisk];
        if(!success || [hostFileBlockerSet.defaultBlocker containsSelfControlBlock]) {
            NSLog(@"WARNING: Error removing host file block.  Attempting to restore backup.");

            if([hostFileBlockerSet restoreBackupHostsFile])
                NSLog(@"INFO: Host file backup restored.");
            else
                NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
        }

        // Get rid of the backup file since we're about to make a new one.
        [hostFileBlockerSet deleteBackupHostsFile];

        // Perform the re-add of the rules
        [SCHelperToolUtilities installBlockRulesFromSettings];
        
        [SCHelperToolUtilities clearCachesIfRequested];

        [SCSentry addBreadcrumb: @"Daemon found compromised block integrity and re-added rules" category: @"daemon"];
        NSLog(@"INFO: Integrity check ran; readded block rules.");
    } else NSLog(@"INFO: Integrity check ran; no action needed.");

    NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
    if (clockState.count > 0) {
        [settings setValue:[SCTrustedClock checkpointState:clockState
                                                   reading:[SCTrustedClock currentReading]]
                    forKey:@"TrustedClockState"];
    }
    
    [self.daemonMethodLock unlock];
}

+ (void)startTediumChallengeWithReply:(void(^)(NSInteger digit, NSInteger progress, NSInteger requiredEntries, NSError* _Nullable error))reply {
    // A user just typed an admin password to get here; don't fail this on a
    // busy half-second the way we would a routine checkup.
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: METHOD_LOCK_TIMEOUT]) {
        reply(0, 0, 0, [SCErr errorWithCode: 320]); // busy; app may retry
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        [self.daemonMethodLock unlock];
        reply(0, 0, 0, [SCErr errorWithCode: 321]); // no block to override
        return;
    }
    if (tediumChallenge == nil) {
        tediumChallenge = [[SCTediumChallenge alloc] initWithRequiredEntries: SC_TEDIUM_REQUIRED_ENTRIES];
        NSLog(@"INFO: Tedium override challenge started (%d entries required)", SC_TEDIUM_REQUIRED_ENTRIES);
        [SCSentry addBreadcrumb: @"Tedium override challenge started" category: @"daemon"];
    }
    [tediumChallenge beginAtUptime: [SCTrustedClock continuousUptimeSecs]];
    reply(tediumChallenge.expectedDigit, tediumChallenge.progress, tediumChallenge.requiredEntries, nil);
    [self.daemonMethodLock unlock];
}

+ (void)submitTediumEntry:(NSInteger)digit reply:(void(^)(NSInteger outcome, NSInteger progress, NSInteger nextDigit, BOOL blockRemoved, NSError* _Nullable error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        reply(0, 0, 0, NO, [SCErr errorWithCode: 320]);
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        // The block is actually gone (removed, expired, or never modern).
        tediumChallenge = nil;
        [self.daemonMethodLock unlock];
        reply(0, 0, 0, NO, [SCErr errorWithCode: 322]); // no active challenge/block
        return;
    }
    if (tediumChallenge == nil) {
        // The daemon (and thus the in-memory challenge) restarted mid-challenge,
        // but a block is still running - distinguish this from "block is gone"
        // so the app doesn't tell the user their block was removed.
        [self.daemonMethodLock unlock];
        reply(0, 0, 0, NO, [SCErr errorWithCode: 323]); // challenge lost; block still running
        return;
    }

    SCTediumSubmitOutcome outcome = [tediumChallenge submitDigit: digit
                                                        atUptime: [SCTrustedClock continuousUptimeSecs]];
    NSInteger progress = tediumChallenge.progress;
    NSInteger nextDigit = tediumChallenge.expectedDigit;
    BOOL removed = NO;

    if (outcome == SCTediumSubmitComplete) {
        NSLog(@"INFO: Tedium override completed (%ld entries); removing block.", (long)progress);
        [SCSentry addBreadcrumb: @"Block removed via tedium override" category: @"daemon"];
        [SCHelperToolUtilities removeBlock];
        [[SCBlockEndVerifier sharedVerifier] reset];
        [[SCDaemon sharedDaemon] stopCheckupTimer];
        tediumChallenge = nil;
        removed = YES;
    }

    reply(outcome, progress, nextDigit, removed, nil);
    [self.daemonMethodLock unlock];
}

+ (void)invalidateTediumChallenge {
    tediumChallenge = nil;
}

@end
