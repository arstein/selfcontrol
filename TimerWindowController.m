
//
//  TimerWindowController.m
//  SelfControl
//
//  Created by Charlie Stigler on 2/15/09.
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


#import "TimerWindowController.h"
#import "SCUIUtilities.h"
#import "SCXPCClient.h"
#import "SCTrustedClock.h"
#import <math.h>

@interface TimerWindowController ()

@property(nonatomic, readonly) AppController* appController;

// Phase 4: minimal, programmatically-created override UI. These are plain
// properties (not IBOutlets) because the controls aren't in the xib -- see
// -setUpOverrideControlsIfNeeded.
@property (nonatomic, strong) NSButton* invokeOverrideButton_;
@property (nonatomic, strong) NSTextField* overrideStatusLabel_;

// Phase 4 live-verify: the daemon's trusted-clock view of override status,
// polled over XPC (getOverrideStatus:) and interpolated between polls using
// ONLY monotonic uptime (SCTrustedClock continuousUptimeSecs) -- never the
// wall clock, which a user can roll forward/back to hide or fake the
// countdown. All of these are main-thread only.
@property (nonatomic, assign) BOOL overrideStatusInFlight_;
@property (nonatomic, assign) NSTimeInterval overrideStatusRequestUptime_;
@property (nonatomic, assign) NSTimeInterval lastStatusUptime_;
@property (nonatomic, assign) BOOL lastStatusValid_;
@property (nonatomic, assign) NSTimeInterval lastRemainingSecs_;
@property (nonatomic, assign) BOOL lastActive_;
@property (nonatomic, assign) NSInteger lastRemainingToday_;
@property (nonatomic, assign) NSInteger lastPerDay_;

- (void)setUpOverrideControlsIfNeeded;
- (void)refreshOverrideUI;
- (void)renderOverrideStatus;
- (IBAction)invokeOverride:(id)sender;

@end

// A half-open vertical interval [minY, maxY) in a view's local coordinate
// space, used to find empty space for the override controls below.
typedef struct {
    CGFloat minY;
    CGFloat maxY;
} SCVerticalInterval;

static int SCCompareVerticalIntervals(const void* a, const void* b) {
    CGFloat ay = ((const SCVerticalInterval*)a)->minY;
    CGFloat by = ((const SCVerticalInterval*)b)->minY;
    if (ay < by) return -1;
    if (ay > by) return 1;
    return 0;
}

// Layout constants for the override row (Phase 4).
static const CGFloat kOverrideRowMargin = 18.0;
static const CGFloat kOverrideButtonWidth = 200.0;
static const CGFloat kOverrideButtonHeight = 28.0;
static const CGFloat kOverrideLabelHeight = 14.0;
static const CGFloat kOverrideRowSpacing = 4.0;
static const CGFloat kOverrideVerticalPadding = 8.0;
static const CGFloat kOverrideWindowGrowth = 56.0;

@implementation TimerWindowController

- (TimerWindowController*) init {
	if(self = [super init]) {
        settings_ = [SCSettings sharedSettings];
        
		// We need a block to prevent us from running multiple copies of the "Add to Block"
		// sheet.
		modifyBlockLock = [[NSLock alloc] init];
	
        numStrikes = 0;
	}

	return self;
}

- (void)awakeFromNib {
	[[self window] center];
	[[self window] makeKeyAndOrderFront: self];

	NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

	NSWindow* window = [self window];

	[window center];

	if([defaults boolForKey:@"TimerWindowFloats"])
		[window setLevel: NSFloatingWindowLevel];
	else
		[window setLevel: NSNormalWindowLevel];

	[window setHidesOnDeactivate: NO];

	[window makeKeyAndOrderFront: self];

    // make the kill-block button red so it's extra noticeable
    NSMutableAttributedString* killBlockMutableAttributedTitle = [killBlockButton_.attributedTitle mutableCopy];
    [killBlockMutableAttributedTitle addAttribute: NSForegroundColorAttributeName value: [NSColor systemRedColor] range: NSMakeRange(0, killBlockButton_.title.length)];
    [killBlockMutableAttributedTitle applyFontTraits: NSBoldFontMask range: NSMakeRange(0, killBlockButton_.title.length)];
    killBlockButton_.attributedTitle = killBlockMutableAttributedTitle;

	killBlockButton_.hidden = YES;
	addToBlockButton_.hidden = NO;
    extendBlockButton_.hidden = NO;
    legacyBlockWarningLabel_.hidden = YES;

    // set up extend block dialog
    extendDurationSlider_.maxDuration = [defaults integerForKey: @"MaxBlockLength"];

    if ([SCBlockUtilities modernBlockIsRunning]) {
        blockEndingDate_ = [settings_ valueForKey: @"BlockEndDate"];
    } else {
        // legacy block!
        blockEndingDate_ = [SCMigrationUtilities legacyBlockEndDate];
        
        // if it's a legacy block, we will disable some features
        // since it's too difficult to get these working across versions.
        // the user will just have to wait until their next block to do these things!
        if ([SCBlockUtilities legacyBlockIsRunning]) {
            addToBlockButton_.hidden = YES;
            extendBlockButton_.hidden = YES;
            legacyBlockWarningLabel_.hidden = NO;
        }
    }

    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 45];
	[self updateTimerDisplay: nil];

	timerUpdater_ = [NSTimer timerWithTimeInterval: 1.0
											target: self
										  selector: @selector(updateTimerDisplay:)
										  userInfo: nil
										   repeats: YES];

	//If the dialog isn't focused, instead of getting a NSTimer, we get null.
	//Scheduling the timer from the main thread seems to work.
	[self performSelectorOnMainThread: @selector(hackAroundMainThreadtimer:) withObject: timerUpdater_ waitUntilDone: YES];
    
    [NSTimer scheduledTimerWithTimeInterval: 1.0 repeats: NO block:^(NSTimer * _Nonnull timer) {
        [SCUIUtilities promptBrowserRestartIfNecessary];
    }];
    
    // the timer is a good time to prompt them to enable error reporting! nothing else is happening
    [NSTimer scheduledTimerWithTimeInterval: 3.0 repeats: NO block:^(NSTimer * _Nonnull timer) {
        [SCSentry showErrorReportingPromptIfNeeded];
    }];

    // Phase 4: set up the (programmatic, not-in-xib) override controls now that
    // the window and its nib-defined controls are loaded and laid out.
    //
    // NOTE: this is done here rather than in -windowDidLoad because this class's
    // -awakeFromNib override above doesn't call [super awakeFromNib], and
    // NSWindowController relies on that super call to trigger -windowDidLoad.
    // Adding a -windowDidLoad override without that super call would silently
    // never fire, so we hook the one lifecycle method we know actually runs.
    [self setUpOverrideControlsIfNeeded];
}

- (void)blockEnded {
    [timerUpdater_ invalidate];
    timerUpdater_ = nil;

    [timerLabel_ setStringValue: NSLocalizedString(@"Block not active", @"block not active string")];
    [timerLabel_ setFont: [[NSFontManager sharedFontManager]
                           convertFont: [timerLabel_ font]
                           toSize: 37]
     ];

    [timerLabel_ sizeToFit];

    [self resetStrikes];
    [self refreshOverrideUI];

    [SCSentry addBreadcrumb: @"Block ended and timer window is closing" category: @"app"];
}


- (void)hackAroundMainThreadtimer:(NSTimer*)timer{
	[[NSRunLoop currentRunLoop] addTimer: timer forMode: NSDefaultRunLoopMode];
}

- (void)updateTimerDisplay:(NSTimer*)timer {
	// update UI for the whole app, in case the block is done with
    [self.appController performSelectorOnMainThread:@selector(refreshUserInterface)
                                         withObject:nil
                                      waitUntilDone:NO];

    NSString* finishingString = [SCBlockUtilities modernBlockIsRunning]
        ? NSLocalizedString(@"Verifying end time…", @"Waiting for network time before ending a block")
        : NSLocalizedString(@"Finishing", @"String shown when waiting for finished block to clear");
    NSNumber* trustedRemaining = [SCBlockUtilities trustedRemainingBlockDurationSecs];
	int numSeconds = (int)ceil(trustedRemaining != nil
        ? trustedRemaining.doubleValue
        : [blockEndingDate_ timeIntervalSinceNow]);
	int numHours;
	int numMinutes;

    // if we're already showing "Finishing", but the block timer isn't clearing,
    // keep track of that, so we can take drastic measures if necessary.
	if(numSeconds < 0 && [timerLabel_.stringValue isEqualToString: finishingString]) {
		[[NSApp dockTile] setBadgeLabel: nil];

		// This increments the strike counter.  After four strikes of the timer being
		// at or less than 0 seconds, SelfControl will assume something's wrong and enable
		// manual block removal
		numStrikes++;

		if(numStrikes >= 300) {
			// OK, this is taking longer than it should. Enable manual block removal.
            if (numStrikes == 300) {
                NSLog(@"WARNING: Block should have ended! Probable failure to remove.");
                NSError* err = [SCErr errorWithCode: 105];
                [SCSentry captureError: err];
            }

			addToBlockButton_.hidden = YES;
            extendBlockButton_.hidden = YES;
            legacyBlockWarningLabel_.hidden = YES;
			killBlockButton_.hidden = NO;
		}

		return;
	}

	numHours = (numSeconds / 3600);
	numSeconds %= 3600;
	numMinutes = (numSeconds / 60);
	numSeconds %= 60;

    NSString* timeString;
    if (numHours > 0 || numMinutes > 0 || numSeconds > 0) {
        timeString = [NSString stringWithFormat: @"%0.2d:%0.2d:%0.2d",
                      numHours,
                      numMinutes,
                      numSeconds];
    } else {
        // It usually takes 5-15 seconds after a block finishes for it to turn off
        // so show "Finishing" instead of "00:00:00" to avoid user worry and confusion!
        timeString = finishingString;
    }

	[timerLabel_ setStringValue: timeString];
	[timerLabel_ setFont: [[NSFontManager sharedFontManager]
						   convertFont: [timerLabel_ font]
						   toSize: 42]
	 ];

	[timerLabel_ sizeToFit];
	[timerLabel_ setFrame:NSRectFromCGRect(CGRectMake(0, timerLabel_.frame.origin.y, self.window.frame.size.width, timerLabel_.frame.size.height))];
	[self resetStrikes];
    
	if([[NSUserDefaults standardUserDefaults] boolForKey: @"BadgeApplicationIcon"] && [blockEndingDate_ timeIntervalSinceNow] > 0) {
		// We want to round up the minutes--standard when we aren't displaying seconds.
		if(numSeconds > 0 && numMinutes != 59) {
			numMinutes++;
		}

		NSString* badgeString = [NSString stringWithFormat: @"%0.2d:%0.2d",
								 numHours,
								 numMinutes];
		[[NSApp dockTile] setBadgeLabel: badgeString];
	} else {
		// If we aren't using badging, set the badge string to be
		// empty to remove any badge if there is one.
		[[NSApp dockTile] setBadgeLabel: nil];
	}
    
    // make sure add to list is disabled if it's an allowlist block
    // don't worry about it for a legacy block! the buttons are disabled anyway so it doesn't matter
    if ([SCBlockUtilities modernBlockIsRunning]) {
        addToBlockButton_.enabled = ![settings_ boolForKey: @"ActiveBlockAsWhitelist"];
    }

    [self refreshOverrideUI];
}

- (void)windowShouldClose:(NSNotification *)notification {
	// Hack to make the application terminate after the last window is closed, but
	// INCLUDE the HUD-style timer window.
	if(![[self.appController initialWindow] isVisible]) {
		[NSApp terminate: self];
	}
}

- (IBAction) addToBlock:(id)sender {
	// Check if there's already a thread trying to modify the block.  If so, don't make
	// another.
	if(![modifyBlockLock tryLock]) {
		return;
	}

    [self.window beginSheet: addSheet_ completionHandler:^(NSModalResponse returnCode) {
        [self->addSheet_ orderOut: self];
    }];

	[modifyBlockLock unlock];
}

- (IBAction) extendBlockTime:(id)sender {
    // Check if there's already a thread trying to modify the block.  If so, don't make
    // another.
    if(![modifyBlockLock tryLock]) {
        return;
    }
    
    [self.window beginSheet: extendBlockTimeSheet_ completionHandler:^(NSModalResponse returnCode) {
        [self->extendBlockTimeSheet_ orderOut: self];
    }];
    
    [modifyBlockLock unlock];
}
- (IBAction)updateExtendSliderDisplay:(id)sender {
    // if the duration is larger than we can display on our slider
    // chop it down to our max display value so the user doesn't
    // accidentally extend the block much longer than intended
    if (extendDurationSlider_.durationValueMinutes > extendDurationSlider_.maxDuration) {
        extendDurationSlider_.integerValue = extendDurationSlider_.maxDuration;
    }

    extendDurationLabel_.stringValue = extendDurationSlider_.durationDescription;
}

- (IBAction) closeAddSheet:(id)sender {
	[NSApp endSheet: addSheet_];
}
- (IBAction) closeExtendSheet:(id)sender {
    [NSApp endSheet: extendBlockTimeSheet_];
}

- (IBAction) performAddSite:(id)sender {
	NSString* addToBlockTextFieldContents = [addToBlockTextField_ stringValue];
	[self.appController addToBlockList: addToBlockTextFieldContents lock: modifyBlockLock];
    addToBlockTextField_.stringValue = @""; // clear text field for next time
	[NSApp endSheet: addSheet_];
}

- (IBAction) performExtendBlock:(id)sender {
    NSInteger extendBlockMinutes = extendDurationSlider_.durationValueMinutes;
        
    [self.appController extendBlockTime: extendBlockMinutes lock: modifyBlockLock];
    [NSApp endSheet: extendBlockTimeSheet_];
}

- (void)configurationChanged {
    if ([SCBlockUtilities modernBlockIsRunning]) {
        blockEndingDate_ = [settings_ valueForKey: @"BlockEndDate"];
    } else {
        // legacy block!
        blockEndingDate_ = [SCMigrationUtilities legacyBlockEndDate];
    }
    
    // update the blocklist teaser in case that changed
    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 45];
    [self updateTimerDisplay: nil];
    [self refreshOverrideUI];
}

- (void)didEndSheet:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	[sheet orderOut:self];
}

// see updateTimerDisplay: for an explanation
- (void)resetStrikes {
	numStrikes = 0;
}

- (IBAction)killBlock:(id)sender {
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
    [self.appController performSelectorOnMainThread:@selector(refreshUserInterface)
                                         withObject:nil
                                      waitUntilDone:YES];
    
    if (helperRefusedUnverifiedExpiry) {
        NSLog(@"WARNING: Killer helper refused to clear the block because network time did not confirm expiry");
        NSAlert* alert = [[NSAlert alloc] init];
        [alert setMessageText: NSLocalizedString(@"Block not cleared", @"Title when the killer helper refuses to clear an unexpired block")];
        [alert setInformativeText: NSLocalizedString(@"SelfControl couldn't verify the block has expired. Network time is required to clear a block, and a block can only be cleared once its full duration has passed. Make sure you're connected to the internet and try again after the timer runs out. You can find the log file, named SelfControl-Killer.log, in your Documents folder.", @"Message when the killer helper refuses to clear a block because network time did not confirm it has expired")];
        [alert addButtonWithTitle: NSLocalizedString(@"OK", @"OK button")];
        [alert runModal];
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
        NSAlert* alert = [[NSAlert alloc] init];
        [alert setMessageText: @"Success!"];
        [alert setInformativeText:@"The block was cleared successfully.  You can find the log file, named SelfControl-Killer.log, in your Documents folder. If you're still having issues, please check out the SelfControl FAQ on GitHub."];
        [alert addButtonWithTitle: @"OK"];
        [alert runModal];
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

- (void)dealloc {
	[timerUpdater_ invalidate];
}

#pragma mark - Override UI (Phase 4, minimal/interim)

// Finds the largest vertical band, at least minHeight tall, within
// contentView's own bounds that doesn't overlap the frame of any view in
// `views`. The views are assumed to be direct subviews of contentView (so
// their .frame is already in its coordinate space). Returns NSZeroRect if
// no such band exists.
- (NSRect)availableBandInView:(NSView*)contentView avoidingViews:(NSArray<NSView*>*)views minHeight:(CGFloat)minHeight {
    CGFloat contentWidth = NSWidth(contentView.bounds);
    CGFloat contentHeight = NSHeight(contentView.bounds);

    NSUInteger count = views.count;
    if (count == 0) {
        return (contentHeight >= minHeight) ? contentView.bounds : NSZeroRect;
    }

    SCVerticalInterval* intervals = calloc(count, sizeof(SCVerticalInterval));
    if (intervals == NULL) {
        return NSZeroRect;
    }
    for (NSUInteger i = 0; i < count; i++) {
        NSRect f = ((NSView*)views[i]).frame;
        intervals[i].minY = NSMinY(f);
        intervals[i].maxY = NSMaxY(f);
    }
    qsort(intervals, count, sizeof(SCVerticalInterval), SCCompareVerticalIntervals);

    CGFloat cursor = 0;
    NSRect bestGap = NSZeroRect;
    CGFloat bestGapHeight = 0;

    for (NSUInteger i = 0; i < count; i++) {
        CGFloat gapHeight = intervals[i].minY - cursor;
        if (gapHeight > bestGapHeight) {
            bestGapHeight = gapHeight;
            bestGap = NSMakeRect(0, cursor, contentWidth, gapHeight);
        }
        if (intervals[i].maxY > cursor) {
            cursor = intervals[i].maxY;
        }
    }

    // the trailing gap, from the topmost occupied point up to the top of the view
    CGFloat trailingGapHeight = contentHeight - cursor;
    if (trailingGapHeight > bestGapHeight) {
        bestGapHeight = trailingGapHeight;
        bestGap = NSMakeRect(0, cursor, contentWidth, trailingGapHeight);
    }

    free(intervals);

    return (bestGapHeight >= minHeight) ? bestGap : NSZeroRect;
}

// Creates the (minimal, interim) invoke-override button + status label and adds
// them as plain subviews of the window's content view -- NOT via the xib, since
// hand-editing that nib's XML is fragile. Safe to call more than once; only the
// first call does anything.
- (void)setUpOverrideControlsIfNeeded {
    if (self.invokeOverrideButton_ != nil) {
        return;
    }

    NSWindow* window = self.window;
    NSView* contentView = window.contentView;
    if (contentView == nil) {
        NSLog(@"WARNING: TimerWindowController has no content view; skipping override UI setup.");
        return;
    }

    [contentView layoutSubtreeIfNeeded];

    NSMutableArray<NSView*>* existingControls = [NSMutableArray array];
    if (addToBlockButton_ != nil)      { [existingControls addObject: addToBlockButton_]; }
    if (killBlockButton_ != nil)       { [existingControls addObject: killBlockButton_]; }
    if (extendBlockButton_ != nil)     { [existingControls addObject: extendBlockButton_]; }
    if (blocklistTeaserLabel_ != nil)  { [existingControls addObject: blocklistTeaserLabel_]; }
    if (timerLabel_ != nil)            { [existingControls addObject: timerLabel_]; }
    if (legacyBlockWarningLabel_ != nil) { [existingControls addObject: legacyBlockWarningLabel_]; }

    CGFloat neededHeight = kOverrideButtonHeight + kOverrideRowSpacing + kOverrideLabelHeight + (kOverrideVerticalPadding * 2);

    NSRect gap = [self availableBandInView: contentView avoidingViews: existingControls minHeight: neededHeight];

    if (gap.size.height <= 0) {
        // Not enough room among the existing controls -- grow the window's
        // content height, keeping the top-left corner anchored on screen (so
        // the window doesn't jump around), and try again.
        NSRect windowFrame = window.frame;
        windowFrame.origin.y -= kOverrideWindowGrowth;
        windowFrame.size.height += kOverrideWindowGrowth;
        [window setFrame: windowFrame display: YES];
        [contentView layoutSubtreeIfNeeded];

        gap = [self availableBandInView: contentView avoidingViews: existingControls minHeight: neededHeight];
    }

    if (gap.size.height <= 0) {
        NSLog(@"WARNING: TimerWindowController couldn't find a safe, non-overlapping spot for the override controls, even after growing the window. Skipping override UI setup.");
        return;
    }

    CGFloat contentWidth = NSWidth(contentView.bounds);
    CGFloat rowWidth = contentWidth - (kOverrideRowMargin * 2);
    if (rowWidth < 40) {
        NSLog(@"WARNING: TimerWindowController's content view is too narrow for the override controls. Skipping override UI setup.");
        return;
    }

    // Center our two-row block (label above button) vertically within the gap.
    CGFloat blockHeight = kOverrideButtonHeight + kOverrideRowSpacing + kOverrideLabelHeight;
    CGFloat blockBottom = NSMinY(gap) + MAX((CGFloat)0.0, (NSHeight(gap) - blockHeight) / 2.0);

    NSButton* button = [[NSButton alloc] initWithFrame: NSMakeRect(kOverrideRowMargin, blockBottom, MIN(kOverrideButtonWidth, rowWidth), kOverrideButtonHeight)];
    button.bezelStyle = NSBezelStyleRounded;
    button.title = @"Invoke override";
    button.target = self;
    button.action = @selector(invokeOverride:);
    button.autoresizingMask = NSViewMaxYMargin;
    [contentView addSubview: button];
    self.invokeOverrideButton_ = button;

    NSTextField* label = [[NSTextField alloc] initWithFrame: NSMakeRect(kOverrideRowMargin, blockBottom + kOverrideButtonHeight + kOverrideRowSpacing, rowWidth, kOverrideLabelHeight)];
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.alignment = NSTextAlignmentLeft;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
    label.textColor = [NSColor secondaryLabelColor];
    label.hidden = YES;
    label.autoresizingMask = (NSViewWidthSizable | NSViewMaxYMargin);
    [contentView addSubview: label];
    self.overrideStatusLabel_ = label;

    [self refreshOverrideUI];
}

// Refreshes the override button/label. Safe to call before the controls
// exist (no-ops), and cheap enough to call on every timer tick / config
// change: when there's no modern block (or no override policy), this hides
// and disables everything exactly as before and makes no XPC call. Otherwise
// it (throttled) polls the daemon's trusted-clock override status via XPC,
// and always re-renders from the latest poll via -renderOverrideStatus so the
// display keeps ticking between polls. Never computes remaining time from
// [NSDate date] / the wall clock -- see -renderOverrideStatus.
- (void)refreshOverrideUI {
    if (self.invokeOverrideButton_ == nil) {
        return;
    }

    SCSettings* settings = [SCSettings sharedSettings];
    NSDictionary* policy = [settings valueForKey: @"OverridePolicy"];
    NSInteger perDay = [policy isKindOfClass: [NSDictionary class]] ? [policy[@"perDay"] integerValue] : 0;

    if (![SCBlockUtilities modernBlockIsRunning] || perDay <= 0) {
        self.overrideStatusLabel_.hidden = YES;
        self.invokeOverrideButton_.title = [NSString stringWithFormat: @"Invoke override (%ld left)", 0L];
        self.invokeOverrideButton_.enabled = NO;
        self.invokeOverrideButton_.hidden = YES; // hide entirely for blocks with no override policy
        return;
    }

    self.invokeOverrideButton_.hidden = NO;

    NSTimeInterval nowUptime = [SCTrustedClock continuousUptimeSecs];
    if (!self.overrideStatusInFlight_ || (nowUptime - self.overrideStatusRequestUptime_) > 3.0) {
        self.overrideStatusInFlight_ = YES;
        self.overrideStatusRequestUptime_ = nowUptime;

        __weak typeof(self) weakSelf = self;
        [self.appController.xpc getOverrideStatus:^(BOOL blockRunning, BOOL overrideActive, NSTimeInterval overrideRemainingSecs, NSInteger remainingToday, NSInteger polledPerDay, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                strongSelf.overrideStatusInFlight_ = NO;
                if (error == nil) {
                    strongSelf.lastRemainingSecs_ = overrideRemainingSecs;
                    strongSelf.lastActive_ = overrideActive;
                    strongSelf.lastRemainingToday_ = remainingToday;
                    strongSelf.lastPerDay_ = polledPerDay;
                    strongSelf.lastStatusUptime_ = [SCTrustedClock continuousUptimeSecs];
                    strongSelf.lastStatusValid_ = YES;
                }
                [strongSelf renderOverrideStatus];
            });
        }];
    }

    // Always re-render, so the displayed countdown keeps interpolating
    // (against monotonic uptime) on every tick, not just when a poll lands.
    [self renderOverrideStatus];
}

// Renders the override button/label from the last daemon poll (see
// -refreshOverrideUI), interpolating the shown countdown using ONLY the
// monotonic uptime elapsed since that poll landed. Falls back to a
// settings-derived display (no seconds countdown) when the last poll is
// stale or hasn't landed yet. Never touches [NSDate date] / the wall clock.
- (void)renderOverrideStatus {
    if (self.invokeOverrideButton_ == nil) {
        return;
    }

    NSTimeInterval nowUptime = [SCTrustedClock continuousUptimeSecs];

    if (self.lastStatusValid_ && (nowUptime - self.lastStatusUptime_) <= 5.0) {
        NSTimeInterval shown = MAX(0.0, self.lastRemainingSecs_ - (nowUptime - self.lastStatusUptime_));

        if (self.lastActive_ && shown > 0) {
            NSInteger secs = (NSInteger)ceil(shown);
            self.overrideStatusLabel_.stringValue = [NSString stringWithFormat: @"Override active — %ldm %02lds left", (long)(secs / 60), (long)(secs % 60)];
            self.overrideStatusLabel_.hidden = NO;
        } else {
            self.overrideStatusLabel_.hidden = YES;
        }

        self.invokeOverrideButton_.title = [NSString stringWithFormat: @"Invoke override (%ld left)", (long)self.lastRemainingToday_];
        self.invokeOverrideButton_.enabled = (self.lastPerDay_ > 0) && (self.lastRemainingToday_ > 0) && !self.lastActive_;
        return;
    }

    // Stale or no poll landed yet: fall back to what we had before
    // live-verify existed, minus any wall-clock countdown math. We only know
    // (from settings) whether an override end date is stored at all, not how
    // many seconds are left, so we show a "checking…" placeholder rather than
    // a number.
    SCSettings* settings = [SCSettings sharedSettings];
    NSDictionary* state = [settings valueForKey: @"OverrideState"];
    id endVal = [state isKindOfClass: [NSDictionary class]] ? state[@"overrideEndDate"] : nil;
    BOOL hasStoredEndDate = [endVal isKindOfClass: [NSDate class]];

    if (hasStoredEndDate) {
        self.overrideStatusLabel_.stringValue = NSLocalizedString(@"Override active — checking…", @"Shown while waiting for the daemon to confirm override status");
        self.overrideStatusLabel_.hidden = NO;
    } else {
        self.overrideStatusLabel_.hidden = YES;
    }

    NSDictionary* policy = [settings valueForKey: @"OverridePolicy"];
    NSInteger perDay    = [policy isKindOfClass: [NSDictionary class]] ? [policy[@"perDay"] integerValue] : 0;
    NSInteger remaining = [state isKindOfClass: [NSDictionary class]] ? [state[@"remainingToday"] integerValue] : 0;

    self.invokeOverrideButton_.title = [NSString stringWithFormat: @"Invoke override (%ld left)", (long)remaining];
    self.invokeOverrideButton_.enabled = (perDay > 0) && (remaining > 0);
}

- (IBAction)invokeOverride:(id)sender {
    SCSettings* settings = [SCSettings sharedSettings];
    NSDictionary* policy = [settings valueForKey: @"OverridePolicy"];
    NSDictionary* state  = [settings valueForKey: @"OverrideState"];

    NSInteger minutes   = [policy isKindOfClass: [NSDictionary class]] ? [policy[@"minutes"] integerValue] : 0;
    NSInteger remaining = [state isKindOfClass: [NSDictionary class]] ? [state[@"remainingToday"] integerValue] : 0;

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Use an override?";
    alert.informativeText = [NSString stringWithFormat:
        @"This uses 1 of your %ld remaining overrides today and unblocks sites for %ld minutes. You can't cancel it once it starts.",
        (long)remaining, (long)minutes];
    [alert addButtonWithTitle: @"Use Override"];
    [alert addButtonWithTitle: @"Cancel"];

    [alert beginSheetModalForWindow: self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            return;
        }

        self.invokeOverrideButton_.enabled = NO;

        [self.appController.xpc invokeOverride:^(NSInteger remainingAfter, NSDate * _Nullable overrideEndDate, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error != nil) {
                    [SCUIUtilities presentError: error];
                }
                // Don't trust (or interpolate from) whatever status we had
                // cached before this invoke -- it's now stale. Force a fresh
                // poll of the daemon's trusted-clock status instead of
                // displaying end − now from the invoke reply itself.
                self.lastStatusValid_ = NO;
                [self refreshOverrideUI];
            });
        }];
    }];
}

#pragma mark - Properties

- (AppController *)appController
{
    AppController* controller = (AppController *)[NSApp delegate];
    return controller;
}

@end
