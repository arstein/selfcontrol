#import "SCDeepBlockDecision.h"
#import "SCDeepBlockConfig.h"

NSString* const SCLayerBase = @"base";
NSString* const SCLayerDeep = @"deep";

@implementation SCDeepBlockDecision

+ (BOOL)durationSecsIsValid:(NSTimeInterval)secs {
    return isfinite(secs) && secs >= SC_DEEP_MIN_SECS && secs <= SC_DEEP_MAX_SECS;
}

+ (NSInteger)startRefusalCodeWithDeepEnforced:(BOOL)deepEnforced
                                 durationSecs:(NSTimeInterval)durationSecs
                                   entryCount:(NSUInteger)entryCount
                                  isAllowlist:(BOOL)isAllowlist
                                clockReadable:(BOOL)clockReadable {
    if (deepEnforced) return 325;
    if (![self durationSecsIsValid:durationSecs]) return 326;
    if (entryCount == 0 && !isAllowlist) return 302;
    if (!clockReadable) return 327;
    return 0;
}

+ (NSArray<NSString*>*)desiredLayersWithBaseRunning:(BOOL)baseRunning
                                     overrideActive:(BOOL)overrideActive
                                       deepShouldEnforce:(BOOL)deepShouldEnforce {
    NSMutableArray* layers = [NSMutableArray array];
    if (baseRunning && (!overrideActive || deepShouldEnforce)) [layers addObject:SCLayerBase];
    if (deepShouldEnforce) [layers addObject:SCLayerDeep];
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
    if (!timingComplete || !remainingKnown) return layerInstalled ? SCDeepActionHeal : SCDeepActionInstall;
    if (expired) return SCDeepActionSeekVerifiedExpiry;
    if (!layerInstalled) return SCDeepActionInstall;
    if (!startIsVerified || needsVerification) return SCDeepActionSeekVerifiedStart;
    return SCDeepActionSteady;
}

+ (BOOL)recordTimingIsComplete:(NSDictionary*)record {
    if (![record isKindOfClass:[NSDictionary class]]) return NO;
    NSNumber* duration = record[@"durationSecs"];
    NSDictionary* clockState = record[@"clockState"];
    if (![duration isKindOfClass:[NSNumber class]]) return NO;
    double secs = duration.doubleValue;
    if (!isfinite(secs) || secs <= 0 || secs > SC_DEEP_MAX_SECS) return NO;
    if (![clockState isKindOfClass:[NSDictionary class]] || clockState.count == 0) return NO;
    id verified = record[@"startIsVerified"];
    if ([verified respondsToSelector:@selector(boolValue)] && [verified boolValue]) {
        id start = record[@"startWall"];
        if (![start isKindOfClass:[NSDate class]] ||
            [(NSDate*)start timeIntervalSinceDate:[NSDate distantPast]] <= 0) return NO;
    }
    return YES;
}

+ (BOOL)recordListIsUsable:(NSDictionary*)record {
    if (![record isKindOfClass:[NSDictionary class]]) return NO;
    NSArray* list = record[@"blocklist"];
    if (![list isKindOfClass:[NSArray class]] || ![record[@"isAllowlist"] isKindOfClass:[NSNumber class]]) return NO;
    for (id entry in list) if (![entry isKindOfClass:[NSString class]]) return NO;
    return YES;
}

static NSDictionary<NSString*, NSString*>* SCDeepTimingKeyMap(void) {
    // regular-block settings key -> deep record key
    return @{@"BlockStartWall": @"startWall",
             @"BlockStartIsVerified": @"startIsVerified",
             @"BlockDurationSecs": @"durationSecs",
             @"TrustedClockState": @"clockState",
             @"TrustedClockNeedsVerification": @"needsVerification"};
}

+ (NSDictionary*)timingSnapshotForRecord:(id)record {
    if (![record isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary* snap = [NSMutableDictionary dictionary];
    [SCDeepTimingKeyMap() enumerateKeysAndObjectsUsingBlock:^(NSString* settingsKey, NSString* recordKey, BOOL* stop) {
        if (record[recordKey] != nil) snap[settingsKey] = record[recordKey];
    }];
    return snap;
}

+ (NSDictionary*)record:(id)record byApplyingTimingWrites:(NSDictionary*)writes {
    NSMutableDictionary* updated = [record isKindOfClass:[NSDictionary class]] ? [record mutableCopy] : [NSMutableDictionary dictionary];
    NSDictionary* map = SCDeepTimingKeyMap();
    for (NSString* key in writes) {
        NSString* recordKey = map[key];
        if (recordKey != nil) updated[recordKey] = writes[key];
    }
    return updated;
}

+ (BOOL)healNeededForRecord:(NSDictionary*)record
             remainingKnown:(BOOL)remainingKnown
             layerInstalled:(BOOL)layerInstalled {
    if (![record isKindOfClass:[NSDictionary class]]) return layerInstalled;
    return ![self recordTimingIsComplete:record] || !remainingKnown;
}

+ (NSDictionary*)healedRecordFromRecord:(NSDictionary*)record
                                payload:(NSDictionary*)payload
                            verifiedNow:(NSDate*)verifiedNow
                             clockState:(NSDictionary*)clockState {
    if (![record isKindOfClass:[NSDictionary class]]) record = nil;
    if (![payload isKindOfClass:[NSDictionary class]]) payload = nil;
    if (record == nil && payload == nil) return nil;
    NSMutableDictionary* healed = record ? [record mutableCopy] : [NSMutableDictionary dictionary];
    if (![healed[@"blocklist"] isKindOfClass:[NSArray class]] && [payload[@"blocklist"] isKindOfClass:[NSArray class]]) {
        healed[@"blocklist"] = payload[@"blocklist"];
    }
    for (NSString* key in @[@"isAllowlist", @"allowLocal", @"evaluateCommonSubdomains", @"includeLinkedDomains"]) {
        if (![healed[key] isKindOfClass:[NSNumber class]] && [payload[key] isKindOfClass:[NSNumber class]]) {
            healed[key] = payload[key];
        }
    }
    // Fail-closed: a missing value (tampered-away record) means off, and either source can turn it off.
    id recordUnlock = record[@"emergencyUnlockEnabled"];
    id payloadUnlock = payload[@"emergencyUnlockEnabled"];
    BOOL recordKnown = [recordUnlock isKindOfClass:[NSNumber class]];
    BOOL payloadKnown = [payloadUnlock isKindOfClass:[NSNumber class]];
    BOOL unlock = (recordKnown || payloadKnown) &&
                  (!recordKnown || [recordUnlock boolValue]) && (!payloadKnown || [payloadUnlock boolValue]);
    healed[@"emergencyUnlockEnabled"] = @(unlock);
    healed[@"durationSecs"] = @(SC_DEEP_HEAL_SECS);
    healed[@"startWall"] = verifiedNow;
    healed[@"startIsVerified"] = @YES;
    healed[@"needsVerification"] = @NO;
    healed[@"clockState"] = clockState;
    return healed;
}

+ (NSInteger)addRefusalCodeForRecord:(NSDictionary*)record {
    if (![self recordListIsUsable:record]) return 328;
    if ([record[@"isAllowlist"] boolValue]) return 329;
    return 0;
}

+ (NSArray<NSString*>*)blocklist:(NSArray<NSString*>*)current byAdding:(NSArray<NSString*>*)additions {
    // `current` is kept exactly as stored (even with duplicates); only genuinely new entries are appended.
    NSMutableArray* merged = [current mutableCopy];
    NSMutableSet* seen = [NSMutableSet setWithArray: current];
    for (NSString* entry in additions) {
        if ([seen containsObject: entry]) continue;
        [seen addObject: entry];
        [merged addObject: entry];
    }
    return merged;
}

+ (BOOL)deepListIsStaleForRecord:(NSDictionary*)record installedPayload:(NSDictionary*)payload {
    if (![self recordListIsUsable:record]) return NO;
    return [record[@"applyPending"] boolValue] || ![self installedPayload:payload coversRecord:record];
}

+ (BOOL)installedPayload:(NSDictionary*)payload coversRecord:(NSDictionary*)record {
    if (![self recordListIsUsable:record]) return YES;
    NSArray* installed = [payload isKindOfClass:[NSDictionary class]] ? payload[@"blocklist"] : nil;
    if (![installed isKindOfClass:[NSArray class]]) return NO;
    NSSet* installedSet = [NSSet setWithArray: installed];
    for (NSString* entry in record[@"blocklist"]) if (![installedSet containsObject: entry]) return NO;
    return YES;
}

@end
