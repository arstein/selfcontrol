//
//  SCTediumWindowController.h
//  SelfControl
//
//  Fully programmatic panel (no xib) for the tedium override challenge.
//  See docs/superpowers/specs/2026-09-28-tedium-override-design.md.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCTediumWindowController : NSWindowController

// Starts (or resumes) the tedium override challenge with the daemon.
// On success, populates and shows the panel. On failure (e.g. no block is
// running, or the daemon is momentarily busy), presents an NSAlert instead
// and leaves the panel hidden.
- (void)beginChallenge;

@end

NS_ASSUME_NONNULL_END
