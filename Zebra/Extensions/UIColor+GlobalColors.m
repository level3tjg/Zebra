//
//  UIColor+GlobalColors.m
//  Zebra
//
//  Created by Andrew Abosh on 2019-04-24.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import <ZBDevice.h>
#import "ZBThemeManager.h"
#import "UIColor+GlobalColors.h"

@implementation UIColor (GlobalColors)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"

+ (UIColor *)accentColor {
    return [ZBThemeManager getAccentColor:[ZBSettings accentColor]];
}

+ (UIColor *)badgeColor {
    return [UIColor colorWithRed:0.98 green:0.40 blue:0.51 alpha:1.0];
}

+ (UIColor *)blueCornflowerColor {
    return [UIColor colorWithRed:0.40 green:0.50 blue:0.98 alpha:1.0];
}

+ (UIColor *)tableViewBackgroundColor {
    if ([ZBThemeManager useCustomTheming]) {
        switch ([ZBSettings interfaceStyle]) {
            case ZBInterfaceStyleLight:
                return [UIColor whiteColor];
            case ZBInterfaceStyleDark:
            case ZBInterfaceStylePureBlack:
                return [UIColor blackColor];
        }
    }
    else {
        return [UIColor systemBackgroundColor];
    }
}

//TODO: Correct colors
+ (UIColor *)groupedTableViewBackgroundColor {
    if ([ZBThemeManager useCustomTheming]) {
        switch ([ZBSettings interfaceStyle]) {
            case ZBInterfaceStyleLight:
                return [UIColor redColor];
            case ZBInterfaceStyleDark:
            case ZBInterfaceStylePureBlack:
                return [UIColor redColor];
        }
    }
    else {
        return [UIColor systemGroupedBackgroundColor];
    }
}

+ (UIColor *)cellBackgroundColor {
    if ([ZBThemeManager useCustomTheming]) {
        switch ([ZBSettings interfaceStyle]) {
            case ZBInterfaceStyleLight:
                return [UIColor whiteColor];
            case ZBInterfaceStyleDark:
                return [UIColor colorWithRed:0.11 green:0.11 blue:0.114 alpha:1.0];
            case ZBInterfaceStylePureBlack:
                return [UIColor blackColor];
        }
    }
    else {
        return [UIColor systemBackgroundColor];
    }
}

+ (UIColor *)primaryTextColor {
    if ([ZBThemeManager useCustomTheming]) {
        switch ([ZBSettings interfaceStyle]) {
            case ZBInterfaceStyleLight:
                return [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0];
            case ZBInterfaceStyleDark:
            case ZBInterfaceStylePureBlack:
                return [UIColor whiteColor];
        }
    }
    else {
        return [UIColor labelColor];
    }
}

+ (UIColor *)secondaryTextColor {
    if ([ZBThemeManager useCustomTheming]) {
        switch ([ZBSettings interfaceStyle]) {
            case ZBInterfaceStyleLight:
                return [UIColor colorWithRed:0.43 green:0.43 blue:0.43 alpha:1.0];
            case ZBInterfaceStyleDark:
            case ZBInterfaceStylePureBlack:
                return [UIColor lightGrayColor];
        }
    }
    else {
        return [UIColor secondaryLabelColor];
    }
}

+ (UIColor *)cellSeparatorColor {
    if ([ZBThemeManager useCustomTheming]) {
        switch ([ZBSettings interfaceStyle]) {
            case ZBInterfaceStyleLight:
                return [UIColor colorWithRed:0.78 green:0.78 blue:0.78 alpha:1.0];
            case ZBInterfaceStyleDark:
                return [UIColor colorWithRed:0.22 green:0.22 blue:0.23 alpha:1.0];
            case ZBInterfaceStylePureBlack:
                return [UIColor blackColor];
        }
    }
    else {
        return [UIColor separatorColor];
    }
}

+ (UIColor *)imageBorderColor {
    switch ([ZBSettings interfaceStyle]) {
        case ZBInterfaceStyleLight:
            return [UIColor colorWithWhite:0.0 alpha:0.2];
        case ZBInterfaceStyleDark:
        case ZBInterfaceStylePureBlack:
            return [UIColor colorWithWhite:1.0 alpha:0.2];
    }
}

+ (NSString *)hexStringFromColor:(UIColor *)color {
    const CGFloat *components = CGColorGetComponents(color.CGColor);
    
    CGFloat r = components[0];
    CGFloat g = components[1];
    CGFloat b = components[2];
    
    return [NSString stringWithFormat:@"#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255)];
}

#pragma clang diagnostic pop

@end
