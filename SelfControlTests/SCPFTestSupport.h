#import <Foundation/Foundation.h>

// Parses pf rules with `pfctl -n` (parse only: never loads, needs no root).
// Returns pfctl's exit status; 0 means pf accepts the text. Writes pfctl's
// output to *outOutput when non-NULL.
static inline int SCPFParseStatus(NSString* rules, NSString** outOutput) {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"sc-pf-%@.conf", NSUUID.UUID.UUIDString]];
    [rules writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/pfctl";
    task.arguments = @[@"-n", @"-f", path];
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    [task launch];
    NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    if (outOutput != NULL) *outOutput = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return task.terminationStatus;
}
