//
//  LKLaunchWirelessDeviceView.h
//  LookinClient
//
//  Created by mlch911 on 2023/11/13.
//  Copyright © 2023 hughkli. All rights reserved.
//

#import "LKBaseView.h"
#import "ECOChannelDeviceInfo.h"

@interface LKLaunchWirelessDeviceView : LKBaseControl

@property(nonatomic, strong) ECOChannelDeviceInfo *device;

/// 用户点击「取消配对」后回调（配对记录已在行内清除），弹层据此移除该行
@property(nonatomic, copy) void (^unpairHandler)(ECOChannelDeviceInfo *device);

@end
