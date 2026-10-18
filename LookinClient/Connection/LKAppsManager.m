//
//  LKDeviceManager.m
//  Lookin
//
//  Created by Li Kai on 2018/11/3.
//  https://lookin.work
//

#import "LKAppsManager.h"
#import "Lookin_PTChannel.h"
#import "LKConnectionManager.h"
#import "LookinDefines.h"
#import "LookinAppInfo.h"
#import "LookinHierarchyInfo.h"
#import "LookinConnectionResponseAttachment.h"

NSString *const LKInspectingAppDidEndNotificationName = @"LKInspectingAppDidEndNotificationName";

@interface LKAppsManager ()

@property(nonatomic, strong) RACSubject *willConnectToApp;

@end

@implementation LKAppsManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static LKAppsManager *instance = nil;
    dispatch_once(&onceToken,^{
        instance = [[super allocWithZone:NULL] init];
    });
    return instance;
}

+ (id)allocWithZone:(struct _NSZone *)zone{
    return [self sharedInstance];
}

- (instancetype)init {
    if (self = [super init]) {
        _willConnectToApp = [RACSubject subject];
        _didAutoReconnectSucc = [RACSubject subject];
        
        @weakify(self);
        // 连接状态会直接驱动多个页面的布局和内容，统一投递到主线程，避免 UI 在后台线程被更新。
        [[[[[[LKConnectionManager sharedInstance].channelWillEnd filter:^BOOL(Lookin_PTChannel *channel) {
            @strongify(self);
            return channel == self.inspectingApp.channel;

        }] deliverOnMainThread] flattenMap:^__kindof RACSignal * _Nullable(Lookin_PTChannel *channel) {
            @strongify(self);

            NSLog(@"current connection end");

            LookinAppInfo *targetAppInfo = self.inspectingApp.appInfo;
            self.inspectingApp = nil;

            RACSignal *signal = [[[RACSignal interval:3 onScheduler:[RACScheduler scheduler]] takeUntil:self.willConnectToApp] flattenMap:^__kindof RACSignal * _Nullable(NSDate * _Nullable value) {
                return [self _fetchInspectableAppWithSimilarInfo:targetAppInfo];
            }];
            return signal;

        }] deliverOnMainThread] subscribeNext:^(LKInspectableApp *newApp) {
            @strongify(self);
            if (newApp) {
                NSLog(@"Reconnected successfully.");
                self.inspectingApp = newApp;
                [self.didAutoReconnectSucc sendNext:newApp];
            } else {
//                NSLog(@"Failed to reconnect.");
            }
        }];
        
//        [[LKConnectionManager sharedInstance].didReceivePush subscribeNext:^(RACTuple *x) {
//            @strongify(self);
//            RACTupleUnpack(Lookin_PTChannel *channel, NSNumber *type, NSObject *data) = x;
//            if (channel != self.inspectingApp.channel) {
//                return;
//            }
//        }];
        
    }
    return self;
}

- (void)setInspectingApp:(LKInspectableApp *)inspectingApp {
    // 该属性被大量 UI 通过 KVO 观察。无论调用方在哪个线程（例如自动重连在 RACScheduler 后台线程上
    // 完成），都统一切回主线程再赋值，避免在后台线程触发 NSSplitView / NSToolbar 等 UI 更新。
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.inspectingApp = inspectingApp;
        });
        return;
    }

    BOOL shouldPostNotification = (_inspectingApp && !inspectingApp);
    
    _inspectingApp = inspectingApp;
    if (inspectingApp) {
        [self.willConnectToApp sendNext:inspectingApp];
    }
    
    if (shouldPostNotification) {
        [[NSNotificationCenter defaultCenter] postNotificationName:LKInspectingAppDidEndNotificationName object:self];
    }
}

- (RACSignal *)_fetchInspectableAppWithSimilarInfo:(LookinAppInfo *)appInfo {
    return [[[self fetchAppInfosWithImage:NO localInfos:nil] map:^id _Nullable(NSArray<LKInspectableApp *> *allApps) {
//        NSLog(@"Reconnecting… ...");
        LKInspectableApp *targetApp = [allApps lookin_firstFiltered:^BOOL(LKInspectableApp *obj) {
            return [appInfo isEqualToAppInfo:obj.appInfo];
        }];
        if (!targetApp) {
            // 双通道（USB + Wi-Fi）下 deviceDescription 的 “ᯤ ” 前缀会随通道不同而不同；
            // 若原通道已断（比对不上），则忽略前缀匹配另一条通道，保证跨通道也能自动重连
            targetApp = [allApps lookin_firstFiltered:^BOOL(LKInspectableApp *obj) {
                return [appInfo.appName isEqualToString:obj.appInfo.appName]
                && [appInfo.osDescription isEqualToString:obj.appInfo.osDescription]
                && appInfo.deviceType == obj.appInfo.deviceType
                && [appInfo.lookin_displayName isEqualToString:obj.appInfo.lookin_displayName];
            }];
        }
        targetApp.appInfo.appIcon = appInfo.appIcon;
        return targetApp;
    }] catch:^RACSignal * _Nonnull(NSError * _Nonnull error) {
        return [RACSignal return:nil];
    }];
}

- (RACSignal *)fetchAppInfosWithImage:(BOOL)needImages localInfos:(NSArray<LookinAppInfo *> *)localInfos {
    NSArray<LookinAppInfo *> *validAppInfos = [localInfos lookin_filter:^BOOL(LookinAppInfo *info) {
        /// 超过 8 秒则认为过期
        return [[NSDate date] timeIntervalSince1970] - info.cachedTimestamp <= 8;
    }];
    
    NSArray<NSNumber *> *localInfoIdentifiers = [validAppInfos lookin_map:^id(NSUInteger idx, LookinAppInfo *value) {
        return @(value.appInfoIdentifier);
    }] ? : @[];
    NSDictionary *params = @{@"needImages":@(needImages), @"local":localInfoIdentifiers};
    
    return [[[[LKConnectionManager sharedInstance] tryToConnectAllPorts] flattenMap:^__kindof RACSignal * _Nullable(NSArray<Lookin_PTChannel *> *connectedChannels) {
        if (!connectedChannels.count) {
            // 没有任何 channel
            return [RACSignal return:nil];
        }
        
        NSArray<RACSignal *> *signals = [connectedChannels lookin_map:^id(NSUInteger idx, Lookin_PTChannel *channel) {
            return [[[LKConnectionManager sharedInstance] requestWithType:LookinRequestTypeApp data:params channel:channel] catch:^RACSignal * _Nonnull(NSError * _Nonnull error) {
                if (error.code == LookinErrCode_ServerVersionTooHigh || error.code == LookinErrCode_ServerVersionTooLow) {
                    // 这些 Lookin 版本不匹配的错误应该被保留，因为业务需要显示这些错误
                    return [RACSignal return:error];
                } else {
                    // 位于后台无法执行代码的 channel 会走到这里，应该过滤掉这些 channel
                    return [RACSignal return:nil];
                }
            }];
        }];
        return [RACSignal zip:signals];
    
    }] map:^id _Nullable(RACTuple * _Nullable x) {
        NSArray<LKInspectableApp *> *apps = [x.allObjects lookin_map:^id(NSUInteger idx, id value) {
            if (value == [NSNull null]) {
                // 位于后台无法执行代码的 app
                return nil;
            }
            
            if ([value isKindOfClass:[NSError class]]) {
                // Lookin 版本不匹配的 app
                LKInspectableApp *app = [[LKInspectableApp alloc] init];
                app.serverVersionError = value;
                return app;
            }
            
            if ([value isKindOfClass:[RACTuple class]]) {
                RACTupleUnpack(LookinConnectionResponseAttachment *response, Lookin_PTChannel *relatedChannel) = value;
                if (response.error) {
                    NSAssert(NO, @"");
                    return nil;
                } else {
                    LookinAppInfo *receivedInfo = response.data;
                    receivedInfo.cachedTimestamp = [[NSDate date] timeIntervalSince1970];
                    if (receivedInfo.shouldUseCache) {
                        // 使用之前拉取的旧 info
                        LookinAppInfo *localInfo = [validAppInfos lookin_firstFiltered:^BOOL(LookinAppInfo *obj) {
                            return obj.appInfoIdentifier == receivedInfo.appInfoIdentifier;
                        }];
                        if (localInfo) {
                            receivedInfo = localInfo;
                        }
                    }
                    
                    LKInspectableApp *app = [[LKInspectableApp alloc] init];
                    app.appInfo = receivedInfo;
                    app.channel = relatedChannel;
                    return app;
                }
            }
            
            NSAssert(NO, @"");
            return nil;
        }];
        return apps;
    }];
}

@end
