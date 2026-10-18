//
//  LKDeviceItem.h
//  Lookin
//
//  Created by Li Kai on 2018/11/3.
//  https://lookin.work
//

#import <Foundation/Foundation.h>
#import "LookinAppInfo.h"
#import "LookinAttributeModification.h"
#import "LookinCustomAttrModification.h"
#import "LookinAttributesGroup.h"
#import "LKConnectionManager.h"

@class Lookin_PTChannel, LookinDisplayItemTrace, LookinInvocationRequest, LookinHierarchyInfo, LookinStaticAsyncUpdateTasksPackage, LookinStaticAsyncUpdateTask;

@interface LKInspectableApp : NSObject

@property(nonatomic, strong) NSError *serverVersionError;

@property(nonatomic, strong) LookinAppInfo *appInfo;

@property(nonatomic, weak) Lookin_PTChannel *channel;

/// 该 app 实际经由的连接通道（USB / 无线 / 本机），由拉取到它的 channel 决定，
/// 不依赖 server 下发的 isWireless 标记（旧版 server 在 USB、Wi-Fi 并存时会标错）
@property(nonatomic, readonly) LKChannelTransport transport;

- (RACSignal *)fetchHierarchyData;

- (RACSignal *)submitInbuiltModification:(LookinAttributeModification *)modification;
- (RACSignal *)submitCustomModification:(LookinCustomAttrModification *)modification;

- (RACSignal *)fetchHierarchyDetailWithTaskPackages:(NSArray<LookinStaticAsyncUpdateTasksPackage *> *)packages;
- (void)cancelHierarchyDetailFetching;

- (RACSignal *)fetchModificationPatchWithTasks:(NSArray<LookinStaticAsyncUpdateTask *> *)tasks;

- (RACSignal *)fetchObjectWithOid:(unsigned long)oid;

/// data 为 NSArray<LookinAttributesGroup *>
- (RACSignal *)fetchAttrGroupListWithOid:(unsigned long)oid;

- (RACSignal *)fetchSelectorNamesWithClass:(NSString *)className hasArg:(BOOL)hasArg;

- (RACSignal *)invokeMethodWithOid:(unsigned long)oid text:(NSString *)text;

/// 获取某个 imageView 的 image 对象，oid 是 imageView 的 oid
- (RACSignal *)fetchImageWithImageViewOid:(unsigned long)oid;

/// 修改一个 gestureRecognizer 的 enable 属性。如果 shouldBeEnabled 为 YES 则表示想要把它的 enable 属性修改为 YES
- (RACSignal *)modifyGestureRecognizer:(unsigned long)oid toBeEnabled:(BOOL)shouldBeEnabled;

#pragma mark - Push From iOS

@end

@interface LookinAppInfo (LookinClient)

/// 去掉 server 端打的 “ᯤ ” 无线前缀后的设备名。旧版 server 在 USB、Wi-Fi 并存时会把 USB 通道的
/// appInfo 也打上该前缀，因此展示与匹配时统一使用该方法，连接类型以 LKInspectableApp.transport 为准
- (NSString *)lookin_displayName;

@end
