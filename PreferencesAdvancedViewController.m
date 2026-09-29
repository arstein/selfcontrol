//
//  PreferencesAdvancedViewController.m
//  SelfControl
//
//  Created by Charles Stigler on 9/27/14.
//
//

#import "PreferencesAdvancedViewController.h"
#import "SCSettings.h"
#import "SCDurationSlider.h"

@interface PreferencesAdvancedViewController ()


@end

// Distinct KVO context pointer so our observer callback never gets confused
// with any other object's observation of the same NSViewController.
static void* PreferencesAdvancedMaxBlockLengthContext = &PreferencesAdvancedMaxBlockLengthContext;

@implementation PreferencesAdvancedViewController {
	NSTextField* maxBlockLengthField_;
	NSTextField* maxBlockLengthHelperLabel_;
	BOOL maxBlockLengthKVORegistered_;
}

- (instancetype)init {
	return [super initWithNibName: @"PreferencesAdvancedViewController" bundle: nil];
}

- (void)viewDidLoad {
	[super viewDidLoad];

	// The Advanced pane's view is an unflipped 480x226 customView loaded from
	// the xib. It uses springs-and-struts autoresizing (NOT Auto Layout), and
	// every existing checkbox carries the flexibleMinY mask (pinned to the top
	// edge). That means simply growing the view's height drags all six checkboxes
	// *upward* by the same amount into any headroom we try to open, so they
	// collide with anything we add there (the overlap bug Adam hit).
	//
	// To add a clean new row at the BOTTOM: (1) suspend subview autoresizing so
	// the frame change doesn't reposition anything, (2) shift the existing
	// controls up to free space at the bottom, (3) grow the view, (4) restore
	// autoresizing, then (5) place our new row in the freed band. MASPreferences
	// pins this non-resizable pane to exactly this size, so nothing resizes it
	// again after viewDidLoad.
	const CGFloat kAddedHeight = 40.0;

	self.view.autoresizesSubviews = NO;
	for (NSView* existing in [self.view.subviews copy]) {
		NSRect r = existing.frame;
		r.origin.y += kAddedHeight;
		existing.frame = r;
	}
	NSRect viewFrame = self.view.frame;
	viewFrame.size.height += kAddedHeight; // 226 -> 266
	self.view.frame = viewFrame;
	self.view.autoresizesSubviews = YES;

	NSTextField* label = [NSTextField labelWithString: NSLocalizedString(@"Maximum block length (minutes):", @"Label for the maximum block length preference field")];
	label.frame = NSMakeRect(18, 15, 220, 18);
	[self.view addSubview: label];

	NSNumberFormatter* maxBlockLengthFormatter = [[NSNumberFormatter alloc] init];
	maxBlockLengthFormatter.numberStyle = NSNumberFormatterNoStyle;
	maxBlockLengthFormatter.allowsFloats = NO;
	maxBlockLengthFormatter.minimum = @1;
	maxBlockLengthFormatter.maximum = @43200;

	maxBlockLengthField_ = [[NSTextField alloc] initWithFrame: NSMakeRect(242, 11, 70, 22)];
	maxBlockLengthField_.formatter = maxBlockLengthFormatter;
	[maxBlockLengthField_ bind: @"value"
					  toObject: [NSUserDefaultsController sharedUserDefaultsController]
				   withKeyPath: @"values.MaxBlockLength"
					   options: @{ NSContinuouslyUpdatesValueBindingOption: @YES }];
	[self.view addSubview: maxBlockLengthField_];

	maxBlockLengthHelperLabel_ = [NSTextField labelWithString: @""];
	maxBlockLengthHelperLabel_.frame = NSMakeRect(320, 15, 142, 18);
	[self.view addSubview: maxBlockLengthHelperLabel_];

	[self updateMaxBlockLengthHelperLabel];

	// Keep the helper label's readable equivalent (e.g. "= 1 day") in sync
	// whenever the underlying default changes, from any source.
	[[NSUserDefaultsController sharedUserDefaultsController] addObserver: self
																forKeyPath: @"values.MaxBlockLength"
																   options: 0
																   context: PreferencesAdvancedMaxBlockLengthContext];
	maxBlockLengthKVORegistered_ = YES;
}

- (void)updateMaxBlockLengthHelperLabel {
	NSInteger maxBlockLengthMinutes = [[NSUserDefaults standardUserDefaults] integerForKey: @"MaxBlockLength"];
	maxBlockLengthHelperLabel_.stringValue = [NSString stringWithFormat: @"= %@", [SCDurationSlider timeSliderDisplayStringFromNumberOfMinutes: maxBlockLengthMinutes]];
}

- (void)observeValueForKeyPath:(NSString*)keyPath
					   ofObject:(id)object
						 change:(NSDictionary<NSKeyValueChangeKey, id>*)change
						context:(void*)context {
	if (context == PreferencesAdvancedMaxBlockLengthContext) {
		[self updateMaxBlockLengthHelperLabel];
		return;
	}

	[super observeValueForKeyPath: keyPath ofObject: object change: change context: context];
}

- (void)dealloc {
	if (maxBlockLengthKVORegistered_) {
		@try {
			[[NSUserDefaultsController sharedUserDefaultsController] removeObserver: self
																		   forKeyPath: @"values.MaxBlockLength"
																			  context: PreferencesAdvancedMaxBlockLengthContext];
		} @catch (NSException* e) {
			NSLog(@"WARNING: Failed to remove MaxBlockLength observer: %@", e);
		}
		maxBlockLengthKVORegistered_ = NO;
	}
}

#pragma mark MASPreferencesViewController

- (NSString*)identifier {
	return @"AdvancedPreferences";
}
- (NSImage *)toolbarItemImage {
	return [NSImage imageNamed: NSImageNameAdvanced];
}

- (NSString *)toolbarItemLabel {
	return NSLocalizedString(@"Advanced", @"Toolbar item name for the Advanced preference pane");
}

@end
