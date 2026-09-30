//
//  SCAppXPC.h
//  SelfControl
//
//  Created by Charlie Stigler on 7/4/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCXPCClient : NSObject

@property (readonly, getter=isConnected) BOOL connected;

- (void)connectToHelperTool;
- (void)installDaemon:(void(^)(NSError*))callback;
- (void)refreshConnectionAndRun:(void(^)(void))callback;
- (void)connectAndExecuteCommandBlock:(void(^)(NSError *))commandBlock;

- (void)getVersion:(void(^)(NSString* version, NSError* error))reply;
- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings reply:(void(^)(NSError* error))reply;
- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist reply:(void(^)(NSError* error))reply;
- (void)updateBlockEndDate:(NSDate*)newEndDate reply:(void(^)(NSError* error))reply;
- (void)startTediumChallenge:(void(^)(NSInteger digit, NSInteger progress, NSInteger requiredEntries, NSError* _Nullable error))reply;
- (void)submitTediumEntry:(NSInteger)digit reply:(void(^)(NSInteger outcome, NSInteger progress, NSInteger nextDigit, BOOL blockRemoved, NSError* _Nullable error))reply;
- (void)invokeOverride:(void(^)(NSInteger remainingAfter, NSDate* _Nullable overrideEndDate, NSError* _Nullable error))reply;
- (void)getOverrideStatus:(void(^)(BOOL blockRunning, BOOL overrideActive, NSTimeInterval overrideRemainingSecs, NSInteger remainingToday, NSInteger perDay, NSError* _Nullable error))reply;

@end

NS_ASSUME_NONNULL_END
