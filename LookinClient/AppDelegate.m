//
//  AppDelegate.m
//  Lookin
//
//  Created by Li Kai on 2018/8/4.
//  https://lookin.work
//

#import "AppDelegate.h"
#import "LKNavigationManager.h"
#import "LKConnectionManager.h"
#import "LKPreferenceManager.h"
#import "LKAppMenuManager.h"
#import "LKLaunchWindowController.h"
#import "LookinDocument.h"
#import "NSString+Score.h"
#import "LookinDashboardBlueprint.h"
#import "LKPreferenceManager.h"
#import "Lookin-Swift.h"
@import AppCenter;
@import AppCenterAnalytics;
@import AppCenterCrashes;

@interface AppDelegate ()

@property(nonatomic, assign) BOOL launchedToOpenFile;

@end

@implementation AppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    [[LKAppMenuManager sharedInstance] setup];
    
    [RACObserve([LKPreferenceManager mainManager], appearanceType) subscribeNext:^(NSNumber *number) {
        LookinPreferredAppeanranceType type = [number integerValue];
        switch (type) {
            case LookinPreferredAppeanranceTypeDark:
                NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
                break;
            case LookinPreferredAppeanranceTypeLight:
                NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
                break;
            default:
                NSApp.appearance = nil;
                break;
        }
    }];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [LKConnectionManager sharedInstance];
    [[LKMCPServer shared] startIfEnabled];
    if (!self.launchedToOpenFile) {
        [[LKNavigationManager sharedInstance] showLaunch];
    }
    // 调试/展示用：带 -openMCPSettings 启动时直接弹出 MCP 设置窗口，
    // 并把窗口内容自渲染到 /tmp（浅色 + 深色），供 UI 验收，无需屏幕录制权限。
    // dataWithPDF 不含窗口背景，需手动合成到 backgroundColor 上，否则黑字落在透明底上不可见。
    if ([[NSProcessInfo processInfo].arguments containsObject:@"-openMCPSettings"]) {
        [[LKMCPSettingsWindowController shared] performSelectorOnMainThread:@selector(present)
                                                                  withObject:nil
                                                             waitUntilDone:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSWindow *win = [[LKMCPSettingsWindowController shared] window];
            [self _renderSettingsWindow:win toPNG:@"/tmp/mcp-settings-light.png"];
            win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self _renderSettingsWindow:win toPNG:@"/tmp/mcp-settings-dark.png"];
            });
        });
    }
    
    [self resolveAppCenterKey];
    
    NSString *key = [self resolveAppCenterKey];
    if (key) {
        [MSACAppCenter start:key withServices:@[
            [MSACAnalytics class],
            [MSACCrashes class]
        ]];
        MSACAppCenter.enabled = LKPreferenceManager.mainManager.enableReport;
    }
    else {
        MSACAppCenter.enabled = NO;
    }
    
#ifdef DEBUG
    [self _runTests];
#endif
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    // MCP server 开启时，关闭最后一个窗口不应退出 App，否则 Agent 会断连。
    // 此时用户可通过菜单栏的 “Quit Lookin” 退出。
    return ![LKPreferenceManager mainManager].mcpEnabled;
}

/// -openMCPSettings 调试钩子：把 contentView 渲染到带背景色的 PNG。
/// cacheDisplayInRect 输出不含窗口背景（黑字会落在透明底上），需先铺背景色；
/// 且不能用 dataWithPDF——其 PDF 输出会丢掉 NSButton。
- (void)_renderSettingsWindow:(NSWindow *)win toPNG:(NSString *)path {
    NSView *content = win.contentView;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                             initWithBitmapDataPlanes:NULL
                             pixelsWide:(NSInteger)content.bounds.size.width
                             pixelsHigh:(NSInteger)content.bounds.size.height
                             bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                             colorSpaceName:NSCalibratedRGBColorSpace
                             bytesPerRow:0 bitsPerPixel:0];
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];

    NSBitmapImageRep *composited = [[NSBitmapImageRep alloc]
                                    initWithBitmapDataPlanes:NULL
                                    pixelsWide:rep.pixelsWide pixelsHigh:rep.pixelsHigh
                                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                    colorSpaceName:NSCalibratedRGBColorSpace
                                    bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:composited];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    [win.backgroundColor setFill];
    NSRectFill(NSMakeRect(0, 0, composited.pixelsWide, composited.pixelsHigh));
    [rep drawInRect:NSMakeRect(0, 0, composited.pixelsWide, composited.pixelsHigh)];
    [NSGraphicsContext restoreGraphicsState];

    [[composited representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    // i18n / 布局诊断探针
    NSMutableString *probe = [NSMutableString stringWithFormat:@"appleLanguages=%@\nprefs=%@\nlookup=%@\n",
                              [NSUserDefaults.standardUserDefaults objectForKey:@"AppleLanguages"] ?: @"nil",
                              [NSBundle.mainBundle preferredLocalizations],
                              NSLocalizedString(@"Enable MCP server", @"")];
    NSMutableArray<NSString *> *frames = [NSMutableArray array];
    void (^dump)(NSView *, NSInteger) = ^(NSView *view, NSInteger depth) {
        [frames addObject:[NSString stringWithFormat:@"%*s%@ %@ %@\n", (int)(depth * 2), "",
                           NSStringFromClass(view.class), NSStringFromRect(view.frame),
                           view.isHidden ? @"hidden" : @""]];
    };
    // 递归块需要自身引用，先声明再赋值
    __block void (^walk)(NSView *, NSInteger) = nil;
    walk = ^(NSView *view, NSInteger depth) {
        dump(view, depth);
        for (NSView *sub in view.subviews) { walk(sub, depth + 1); }
    };
    walk(content, 0);
    [probe appendFormat:@"views:\n%@", [frames componentsJoinedByString:@""]];
    [probe writeToFile:@"/tmp/mcp-i18n-probe.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    self.launchedToOpenFile = YES;
    NSError *error;
    BOOL isSuccessful = [[LKNavigationManager sharedInstance] showReaderWithFilePath:filename error:&error];    
    return isSuccessful;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [[LKMCPServer shared] stopBeforeTermination];

    // 清理打开 UIImageView 的图片时创建的临时文件
    NSArray<NSString *> *tempImageFilesToDelete = [LKHelper sharedInstance].tempImageFiles;
    if (tempImageFilesToDelete.count == 0) {
        return NSTerminateNow;
    }
    [tempImageFilesToDelete enumerateObjectsUsingBlock:^(NSString * _Nonnull path, NSUInteger idx, BOOL * _Nonnull stop) {
        BOOL isSucc = [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (!isSucc) {
            NSAssert(NO, @"");
        }
    }];
    return NSTerminateNow;
}

#pragma mark - Test

- (NSString *)resolveAppCenterKey {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"hughkli.Lookin"]) {
        return @"fce2565c-518c-4851-be73-fa8317dd1590";
    }
    NSAssert(NO, @"");
    return nil;
}

/// 一些单元测试
- (void)_runTests {
    // 确保 LookinAttrGroupIdentifier 的 value 没有重复
    NSArray<LookinAttrGroupIdentifier> *allGroupIDs = [LookinDashboardBlueprint groupIDs];
    NSSet<LookinAttrGroupIdentifier> *allGroupIDs_unique = [NSSet setWithArray:allGroupIDs];
    if (allGroupIDs.count != allGroupIDs_unique.count) {
        NSAssert(NO, @"");
    }
    
    // 确保 LookinAttrSectionIdentifier 的 value 没有重复
    NSMutableArray<LookinAttrSectionIdentifier> *allSecIDs = [NSMutableArray array];
    [allGroupIDs enumerateObjectsUsingBlock:^(LookinAttrGroupIdentifier  _Nonnull groupID, NSUInteger idx, BOOL * _Nonnull stop) {
        NSArray<LookinAttrSectionIdentifier> *secIDs = [LookinDashboardBlueprint sectionIDsForGroupID:groupID];
        [allSecIDs addObjectsFromArray:secIDs];
    }];
    NSSet<LookinAttrSectionIdentifier> *allSecIDs_unique = [NSSet setWithArray:allSecIDs];
    if (allSecIDs.count != allSecIDs_unique.count) {
        NSAssert(NO, @"");
    }
    
    // 确保 LookinAttrIdentifier 的 value 没有重复
    NSMutableArray<LookinAttrIdentifier> *allAttrIDs = [NSMutableArray array];
    [allSecIDs enumerateObjectsUsingBlock:^(LookinAttrSectionIdentifier  _Nonnull secID, NSUInteger idx, BOOL * _Nonnull stop) {
        NSArray<LookinAttrIdentifier> *attrIDs = [LookinDashboardBlueprint attrIDsForSectionID:secID];
        [allAttrIDs addObjectsFromArray:attrIDs];
    }];
    NSSet<LookinAttrIdentifier> *allAttrIDs_unique = [NSSet setWithArray:allAttrIDs];
    if (allAttrIDs.count != allAttrIDs_unique.count) {
        NSAssert(NO, @"");
    }
}

@end
