//
//  SCUIUtilities.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/20/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCUIUtilities : NSObject

// Returns YES if, according to settings or the hostfile, the
// SelfControl block is running  Returns NO if it is not.
+ (BOOL)blockIsRunning;

// Checks whether a network connection is available by checking the reachabilty
// of google.com  This method may not be correct if the network configuration
// was just changed a few seconds ago.
+ (BOOL)networkConnectionIsAvailable;

+ (BOOL)promptBrowserRestartIfNecessary;

// Returns the error as it should be shown to the user (re-localizing daemon
// errors that lacked our .strings), or nil if it shouldn't be shown at all
// (nil input, or an auth-cancel).
+ (nullable NSError*)displayableError:(nullable NSError*)err;

// presents an error via a popup in the app (SCDialog, on the main thread),
// after filtering it through displayableError: (nothing is shown for nil
// or auth-cancel errors)
+ (void)presentError:(NSError*)err;

@end

NS_ASSUME_NONNULL_END
