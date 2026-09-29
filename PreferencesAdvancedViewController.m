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

	// The Advanced pane's view is a fixed-frame (no Auto Layout), unflipped
	// 480x226 customView loaded from the xib, with the six existing checkboxes
	// occupying y=18...190. We grow the view to 480x286 here (60px of new
	// headroom at the top, y=226...286) and add the new controls there so none
	// of the existing controls need to move.
	NSRect viewFrame = self.view.frame;
	viewFrame.size.height = 286;
	self.view.frame = viewFrame;

	NSTextField* label = [NSTextField labelWithString: NSLocalizedString(@"Maximum block length (minutes):", @"Label for the maximum block length preference field")];
	label.frame = NSMakeRect(18, 248, 220, 18);
	[self.view addSubview: label];

	NSNumberFormatter* maxBlockLengthFormatter = [[NSNumberFormatter alloc] init];
	maxBlockLengthFormatter.numberStyle = NSNumberFormatterNoStyle;
	maxBlockLengthFormatter.allowsFloats = NO;
	maxBlockLengthFormatter.minimum = @1;
	maxBlockLengthFormatter.maximum = @43200;

	maxBlockLengthField_ = [[NSTextField alloc] initWithFrame: NSMakeRect(242, 244, 70, 22)];
	maxBlockLengthField_.formatter = maxBlockLengthFormatter;
	[maxBlockLengthField_ bind: @"value"
					  toObject: [NSUserDefaultsController sharedUserDefaultsController]
				   withKeyPath: @"values.MaxBlockLength"
					   options: @{ NSContinuouslyUpdatesValueBindingOption: @YES }];
	[self.view addSubview: maxBlockLengthField_];

	maxBlockLengthHelperLabel_ = [NSTextField labelWithString: @""];
	maxBlockLengthHelperLabel_.frame = NSMakeRect(320, 248, 142, 18);
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
