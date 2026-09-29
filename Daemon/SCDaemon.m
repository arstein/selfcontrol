//
//  SCDaemon.m
//  SelfControl
//
//  Created by Charlie Stigler on 5/28/20.
//

#import "SCDaemon.h"
#import "SCDaemonProtocol.h"
#import "SCDaemonXPC.h"
#import"SCDaemonBlockMethods.h"
#import "SCFileWatcher.h"
#import "SCTrustedClock.h"
#import <Security/Security.h>
#import <signal.h>

static NSString* serviceName = @"org.eyebeam.selfcontrold";
float const INACTIVITY_LIMIT_SECS = 60 * 2; // 2 minutes

@interface NSXPCConnection(PrivateAuditToken)

// This property exists, but it's private. Make it available:
@property (nonatomic, readonly) audit_token_t auditToken;

@end

@interface SCDaemon () <NSXPCListenerDelegate>

@property (nonatomic, strong, readwrite) NSXPCListener* listener;
@property (strong, readwrite) NSTimer* checkupTimer;
@property (strong, readwrite) NSTimer* inactivityTimer;
@property (nonatomic, strong, readwrite) NSDate* lastActivityDate;

@property (nonatomic, strong) SCFileWatcher* hostsFileWatcher;

// Dispatch signal sources for the clean-shutdown checkpoint flush. Retained on
// strong properties because a dispatch source stops firing if it is released.
@property (strong) dispatch_source_t sigtermSource;
@property (strong) dispatch_source_t sigintSource;

@end

// Create a dispatch source that catches `sig` and runs `handler` on queue `q`.
//
// signal(sig, SIG_IGN) first: we take the signal away from the default
// (process-terminating) disposition so the dispatch source receives it. The
// event handler runs on a normal GCD queue -- NOT in async-signal context -- so
// it is safe to do real work (SCSettings I/O) there. Nothing is done in signal
// context itself.
static dispatch_source_t SCMakeSignalSource(int sig, dispatch_queue_t q, dispatch_block_t handler) {
    signal(sig, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, q);
    dispatch_source_set_event_handler(src, handler);
    dispatch_resume(src);
    return src;
}

@implementation SCDaemon

+ (instancetype)sharedDaemon {
    static SCDaemon* daemon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        daemon = [SCDaemon new];
    });
    return daemon;
}

- (id) init {
    self = [super init];
    if (self) {
        _listener = [[NSXPCListener alloc] initWithMachServiceName: serviceName];
        _listener.delegate = self;
    }
    
    return self;
}

- (void)start {
    // Re-anchor the trusted clock after a reboot BEFORE accepting XPC
    // connections, and under the daemon method lock, so no early request
    // (startBlock, extend, checkup) can observe or race the stale state.
    [SCDaemonBlockMethods.daemonMethodLock lock];
    if ([SCBlockUtilities modernBlockIsRunning]) {
        SCSettings* settings = [SCSettings sharedSettings];
        NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
        NSDictionary* reading = [SCTrustedClock currentReading];
        if ([clockState isKindOfClass:[NSDictionary class]] && clockState.count > 0 &&
            ![clockState[@"bootSessionID"] isEqual:reading[@"boot"]]) {
            [settings setValue:[SCTrustedClock reanchoredStateAfterBootChange:clockState reading:reading]
                        forKey:@"TrustedClockState"];
            [settings setValue:@YES forKey:@"TrustedClockNeedsVerification"];
            NSError* syncErr = [settings syncSettingsAndWait:5];
            if (syncErr != nil) NSLog(@"WARNING: failed to persist re-anchored trusted clock: %@", syncErr);
        }
    }
    [SCDaemonBlockMethods.daemonMethodLock unlock];

    [self.listener resume];

    // if there's any evidence of a block (i.e. an official one running,
    // OR just block remnants remaining in hosts), we should start
    // running checkup regularly so the block gets found/removed
    // at the proper time.
    // we do NOT run checkup if there's no block, because it can result
    // in the daemon actually unloading itself before the app has a chance
    // to start the block
    if ([SCBlockUtilities anyBlockIsRunning] || [SCBlockUtilities blockRulesFoundOnSystem]) {
        [self startCheckupTimer];
    }
    
    [self startInactivityTimer];
    [self resetInactivityTimer];
    
    self.hostsFileWatcher = [SCFileWatcher watcherWithFile: @"/etc/hosts" block:^(NSError * _Nonnull error) {
        if ([SCBlockUtilities anyBlockIsRunning]) {
            NSLog(@"INFO: hosts file changed, checking block integrity");
            [SCDaemonBlockMethods checkBlockIntegrity];
        }
    }];

    // Best-effort clean-shutdown flush: on SIGTERM/SIGINT write one final
    // trusted-clock checkpoint so a graceful stop loses ~0 elapsed time instead
    // of up to one checkpoint interval. Installed exactly once, here at daemon
    // startup (this is -start, the daemon's run entry called from DaemonMain).
    // The dispatch-source handler runs on the main queue -- a normal GCD queue,
    // NOT async-signal context -- so the SCSettings write it performs is safe.
    //
    // If launchd delivers SIGKILL (uncatchable) on some shutdowns, the flush
    // simply doesn't run and Phase-1 fail-closed behavior applies (elapsed time
    // is only ever under-counted, never over-counted). That is acceptable: this
    // is purely a best-effort improvement.
    __weak typeof(self) weakSelf = self;
    self.sigtermSource = SCMakeSignalSource(SIGTERM, dispatch_get_main_queue(), ^{
        [weakSelf flushTrustedClockCheckpoint];
        exit(0);
    });
    self.sigintSource = SCMakeSignalSource(SIGINT, dispatch_get_main_queue(), ^{
        [weakSelf flushTrustedClockCheckpoint];
        exit(0);
    });
}

// Writes one monotonic trusted-clock checkpoint. Safe to call from the daemon's
// normal queue only (it does real settings I/O) -- NOT from signal context.
- (void)flushTrustedClockCheckpoint {
    SCSettings* settings = [SCSettings sharedSettings];
    NSDictionary* clockState = [settings valueForKey:@"TrustedClockState"];
    if (clockState.count > 0) {
        [settings setValue:[SCTrustedClock checkpointState:clockState reading:[SCTrustedClock currentReading]]
                    forKey:@"TrustedClockState"];
        [settings syncSettingsAndWait:2];
    }
}

- (void)startCheckupTimer {
    // this method must always be called on the main thread, so the timer will work properly
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self startCheckupTimer];
        });
        return;
    }

    // if the timer's already running, don't stress it!
    if (self.checkupTimer != nil) {
        return;
    }
    
    self.checkupTimer = [NSTimer scheduledTimerWithTimeInterval: 1 repeats: YES block:^(NSTimer * _Nonnull timer) {
       [SCDaemonBlockMethods checkupBlock];
    }];

    // run the first checkup immediately!
    [SCDaemonBlockMethods checkupBlock];
}
- (void)stopCheckupTimer {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopCheckupTimer];
        });
        return;
    }
    if (self.checkupTimer == nil) {
        return;
    }
    
    [self.checkupTimer invalidate];
    self.checkupTimer = nil;
}


- (void)startInactivityTimer {
    self.inactivityTimer = [NSTimer scheduledTimerWithTimeInterval: 15.0 repeats: YES block:^(NSTimer * _Nonnull timer) {
        // we haven't had any activity in a while, the daemon appears to be idling
        // so kill it to avoid the user having unnecessary processes running!
        if ([[NSDate date] timeIntervalSinceDate: self.lastActivityDate] > INACTIVITY_LIMIT_SECS) {
            // if we're inactive but also there's a block running, that's a bad thing
            // start the checkups going again - unclear why they would've stopped
            if ([SCBlockUtilities anyBlockIsRunning] || [SCBlockUtilities blockRulesFoundOnSystem]) {
                [self startCheckupTimer];
                [SCDaemonBlockMethods checkupBlock];
                return;
            }
            
            NSLog(@"Daemon inactive for more than %f seconds, exiting!", INACTIVITY_LIMIT_SECS);
            [SCHelperToolUtilities unloadDaemonJob];
        }
    }];
}
- (void)resetInactivityTimer {
    self.lastActivityDate = [NSDate date];
}

- (void)dealloc {
    if (self.checkupTimer) {
        [self.checkupTimer invalidate];
        self.checkupTimer = nil;
    }
    if (self.inactivityTimer) {
        [self.inactivityTimer invalidate];
        self.inactivityTimer = nil;
    }
    if (self.hostsFileWatcher) {
        [self.hostsFileWatcher stopWatching];
        self.hostsFileWatcher = nil;
    }
}

// Returns the team identifier this daemon binary is signed with, or nil.
// Used to accept XPC connections only from clients signed by the same team,
// without hardcoding the fork owner's team ID in source.
+ (NSString*)ownTeamIdentifier {
    SecCodeRef selfCode = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &selfCode) != errSecSuccess || selfCode == NULL) {
        return nil;
    }
    SecStaticCodeRef staticCode = NULL;
    OSStatus status = SecCodeCopyStaticCode(selfCode, kSecCSDefaultFlags, &staticCode);
    CFRelease(selfCode);
    if (status != errSecSuccess || staticCode == NULL) {
        return nil;
    }
    CFDictionaryRef infoDict = NULL;
    status = SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &infoDict);
    CFRelease(staticCode);
    if (status != errSecSuccess || infoDict == NULL) {
        return nil;
    }
    NSDictionary* info = CFBridgingRelease(infoDict);
    return info[(__bridge NSString*)kSecCodeInfoTeamIdentifier];
}

#pragma mark - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    // There is a potential security issue / race condition with matching based on PID, so we use the (technically private) auditToken instead
    audit_token_t auditToken = newConnection.auditToken;
    NSDictionary* guestAttributes = @{
        (id)kSecGuestAttributeAudit: [NSData dataWithBytes: &auditToken length: sizeof(audit_token_t)]
    };
    SecCodeRef guest;
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef _Nullable)(guestAttributes), kSecCSDefaultFlags, &guest) != errSecSuccess) {
        return NO;
    }
    
    NSString* teamID = [SCDaemon ownTeamIdentifier];
    if (teamID == nil) {
        NSLog(@"Rejecting XPC connection: daemon has no team identifier (unsigned build?)");
        CFRelease(guest);
        return NO;
    }
    // Fork: accept only clients signed with OUR team (Apple Development or
    // Developer ID both carry the team in subject.OU). No version floor -
    // we control both sides of this connection.
    NSString* reqString = [NSString stringWithFormat:
        @"anchor apple generic and (identifier \"org.eyebeam.SelfControl\" or identifier \"org.eyebeam.selfcontrol-cli\") and certificate leaf[subject.OU] = \"%@\"",
        teamID];
    SecRequirementRef isSelfControlApp = NULL;
    if (SecRequirementCreateWithString((__bridge CFStringRef)reqString, kSecCSDefaultFlags, &isSelfControlApp) != errSecSuccess || isSelfControlApp == NULL) {
        NSLog(@"Rejecting XPC connection: could not create signing requirement");
        CFRelease(guest);
        return NO;
    }
    OSStatus clientValidityStatus = SecCodeCheckValidity(guest, kSecCSDefaultFlags, isSelfControlApp);
    
    CFRelease(guest);
    CFRelease(isSelfControlApp);
    
    if (clientValidityStatus) {
        NSError* error = [NSError errorWithDomain: NSOSStatusErrorDomain code: clientValidityStatus userInfo: nil];
        NSLog(@"Rejecting XPC connection because of invalid client signing. Error was %@", error);
        [SCSentry captureError: error];
        return NO;
    }
    
    SCDaemonXPC* scdXPC = [[SCDaemonXPC alloc] init];
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(SCDaemonProtocol)];
    newConnection.exportedObject = scdXPC;

    [newConnection resume];
    
    NSLog(@"Accepted new connection!");
    [SCSentry addBreadcrumb: @"Daemon accepted new connection" category: @"daemon"];
    
    return YES;
}

@end
