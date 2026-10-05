//
//  AppController.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/29/09.
//  Copyright 2009 Eyebeam.

// This file is part of SelfControl.
//
// SelfControl is free software:  you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import "AppController.h"
#import "SCTimeIntervalFormatter.h"
#import <LetsMove/PFMoveApplication.h>
#import "SCSettings.h"
#import <ServiceManagement/ServiceManagement.h>
#import "SCXPCClient.h"
#import "SCBlockFileReaderWriter.h"
#import "SCUIUtilities.h"
#import "SCDurationSlider.h"
#import "SelfControl-Swift.h"

@interface AppController () {}

@property (atomic, strong, readwrite) SCXPCClient* xpc;
@property (nonatomic, strong, readwrite) MainWindowController* mainWindowController;
// Main-thread-only guard serializing the SwiftUI window's block modifications
// (add entries / extend).
@property (nonatomic, assign) BOOL modifyingBlock;

@end

@implementation AppController {
	NSWindowController* getStartedWindowController;
}

@synthesize addingBlock;

- (AppController*) init {
	if(self = [super init]) {

		defaults_ = [NSUserDefaults standardUserDefaults];
		[defaults_ registerDefaults: SCConstants.defaultUserDefaults];

		self.addingBlock = false;

		// refreshUILock_ is a lock that prevents a race condition by making the refreshUserInterface
		// method alter the blockIsOn variable atomically (will no longer be necessary once we can
		// use properties).
		refreshUILock_ = [[NSLock alloc] init];
	}

	return self;
}

- (IBAction)addBlock:(id)sender {
    if ([SCUIUtilities blockIsRunning]) {
		// This method shouldn't be getting called, a block is on so the Start button should be disabled.
        NSError* err = [SCErr errorWithCode: 104];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
		return;
	}
	if (([[defaults_ arrayForKey: @"Blocklist"] count] == 0) && ![defaults_ boolForKey: @"BlockAsWhitelist"]) {
		// Since the Start button should be disabled when the blocklist has no entries (and it's not an allowlist)
		// this should definitely not be happening.  Exit.

        NSError* err = [SCErr errorWithCode: 100];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];

		return;
	}

	if([defaults_ boolForKey: @"VerifyInternetConnection"] && ![SCUIUtilities networkConnectionIsAvailable]) {
        [SCDialog informWithTitle: NSLocalizedString(@"You're offline", @"No network connection when starting a block: title")
                          message: NSLocalizedString(@"SelfControl needs an internet connection to start a block. You can turn this check off in Settings.", @"No network connection when starting a block: message")];
		return;
	}

    // cancel if we pop up a warning about the super long block, and the user decides to cancel
    if (![self showLongBlockWarningsIfNecessary]) {
        return;
    }

	[NSThread detachNewThreadSelector: @selector(installBlock) toTarget: self withObject: nil];
}

// returns YES if we should continue with the block, NO if we should cancel it
- (BOOL)showLongBlockWarningsIfNecessary {
    // all UI stuff MUST be done on the main thread
    if (![NSThread isMainThread]) {
        __block BOOL retVal = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            retVal = [self showLongBlockWarningsIfNecessary];
        });
        return retVal;
    }
    
    NSString* LONG_BLOCK_SUPPRESSION_KEY = @"SuppressLongBlockWarning";
    int LONG_BLOCK_THRESHOLD_MINS = 2880; // 2 days
    int FIRST_TIME_LONG_BLOCK_THRESHOLD_MINS = 480; // 8 hours

    BOOL isFirstBlock = ![defaults_ boolForKey: @"FirstBlockStarted"];
    int blockDuration = [[self->defaults_ valueForKey: @"BlockDuration"] intValue];

    BOOL showLongBlockWarning = blockDuration >= LONG_BLOCK_THRESHOLD_MINS || (isFirstBlock && blockDuration >= FIRST_TIME_LONG_BLOCK_THRESHOLD_MINS);
    if (!showLongBlockWarning) return YES;

    // if they don't want warnings, they don't get warnings. their funeral 💀
    if ([self->defaults_ boolForKey: LONG_BLOCK_SUPPRESSION_KEY]) {
        return YES;
    }

    // Cancel answers both Esc and Return: Return must never start an irreversible block.
    SCDialogResult* result = [SCDialog runWithTitle: [NSString stringWithFormat: NSLocalizedString(@"Start a block for %@?", @"Long block warning title"), [SCDurationSlider timeSliderDisplayStringFromNumberOfMinutes: blockDuration]]
                                            message: NSLocalizedString(@"You won't be able to end it early, even if you've blocked something you need. If your list is new, try a short block first.", @"Long block warning message")
                                            buttons: @[NSLocalizedString(@"Cancel", @"Button to cancel a long block"),
                                                       NSLocalizedString(@"Start Block", @"Button to start a long block despite warnings")]
                                       primaryIndex: 1
                                        cancelIndex: 0
                                       defaultIndex: 0
                                   suppressionTitle: NSLocalizedString(@"Don't warn me about long blocks", @"Long block warning suppression checkbox")];
    if (result.suppressionChecked) {
        // no more warnings, they say
        [self->defaults_ setBool: YES forKey: LONG_BLOCK_SUPPRESSION_KEY];
    }
    if (result.buttonIndex != 1) {
        return NO;
    }
    
    return YES;
}


- (void)refreshUserInterface {
    // UI updates are for the main thread only!
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self refreshUserInterface];
        });
        return;
    }

    if(![refreshUILock_ tryLock]) {
        // already refreshing the UI, no need to wait and do it again
        return;
    }

    BOOL blockWasOn = blockIsOn;
    blockIsOn = [SCUIUtilities blockIsRunning];

    if (blockIsOn && !blockWasOn) {
        // apparently, a block is running, so make sure FirstBlockStarted is true
        [defaults_ setBool: YES forKey: @"FirstBlockStarted"];
        [NSTimer scheduledTimerWithTimeInterval: 1.0 repeats: NO block:^(NSTimer * _Nonnull timer) {
            [SCUIUtilities promptBrowserRestartIfNecessary];
        }];
    } else if (!blockIsOn && blockWasOn) {
        // make sure the dock badge is cleared
        [[NSApp dockTile] setBadgeLabel: nil];

        // send a notification letting the user know the block ended
        // TODO: make this sent from a background process so it shows if app is closed
        // (but we can't send it from the selfcontrold process, because it's running as root)
        NSUserNotificationCenter* userNoteCenter = [NSUserNotificationCenter defaultUserNotificationCenter];
        NSUserNotification* endedNote = [NSUserNotification new];
        endedNote.title = NSLocalizedString(@"Block finished", @"Block-ended notification title");
        endedNote.informativeText = NSLocalizedString(@"All sites are reachable again.", @"Block-ended notification message");
        [userNoteCenter deliverNotification: endedNote];
    }

    // if block's off, and we haven't shown it yet, show the first-time modal
    if (!blockIsOn && ![defaults_ boolForKey: @"GetStartedShown"]) {
        [defaults_ setBool: YES forKey: @"GetStartedShown"];
        [self showGetStartedWindow: self];
    }

    // finally: if the helper tool marked that it detected tampering, make sure
    // we follow through and set the cheater wallpaper (helper tool can't do it itself)
    if ([settings_ boolForKey: @"TamperingDetected"]) {
        NSURL* cheaterBackgroundURL = [[NSBundle mainBundle] URLForResource: @"cheater-background" withExtension: @"png"];
            NSArray<NSScreen *>* screens = [NSScreen screens];
        for (NSScreen* screen in screens) {
            NSError* err;
            [[NSWorkspace sharedWorkspace] setDesktopImageURL: cheaterBackgroundURL
                                                    forScreen: screen
                                                      options: @{}
                                                        error: &err];
        }
        [settings_ setValue: @NO forKey: @"TamperingDetected"];
    }

    [self.mainWindowController refresh];

    [refreshUILock_ unlock];
}

- (void)handleConfigurationChangedNotification {
    [SCSentry addBreadcrumb: @"Received configuration changed notification" category: @"app"];
    // if our configuration changed, we should assume the settings may have changed
    [[SCSettings sharedSettings] reloadSettings];

    // clean out empty strings from the defaults blocklist (they can end up there occasionally due to UI glitches etc)
    // note we don't screw with the actively running blocklist - that should've been cleaned before it started anyway
    // (the equality guard prevents a defaults-changed -> reload -> write loop)
    NSArray<NSString*>* cleanedBlocklist = [SCMiscUtilities cleanBlocklist: [defaults_ arrayForKey: @"Blocklist"]];
    if (![cleanedBlocklist isEqualToArray: [defaults_ arrayForKey: @"Blocklist"] ?: @[]]) {
        [defaults_ setObject: cleanedBlocklist forKey: @"Blocklist"];
    }

    // and our interface may need to change to match!
    [self refreshUserInterface];
}

- (IBAction)openPreferences:(id)sender {
    [SCSentry addBreadcrumb: @"Opening settings card" category: @"app"];
    [self.mainWindowController showSettings];
}

- (IBAction)showGetStartedWindow:(id)sender {
    [SCSentry addBreadcrumb: @"Showing \"Get Started\" window" category: @"app"];
	if (!getStartedWindowController) {
		getStartedWindowController = [[NSWindowController alloc] initWithWindowNibName: @"FirstTime"];
	}
	[getStartedWindowController.window center];
	[getStartedWindowController.window makeKeyAndOrderFront: nil];
	[getStartedWindowController showWindow: nil];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
#if DEBUG
    // Snapshot mode must never fall through into the real launch (LetsMove, SCSettings,
    // XPC, daemon), so exit whenever the flag is present, even if rendering failed.
    if ([NSProcessInfo.processInfo.arguments containsObject: @"-SCRenderSnapshots"]) {
        exit([SCSnapshotRenderer runIfRequested] ? 0 : 1);
    }
#endif
    // For test runs, we don't want to pop up the dialog to move to the Applications folder, as it breaks the tests
    if (NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] == nil) {
        PFMoveToApplicationsFolderIfNecessary();
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	[NSApplication sharedApplication].delegate = self;
    
    [SCSentry startSentry: @"org.eyebeam.SelfControl"];

    settings_ = [SCSettings sharedSettings];
    // go copy over any preferences from legacy setting locations
    // (we won't clear any old data yet - we leave that to the daemon)
    if ([SCMigrationUtilities legacySettingsFoundForCurrentUser]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults];
    }

    // start up our daemon XPC
    self.xpc = [SCXPCClient new];
    [self.xpc connectToHelperTool];
    
    // if we don't have a connection within 0.5 seconds,
    // OR we get back a connection with an old daemon version
    // AND we're running a modern block (which should have a daemon running it)
    // something's wrong with our app-daemon connection. This probably means one of two things:
    //   1. The daemon got unloaded somehow and failed to restart. This is a big problem because the block won't come off.
    //   2. The daemon doesn't want to talk to us anymore, potentially because we've changed our signing certificate. This is a
    //      smaller problem, but still not great because the app can't communicate anything to the daemon.
    //   3. There's a daemon but it's an old version, and should be replaced.
    // in any case, let's go try to reinstall the daemon
    // (we debounce this call so it happens only once, after the connection has been invalidated for an extended period)
    if ([SCBlockUtilities modernBlockIsRunning]) {
        [NSTimer scheduledTimerWithTimeInterval: 0.5 repeats: NO block:^(NSTimer * _Nonnull timer) {
            [self.xpc getVersion:^(NSString * _Nonnull daemonVersion, NSError * _Nonnull error) {
                if (error == nil) {
                    if ([SELFCONTROL_VERSION_STRING compare: daemonVersion options: NSNumericSearch] == NSOrderedDescending) {
                        NSLog(@"Daemon version of %@ is out of date (current version is %@).", daemonVersion, SELFCONTROL_VERSION_STRING);
                        [SCSentry addBreadcrumb: @"Detected out-of-date daemon" category: @"app"];
                        [self reinstallDaemon];
                    } else {
                        [SCSentry addBreadcrumb: @"Detected up-to-date daemon" category:@"app"];
                        NSLog(@"Daemon version of %@ is up-to-date!", daemonVersion);
                    }
                } else {
                    NSLog(@"ERROR: Fetching daemon version failed with error %@", error);
                    [self reinstallDaemon];
                }
            }];
        }];
    }

    // Register observers on both distributed and normal notification centers
	// to receive notifications from the helper tool and the other parts of the
	// main SelfControl app.  Note that they are divided thusly because distributed
	// notifications are very expensive and should be minimized.
	[[NSDistributedNotificationCenter defaultCenter] addObserver: self
														selector: @selector(handleConfigurationChangedNotification)
															name: @"SCConfigurationChangedNotification"
														  object: nil
                                              suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];
	[[NSNotificationCenter defaultCenter] addObserver: self
											 selector: @selector(handleConfigurationChangedNotification)
												 name: @"SCConfigurationChangedNotification"
											   object: nil];

    // the one window (SwiftUI). blockIsOn starts out correct - there's no more
    // window-swap trick; the window shows Ready or Blocking from live state.
    blockIsOn = [SCUIUtilities blockIsRunning];
    if (blockIsOn) {
        // a block is already running, so make sure FirstBlockStarted is true
        [defaults_ setBool: YES forKey: @"FirstBlockStarted"];
    }
    // The UI is dark-only (spec §5): make alerts, open/save panels and menus match the window.
    NSApp.appearance = [NSAppearance appearanceNamed: NSAppearanceNameDarkAqua];
    self.mainWindowController = [[MainWindowController alloc] initWithLiveModel: YES];
    [self.mainWindowController showWindow: nil];
    [self.mainWindowController startTicking];
    if (blockIsOn) {
        [NSTimer scheduledTimerWithTimeInterval: 1.0 repeats: NO block:^(NSTimer * _Nonnull timer) {
            [SCUIUtilities promptBrowserRestartIfNecessary];
        }];
    }

    [self setUpTediumMenuItem];
    [self retitleMenuItems];

	[self refreshUserInterface];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [settings_ synchronizeSettings];
}

- (void)reinstallDaemon {
    NSLog(@"Attempting to reinstall daemon...");
    [SCSentry addBreadcrumb: @"Reinstalling daemon" category:@"app"];
    [self.xpc installDaemon:^(NSError * _Nonnull error) {
        if (error == nil) {
            NSLog(@"Reinstalled daemon successfully!");
            [SCSentry addBreadcrumb: @"Daemon reinstalled successfully" category:@"app"];
            
            NSLog(@"Retrying helper tool connection...");
            [self.xpc performSelectorOnMainThread: @selector(connectToHelperTool) withObject: nil waitUntilDone: YES];
        } else {
            if (![SCMiscUtilities errorIsAuthCanceled: error]) {
                NSLog(@"ERROR: Reinstalling daemon failed with error %@", error);
                [SCUIUtilities presentError: error];
            }
        }
    }];
}

- (IBAction)showDomainList:(id)sender {
    [SCSentry addBreadcrumb: @"Showing restrictions card" category:@"app"];
    [self.mainWindowController showRestrictions];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)theApplication {
    // closing the one window quits the app (the daemon keeps enforcing)
    return !PFMoveIsInProgress();
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) [self.mainWindowController showWindow: nil];
    return YES;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver: self
													name: @"SCConfigurationChangedNotification"
												  object: nil];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver: self
															   name: @"SCConfigurationChangedNotification"
															 object: nil];
}

- (void)installBlock {
    [SCSentry addBreadcrumb: @"App running installBlock method" category:@"app"];
	@autoreleasepool {
		self.addingBlock = true;

		[self refreshUserInterface];

        [self.xpc installDaemon:^(NSError * _Nonnull error) {
            if (error != nil) {
                [SCUIUtilities presentError: error];
                self.addingBlock = false;
                [self refreshUserInterface];
                return;
            } else {
                [SCSentry addBreadcrumb: @"Daemon installed successfully (en route to installing block)" category:@"app"];
                // helper tool installed successfully, let's prepare to start the block!
                // for legacy reasons, BlockDuration is in minutes, so convert it to seconds before passing it through]
                // sanity check duration (must be above zero)
                NSTimeInterval blockDurationSecs = MAX([[self->defaults_ valueForKey: @"BlockDuration"] intValue] * 60, 0);
                NSDate* newBlockEndDate = [NSDate dateWithTimeIntervalSinceNow: blockDurationSecs];
                
                // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
                [self->settings_ synchronizeSettings];
                [self->defaults_ synchronize];

                // ok, the new helper tool is installed! refresh the connection, then it's time to start the block
                [self.xpc refreshConnectionAndRun:^{
                    NSLog(@"Refreshed connection and ready to start block!");
                    [self.xpc startBlockWithControllingUID: getuid()
                                                 blocklist: [self->defaults_ arrayForKey: @"Blocklist"]
                                               isAllowlist: [self->defaults_ boolForKey: @"BlockAsWhitelist"]
                                                   endDate: newBlockEndDate
                                             blockSettings: @{
                                                                @"ClearCaches": [self->defaults_ valueForKey: @"ClearCaches"],
                                                                @"AllowLocalNetworks": [self->defaults_ valueForKey: @"AllowLocalNetworks"],
                                                                @"EvaluateCommonSubdomains": [self->defaults_ valueForKey: @"EvaluateCommonSubdomains"],
                                                                @"IncludeLinkedDomains": [self->defaults_ valueForKey: @"IncludeLinkedDomains"],
                                                                @"BlockSoundShouldPlay": [self->defaults_ valueForKey: @"BlockSoundShouldPlay"],
                                                                @"BlockSound": [self->defaults_ valueForKey: @"BlockSound"],
                                                                @"EnableErrorReporting": [self->defaults_ valueForKey: @"EnableErrorReporting"],
                                                                @"EmergencyUnlockEnabled": [self->defaults_ valueForKey: @"EmergencyUnlockEnabled"],
                                                                @"OverridePerDay": [self->defaults_ valueForKey: @"OverridePerDay"],
                                                                @"OverrideMinutes": [self->defaults_ valueForKey: @"OverrideMinutes"]
                                                            }
                                                     reply:^(NSError * _Nonnull error) {
                        if (error != nil) {
                            [SCUIUtilities presentError: error];
                        } else {
                            [SCSentry addBreadcrumb: @"Block started successfully" category:@"app"];
                        }
                        
                        // get the new settings
                        [self->settings_ synchronizeSettingsWithCompletion:^(NSError * _Nullable error) {
                            self.addingBlock = false;
                            [self refreshUserInterface];
                        }];
                    }];
                }];
            }
        }];
	}
}

- (IBAction)save:(id)sender {
	NSSavePanel *sp;
	long runResult;

	/* create or get the shared instance of NSSavePanel */
	sp = [NSSavePanel savePanel];
	sp.allowedFileTypes = @[@"selfcontrol"];

	/* display the NSSavePanel */
	runResult = [sp runModal];

	/* if successful, save file under designated name */
	if (runResult == NSModalResponseOK) {
        NSError* err;
        [SCBlockFileReaderWriter writeBlocklistToFileURL: sp.URL
                                   blockInfo: @{
                                       @"Blocklist": [defaults_ arrayForKey: @"Blocklist"],
                                       @"BlockAsWhitelist": [defaults_ objectForKey: @"BlockAsWhitelist"]
                                       
                                   }
                                   error: &err];

        if (err != nil) {
            NSError* displayErr = [SCErr errorWithCode: 101 subDescription: err.localizedDescription];
            [SCSentry captureError: displayErr];
            NSBeep();
            [SCUIUtilities presentError: displayErr];
			return;
        } else {
            [SCSentry addBreadcrumb: @"Saved blocklist to file" category:@"app"];
        }
	}
}

- (BOOL)openSavedBlockFileAtURL:(NSURL*)fileURL {
    NSDictionary* settingsFromFile = [SCBlockFileReaderWriter readBlocklistFromFile: fileURL];
    
    if (settingsFromFile != nil) {
        [defaults_ setObject: settingsFromFile[@"Blocklist"] forKey: @"Blocklist"];
        [defaults_ setObject: settingsFromFile[@"BlockAsWhitelist"] forKey: @"BlockAsWhitelist"];
        [SCSentry addBreadcrumb: @"Opened blocklist from file" category:@"app"];
    } else {
        NSLog(@"WARNING: Could not read a valid blocklist from file - ignoring.");
        return NO;
    }

    // send a notification so the window (etc) updates
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
    
    [self refreshUserInterface];
    return YES;
}

- (IBAction)open:(id)sender {
	NSOpenPanel* oPanel = [NSOpenPanel openPanel];
	oPanel.allowedFileTypes = @[@"selfcontrol"];
	oPanel.allowsMultipleSelection = NO;

	long result = [oPanel runModal];
	if (result == NSModalResponseOK) {
		if([oPanel.URLs count] > 0) {
            [self openSavedBlockFileAtURL: oPanel.URLs[0]];
		}
	}
}

- (BOOL)application:(NSApplication*)theApplication openFile:(NSString*)filename {
    // installBlock reads the restrictions from defaults only after the auth
    // prompt, so an import while a block is starting would land in that block.
    if (self.addingBlock) return NO;
    return [self openSavedBlockFileAtURL: [NSURL fileURLWithPath: filename]];
}

- (IBAction)openFAQ:(id)sender {
    [SCSentry addBreadcrumb: @"Opened SelfControl FAQ" category:@"app"];
	NSURL *url=[NSURL URLWithString: @"https://github.com/SelfControlApp/selfcontrol/wiki/FAQ#q-selfcontrols-timer-is-at-0000-and-i-cant-start-a-new-block-and-im-freaking-out"];
	[[NSWorkspace sharedWorkspace] openURL: url];
}

- (IBAction)openSupportHub:(id)sender {
    [SCSentry addBreadcrumb: @"Opened SelfControl Support Hub" category:@"app"];
    NSURL *url=[NSURL URLWithString: @"https://selfcontrolapp.com/support"];
    [[NSWorkspace sharedWorkspace] openURL: url];
}

// Appends the tedium override menu item (after a separator) to the menu
// that already hosts our other block-related, non-toolbar commands
// (Open/Save Blocklist live in the File menu). Programmatic - no xib edits.
- (void)setUpTediumMenuItem {
    NSMenu* mainMenu = [NSApp mainMenu];
    NSMenuItem* fileMenuItem = [mainMenu itemWithTitle: @"File"];
    // fall back to positional lookup in case the title's been localized
    if (fileMenuItem == nil && mainMenu.itemArray.count > 1) {
        fileMenuItem = mainMenu.itemArray[1];
    }
    NSMenu* fileMenu = fileMenuItem.submenu;
    if (fileMenu == nil) {
        NSLog(@"WARNING: Couldn't find File menu to attach tedium override menu item.");
        return;
    }

    NSMenuItem* tediumItem = [[NSMenuItem alloc] initWithTitle: NSLocalizedString(@"Emergency Unlock…", @"menu item that opens the emergency unlock (tedium override) card")
                                                         action: @selector(openTediumOverride:)
                                                  keyEquivalent: @""];
    tediumItem.target = self;
    [fileMenu addItem: [NSMenuItem separatorItem]];
    [fileMenu addItem: tediumItem];
}

// Menu titles that still say "Blocklist" from the old UI (spec §4).
- (void)retitleMenuItems {
    NSDictionary<NSString*, NSString*>* titles = @{
        NSStringFromSelector(@selector(showDomainList:)): NSLocalizedString(@"Edit Restrictions…", @"menu item"),
        NSStringFromSelector(@selector(open:)): NSLocalizedString(@"Import Restrictions…", @"menu item"),
        NSStringFromSelector(@selector(save:)): NSLocalizedString(@"Export Restrictions…", @"menu item"),
    };
    NSMutableArray<NSMenu*>* queue = [NSMutableArray arrayWithObject: [NSApp mainMenu]];
    while (queue.count > 0) {
        NSMenu* menu = queue.firstObject;
        [queue removeObjectAtIndex: 0];
        for (NSMenuItem* item in menu.itemArray) {
            if (item.submenu != nil) [queue addObject: item.submenu];
            NSString* newTitle = item.action ? titles[NSStringFromSelector(item.action)] : nil;
            if (newTitle != nil) item.title = newTitle;
        }
    }
}

- (IBAction)openTediumOverride:(id)sender {
    [SCSentry addBreadcrumb: @"Opening emergency unlock" category:@"app"];
    [self.mainWindowController showEmergencyUnlock];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
    if (menuItem.action == @selector(openTediumOverride:)) {
        // Match the daemon's own gate (SCDaemonBlockMethods rejects the
        // challenge with error 321 unless a modern block is running).
        // The block may also have been started with emergency unlock turned off.
        return [SCBlockUtilities modernBlockIsRunning] &&
               [SCBlockUtilities emergencyUnlockAllowedForSettingsValue: [[SCSettings sharedSettings] valueForKey: @"EmergencyUnlockEnabled"]];
    }
    // No edits while a block is starting: installBlock reads Blocklist,
    // BlockAsWhitelist and the override settings only after the auth prompt.
    if (self.addingBlock &&
        (menuItem.action == @selector(showDomainList:) ||
         menuItem.action == @selector(openPreferences:) ||
         menuItem.action == @selector(open:))) {
        return NO;
    }
    return YES;
}

#pragma mark - Actions for the SwiftUI window

- (NSError*)uiErrorWithDescription:(NSString*)description {
    return [NSError errorWithDomain: kSelfControlErrorDomain code: -1 userInfo: @{ NSLocalizedDescriptionKey: description }];
}

- (void)addEntriesToRunningBlock:(NSString*)rawInput completion:(void (^)(NSError* _Nullable error))completion {
    NSAssert([NSThread isMainThread], @"addEntriesToRunningBlock must be called on the main thread");
    void (^finish)(NSError*) = ^(NSError* err) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
    };
    // Used only once modifyingBlock has been claimed by this call.
    void (^finishAndRelease)(NSError*) = ^(NSError* err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.modifyingBlock = NO;
            completion(err);
        });
    };

    if (![SCUIUtilities blockIsRunning]) { finish([SCErr errorWithCode: 102]); return; }
    if (![SCBlockUtilities modernBlockIsRunning]) { finish([SCErr errorWithCode: 303]); return; }
    if ([settings_ boolForKey: @"ActiveBlockAsWhitelist"]) { finish([SCErr errorWithCode: 305]); return; }

    NSArray<NSString*>* cleanedEntries = [SCMiscUtilities cleanBlocklistEntry: rawInput];
    if (cleanedEntries.count == 0) {
        finish([self uiErrorWithDescription: NSLocalizedString(@"That doesn't look like a site address.", @"add-site error for unusable input")]);
        return;
    }
    if ([defaults_ boolForKey: @"VerifyInternetConnection"] && ![SCUIUtilities networkConnectionIsAvailable]) {
        finish([self uiErrorWithDescription: NSLocalizedString(@"You're offline — connect to add a site.", @"add-site error when offline")]);
        return;
    }
    if (self.modifyingBlock) {
        finish([self uiErrorWithDescription: NSLocalizedString(@"Still saving your last change — try again in a moment.", @"busy modifying block")]);
        return;
    }
    self.modifyingBlock = YES;

    // Note we RETRIEVE the latest list from settings (ActiveBlocklist), but we SET the new list in defaults
    // since the helper daemon should be the only one changing ActiveBlocklist
    NSMutableArray* list = [[settings_ valueForKey: @"ActiveBlocklist"] mutableCopy] ?: [NSMutableArray array];
    for (NSString* entry in cleanedEntries) {
        if (![list containsObject: entry]) [list addObject: entry];
    }
    [defaults_ setValue: list forKey: @"Blocklist"];

    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];
    [defaults_ synchronize];

    [self.xpc refreshConnectionAndRun:^{
        [self.xpc updateBlocklist: list reply:^(NSError * _Nonnull error) {
            if (error == nil) {
                [SCSentry addBreadcrumb: @"Blocklist updated successfully" category:@"app"];
            }
            finishAndRelease(error);
        }];
    }];
}

- (void)extendRunningBlockByMinutes:(NSInteger)minutes completion:(void (^)(NSError* _Nullable error))completion {
    NSAssert([NSThread isMainThread], @"extendRunningBlockByMinutes must be called on the main thread");
    void (^finish)(NSError*) = ^(NSError* err) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
    };
    // Used only once modifyingBlock has been claimed by this call.
    void (^finishAndRelease)(NSError*) = ^(NSError* err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.modifyingBlock = NO;
            completion(err);
        });
    };

    NSInteger maxBlockLength = [defaults_ integerForKey: @"MaxBlockLength"];
    if (minutes < 1) { finish(nil); return; }
    if (minutes > maxBlockLength) minutes = maxBlockLength;

    if (![SCUIUtilities blockIsRunning]) { finish([SCErr errorWithCode: 103]); return; }
    if (![SCBlockUtilities modernBlockIsRunning]) { finish([SCErr errorWithCode: 306]); return; }
    if (self.modifyingBlock) {
        finish([self uiErrorWithDescription: NSLocalizedString(@"Still saving your last change — try again in a moment.", @"busy modifying block")]);
        return;
    }
    self.modifyingBlock = YES;

    NSDate* oldBlockEndDate = [settings_ valueForKey: @"BlockEndDate"];
    if (oldBlockEndDate == nil) {
        finishAndRelease([self uiErrorWithDescription: NSLocalizedString(@"This block has already ended.", @"extend error when the block is over")]);
        return;
    }
    NSDate* newBlockEndDate = [oldBlockEndDate dateByAddingTimeInterval: (minutes * 60)];

    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];
    [defaults_ synchronize];

    [self.xpc refreshConnectionAndRun:^{
        // Before we try to extend the block, make sure the block time didn't run out (or is about to run out) in the meantime
        if ([SCBlockUtilities currentBlockIsExpired] || [oldBlockEndDate timeIntervalSinceNow] < 1) {
            finishAndRelease([self uiErrorWithDescription: NSLocalizedString(@"This block has already ended.", @"extend error when the block is over")]);
            return;
        }
        [self.xpc updateBlockEndDate: newBlockEndDate reply:^(NSError * _Nonnull error) {
            if (error == nil) {
                [SCSentry addBreadcrumb: @"App extended block duration successfully" category:@"app"];
            }
            finishAndRelease(error);
        }];
    }];
}

#pragma mark - Manual block stop (moved from TimerWindowController)

- (void)stopBlockManually {
	AuthorizationRef authorizationRef;
	char* helperToolPath = [self selfControlKillerHelperToolPathUTF8String];
	NSUInteger helperToolPathSize = strlen(helperToolPath);
	AuthorizationItem right = {
		kAuthorizationRightExecute,
		helperToolPathSize,
		helperToolPath,
		0
	};
	AuthorizationRights authRights = {
		1,
		&right
	};
	AuthorizationFlags myFlags = kAuthorizationFlagDefaults |
	kAuthorizationFlagExtendRights |
	kAuthorizationFlagInteractionAllowed;
	OSStatus status;

	status = AuthorizationCreate (&authRights,
								  kAuthorizationEmptyEnvironment,
								  myFlags,
								  &authorizationRef);

	if(status) {
        if (status != AUTH_CANCELLED_STATUS) {
            NSError* err = [SCErr errorWithCode: 501];
            [SCSentry captureError: err];
        }
        return;
	}
    
    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];

	char uidString[10];
	snprintf(uidString, sizeof(uidString), "%d", getuid());

    NSDate* keyDate = [NSDate date];
    NSString* killerKey = [SCMiscUtilities killerKeyForDate: keyDate];
    NSString* keyDateString = [[NSISO8601DateFormatter new] stringFromDate: keyDate];
    
	char* args[] = { (char*)[killerKey UTF8String], (char*)[keyDateString UTF8String], uidString, NULL };
    
    FILE* pipe = NULL;
	status = AuthorizationExecuteWithPrivileges(authorizationRef,
												helperToolPath,
												kAuthorizationFlagDefaults,
												args,
												&pipe);
    
	if(status) {
		NSLog(@"WARNING: Authorized execution of helper tool returned failure status code %d", status);

        /// AUTH_CANCELLED_STATUS just means auth is cancelled, not really an "error" per se
        if (status != AUTH_CANCELLED_STATUS) {
            NSError* err = [SCErr errorWithCode: 400];
            [SCSentry captureError: err];
            [SCUIUtilities presentError: err];
        }

		return;
	}

    // read until the pipe finishes so we wait for execution to end before we
    // show the modal (this also helps make the focus ordering better).
    // Keep the output: the helper reports a refusal on stdout, since its exit
    // status isn't available to us through AuthorizationExecuteWithPrivileges.
    NSMutableData* helperOutput = [NSMutableData data];
    if (pipe != NULL) {
        char buffer[256];
        for (;;) {
            ssize_t bytesRead = read(fileno(pipe), buffer, sizeof(buffer));
            if (bytesRead < 0 && errno == EINTR) continue;
            if (bytesRead < 1) break;
            [helperOutput appendBytes: buffer length: (NSUInteger)bytesRead];
        }
        fclose(pipe);
    }
    NSString* helperOutputString = [[NSString alloc] initWithData: helperOutput encoding: NSUTF8StringEncoding];
    BOOL helperRefusedUnverifiedExpiry = [helperOutputString containsString: SCKillerExpiryNotVerifiedMarker];
        
    // reload settings so the timer window knows the block is done
    [[SCSettings sharedSettings] reloadSettings];
        
    // update the UI _before_ we run the alert,
    // so the main window doesn't steal the focus from the alert
    // (and after we've synced settings so we know things have changed)
    [self refreshUserInterface];
    
    if (helperRefusedUnverifiedExpiry) {
        NSLog(@"WARNING: Killer helper refused to clear the block because network time did not confirm expiry");
        [SCDialog informWithTitle: NSLocalizedString(@"Block not cleared", @"Title when the killer helper refuses to clear an unexpired block")
                          message: NSLocalizedString(@"SelfControl couldn't confirm the block has finished. Connect to the internet and try again once the timer has run out. (Details: SelfControl-Killer.log in Documents.)", @"Message when the killer helper refuses to clear a block because network time did not confirm it has expired")];
        return;
    }

    // send some debug info to Sentry to help us track this issue
    // detailed logs disabled for now because the best current method might collect user PII we don't want
    [SCSentry captureMessage: @"User manually cleared SelfControl block from the timer window"];
    //    [SCSentry captureMessage: @"User manually cleared SelfControl block from the timer window" withScopeBlock:^(SentryScope * _Nonnull scope) {
    //        SentryAttachment* fileAttachment = [[SentryAttachment alloc] initWithPath: [@"~/Documents/SelfControl-Killer.log" stringByExpandingTildeInPath]];
    //        [scope addAttachment: fileAttachment];
    //    }];
    
    if ([SCBlockUtilities anyBlockIsRunning]) {
        // ruh roh! the block wasn't cleared successfully, since it's still running
        NSError* err = [SCErr errorWithCode: 401];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
    } else {
        [SCDialog informWithTitle: NSLocalizedString(@"Block cleared", @"Title when a block was cleared manually")
                          message: NSLocalizedString(@"All sites are reachable again. (Details: SelfControl-Killer.log in Documents.)", @"Message when a block was cleared manually")];
    }
}

- (NSString*)selfControlKillerHelperToolPath {
	static NSString* path;

	// Cache the path so it doesn't have to be searched for again.
	if(!path) {
		NSBundle* thisBundle = [NSBundle mainBundle];
		path = [thisBundle pathForAuxiliaryExecutable: @"SCKillerHelper"];
	}

	return path;
}
- (char*)selfControlKillerHelperToolPathUTF8String {
	static char* path;

	// Cache the converted path so it doesn't have to be converted again
	if(!path) {
		path = malloc(512);
		[[self selfControlKillerHelperToolPath] getCString: path
												 maxLength: 512
												  encoding: NSUTF8StringEncoding];
	}

	return path;
}

@end
