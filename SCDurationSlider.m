//
//  SCTimeSlider.m
//  SelfControl
//
//  Created by Charlie Stigler on 4/17/21.
//

#import "SCDurationSlider.h"
#import "SCTimeIntervalFormatter.h"

#define kValueTransformerName @"BlockDurationSliderTransformer"

// Rounds a slider's float value to whole minutes.
// (Replaces the TransformerKit block-based transformer.)
//
// This MUST allow reverse transformation. The slider's `value` is bound
// read-write with NSContinuouslyUpdatesValueBindingOption, so every drag step
// writes the slider's value back to the model, which requires reverse
// transformation. A forward-only transformer makes NSValueTransformer raise on
// that write-back; the exception unwinds through NSSlider's mouse-tracking loop
// and corrupts AppKit's event-tracking state, freezing all mouse input (keyboard
// still works). Both directions just round to whole minutes: the model holds
// integer minutes and the slider holds a float position.
@interface SCMinutesValueTransformer : NSValueTransformer
@end

@implementation SCMinutesValueTransformer

+ (Class)transformedValueClass {
    return [NSNumber class];
}

+ (BOOL)allowsReverseTransformation {
    return YES;
}

- (id)transformedValue:(id)value {
    // if it's not a number or convertable to one, IDK man
    if (![value respondsToSelector: @selector(floatValue)]) return @0;

    return @(lroundf([value floatValue]));
}

- (id)reverseTransformedValue:(id)value {
    if (![value respondsToSelector: @selector(floatValue)]) return @0;

    return @(lroundf([value floatValue]));
}

@end

@implementation SCDurationSlider

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    // Drawing code here.
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super initWithCoder: coder]) {
        [self initializeDurationProperties];
    }
    return self;
}
- (instancetype)init {
    if (self = [super init]) {
        [self initializeDurationProperties];
    }
    return self;
}

- (void)initializeDurationProperties {
    // default: 1 day max
    _maxDuration = 1440;

    // register an NSValueTransformer
    [self registerMinutesValueTransformer];
}

- (void)setMaxDuration:(NSInteger)maxDuration {
    _maxDuration = maxDuration;
    [self setMinValue: 1]; // never start a block shorter than 1 minute
    [self setMaxValue: self.maxDuration];
}

- (void)registerMinutesValueTransformer {
    [NSValueTransformer setValueTransformer: [SCMinutesValueTransformer new]
                                    forName: kValueTransformerName];
}

- (NSInteger)durationValueMinutes {
    return lroundf(self.floatValue);
}

- (void)bindDurationToObject:(id)obj keyPath:(NSString*)keyPath {
    [self bind: @"value"
      toObject: obj
   withKeyPath: keyPath
       options: @{
                  NSContinuouslyUpdatesValueBindingOption: @YES,
                  NSValueTransformerNameBindingOption: kValueTransformerName
                  }];
}

- (NSString*)durationDescription {
    return [SCDurationSlider timeSliderDisplayStringFromNumberOfMinutes: self.durationValueMinutes];
}

// String conversion utility methods

+ (NSString *)timeSliderDisplayStringFromTimeInterval:(NSTimeInterval)numberOfSeconds {
    static SCTimeIntervalFormatter* formatter = nil;
    if (formatter == nil) {
        formatter = [[SCTimeIntervalFormatter alloc] init];
    }

    NSString* formatted = [formatter stringForObjectValue:@(numberOfSeconds)];
    return formatted;
}

+ (NSString *)timeSliderDisplayStringFromNumberOfMinutes:(NSInteger)numberOfMinutes {
    if (numberOfMinutes < 0) return @"Invalid duration";

    static NSCalendar* gregorian = nil;
    if (gregorian == nil) {
        gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    }

    NSRange secondsRangePerMinute = [gregorian
                                     rangeOfUnit:NSCalendarUnitSecond
                                     inUnit:NSCalendarUnitMinute
                                     forDate:[NSDate date]];
    NSInteger numberOfSecondsPerMinute = (NSInteger)NSMaxRange(secondsRangePerMinute);

    NSTimeInterval numberOfSecondsSelected = (NSTimeInterval)(numberOfSecondsPerMinute * numberOfMinutes);

    NSString* displayString = [SCDurationSlider timeSliderDisplayStringFromTimeInterval:numberOfSecondsSelected];
    return displayString;
}


@end
