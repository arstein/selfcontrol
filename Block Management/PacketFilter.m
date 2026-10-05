//
//  PacketFilter.m
//  SelfControl
//
//  Created by Charles Stigler on 6/29/14.
//
//

#import "PacketFilter.h"

NSString* const kPfctlExecutablePath = @"/sbin/pfctl";
NSString* const kPFConfPath = @"/etc/pf.conf";
NSString* const kPFAnchorCommand = @"anchor \"org.eyebeam\"";
NSString* const kPFAnchorPath = @"/etc/pf.anchors/org.eyebeam";

@implementation PacketFilter

NSFileHandle* appendFileHandle;

+ (BOOL)blockFoundInPF {
    // last try if we can't find a block anywhere: check the host file, and see if a block is in there
    NSString* pfConfContents = [NSString stringWithContentsOfFile: kPFConfPath encoding: NSUTF8StringEncoding error: NULL];
    if(pfConfContents != nil && [pfConfContents rangeOfString: kPFAnchorCommand].location != NSNotFound) {
        return YES;
    }

    return NO;
}

- (PacketFilter*)initAsAllowlist: (BOOL)allowlist {
	if (self = [super init]) {
		isAllowlist = allowlist;
		rules = [NSMutableString stringWithCapacity: 1000];
	}
	return self;
}

- (void)addBlockHeader:(NSMutableString*)configText {
	[configText appendString: @"# Options\n"
	 "set block-policy drop\n"
	 "set fingerprints \"/etc/pf.os\"\n"
	 "set ruleset-optimization basic\n"
	 "set skip on lo0\n"
	 "\n"
	 "#\n"
	 "# org.eyebeam ruleset for SelfControl blocks\n"
	 "#\n"];

	// Fail-closed trusted timing: the time sources (SNTP) and DNS must always be
	// reachable, in both blocklist and allowlist mode and no matter what block/pass
	// rules follow below - otherwise a blocklist entry like a bare "*", a raw IP, or a
	// wide CIDR range (e.g. an Apple or resolver range) could block UDP 123 and/or DNS,
	// and an expired block could never be verified and lifted. "quick" makes these
	// rules terminal: matching traffic is decided right here, and no later rule in
	// this anchor (which otherwise follows pf's last-match-wins precedence) can
	// override them. These are intentionally family-agnostic (no inet/inet6 keyword),
	// matching the style of the other rules generated in this file.
	[configText appendString: @"# fail-closed trusted timing: time sources and DNS must always be reachable\n"
	 "pass out quick proto udp from any to any port 123\n"
	 "pass out quick proto udp from any to any port 53\n"
	 "pass out quick proto tcp from any to any port 53\n"
	 "\n"];

	if (isAllowlist) {
		[configText appendString: @"block return out proto tcp from any to any\n"
		 "block return out proto udp from any to any\n"
		 "\n"];
	}
}
- (void)addAllowlistFooter:(NSMutableString*)configText {
	[configText appendString: @"pass out proto tcp from any to any port 53\n"];
	[configText appendString: @"pass out proto udp from any to any port 53\n"];
	[configText appendString: @"pass out proto udp from any to any port 123\n"];
	[configText appendString: @"pass out proto udp from any to any port 67\n"];
	[configText appendString: @"pass out proto tcp from any to any port 67\n"];
	[configText appendString: @"pass out proto udp from any to any port 68\n"];
	[configText appendString: @"pass out proto tcp from any to any port 68\n"];
	[configText appendString: @"pass out proto udp from any to any port 5353\n"];
	[configText appendString: @"pass out proto tcp from any to any port 5353\n"];
}

- (NSArray<NSString*>*)ruleStringsForIP:(NSString*)ip port:(NSInteger)port maskLen:(NSInteger)maskLen {
    NSMutableString* rule = [NSMutableString stringWithString: @"from any to "];

    if (ip) {
        [rule appendString: ip];
    } else {
        [rule appendString: @"any"];
    }

    if (maskLen) {
        [rule appendString: [NSString stringWithFormat: @"/%ld", (long)maskLen]];
    }

    if (port) {
        [rule appendString: [NSString stringWithFormat: @" port %ld", (long)port]];
    }

    if (isAllowlist) {
        return @[
            [NSString stringWithFormat: @"pass out proto tcp %@\n", rule],
            [NSString stringWithFormat: @"pass out proto udp %@\n", rule]
        ];
    } else {
        return @[
            [NSString stringWithFormat: @"block return out proto tcp %@\n", rule],
            [NSString stringWithFormat: @"block return out proto udp %@\n", rule]
        ];
    }
}
- (void)addRuleWithIP:(NSString*)ip port:(NSInteger)port maskLen:(NSInteger)maskLen {
    @synchronized(self) {
        NSArray<NSString*>* ruleStrings = [self ruleStringsForIP: ip port: port maskLen: maskLen];
        for (NSString* ruleString in ruleStrings) {
            if (appendFileHandle) {
                [appendFileHandle writeData: [ruleString dataUsingEncoding:NSUTF8StringEncoding]];
            } else {
                [rules appendString: ruleString];
            }
        }
    }
}

- (NSString*)configurationText {
	NSMutableString* filterConfiguration = [NSMutableString stringWithCapacity: 1000];

	[self addBlockHeader: filterConfiguration];
	[filterConfiguration appendString: rules];

	if (isAllowlist) {
		[self addAllowlistFooter: filterConfiguration];
	}
	return filterConfiguration;
}

- (void)writeConfiguration {
	[[self configurationText] writeToFile: @"/etc/pf.anchors/org.eyebeam" atomically: true encoding: NSUTF8StringEncoding error: nil];
}

- (void)enterAppendMode {
    if (isAllowlist) {
        NSLog(@"WARNING: Can't append rules to allowlist blocks - ignoring");
        return;
    }

    // open the file and prepare to write to the very bottom (no footer since it's not an allowlist)
    appendFileHandle = [NSFileHandle fileHandleForWritingAtPath: @"/etc/pf.anchors/org.eyebeam"];
    if (!appendFileHandle) {
        NSLog(@"ERROR: Failed to get handle for pf.anchors file while attempting to append rules");
        return;
    }

    [appendFileHandle seekToEndOfFile];
}
- (void)finishAppending {
    [appendFileHandle closeFile];
    appendFileHandle = nil;
}

- (void)appendRulesToCurrentBlockConfiguration:(NSArray<NSDictionary*>*)newEntryDicts {
    if (newEntryDicts.count < 1) return;
    if (isAllowlist) {
        NSLog(@"WARNING: Can't append rules to allowlist blocks - ignoring");
        return;
    }

    // open the file and prepare to write to the very bottom (no footer since it's not an allowlist)
    // NOTE FOR FUTURE: NSFileHandle can't append lines to the middle of the file anyway,
    // would need to read in the whole thing + write out again
    NSFileHandle* fileHandle = [NSFileHandle fileHandleForWritingAtPath: @"/etc/pf.anchors/org.eyebeam"];
    if (!fileHandle) {
        NSLog(@"ERROR: Failed to get handle for pf.anchors file while attempting to append rules");
        return;
    }

    [fileHandle seekToEndOfFile];
    for (NSDictionary* entryHostInfo in newEntryDicts) {
        NSString* hostName = entryHostInfo[@"hostName"];
        int portNum = [entryHostInfo[@"port"] intValue];
        int maskLen = [entryHostInfo[@"maskLen"] intValue];

        NSArray<NSString*>* ruleStrings = [self ruleStringsForIP: hostName port: portNum maskLen: maskLen];
        for (NSString* ruleString in ruleStrings) {
            [fileHandle writeData: [ruleString dataUsingEncoding:NSUTF8StringEncoding]];
        }
    }
    [fileHandle closeFile];
}

- (int)startBlock {
	[self addSelfControlConfig];
	[self writeConfiguration];

	NSArray* args = [@"-E -f /etc/pf.conf -F states" componentsSeparatedByString: @" "];

	NSTask* task = [[NSTask alloc] init];
	[task setLaunchPath: kPfctlExecutablePath];
	[task setArguments: args];

	NSPipe* inPipe = [[NSPipe alloc] init];
	NSFileHandle* readHandle = [inPipe fileHandleForReading];
	[task setStandardOutput: inPipe];
	[task setStandardError: inPipe];

	[task launch];
	NSString* pfctlOutput = [[NSString alloc] initWithData: [readHandle readDataToEndOfFile] encoding: NSUTF8StringEncoding];
	[readHandle closeFile];
	[task waitUntilExit];

	NSArray* lines = [pfctlOutput componentsSeparatedByString: @"\n"];
	for (NSString* line in lines) {
		if ([line hasPrefix: @"Token : "]) {
			[self writePFToken: [line substringFromIndex: [@"Token : " length]] error: nil];
			break;
		}
	}

	return [task terminationStatus];
}
// Runs pfctl with the given arguments, capturing combined stdout/stderr.
- (int)runPfctl:(NSArray<NSString*>*)args output:(NSString**)outOutput {
	NSTask* task = [[NSTask alloc] init];
	[task setLaunchPath: kPfctlExecutablePath];
	[task setArguments: args];
	NSPipe* inPipe = [[NSPipe alloc] init];
	NSFileHandle* readHandle = [inPipe fileHandleForReading];
	[task setStandardOutput: inPipe];
	[task setStandardError: inPipe];
	[task launch];
	NSString* output = [[NSString alloc] initWithData: [readHandle readDataToEndOfFile] encoding: NSUTF8StringEncoding];
	[readHandle closeFile];
	[task waitUntilExit];
	if (outOutput != NULL) *outOutput = output ?: @"";
	return [task terminationStatus];
}

// Writes the whole anchor and (re)loads pf. Fail-closed: pf is never disabled
// here, and any failure puts back exactly what was enforced before.
//  1. Parse-check the text (pfctl -n) before touching /etc at all.
//  2. Load it with a fresh enable reference (-E).
//  3. Only after a successful load is the previous enable reference released,
//     so there is never a moment with zero references (pf would turn off).
//  4. On failure the previous anchor (and pf.conf, if we added our lines in
//     this attempt) is restored and reloaded without -E; the old reference stays.
- (int)installAnchorText:(NSString*)anchorText {
	NSString* tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
	                     [NSString stringWithFormat: @"sc-anchor-%@.conf", NSUUID.UUID.UUIDString]];
	if (![anchorText writeToFile: tmpPath atomically: YES encoding: NSUTF8StringEncoding error: nil]) {
		NSLog(@"ERROR: Couldn't write SelfControl rules to a temp file for validation; leaving pf untouched.");
		return 1;
	}
	NSString* checkOutput = nil;
	int checkStatus = [self runPfctl: @[@"-n", @"-a", @"org.eyebeam", @"-f", tmpPath] output: &checkOutput];
	[[NSFileManager defaultManager] removeItemAtPath: tmpPath error: nil];
	if (checkStatus != 0) {
		NSLog(@"ERROR: pfctl rejected SelfControl rules; leaving pf untouched: %@", checkOutput);
		return checkStatus;
	}

	NSString* previousAnchor = [NSString stringWithContentsOfFile: kPFAnchorPath encoding: NSUTF8StringEncoding error: nil];
	NSString* oldToken = [[self readPFToken: nil] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
	BOOL confHadAnchor = [self containsSelfControlBlock];

	[self addSelfControlConfig];
	BOOL wroteAnchor = [anchorText writeToFile: kPFAnchorPath atomically: YES encoding: NSUTF8StringEncoding error: nil];
	NSString* pfctlOutput = @"";
	int status = wroteAnchor ? [self runPfctl: @[@"-E", @"-f", kPFConfPath, @"-F", @"states"] output: &pfctlOutput] : 1;
	NSString* newToken = nil;
	for (NSString* line in [pfctlOutput componentsSeparatedByString: @"\n"]) {
		if ([line hasPrefix: @"Token : "]) {
			newToken = [[line substringFromIndex: [@"Token : " length]] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
			break;
		}
	}

	if (status == 0) {
		if ([newToken length]) {
			[self writePFToken: newToken error: nil];
			if ([oldToken length] && ![oldToken isEqualToString: newToken]) {
				[self runPfctl: @[@"-X", oldToken] output: nil];
			}
		} else {
			// The rules are loaded; keep them (rolling back would relax enforcement)
			// and keep whatever reference we already hold.
			NSLog(@"WARNING: pfctl loaded SelfControl rules but printed no enable token: %@", pfctlOutput);
		}
		return 0;
	}

	NSLog(@"ERROR: pfctl failed to load SelfControl rules (status %d); restoring previous rules: %@", status, pfctlOutput);
	if (!wroteAnchor) NSLog(@"ERROR: Couldn't write %@", kPFAnchorPath);
	// A reference taken by this failed attempt would otherwise leak; the old one stays.
	if ([newToken length] && ![newToken isEqualToString: oldToken]) {
		[self runPfctl: @[@"-X", newToken] output: nil];
	}
	[(previousAnchor ?: @"") writeToFile: kPFAnchorPath atomically: YES encoding: NSUTF8StringEncoding error: nil];
	// Our pf.conf lines were added by this attempt: take them out again, so the
	// checkup sees no rules installed and retries the install.
	if (!confHadAnchor) [self removeSelfControlConfig];
	NSString* reloadOutput = nil;
	int reloadStatus = [self runPfctl: @[@"-f", kPFConfPath] output: &reloadOutput];
	if (reloadStatus != 0) NSLog(@"ERROR: pfctl failed to reload the previous rules (status %d): %@", reloadStatus, reloadOutput);
	return status;
}

- (int)refreshPFRules {
    NSArray* args = [@"-f /etc/pf.conf -F states" componentsSeparatedByString: @" "];

    NSTask* task = [[NSTask alloc] init];
    [task setLaunchPath: kPfctlExecutablePath];
    [task setArguments: args];
    [task launch];
    [task waitUntilExit];

    return [task terminationStatus];
}

- (void)writePFToken:(NSString*)token error:(NSError**)error {
	[token writeToFile: @"/etc/SelfControlPFToken" atomically: YES encoding: NSUTF8StringEncoding error: error];
}
- (NSString*)readPFToken:(NSError**)error {
	return [NSString stringWithContentsOfFile: @"/etc/SelfControlPFToken" encoding: NSUTF8StringEncoding error: error];
}

// Strips every org.eyebeam line from /etc/pf.conf (file only; no reload).
- (void)removeSelfControlConfig {
	NSString* mainConf = [NSString stringWithContentsOfFile: kPFConfPath encoding: NSUTF8StringEncoding error: nil];
	if (mainConf == nil) return;   // never replace an unreadable pf.conf with an empty one
	NSArray* lines = [mainConf componentsSeparatedByString: @"\n"];
	NSMutableString* newConf = [NSMutableString stringWithCapacity: [mainConf length]];
	for (NSString* line in lines) {
		if ([line rangeOfString: @"org.eyebeam"].location == NSNotFound) {
			[newConf appendFormat: @"%@\n", line];
		}
	}
	newConf = [[newConf stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]] mutableCopy];
	[newConf appendString: @"\n"];
	[newConf writeToFile: kPFConfPath atomically: true encoding: NSUTF8StringEncoding error: nil];
}

- (int)stopBlock:(BOOL)force {
	NSError* err;
	NSString* token = [[self readPFToken: &err] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];

	[@"" writeToFile: kPFAnchorPath atomically: true encoding: NSUTF8StringEncoding error: nil];
	[self removeSelfControlConfig];

	NSArray* args;
	if ([token length] && !force) {
		args = @[@"-X", token, @"-f", kPFConfPath];
	} else {
		args = @[@"-d", @"-f", kPFConfPath];
	}

	NSTask* task = [NSTask launchedTaskWithLaunchPath: kPfctlExecutablePath arguments: args];
	[task waitUntilExit];
	// The reference is released (or pf force-disabled): never release this token again.
	[[NSFileManager defaultManager] removeItemAtPath: @"/etc/SelfControlPFToken" error: nil];
	return [task terminationStatus];
}

- (void)addSelfControlConfig {
	NSMutableString* pfConf = [NSMutableString stringWithContentsOfFile: @"/etc/pf.conf" encoding: NSUTF8StringEncoding error: nil];

	if ([pfConf rangeOfString: @"/etc/pf.anchors/org.eyebeam"].location == NSNotFound) {
		[pfConf appendString: @"\n"
		 "anchor \"org.eyebeam\"\n"
		 "load anchor \"org.eyebeam\" from \"/etc/pf.anchors/org.eyebeam\"\n"];
	}

	[pfConf writeToFile: @"/etc/pf.conf" atomically: true encoding: NSUTF8StringEncoding error: nil];
}

- (BOOL)containsSelfControlBlock {
	NSString* mainConf = [NSString stringWithContentsOfFile: @"/etc/pf.conf" encoding: NSUTF8StringEncoding error: nil];
	return mainConf != nil && [mainConf rangeOfString: @"org.eyebeam"].location != NSNotFound;
}

@end
