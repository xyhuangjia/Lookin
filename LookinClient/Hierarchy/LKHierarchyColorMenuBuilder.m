//
//  LKHierarchyColorMenuBuilder.m
//  LookinClient
//
//  Created by huangj on 2026/10/21.
//

#import "LKHierarchyColorMenuBuilder.h"
#import "LookinDefines.h"
#import "LKColorIndicatorLayer.h"

NSInteger const LKHierarchyColorMenuCustomColorItemTag = 10;
NSInteger const LKHierarchyColorMenuToggleColorFormatItemTag = 11;

@interface LKSelectColorItem : NSObject

+ (instancetype)itemWithTitle:(NSString *)title color:(LookinColor *)color;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) NSColor *color;

@end

@implementation LKSelectColorItem

+ (instancetype)itemWithTitle:(NSString *)title color:(LookinColor *)color {
    LKSelectColorItem *item = [LKSelectColorItem new];
    item.title = title;
    item.color = color;
    return item;
}

@end

@interface LKSelectColorItemsSection : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSArray<LKSelectColorItem *> *items;

@end

@implementation LKSelectColorItemsSection

- (void)setItems:(NSArray<LKSelectColorItem *> *)items {
    _items = [items sortedArrayUsingComparator:^NSComparisonResult(LKSelectColorItem * _Nonnull obj1, LKSelectColorItem * _Nonnull obj2) {
        return [obj1.title caseInsensitiveCompare:obj2.title];
    }].copy;
}

@end

@interface LKHierarchyColorMenuBuilder ()

@property(nonatomic, copy, readwrite) NSDictionary<NSString *, NSArray<NSString *> *> *colorToAliasMap;

@end

@implementation LKHierarchyColorMenuBuilder

- (NSMenu *)menuWithColorAlias:(NSDictionary *)colorAlias rgbaFormat:(BOOL)rgbaFormat {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *colorToAliasMap = [NSMutableDictionary dictionary];
    /// 成员可能是 LKSelectColorItem 和 LKSelectColorItemsSection 混杂在一起
    NSMutableArray *aliasColorItemsOrSections = [NSMutableArray array];

    /**
     colorAlias 可以有三种结构：
     1）key 是颜色别名，value 是 UIColor/NSColor。即 <NSString *, Color *>
     2）key 是一组颜色的标题，value 是 NSDictionary，而这个 NSDictionary 的 key 是颜色别名，value 是 UIColor / NSColor。即 <NSString *, NSDictionary<NSString *, Color *> *>
     3）以上两者混在一起
     */
    [colorAlias enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id _Nonnull colorOrDict, BOOL * _Nonnull stop) {
        if ([colorOrDict isKindOfClass:[NSColor class]]) {
            NSString *colorDesc = [((NSColor *)colorOrDict) rgbaString];
            if (colorDesc) {
                if (!colorToAliasMap[colorDesc]) {
                    colorToAliasMap[colorDesc] = [NSMutableArray array];
                }
                [colorToAliasMap[colorDesc] addObject:key];
            }

            [aliasColorItemsOrSections addObject:[LKSelectColorItem itemWithTitle:key color:(NSColor *)colorOrDict]];

        } else if ([colorOrDict isKindOfClass:[NSDictionary class]]) {
            LKSelectColorItemsSection *section = [LKSelectColorItemsSection new];
            section.title = key;
            NSMutableArray<LKSelectColorItem *> *aliasItems = [NSMutableArray array];

            [((NSDictionary *)colorOrDict) enumerateKeysAndObjectsUsingBlock:^(NSString *colorAliaName, NSColor *colorObj, BOOL * _Nonnull stop) {
                NSString *colorDesc = colorObj.rgbaString;
                if (colorDesc) {
                    if (!colorToAliasMap[colorDesc]) {
                        colorToAliasMap[colorDesc] = [NSMutableArray array];
                    }
                    [colorToAliasMap[colorDesc] addObject:colorAliaName];
                }

                [aliasItems addObject:[LKSelectColorItem itemWithTitle:colorAliaName color:colorObj]];
            }];

            if (aliasItems.count) {
                section.items = aliasItems;
                [aliasColorItemsOrSections addObject:section];
            }

        } else {
            NSAssert(NO, @"");
        }
    }];

    [aliasColorItemsOrSections sortUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
        if ([obj1 isKindOfClass:[LKSelectColorItem class]]) {
            if ([obj2 isKindOfClass:[LKSelectColorItem class]]) {
                return [((LKSelectColorItem *)obj1).title caseInsensitiveCompare:((LKSelectColorItem *)obj2).title];
            }
            if ([obj2 isKindOfClass:[LKSelectColorItemsSection class]]) {
                return NSOrderedAscending;
            }
        }
        if ([obj1 isKindOfClass:[LKSelectColorItemsSection class]]) {
            if ([obj2 isKindOfClass:[LKSelectColorItem class]]) {
                return NSOrderedDescending;
            }
            if ([obj2 isKindOfClass:[LKSelectColorItemsSection class]]) {
                return [((LKSelectColorItemsSection *)obj1).title caseInsensitiveCompare:((LKSelectColorItemsSection *)obj2).title];
            }
        }
        NSAssert(NO, @"");
        return NSOrderedAscending;
    }];

    self.colorToAliasMap = colorToAliasMap;
    return [self _menuWithAliasColorItemsOrSections:aliasColorItemsOrSections usingRGBAFormat:rgbaFormat];
}

#pragma mark - Menu Building

- (NSMenu *)_menuWithAliasColorItemsOrSections:(NSArray *)AliasColorItemsOrSections usingRGBAFormat:(BOOL)rgbaFormat {
    NSMutableArray *menuModel = [NSMutableArray array];

    [menuModel addObject:[LKSelectColorItem itemWithTitle:@"nil" color:nil]];
    [menuModel addObject:[LKSelectColorItem itemWithTitle:@"clear color" color:LookinColorRGBAMake(0, 0, 0, 0)]];

    NSArray<NSColor *> *defaultColors = @[LookinColorMake(0, 0, 0),
                                          LookinColorMake(126, 126, 126),
                                          LookinColorMake(255, 255, 255),
                                          LookinColorRGBAMake(0, 166, 248, .5),
                                          LookinColorMake(253, 62, 0),
                                          LookinColorMake(105, 190, 0),
                                          LookinColorMake(254, 182, 2)];
    NSArray<LKSelectColorItem *> *defaultColorItems = [defaultColors lookin_map:^id(NSUInteger idx, NSColor *value) {
        LKSelectColorItem *item = [LKSelectColorItem new];
        item.color = value;
        if (value) {
            item.title = rgbaFormat ? [value rgbaString]: [value hexString];
        } else {
            item.title = @"nil";
        }
        return item;
    }];
    [menuModel addObjectsFromArray:defaultColorItems];

    NSUInteger defaultItemsCount = menuModel.count;

    if (AliasColorItemsOrSections) {
        [menuModel addObjectsFromArray:AliasColorItemsOrSections];
    }

    NSMenu *menu = [NSMenu new];
    [menuModel enumerateObjectsUsingBlock:^(id itemOrSection, NSUInteger idx, BOOL * _Nonnull stop) {
        if (idx == defaultItemsCount) {
            [menu addItem:[NSMenuItem separatorItem]];
        }

        if ([itemOrSection isKindOfClass:[LKSelectColorItemsSection class]]) {
            LKSelectColorItemsSection *itemsSection = itemOrSection;

            NSMenuItem *menuItem = [NSMenuItem new];
            menuItem.image = [[NSImage alloc] initWithSize:NSMakeSize(1, 22)];
            [menu addItem:menuItem];
            menuItem.title = itemsSection.title;

            NSMenu *submenu = [NSMenu new];
            [itemsSection.items enumerateObjectsUsingBlock:^(LKSelectColorItem * _Nonnull subAliasItem, NSUInteger idx, BOOL * _Nonnull stop) {
                NSMenuItem *subMenuItem = [self _menuItemFromColorItem:subAliasItem];
                [submenu addItem:subMenuItem];
            }];
            menuItem.submenu = submenu;

        } else if ([itemOrSection isKindOfClass:[LKSelectColorItem class]]) {
            NSMenuItem *menuItem = [self _menuItemFromColorItem:itemOrSection];
            [menu addItem:menuItem];

        } else {
            NSAssert(NO, @"");
        }
    }];

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:({
        NSMenuItem *menuItem = [NSMenuItem new];
        menuItem.image = [[NSImage alloc] initWithSize:NSMakeSize(1, 22)];
        menuItem.title = NSLocalizedString(@"Other…", nil);
        menuItem.tag = LKHierarchyColorMenuCustomColorItemTag;
        menuItem;
    })];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:({
        NSMenuItem *menuItem = [NSMenuItem new];
        menuItem.image = [[NSImage alloc] initWithSize:NSMakeSize(1, 22)];
        if (rgbaFormat) {
            menuItem.title = NSLocalizedString(@"Switch color format to HEX", nil);
        } else {
            menuItem.title = NSLocalizedString(@"Switch color format to RGBA", nil);
        }
        menuItem.tag = LKHierarchyColorMenuToggleColorFormatItemTag;
        menuItem;
    })];

    return menu;
}

- (NSMenuItem *)_menuItemFromColorItem:(LKSelectColorItem *)item {
    NSImage *image = [LKColorIndicatorLayer imageWithColor:item.color shapeSize:NSMakeSize(20, 20) insets:NSEdgeInsetsMake(4, 5, 4, 6)];
    NSMenuItem *menuItem = [NSMenuItem new];
    menuItem.image = image;
    menuItem.title = item.title;
    menuItem.representedObject = item.color;
    return menuItem;
}

@end
