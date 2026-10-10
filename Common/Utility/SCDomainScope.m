#import "SCDomainScope.h"
#import "NSString+IPAddress.h"

@implementation SCDomainScope

static NSString* NormalizedHostname(NSString* hostname) {
    NSString* h = hostname.lowercaseString;
    while ([h hasSuffix: @"."]) h = [h substringToIndex: h.length - 1];
    return h;
}

+ (NSString*)registrableDomainForHostname:(NSString*)hostname {
    NSString* h = NormalizedHostname(hostname);
    NSArray<NSString*>* labels = [h componentsSeparatedByString: @"."];
    if (labels.count < 2) return h;

    static NSSet<NSString*>* secondLevel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        secondLevel = [NSSet setWithArray: @[@"co", @"com", @"net", @"org", @"gov", @"edu", @"ac",
                                             @"ne", @"or", @"go", @"gob", @"mil", @"ltd", @"plc", @"sch"]];
    });

    NSUInteger keep = 2;
    if (labels.count >= 3 && labels.lastObject.length == 2 &&
        [secondLevel containsObject: labels[labels.count - 2]]) {
        keep = 3;
    }
    return [[labels subarrayWithRange: NSMakeRange(labels.count - keep, keep)] componentsJoinedByString: @"."];
}

+ (BOOL)isAddressOnlyBlockEntry:(SCBlockEntry*)entry {
    if (entry == nil || entry.hostname.length == 0) return NO;
    if (entry.port != 0 || entry.maskLen != 0) return NO;
    if ([entry.hostname isEqualToString: @"*"] || [entry.hostname isValidIPAddress]) return NO;

    NSString* h = NormalizedHostname(entry.hostname);
    NSUInteger labels = [h componentsSeparatedByString: @"."].count;
    NSUInteger registrableLabels = [[self registrableDomainForHostname: h] componentsSeparatedByString: @"."].count;
    return labels > registrableLabels;
}

+ (BOOL)isAddressOnlyEntry:(NSString*)entryString {
    if (entryString == nil) return NO;
    return [self isAddressOnlyBlockEntry: [SCBlockEntry entryFromString: entryString]];
}

@end
