//
//  BlockManager.m
//  SelfControl
//
//  Created by Charles Stigler on 2/5/13.
//  Copyright 2009 Eyebeam.

// This file is part of SelfControl.
//
// SelfControl is free software:  you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import "BlockManager.h"
#import "SCDomainScope.h"
#import "AllowlistScraper.h"
#import "SCBlockEntry.h"
#include <sys/socket.h>
#include <netdb.h>
#import "HostFileBlockerSet.h"
#import "SCSNTPClient.h"
#import "SCRuleCompiler.h"

@implementation BlockManager

BOOL appendMode = NO;

- (BlockManager*)init {
	return [self initAsAllowlist: NO allowLocal: YES includeCommonSubdomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist {
	return [self initAsAllowlist: allowlist allowLocal: YES includeCommonSubdomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local {
	return [self initAsAllowlist: allowlist allowLocal: local includeCommonSubdomains: YES];
}
- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon {
	return [self initAsAllowlist: allowlist allowLocal: local includeCommonSubdomains: blockCommon includeLinkedDomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon includeLinkedDomains:(BOOL)includeLinked {
	if(self = [super init]) {
		opQueue = [[NSOperationQueue alloc] init];
		[opQueue setMaxConcurrentOperationCount: 35];

		pf = [[PacketFilter alloc] initAsAllowlist: allowlist];
		hostBlockerSet = [[HostFileBlockerSet alloc] init];
		hostsBlockingEnabled = NO;

		isAllowlist = allowlist;
		allowLocal = local;
		includeCommonSubdomains = blockCommon;
		includeLinkedDomains = includeLinked;
        addedBlockEntries = [NSMutableSet set];
	}

	return self;
}

- (void)prepareToAddBlock {
    for (HostFileBlocker* blocker in hostBlockerSet.blockers) {
        if([blocker containsSelfControlBlock]) {
            [blocker removeSelfControlBlock];
            [blocker writeNewFileContents];
        }
    }

	if(!isAllowlist && ![hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
        [hostBlockerSet createBackupHostsFile];
		[hostBlockerSet addSelfControlBlockHeader];
		hostsBlockingEnabled = YES;
	} else {
		hostsBlockingEnabled = NO;
	}
}

- (void)enterAppendMode {
    if (isAllowlist) {
        NSLog(@"ERROR: can't append to allowlist block");
        return;
    }
    if(![hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
        NSLog(@"ERROR: can't append to hosts block that doesn't yet exist");
        return;
    }
    
    hostsBlockingEnabled = YES;
    appendMode = YES;
    [pf enterAppendMode];
}
- (void)finishAppending {
    NSLog(@"BlockManager: About to run operation queue for appending...");
    NSDate* startedRunning  = [NSDate date];
    [opQueue waitUntilAllOperationsAreFinished];
    NSDate* finishedRunning  = [NSDate date];
    NSTimeInterval runTime = [finishedRunning timeIntervalSinceDate: startedRunning];
    NSLog(@"BlockManager: Operation queue ran in %f seconds!", runTime);

    [hostBlockerSet writeNewFileContents];
    [pf finishAppending];
    [pf refreshPFRules];
    appendMode = NO;
}

- (void)finalizeBlock {
    NSLog(@"BlockManager: About to run operation queue...");
    NSDate* startedRunning  = [NSDate date];
	[opQueue waitUntilAllOperationsAreFinished];
    NSDate* finishedRunning  = [NSDate date];
    NSTimeInterval runTime = [finishedRunning timeIntervalSinceDate: startedRunning];
    NSLog(@"BlockManager: Operation queue ran in %f seconds!", runTime);

	if(hostsBlockingEnabled) {
		[hostBlockerSet addSelfControlBlockFooter];
		[hostBlockerSet writeNewFileContents];
	}

	[pf startBlock];
}

+ (BOOL)isSinkholeAddress:(NSString*)ip maskLen:(NSInteger)maskLen {
    if (![ip isKindOfClass: [NSString class]] || ![@[@"0.0.0.0", @"::", @"127.0.0.1", @"::1"] containsObject: ip]) return NO;
    NSInteger fullLen = [ip containsString: @":"] ? 128 : 32;
    return maskLen == 0 || maskLen == fullLen;
}

- (void)emitIP:(NSString*)ip port:(NSInteger)port maskLen:(NSInteger)maskLen {
    // While a blocklist block runs, /etc/hosts maps blocked domains to 0.0.0.0 / ::
    // and CFHost honors /etc/hosts, so re-resolving returns our own sinkhole
    // addresses. They are never real destinations (and loopback always passes
    // anyway), so drop them in every mode - but only as single hosts (no mask, or
    // the full /32 or /128). A range a user typed, like 0.0.0.0/1, is kept.
    //
    // Known gap (documented, not fixed): a domain listed in two blocklist layers
    // is resolved for the second layer while the first layer's hosts sinkhole is
    // already active, so the second resolution only sees these sinkhole addresses
    // and that layer's pf rules lack the domain's real IPs. /etc/hosts still
    // blocks the domain, and the tighten-only union keeps any IPs a layer already
    // had in the installed anchor.
    if ([BlockManager isSinkholeAddress: ip maskLen: maskLen]) return;
    if (collectedSpecs != nil) {
        @synchronized (collectedSpecs) {
            [collectedSpecs addObject:[SCRuleCompiler specWithIP:ip maskLen:maskLen port:port]];
        }
        return;
    }
    [pf addRuleWithIP:ip port:port maskLen:maskLen];
}

- (void)resolveEntries:(NSArray<NSString*>*)entries specs:(NSArray<NSDictionary*>**)outSpecs hostDomains:(NSArray<NSString*>**)outDomains {
    collectedSpecs = [NSMutableArray array];
    collectedDomains = [NSMutableOrderedSet orderedSet];
    [self addBlockEntriesFromStrings: entries];
    [opQueue waitUntilAllOperationsAreFinished];
    // Deterministic output (resolution runs concurrently): star specs first,
    // then by ip string, mask, port; domains alphabetically.
    *outSpecs = [collectedSpecs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        NSString* ipA = [a[@"ip"] isKindOfClass: [NSString class]] ? a[@"ip"] : nil;
        NSString* ipB = [b[@"ip"] isKindOfClass: [NSString class]] ? b[@"ip"] : nil;
        if (ipA == nil && ipB != nil) return NSOrderedAscending;
        if (ipA != nil && ipB == nil) return NSOrderedDescending;
        if (ipA != nil) {
            NSComparisonResult r = [ipA compare: ipB];
            if (r != NSOrderedSame) return r;
        }
        NSComparisonResult r = [@([a[@"maskLen"] integerValue]) compare: @([b[@"maskLen"] integerValue])];
        if (r != NSOrderedSame) return r;
        return [@([a[@"port"] integerValue]) compare: @([b[@"port"] integerValue])];
    }];
    *outDomains = [collectedDomains.array sortedArrayUsingSelector: @selector(compare:)];
    collectedSpecs = nil;
    collectedDomains = nil;
}

// pf first: if it fails, PacketFilter has already put the previous rules back
// and /etc/hosts was never touched, so the system is exactly as before and the
// next checkup retries. Hosts is then rewritten with a single write per file
// (old SC block removed and new one added in memory), so there is never a
// moment with no hosts block.
- (BOOL)installAnchorText:(NSString*)anchorText hostDomains:(NSArray<NSString*>*)hostDomains {
    if ([pf installAnchorText: anchorText] != 0) {
        NSLog(@"ERROR: pf install failed; hosts file left unchanged.");
        return NO;
    }

    BOOL hostsOK = YES;
    for (HostFileBlocker* blocker in hostBlockerSet.blockers) {
        BOOL hadBlock = [blocker containsSelfControlBlock];
        // Back up only a clean file. When a block is already there, the backup
        // made (from a clean file) by the install that wrote it is kept.
        if (hostDomains != nil && !hadBlock) [blocker createBackupHostsFile];
        if (hadBlock) [blocker removeSelfControlBlock];
        if (hostDomains != nil) {
            [blocker addSelfControlBlockHeader];
            for (NSString* domain in hostDomains) {
                [blocker addRuleBlockingDomain: domain];
            }
            [blocker addSelfControlBlockFooter];
        }
        if (hadBlock || hostDomains != nil) {
            hostsOK = [blocker writeNewFileContents] && hostsOK;
        }
    }
    if (hostDomains == nil) [hostBlockerSet deleteBackupHostsFile];
    if (!hostsOK) NSLog(@"ERROR: Failed to write the SelfControl hosts block.");
    return hostsOK;
}

- (void)enqueueBlockEntry:(SCBlockEntry*)entry {
	NSBlockOperation* op = [NSBlockOperation blockOperationWithBlock:^{
        [self addBlockEntry: entry];
	}];
	[opQueue addOperation: op];
}

- (void)addBlockEntry:(SCBlockEntry*)entry {
    // nil entries = something didn't parse right
    if (entry == nil) return;

    NSString* normalizedHostname = entry.hostname.lowercaseString;
    while ([normalizedHostname hasSuffix:@"."]) {
        normalizedHostname = [normalizedHostname substringToIndex:normalizedHostname.length - 1];
    }
    if ([SCTimeSourceHosts() containsObject:normalizedHostname]) {
        NSLog(@"WARNING: refusing to block trusted time source %@", entry.hostname);
        return;
    }
    
    // NSMutableSet is NOT thread-safe
    @synchronized (addedBlockEntries) {
        // don't try to block the same thing twice
        if ([addedBlockEntries containsObject: entry]) {
            return;
        }
        [addedBlockEntries addObject: entry];
    }

	BOOL isIP = [entry.hostname isValidIPAddress];

    // Design spec section 7: address-only blocklist entries (e.g. www.nytimes.com)
    // are hosts-only, with no IP/pf rules, since an IP would block the whole site.
    // Accepted trade-off: DNS-over-HTTPS can bypass a hosts-only entry.
    BOOL addressOnly = !isAllowlist && [SCDomainScope isAddressOnlyBlockEntry: entry];

	if (addressOnly) {
		// hosts entry only; handled below
	} else if([entry.hostname isEqualToString: @"*"]) {
		[self emitIP: nil port: entry.port maskLen: 0];
	} else if(isIP) { // IPv4 or IPv6 literal; the rule compiler validates the address
		[self emitIP: entry.hostname port: entry.port maskLen: entry.maskLen];
	} else if(!isIP) { // domain name
        // Google requires special handling
        if ([self domainIsGoogle: entry.hostname]) {
            if (isAllowlist) {
                // just add the whole Google IP range, it's way too error-prone to do an allowlist block of Google any other way
                // last updated: 9/23/21 from https://www.gstatic.com/ipranges/goog.json
                [self addGoogleIPsToPF];
            }
            // for blocklist blocks, just skip blocking Google by IP
            // because we'd end up blocking more than the user wants (i.e. Search/Mail)
            // rely on the domain-level blocking instead
        } else {
            // non-Google domains just get looked up and blocked by IP
            NSArray* addresses = [BlockManager ipAddressesForDomainName: entry.hostname];

            for(NSUInteger i = 0; i < [addresses count]; i++) {
                NSString* ip = addresses[i];

                [self emitIP: ip port: entry.port maskLen: entry.maskLen];
            }
        }
	}

	if (collectedDomains != nil) {
		if (!isAllowlist && ![entry.hostname isEqualToString: @"*"] && !entry.port && !isIP) {
			@synchronized (collectedDomains) { [collectedDomains addObject: entry.hostname]; }
		}
	} else if(hostsBlockingEnabled && ![entry.hostname isEqualToString: @"*"] && !entry.port && !isIP) {
        if (appendMode) {
            [hostBlockerSet appendExistingBlockWithRuleForDomain: entry.hostname];
        } else {
            [hostBlockerSet addRuleBlockingDomain: entry.hostname];
        }
	}
}

- (void)addBlockEntryFromString:(NSString*)entryString {
    SCBlockEntry* entry = [SCBlockEntry entryFromString: entryString];

    // nil means that we don't have anything valid to block in this entry
    if (entry == nil) return;

    // enqueue new entries _before_ running this one, so they can happen in parallel
    NSArray<SCBlockEntry*>* relatedEntries = [self relatedBlockEntriesForEntry: entry];
    for (SCBlockEntry* relatedEntry in relatedEntries) {
        [self enqueueBlockEntry: relatedEntry];
    }

    [self addBlockEntry: entry];
}

- (void)addBlockEntriesFromStrings:(NSArray<NSString*>*)blockList {
	for(NSUInteger i = 0; i < [blockList count]; i++) {
		NSBlockOperation* op = [NSBlockOperation blockOperationWithBlock:^{
			[self addBlockEntryFromString: blockList[i]];
		}];
		[opQueue addOperation: op];
	}
}

- (BOOL)clearBlock {
	[pf stopBlock: false];
	BOOL pfSuccess = ![pf containsSelfControlBlock];

	[hostBlockerSet removeSelfControlBlock];
	BOOL hostSuccess = [hostBlockerSet writeNewFileContents];
	// Revert the host file blocker's file contents to disk so we can check
	// whether or not it still contains the block (aka we messed up).
	[hostBlockerSet revertFileContentsToDisk];
	hostSuccess = hostSuccess && ![hostBlockerSet containsSelfControlBlock];

	BOOL clearedSuccessfully = hostSuccess && pfSuccess;

	if(clearedSuccessfully)
		NSLog(@"INFO: Block successfully cleared.");
	else {
		if (!pfSuccess) {
			NSLog(@"WARNING: Error clearing pf block. Tring to clear using force.");
			[pf stopBlock: true];
		}
		if (!hostSuccess) {
			NSLog(@"WARNING: Error removing hostfile block.  Attempting to restore host file backup.");
			[hostBlockerSet restoreBackupHostsFile];
		}

		clearedSuccessfully = ![self blockIsActive];

		if ([hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
			NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
		}
		if ([pf containsSelfControlBlock]) {
			NSLog(@"ERROR: Firewall rules could not be cleared.  This may result in a permanent block.");
		}
		if (clearedSuccessfully) {
			NSLog(@"INFO: Firewall rules successfully cleared.");
		}
	}

	[hostBlockerSet deleteBackupHostsFile];

	return clearedSuccessfully;
}

- (BOOL)forceClearBlock {
	[pf stopBlock: YES];
	BOOL pfSuccess = ![pf containsSelfControlBlock];

	[hostBlockerSet removeSelfControlBlock];
	BOOL hostSuccess = [hostBlockerSet writeNewFileContents];
	// Revert the host file blocker's file contents to disk so we can check
	// whether or not it still contains the block (aka we messed up).
	[hostBlockerSet revertFileContentsToDisk];
	hostSuccess = hostSuccess && ![hostBlockerSet containsSelfControlBlock];

	BOOL clearedSuccessfully = hostSuccess && pfSuccess;

	if(clearedSuccessfully)
		NSLog(@"INFO: Block successfully cleared.");
	else {
		if (!pfSuccess) {
			NSLog(@"ERROR: Error clearing pf block. This may result in a permanent block.");
		}
		if (!hostSuccess) {
			NSLog(@"WARNING: Error removing hostfile block.  Attempting to restore host file backup.");
			[hostBlockerSet restoreBackupHostsFile];
		}

		clearedSuccessfully = ![self blockIsActive];

		if ([hostBlockerSet.defaultBlocker containsSelfControlBlock]) {
			NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
		}
		if (clearedSuccessfully) {
			NSLog(@"INFO: Firewall rules successfully cleared.");
		}
	}

	return clearedSuccessfully;
}

- (BOOL)blockIsActive {
	return [hostBlockerSet.defaultBlocker containsSelfControlBlock] || [pf containsSelfControlBlock];
}

- (NSArray*)commonSubdomainsForHostName:(NSString*)hostName {
	NSMutableSet* newHosts = [NSMutableSet set];

	// If the domain ends in facebook.com...  Special case for Facebook because
	// users will often forget to block some of its many mirror subdomains that resolve
	// to different IPs, i.e. hs.facebook.com.  Thanks to Danielle for raising this issue.
	if([hostName hasSuffix: @"facebook.com"]) {
		// pulled list of facebook IP ranges from https://developers.facebook.com/docs/sharing/webmasters/crawler
		// TODO: pull these automatically by running:
		// whois -h whois.radb.net -- '-i origin AS32934' | grep ^route
        // (looks like they now use 2 different AS numbers: https://www.facebook.com/peering/)
		NSArray* facebookIPs = @[@"31.13.24.0/21",
                                 @"31.13.64.0/18",
                                 @"45.64.40.0/22",
                                 @"66.220.144.0/20",
                                 @"69.63.176.0/20",
                                 @"69.171.224.0/19",
                                 @"74.119.76.0/22",
                                 @"102.132.96.0/20",
                                 @"103.4.96.0/22",
                                 @"129.134.0.0/16",
                                 @"147.75.208.0/20",
                                 @"157.240.0.0/16",
                                 @"173.252.64.0/18",
                                 @"179.60.192.0/22",
                                 @"185.60.216.0/22",
                                 @"185.89.216.0/22",
                                 @"199.201.64.0/22",
                                 @"204.15.20.0/22"];

		[newHosts addObjectsFromArray: facebookIPs];
	}
	if ([hostName hasSuffix: @"twitter.com"]) {
		[newHosts addObject: @"api.twitter.com"];
	}

    if ([hostName hasSuffix: @"netflix.com"]) {
        [newHosts addObject: @"assets.nflxext.com"];
        [newHosts addObject: @"codex.nflxext.com"];
        [newHosts addObject: @"nflxext.com"];
    }

	// Block the domain with no subdomains, if www.domain is blocked
	if([hostName rangeOfString: @"www."].location == 0) {
		[newHosts addObject: [hostName substringFromIndex: 4]];
	} else { // Or block www.domain otherwise
		[newHosts addObject: [@"www." stringByAppendingString: hostName]];
	}

	return [newHosts allObjects];
}

// by Jakob Egger, taken from: https://eggerapps.at/blog/2014/hostname-lookups.html
+ (NSString*)stringForAddress:(NSData*)addressData error:(NSError**)outError {
    char hbuf[NI_MAXHOST];
    int gai_error = getnameinfo(addressData.bytes, (socklen_t)addressData.length, hbuf, NI_MAXHOST, NULL, 0, NI_NUMERICHOST);
    if (gai_error) {
        if (outError) *outError = [NSError errorWithDomain:@"MyDomain" code:gai_error userInfo:@{NSLocalizedDescriptionKey:@(gai_strerror(gai_error))}];
        return nil;
    }
    return [NSString stringWithUTF8String:hbuf];
}
+ (NSArray*)ipAddressesForDomainName:(NSString*)domainName {
    if(domainName == nil) return @[];

	NSDate* startedResolving = [NSDate date];
    CFHostRef cfHost = CFHostCreateWithName(kCFAllocatorDefault, (__bridge CFStringRef)domainName);
    CFStreamError streamErr;
    // TODO: call CFHostsScheduleWithRunLoop to put this on a background thread, so we can cancel/timeout early
    CFHostStartInfoResolution(cfHost, kCFHostAddresses, &streamErr);
    if (streamErr.error) {
        NSLog(@"BlockManager: Warning: failed to resolve addresses for %@ with stream error", domainName);
        CFRelease(cfHost);
        return @[];
    }
    
    NSArray<NSData*>* addresses = (__bridge NSArray*)CFHostGetAddressing(cfHost, NULL);

    NSMutableArray* stringAddresses = [NSMutableArray array];
    if (addresses != NULL) {
        for (NSData* addrData in addresses) {
            NSError* parseErr;
            NSString* ipStr = [BlockManager stringForAddress: addrData error: &parseErr];
            if (ipStr) {
                [stringAddresses addObject: ipStr];
            } else {
                NSLog(@"BlockManager: Warning: Failed to parse IP struct for domain %@ with error %@", domainName, parseErr);
            }
        }
    } else {
        NSLog(@"BlockManager: Warning: failed to resolve addresses for %@", domainName);
    }

	// log slow resolutions
	NSDate* finishedResolving  = [NSDate date];
	NSTimeInterval resolutionTime = [finishedResolving timeIntervalSinceDate: startedResolving];
	if (resolutionTime > 2.5) {
		NSLog(@"BlockManager: Warning: took %f seconds to resolve %@", resolutionTime, domainName);
	}
    
    CFRelease(cfHost);

	return stringAddresses;
}

+ (NSPredicate*)googleTesterPredicate {
    static NSPredicate* pred = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* googleRegex = @"^([a-z0-9]+\\.)*(google|youtube|picasa|sketchup|blogger|blogspot)\\.([a-z]{1,3})(\\.[a-z]{1,3})?$";
        pred = [NSPredicate
                 predicateWithFormat: @"SELF MATCHES %@",
                 googleRegex
                 ];
    });
    
    return pred;
}
- (BOOL)domainIsGoogle:(NSString*)domainName {
	return [[BlockManager googleTesterPredicate] evaluateWithObject: domainName];
}

- (NSArray<SCBlockEntry*>*)relatedBlockEntriesForEntry:(SCBlockEntry*)entry {
    // nil means that we don't have anything valid to block in this entry, therefore no related entries either
    if (entry == nil) return @[];
    
    // Design spec section 7: an address-only blocklist entry stands alone
    // (no www./apex flip, no site-specific extras).
    if (!isAllowlist && [SCDomainScope isAddressOnlyBlockEntry: entry]) return @[];

    NSMutableArray<SCBlockEntry*>* relatedEntries = [NSMutableArray array];

    if (isAllowlist && includeLinkedDomains && ![entry.hostname isValidIPAddress]) {
        NSDate* startedScraping  = [NSDate date];
        NSArray<SCBlockEntry*>* scrapedEntries = [[AllowlistScraper relatedBlockEntries: entry.hostname] allObjects];
        NSDate* finishedScraping  = [NSDate date];
        NSTimeInterval resolutionTime = [finishedScraping timeIntervalSinceDate: startedScraping];
        if (resolutionTime > 5.0) {
            NSLog(@"BlockManager: Warning: allowlist scraper took %f seconds on %@", resolutionTime, entry.hostname);
        }
        [relatedEntries addObjectsFromArray: scrapedEntries];
    }

    if(![entry.hostname isValidIPAddress] && includeCommonSubdomains) {
        NSArray<NSString*>* commonSubdomains = [self commonSubdomainsForHostName: entry.hostname];

        for (NSString* subdomain in commonSubdomains) {
            // we do not pull port, we leave the port number the same as we got it
            SCBlockEntry* subdomainEntry = [SCBlockEntry entryFromString: subdomain];

            if (subdomainEntry == nil) continue;
            
            [relatedEntries addObject: subdomainEntry];
        }
    }
    
    return relatedEntries;
}

- (void)addGoogleIPsToPF {
    [self emitIP: @"8.8.4.0" port: 0 maskLen: 24];
    [self emitIP: @"8.34.208.0" port: 0 maskLen: 20];
    [self emitIP: @"8.35.192.0" port: 0 maskLen: 20];
    [self emitIP: @"23.236.48.0" port: 0 maskLen: 20];
    [self emitIP: @"23.251.128.0" port: 0 maskLen: 19];
    [self emitIP: @"34.64.0.0" port: 0 maskLen: 10];
    [self emitIP: @"34.128.0.0" port: 0 maskLen: 10];
    [self emitIP: @"35.184.0.0" port: 0 maskLen: 13];
    [self emitIP: @"35.192.0.0" port: 0 maskLen: 14];
    [self emitIP: @"35.196.0.0" port: 0 maskLen: 15];
    [self emitIP: @"35.198.0.0" port: 0 maskLen: 16];
    [self emitIP: @"35.199.0.0" port: 0 maskLen: 17];
    [self emitIP: @"35.199.128.0" port: 0 maskLen: 18];
    [self emitIP: @"35.200.0.0" port: 0 maskLen: 13];
    [self emitIP: @"35.208.0.0" port: 0 maskLen: 12];
    [self emitIP: @"35.224.0.0" port: 0 maskLen: 12];
    [self emitIP: @"35.240.0.0" port: 0 maskLen: 13];
    [self emitIP: @"64.15.112.0" port: 0 maskLen: 20];
    [self emitIP: @"64.233.160.0" port: 0 maskLen: 19];
    [self emitIP: @"66.102.0.0" port: 0 maskLen: 20];
    [self emitIP: @"66.249.64.0" port: 0 maskLen: 19];
    [self emitIP: @"70.32.128.0" port: 0 maskLen: 19];
    [self emitIP: @"72.14.192.0" port: 0 maskLen: 18];
    [self emitIP: @"74.114.24.0" port: 0 maskLen: 21];
    [self emitIP: @"74.125.0.0" port: 0 maskLen: 16];
    [self emitIP: @"104.154.0.0" port: 0 maskLen: 16];
    [self emitIP: @"104.196.0.0" port: 0 maskLen: 14];
    [self emitIP: @"104.237.160.0" port: 0 maskLen: 19];
    [self emitIP: @"107.167.160.0" port: 0 maskLen: 19];
    [self emitIP: @"107.178.192.0" port: 0 maskLen: 18];
    [self emitIP: @"108.59.80.0" port: 0 maskLen: 20];
    [self emitIP: @"108.170.192.0" port: 0 maskLen: 18];
    [self emitIP: @"108.177.0.0" port: 0 maskLen: 17];
    [self emitIP: @"130.211.0.0" port: 0 maskLen: 16];
    [self emitIP: @"136.112.0.0" port: 0 maskLen: 12];
    [self emitIP: @"142.250.0.0" port: 0 maskLen: 15];
    [self emitIP: @"146.148.0.0" port: 0 maskLen: 17];
    [self emitIP: @"162.216.148.0" port: 0 maskLen: 22];
    [self emitIP: @"162.222.176.0" port: 0 maskLen: 21];
    [self emitIP: @"172.110.32.0" port: 0 maskLen: 21];
    [self emitIP: @"172.217.0.0" port: 0 maskLen: 16];
    [self emitIP: @"172.253.0.0" port: 0 maskLen: 16];
    [self emitIP: @"173.194.0.0" port: 0 maskLen: 16];
    [self emitIP: @"173.255.112.0" port: 0 maskLen: 20];
    [self emitIP: @"192.158.28.0" port: 0 maskLen: 22];
    [self emitIP: @"192.178.0.0" port: 0 maskLen: 15];
    [self emitIP: @"193.186.4.0" port: 0 maskLen: 24];
    [self emitIP: @"199.36.154.0" port: 0 maskLen: 23];
    [self emitIP: @"199.36.156.0" port: 0 maskLen: 24];
    [self emitIP: @"199.192.112.0" port: 0 maskLen: 22];
    [self emitIP: @"199.223.232.0" port: 0 maskLen: 21];
    [self emitIP: @"207.223.160.0" port: 0 maskLen: 20];
    [self emitIP: @"208.65.152.0" port: 0 maskLen: 22];
    [self emitIP: @"208.68.108.0" port: 0 maskLen: 22];
    [self emitIP: @"208.81.188.0" port: 0 maskLen: 22];
    [self emitIP: @"208.117.224.0" port: 0 maskLen: 19];
    [self emitIP: @"209.85.128.0" port: 0 maskLen: 17];
    [self emitIP: @"216.58.192.0" port: 0 maskLen: 19];
    [self emitIP: @"216.73.80.0" port: 0 maskLen: 20];
    [self emitIP: @"216.239.32.0" port: 0 maskLen: 19];
    [self emitIP: @"2001:4860::" port: 0 maskLen: 32];
    [self emitIP: @"2404:6800::" port: 0 maskLen: 32];
    [self emitIP: @"2404:f340::" port: 0 maskLen: 32];
    [self emitIP: @"2600:1900::" port: 0 maskLen: 28];
    [self emitIP: @"2606:73c0::" port: 0 maskLen: 32];
    [self emitIP: @"2607:f8b0::" port: 0 maskLen: 32];
    [self emitIP: @"2620:11a:a000::" port: 0 maskLen: 40];
    [self emitIP: @"2620:120:e000::" port: 0 maskLen: 40];
    [self emitIP: @"2800:3f0::" port: 0 maskLen: 32];
    [self emitIP: @"2a00:1450::" port: 0 maskLen: 32];
    [self emitIP: @"2c0f:fb50::" port: 0 maskLen: 32];
}

@end
