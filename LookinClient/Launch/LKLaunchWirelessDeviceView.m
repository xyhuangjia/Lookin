//
//  LKLaunchWirelessDeviceView.m
//  LookinClient
//
//  Created by mlch911 on 2023/11/13.
//  Copyright © 2023 hughkli. All rights reserved.
//

#import "LKLaunchWirelessDeviceView.h"
#import "LKConnectionManager.h"

@interface LKLaunchWirelessDeviceView ()

@property(nonatomic, strong) CALayer *hoverBgLayer;
@property(nonatomic, strong) NSImageView *iconImageView;
@property(nonatomic, strong) LKLabel *titleLabel;
@property(nonatomic, strong) LKLabel *subtitleLabel;
@property(nonatomic, strong) LKLabel *stateLabel;
@property(nonatomic, strong) LKTextControl *unpairControl;

@end

@implementation LKLaunchWirelessDeviceView {
	NSEdgeInsets _insets;
	CGFloat _iconMarginRight;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
	if (self = [super initWithFrame:frameRect]) {
		self.layer.cornerRadius = 4;
		
		self.hoverBgLayer = [CALayer layer];
		self.hoverBgLayer.opacity = 0;
		self.hoverBgLayer.cornerRadius = 4;
		[self.layer addSublayer:self.hoverBgLayer];
		
		self.iconImageView = [NSImageView new];
		[self addSubview:self.iconImageView];
		
		self.titleLabel = [LKLabel new];
		self.titleLabel.textColor = [NSColor labelColor];
		[self addSubview:self.titleLabel];
		
		self.subtitleLabel = [LKLabel new];
		self.subtitleLabel.textColor = [NSColor secondaryLabelColor];
		[self addSubview:self.subtitleLabel];
		
		self.stateLabel = [LKLabel new];
		self.stateLabel.textColor = [NSColor labelColor];
		[self addSubview:self.stateLabel];
		
		self.unpairControl = LKTextControl.new;
		self.unpairControl.label.textColor = [NSColor labelColor];
		self.unpairControl.spaceBetweenLabelAndImage = 4;
		[self addSubview:self.unpairControl];

		_insets = NSEdgeInsetsMake(12, 13, 8, 13);
		_iconMarginRight = 6;
		self.titleLabel.font = NSFontMake(12);
		self.subtitleLabel.font = NSFontMake(11);

		[self.unpairControl addTarget:self clickAction:@selector(handleUnpairControl)];
	}
	return self;
}

- (void)layout {
	[super layout];
	
	self.hoverBgLayer.frame = self.layer.bounds;
	
	$(self.iconImageView).sizeToFit.y(_insets.top);
	
	$(self.titleLabel).sizeToFit;
	$(self.subtitleLabel).sizeToFit.y(self.titleLabel.$maxY + 2);
	$(self.titleLabel, self.subtitleLabel).x(self.iconImageView.$maxX + _iconMarginRight).groupMidY(self.iconImageView.$midY);
	
	$(self.unpairControl).sizeToFit.maxX(self.$maxX - _insets.right - 10).midY(self.subtitleLabel.$midY);
	$(self.stateLabel).sizeToFit.maxX(self.unpairControl.hidden ? self.unpairControl.$maxX : self.unpairControl.$x - 6).midY(self.subtitleLabel.$midY);
	
	$(self.iconImageView, self.titleLabel, self.subtitleLabel).groupHorAlign.offsetX(-2);
}

- (NSSize)sizeThatFits:(NSSize)limitedSize {
	CGFloat width = self.iconImageView.image.size.width + _iconMarginRight + MAX([self.titleLabel sizeThatFits:NSSizeMax].width, [self.subtitleLabel sizeThatFits:NSSizeMax].width) + _insets.left + _insets.right;
	//右侧状态区也占行宽：stateLabel 永远存在，已配对设备其后还有「取消配对」按钮（layout 里右对齐、
	//且比 insets 额外缩进 10pt）。不计入的话行宽只按标题算，标题长时会压到按钮底下
	CGFloat rightZoneWidth = [self.stateLabel sizeThatFits:NSSizeMax].width;
	if (!self.unpairControl.hidden) {
		rightZoneWidth += 6 + [self.unpairControl sizeThatFits:NSSizeMax].width;
	}
	width += rightZoneWidth + 16;
	CGFloat height = _insets.top + self.iconImageView.image.size.height + _insets.bottom;
	return NSMakeSize(width, height);
}

- (void)sizeToFit {
	NSSize size = [self sizeThatFits:NSSizeMax];
	[self setFrameSize:size];
}

- (void)setDevice:(ECOChannelDeviceInfo *)device {
	_device = device;
	switch (device.deviceType) {
	case ECODeviceType_Simulator:
		self.iconImageView.image = NSImageMake(@"icon_simulator_big");
		break;
	case ECODeviceType_Device:
		self.iconImageView.image = NSImageMake(@"icon_iphone_big");
		break;
	case ECODeviceType_iPad_Device:
		self.iconImageView.image = NSImageMake(@"icon_ipad_big");
		break;
	case ECODeviceType_MacApp:
		NSAssert(NO, @"");
		break;
	default:
		break;
	}
	self.titleLabel.stringValue = [NSString stringWithFormat:@"%@ - %@(%@.%@)", device.deviceName, device.appInfo.appName, device.appInfo.appVersion, device.appInfo.appShortVersion];
	self.subtitleLabel.stringValue = [NSString stringWithFormat:@"iOS %@", device.systemVersion];
	if (device.authorizedType) {
		self.stateLabel.stringValue = NSLocalizedString(@"Connected", nil);
	} else {
		NSString *pairCode = [LKConnectionManager.sharedInstance pairingCodeForDevice:device];
		if (pairCode.length >= 6) {
			//与手机端一致，6 位码分成 3+3 展示，方便肉眼核对
			NSString *displayCode = [NSString stringWithFormat:@"%@ %@", [pairCode substringToIndex:3], [pairCode substringFromIndex:3]];
			self.stateLabel.stringValue = [NSString stringWithFormat:NSLocalizedString(@"Pairing code %@", nil), displayCode];
		} else {
			self.stateLabel.stringValue = NSLocalizedString(@"Click to pair", nil);
		}
	}

	//已配对（连接中）的设备才显示「取消配对」
	self.unpairControl.hidden = !device.authorizedType;
	self.unpairControl.label.stringValue = NSLocalizedString(@"Unpair", nil);
	self.unpairControl.rightImage = nil;
}

- (void)handleUnpairControl {
	[LKConnectionManager.sharedInstance unpairDevice:self.device];
}

- (void)mouseEntered:(NSEvent *)event {
	[super mouseEntered:event];
	if (!self.device.authorizedType) {
		self.hoverBgLayer.opacity = 1;
	}
}

- (void)mouseExited:(NSEvent *)event {
	[super mouseExited:event];
	if (!self.device.authorizedType) {
		self.hoverBgLayer.opacity = 0;
	}
}

- (void)updateLayer {
	[super updateLayer];
	self.hoverBgLayer.backgroundColor = self.effectiveAppearance.lk_isDarkMode ? LookinColorRGBAMake(0, 0, 0, .17).CGColor : LookinColorRGBAMake(0, 0, 0, .08).CGColor;
	self.layer.backgroundColor = [NSColor clearColor].CGColor;
}

- (void)updateTrackingAreas {
	[super updateTrackingAreas];
	[self.trackingAreas enumerateObjectsUsingBlock:^(NSTrackingArea * _Nonnull oldArea, NSUInteger idx, BOOL * _Nonnull stop) {
		[self removeTrackingArea:oldArea];
	}];
	
	NSTrackingArea *newArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways owner:self userInfo:nil];
	[self addTrackingArea:newArea];
}

@end
