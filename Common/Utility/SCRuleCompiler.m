#import "SCRuleCompiler.h"
#include <arpa/inet.h>

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
    // Strict parse: anything inet_pton rejects would make pf reject the whole ruleset.
    const char* cip = ip.UTF8String;
    struct in_addr a4;
    struct in6_addr a6;
    NSInteger maxMask;
    if (inet_pton(AF_INET, cip, &a4) == 1) maxMask = 32;
    else if (inet_pton(AF_INET6, cip, &a6) == 1) maxMask = 128;
    else return nil;
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
    // Only well-formed, unique layer names are emitted: the name goes into the
    // marker line and a pf table name, so anything else could break parsing.
    NSMutableArray<SCRuleLayer*>* emitted = [NSMutableArray array];
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    NSCharacterSet* nonLower = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"].invertedSet;
    for (SCRuleLayer* layer in layers) {
        NSString* name = layer.name;
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;
        if ([name rangeOfCharacterFromSet:nonLower].location != NSNotFound) continue;
        if ([names containsObject:name]) continue;
        [names addObject:name];
        [emitted addObject:layer];
    }
    layers = emitted;

    NSMutableString* t = [NSMutableString string];
    [t appendFormat:@"%@%@\n", kLayersPrefix, [names componentsJoinedByString:@","]];
    for (SCRuleLayer* layer in layers) {
        if (layer.payload == nil || ![NSJSONSerialization isValidJSONObject:layer.payload]) continue;
        NSData* json = [NSJSONSerialization dataWithJSONObject:layer.payload options:0 error:nil];
        if (json != nil) [t appendFormat:@"%@%@\n", kDeepPrefix, [json base64EncodedStringWithOptions:0]];
    }

    // No `set` options: pf ignores them inside an anchor. Loopback and the
    // infrastructure below must always pass, so they come before every block.
    [t appendString:@"\n"
     "# Always reachable, whatever the lists say: loopback, time checks (fail-closed timing), DNS, DHCP/DHCPv6, mDNS.\n"
     "pass quick on lo0 all\n"
     "pass out quick proto udp from any to any port 123\n"
     "pass out quick proto { tcp udp } from any to any port 53\n"
     "pass out quick proto udp from any to any port { 67 68 546 547 5353 }\n"];

    for (SCRuleLayer* layer in layers) {
        NSString* table = [NSString stringWithFormat:@"sc_%@", layer.name];
        [t appendFormat:@"\n# layer %@ (%@)\n", layer.name, layer.isAllowlist ? @"allowlist" : @"blocklist"];
        if (layer.isAllowlist) {
            // A portless "*" entry allows everything: this layer restricts nothing.
            // A "*" entry with a port is ignored (the table can't express it; stricter = fail-closed).
            BOOL allowsAll = NO;
            NSMutableOrderedSet<NSString*>* allowed = [NSMutableOrderedSet orderedSet];
            for (NSDictionary* spec in layer.specs) {
                if ([self specIsStar:spec]) {
                    if ([self portForSpec:spec] == 0) { allowsAll = YES; break; }
                    continue;
                }
                NSString* address = [self addressForSpec:spec];
                if (address != nil) [allowed addObject:address];
            }
            if (allowsAll) continue;
            if (layer.allowLocal) {
                [allowed addObjectsFromArray:@[@"10.0.0.0/8", @"172.16.0.0/12", @"192.168.0.0/16", @"169.254.0.0/16", @"fe80::/10", @"fc00::/7"]];
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
    __block NSString* found = nil;
    [text enumerateLinesUsingBlock:^(NSString* line, BOOL* stop) {
        if ([line hasPrefix:prefix]) {
            found = [line substringFromIndex:prefix.length];
            *stop = YES;
        }
    }];
    return found;
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
    NSMutableDictionary* result = [@{@"blocklist": blocklist, @"isAllowlist": payload[@"isAllowlist"]} mutableCopy];
    for (NSString* key in @[@"emergencyUnlockEnabled", @"allowLocal", @"evaluateCommonSubdomains", @"includeLinkedDomains"]) {
        if ([payload[key] isKindOfClass:[NSNumber class]]) result[key] = payload[key];
    }
    return result;
}

// "a.b.c.d" or "a.b.c.d/n" -> spec (validated); nil if not a well-formed address.
+ (NSDictionary*)specForAddress:(NSString*)address port:(NSInteger)port {
    NSArray<NSString*>* parts = [address componentsSeparatedByString:@"/"];
    if (parts.count > 2 || parts[0].length == 0) return nil;
    NSInteger mask = 0;
    if (parts.count == 2) {
        NSScanner* scanner = [NSScanner scannerWithString:parts[1]];
        if (![scanner scanInteger:&mask] || !scanner.isAtEnd || mask <= 0) return nil;
    }
    NSDictionary* spec = [self specWithIP:parts[0] maskLen:mask port:port];
    return [self addressForSpec:spec] != nil ? spec : nil;
}

+ (NSArray<NSDictionary*>*)blocklistSpecsForLayer:(NSString*)name inAnchorText:(NSString*)text {
    if (![text isKindOfClass:[NSString class]] || name.length == 0) return @[];
    NSString* header = [NSString stringWithFormat:@"# layer %@ (blocklist)", name];
    NSString* tablePrefix = [NSString stringWithFormat:@"table <sc_%@> persist { ", name];
    NSMutableArray<NSDictionary*>* specs = [NSMutableArray array];
    __block BOOL inSection = NO;
    [text enumerateLinesUsingBlock:^(NSString* line, BOOL* stop) {
        if ([line hasPrefix:@"# layer "]) {
            if (inSection) { *stop = YES; return; }
            inSection = [line isEqualToString:header];
            return;
        }
        if (!inSection) return;
        if ([line hasPrefix:tablePrefix] && [line hasSuffix:@" }"]) {
            NSString* body = [line substringWithRange:NSMakeRange(tablePrefix.length, line.length - tablePrefix.length - 2)];
            for (NSString* part in [body componentsSeparatedByString:@","]) {
                NSString* address = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSDictionary* spec = [self specForAddress:address port:0];
                if (spec != nil) [specs addObject:spec];
            }
            return;
        }
        if (![line hasPrefix:kBlockPrefix]) return;
        // "<addr>" | "<addr> port <p>" | "any" | "any port <p>"; the "<sc_name>" table rule is skipped.
        NSArray<NSString*>* words = [[line substringFromIndex:kBlockPrefix.length] componentsSeparatedByString:@" "];
        NSInteger port = 0;
        if (words.count == 3 && [words[1] isEqualToString:@"port"]) {
            NSScanner* scanner = [NSScanner scannerWithString:words[2]];
            if (![scanner scanInteger:&port] || !scanner.isAtEnd || port <= 0 || port > 65535) return;
        } else if (words.count != 1) {
            return;
        }
        if ([words[0] isEqualToString:@"any"]) {
            [specs addObject:[self specWithIP:nil maskLen:0 port:port]];
            return;
        }
        NSDictionary* spec = [self specForAddress:words[0] port:port];
        if (spec != nil) [specs addObject:spec];
    }];
    return specs;
}

@end
