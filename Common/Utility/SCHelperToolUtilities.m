//
//  SCHelperToolUtilities.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import "SCHelperToolUtilities.h"
#import "BlockManager.h"
#import "SCRuleCompiler.h"
#import "SCDeepBlockDecision.h"

@implementation SCHelperToolUtilities

// A resolution option from a deep record or payload. Absent / non-number
// means the fail-closed choice: for a blocklist, evaluating common subdomains
// and linked domains blocks more (YES); for an allowlist they allow more (NO).
// allowLocal (allowlist only) defaults to NO.
static BOOL SCDeepOption(NSDictionary* deep, NSString* key, BOOL failClosedDefault) {
    id value = deep[key];
    return [value isKindOfClass: [NSNumber class]] ? [value boolValue] : failClosedDefault;
}

+ (SCRuleLayer*)resolvedLayerNamed:(NSString*)name
                       hostDomains:(NSMutableOrderedSet<NSString*>*)hostDomains
                   installedAnchor:(NSString*)installedAnchor {
    SCSettings* settings = [SCSettings sharedSettings];
    NSArray* entries; BOOL allowlist, allowLocal, commonSubdomains, linkedDomains;
    NSDictionary* payload = nil;
    if ([name isEqualToString: SCLayerDeep]) {
        NSDictionary* deep = [SCBlockUtilities deepBlockRecord];
        if (deep != nil && ![SCDeepBlockDecision recordListIsUsable: deep]) {
            // A record whose list or mode has the wrong type can't say what to
            // enforce (and a guessed mode could relax it): treat it as unusable.
            NSLog(@"WARNING: Deep block record has an unusable blocklist/isAllowlist; using the installed payload.");
            deep = nil;
        }
        if (deep == nil) {
            // Record tampered away (or unusable) but the layer is installed: keep
            // enforcing the installed list (from the anchor payload) until the heal
            // path rebuilds it. The payload parser validates the same types.
            deep = [SCRuleCompiler deepPayloadFromAnchorText: installedAnchor];
            if (deep == nil) return nil;   // can't rebuild: caller must not touch the rules
        }
        entries = deep[@"blocklist"];
        allowlist = [deep[@"isAllowlist"] boolValue];
        allowLocal = SCDeepOption(deep, @"allowLocal", NO);
        commonSubdomains = SCDeepOption(deep, @"evaluateCommonSubdomains", !allowlist);
        linkedDomains = SCDeepOption(deep, @"includeLinkedDomains", !allowlist);
        NSMutableDictionary* p = [@{@"blocklist": entries,
                                    @"isAllowlist": @(allowlist),
                                    @"allowLocal": @(allowLocal),
                                    @"evaluateCommonSubdomains": @(commonSubdomains),
                                    @"includeLinkedDomains": @(linkedDomains)} mutableCopy];
        if ([deep[@"emergencyUnlockEnabled"] isKindOfClass: [NSNumber class]]) p[@"emergencyUnlockEnabled"] = deep[@"emergencyUnlockEnabled"];
        payload = p;
    } else {
        entries = [settings valueForKey: @"ActiveBlocklist"];
        allowlist = [settings boolForKey: @"ActiveBlockAsWhitelist"];
        allowLocal = [settings boolForKey: @"AllowLocalNetworks"];
        commonSubdomains = [settings boolForKey: @"EvaluateCommonSubdomains"];
        linkedDomains = [settings boolForKey: @"IncludeLinkedDomains"];
    }
    if (![entries isKindOfClass: [NSArray class]]) entries = @[];

    BlockManager* bm = [[BlockManager alloc] initAsAllowlist: allowlist allowLocal: allowLocal
                                     includeCommonSubdomains: commonSubdomains includeLinkedDomains: linkedDomains];
    NSArray* specs = nil; NSArray* domains = nil;
    [bm resolveEntries: entries specs: &specs hostDomains: &domains];
    if (!allowlist) {
        [hostDomains addObjectsFromArray: domains];
        // Tighten-only: a running blocklist layer keeps every address it already
        // blocks. Re-resolution happens under our own hosts sinkhole (blocked
        // domains -> 0.0.0.0 / ::) or possibly offline, so a fresh lookup can come
        // back short; that must never shrink a running block. The compiler dedupes.
        // Never for an allowlist layer: a union there would allow MORE.
        specs = [specs arrayByAddingObjectsFromArray:
                 [SCRuleCompiler blocklistSpecsForLayer: name inAnchorText: installedAnchor]];
    }

    SCRuleLayer* layer = [SCRuleLayer layerWithName: name isAllowlist: allowlist allowLocal: allowLocal specs: specs];
    layer.payload = payload;
    return layer;
}

+ (BOOL)applyDesiredLayers:(NSArray<NSString*>*)layerNames {
    NSLog(@"INFO: Applying block layers: [%@]", [layerNames componentsJoinedByString: @","]);
    if (layerNames.count == 0) {
        BOOL cleared = [[BlockManager new] clearBlock];
        [SCHelperToolUtilities clearOSDNSCache];
        return cleared;
    }
    // Read once: the deep fallback payload and the tighten-only union both come from it.
    NSString* installedAnchor = [NSString stringWithContentsOfFile: @"/etc/pf.anchors/org.eyebeam" encoding: NSUTF8StringEncoding error: nil];
    NSMutableOrderedSet<NSString*>* hostDomains = [NSMutableOrderedSet orderedSet];
    NSMutableArray<SCRuleLayer*>* layers = [NSMutableArray array];
    BOOL anyBlocklist = NO;
    for (NSString* name in layerNames) {
        SCRuleLayer* layer = [self resolvedLayerNamed: name hostDomains: hostDomains installedAnchor: installedAnchor];
        if (layer == nil) {
            // Known limitation: the deep record AND the anchor's payload are both
            // gone (requires root tampering). The installed rules are left exactly
            // as they are (fail-closed), but no layer change can be applied - e.g.
            // a new regular block can't be layered on - until a heal rebuilds the
            // deep record. Callers see NO.
            NSLog(@"WARNING: Can't resolve block layer %@; leaving installed rules untouched.", name);
            return NO;
        }
        anyBlocklist = anyBlocklist || !layer.isAllowlist;
        [layers addObject: layer];
    }
    NSString* anchorText = [SCRuleCompiler anchorTextForLayers: layers];
    BlockManager* writer = [[BlockManager alloc] init];
    BOOL installed = [writer installAnchorText: anchorText hostDomains: anyBlocklist ? hostDomains.array : nil];
    if (!installed) {
        NSLog(@"ERROR: Failed to install block layers.");
    }
    [SCHelperToolUtilities clearOSDNSCache];
    return installed;
}

// The deep layer is enforced while its record exists OR its rules are installed
// (a tampered-away record must never relax enforcement; only a verified expiry or
// emergency unlock removes it, and those pass explicit layers).
+ (BOOL)deepShouldEnforce {
    return [SCBlockUtilities deepBlockIsRunning] || [[SCBlockUtilities installedLayerNames] containsObject: SCLayerDeep];
}

+ (NSArray<NSString*>*)desiredLayersWithOverrideActive:(BOOL)overrideActive {
    return [SCDeepBlockDecision desiredLayersWithBaseRunning: [SCBlockUtilities modernBlockIsRunning]
                                               overrideActive: overrideActive
                                            deepShouldEnforce: [self deepShouldEnforce]];
}

+ (BOOL)installBlockRulesFromSettings {
    return [self applyDesiredLayers: [self desiredLayersWithOverrideActive: NO]];
}

+ (BOOL)clearBlockRulesOnly {
    NSLog(@"INFO: Lifting base block rules (override active).");
    return [self applyDesiredLayers: [self desiredLayersWithOverrideActive: YES]];
}

+ (void)unloadDaemonJob {
    NSLog(@"Unloading SelfControl daemon...");
    [SCSentry addBreadcrumb: @"Daemon about to unload" category: @"daemon"];
    SCSettings* settings = [SCSettings sharedSettings];

    // we're about to unload the launchd job
    // this will kill this process, so we have to make sure
    // all settings are synced before we unload
    NSError* syncErr = [settings syncSettingsAndWait: 5.0];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ before unloading daemon job", syncErr);
        [SCSentry captureError: syncErr];
    }
    
    // SMAppService fork: the daemon can't SMJobRemove itself anymore.
    // A clean exit(0) plus KeepAlive={SuccessfulExit=false} in the launchd
    // plist means we stay dead until launchd relaunches us on-demand
    // (next XPC connection) or at boot (RunAtLoad).
    NSLog(@"Daemon idle; exiting cleanly.");
    exit(EXIT_SUCCESS);
}

+ (void)clearCachesIfRequested {
    SCSettings* settings = [SCSettings sharedSettings];
    if(![settings boolForKey: @"ClearCaches"]) {
        return;
    }
    
    NSError* err = [SCHelperToolUtilities clearBrowserCaches];
    if (err) {
        NSLog(@"WARNING: Error clearing browser caches: %@", err);
        [SCSentry captureError: err];
    }

    [SCHelperToolUtilities clearOSDNSCache];
}

+ (NSError*)clearBrowserCaches {
    NSFileManager* fileManager = [NSFileManager defaultManager];

    NSError* homeDirErr = nil;
    NSArray<NSURL *>* homeDirectoryURLs = [SCMiscUtilities allUserHomeDirectoryURLs: &homeDirErr];
    if (homeDirectoryURLs == nil) return homeDirErr;
    
    NSArray<NSString*>* cacheDirPathComponents = @[
        // chrome
        @"/Library/Caches/Google/Chrome/Default",
        @"/Library/Caches/Google/Chrome/com.google.Chrome",
        
        // firefox
        @"/Library/Caches/Firefox/Profiles",
        
        // safari
        @"/Library/Caches/com.apple.Safari",
        @"/Library/Containers/com.apple.Safari/Data/Library/Caches" // this one seems to fail due to permissions issues, but not sure how to fix
    ];
    
    
    NSMutableArray<NSURL*>* cacheDirURLs = [NSMutableArray arrayWithCapacity: cacheDirPathComponents.count * homeDirectoryURLs.count];
    for (NSURL* homeDirURL in homeDirectoryURLs) {
        for (NSString* cacheDirPathComponent in cacheDirPathComponents) {
            [cacheDirURLs addObject: [homeDirURL URLByAppendingPathComponent: cacheDirPathComponent isDirectory: YES]];
        }
    }
    
    for (NSURL* cacheDirURL in cacheDirURLs) {
        NSLog(@"Clearing browser cache folder %@", cacheDirURL);
        // removeItemAtURL will return errors if the file doesn't exist
        // so we don't track the errors - best effort is OK
        [fileManager removeItemAtURL: cacheDirURL error: nil];
    }
    
    return nil;
}

+ (void)clearOSDNSCache {
    // no error checks - if it works it works!
    NSTask* flushDsCacheUtil = [[NSTask alloc] init];
    [flushDsCacheUtil setLaunchPath: @"/usr/bin/dscacheutil"];
    [flushDsCacheUtil setArguments: @[@"-flushcache"]];
    [flushDsCacheUtil launch];
    [flushDsCacheUtil waitUntilExit];
    
    NSTask* killResponder = [[NSTask alloc] init];
    [killResponder setLaunchPath: @"/usr/bin/killall"];
    [killResponder setArguments: @[@"-HUP", @"mDNSResponder"]];
    [killResponder launch];
    [killResponder waitUntilExit];
    
    NSTask* killResponderHelper = [[NSTask alloc] init];
    [killResponderHelper setLaunchPath: @"/usr/bin/killall"];
    [killResponderHelper setArguments: @[@"mDNSResponderHelper"]];
    [killResponderHelper launch];
    [killResponderHelper waitUntilExit];
    
    NSLog(@"Cleared OS DNS caches");
}

+ (void)playBlockEndSound {
    [self playSoundIfOnKey: @"BlockSoundShouldPlay" indexKey: @"BlockSound"];
}

+ (void)playOverrideEndSound {
    [self playSoundIfOnKey: @"OverrideSoundShouldPlay" indexKey: @"OverrideSound"];
}

+ (void)playSoundIfOnKey:(NSString*)onKey indexKey:(NSString*)indexKey {
    SCSettings* settings = [SCSettings sharedSettings];
    if(![settings boolForKey: onKey]) return;
    // Map the tags used in interface builder to the sound
    NSArray* systemSoundNames = SCConstants.systemSoundNames;
    NSUInteger index = (NSUInteger)[[settings valueForKey: indexKey] intValue];
    NSSound* alertSound = index < systemSoundNames.count ? [NSSound soundNamed: systemSoundNames[index]] : nil;
    if(!alertSound)
        NSLog(@"WARNING: Alert sound not found.");
    else {
        [alertSound play];
    }
}

// Both removals apply the target rules FIRST and only clear settings once the
// rules really came off. A failed teardown leaves the block "running and
// expired" in settings, so the next verified time retries the removal; clearing
// settings first would let the integrity/heal paths rebuild the still-installed
// rules into a fresh block.
+ (BOOL)removeBlock {
    NSArray* layers = [SCDeepBlockDecision desiredLayersWithBaseRunning: NO
                                                         overrideActive: NO
                                                      deepShouldEnforce: [self deepShouldEnforce]];   // deep layer only, or teardown
    if (![self applyDesiredLayers: layers]) {
        NSLog(@"ERROR: Failed to remove the regular block's rules; keeping its settings so removal is retried.");
        return NO;
    }
    [SCBlockUtilities removeBlockFromSettings];
    [self finishRemovingBlock];
    return YES;
}

+ (BOOL)removeAllBlocks {
    if (![self applyDesiredLayers: @[]]) {   // explicit: the deep layer goes too
        NSLog(@"ERROR: Failed to clear all block rules; keeping block settings so removal is retried.");
        return NO;
    }
    [SCBlockUtilities removeDeepBlockFromSettings];
    [SCBlockUtilities removeBlockFromSettings];
    [self finishRemovingBlock];
    return YES;
}

+ (void)finishRemovingBlock {
    [SCHelperToolUtilities clearCachesIfRequested];

    // play a sound letting
    [SCHelperToolUtilities playBlockEndSound];
        
    // always synchronize settings ASAP after removing a block to let everybody else know
    // and wait until they're synced before we send the configuration change notification
    // so the app has no chance of reading the data before we update it
    NSError* syncErr = [[SCSettings sharedSettings] syncSettingsAndWait: 5.0];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after removing block", syncErr);
        [SCSentry captureError: syncErr];
    }

    // let the main app know things have changed so it can update the UI!
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    NSLog(@"INFO: Block cleared.");
}

+ (void)sendConfigurationChangedNotification {
    // if you don't include the NSNotificationPostToAllSessions option,
    // it will not deliver when run by launchd (root) to the main app being run by the user
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification"
                                                                   object: nil
                                                                 userInfo: nil
                                                                  options: NSNotificationDeliverImmediately | NSNotificationPostToAllSessions];
}

@end
