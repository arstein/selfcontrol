//
//  SCUIUtilities.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/20/21.
//

#import "SCUIUtilities.h"
#import <SystemConfiguration/SystemConfiguration.h>

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

    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText: NSLocalizedString(@"Restart Firefox", "FireFox browser restart prompt")];
    [alert setInformativeText:NSLocalizedString(@"SelfControl's block may not work properly in Firefox until you restart the browser. Do you want to quit Firefox now?", @"Message explaining Firefox restart requirement")];
    [alert addButtonWithTitle: NSLocalizedString(@"Quit Firefox", @"Button to quit Firefox")];
    [alert addButtonWithTitle: NSLocalizedString(@"Continue Without Restart", "Button to decline restarting Firefox")];
    alert.showsSuppressionButton = YES;

    NSModalResponse modalResponse = [alert runModal];
    if (alert.suppressionButton.state == NSControlStateValueOn) {
        // no more warnings, they say
        [defaults setBool: YES forKey: RESTART_FF_SUPPRESSION_KEY];
    }
    if (modalResponse == NSAlertFirstButtonReturn) {
        for (NSRunningApplication* ff in runningFF) {
            [ff terminate];
        }
        
        return YES;
    }
    
    return NO;
}

+ (BOOL)blockIsRunning {
    // we'll say a block is running if we find the block info, but
    // also, importantly, if we find a block still going in the hosts file
    // that way if this happens, the user will still see the timer window -
    // which will let them manually clear the remaining block info after 10 seconds
    return [SCBlockUtilities anyBlockIsRunning] || [SCBlockUtilities blockRulesFoundOnSystem];
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
    [NSApp performSelectorOnMainThread: @selector(presentError:)
                            withObject: shown
                         waitUntilDone: YES];
}

@end
