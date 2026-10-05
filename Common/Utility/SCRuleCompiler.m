#import "SCRuleCompiler.h"

static NSString* const kLayersPrefix = @"# sc-layers: ";
static NSString* const kDeepPrefix = @"# sc-deep: ";
static NSString* const kBlockPrefix = @"block return out quick proto { tcp udp } from any to ";

@implementation SCRuleLayer
+ (instancetype)layerWithName:(NSString*)name isAllowlist:(BOOL)isAllowlist allowLocal:(BOOL)allowLocal specs:(NSArray<NSDictionary*>*)specs {
    SCRuleLayer* layer = [[self alloc] init];
    layer.name = name;
    layer.isAllowlist = isAllowlist;
    layer.allowLocal = allowLocal;
    layer.specs = specs;
    return layer;
}
@end

@implementation SCRuleCompiler

+ (NSDictionary*)specWithIP:(NSString*)ip maskLen:(NSInteger)maskLen port:(NSInteger)port {
    NSMutableDictionary* spec = [@{@"maskLen": @(maskLen), @"port": @(port)} mutableCopy];
    if (ip != nil) spec[@"ip"] = ip;
    return spec;
}

+ (NSString*)addressForSpec:(NSDictionary*)spec {
    NSString* ip = spec[@"ip"];
    if (![ip isKindOfClass:[NSString class]] || ip.length == 0) return nil;
    NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF:."];
    if ([ip rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    NSInteger maxMask = [ip containsString:@":"] ? 128 : 32;
    NSInteger mask = [spec[@"maskLen"] integerValue];
    if (mask < 0 || mask > maxMask) return nil;
    return mask > 0 ? [NSString stringWithFormat:@"%@/%ld", ip, (long)mask] : ip;
}

+ (NSInteger)portForSpec:(NSDictionary*)spec {
    NSInteger port = [spec[@"port"] integerValue];
    return (port > 0 && port <= 65535) ? port : 0;
}

+ (BOOL)specIsStar:(NSDictionary*)spec {
    return spec[@"ip"] == nil;
}

+ (NSString*)tableLineNamed:(NSString*)table addresses:(NSOrderedSet<NSString*>*)addresses {
    if (addresses.count == 0) return [NSString stringWithFormat:@"table <%@> persist\n", table];
    return [NSString stringWithFormat:@"table <%@> persist { %@ }\n", table, [addresses.array componentsJoinedByString:@", "]];
}

+ (NSString*)anchorTextForLayers:(NSArray<SCRuleLayer*>*)layers {
    NSMutableString* t = [NSMutableString string];
    NSMutableArray* names = [NSMutableArray array];
    for (SCRuleLayer* layer in layers) [names addObject:layer.name];
    [t appendFormat:@"%@%@\n", kLayersPrefix, [names componentsJoinedByString:@","]];
    for (SCRuleLayer* layer in layers) {
        if (layer.payload == nil) continue;
        NSData* json = [NSJSONSerialization dataWithJSONObject:layer.payload options:0 error:nil];
        if (json != nil) [t appendFormat:@"%@%@\n", kDeepPrefix, [json base64EncodedStringWithOptions:0]];
    }

    [t appendString:@"set block-policy drop\n"
     "set fingerprints \"/etc/pf.os\"\n"
     "set ruleset-optimization basic\n"
     "set skip on lo0\n"
     "\n"
     "# Always reachable, whatever the lists say: time checks (fail-closed timing), DNS, DHCP, mDNS.\n"
     "pass out quick proto udp from any to any port 123\n"
     "pass out quick proto { tcp udp } from any to any port 53\n"
     "pass out quick proto { tcp udp } from any to any port { 67 68 5353 }\n"];

    for (SCRuleLayer* layer in layers) {
        NSString* table = [NSString stringWithFormat:@"sc_%@", layer.name];
        [t appendFormat:@"\n# layer %@ (%@)\n", layer.name, layer.isAllowlist ? @"allowlist" : @"blocklist"];
        if (layer.isAllowlist) {
            // A "*" entry allows everything: this layer restricts nothing.
            BOOL allowsAll = NO;
            NSMutableOrderedSet<NSString*>* allowed = [NSMutableOrderedSet orderedSet];
            for (NSDictionary* spec in layer.specs) {
                if ([self specIsStar:spec]) { allowsAll = YES; break; }
                NSString* address = [self addressForSpec:spec];
                if (address != nil) [allowed addObject:address];
            }
            if (allowsAll) continue;
            if (layer.allowLocal) {
                [allowed addObjectsFromArray:@[@"10.0.0.0/8", @"172.16.0.0/12", @"192.168.0.0/16", @"169.254.0.0/16"]];
            }
            [t appendString:[self tableLineNamed:table addresses:allowed]];
            [t appendFormat:@"%@! <%@>\n", kBlockPrefix, table];
        } else {
            NSMutableOrderedSet<NSString*>* blocked = [NSMutableOrderedSet orderedSet];
            NSMutableOrderedSet<NSString*>* single = [NSMutableOrderedSet orderedSet];
            for (NSDictionary* spec in layer.specs) {
                NSInteger port = [self portForSpec:spec];
                NSString* portSuffix = port > 0 ? [NSString stringWithFormat:@" port %ld", (long)port] : @"";
                if ([self specIsStar:spec]) {
                    [single addObject:[NSString stringWithFormat:@"%@any%@\n", kBlockPrefix, portSuffix]];
                    continue;
                }
                NSString* address = [self addressForSpec:spec];
                if (address == nil) continue;
                if (port > 0) [single addObject:[NSString stringWithFormat:@"%@%@%@\n", kBlockPrefix, address, portSuffix]];
                else [blocked addObject:address];
            }
            if (blocked.count > 0) {
                [t appendString:[self tableLineNamed:table addresses:blocked]];
                [t appendFormat:@"%@<%@>\n", kBlockPrefix, table];
            }
            for (NSString* rule in single) [t appendString:rule];
        }
    }
    return t;
}

+ (NSString*)firstLineWithPrefix:(NSString*)prefix inText:(NSString*)text {
    if (![text isKindOfClass:[NSString class]]) return nil;
    for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:prefix]) return [line substringFromIndex:prefix.length];
    }
    return nil;
}

+ (NSArray<NSString*>*)layerNamesFromAnchorText:(NSString*)text {
    NSString* rest = [self firstLineWithPrefix:kLayersPrefix inText:text];
    if (rest == nil) return nil;
    NSMutableArray* names = [NSMutableArray array];
    for (NSString* part in [rest componentsSeparatedByString:@","]) {
        NSString* name = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (name.length > 0) [names addObject:name];
    }
    return names;
}

+ (NSDictionary*)deepPayloadFromAnchorText:(NSString*)text {
    NSString* encoded = [self firstLineWithPrefix:kDeepPrefix inText:text];
    if (encoded == nil) return nil;
    NSData* data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (data == nil) return nil;
    id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) return nil;
    NSArray* blocklist = payload[@"blocklist"];
    if (![blocklist isKindOfClass:[NSArray class]] || ![payload[@"isAllowlist"] isKindOfClass:[NSNumber class]]) return nil;
    for (id entry in blocklist) if (![entry isKindOfClass:[NSString class]]) return nil;
    return @{@"blocklist": blocklist, @"isAllowlist": payload[@"isAllowlist"]};
}

@end
