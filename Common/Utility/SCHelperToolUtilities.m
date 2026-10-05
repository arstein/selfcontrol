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

+ (SCRuleLayer*)resolvedLayerNamed:(NSString*)name hostDomains:(NSMutableOrderedSet<NSString*>*)hostDomains {
    SCSettings* settings = [SCSettings sharedSettings];
    NSArray* entries; BOOL allowlist, allowLocal, commonSubdomains, linkedDomains;
    NSDictionary* payload = nil;
    if ([name isEqualToString: SCLayerDeep]) {
        NSDictionary* deep = [SCBlockUtilities deepBlockRecord];
        if (deep == nil) {
            // Record tampered away but the layer is installed: keep enforcing the
            // installed list (from the anchor payload) until the heal path rebuilds it.
            NSString* anchor = [NSString stringWithContentsOfFile: @"/etc/pf.anchors/org.eyebeam" encoding: NSUTF8StringEncoding error: nil];
            deep = [SCRuleCompiler deepPayloadFromAnchorText: anchor];
            if (deep == nil) return nil;   // can't rebuild: caller must not touch the rules
        }
        entries = deep[@"blocklist"];
        allowlist = [deep[@"isAllowlist"] boolValue];
        allowLocal = [deep[@"allowLocal"] boolValue];
        commonSubdomains = [deep[@"evaluateCommonSubdomains"] boolValue];
        linkedDomains = [deep[@"includeLinkedDomains"] boolValue];
        NSMutableDictionary* p = [@{@"blocklist": entries ?: @[], @"isAllowlist": @(allowlist)} mutableCopy];
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
    if (!allowlist) [hostDomains addObjectsFromArray: domains];

    SCRuleLayer* layer = [SCRuleLayer layerWithName: name isAllowlist: allowlist allowLocal: allowLocal specs: specs];
    layer.payload = payload;
    return layer;
}

+ (void)applyDesiredLayers:(NSArray<NSString*>*)layerNames {
    NSLog(@"INFO: Applying block layers: [%@]", [layerNames componentsJoinedByString: @","]);
    if (layerNames.count == 0) {
        [[BlockManager new] clearBlock];
        [SCHelperToolUtilities clearOSDNSCache];
        return;
    }
    NSMutableOrderedSet<NSString*>* hostDomains = [NSMutableOrderedSet orderedSet];
    NSMutableArray<SCRuleLayer*>* layers = [NSMutableArray array];
    BOOL anyBlocklist = NO;
    for (NSString* name in layerNames) {
        SCRuleLayer* layer = [self resolvedLayerNamed: name hostDomains: hostDomains];
        if (layer == nil) {
            NSLog(@"WARNING: Can't resolve block layer %@; leaving installed rules untouched.", name);
            return;
        }
        anyBlocklist = anyBlocklist || !layer.isAllowlist;
        [layers addObject: layer];
    }
    NSString* anchorText = [SCRuleCompiler anchorTextForLayers: layers];
    BlockManager* writer = [[BlockManager alloc] init];
    if (![writer installAnchorText: anchorText hostDomains: anyBlocklist ? hostDomains.array : nil]) {
        NSLog(@"ERROR: Failed to install block layers.");
    }
    [SCHelperToolUtilities clearOSDNSCache];
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

+ (void)installBlockRulesFromSettings {
    [self applyDesiredLayers: [self desiredLayersWithOverrideActive: NO]];
}

+ (void)clearBlockRulesOnly {
    NSLog(@"INFO: Lifting base block rules (override active).");
    [self applyDesiredLayers: [self desiredLayersWithOverrideActive: YES]];
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
    SCSettings* settings = [SCSettings sharedSettings];
    if([settings boolForKey: @"BlockSoundShouldPlay"]) {
        // Map the tags used in interface builder to the sound
        NSArray* systemSoundNames = SCConstants.systemSoundNames;
        NSSound* alertSound = [NSSound soundNamed: systemSoundNames[(NSUInteger)[[settings valueForKey: @"BlockSound"] intValue]]];
        if(!alertSound)
            NSLog(@"WARNING: Alert sound not found.");
        else {
            [alertSound play];
        }
    }
}

+ (void)removeBlock {
    [SCBlockUtilities removeBlockFromSettings];
    [self applyDesiredLayers: [self desiredLayersWithOverrideActive: NO]];   // deep layer only, or teardown
    [self finishRemovingBlock];
}

+ (void)removeAllBlocks {
    [SCBlockUtilities removeDeepBlockFromSettings];
    [SCBlockUtilities removeBlockFromSettings];
    [self applyDesiredLayers: @[]];   // explicit: the deep layer goes too
    [self finishRemovingBlock];
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
