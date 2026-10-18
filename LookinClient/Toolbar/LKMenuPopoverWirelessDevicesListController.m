//
//  LKMenuPopoverWirelessAppsListController.m
//  LookinClient
//
//  Created by mlch911 on 2023/11/13.
//  Copyright © 2023 hughkli. All rights reserved.
//

#import "LKMenuPopoverWirelessDevicesListController.h"
#import "LKAppsManager.h"
#import "LKLaunchWirelessDeviceView.h"
#import "LookinHierarchyInfo.h"
#import "LKStaticHierarchyDataSource.h"

@interface LKMenuPopoverWirelessDevicesListController ()

@property(nonatomic, strong) NSArray<LKLaunchWirelessDeviceView *> *deviceViews;

@property(nonatomic, strong) LKLabel *titleLabel;
@property(nonatomic, strong) LKLabel *subtitleLabel;
@property(nonatomic, strong) LKTextControl *tutorialControl;

@end

@implementation LKMenuPopoverWirelessDevicesListController {
	CGFloat _appViewInterSpace;
	NSEdgeInsets _insets;
	CGFloat _titleMarginBottom;
	CGFloat _subtitleMarginBottom;
}

- (instancetype)initWithDevices:(NSArray<ECOChannelDeviceInfo *> *)devices {
	if (self = [self init]) {
		_insets = NSEdgeInsetsMake(9, 18, 35, 14);
		_titleMarginBottom = 3;
		_subtitleMarginBottom = 5;
		_appViewInterSpace = 1;
		
		NSString *title = NSLocalizedString(@"Wireless Devices", nil);
		NSString *subtitle = nil;
		
		if (devices.count) {
			self.deviceViews = [devices.rac_sequence map:^id _Nullable(ECOChannelDeviceInfo *device) {
				LKLaunchWirelessDeviceView *view = [LKLaunchWirelessDeviceView new];
				view.device = device;
				@weakify(self);
				view.unpairHandler = ^(ECOChannelDeviceInfo *unpairedDevice) {
					@strongify(self);
					[self removeDeviceViewForDevice:unpairedDevice];
				};
				[view addTarget:self clickAction:@selector(handleClickAppView:)];
				[self.view addSubview:view];
				return view;
			}].array;
		}
		
		if (title.length) {
			self.titleLabel = [LKLabel new];
			self.titleLabel.alignment = NSTextAlignmentCenter;
			self.titleLabel.font = NSFontMake(14);
			self.titleLabel.textColor = [NSColor labelColor];
			self.titleLabel.stringValue = title;
			[self.view addSubview:self.titleLabel];
		}
		
		if (subtitle.length) {
			self.subtitleLabel = [LKLabel new];
			self.subtitleLabel.alignment = NSTextAlignmentCenter;
			self.subtitleLabel.font = NSFontMake(12);
			self.subtitleLabel.textColor = [NSColor labelColor];
			self.subtitleLabel.stringValue = subtitle;
			[self.view addSubview:self.subtitleLabel];
		}
		
		self.tutorialControl = [LKTextControl new];
		self.tutorialControl.layer.cornerRadius = 4;
		self.tutorialControl.label.stringValue = NSLocalizedString(@"Can't see your app ?", nil);
		self.tutorialControl.label.textColor = [NSColor linkColor];
		self.tutorialControl.label.font = NSFontMake(12);
		self.tutorialControl.adjustAlphaWhenClick = YES;
		[self.tutorialControl addTarget:self clickAction:@selector(_handleTutorial)];
		[self.view addSubview:self.tutorialControl];
	}
	return self;
}

- (void)viewDidLayout {
	[super viewDidLayout];
	
	__block CGFloat y = _insets.top;
	if (self.titleLabel) {
		$(self.titleLabel).fullWidth.heightToFit.y(y);
		y = self.titleLabel.$maxY + _titleMarginBottom;
	}
	if (self.subtitleLabel) {
		$(self.subtitleLabel).fullWidth.heightToFit.y(y);
		y = self.subtitleLabel.$maxY + _subtitleMarginBottom;
	}
	
	if (self.deviceViews.count) {
		[self.deviceViews enumerateObjectsUsingBlock:^(LKLaunchWirelessDeviceView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
			$(obj).sizeToFit.x(0).y(y);
			y = obj.$maxY + self->_appViewInterSpace;
		}];
		//注意：这里不能用 groupHorAlign —— 它按 superview 宽度整体居中，而 popover 定宽晚于本次
		//布局（superview 宽度可能还是 0），会把行平移到负坐标、行内容整体漂出可视区。
		//tutorial 链接同理不用 horAlign，改为以首行宽度（= 内容宽）为锚居中
		$(self.tutorialControl).sizeToFit.midX(self.deviceViews.firstObject.$width / 2).bottom(10);
	} else {
		$(self.tutorialControl).sizeToFit.horAlign.offsetX(3);
		if (self.subtitleLabel.isVisible) {
			$(self.tutorialControl).y(y);
		} else {
			$(self.tutorialControl).y(y + 8);
		}
		$(self.titleLabel, self.subtitleLabel, self.tutorialControl).visibles.groupVerAlign;
	}
	
}

- (void)handleClickAppView:(LKLaunchWirelessDeviceView *)view {
	ECOChannelDeviceInfo *device = view.device;
	if (!device.authorizedType && self.didSelectDevice) {
		self.didSelectDevice(device);
	}
}

/// 取消配对后移除对应行并触发重排（剩余行重新垂直排布）
- (void)removeDeviceViewForDevice:(ECOChannelDeviceInfo *)device {
	__block LKLaunchWirelessDeviceView *target = nil;
	[self.deviceViews enumerateObjectsUsingBlock:^(LKLaunchWirelessDeviceView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
		if ([obj.device isEqual:device]) {
			target = obj;
			*stop = YES;
		}
	}];
	if (!target) {
		return;
	}
	NSMutableArray<LKLaunchWirelessDeviceView *> *remaining = [self.deviceViews mutableCopy];
	[remaining removeObject:target];
	self.deviceViews = remaining;
	[target removeFromSuperview];
	[self.view setNeedsLayout:YES];
}

- (void)_handleTutorial {
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://lookin.work/faq/cannot-see/"]];
}

- (NSSize)bestSize {
	if (self.deviceViews.count <= 0) {
		return NSMakeSize(245, 80);
	}
	__block CGFloat width = 0;
	__block CGFloat height = _insets.top + _insets.bottom;
	[self.deviceViews enumerateObjectsUsingBlock:^(LKLaunchWirelessDeviceView * _Nonnull view, NSUInteger idx, BOOL * _Nonnull stop) {
		NSSize size = [view sizeThatFits:NSSizeMax];
		width = MAX(width, size.width + _insets.left + _insets.right);
		height += size.height;
	}];
	
	if (self.titleLabel) {
		NSSize titleSize = [self.titleLabel sizeThatFits:NSSizeMax];
		height += titleSize.height + _titleMarginBottom;
		width = MAX(width, titleSize.width + _insets.left + _insets.right);
	}
	if (self.subtitleLabel) {
		NSSize subtitleSize = [self.subtitleLabel sizeThatFits:NSSizeMax];
		height += subtitleSize.height + _subtitleMarginBottom;
		width = MAX(width, subtitleSize.width + _insets.left + _insets.right);
	}
	
	return NSMakeSize(MAX(245, width), height);
}

@end
