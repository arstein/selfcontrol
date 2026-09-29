//
//  SCMinutesValueTransformer.h
//  SelfControl
//
//  Rounds a value to whole minutes, in both directions. Used by the block
//  duration slider, whose `value` binding is read-write with continuous
//  updates: the forward path maps the model's integer minutes to the slider's
//  float position, and the reverse path (every drag step) maps the slider's
//  float position back to whole minutes for the model.
//
//  This MUST allow reverse transformation. A forward-only transformer makes
//  NSValueTransformer raise on the write-back; the exception unwinds through
//  NSSlider's mouse-tracking loop and corrupts AppKit's event-tracking state,
//  freezing all mouse input for the window (keyboard still works).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const SCMinutesValueTransformerName;

@interface SCMinutesValueTransformer : NSValueTransformer
@end

NS_ASSUME_NONNULL_END
