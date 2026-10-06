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
#import "SCOverrideDecision.h"
#import "SCOverrideConfig.h"
#import "SCSNTPClient.h"
#import "SCDeepBlockDecision.h"
#import "SCDeepBlockConfig.h"
#import "SCRuleCompiler.h"
#import <stdatomic.h>

NSTimeInterval METHOD_LOCK_TIMEOUT = 5.0;
NSTimeInterval CHECKUP_LOCK_TIMEOUT = 0.5; // use a shorter lock timeout for checkups, because we'd prefer not to have tons pile up

@interface SCDaemonBlockMethods ()
+ (void)handleVerifiedTime:(NSDate*)verifiedNow
                   reading:(NSDictionary*)reading
                generation:(NSUInteger)generation;
+ (void)handleSelfHealVerifiedTime:(NSDate*)verifiedNow
                           reading:(NSDictionary*)reading
                        generation:(NSUInteger)generation;
+ (NSDate*)overrideEndDateFromSettings:(SCSettings*)settings
                           outStateOut:(NSDictionary**)outState;
+ (NSTimeZone*)activationTimeZoneFromSettings:(SCSettings*)settings;
+ (BOOL)overrideActiveNowInSettings:(SCSettings*)settings;
+ (void)installBaseLayerIfMissing;
// Applies a verified-time trusted-timing decision (and, if verified-expired,
// removes the block). Caller holds daemonMethodLock and has already checked
// modernBlockIsRunning + verifier generation. Does NOT sync or notify, except
// what removeBlock itself does. Returns NO (nothing written) when the decision
// could not be computed.
+ (BOOL)applyVerifiedTime:(NSDate*)verifiedNow
                  reading:(NSDictionary*)reading
                 settings:(SCSettings*)settings
           didRemoveBlock:(BOOL*)outRemoved
           startCorrected:(BOOL*)outCorrected;
// YES iff an anchored trustedNow indicates the daily override ration is due to
// reset. Detection only; writes nothing.
+ (BOOL)overrideResetPendingForTrustedNow:(NSDate*)trustedNow
                            clockAnchored:(BOOL)anchored
                                 settings:(SCSettings*)settings;
// Applies the daily ration reset against VERIFIED time. Must be called right
// after applyVerifiedTime: succeeded (the day is taken from the freshly
// anchored TrustedClockState; `verifiedNow` is only a nil-guard). Writes
// OverrideState (no sync). Returns YES iff a reset was written.
+ (BOOL)applyOverrideResetForVerifiedNow:(NSDate*)verifiedNow settings:(SCSettings*)settings;
+ (void)stopCheckupTimerIfIdle;
+ (void)requestVerifiedTime;
+ (void)handleDeepSelfHealVerifiedTime:(NSDate*)verifiedNow
                               reading:(NSDictionary*)reading
                            generation:(NSUInteger)generation;
// Deep-block side of a verified network time: heals a broken/missing record, else
// corrects/rebases its timing and removes it when verified-expired. Caller holds
// daemonMethodLock and has checked the verifier generation. Syncs and notifies.
+ (void)applyDeepVerifiedTime:(NSDate*)verifiedNow reading:(NSDictionary*)reading settings:(SCSettings*)settings
              playEndSound:(BOOL)playEndSound;
// Shared throttle for TIGHTENING re-installs only (checkup Install, a missing
// regular-block layer, a missing deep layer, integrity re-apply): runs `attempt`
// unless a recent failure put it in backoff (then returns NO without trying).
// Failures back off 5 s, doubling to 300 s; a success resets it. Never used for
// removals, overrides, block starts or verified-expiry applies, which always run.
// Caller holds daemonMethodLock.
+ (BOOL)installThrottled:(BOOL (^)(void))attempt;
+ (void)resetInstallBackoff;
// Heals the deep record to verified now + SC_DEEP_HEAL_SECS when still needed.
// Caller holds daemonMethodLock. Returns YES iff a heal was written (and synced).
+ (BOOL)healDeepBlockIfNeededWithVerifiedTime:(NSDate*)verifiedNow reading:(NSDictionary*)reading settings:(SCSettings*)settings;
@end

// Single daemon-held tedium override challenge instance. All access is
// serialized under daemonMethodLock (see startTediumChallengeWithReply: and
// submitTediumEntry:reply:).
static SCTediumChallenge* tediumChallenge = nil;

// YES while an invoke's live SNTP worker is running (see invokeOverrideWithReply:).
// Set by the invoker just before dispatch; cleared only by the worker itself.
static atomic_bool sOverrideSNTPWorkerInFlight = false;

// Install backoff state (see installThrottled:). Guarded by daemonMethodLock.
// Continuous uptime: monotonic and counts sleep, so wall-clock changes can't skew it.
static NSTimeInterval sNextInstallAttemptUptime = 0;
static NSTimeInterval sInstallBackoffSecs = 0;

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

// Stops checkups only when neither block is left (nor any rules for them).
+ (void)stopCheckupTimerIfIdle {
    if (![SCBlockUtilities modernBlockIsRunning] && ![SCBlockUtilities deepBlockIsRunning] &&
        ![[SCBlockUtilities installedLayerNames] containsObject:SCLayerDeep]) {
        [[SCDaemon sharedDaemon] stopCheckupTimer];
    }
}

+ (void)resetInstallBackoff {
    sInstallBackoffSecs = 0;
    sNextInstallAttemptUptime = 0;
}

+ (BOOL)installThrottled:(BOOL (^)(void))attempt {
    NSTimeInterval now = [SCTrustedClock continuousUptimeSecs];
    if (sInstallBackoffSecs > 0 && now < sNextInstallAttemptUptime) return NO;
    if (attempt()) {
        [self resetInstallBackoff];
        return YES;
    }
    sInstallBackoffSecs = [SCEnforcementDecision installBackoffSecsAfterFailureWithCurrent:sInstallBackoffSecs];
    sNextInstallAttemptUptime = now + sInstallBackoffSecs;
    NSLog(@"WARNING: Rule install failed; next re-install attempt in %.0f s.", sInstallBackoffSecs);
    return NO;
}

+ (void)requestVerifiedTime {
    [[SCBlockEndVerifier sharedVerifier] requestVerificationWithCompletion:^(NSDate* v, NSDictionary* r, NSUInteger g) {
        [SCDaemonBlockMethods handleVerifiedTime:v reading:r generation:g];
    }];
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

    // --- Override policy + initial state (Phase 4) ---
    NSInteger overridePerDay = [blockSettings[@"OverridePerDay"] integerValue];
    NSInteger overrideMinutes = [blockSettings[@"OverrideMinutes"] integerValue];
    [settings setValue:@{ @"perDay": @(overridePerDay), @"minutes": @(overrideMinutes) }
                forKey:@"OverridePolicy"];
    // Captured at start like the override policy; absent/odd values mean "allowed".
    [settings setValue: blockSettings[@"EmergencyUnlockEnabled"] forKey: @"EmergencyUnlockEnabled"];
    NSString* activationTZName = [NSTimeZone systemTimeZone].name;
    [settings setValue:activationTZName forKey:@"ActivationTimeZone"];
    NSTimeZone* activationZone = [NSTimeZone timeZoneWithName:activationTZName] ?: [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString* today = [SCOverrideDecision dayStringForDate:[NSDate date] timeZone:activationZone];
    [settings setValue:@{ @"remainingToday": @(overridePerDay),
                          @"lastResetDay": today }
                forKey:@"OverrideState"];

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
    // BlockIsRunning first: the desired layers derive from it.
    [settings setValue: @YES forKey: @"BlockIsRunning"];
    if ([SCHelperToolUtilities installBlockRulesFromSettings]) {
        [SCDaemonBlockMethods resetInstallBackoff];   // a fresh block's repairs start unthrottled
    } else {
        // BlockIsRunning stays YES: a failed install leaves the previous rules in
        // place (PacketFilter rolls back, and takes out pf.conf lines it added), so
        // the checkup sees the regular block's rules missing and retries the install.
        NSLog(@"ERROR: Installing the block's rules failed; the checkup will retry.");
        [SCSentry addBreadcrumb: @"Daemon failed to install block rules at start" category: @"daemon"];
    }
    
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

+ (void)startDeepBlockWithBlocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist durationSecs:(double)durationSecs blockSettings:(NSDictionary*)blockSettings reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) return;
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [SCSentry addBreadcrumb: @"Daemon method startDeepBlock called" category: @"daemon"];

    NSArray<NSString*>* filtered = [SCBlockUtilities blocklistByRemovingTimeSources: blocklist ?: @[]];
    NSDictionary* reading = [SCTrustedClock currentReading];
    // "Already running" also covers deep rules installed without a record (tampered
    // away, awaiting heal): a new record would replace what that layer enforces.
    NSInteger refusal = [SCDeepBlockDecision startRefusalCodeWithDeepEnforced: [SCHelperToolUtilities deepShouldEnforce]
                                                                 durationSecs: durationSecs
                                                                   entryCount: filtered.count
                                                                  isAllowlist: isAllowlist
                                                                clockReadable: reading[@"wall"] != nil];
    if (refusal != 0) {
        reply([SCErr errorWithCode: refusal]);
        [self.daemonMethodLock unlock];
        return;
    }

    SCSettings* settings = [SCSettings sharedSettings];
    NSMutableDictionary* record = [@{
        @"blocklist": filtered,
        @"isAllowlist": @(isAllowlist),
        @"durationSecs": @(durationSecs),
        @"startWall": reading[@"wall"],
        @"startIsVerified": @NO,
        @"needsVerification": @YES,
        @"clockState": [SCTrustedClock freshStateWithReading: reading],
        @"allowLocal": @([blockSettings[@"AllowLocalNetworks"] boolValue]),
        @"evaluateCommonSubdomains": @([blockSettings[@"EvaluateCommonSubdomains"] boolValue]),
        @"includeLinkedDomains": @([blockSettings[@"IncludeLinkedDomains"] boolValue]),
    } mutableCopy];
    if (blockSettings[@"EmergencyUnlockEnabled"] != nil) record[@"emergencyUnlockEnabled"] = blockSettings[@"EmergencyUnlockEnabled"];
    [settings setValue: record forKey: @"DeepBlock"];

    // Overrides are off for the whole deep block: end one that's running now.
    id originalOverrideState = [settings valueForKey: @"OverrideState"];
    BOOL overrideEnded = NO;
    if ([originalOverrideState isKindOfClass: [NSDictionary class]] && originalOverrideState[@"overrideEndDate"] != nil) {
        NSMutableDictionary* ended = [originalOverrideState mutableCopy];
        [ended removeObjectForKey: @"overrideEndDate"];
        [settings setValue: ended forKey: @"OverrideState"];
        overrideEnded = YES;
        NSLog(@"INFO: Deep block starting; ending the active override.");
    }

    // Derives base (if running) + deep. Starts always run: not throttled.
    BOOL installed = [SCHelperToolUtilities installBlockRulesFromSettings];
    if (!installed && [[SCBlockUtilities installedLayerNames] containsObject: SCLayerDeep]) {
        // pf took the deep layer but a later step (e.g. the hosts write) failed.
        // Rolling the record back would orphan installed deep rules, which the heal
        // path would then rebuild as a 4-hour block. Keep the record: the block has
        // started, and the checkup's integrity check repairs the rest.
        NSLog(@"WARNING: Deep block rules are in pf but the install reported a failure; keeping the deep block, the checkup will repair it.");
        [SCSentry addBreadcrumb: @"Deep block start: partial install kept" category: @"daemon"];
        installed = YES;
    }
    if (!installed) {
        // A start that didn't install must not leave a record behind.
        NSLog(@"ERROR: Installing the deep block's rules failed; not starting it.");
        [SCBlockUtilities removeDeepBlockFromSettings];
        if (overrideEnded) [settings setValue: originalOverrideState forKey: @"OverrideState"];
        NSError* syncErr = [settings syncSettingsAndWait: 5];
        if (syncErr != nil) NSLog(@"WARNING: Sync failed after rolling back deep block start: %@", syncErr);
        [SCSentry addBreadcrumb: @"Daemon failed to install deep block rules at start" category: @"daemon"];
        reply([SCErr errorWithCode: 327]);
        [[SCDaemon sharedDaemon] resetInactivityTimer];
        [self.daemonMethodLock unlock];
        return;
    }
    [SCDaemonBlockMethods resetInstallBackoff];
    [SCDaemonBlockMethods invalidateTediumChallenge];

    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) NSLog(@"WARNING: Sync failed after starting deep block: %@", syncErr);
    [SCHelperToolUtilities sendConfigurationChangedNotification];
    if ([blockSettings[@"ClearCaches"] boolValue]) [SCHelperToolUtilities clearBrowserCaches];

    NSLog(@"INFO: Deep block started (%.0fs, %@).", durationSecs, isAllowlist ? @"allowlist" : @"blocklist");
    reply(nil);
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [[SCDaemon sharedDaemon] startCheckupTimer];
    [self.daemonMethodLock unlock];
    [SCDaemonBlockMethods requestVerifiedTime];
}

+ (void)addToDeepBlocklist:(NSArray<NSString*>*)entries authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) return;
    [SCSentry addBreadcrumb: @"Daemon method addToDeepBlocklist called" category: @"daemon"];

    SCSettings* settings = [SCSettings sharedSettings];
    NSDictionary* record = [SCBlockUtilities deepBlockRecord];
    // Additions only, and only to a blocklist deep block with a list we can trust.
    NSInteger refusal = [SCDeepBlockDecision addRefusalCodeForRecord: record];
    if (refusal != 0) {
        NSLog(@"ERROR: Can't add to the deep blocklist (code %ld)", (long)refusal);
        reply([SCErr errorWithCode: refusal]);
        [[SCDaemon sharedDaemon] resetInactivityTimer];
        [self.daemonMethodLock unlock];
        return;
    }

    NSMutableArray<NSString*>* valid = [NSMutableArray array];
    for (id entry in entries ?: @[]) {
        if ([entry isKindOfClass: [NSString class]] && [entry length] > 0) [valid addObject: entry];
    }
    NSArray<NSString*>* filtered = [SCBlockUtilities blocklistByRemovingTimeSources: valid];
    NSArray<NSString*>* merged = [SCDeepBlockDecision blocklist: record[@"blocklist"] byAdding: filtered];
    if (merged.count == [record[@"blocklist"] count]) {   // byAdding keeps the record's list as-is, so equal counts means nothing new
        // Nothing new, but an earlier add may still be waiting to be applied.
        id pendingFlag = record[@"applyPending"];
        BOOL pending = [pendingFlag isKindOfClass: [NSNumber class]] && [pendingFlag boolValue];
        reply(pending ? [SCErr errorWithCode: 336] : nil);
        [[SCDaemon sharedDaemon] resetInactivityTimer];
        [self.daemonMethodLock unlock];
        return;
    }

    NSMutableDictionary* updated = [record mutableCopy];
    updated[@"blocklist"] = merged;
    // Until the rules are applied, the checkup keeps retrying (a hosts failure after pf succeeded
    // leaves the installed payload covering the record, so it needs its own flag).
    updated[@"applyPending"] = @YES;
    [settings setValue: updated forKey: @"DeepBlock"];

    // Re-resolve and rewrite every layer, override-aware exactly as updateBlocklist.
    BOOL overrideActive = [SCDaemonBlockMethods overrideActiveNowInSettings: settings];
    BOOL applied = overrideActive ? [SCHelperToolUtilities clearBlockRulesOnly]
                                  : [SCHelperToolUtilities installBlockRulesFromSettings];

    if (applied) {
        [updated removeObjectForKey: @"applyPending"];
        [settings setValue: updated forKey: @"DeepBlock"];
    }
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) NSLog(@"WARNING: Sync failed or timed out with error %@ after adding to the deep blocklist", syncErr);

    if (!applied) {
        // Never roll back (that would relax). The record keeps the new sites and the
        // checkup's integrity check re-applies until the installed payload covers them.
        NSLog(@"ERROR: Failed to apply deep block rules after adding sites; keeping them, the checkup will retry.");
        [SCSentry addBreadcrumb: @"Daemon failed to apply deep blocklist addition" category: @"daemon"];
        reply([SCErr errorWithCode: 336]);
    } else {
        [SCHelperToolUtilities sendConfigurationChangedNotification];
        [SCHelperToolUtilities clearCachesIfRequested];
        NSLog(@"INFO: Deep blocklist successfully updated.");
        reply(nil);
    }
    [[SCDaemon sharedDaemon] resetInactivityTimer];
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
    
    // Preserve active entries even if a caller omitted them; mid-block edits
    // are tighten-only.
    NSMutableArray* storedBlocklist = [activeBlocklist mutableCopy];
    [storedBlocklist addObjectsFromArray:added];
    [settings setValue:storedBlocklist forKey:@"ActiveBlocklist"];

    // Re-resolve and rewrite every layer (no partial appends). If an override is
    // active the base layer must stay lifted: computed exactly as checkupBlock does.
    BOOL overrideActive = [SCDaemonBlockMethods overrideActiveNowInSettings:settings];
    BOOL applied = overrideActive ? [SCHelperToolUtilities clearBlockRulesOnly]
                                  : [SCHelperToolUtilities installBlockRulesFromSettings];
    if (!applied) NSLog(@"ERROR: Failed to apply block rules after updating the blocklist.");

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

// Returns the current override end date (or nil), and by-ref the parsed state dict.
+ (NSDate*)overrideEndDateFromSettings:(SCSettings*)settings
                           outStateOut:(NSDictionary**)outState {
    NSDictionary* state = [settings valueForKey:@"OverrideState"];
    if (![state isKindOfClass:[NSDictionary class]]) state = nil;
    if (outState != NULL) *outState = state;
    id end = state[@"overrideEndDate"];
    return [end isKindOfClass:[NSDate class]] ? end : nil;
}

// The block's pinned override/reset timezone (captured at block start). Never
// the live system zone (that would let a TZ change move the reset boundary);
// falls back to UTC when unset.
+ (NSTimeZone*)activationTimeZoneFromSettings:(SCSettings*)settings {
    id name = [settings valueForKey:@"ActivationTimeZone"];
    NSTimeZone* tz = [name isKindOfClass:[NSString class]] ? [NSTimeZone timeZoneWithName:name] : nil;
    return tz ?: [NSTimeZone timeZoneForSecondsFromGMT:0];
}

// "Rules installed" above is coarse (pf.conf anchor line OR hosts block), so a
// deep layer alone counts. When the regular block runs (and no override lifts
// it) but its layer is not in the installed anchor - a failed install that was
// rolled back onto the deep layer, or an override that just ended - install it.
// Tightening only; no network needed.
+ (void)installBaseLayerIfMissing {
    if (![SCBlockUtilities modernBlockIsRunning] || [SCBlockUtilities baseRulesFoundOnSystem]) return;
    __block BOOL attempted = NO;
    BOOL installed = [SCDaemonBlockMethods installThrottled:^BOOL{
        attempted = YES;
        NSLog(@"INFO: Regular block running but its rules are missing; installing.");
        return [SCHelperToolUtilities installBlockRulesFromSettings];
    }];
    if (!attempted) return;   // backing off after a recent failure
    if (!installed) NSLog(@"ERROR: Installing the regular block's rules failed; will retry.");
    [SCHelperToolUtilities sendConfigurationChangedNotification];
}

// Fail-closed override state: requires a genuinely ANCHORED trusted clock
// (trustedNowForState: silently returns the raw wall clock when wallAnchor is
// absent), and the lift is bounded so a corrupt overrideEndDate can't lift forever.
+ (BOOL)overrideActiveNowInSettings:(SCSettings*)settings {
    NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
    NSDate* trustedNow = [SCTrustedClock trustedNowForState:clockState
                                                    reading:[SCTrustedClock currentReading]];
    NSDate* overrideEndDate = [SCDaemonBlockMethods overrideEndDateFromSettings:settings outStateOut:NULL];
    BOOL clockAnchored = [clockState isKindOfClass:[NSDictionary class]] && clockState[@"wallAnchor"] != nil;
    return [SCOverrideDecision liftRemainingSecsWithTrustedNow:trustedNow
                                               overrideEndDate:overrideEndDate
                                                 clockAnchored:clockAnchored
                                                   maxLiftSecs:SC_OVERRIDE_MAX_LIFT_SECS] > 0;
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
    // The regular block's own rules: a deep layer alone must not look like them.
    NSArray* installedLayers = [SCBlockUtilities installedLayerNames];
    BOOL rulesInstalled = [installedLayers containsObject:SCLayerBase];
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

    // --- Override overlay (Phase 4): resolve fail-closed active state. ---
    // Fail-closed requires a genuinely ANCHORED trusted clock: trustedNowForState:
    // silently returns the raw system wall clock when wallAnchor is absent, so a
    // non-nil trustedNow is NOT by itself a trust signal. Require wallAnchor, and
    // bound the lift so a corrupt/oversized overrideEndDate cannot lift indefinitely.
    NSDate* trustedNow = [SCTrustedClock trustedNowForState:clockState
                                                    reading:[SCTrustedClock currentReading]];
    BOOL clockAnchored = [clockState isKindOfClass:[NSDictionary class]] && clockState[@"wallAnchor"] != nil;
    BOOL overrideActive = [SCDaemonBlockMethods overrideActiveNowInSettings:settings];
    // An override never lifts the regular block while the deep block is enforced
    // (record present, or its rules installed without one).
    NSDictionary* deep = [SCBlockUtilities deepBlockRecord];
    BOOL deepEnforced = deep != nil || [installedLayers containsObject:SCLayerDeep];
    BOOL baseLifted = overrideActive && !deepEnforced;

    // Midnight reset must be driven by VERIFIED time (master spec §4). trustedNow advances
    // monotonically offline, so it may only DETECT that a reset is due; the reset itself is
    // applied in handleVerifiedTime: from a live fetch. Offline => the reset waits.
    if (modernRunning && [SCDaemonBlockMethods overrideResetPendingForTrustedNow:trustedNow clockAnchored:clockAnchored settings:settings]) {
        [[SCBlockEndVerifier sharedVerifier] requestVerificationWithCompletion:^(NSDate* v, NSDictionary* r, NSUInteger g) {
            [SCDaemonBlockMethods handleVerifiedTime:v reading:r generation:g];
        }];
    }

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
            if (deepEnforced) break;   // the deep block keeps checkups running
            NSLog(@"INFO: Checkup ran; no block in settings and no rules on system; stopping checkups.");
            [SCDaemonBlockMethods invalidateTediumChallenge];
            // once the checkups stop, the daemon will clear itself in a while due to inactivity
            [SCDaemonBlockMethods stopCheckupTimerIfIdle];
            break;
        }
        case SCEnforcementActionLegacyExpireCheck: {
            // Genuine pre-fork block only: upstream local-clock removal on expiry
            // (anti-permablock for old blocks). Otherwise leave checkups running.
            if ([SCBlockUtilities currentBlockIsExpired]) {
                NSLog(@"INFO: Legacy block expired; preserving upstream removal behavior.");
                if ([SCHelperToolUtilities removeBlock]) {
                    [SCDaemonBlockMethods invalidateTediumChallenge];
                    // A deep block may still be enforced: only stop when nothing is left.
                    [SCDaemonBlockMethods stopCheckupTimerIfIdle];
                } else {
                    NSLog(@"ERROR: Removing the expired legacy block failed; will retry.");
                }
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
            if (baseLifted) {
                [SCHelperToolUtilities clearBlockRulesOnly];
            }
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
            if (baseLifted) {
                // Override running: desired base rules = none. Ensure lifted.
                if (rulesInstalled) {
                    [SCHelperToolUtilities clearBlockRulesOnly];
                    [SCHelperToolUtilities sendConfigurationChangedNotification];
                }
                break;
            }
            __block BOOL attempted = NO;
            [SCDaemonBlockMethods installThrottled:^BOOL{
                attempted = YES;
                NSLog(@"INFO: Desired enforcement on but rules missing; installing.");
                return [SCHelperToolUtilities installBlockRulesFromSettings];
            }];
            if (attempted) [SCHelperToolUtilities sendConfigurationChangedNotification];
            break;
        }
        case SCEnforcementActionSeekVerifiedExpiry: {
            // Trusted-expired: ask for verified time. handleVerifiedTime remains
            // the ONLY place expiry removes rules. While waiting (e.g. offline) pf may
            // be disabled or flushed, so the integrity check (add-only) still runs.
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
        case SCEnforcementActionSeekVerifiedStart: {
            // Start not yet verified / re-verification flagged: ask for verified time.
            if (!baseLifted) [SCDaemonBlockMethods installBaseLayerIfMissing];
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
            if (baseLifted) {
                if (rulesInstalled) {
                    [SCHelperToolUtilities clearBlockRulesOnly];
                    [SCHelperToolUtilities sendConfigurationChangedNotification];
                }
                break; // no integrity check while base is intentionally lifted
            }
            [SCDaemonBlockMethods installBaseLayerIfMissing];
            if ([[NSDate date] timeIntervalSinceDate:lastBlockIntegrityCheck] > integrityCheckIntervalSecs) {
                lastBlockIntegrityCheck = [NSDate date];
                shouldRunIntegrityCheck = YES;
            }
            break;
        }
    }

    // --- Deep block (Phase 5): parallel record, same fail-closed timing rules. ---
    // Re-read: the regular-block branch may have just installed layers (or re-armed).
    deep = [SCBlockUtilities deepBlockRecord];
    installedLayers = [SCBlockUtilities installedLayerNames];
    BOOL deepInstalled = [installedLayers containsObject:SCLayerDeep];
    NSNumber* deepRemaining = [SCBlockUtilities trustedRemainingDeepBlockSecs];
    SCDeepAction deepAction = [SCDeepBlockDecision
        actionForRecordPresent:deep != nil
                timingComplete:[SCDeepBlockDecision recordTimingIsComplete:deep]
                remainingKnown:deepRemaining != nil
                       expired:deepRemaining != nil && deepRemaining.doubleValue <= 0
               startIsVerified:[deep[@"startIsVerified"] boolValue]
             needsVerification:[deep[@"needsVerification"] boolValue]
                layerInstalled:deepInstalled];
    switch (deepAction) {
        case SCDeepActionNone:
        case SCDeepActionSteady:
            break;
        case SCDeepActionInstall: {
            // Tightening, no network. Union with what's installed so this can only add
            // (e.g. regular-block rules whose running flag was just re-armed stay put).
            NSMutableOrderedSet* layers = [NSMutableOrderedSet orderedSetWithArray:
                [SCDeepBlockDecision desiredLayersWithBaseRunning:[SCBlockUtilities modernBlockIsRunning]
                                                   overrideActive:overrideActive
                                                deepShouldEnforce:YES]];
            [layers addObjectsFromArray:installedLayers];
            __block BOOL attempted = NO;
            BOOL installed = [SCDaemonBlockMethods installThrottled:^BOOL{
                attempted = YES;
                NSLog(@"INFO: Deep block rules missing; installing.");
                return [SCHelperToolUtilities applyDesiredLayers:layers.array];
            }];
            if (attempted) {
                if (!installed) NSLog(@"ERROR: Installing the deep block's rules failed; will retry.");
                [SCHelperToolUtilities sendConfigurationChangedNotification];
            }
            if (![deep[@"startIsVerified"] boolValue] || [deep[@"needsVerification"] boolValue]) {
                [SCDaemonBlockMethods requestVerifiedTime];
            }
            break;
        }
        case SCDeepActionSeekVerifiedStart:
        case SCDeepActionSeekVerifiedExpiry:
            // handleVerifiedTime: is the only place a deep block's expiry removes it.
            [SCDaemonBlockMethods requestVerifiedTime];
            break;
        case SCDeepActionHeal:
            // Online: heal to verified now + SC_DEEP_HEAL_SECS. Offline: rules untouched.
            NSLog(@"WARNING: Deep block end undeterminable (or record missing); attempting self-heal.");
            [[SCBlockEndVerifier sharedVerifier] requestVerificationWithCompletion:^(NSDate* v, NSDictionary* r, NSUInteger g) {
                [SCDaemonBlockMethods handleDeepSelfHealVerifiedTime:v reading:r generation:g];
            }];
            break;
    }
    // Integrity also covers a deep-only block (it only ever adds rules).
    if ((deepAction == SCDeepActionSteady || deepAction == SCDeepActionSeekVerifiedStart || deepAction == SCDeepActionSeekVerifiedExpiry || deepAction == SCDeepActionHeal) &&
        [[NSDate date] timeIntervalSinceDate:lastBlockIntegrityCheck] > integrityCheckIntervalSecs) {
        lastBlockIntegrityCheck = [NSDate date];
        shouldRunIntegrityCheck = YES;
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
    // One verification serves both blocks (and a deep layer whose record is gone).
    BOOL baseRunning = [SCBlockUtilities modernBlockIsRunning];
    BOOL deepPresent = [SCBlockUtilities deepBlockIsRunning] ||
                       [[SCBlockUtilities installedLayerNames] containsObject:SCLayerDeep];
    if ((!baseRunning && !deepPresent) ||
        ![[SCBlockEndVerifier sharedVerifier] isCurrentGeneration:generation]) {
        [self.daemonMethodLock unlock];
        return;
    }

    SCSettings* settings = [SCSettings sharedSettings];
    BOOL baseRemoved = NO;
    if (baseRunning) {
        BOOL removed = NO;
        BOOL correctedStart = NO;
        // NO = the regular block's timing is incomplete: keep it, but still serve the deep block.
        if ([SCDaemonBlockMethods applyVerifiedTime:verifiedNow
                                            reading:reading
                                           settings:settings
                                     didRemoveBlock:&removed
                                     startCorrected:&correctedStart] && !removed) {
            // Verified time in hand: this is the ONLY place the daily override
            // ration resets (the checkup merely detects that one is due).
            BOOL resetApplied = [SCDaemonBlockMethods applyOverrideResetForVerifiedNow:verifiedNow settings:settings];
            if (resetApplied) NSLog(@"INFO: Daily override ration reset against verified network time.");
            NSError* syncError = [settings syncSettingsAndWait:5];
            if (syncError != nil) NSLog(@"WARNING: failed to persist verified time: %@", syncError);
            if (correctedStart || resetApplied) [SCHelperToolUtilities sendConfigurationChangedNotification];
        }
        baseRemoved = removed;
    }

    if (deepPresent) {
        // Both blocks ending on the same verified time: the end sound plays once.
        [SCDaemonBlockMethods applyDeepVerifiedTime:verifiedNow reading:reading settings:settings
                                       playEndSound:!baseRemoved];
    }

    [self.daemonMethodLock unlock];
}

+ (void)applyDeepVerifiedTime:(NSDate*)verifiedNow reading:(NSDictionary*)reading settings:(SCSettings*)settings
              playEndSound:(BOOL)playEndSound {
    // A broken or missing record can't be timed: heal it (never remove on doubt).
    if ([SCDaemonBlockMethods healDeepBlockIfNeededWithVerifiedTime:verifiedNow reading:reading settings:settings]) return;

    NSDictionary* deep = [SCBlockUtilities deepBlockRecord];
    if (deep == nil) return;
    NSDictionary* decision = [SCBlockUtilities trustedTimingDecisionForSettings:[SCDeepBlockDecision timingSnapshotForRecord:deep]
                                                                   verifiedNow:verifiedNow
                                                                       reading:reading];
    if (decision == nil) {
        NSLog(@"WARNING: Verified network time received, but deep-block timing is incomplete; keeping it.");
        return;
    }
    NSDictionary* updated = [SCDeepBlockDecision record:deep byApplyingTimingWrites:decision[SCTrustedTimingSettingsWritesKey]];
    if ([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]) {
        NSLog(@"INFO: Deep block expiry verified against network time; removing it.");
        [SCBlockUtilities removeDeepBlockFromSettings];
        // Explicit layers: the deep rules are still installed, so the default
        // derivation (record OR installed) would keep them. overrideActive:NO -
        // an override can't be running alongside a deep block (fail-closed if one is;
        // the checkup lifts the regular block again on its next tick).
        NSArray* layers = [SCDeepBlockDecision desiredLayersWithBaseRunning:[SCBlockUtilities modernBlockIsRunning]
                                                             overrideActive:NO
                                                          deepShouldEnforce:NO];
        if ([SCHelperToolUtilities applyDesiredLayers:layers]) {
            [SCSentry addBreadcrumb:@"Daemon verified and cleared expired deep block" category:@"daemon"];
            if (playEndSound) [SCHelperToolUtilities playBlockEndSound];
            [SCDaemonBlockMethods stopCheckupTimerIfIdle];
        } else {
            // Keep the record (verified-expired) so the next verification retries the
            // removal; without it the still-installed layer would be healed to +4 h.
            NSLog(@"ERROR: Removing the deep block's rules failed; will retry on the next verification.");
            [settings setValue:updated forKey:@"DeepBlock"];
        }
    } else {
        [settings setValue:updated forKey:@"DeepBlock"];
        if ([decision[SCTrustedTimingStartWasCorrectedKey] boolValue]) NSLog(@"INFO: Corrected deep block start against verified network time.");
    }
    NSError* syncError = [settings syncSettingsAndWait:5];
    if (syncError != nil) NSLog(@"WARNING: failed to persist deep-block verified time: %@", syncError);
    [SCHelperToolUtilities sendConfigurationChangedNotification];
}

+ (BOOL)healDeepBlockIfNeededWithVerifiedTime:(NSDate*)verifiedNow reading:(NSDictionary*)reading settings:(SCSettings*)settings {
    NSDictionary* deep = [SCBlockUtilities deepBlockRecord];
    // Only heal when it's still needed (never over a legitimate teardown).
    BOOL needed = [SCDeepBlockDecision healNeededForRecord:deep
                                            remainingKnown:[SCBlockUtilities trustedRemainingDeepBlockSecs] != nil
                                            layerInstalled:[[SCBlockUtilities installedLayerNames] containsObject:SCLayerDeep]];
    if (!needed || verifiedNow == nil || reading == nil) return NO;

    NSString* anchor = [NSString stringWithContentsOfFile:@"/etc/pf.anchors/org.eyebeam" encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* payload = [SCRuleCompiler deepPayloadFromAnchorText:anchor];
    if (deep == nil && payload == nil) {
        // Can't rebuild the list: leave the installed rules alone and retry next checkup.
        NSLog(@"WARNING: Deep block rules present with no record or payload; holding.");
        return NO;
    }
    NSMutableDictionary* verifiedReading = [reading mutableCopy];
    verifiedReading[@"wall"] = verifiedNow;
    NSDictionary* healed = [SCDeepBlockDecision healedRecordFromRecord:deep
                                                               payload:payload
                                                           verifiedNow:verifiedNow
                                                            clockState:[SCTrustedClock freshStateWithReading:verifiedReading]];
    [settings setValue:healed forKey:@"DeepBlock"];
    NSError* syncError = [settings syncSettingsAndWait:5];
    if (syncError != nil) NSLog(@"WARNING: failed to persist deep self-heal: %@", syncError);
    [SCHelperToolUtilities sendConfigurationChangedNotification];
    [SCSentry addBreadcrumb:@"Daemon self-healed the deep block" category:@"daemon"];
    NSLog(@"INFO: Self-healed deep block to verified now + %ds.", SC_DEEP_HEAL_SECS);
    return YES;
}

+ (void)handleDeepSelfHealVerifiedTime:(NSDate*)verifiedNow
                               reading:(NSDictionary*)reading
                            generation:(NSUInteger)generation {
    if (![SCDaemonBlockMethods lockOrTimeout:nil timeout:CHECKUP_LOCK_TIMEOUT]) return;
    if ([[SCBlockEndVerifier sharedVerifier] isCurrentGeneration:generation]) {
        [SCDaemonBlockMethods healDeepBlockIfNeededWithVerifiedTime:verifiedNow reading:reading settings:[SCSettings sharedSettings]];
    }
    [self.daemonMethodLock unlock];
}

+ (BOOL)applyVerifiedTime:(NSDate*)verifiedNow
                  reading:(NSDictionary*)reading
                 settings:(SCSettings*)settings
           didRemoveBlock:(BOOL*)outRemoved
           startCorrected:(BOOL*)outCorrected {
    if (outRemoved != NULL) *outRemoved = NO;
    if (outCorrected != NULL) *outCorrected = NO;

    NSDictionary* decision = [SCBlockUtilities
        trustedTimingDecisionForSettings:[SCBlockUtilities trustedTimingSettingsSnapshot]
                             verifiedNow:verifiedNow
                                 reading:reading];
    if (decision == nil) {
        NSLog(@"WARNING: Verified network time received, but trusted-timing state is incomplete; keeping block.");
        return NO;
    }

    NSDictionary* writes = decision[SCTrustedTimingSettingsWritesKey];
    for (NSString* key in writes) {
        [settings setValue:writes[key] forKey:key];
    }
    BOOL correctedStart = [decision[SCTrustedTimingStartWasCorrectedKey] boolValue];
    if (correctedStart) NSLog(@"INFO: Corrected block start against verified network time.");
    if (outCorrected != NULL) *outCorrected = correctedStart;

    if ([decision[SCTrustedTimingShouldRemoveBlockKey] boolValue]) {
        NSLog(@"INFO: Block expiry verified against network time; removing block.");
        if ([SCHelperToolUtilities removeBlock]) {
            [SCDaemonBlockMethods invalidateTediumChallenge];
            [[SCBlockEndVerifier sharedVerifier] reset];
            [SCDaemonBlockMethods stopCheckupTimerIfIdle];
            [SCSentry addBreadcrumb:@"Daemon verified and cleared expired block" category:@"daemon"];
            if (outRemoved != NULL) *outRemoved = YES;
        } else {
            // The block stays "running and expired" (the timing writes above are
            // persisted by the caller), so the next verified time retries removal.
            NSLog(@"ERROR: Removing the verified-expired block failed; will retry on the next verification.");
        }
    }
    return YES;
}

+ (BOOL)overrideResetPendingForTrustedNow:(NSDate*)trustedNow
                            clockAnchored:(BOOL)anchored
                                 settings:(SCSettings*)settings {
    if (trustedNow == nil || !anchored) return NO;
    NSDictionary* ovState = [settings valueForKey:@"OverrideState"];
    NSDictionary* policy = [settings valueForKey:@"OverridePolicy"];
    if (![ovState isKindOfClass:[NSDictionary class]] || ![policy isKindOfClass:[NSDictionary class]]) return NO;
    NSString* day = [SCOverrideDecision dayStringForDate:trustedNow
                                                timeZone:[SCDaemonBlockMethods activationTimeZoneFromSettings:settings]];
    id lastReset = ovState[@"lastResetDay"];
    NSString* lastResetStr = [lastReset isKindOfClass:[NSString class]] ? lastReset : nil;
    NSInteger tmp = 0;
    return [SCOverrideDecision resetForVerifiedDay:day
                                      lastResetDay:lastResetStr
                                            perDay:[policy[@"perDay"] integerValue]
                                   outNewRemaining:&tmp];
}

+ (BOOL)applyOverrideResetForVerifiedNow:(NSDate*)verifiedNow settings:(SCSettings*)settings {
    if (verifiedNow == nil) return NO;
    NSDictionary* ovState = [settings valueForKey:@"OverrideState"];
    NSDictionary* policy = [settings valueForKey:@"OverridePolicy"];
    if (![ovState isKindOfClass:[NSDictionary class]] || ![policy isKindOfClass:[NSDictionary class]]) return NO;
    NSInteger perDay = [policy[@"perDay"] integerValue];
    // Derive the day from the trusted clock as it stands NOW, not from the raw
    // `verifiedNow` instant. Callers invoke this right after applyVerifiedTime:
    // wrote a fresh anchored TrustedClockState, so `now` ~= current verified
    // time. `verifiedNow` itself may be stale (e.g. a checkup fetch that started
    // before midnight and completed after an invoke already committed the next
    // day); a stale verified instant must never move the reset day backwards
    // (and the pure rule additionally only resets on a strictly later day).
    NSDictionary* cs = [settings valueForKey:@"TrustedClockState"];
    BOOL anchored = [cs isKindOfClass:[NSDictionary class]] && cs[@"wallAnchor"] != nil;
    NSDate* now = anchored ? [SCTrustedClock trustedNowForState:cs reading:[SCTrustedClock currentReading]] : nil;
    if (now == nil) return NO;
    NSString* verifiedDay = [SCOverrideDecision dayStringForDate:now
                                                        timeZone:[SCDaemonBlockMethods activationTimeZoneFromSettings:settings]];
    id lastReset = ovState[@"lastResetDay"];
    NSString* lastResetStr = [lastReset isKindOfClass:[NSString class]] ? lastReset : nil;
    NSInteger newRemaining = 0;
    if (![SCOverrideDecision resetForVerifiedDay:verifiedDay
                                    lastResetDay:lastResetStr
                                          perDay:perDay
                                 outNewRemaining:&newRemaining]) {
        return NO;
    }
    NSMutableDictionary* updated = [ovState mutableCopy]; // keeps overrideEndDate
    updated[@"remainingToday"] = @(newRemaining);
    updated[@"lastResetDay"] = verifiedDay;
    [settings setValue:updated forKey:@"OverrideState"];
    return YES;
}

+ (void)handleSelfHealVerifiedTime:(NSDate*)verifiedNow
                           reading:(NSDictionary*)reading
                        generation:(NSUInteger)generation {
    if (![SCDaemonBlockMethods lockOrTimeout:nil timeout:CHECKUP_LOCK_TIMEOUT]) return;

    // Only heal if the regular block's rules are genuinely still on the system (never
    // over a legitimate teardown; a deep layer alone doesn't count) and this result
    // belongs to the current generation.
    if (![[SCBlockEndVerifier sharedVerifier] isCurrentGeneration:generation]) {
        [self.daemonMethodLock unlock];
        return;
    }
    SCSettings* settings = [SCSettings sharedSettings];
    // One verifier serves both blocks and drops requests while a fetch is in flight,
    // so a pending deep heal must not wait on this result's completion getting a turn.
    [SCDaemonBlockMethods healDeepBlockIfNeededWithVerifiedTime:verifiedNow reading:reading settings:settings];
    if (![SCBlockUtilities baseRulesFoundOnSystem]) {
        [self.daemonMethodLock unlock];
        return;
    }

    // Heal to at least SC_SELFHEAL_BLOCK_SECS, but never shorter than the block's
    // own stored duration when it's still known: tampering can only extend the
    // block, never shorten it (fail-closed).
    NSTimeInterval healSecs = [SCEnforcementDecision
        healDurationSecsForExistingDuration:[settings valueForKey:@"BlockDurationSecs"]];
    NSDate* healedEnd = [verifiedNow dateByAddingTimeInterval:healSecs];
    [settings setValue:@YES forKey:@"BlockIsRunning"];
    [settings setValue:healedEnd forKey:@"BlockEndDate"];
    [settings setValue:@(healSecs) forKey:@"BlockDurationSecs"];
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
    NSLog(@"INFO: Self-healed block end to verified now + %.0fs.", healSecs);

    [self.daemonMethodLock unlock];
}

+ (void)checkBlockIntegrity {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkBlockIntegrity called" category: @"daemon"];

    SCSettings* settings = [SCSettings sharedSettings];
    NSArray* installed = [SCBlockUtilities installedLayerNames];
    NSDictionary* deep = [SCBlockUtilities deepBlockRecord];
    BOOL deepEnforced = deep != nil || [installed containsObject:SCLayerDeep];
    // The real override state (not NO): the hosts watcher calls this during an
    // override too, and re-adding the lifted regular block would undo the override.
    NSArray* desired = [SCDeepBlockDecision desiredLayersWithBaseRunning:[SCBlockUtilities modernBlockIsRunning]
                                                          overrideActive:[SCDaemonBlockMethods overrideActiveNowInSettings:settings]
                                                       deepShouldEnforce:deepEnforced];
    BOOL missingLayer = NO;
    for (NSString* name in desired) if (![installed containsObject:name]) missingLayer = YES;
    BOOL desiredHasBlocklist = NO;
    if ([desired containsObject:SCLayerBase] && ![settings boolForKey:@"ActiveBlockAsWhitelist"]) desiredHasBlocklist = YES;
    BOOL deepListStale = NO;
    if ([desired containsObject:SCLayerDeep]) {
        NSString* anchor = [NSString stringWithContentsOfFile:@"/etc/pf.anchors/org.eyebeam" encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* installedPayload = [SCRuleCompiler deepPayloadFromAnchorText:anchor];
        NSDictionary* deepInfo = [SCDeepBlockDecision recordListIsUsable:deep] ? deep : installedPayload;
        // A failed add leaves the record ahead of what's installed: re-apply until it's covered.
        deepListStale = [SCDeepBlockDecision deepListIsStaleForRecord:deep installedPayload:installedPayload];
        // Unknown mode (no usable record or payload) counts as a blocklist: expecting
        // hosts entries can only add enforcement.
        id deepMode = deepInfo[@"isAllowlist"];
        if (![deepMode isKindOfClass:[NSNumber class]] || ![deepMode boolValue]) desiredHasBlocklist = YES;
    }
    HostFileBlockerSet* hostFileBlockerSet = [[HostFileBlockerSet alloc] init];
    BOOL hostsMissing = desiredHasBlocklist && ![hostFileBlockerSet.defaultBlocker containsSelfControlBlock];
    // The files above can say "installed" while nothing is enforced: macOS loads
    // /etc/pf.conf at boot without enabling pf, `pfctl -d` turns pf off, and the
    // anchor can be flushed. Ask pf itself (re-apply takes a fresh -E reference).
    BOOL pfNotEnforcing = NO;
    if (desired.count > 0) {
        BOOL pfEnabled = [PacketFilter pfIsEnabled];
        BOOL anchorLoaded = pfEnabled && [PacketFilter anchorRulesLoaded];
        pfNotEnforcing = !pfEnabled || !anchorLoaded;
        if (pfNotEnforcing) NSLog(@"WARNING: pf is %@; SelfControl rules aren't being enforced.",
                                  pfEnabled ? @"enabled but our anchor has no rules loaded" : @"disabled");
    }

    // Only ever ADDS missing enforcement (tightening): no teardown first, and every
    // installed layer is kept. Removing a layer is a relaxing transition and happens
    // solely on verified paths (or an override / emergency unlock).
    // Known limitation: with the deep record gone, a deep layer that was also removed
    // can't be restored here (no record, no anchor payload); the heal path rebuilds it
    // from the payload while the anchor still carries it. An attacker with root
    // deleting both the record and the anchor is out of scope.
    if (missingLayer || hostsMissing || pfNotEnforcing || deepListStale) {
        // applyDesiredLayers rebuilds a record-less deep layer from the anchor payload.
        NSMutableOrderedSet* layers = [NSMutableOrderedSet orderedSetWithArray:desired];
        [layers addObjectsFromArray:installed];
        __block BOOL attempted = NO;
        BOOL reapplied = [SCDaemonBlockMethods installThrottled:^BOOL{
            attempted = YES;
            NSLog(@"INFO: Block enforcement missing (installed [%@], desired [%@], hosts %@, pf %@, deep list %@); re-adding...",
                  [installed componentsJoinedByString:@","], [desired componentsJoinedByString:@","],
                  hostsMissing ? @"missing" : @"ok", pfNotEnforcing ? @"not enforcing" : @"ok",
                  deepListStale ? @"stale" : @"ok");
            if (![SCHelperToolUtilities applyDesiredLayers:layers.array]) return NO;
            if (deepListStale) {
                NSString* after = [NSString stringWithContentsOfFile:@"/etc/pf.anchors/org.eyebeam" encoding:NSUTF8StringEncoding error:nil];
                if (![SCDeepBlockDecision installedPayload:[SCRuleCompiler deepPayloadFromAnchorText:after] coversRecord:deep]) {
                    NSLog(@"ERROR: Rules re-applied but the installed deep list still lacks the record's sites.");
                    return NO;
                }
            }
            // A "successful" load that still leaves pf off or our anchor empty is a
            // failure too: back off instead of flushing states every check.
            if (pfNotEnforcing && !([PacketFilter pfIsEnabled] && [PacketFilter anchorRulesLoaded])) {
                NSLog(@"ERROR: Rules re-applied but pf still isn't enforcing them.");
                return NO;
            }
            return YES;
        }];
        if (!attempted) {
            NSLog(@"INFO: Integrity check found missing enforcement; re-install backing off.");
        } else if (reapplied) {
            [SCHelperToolUtilities clearCachesIfRequested];
            if (deepListStale && [deep[@"applyPending"] boolValue]) {
                NSDictionary* current = [SCBlockUtilities deepBlockRecord];
                if (current != nil) {
                    NSMutableDictionary* cleared = [current mutableCopy];
                    [cleared removeObjectForKey: @"applyPending"];
                    [settings setValue: cleared forKey: @"DeepBlock"];
                    NSError* clearErr = [settings syncSettingsAndWait: 5];
                    if (clearErr != nil) NSLog(@"WARNING: Sync failed after clearing applyPending: %@", clearErr);
                }
            }
            NSLog(@"INFO: Integrity check ran; re-added block rules.");
            [SCSentry addBreadcrumb: @"Daemon found compromised block integrity and re-added rules" category: @"daemon"];
        } else {
            NSLog(@"ERROR: Integrity check failed to re-add block rules; will retry.");
        }
    } else NSLog(@"INFO: Integrity check ran; no action needed.");

    NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
    if (clockState.count > 0) {
        [settings setValue:[SCTrustedClock checkpointState:clockState
                                                   reading:[SCTrustedClock currentReading]]
                    forKey:@"TrustedClockState"];
    }
    // Re-read: the re-apply above may have just cleared applyPending on the record.
    NSDictionary* deepNow = [SCBlockUtilities deepBlockRecord];
    NSDictionary* deepClock = deepNow[@"clockState"];
    if ([deepClock isKindOfClass:[NSDictionary class]] && deepClock.count > 0) {
        NSMutableDictionary* updated = [deepNow mutableCopy];
        updated[@"clockState"] = [SCTrustedClock checkpointState:deepClock reading:[SCTrustedClock currentReading]];
        [settings setValue:updated forKey:@"DeepBlock"];
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
    // A deep layer installed without its record counts too: emergency unlock is
    // the way out when that record can't be rebuilt (no permanent block).
    if (![SCBlockUtilities modernBlockIsRunning] && ![SCHelperToolUtilities deepShouldEnforce]) {
        [self.daemonMethodLock unlock];
        reply(0, 0, 0, [SCErr errorWithCode: 321]); // no block to override
        return;
    }
    if (![SCBlockUtilities emergencyUnlockAllowedForCurrentBlocks]) {
        tediumChallenge = nil;
        [self.daemonMethodLock unlock];
        reply(0, 0, 0, [SCErr errorWithCode: 324]); // turned off for this block
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
    if (![SCBlockUtilities modernBlockIsRunning] && ![SCHelperToolUtilities deepShouldEnforce]) {
        // The block is actually gone (removed, expired, or never modern).
        tediumChallenge = nil;
        [self.daemonMethodLock unlock];
        reply(0, 0, 0, NO, [SCErr errorWithCode: 322]); // no active challenge/block
        return;
    }
    if (![SCBlockUtilities emergencyUnlockAllowedForCurrentBlocks]) {
        tediumChallenge = nil;
        [self.daemonMethodLock unlock];
        reply(0, 0, 0, NO, [SCErr errorWithCode: 324]); // turned off for this block
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
        if ([SCHelperToolUtilities removeAllBlocks]) {
            [SCSentry addBreadcrumb: @"Block removed via tedium override" category: @"daemon"];
            [[SCBlockEndVerifier sharedVerifier] reset];
            [SCDaemonBlockMethods stopCheckupTimerIfIdle];
            tediumChallenge = nil;
            removed = YES;
        } else {
            // Block (and its settings) stay. The completed challenge is kept, so the
            // next correct digit completes it again and retries the removal.
            NSLog(@"ERROR: Tedium override completed but removing the block failed.");
            reply(outcome, progress, nextDigit, NO, [SCErr errorWithCode: 300]);   // try again in a moment
            [self.daemonMethodLock unlock];
            return;
        }
    }

    reply(outcome, progress, nextDigit, removed, nil);
    [self.daemonMethodLock unlock];
}

+ (void)invalidateTediumChallenge {
    tediumChallenge = nil;
}

+ (NSInteger)errorCodeForOverrideResult:(SCOverrideInvokeResult)r {
    switch (r) {
        case SCOverrideInvokeDenyNoActiveBlock:   return 330;
        case SCOverrideInvokeDenyAlreadyActive:   return 331;
        case SCOverrideInvokeDenyDuringDeepBlock: return 332;
        case SCOverrideInvokeDenyNotAllowed:      return 333;
        case SCOverrideInvokeDenyExhausted:       return 335;
        case SCOverrideInvokeAllowed:             return 0;
    }
    return 300;
}

// Serializes invokes end-to-end (including the live network fetch, during
// which daemonMethodLock is NOT held). A concurrent invoke is refused as busy.
+ (NSLock*)overrideInvokeGate {
    static NSLock* gate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gate = [[NSLock alloc] init];
    });
    return gate;
}

// Phase 5: a deep block's presence alone denies overrides (fail-closed; its
// expiry is a verified transition that deletes the record). deepShouldEnforce
// also counts an installed deep layer, so a tampered-away record still denies.
+ (BOOL)deepBlockActiveInSettings:(SCSettings*)settings trustedNow:(NSDate*)trustedNow clockAnchored:(BOOL)clockAnchored {
    return [SCHelperToolUtilities deepShouldEnforce];
}

+ (void)invokeOverrideWithReply:(void(^)(NSInteger remainingAfter, NSDate* _Nullable overrideEndDate, NSError* _Nullable error))reply {
    NSLock* gate = [SCDaemonBlockMethods overrideInvokeGate];
    // (1) One invoke at a time, end to end.
    if (![gate tryLock]) {
        reply(0, nil, [SCErr errorWithCode: 320]); // busy; app may retry
        return;
    }
    // (2)
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: METHOD_LOCK_TIMEOUT]) {
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 320]); // busy; app may retry
        return;
    }
    SCSettings* settings = [SCSettings sharedSettings];

    // (3) Pre-check against stored state, so obviously-denied invokes (no block,
    // exhausted, already active, deep block, disabled) fail fast with no network.
    BOOL modernRunning = [SCBlockUtilities modernBlockIsRunning];
    NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
    NSDate* trustedNow = [SCTrustedClock trustedNowForState:clockState reading:[SCTrustedClock currentReading]];
    BOOL clockAnchored = [clockState isKindOfClass:[NSDictionary class]] && clockState[@"wallAnchor"] != nil;

    NSDictionary* ovState = nil;
    NSDate* overrideEndDate = [SCDaemonBlockMethods overrideEndDateFromSettings:settings outStateOut:&ovState];
    BOOL alreadyActive = [SCOverrideDecision liftRemainingSecsWithTrustedNow:trustedNow
                                                             overrideEndDate:overrideEndDate
                                                               clockAnchored:clockAnchored
                                                                 maxLiftSecs:SC_OVERRIDE_MAX_LIFT_SECS] > 0;
    BOOL deepActive = [SCDaemonBlockMethods deepBlockActiveInSettings:settings trustedNow:trustedNow clockAnchored:clockAnchored];

    NSDictionary* policy = [settings valueForKey:@"OverridePolicy"];
    NSInteger perDay  = [policy isKindOfClass:[NSDictionary class]] ? [policy[@"perDay"] integerValue] : 0;
    NSInteger minutes = [policy isKindOfClass:[NSDictionary class]] ? [policy[@"minutes"] integerValue] : 0;
    NSInteger remaining = [ovState[@"remainingToday"] integerValue];

    // (4) If a reset looks due, pre-check as if reset (never persisted here; the
    // real reset is re-evaluated below against VERIFIED time).
    NSInteger preRemaining = [SCDaemonBlockMethods overrideResetPendingForTrustedNow:trustedNow
                                                                        clockAnchored:clockAnchored
                                                                             settings:settings] ? perDay : remaining;

    // (5) `alreadyActive` is a separate deny reason, NOT folded into baseEnforcing
    // (else an invoke during an active override would report 330 not 331).
    SCOverrideInvokeResult preDecision = [SCOverrideDecision invokeAllowedWithBaseEnforcing:modernRunning
                                                                                 deepActive:deepActive
                                                                              alreadyActive:alreadyActive
                                                                               policyPerDay:perDay
                                                                             remainingToday:preRemaining];
    if (preDecision != SCOverrideInvokeAllowed) {
        [self.daemonMethodLock unlock];
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode:[SCDaemonBlockMethods errorCodeForOverrideResult:preDecision]]);
        return;
    }
    if (minutes <= 0) {
        [self.daemonMethodLock unlock];
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 333]);
        return;
    }

    // (6) Capture the generation, then release the daemon lock for the fetch
    // (never hold it across network I/O). The gate stays held.
    NSUInteger generation = [[SCBlockEndVerifier sharedVerifier] currentGeneration];
    [self.daemonMethodLock unlock];

    // (7) Relaxing action => require LIVE network-verified time (master spec:
    // "no internet => no override"). The stored anchor is not sufficient.
    // __block storage is heap-promoted when dispatch_async copies the block, so a
    // late worker write after a timeout is memory-safe; we simply never read the
    // vars after a timeout.
    //
    // At most one SNTP worker in flight: a worker from an earlier invoke that hit
    // the hard deadline may still be running (the gate was released on timeout),
    // and repeated invokes must not pile up more. The daemon lock is already
    // released here and the gate is held, so the only thing to undo on refusal
    // is the gate. The flag is set here (only when we are about to dispatch) and
    // cleared solely by the worker at the very end of its work, whether or not
    // we timed out waiting for it -- so no return path below can leak it.
    if (atomic_exchange(&sOverrideSNTPWorkerInFlight, true)) {
        NSLog(@"WARNING: Override invoke refused: previous network-time fetch still in flight.");
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 320]); // busy; app may retry
        return;
    }
    __block NSDate* verified = nil;
    __block NSDictionary* verifiedReading = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSDictionary* r = nil;
            NSDate* v = [SCSNTPClient fetchNetworkTimeWithTimeout:SC_OVERRIDE_VERIFY_TIMEOUT_SECS readingAtResponse:&r];
            verified = v;
            verifiedReading = r;
        }
        atomic_store(&sOverrideSNTPWorkerInFlight, false);
        dispatch_semaphore_signal(done);
    });
    long waitResult = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SC_OVERRIDE_VERIFY_HARD_DEADLINE_SECS * NSEC_PER_SEC)));
    NSDate* verifiedNow = nil;
    NSDictionary* reading = nil;
    if (waitResult == 0) {
        verifiedNow = verified;
        reading = verifiedReading;
    }
    if (waitResult != 0 || verifiedNow == nil || reading == nil) {
        NSLog(@"WARNING: Override invoke denied: could not verify network time (%@).",
              waitResult != 0 ? @"hard deadline exceeded" : @"fetch failed");
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 334]); // couldn't verify internet time
        return;
    }

    // (8)
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: METHOD_LOCK_TIMEOUT]) {
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 320]);
        return;
    }

    // (9) A teardown/restart during the fetch invalidates this result.
    if (![SCBlockUtilities modernBlockIsRunning] ||
        ![[SCBlockEndVerifier sharedVerifier] isCurrentGeneration:generation]) {
        [self.daemonMethodLock unlock];
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 330]);
        return;
    }

    // (10) Apply verified time via the same applyVerifiedTime: path that
    // handleVerifiedTime: uses (the ration reset is handled in (12)/(13)/(14)).
    BOOL removed = NO;
    BOOL correctedStart = NO;
    if (![SCDaemonBlockMethods applyVerifiedTime:verifiedNow
                                         reading:reading
                                        settings:settings
                                  didRemoveBlock:&removed
                                  startCorrected:&correctedStart]) {
        [self.daemonMethodLock unlock];
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 334]);
        return;
    }
    if (removed) {
        // Verified-expired: the helper already tore the block down (removeBlock
        // persists its own state, as in handleVerifiedTime:).
        [self.daemonMethodLock unlock];
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 330]);
        return;
    }
    NSNumber* remainingAfterVerify = [SCBlockUtilities trustedRemainingBlockDurationSecs];
    if (remainingAfterVerify != nil && remainingAfterVerify.doubleValue <= 0) {
        // Verified-expired but the removal failed: never spend an override on it.
        // Persist the verified-time writes; the next verification retries removal.
        NSError* syncError = [settings syncSettingsAndWait:5];
        if (syncError != nil) NSLog(@"WARNING: failed to persist verified time: %@", syncError);
        [self.daemonMethodLock unlock];
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode: 300]);
        return;
    }

    // (11) Re-read everything against the freshly verified state.
    NSDictionary* clockState2 = [settings valueForKey:@"TrustedClockState"];
    NSDate* trustedNow2 = [SCTrustedClock trustedNowForState:clockState2 reading:[SCTrustedClock currentReading]];
    BOOL clockAnchored2 = [clockState2 isKindOfClass:[NSDictionary class]] && clockState2[@"wallAnchor"] != nil;
    NSDictionary* ovState2 = nil;
    NSDate* overrideEndDate2 = [SCDaemonBlockMethods overrideEndDateFromSettings:settings outStateOut:&ovState2];
    NSDictionary* policy2 = [settings valueForKey:@"OverridePolicy"];
    NSInteger perDay2  = [policy2 isKindOfClass:[NSDictionary class]] ? [policy2[@"perDay"] integerValue] : 0;
    NSInteger minutes2 = [policy2 isKindOfClass:[NSDictionary class]] ? [policy2[@"minutes"] integerValue] : 0;
    NSInteger remaining2 = [ovState2[@"remainingToday"] integerValue];
    id lastReset2 = ovState2[@"lastResetDay"];
    NSString* lastResetStr2 = [lastReset2 isKindOfClass:[NSString class]] ? lastReset2 : nil;
    BOOL alreadyActive2 = [SCOverrideDecision liftRemainingSecsWithTrustedNow:trustedNow2
                                                              overrideEndDate:overrideEndDate2
                                                                clockAnchored:clockAnchored2
                                                                  maxLiftSecs:SC_OVERRIDE_MAX_LIFT_SECS] > 0;
    BOOL deepActive2 = [SCDaemonBlockMethods deepBlockActiveInSettings:settings trustedNow:trustedNow2 clockAnchored:clockAnchored2];

    // (12) Midnight reset against the verified day (pinned activation zone).
    NSString* verifiedDay = (trustedNow2 != nil)
        ? [SCOverrideDecision dayStringForDate:trustedNow2 timeZone:[SCDaemonBlockMethods activationTimeZoneFromSettings:settings]]
        : nil;
    NSInteger resetRemaining = 0;
    if (verifiedDay != nil && [SCOverrideDecision resetForVerifiedDay:verifiedDay
                                                         lastResetDay:lastResetStr2
                                                               perDay:perDay2
                                                      outNewRemaining:&resetRemaining]) {
        remaining2 = resetRemaining; // lastResetDay becomes verifiedDay on commit
    }

    // (13) Final decision.
    SCOverrideInvokeResult decision = [SCOverrideDecision invokeAllowedWithBaseEnforcing:YES
                                                                              deepActive:deepActive2
                                                                           alreadyActive:alreadyActive2
                                                                            policyPerDay:perDay2
                                                                          remainingToday:remaining2];
    NSInteger denyCode = 0;
    if (decision != SCOverrideInvokeAllowed) {
        denyCode = [SCDaemonBlockMethods errorCodeForOverrideResult:decision];
    } else if (minutes2 <= 0) {
        denyCode = 333;
    } else if (trustedNow2 == nil || !clockAnchored2 || verifiedDay == nil) {
        // Defensive: the verified decision always writes an anchored clock state.
        denyCode = 334;
    }
    if (denyCode != 0) {
        // Denied, but we hold verified time: persist the verified-time writes we
        // already made plus any due daily ration reset (the same verified-time
        // side effects handleVerifiedTime: persists), so a deny doesn't leave a
        // due reset unpersisted.
        BOOL resetApplied = [SCDaemonBlockMethods applyOverrideResetForVerifiedNow:verifiedNow settings:settings];
        if (resetApplied) NSLog(@"INFO: Daily override ration reset against verified network time.");
        NSError* syncError = [settings syncSettingsAndWait:5];
        if (syncError != nil) NSLog(@"WARNING: failed to persist verified time: %@", syncError);
        if (correctedStart || resetApplied) [SCHelperToolUtilities sendConfigurationChangedNotification];
        [self.daemonMethodLock unlock];
        [gate unlock];
        reply(0, nil, [SCErr errorWithCode:denyCode]);
        return;
    }

    // (14) Commit. Clamp the lift to the same ceiling the checkup overlay enforces,
    // so a misconfigured (large) `minutes` can't produce an overrideEndDate the
    // overlay would immediately reject (burning a counter for a zero-length lift).
    remaining2 -= 1;
    NSTimeInterval liftSecs = MIN(minutes2 * 60.0, SC_OVERRIDE_MAX_LIFT_SECS);
    NSDate* end = [trustedNow2 dateByAddingTimeInterval:liftSecs];
    // lastResetDay never moves backwards (a wall-clock-seeded future day stays).
    NSString* storedResetDay = [ovState2[@"lastResetDay"] isKindOfClass:[NSString class]] ? ovState2[@"lastResetDay"] : nil;
    NSString* committedResetDay = (storedResetDay != nil && [storedResetDay compare:verifiedDay] == NSOrderedDescending)
        ? storedResetDay : verifiedDay;
    [settings setValue:@{ @"remainingToday": @(remaining2),
                          @"lastResetDay": committedResetDay,
                          @"overrideEndDate": end }
                forKey:@"OverrideState"];
    NSError* syncError = [settings syncSettingsAndWait:5];
    if (syncError != nil) NSLog(@"WARNING: failed to persist override state: %@", syncError);

    // (15) Lift base rules now (don't wait a tick), then tell the app.
    [SCHelperToolUtilities clearBlockRulesOnly];
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    NSLog(@"INFO: Override invoked against verified time; %ld remaining today; lifts until %@", (long)remaining2, end);
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
    [gate unlock];
    reply(remaining2, end, nil);
}

// Read-only, no daemonMethodLock (no writes, and this must never block behind
// a slow checkup/invoke), no network. Mirrors the checkup's fail-closed
// overlay computation (see checkupBlock) so the UI's notion of "active" and
// "remaining" always matches enforcement.
+ (void)getOverrideStatusWithReply:(void(^)(BOOL blockRunning, BOOL overrideActive, double overrideRemainingSecs, NSInteger remainingToday, NSInteger perDay))reply {
    SCSettings* settings = [SCSettings sharedSettings];
    BOOL blockRunning, overrideActive;
    NSTimeInterval remainingSecs;
    NSInteger remainingToday, perDay;

    // No daemonMethodLock, but hold SCSettings' own (brief, recursive) monitor so
    // this frequent poll can't read the settings dictionary mid-mutation/reload.
    @synchronized (settings) {
        blockRunning = [SCBlockUtilities modernBlockIsRunning];

        NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
        NSDate* trustedNow = [SCTrustedClock trustedNowForState:clockState reading:[SCTrustedClock currentReading]];
        BOOL clockAnchored = [clockState isKindOfClass:[NSDictionary class]] && clockState[@"wallAnchor"] != nil;

        NSDictionary* ovState = nil;
        NSDate* overrideEndDate = [SCDaemonBlockMethods overrideEndDateFromSettings:settings outStateOut:&ovState];
        remainingSecs = [SCOverrideDecision liftRemainingSecsWithTrustedNow:trustedNow
                                                            overrideEndDate:overrideEndDate
                                                              clockAnchored:clockAnchored
                                                                maxLiftSecs:SC_OVERRIDE_MAX_LIFT_SECS];
        overrideActive = remainingSecs > 0;

        remainingToday = [ovState isKindOfClass:[NSDictionary class]] ? [ovState[@"remainingToday"] integerValue] : 0;
        NSDictionary* policy = [settings valueForKey:@"OverridePolicy"];
        perDay = [policy isKindOfClass:[NSDictionary class]] ? [policy[@"perDay"] integerValue] : 0;
    }

    reply(blockRunning, overrideActive, remainingSecs, remainingToday, perDay);
}

@end
