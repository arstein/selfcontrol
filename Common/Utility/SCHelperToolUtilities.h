//
//  SCHelperToolUtilities.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/19/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Utility methods athat are only used by the helper tools
// (i.e. selfcontrold, selfcontrol-cli, and SCKillerHelper)
// note that this is NOT included in SCUtility.h currently!
@interface SCHelperToolUtilities : NSObject

// The single enforcement path: installs exactly these layers (SCLayerBase,
// SCLayerDeep) from settings, replacing whatever was there. Empty -> teardown.
// If a layer can't be resolved (deep layer with neither record nor anchor
// payload) nothing is changed (fail-closed). Running blocklist layers are
// tighten-only: addresses already in the installed anchor are kept.
// Returns YES when the rules were installed (or cleared); NO when a layer
// couldn't be resolved or the install failed (the previous rules then stay).
+ (BOOL)applyDesiredLayers:(NSArray<NSString*>*)layerNames;

// Installs the regular block's layer (plus the deep layer if a deep block exists).
+ (BOOL)installBlockRulesFromSettings;

// Lifts the regular block's layer for an override; a deep layer stays.
+ (BOOL)clearBlockRulesOnly;

// exits the daemon process cleanly once settings are synced; launchd's
// KeepAlive={SuccessfulExit=false} keeps it dead until relaunched on-demand
+ (void)unloadDaemonJob;

// Checks the settings system to see whether the user wants their web browser
// caches cleared, and deletes the specific cache folders for a few common
// web browsers if it is required.
+ (void)clearCachesIfRequested;

// Clear only the caches for browsers
+ (NSError*)clearBrowserCaches;

// Clear only the OS-level DNS cache
+ (void)clearOSDNSCache;

// Plays the user's block-end sound, if they asked for one.
+ (void)playBlockEndSound;
+ (void)playOverrideEndSound;

// YES while the deep layer must be enforced: its record exists OR its rules are
// installed (a tampered-away record never relaxes enforcement).
+ (BOOL)deepShouldEnforce;

// Removes the regular block (its rules, then settings, sound, caches); a running
// deep block stays enforced. Rules first: settings are cleared only when the rules
// came off. Returns NO (settings untouched, block still "running") on failure.
+ (BOOL)removeBlock;

// Emergency unlock: removes the regular block and the deep block, rules first as
// above. Returns NO (settings untouched) when the rules couldn't be cleared.
+ (BOOL)removeAllBlocks;

+ (void)sendConfigurationChangedNotification;

@end

NS_ASSUME_NONNULL_END
