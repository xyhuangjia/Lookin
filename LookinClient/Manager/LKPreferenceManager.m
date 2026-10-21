//
//  LKPreferenceManager.m
//  Lookin
//
//  Created by Li Kai on 2019/1/8.
//  https://lookin.work
//

#import "LKPreferenceManager.h"
#import "LookinDashboardBlueprint.h"
#import "LKPreviewView.h"
#import "LKTutorialManager.h"
@import AppCenter;
@import AppCenterAnalytics;

NSString *const NotificationName_DidChangeSectionShowing = @"NotificationName_DidChangeSectionShowing";
NSString *const LKMCPSettingsDidChangeNotification = @"LKMCPSettingsDidChangeNotification";

NSString *const LKWindowSizeName_Dynamic = @"LKWindowSizeName_Dynamic";
NSString *const LKWindowSizeName_Static = @"LKWindowSizeName_Static";

const CGFloat LKInitialPreviewScale = 0.27;

static NSString * const Key_PreviousClientVersion = @"preVer";
static NSString * const Key_ShowOutline = @"showOutline";
static NSString * const Key_ShowHiddenItems = @"showHiddenItems";
static NSString * const Key_EnableReport = @"enableReport";
static NSString * const Key_RgbaFormat = @"egbaFormat";
static NSString * const Key_ZInterspace = @"zInterspace_v095";
static NSString * const Key_AppearanceType = @"appearanceType";
static NSString * const Key_DoubleClickBehavior = @"doubleClickBehavior";
static NSString * const Key_ExpansionIndex = @"expansionIndex";
static NSString * const Key_ContrastLevel = @"contrastLevel";
static NSString * const Key_SectionsShow = @"ss";
static NSString * const Key_CollapsedGroups = @"collapsedGroups_918";
static NSString * const Key_PreferredExportCompression = @"preferredExportCompression";
static NSString * const Key_CallStackType = @"callStackType";
static NSString * const Key_SyncConsoleTarget = @"syncConsoleTarget";
static NSString * const Key_FreeRotation = @"FreeRotation";
static NSString * const Key_FastMode = @"fastMode";
static NSString * const Key_ReceivingConfigTime_Color = @"ConfigTime_Color";
static NSString * const Key_ReceivingConfigTime_Class = @"ConfigTime_Class";
static NSString * const Key_MCPEnabled = @"mcpEnabled";
static NSString * const Key_MCPPort = @"mcpPort";
static NSString * const Key_MCPAllowWrites = @"mcpAllowWrites";
static NSString * const Key_MCPAllowInvoke = @"mcpAllowInvoke";
static NSString * const Key_MCPInvokeAllowlist = @"mcpInvokeAllowlist";

static const NSUInteger LKMCPDefaultPort = 47200;

@interface LKPreferenceManager ()

@property(nonatomic, strong) NSMutableDictionary<LookinAttrSectionIdentifier, NSNumber *> *storedSectionShowConfig;

@end

@implementation LKPreferenceManager

+ (instancetype)mainManager {
    static dispatch_once_t onceToken;
    static LKPreferenceManager *instance = nil;
    dispatch_once(&onceToken,^{
        instance = [[super allocWithZone:NULL] init];
        instance.shouldStoreToLocal = YES;
    });
    return instance;
}

#pragma mark - Persistence Seam

/// 持久化 seam 的缺省策略：键缺失时把默认值写入 UserDefaults，
/// 「首次读取即落盘默认值」这一行为只在此处定义
- (id)_objectForKey:(NSString *)key defaultProvider:(id _Nonnull (^)(void))provider {
    id object = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (object != nil) {
        return object;
    }
    id defaultValue = provider();
    [[NSUserDefaults standardUserDefaults] setObject:defaultValue forKey:key];
    return defaultValue;
}

/// 持久化 seam 的写入策略：shouldStoreToLocal 关闭时只改内存不落盘
- (void)_persistObject:(id)object forKey:(NSString *)key {
    if (self.shouldStoreToLocal) {
        [[NSUserDefaults standardUserDefaults] setObject:object forKey:key];
    }
}

- (instancetype)init {
    if (self = [super init]) {
        // 以下属性不持久化，每次启动重置
        _previewScale = [LookinDoubleMsgAttribute attributeWithDouble:LKInitialPreviewScale];
        _previewDimension = [LookinIntegerMsgAttribute attributeWithInteger:LookinPreviewDimension3D];
        _measureState = [LookinIntegerMsgAttribute attributeWithInteger:LookinMeasureState_no];
        _isQuickSelecting = [LookinBOOLMsgAttribute attributeWithBOOL:NO];

        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

        // 记录本次客户端 version（目前仅用于观察）
        NSInteger prevClientVersion = [userDefaults integerForKey:Key_PreviousClientVersion];
        if (prevClientVersion != LOOKIN_CLIENT_VERSION) {
            [userDefaults setInteger:LOOKIN_CLIENT_VERSION forKey:Key_PreviousClientVersion];
        }

        _showOutline = [LookinBOOLMsgAttribute attributeWithBOOL:[self _boolForKey:Key_ShowOutline defaultValue:YES]];
        [self.showOutline subscribe:self action:@selector(_handleShowOutlineDidChange:) relatedObject:nil];

        _showHiddenItems = [LookinBOOLMsgAttribute attributeWithBOOL:[self _boolForKey:Key_ShowHiddenItems defaultValue:NO]];
        [self.showHiddenItems subscribe:self action:@selector(_handleShowHiddenItemsChange:) relatedObject:nil];

        _enableReport = [self _boolForKey:Key_EnableReport defaultValue:YES];

        _doubleClickBehavior = [self _integerForKey:Key_DoubleClickBehavior defaultValue:LookinDoubleClickBehaviorCollapse];

        _rgbaFormat = [self _boolForKey:Key_RgbaFormat defaultValue:YES];

        // 默认值为 0.22
        double zInterspaceValue = [self _doubleForKey:Key_ZInterspace defaultValue:.22];
        zInterspaceValue = MAX(MIN(zInterspaceValue, LookinPreviewMaxZInterspace), LookinPreviewMinZInterspace);
        _zInterspace = [LookinDoubleMsgAttribute attributeWithDouble:zInterspaceValue];
        [self.zInterspace subscribe:self action:@selector(_handleZInterspaceDidChange:) relatedObject:nil];

        _appearanceType = [self _integerForKey:Key_AppearanceType defaultValue:LookinPreferredAppeanranceTypeSystem];

        _expansionIndex = [self _integerForKey:Key_ExpansionIndex defaultValue:3];

        _imageContrastLevel = [self _integerForKey:Key_ContrastLevel defaultValue:0];

        _syncConsoleTarget = [self _boolForKey:Key_SyncConsoleTarget defaultValue:YES];

        _freeRotation = [LookinBOOLMsgAttribute attributeWithBOOL:[self _boolForKey:Key_FreeRotation defaultValue:YES]];
        [self.freeRotation subscribe:self action:@selector(_handleFreeRotationDidChange:) relatedObject:nil];

        _fastMode = [LookinBOOLMsgAttribute attributeWithBOOL:[self _boolForKey:Key_FastMode defaultValue:NO]];
        [self.fastMode subscribe:self action:@selector(_handleFastModeDidChange:) relatedObject:nil];

        self.storedSectionShowConfig = [[userDefaults objectForKey:Key_SectionsShow] mutableCopy] ?: [NSMutableDictionary dictionary];

        _collapsedAttrGroups = [userDefaults objectForKey:Key_CollapsedGroups] ?: @[LookinAttrGroup_Class];

        // 默认值需要在 LKExportAccessory.m 里定义的选项里面
        _preferredExportCompression = [self _doubleForKey:Key_PreferredExportCompression defaultValue:.5];

        _receivingConfigTime_Color = [userDefaults doubleForKey:Key_ReceivingConfigTime_Color];
        _receivingConfigTime_Class = [userDefaults doubleForKey:Key_ReceivingConfigTime_Class];

        // MCP 各项缺失时不写默认值，与 setter 里的缺省回退保持一致
        _mcpEnabled = [userDefaults boolForKey:Key_MCPEnabled];

        _mcpPort = (NSUInteger)[userDefaults integerForKey:Key_MCPPort];
        if (_mcpPort < 1024 || _mcpPort > 65535) {
            _mcpPort = LKMCPDefaultPort;
        }

        _mcpAllowWrites = [userDefaults boolForKey:Key_MCPAllowWrites];
        _mcpAllowInvoke = [userDefaults boolForKey:Key_MCPAllowInvoke];
        _mcpInvokeAllowlistText = [userDefaults objectForKey:Key_MCPInvokeAllowlist] ?: @"";
    }
    return self;
}

- (BOOL)_boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    return [[self _objectForKey:key defaultProvider:^id _Nonnull {
        return @(defaultValue);
    }] boolValue];
}

- (NSInteger)_integerForKey:(NSString *)key defaultValue:(NSInteger)defaultValue {
    return [[self _objectForKey:key defaultProvider:^id _Nonnull {
        return @(defaultValue);
    }] integerValue];
}

- (double)_doubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    return [[self _objectForKey:key defaultProvider:^id _Nonnull {
        return @(defaultValue);
    }] doubleValue];
}

#pragma mark - MCP

- (void)setMcpEnabled:(BOOL)mcpEnabled {
    if (_mcpEnabled == mcpEnabled) {
        return;
    }
    _mcpEnabled = mcpEnabled;
    [self _persistObject:@(mcpEnabled) forKey:Key_MCPEnabled];
    [[NSNotificationCenter defaultCenter] postNotificationName:LKMCPSettingsDidChangeNotification object:self];
}

- (void)setMcpPort:(NSUInteger)mcpPort {
    if (mcpPort < 1024 || mcpPort > 65535) {
        mcpPort = LKMCPDefaultPort;
    }
    if (_mcpPort == mcpPort) {
        return;
    }
    _mcpPort = mcpPort;
    [self _persistObject:@(mcpPort) forKey:Key_MCPPort];
    [[NSNotificationCenter defaultCenter] postNotificationName:LKMCPSettingsDidChangeNotification object:self];
}

- (void)setMcpAllowWrites:(BOOL)mcpAllowWrites {
    if (_mcpAllowWrites == mcpAllowWrites) {
        return;
    }
    _mcpAllowWrites = mcpAllowWrites;
    [self _persistObject:@(mcpAllowWrites) forKey:Key_MCPAllowWrites];
    [[NSNotificationCenter defaultCenter] postNotificationName:LKMCPSettingsDidChangeNotification object:self];
}

- (void)setMcpAllowInvoke:(BOOL)mcpAllowInvoke {
    if (_mcpAllowInvoke == mcpAllowInvoke) {
        return;
    }
    _mcpAllowInvoke = mcpAllowInvoke;
    [self _persistObject:@(mcpAllowInvoke) forKey:Key_MCPAllowInvoke];
    [[NSNotificationCenter defaultCenter] postNotificationName:LKMCPSettingsDidChangeNotification object:self];
}

- (void)setMcpInvokeAllowlistText:(NSString *)mcpInvokeAllowlistText {
    _mcpInvokeAllowlistText = [mcpInvokeAllowlistText copy] ?: @"";
    [self _persistObject:_mcpInvokeAllowlistText forKey:Key_MCPInvokeAllowlist];
    [[NSNotificationCenter defaultCenter] postNotificationName:LKMCPSettingsDidChangeNotification object:self];
}

- (NSSet<NSString *> *)mcpInvokeAllowlist {
    NSMutableSet<NSString *> *result = [NSMutableSet set];
    NSArray<NSString *> *lines = [self.mcpInvokeAllowlistText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) {
            [result addObject:trimmed];
        }
    }
    return result.copy;
}

- (void)_handleShowOutlineDidChange:(LookinMsgActionParams *)param {
    [self _persistObject:@(param.boolValue) forKey:Key_ShowOutline];
}

- (void)_handleShowHiddenItemsChange:(LookinMsgActionParams *)param {
    [self _persistObject:@(param.boolValue) forKey:Key_ShowHiddenItems];
}

- (void)setEnableReport:(BOOL)enableReport {
    if (_enableReport == enableReport) {
        return;
    }
    _enableReport = enableReport;
    [self _persistObject:@(enableReport) forKey:Key_EnableReport];

    MSACAppCenter.enabled = enableReport;
}

- (void)setRgbaFormat:(BOOL)rgbaFormat {
    if (_rgbaFormat == rgbaFormat) {
        return;
    }
    _rgbaFormat = rgbaFormat;
    [self _persistObject:@(rgbaFormat) forKey:Key_RgbaFormat];
}

- (void)setDoubleClickBehavior:(LookinDoubleClickBehavior)doubleClickBehavior {
    _doubleClickBehavior = doubleClickBehavior;
    [self _persistObject:@(doubleClickBehavior) forKey:Key_DoubleClickBehavior];
}

- (void)setAppearanceType:(LookinPreferredAppeanranceType)appearanceType {
    if (_appearanceType == appearanceType) {
        return;
    }
    _appearanceType = appearanceType;
    [self _persistObject:@(appearanceType) forKey:Key_AppearanceType];
}

- (void)setExpansionIndex:(NSInteger)expansionIndex {
    if (_expansionIndex == expansionIndex) {
        return;
    }
    _expansionIndex = expansionIndex;
    [self _persistObject:@(expansionIndex) forKey:Key_ExpansionIndex];
}

- (void)setImageContrastLevel:(NSInteger)imageContrastLevel {
    if (_imageContrastLevel == imageContrastLevel) {
        return;
    }
    _imageContrastLevel = imageContrastLevel;
    [self _persistObject:@(imageContrastLevel) forKey:Key_ContrastLevel];
}

- (void)setCollapsedAttrGroups:(NSArray<NSNumber *> *)collapsedAttrGroups {
    _collapsedAttrGroups = collapsedAttrGroups.copy;
    [self _persistObject:collapsedAttrGroups forKey:Key_CollapsedGroups];
}

- (void)setPreferredExportCompression:(CGFloat)preferredExportCompression {
    if (_preferredExportCompression == preferredExportCompression) {
        return;
    }
    _preferredExportCompression = preferredExportCompression;
    [self _persistObject:@(preferredExportCompression) forKey:Key_PreferredExportCompression];
}

- (void)setCallStackType:(LookinPreferredCallStackType)callStackType {
    if (callStackType < 0 || callStackType > 2) {
        NSAssert(NO, @"");
        callStackType = 0;
    }
    _callStackType = callStackType;
}

- (void)setSyncConsoleTarget:(BOOL)syncConsoleTarget {
    if (_syncConsoleTarget == syncConsoleTarget) {
        return;
    }
    _syncConsoleTarget = syncConsoleTarget;
    [self _persistObject:@(syncConsoleTarget) forKey:Key_SyncConsoleTarget];
}

- (void)setReceivingConfigTime_Class:(NSTimeInterval)receivingConfigTime_Class {
    _receivingConfigTime_Class = receivingConfigTime_Class;
    [[NSUserDefaults standardUserDefaults] setDouble:receivingConfigTime_Class forKey:Key_ReceivingConfigTime_Class];
}

- (void)setReceivingConfigTime_Color:(NSTimeInterval)receivingConfigTime_Color {
    _receivingConfigTime_Color = receivingConfigTime_Color;
    [[NSUserDefaults standardUserDefaults] setDouble:receivingConfigTime_Color forKey:Key_ReceivingConfigTime_Color];
}

- (void)_handleFreeRotationDidChange:(LookinMsgActionParams *)param {
    [self _persistObject:@(param.boolValue) forKey:Key_FreeRotation];
}

- (void)_handleFastModeDidChange:(LookinMsgActionParams *)param {
    [self _persistObject:@(param.boolValue) forKey:Key_FastMode];
}


- (void)_handleZInterspaceDidChange:(LookinMsgActionParams *)param {
    [self _persistObject:@(param.doubleValue) forKey:Key_ZInterspace];
}

/// 返回某个 section 是否应该被显示在主界面上
- (BOOL)isSectionShowing:(LookinAttrSectionIdentifier)secID {
    if (self.storedSectionShowConfig[secID] != nil) {
        return [self.storedSectionShowConfig[secID] boolValue];
    }
    NSSet<LookinAttrSectionIdentifier> *showingSecIDs = [self _showingSecIDsInDefault];
    if ([showingSecIDs containsObject:secID]) {
        return YES;
    } else {
        return NO;
    }
}

/// 把某个 section 显示在主界面上
- (void)showSection:(LookinAttrSectionIdentifier)secID {
    if ([self isSectionShowing:secID]) {
        NSAssert(NO, @"");
        return;
    }
    self.storedSectionShowConfig[secID] = @(YES);
    [[NSNotificationCenter defaultCenter] postNotificationName:NotificationName_DidChangeSectionShowing object:nil];
    [[NSUserDefaults standardUserDefaults] setObject:self.storedSectionShowConfig.copy forKey:Key_SectionsShow];
}

/// 把某个 section 从主界面上移除
- (void)hideSection:(LookinAttrSectionIdentifier)secID {
    if (![self isSectionShowing:secID]) {
        NSAssert(NO, @"");
        return;
    }
    self.storedSectionShowConfig[secID] = @(NO);
    [[NSNotificationCenter defaultCenter] postNotificationName:NotificationName_DidChangeSectionShowing object:nil];
    [[NSUserDefaults standardUserDefaults] setObject:self.storedSectionShowConfig.copy forKey:Key_SectionsShow];
}

/// 返回默认情况下，哪些 section 应该被显示在主界面上
- (NSSet<LookinAttrSectionIdentifier> *)_showingSecIDsInDefault {
    static dispatch_once_t onceToken;
    static NSSet *targetSet = nil;
    dispatch_once(&onceToken,^{
        NSArray<LookinAttrSectionIdentifier> *array = @[LookinAttrSec_Class_Class,
                                                        
                                                        LookinAttrSec_Relation_Relation,
                                                        
                                                        LookinAttrSec_Layout_Frame,
                                                        LookinAttrSec_Layout_Bounds,
                                                        
                                                        LookinAttrSec_AutoLayout_Hugging,
                                                        LookinAttrSec_AutoLayout_Resistance,
                                                        LookinAttrSec_AutoLayout_Constraints,
                                                        LookinAttrSec_AutoLayout_IntrinsicSize,
                                                        
                                                        LookinAttrSec_ViewLayer_Visibility,
                                                        LookinAttrSec_ViewLayer_InterationAndMasks,
                                                        LookinAttrSec_ViewLayer_Corner,
                                                        LookinAttrSec_ViewLayer_BgColor,
                                                        LookinAttrSec_ViewLayer_Border,
                                                        LookinAttrSec_ViewLayer_Shadow,
                                                        
                                                        LookinAttrSec_UIStackView_Axis,
                                                        LookinAttrSec_UIStackView_Alignment,
                                                        LookinAttrSec_UIStackView_Distribution,
                                                        LookinAttrSec_UIStackView_Spacing,
                                                        
                                                        LookinAttrSec_UIVisualEffectView_Style,
                                                        LookinAttrSec_UIVisualEffectView_QMUIForegroundColor,
                                                        
                                                        LookinAttrSec_UIImageView_Name,
                                                        LookinAttrSec_UIImageView_Open,
                                                        
                                                        LookinAttrSec_UILabel_Text,
                                                        LookinAttrSec_UILabel_Font,
                                                        LookinAttrSec_UILabel_NumberOfLines,
                                                        LookinAttrSec_UILabel_TextColor,
                                                        LookinAttrSec_UILabel_BreakMode,
                                                        LookinAttrSec_UILabel_Alignment,
                                                        
                                                        LookinAttrSec_UIControl_EnabledSelected,
                                                        LookinAttrSec_UIControl_QMUIOutsideEdge,
                                                        
                                                        LookinAttrSec_UIButton_ContentInsets,
                                                        
                                                        LookinAttrSec_UIScrollView_ContentInset,
                                                        LookinAttrSec_UIScrollView_AdjustedInset,
                                                        LookinAttrSec_UIScrollView_IndicatorInset,
                                                        LookinAttrSec_UIScrollView_Offset,
                                                        LookinAttrSec_UIScrollView_ContentSize,
                                                        LookinAttrSec_UIScrollView_Behavior,
                                                        
                                                        LookinAttrSec_UITableView_Style,
                                                        LookinAttrSec_UITableView_SectionsNumber,
                                                        LookinAttrSec_UITableView_RowsNumber,
                                                        
                                                        LookinAttrSec_UITextView_Text,
                                                        LookinAttrSec_UITextView_Font,
                                                        LookinAttrSec_UITextView_TextColor,
                                                        LookinAttrSec_UITextView_Alignment,
                                                        LookinAttrSec_UITextView_ContainerInset,
                                                        
                                                        LookinAttrSec_UITextField_Text,
                                                        LookinAttrSec_UITextField_Font,
                                                        LookinAttrSec_UITextField_TextColor,
                                                        LookinAttrSec_UITextField_Alignment,

                                                        LookinAttrSec_NSImageView_Name,
                                                        LookinAttrSec_NSImageView_Open,
                                                        
                                                        LookinAttrSec_NSControl_State,
                                                        LookinAttrSec_NSControl_ControlSize,
                                                        LookinAttrSec_NSControl_Font,
                                                        LookinAttrSec_NSControl_Alignment,
                                                        LookinAttrSec_NSControl_Value,
                                                        
                                                        LookinAttrSec_NSButton_Title,
                                                        LookinAttrSec_NSButton_Bordered,
                                                        LookinAttrSec_NSButton_Transparent,
                                                        LookinAttrSec_NSButton_ButtonType,
                                                        LookinAttrSec_NSButton_BezelStyle,
                                                        
                                                        LookinAttrSec_NSTextField_Bezeled,
                                                        LookinAttrSec_NSTextField_BezelStyle,
                                                        LookinAttrSec_NSTextField_Bordered,
                                                        LookinAttrSec_NSTextField_Editable,
                                                        LookinAttrSec_NSTextField_Selectable,
                                                        LookinAttrSec_NSTextField_TextColor,
                                                        LookinAttrSec_NSTextField_Placeholder,
                                                        
                                                        LookinAttrSec_NSTextView_String,
                                                        LookinAttrSec_NSTextView_Basic,
                                                        LookinAttrSec_NSTextView_Font,
                                                        LookinAttrSec_NSTextView_TextColor,
                                                        LookinAttrSec_NSTextView_Alignment,
                                                        LookinAttrSec_NSTextView_Size,
                                                        LookinAttrSec_NSTextView_ContainerInset,
                                                        
        ];
        targetSet = [NSSet setWithArray:array];
    });
    return targetSet;
}

+ (BOOL)popupToAskDoubleClickBehaviorIfNeededWithWindow:(NSWindow *)window {
    if (!window) {
        return NO;
    }
    if ([LKTutorialManager sharedInstance].hasAskedDoubleClickBehavior) {
        return NO;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = NSLocalizedString(@"What do you want to happen when you double click the layer?", nil);
    alert.informativeText = NSLocalizedString(@"You can change it at any time in your Preferences.", nil);
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:NSLocalizedString(@"Expand or collapse layer", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Focus on layer", nil)];
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            // collapse
            [LKPreferenceManager mainManager].doubleClickBehavior = LookinDoubleClickBehaviorCollapse;
        } else {
            // focus
            [LKPreferenceManager mainManager].doubleClickBehavior = LookinDoubleClickBehaviorFocus;
        }
    }];
    [LKTutorialManager sharedInstance].hasAskedDoubleClickBehavior = YES;
    return YES;
}

- (void)reset {
    [LKTutorialManager sharedInstance].hasAskedDoubleClickBehavior = NO;
    self.mcpEnabled = NO;
    self.mcpPort = LKMCPDefaultPort;
    self.mcpAllowWrites = NO;
    self.mcpAllowInvoke = NO;
    self.mcpInvokeAllowlistText = @"";
}

- (void)reportStatistics {
    [MSACAnalytics trackEvent:@"Preference" withProperties:@{
        @"DoubleClick": [NSString stringWithFormat:@"%@", @(self.doubleClickBehavior)],
        @"ShowHidden": [NSString stringWithFormat:@"%@", @(self.showHiddenItems.currentBOOLValue)],
        @"RGBA": [NSString stringWithFormat:@"%@", @(self.rgbaFormat)],
        @"FreeRotation": [NSString stringWithFormat:@"%@", @(self.freeRotation.currentBOOLValue)],
        @"FastMode": [NSString stringWithFormat:@"%@", @(self.fastMode.currentBOOLValue)]
    }];
}

@end
