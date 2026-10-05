#import "SCDeepBlockDecision.h"
#import "SCDeepBlockConfig.h"

NSString* const SCLayerBase = @"base";
NSString* const SCLayerDeep = @"deep";

@implementation SCDeepBlockDecision

+ (BOOL)durationSecsIsValid:(NSTimeInterval)secs {
    return isfinite(secs) && secs >= SC_DEEP_MIN_SECS && secs <= SC_DEEP_MAX_SECS;
}

+ (NSArray<NSString*>*)desiredLayersWithBaseRunning:(BOOL)baseRunning
                                     overrideActive:(BOOL)overrideActive
                                        deepPresent:(BOOL)deepPresent {
    NSMutableArray* layers = [NSMutableArray array];
    if (baseRunning && (!overrideActive || deepPresent)) [layers addObject:SCLayerBase];
    if (deepPresent) [layers addObject:SCLayerDeep];
    return layers;
}

+ (SCDeepAction)actionForRecordPresent:(BOOL)recordPresent
                        timingComplete:(BOOL)timingComplete
                        remainingKnown:(BOOL)remainingKnown
                               expired:(BOOL)expired
                       startIsVerified:(BOOL)startIsVerified
                     needsVerification:(BOOL)needsVerification
                        layerInstalled:(BOOL)layerInstalled {
    if (!recordPresent) return layerInstalled ? SCDeepActionHeal : SCDeepActionNone;
    if (!timingComplete || !remainingKnown) return SCDeepActionHeal;
    if (expired) return SCDeepActionSeekVerifiedExpiry;
    if (!layerInstalled) return SCDeepActionInstall;
    if (!startIsVerified || needsVerification) return SCDeepActionSeekVerifiedStart;
    return SCDeepActionSteady;
}

+ (BOOL)recordTimingIsComplete:(NSDictionary*)record {
    if (![record isKindOfClass:[NSDictionary class]]) return NO;
    NSNumber* duration = record[@"durationSecs"];
    NSDictionary* clockState = record[@"clockState"];
    return [duration isKindOfClass:[NSNumber class]] && duration.doubleValue > 0 &&
           [clockState isKindOfClass:[NSDictionary class]] && clockState.count > 0;
}

static NSDictionary<NSString*, NSString*>* SCDeepTimingKeyMap(void) {
    // regular-block settings key -> deep record key
    return @{@"BlockStartWall": @"startWall",
             @"BlockStartIsVerified": @"startIsVerified",
             @"BlockDurationSecs": @"durationSecs",
             @"TrustedClockState": @"clockState",
             @"TrustedClockNeedsVerification": @"needsVerification"};
}

+ (NSDictionary*)timingSnapshotForRecord:(NSDictionary*)record {
    NSMutableDictionary* snap = [NSMutableDictionary dictionary];
    [SCDeepTimingKeyMap() enumerateKeysAndObjectsUsingBlock:^(NSString* settingsKey, NSString* recordKey, BOOL* stop) {
        if (record[recordKey] != nil) snap[settingsKey] = record[recordKey];
    }];
    return snap;
}

+ (NSDictionary*)record:(NSDictionary*)record byApplyingTimingWrites:(NSDictionary*)writes {
    NSMutableDictionary* updated = [record mutableCopy];
    NSDictionary* map = SCDeepTimingKeyMap();
    for (NSString* key in writes) {
        NSString* recordKey = map[key];
        if (recordKey != nil) updated[recordKey] = writes[key];
    }
    return updated;
}

@end
