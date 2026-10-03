//
//  AppController.h
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

@class SCXPCClient;
@class MainWindowController;

#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#import <SystemConfiguration/SCNetwork.h>
#import <unistd.h>
#import "SCSettings.h"

// The main controller for the SelfControl app: app delegate, daemon connection,
// block start/modify actions, and owner of the single SwiftUI window.
@interface AppController : NSObject <NSApplicationDelegate> {
	NSUserDefaults* defaults_;
    SCSettings* settings_;
	NSLock* refreshUILock_;
	BOOL blockIsOn;
	BOOL addingBlock;
}

@property (assign) BOOL addingBlock;

// Shared daemon XPC connection. Exposed read-only so the SwiftUI window
// (AppModel) can reuse the same connection instead of opening its own.
@property (atomic, strong, readonly) SCXPCClient* xpc;

// The single SwiftUI window (UI/MainWindowController.swift).
@property (nonatomic, strong, readonly) MainWindowController* mainWindowController;

/* // Gets authorization for and then immediately removes the block by calling
 // SelfControl's helper tool with the appropriate arguments.  This can be used
 // for testing, but should not be called at all during normal execution of the
 // program.
 - (void)removeBlock; */

// Called when the main Start button is clicked.  Launchs installBlock in another
// thread after some checking and syncing.
- (IBAction)addBlock:(id)sender;

// Checks whether the SelfControl block is active and accordingly changes the
// user interface.  Called very often by several parts of the program.
- (void)refreshUserInterface;

// Menu item: opens the Restrictions card in the main window.
- (IBAction)showDomainList:(id)sender;

// Gets authorization for and then immediately adds the block by calling
// SelfControl's helper tool with the appropriate arguments.  Meant to be called
// as a separate thread.
- (void)installBlock;

// open preferences panel
- (IBAction)openPreferences:(id)sender;

- (IBAction)showGetStartedWindow:(id)sender;

// Opens a save panel and saves the blocklist.
- (IBAction)save:(id)sender;

// Opens an open panel and imports a blocklist, clearing the current one.
- (IBAction)open:(id)sender;

// opens the SelfControl FAQ in the default browser
- (IBAction)openFAQ:(id)sender;

// opens the SelfControl Support Hub in the default browser
- (IBAction)openSupportHub:(id)sender;

// Opens the Emergency Unlock (tedium override) card in the main window. Only
// enabled (see -validateMenuItem:) while a modern block is running.
- (IBAction)openTediumOverride:(id)sender;

#pragma mark - Actions for the SwiftUI window (completion is always called on the main queue)

// Both methods below must be called on the main thread; they are serialized
// by a main-thread-only "modifying block" flag (busy -> error, not queued).

// Adds cleaned entries from rawInput to the RUNNING block via the daemon's
// updateBlocklist. Returns errors instead of presenting them (no-block 102, legacy 303, allowlist 305, invalid input,
// no network, busy, or the daemon's error).
- (void)addEntriesToRunningBlock:(NSString*)rawInput completion:(void (^)(NSError* _Nullable error))completion;

// Extends the RUNNING block (clamped to
// MaxBlockLength; daemon still enforces its 24h-per-call cap, error 309).
- (void)extendRunningBlockByMinutes:(NSInteger)minutes completion:(void (^)(NSError* _Nullable error))completion;

// The manual "Stuck? Stop block manually" flow (SCKillerHelper). Main thread only; shows its own alerts.
- (void)stopBlockManually;

@end
