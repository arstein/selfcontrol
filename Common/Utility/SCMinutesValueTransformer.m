//
//  SCMinutesValueTransformer.m
//  SelfControl
//

#import "SCMinutesValueTransformer.h"

NSString* const SCMinutesValueTransformerName = @"BlockDurationSliderTransformer";

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
