#import <Foundation/Foundation.h>
#import "SCBlockEntry.h"
NS_ASSUME_NONNULL_BEGIN

/// Decides whether a blocklist entry covers one exact address or a whole site.
/// No Public Suffix List is vendored; a small built-in rule finds the registrable domain.
@interface SCDomainScope : NSObject

/// Lowercased hostname with trailing dots removed: its registrable domain.
/// Rule: if there are >= 3 labels, the last label is 2 letters, and the
/// second-to-last label is one of co com net org gov edu ac ne or go gob mil ltd plc sch
/// then the last 3 labels; otherwise the last 2. A hostname with < 2 labels returns itself.
+ (NSString*)registrableDomainForHostname:(NSString*)hostname;

/// YES when entry is a hostname - not `*`, not an IP/CIDR literal - with no port and no mask,
/// and has more labels than its registrable domain. nil -> NO.
+ (BOOL)isAddressOnlyBlockEntry:(nullable SCBlockEntry*)entry;

/// Parses with +[SCBlockEntry entryFromString:] then applies isAddressOnlyBlockEntry:.
/// nil/unparseable -> NO.
+ (BOOL)isAddressOnlyEntry:(nullable NSString*)entryString;

@end

NS_ASSUME_NONNULL_END
