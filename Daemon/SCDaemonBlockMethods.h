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

@end

NS_ASSUME_NONNULL_END
