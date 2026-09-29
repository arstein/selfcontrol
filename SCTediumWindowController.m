//
//  SCTediumWindowController.m
//  SelfControl
//
//  Fully programmatic panel (no xib) for the tedium override challenge.
//  See docs/superpowers/specs/2026-09-28-tedium-override-design.md.
//

#import "SCTediumWindowController.h"
#import "AppController.h"
#import "SCXPCClient.h"
#import "SCTediumChallenge.h"
#import "SCUIUtilities.h"
#import "SCMiscUtilities.h"
#import "SCSentry.h"

static const CGFloat kTediumPanelWidth = 320.0;
static const CGFloat kTediumPanelHeight = 220.0;
static const NSTimeInterval kTediumStatusFlashDuration = 1.5;

@interface SCTediumWindowController ()

@property (nonatomic, readonly) AppController* appController;

@property (nonatomic, strong) NSTextField* digitLabel;
@property (nonatomic, strong) NSTextField* progressLabel;
@property (nonatomic, strong) NSTextField* statusLabel;
@property (nonatomic, strong) NSTextField* entryField;
@property (nonatomic, strong) NSButton* cancelButton;

@property (nonatomic) NSInteger requiredEntries;
@property (nonatomic, strong, nullable) NSTimer* statusClearTimer;

@end

@implementation SCTediumWindowController

- (instancetype)init {
    NSRect contentRect = NSMakeRect(0, 0, kTediumPanelWidth, kTediumPanelHeight);
    NSPanel* panel = [[NSPanel alloc] initWithContentRect: contentRect
                                                 styleMask: (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                   backing: NSBackingStoreBuffered
                                                     defer: NO];
    panel.title = NSLocalizedString(@"Tedious Override", @"tedium override panel title");
    panel.level = NSNormalWindowLevel;
    // Keep the window object alive across hide/show cycles - we reuse a single
    // controller (and thus a single window) for the lifetime of the app.
    panel.releasedWhenClosed = NO;
    [panel center];

    if (self = [super initWithWindow: panel]) {
        [self buildContentView];
    }
    return self;
}

#pragma mark - UI construction

- (NSTextField*)makeLabelWithFrame:(NSRect)frame {
    NSTextField* label = [[NSTextField alloc] initWithFrame: frame];
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.alignment = NSTextAlignmentCenter;
    return label;
}

- (void)buildContentView {
    NSView* contentView = self.window.contentView;
    CGFloat width = contentView.frame.size.width;

    self.digitLabel = [self makeLabelWithFrame: NSMakeRect(0, 110, width, 76)];
    self.digitLabel.font = [NSFont boldSystemFontOfSize: 64];
    [contentView addSubview: self.digitLabel];

    self.progressLabel = [self makeLabelWithFrame: NSMakeRect(0, 88, width, 20)];
    self.progressLabel.font = [NSFont systemFontOfSize: 13];
    [contentView addSubview: self.progressLabel];

    self.statusLabel = [self makeLabelWithFrame: NSMakeRect(0, 66, width, 18)];
    self.statusLabel.font = [NSFont systemFontOfSize: 11];
    self.statusLabel.stringValue = @"";
    [contentView addSubview: self.statusLabel];

    self.entryField = [[NSTextField alloc] initWithFrame: NSMakeRect((width - 80) / 2, 28, 80, 28)];
    self.entryField.font = [NSFont systemFontOfSize: 20];
    self.entryField.alignment = NSTextAlignmentCenter;
    self.entryField.target = self;
    self.entryField.action = @selector(submitEntry:);
    [contentView addSubview: self.entryField];

    self.cancelButton = [[NSButton alloc] initWithFrame: NSMakeRect(width - 96, 10, 80, 24)];
    self.cancelButton.title = NSLocalizedString(@"Cancel", @"Cancel button");
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.target = self;
    self.cancelButton.action = @selector(cancelChallenge:);
    [contentView addSubview: self.cancelButton];
}

#pragma mark - Properties

- (AppController*)appController {
    return (AppController*)[NSApp delegate];
}

#pragma mark - Challenge lifecycle

- (void)beginChallenge {
    [self.appController.xpc startTediumChallenge:^(NSInteger digit, NSInteger progress, NSInteger requiredEntries, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil) {
                [self presentStartError: error];
                return;
            }

            self.requiredEntries = requiredEntries;
            [self updateDigit: digit progress: progress];
            [self clearStatus];

            [self showWindow: nil];
            [self.window center];
            [self.window makeKeyAndOrderFront: nil];
            [self clearAndRefocusEntryField];
        });
    }];
}

- (void)presentStartError:(NSError*)error {
    // an auth-cancel just means the user backed out of the Touch ID/password
    // prompt - not a real error, so don't nag them about it.
    if ([SCMiscUtilities errorIsAuthCanceled: error]) {
        return;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"Couldn't start tedium override", @"tedium override: start failure alert title");
    if (error.code == 321) {
        alert.informativeText = NSLocalizedString(@"No block is running.", @"tedium override: no block running error");
    } else {
        alert.informativeText = error.localizedDescription;
    }
    [alert addButtonWithTitle: NSLocalizedString(@"OK", @"OK button")];
    [alert runModal];
}

#pragma mark - Entry submission

- (IBAction)submitEntry:(id)sender {
    NSString* text = self.entryField.stringValue;
    NSCharacterSet* digitSet = [NSCharacterSet characterSetWithCharactersInString: @"0123456789"];
    BOOL isExactlyOneDigit = (text.length == 1) && [digitSet characterIsMember: [text characterAtIndex: 0]];

    if (!isExactlyOneDigit) {
        // never send garbage to the daemon - a mistyped/pasted non-digit costs
        // nothing, only a genuinely wrong DIGIT does.
        NSBeep();
        [self clearAndRefocusEntryField];
        return;
    }

    NSInteger digit = [text integerValue];

    [self.appController.xpc submitTediumEntry: digit reply:^(NSInteger outcome, NSInteger progress, NSInteger nextDigit, BOOL blockRemoved, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearAndRefocusEntryField];

            if (error != nil) {
                if (error.code == 322) {
                    // the challenge (or its block) is already gone - nothing left to do here
                    [self.window close];
                    [self showPlainAlert: NSLocalizedString(@"Block removed.", @"tedium override: block already removed message")];
                } else {
                    [SCUIUtilities presentError: error];
                }
                return;
            }

            [self updateDigit: nextDigit progress: progress];

            switch ((SCTediumSubmitOutcome)outcome) {
                case SCTediumSubmitWrongDigit:
                    [self flashStatus: NSLocalizedString(@"Wrong — −20", @"tedium override: wrong digit penalty message")
                                 color: [NSColor systemRedColor]];
                    break;
                case SCTediumSubmitIgnoredTooFast:
                    [self flashStatus: NSLocalizedString(@"(too fast — ignored)", @"tedium override: entry ignored for arriving too fast")
                                 color: [NSColor secondaryLabelColor]];
                    break;
                case SCTediumSubmitAccepted:
                case SCTediumSubmitComplete:
                    [self clearStatus];
                    break;
            }

            if (blockRemoved) {
                [self.window close];
                [self showPlainAlert: NSLocalizedString(@"Block removed.", @"tedium override: block removed message")];
            }
        });
    }];
}

- (IBAction)cancelChallenge:(id)sender {
    // the daemon-side challenge session persists - closing just hides the panel
    [self.window close];
}

#pragma mark - UI helpers (main thread only)

- (void)updateDigit:(NSInteger)digit progress:(NSInteger)progress {
    self.digitLabel.stringValue = [NSString stringWithFormat: @"%ld", (long)digit];
    self.progressLabel.stringValue = [NSString stringWithFormat: NSLocalizedString(@"%ld / %ld", @"tedium override progress label, e.g. 17 / 300"), (long)progress, (long)self.requiredEntries];
}

- (void)clearStatus {
    [self.statusClearTimer invalidate];
    self.statusClearTimer = nil;
    self.statusLabel.stringValue = @"";
}

- (void)flashStatus:(NSString*)message color:(NSColor*)color {
    [self.statusClearTimer invalidate];

    self.statusLabel.textColor = color;
    self.statusLabel.stringValue = message;

    __weak typeof(self) weakSelf = self;
    self.statusClearTimer = [NSTimer scheduledTimerWithTimeInterval: kTediumStatusFlashDuration repeats: NO block:^(NSTimer * _Nonnull timer) {
        weakSelf.statusLabel.stringValue = @"";
    }];
}

- (void)clearAndRefocusEntryField {
    self.entryField.stringValue = @"";
    [self.window makeFirstResponder: self.entryField];
}

- (void)showPlainAlert:(NSString*)message {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = message;
    [alert addButtonWithTitle: NSLocalizedString(@"OK", @"OK button")];
    [alert runModal];
}

@end
