//
//  SCDaemonBlockMethods.h
//  org.eyebeam.selfcontrold
//
//  Created by Charlie Stigler on 7/4/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Top-level logic for different methods run by the SelfControl daemon
// these logics can be run by XPC methods, or elsewhere
@interface SCDaemonBlockMethods : NSObject

@property (class, readonly) NSLock* daemonMethodLock;

// Starts a block
+ (void)startDeepBlockWithBlocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist durationSecs:(double)durationSecs blockSettings:(NSDictionary*)blockSettings reply:(void(^)(NSError* error))reply;
+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// Checks whether the block is expired or compromised, and takes action to fix
+ (void)checkupBlock;

// updates the blocklist for the currently running block
// (i.e. adds new sites to the list)
+ (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// updates the block end date for the currently running block
// (i.e. extends the block)
+ (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

+ (void)checkBlockIntegrity;

// Starts (or resumes) the tedium override challenge
+ (void)startTediumChallengeWithReply:(void(^)(NSInteger digit, NSInteger progress, NSInteger requiredEntries, NSError* _Nullable error))reply;

// Submits one tedium override challenge entry
+ (void)submitTediumEntry:(NSInteger)digit reply:(void(^)(NSInteger outcome, NSInteger progress, NSInteger nextDigit, BOOL blockRemoved, NSError* _Nullable error))reply;

// Invalidates any in-progress tedium challenge (called from every teardown
// path in this file so a stale challenge can't outlive its block).
// Caller must hold daemonMethodLock; performs no locking itself.
+ (void)invalidateTediumChallenge;

// Invokes an override. Pre-checks stored state (fast deny, no network), then
// performs a LIVE network time fetch (bounded by SC_OVERRIDE_VERIFY_HARD_DEADLINE_SECS,
// with daemonMethodLock released during it). No verified time => 334, nothing
// written ("no internet => no override"). With verified time, applies it as the
// checkup would (possibly verified-expiring the block => 330), resets the daily
// ration against the verified day if due, re-decides, and if allowed lifts the
// base block. Concurrent invokes are refused as busy (320). Blocks the calling
// (XPC) queue for up to the hard deadline.
+ (void)invokeOverrideWithReply:(void(^)(NSInteger remainingAfter, NSDate* _Nullable overrideEndDate, NSError* _Nullable error))reply;

// Read-only poll of the daemon's trusted-clock view of override status: no
// daemonMethodLock, no network, always replies promptly. blockRunning is
// whether a modern block is running at all; overrideActive/overrideRemainingSecs
// are computed the same way the checkup's overlay decision is (trusted clock,
// fail-closed); remainingToday/perDay reflect the stored policy/state as-is
// (no reset applied -- resets only happen against verified time elsewhere).
+ (void)getOverrideStatusWithReply:(void(^)(BOOL blockRunning, BOOL overrideActive, double overrideRemainingSecs, NSInteger remainingToday, NSInteger perDay))reply;

@end

NS_ASSUME_NONNULL_END
