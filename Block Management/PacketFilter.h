//
//  PacketFilter.h
//  SelfControl
//
//  Created by Charles Stigler on 6/29/14.
//
//

#import <Foundation/Foundation.h>

@class SCBlockEntry;

@interface PacketFilter : NSObject {
	NSMutableString* rules;
	BOOL isAllowlist;
}

+ (BOOL)blockFoundInPF;

// Live pf state (runs /sbin/pfctl; root only, daemon only). The files can say a
// block is installed while pf itself is off (macOS loads /etc/pf.conf at boot
// without enabling pf; `pfctl -d` turns it off) or our anchor isn't loaded.
// Both answer NO when pfctl can't be run or its output can't be read.
+ (BOOL)pfIsEnabled;          // `pfctl -s info` shows "Status: Enabled"
+ (BOOL)anchorRulesLoaded;    // `pfctl -a org.eyebeam -s rules` lists a pass/block rule
// Pure parsers for the above (unit-tested on sample output).
+ (BOOL)infoOutputShowsEnabled:(NSString*)output;
+ (BOOL)rulesOutputHasRules:(NSString*)output;

// Pure pf.conf editing. "Our lines" are exactly the `anchor "org.eyebeam"` line
// and the `load anchor "org.eyebeam" ...` line (leading/trailing whitespace
// ignored); each is checked independently. nil in -> nil out (never replace
// an unreadable pf.conf with an empty one).
+ (BOOL)confTextContainsSelfControlLines:(NSString*)conf;            // either line present
+ (NSString*)confTextByAddingSelfControlLines:(NSString*)conf;       // appends only what's missing
+ (NSString*)confTextByRemovingSelfControlLines:(NSString*)conf;     // removes both

- (PacketFilter*)initAsAllowlist: (BOOL)allowlist;
- (void)addBlockHeader:(NSMutableString*)configText;
- (void)addAllowlistFooter:(NSMutableString*)configText;
- (void)addRuleWithIP:(NSString*)ip port:(NSInteger)port maskLen:(NSInteger)maskLen;
- (void)writeConfiguration;
- (NSString*)configurationText;
- (int)startBlock;
- (int)installAnchorText:(NSString*)anchorText;
- (int)stopBlock:(BOOL)force;
- (void)addSelfControlConfig;
- (BOOL)containsSelfControlBlock;
- (void)enterAppendMode;
- (void)finishAppending;
- (int)refreshPFRules;

@end
