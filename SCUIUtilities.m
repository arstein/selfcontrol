//
//  SCUIUtilities.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/20/21.
//

#import "SCUIUtilities.h"
#import <SystemConfiguration/SystemConfiguration.h>
// SCDialog lives in the app's Swift code; this file is also compiled into the
// Swift-less SelfControl Killer target, which falls back to the system error sheet.
#if __has_include("SelfControl-Swift.h")
#import "SelfControl-Swift.h"
#define SC_HAS_DIALOG 1
#else
#define SC_HAS_DIALOG 0
#endif

@implementation SCUIUtilities

+ (BOOL)networkConnectionIsAvailable {
    SCNetworkReachabilityFlags flags;

    // This method goes haywire if Google ever goes down...
    SCNetworkReachabilityRef target = SCNetworkReachabilityCreateWithName (kCFAllocatorDefault, "google.com");

    BOOL reachable = (BOOL)SCNetworkReachabilityGetFlags (target, &flags);
    
    return reachable && (flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired);
}

+ (BOOL)promptBrowserRestartIfNecessary {
    NSString* ffBundleId = @"org.mozilla.firefox";
    NSArray<NSRunningApplication*>* runningFF = [NSRunningApplication runningApplicationsWithBundleIdentifier: ffBundleId];
    if (runningFF.count < 1) {
        // Firefox isn't running, no stress!
        return NO;
    }

    // all UI stuff MUST be done on the main thread
    if (![NSThread isMainThread]) {
        __block BOOL retVal = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            retVal = [SCUIUtilities promptBrowserRestartIfNecessary];
        });
        return retVal;
    }

    NSString* RESTART_FF_SUPPRESSION_KEY = @"SuppressRestartFirefoxWarning";
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

    // if they don't want the warnings, they don't get the warnings
    if ([defaults boolForKey: RESTART_FF_SUPPRESSION_KEY]) {
        return NO;
    }

#if SC_HAS_DIALOG
    // Not Now answers Esc and Return; quitting Firefox needs an explicit click.
    SCDialogResult* result = [SCDialog runWithTitle: NSLocalizedString(@"Restart Firefox?", @"FireFox browser restart prompt")
                                            message: NSLocalizedString(@"Firefox may not respect the block until it restarts.", @"Message explaining Firefox restart requirement")
                                            buttons: @[NSLocalizedString(@"Not Now", @"Button to decline restarting Firefox"),
                                                       NSLocalizedString(@"Quit Firefox", @"Button to quit Firefox")]
                                       primaryIndex: 1
                                        cancelIndex: 0
                                       defaultIndex: 0
                                   suppressionTitle: NSLocalizedString(@"Don't ask again", @"Firefox restart prompt suppression checkbox")];
    if (result.suppressionChecked) {
        // no more warnings, they say
        [defaults setBool: YES forKey: RESTART_FF_SUPPRESSION_KEY];
    }
    if (result.buttonIndex == 1) {
        for (NSRunningApplication* ff in runningFF) {
            [ff terminate];
        }
        
        return YES;
    }
#endif

    return NO;
}

+ (BOOL)blockIsRunning {
    // we'll say a block is running if we find the block info, but
    // also, importantly, if we find the regular block's rules still on the system
    // that way if this happens, the user will still see the timer window -
    // which will let them manually clear the remaining block info after 10 seconds
    return [SCBlockUtilities anyBlockIsRunning] || [SCBlockUtilities baseRulesFoundOnSystem];
}

+ (nullable NSError*)displayableError:(nullable NSError*)err {
    if (err == nil) return nil;
    // When errors are generated in the daemon, they generally don't have access to the localized .strings
    // files which are in our bundle, so the errors won't have a proper localized description.
    if ([err.domain isEqualToString: kSelfControlErrorDomain] && [err.userInfo[@"SCDescriptionNotFound"] boolValue]) {
        err = [SCErr errorWithCode: err.code];
    }
    // we don't present auth cancelled errors, since they generally don't indicate a "real" problem
    if ([SCMiscUtilities errorIsAuthCanceled: err]) return nil;
    return err;
}

+ (void)presentError:(NSError*)err {
    NSError* shown = [SCUIUtilities displayableError: err];
    if (shown == nil) return;

    // always present errors on the main thread since it's a UI task
    void (^present)(void) = ^{
#if SC_HAS_DIALOG
        [SCDialog showError: shown];
#else
        [NSApp presentError: shown];
#endif
    };
    if ([NSThread isMainThread]) {
        present();
    } else {
        dispatch_sync(dispatch_get_main_queue(), present);
    }
}

@end
