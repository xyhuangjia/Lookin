//
//  LKLaunchAppView.m
//  Lookin
//
//  Created by Li Kai on 2018/11/3.
//  https://lookin.work
//

#import "LKLaunchAppView.h"
#import "LKInspectableApp.h"

@interface LKLaunchAppView ()

@property(nonatomic, strong) CALayer *hoverBgLayer;
@property(nonatomic, strong) NSImageView *previewImageView;
/// 悬浮在小图左上角的连接通道徽标（USB / Wi-Fi），区分同设备的双通道条目
@property(nonatomic, strong) LKTextControl *transportBadge;
@property(nonatomic, assign) LKChannelTransport transport;
@property(nonatomic, strong) NSImageView *iconImageView;
@property(nonatomic, strong) LKLabel *titleLabel;
@property(nonatomic, strong) LKLabel *subtitleLabel;

@property(nonatomic, strong) NSImageView *errorImageView;
@property(nonatomic, strong) LKLabel *errorTitleLabel;
@property(nonatomic, strong) LKLabel *errorSubtitleLabel;

@end

@implementation LKLaunchAppView {
    NSSize _previewSize;
    NSEdgeInsets _insets;
    CGFloat _iconTop;
    CGFloat _iconMarginRight;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    if (self = [super initWithFrame:frameRect]) {
        self.layer.cornerRadius = 4;
        
        self.hoverBgLayer = [CALayer layer];
        self.hoverBgLayer.opacity = 0;
        self.hoverBgLayer.cornerRadius = 4;
        [self.layer addSublayer:self.hoverBgLayer];
        
        self.previewImageView = [NSImageView new];
        [self addSubview:self.previewImageView];

        self.transportBadge = [LKTextControl new];
        self.transportBadge.label.font = NSFontMake(10);
        self.transportBadge.label.textColor = [NSColor whiteColor];
        self.transportBadge.insets = NSEdgeInsetsMake(2, 6, 2, 6);
        self.transportBadge.layer.cornerRadius = 3;
        self.transportBadge.adjustAlphaWhenClick = NO;
        self.transportBadge.hidden = YES;
        [self addSubview:self.transportBadge];

        self.iconImageView = [NSImageView new];
        [self addSubview:self.iconImageView];
        
        self.titleLabel = [LKLabel new];
        self.titleLabel.textColor = [NSColor labelColor];
        [self addSubview:self.titleLabel];
        
        self.subtitleLabel = [LKLabel new];
        self.subtitleLabel.textColor = [NSColor labelColor];
        [self addSubview:self.subtitleLabel];
        
        self.compactLayout = NO;
    }
    return self;
}

- (void)setCompactLayout:(BOOL)compactLayout {
    if (compactLayout) {
        _previewSize = NSMakeSize(120, 220);
        _insets = NSEdgeInsetsMake(12, 13, 8, 13);
        _iconTop = 10;
        _iconMarginRight = 6;
        self.titleLabel.font = NSFontMake(12);
        self.subtitleLabel.font = NSFontMake(11);
    } else {
        _previewSize = NSMakeSize(142, 260);
        _insets = NSEdgeInsetsMake(12, 25, 12, 25);
        _iconTop = 10;
        _iconMarginRight = 8;
        self.titleLabel.font = NSFontMake(13);
        self.subtitleLabel.font = NSFontMake(12);
    }
    
    [self setNeedsLayout:YES];
}

- (void)layout {
    [super layout];
    
    self.hoverBgLayer.frame = self.layer.bounds;
    
    if (self.app.serverVersionError) {
        $(self.errorImageView).sizeToFit.horAlign;
        $(self.errorTitleLabel).x(10).toRight(10).heightToFit.y(self.errorImageView.$maxY + 15);
        $(self.errorSubtitleLabel).sizeToFit.horAlign.y(self.errorTitleLabel.$maxY + 10);
        $(self.errorImageView, self.errorTitleLabel, self.errorSubtitleLabel).groupVerAlign.offsetY(-10);
        
    } else {
        $(self.previewImageView).size(_previewSize).horAlign.y(_insets.top);
        // 徽标悬浮于小图左上角，hidden 时布局无副作用
        $(self.transportBadge).sizeToFit.x(self.previewImageView.$x + 4).y(self.previewImageView.$y + 4);

        $(self.iconImageView).sizeToFit.y(_insets.top + _previewSize.height + _iconTop);
        
        $(self.titleLabel).sizeToFit;
        $(self.subtitleLabel).sizeToFit.y(self.titleLabel.$maxY + 2);
        $(self.titleLabel, self.subtitleLabel).x(self.iconImageView.$maxX + _iconMarginRight).groupMidY(self.iconImageView.$midY);
        
        $(self.iconImageView, self.titleLabel, self.subtitleLabel).groupHorAlign.offsetX(-2);
    }
}

- (NSSize)sizeThatFits:(NSSize)limitedSize {
    if (self.app.serverVersionError) {
        return NSMakeSize(_previewSize.width + _insets.left + _insets.right, _insets.top + _previewSize.height + _iconTop + _insets.bottom);
        
    } else {
        CGFloat previewWidth = _previewSize.width + _insets.left + _insets.right;
        CGFloat labelsWidth = self.iconImageView.image.size.width + _iconMarginRight + MAX([self.titleLabel sizeThatFits:NSSizeMax].width, [self.subtitleLabel sizeThatFits:NSSizeMax].width) + _insets.left + _insets.right;
        
        CGFloat width = MAX(previewWidth, labelsWidth);
        CGFloat height = _insets.top + _previewSize.height + _iconTop + self.iconImageView.image.size.height + _insets.bottom;
        return NSMakeSize(width, height);
    }
}

- (void)sizeToFit {
    NSSize size = [self sizeThatFits:NSSizeMax];
    [self setFrameSize:size];
}

- (void)setApp:(LKInspectableApp *)app {
    _app = app;
    
    if (app.serverVersionError) {
        [self _initErrorViewsIfNeeded];
        
        self.errorImageView.hidden = NO;
        self.errorTitleLabel.hidden = NO;
        self.errorSubtitleLabel.hidden = NO;
        
        self.previewImageView.hidden = YES;
        self.iconImageView.hidden = YES;
        self.titleLabel.hidden = YES;
        self.subtitleLabel.hidden = YES;
        
        if (app.serverVersionError.code == LookinErrCode_ServerVersionTooLow) {
            self.errorTitleLabel.stringValue = NSLocalizedString(@"The version of LookinServer linked with this iOS App is too low.", nil);
            
        } else if (app.serverVersionError.code == LookinErrCode_ServerVersionTooHigh) {
            self.errorTitleLabel.stringValue = NSLocalizedString(@"Unable to inspect this iOS App. Current version of Lookin app is too low.", nil);
            
        } else {
            self.errorTitleLabel.stringValue = @"Unknown Error";
            NSAssert(NO, @"");
        }
        
    } else {
        self.errorImageView.hidden = YES;
        self.errorTitleLabel.hidden = YES;
        self.errorSubtitleLabel.hidden = YES;
        
        self.previewImageView.hidden = NO;
        self.iconImageView.hidden = NO;
        self.titleLabel.hidden = NO;
        self.subtitleLabel.hidden = NO;
        
        self.previewImageView.image = app.appInfo.screenshot;
        if (app.appInfo.deviceType == LookinAppInfoDeviceSimulator) {
            self.iconImageView.image = NSImageMake(@"icon_simulator_big");
        } else if (app.appInfo.deviceType == LookinAppInfoDeviceIPad) {
            self.iconImageView.image = NSImageMake(@"icon_ipad_big");
        } else if (app.appInfo.deviceType == LookinAppInfoDeviceMac) {
            self.iconImageView.image = NSImageMake(@"icon_mac_big");
        } else {
            self.iconImageView.image = NSImageMake(@"icon_iphone_big");
        }
        self.titleLabel.stringValue = app.appInfo.lookin_displayName;
        self.subtitleLabel.stringValue = [NSString stringWithFormat:@"%@", app.appInfo.osDescription];

        // 连接类型以本地 channel 为准（transport），不信任 server 下发的前缀（旧版 server 会标错）
        self.transport = app.transport;
        switch (self.transport) {
            case LKChannelTransportUSB:
                self.transportBadge.label.stringValue = @"USB";
                self.transportBadge.hidden = NO;
                break;
            case LKChannelTransportWireless:
                self.transportBadge.label.stringValue = @"Wi-Fi";
                self.transportBadge.hidden = NO;
                break;
            default:
                self.transportBadge.hidden = YES;
                break;
        }
    }
    
    [self updateLayer];
    [self setNeedsLayout:YES];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    self.hoverBgLayer.opacity = 1;
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    self.hoverBgLayer.opacity = 0;
}

- (void)updateLayer {
    [super updateLayer];
    self.hoverBgLayer.backgroundColor = self.effectiveAppearance.lk_isDarkMode ? LookinColorRGBAMake(0, 0, 0, .17).CGColor : LookinColorRGBAMake(0, 0, 0, .08).CGColor;

    if (self.app.serverVersionError) {
        self.layer.backgroundColor = self.effectiveAppearance.lk_isDarkMode ? LookinColorRGBAMake(0, 0, 0, .13).CGColor : LookinColorRGBAMake(0, 0, 0, .05).CGColor;
    } else {
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
    }

    if (!self.transportBadge.hidden) {
        // 动态色的 CGColor 需随 appearance 重新解析
        NSColor *badgeColor = (self.transport == LKChannelTransportWireless) ? [NSColor systemBlueColor] : [NSColor systemGreenColor];
        self.transportBadge.layer.backgroundColor = badgeColor.CGColor;
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    [self.trackingAreas enumerateObjectsUsingBlock:^(NSTrackingArea * _Nonnull oldArea, NSUInteger idx, BOOL * _Nonnull stop) {
        [self removeTrackingArea:oldArea];
    }];
    
    NSTrackingArea *newArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways owner:self userInfo:nil];
    [self addTrackingArea:newArea];
}

- (void)_initErrorViewsIfNeeded {
    if (!self.errorImageView) {
        self.errorImageView = [NSImageView new];
        self.errorImageView.image = NSImageMake(@"icon_alert_big");
        [self addSubview:self.errorImageView];
    }
    if (!self.errorTitleLabel) {
        self.errorTitleLabel = [LKLabel new];
        self.errorTitleLabel.textColor = [NSColor labelColor];
        self.errorTitleLabel.alignment = NSTextAlignmentCenter;
        self.errorTitleLabel.maximumNumberOfLines = 0;
        [self addSubview:self.errorTitleLabel];
    }
    if (!self.errorSubtitleLabel) {
        self.errorSubtitleLabel = [LKLabel new];
        self.errorSubtitleLabel.stringValue = NSLocalizedString(@"Find solution…", nil);
        self.errorSubtitleLabel.textColor = [NSColor linkColor];
        [self addSubview:self.errorSubtitleLabel];
    }
}

@end
