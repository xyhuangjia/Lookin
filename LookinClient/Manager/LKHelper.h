//
//  LKHelper.h
//  Lookin
//
//  Created by Li Kai on 2018/8/4.
//  https://lookin.work
//

#import <Cocoa/Cocoa.h>
#import "LookinDefines.h"

#define InspectingApp [LKAppsManager sharedInstance].inspectingApp
#define TutorialMng [LKTutorialManager sharedInstance]
#define CurrentTime [[NSDate date] timeIntervalSince1970]
#define CurrentKeyWindow [NSApplication sharedApplication].keyWindow

#define NSImageMake(imageName) [NSImage imageNamed:imageName]
#define NSFontMake(fontSize) [NSFont systemFontOfSize:fontSize]

#define DashboardCardValueColor LookinColorMake(223, 223, 223)
#define DashboardCardControlBackgroundColor LookinColorMake(40, 40, 40)
#define DashboardCardControlBorderColor LookinColorMake(87, 87, 87)

#define SeparatorLightModeColor LookinColorMake(215, 215, 215)
#define SeparatorDarkModeColor LookinColorMake(67, 67, 69)

#define NSSizeMax NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)

#define NSColorBlack LookinColorMake(13, 20, 30)
#define NSColorWhite LookinColorMake(250, 251, 252)
#define NSColorGray0 LookinColorMake(33, 40, 50)
#define NSColorGray1 LookinColorMake(53, 60, 70)
#define NSColorGray9 LookinColorMake(216, 220, 228)

extern const CGFloat HierarchyMinWidth;

extern const CGFloat MeasureViewWidth;

extern const CGFloat DashboardViewWidth;
extern const CGFloat DashboardAttrItemHorInterspace;
extern const CGFloat DashboardAttrItemVerInterspace;
extern const CGFloat DashboardHorInset;
extern const CGFloat DashboardCardControlCornerRadius;
extern const CGFloat DashboardSectionMarginTop;
extern const CGFloat DashboardCardCornerRadius;
extern const CGFloat DashboardSearchCardInset;

extern const CGFloat ConsoleInsetLeft;
extern const CGFloat ConsoleInsetRight;

extern const CGFloat ZoomSliderMaxValue;

typedef struct {
    CGFloat left, right;
} HorizontalMargins;

CG_INLINE HorizontalMargins HorizontalMarginsMake(CGFloat left, CGFloat right) {
    HorizontalMargins margins = {left, right};
    return margins;
}

#define AlertError(targetError, targetWindow) if (targetError.code != LookinErrCode_Discard) {[[NSAlert alertWithError:targetError] beginSheetModalForWindow:targetWindow completionHandler:nil];}

#define AlertErrorText(errorTitle, errorDetail, targetWindow) AlertError(LookinErrorMake(errorTitle, errorDetail), targetWindow)

#define IsEnglish [LKHelper isEnglish]

@interface LKHelper : NSObject

+ (instancetype)sharedInstance;

+ (NSFont *)italicFontOfSize:(CGFloat)fontSize;

+ (NSString *)lookinReadableVersion;

+ (void)openLookinWebsiteWithPath:(NSString *)path;

+ (void)openLookinOfficialWebsite;

+ (void)openCustomConfigWebsite;

+ (BOOL)isEnglish;

/// macOS 10.14 及以后返回用户的系统主题色，旧版本系统返回蓝色
+ (NSColor *)accentColor;

+ (NSArray<NSString *> *)bestMatchesInCandidates:(NSArray<NSString *> *)candidates input:(NSString *)input maxResultsCount:(NSUInteger)maxResultsCount;

/// 使用 UIImageView 的 “使用预览打开该图片” 功能时会创建临时图片文件，它们的路径会保存在这里，Lookin 退出时应当删除这些临时文件
/// 创建图片的相关逻辑见 LKDashboardAttributeOpenImageView.m
@property(nonatomic, strong) NSMutableArray<NSString *> *tempImageFiles;

/// macOS 10.14 及之后返回系统的 [NSTextView scrollableTextView]。10.13 由该方法自己实现。
/// 当使用自己实现的版本时（即 10.13 系统），需要业务自己负责 textView（即  scrollableTextView.documentVie）的布局
+ (NSScrollView *)scrollableTextView;

+ (BOOL)validateFrame:(CGRect)frame;

/// 解码 Lookin 协议消息及 .lookin 文档时允许的类集合。
/// 这里不能包含 [NSObject class]：NSSecureCoding 的白名单含 NSObject 等于放行任意类，
/// 系统会打印 validateAllowedClass: 安全警告，并声明未来会升级为错误。
/// 由于大多数 Lookin 模型的 initWithCoder: 使用 decodeObjectForKey:，
/// 归档中的全部嵌套类型都必须显式列在这里，否则会被解码成 nil。
+ (NSSet<Class> *)lookinAllowedUnarchiveClasses;

/// 使用上述白名单解码一个 Lookin KeyedArchive
+ (id)lookinUnarchivedObjectFromData:(NSData *)data error:(NSError **)error;

@end
