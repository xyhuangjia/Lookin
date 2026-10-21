//
//  LKHierarchyColorMenuBuilder.h
//  LookinClient
//
//  Created by huangj on 2026/10/21.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 取色菜单里「自定义颜色…」菜单项的 tag
extern NSInteger const LKHierarchyColorMenuCustomColorItemTag;
/// 取色菜单里「切换颜色格式（RGBA/HEX）」菜单项的 tag
extern NSInteger const LKHierarchyColorMenuToggleColorFormatItemTag;

/// 把 server 下发的 colorAlias（颜色别名表，挂在 LookinHierarchyInfo 上）解析并构建成
/// dashboard 取色菜单。与层级仓库无状态耦合：输入 colorAlias 与颜色格式，输出菜单与
/// 「rgba 字符串 → 别名数组」映射，供别名展示与菜单点击方使用。
@interface LKHierarchyColorMenuBuilder : NSObject

/// 解析 colorAlias 并生成取色菜单；同时更新 colorToAliasMap
///（colorAlias 结构可能是 别名→颜色、分组标题→(别名→颜色) 或两者混杂，见 LookinHierarchyInfo）
- (NSMenu *)menuWithColorAlias:(nullable NSDictionary *)colorAlias rgbaFormat:(BOOL)rgbaFormat;

/// rgba 字符串（如 @"(255, 255, 255, 1)"）→ 别名数组，由最近一次 -menuWithColorAlias:rgbaFormat: 更新
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSArray<NSString *> *> *colorToAliasMap;

@end

NS_ASSUME_NONNULL_END
