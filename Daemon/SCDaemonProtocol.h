//
//  SCDaemonProtocol.h
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SCDaemonProtocol <NSObject>

// XPC method to start block
- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to add to blocklist
- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to extend block
- (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to get version of the installed daemon
- (void)getVersionWithReply:(void(^)(NSString * version))reply;

// XPC method to start (or resume) the tedium override challenge
- (void)startTediumChallengeWithAuthorization:(NSData*)authData reply:(void(^)(NSInteger digit, NSInteger progress, NSInteger requiredEntries, NSError* _Nullable error))reply;

// XPC method to submit one challenge entry. outcome is SCTediumSubmitOutcome.
- (void)submitTediumEntry:(NSInteger)digit reply:(void(^)(NSInteger outcome, NSInteger progress, NSInteger nextDigit, BOOL blockRemoved, NSError* _Nullable error))reply;

// XPC method to invoke an override (temporarily lift the base block)
- (void)invokeOverrideWithAuthorization:(NSData *)authData
                                  reply:(void(^)(NSInteger remainingAfter, NSDate* _Nullable overrideEndDate, NSError* _Nullable error))reply;

// XPC method to poll the daemon's trusted-clock view of override status. Read-
// only, no authorization required (the connection is already code-signature
// gated), no side effects -- safe to poll frequently, and always replies
// promptly (no network, no lock wait).
- (void)getOverrideStatusWithReply:(void(^)(BOOL blockRunning, BOOL overrideActive, double overrideRemainingSecs, NSInteger remainingToday, NSInteger perDay))reply;

@end

NS_ASSUME_NONNULL_END
