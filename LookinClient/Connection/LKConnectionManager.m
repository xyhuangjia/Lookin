//
//  LKConnectionManager.m
//  Lookin
//
//  Created by Li Kai on 2018/11/2.
//  https://lookin.work
//

#import "LKConnectionManager.h"
#import "Lookin_PTChannel.h"
#import "LookinDefines.h"
#import "LookinConnectionResponseAttachment.h"
#import "LKPreferenceManager.h"
#import "LookinAppInfo.h"
#import "LKConnectionRequest.h"
#import "LKServerVersionRequestor.h"
#import "ECOChannelManager.h"
#import "LKHelper.h"

static NSIndexSet * PushFrameTypeList(void) {
    static NSIndexSet *list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
        list = set.copy;
    });
    return list;
}

NSString *const LKUnpairedWirelessDeviceDidArriveNotification = @"LKUnpairedWirelessDeviceDidArriveNotification";

/// 通道对象上绑定的来源类型（LKChannelTransport），用于 UI 区分 USB / Wi-Fi
static NSString * const Key_BindingChannelTransport = @"lk_channelTransport";

@implementation Lookin_PTChannel (LKConnection)

- (void)setActiveRequests:(NSMutableSet<LKConnectionRequest *> *)activeRequests {
    [self lookin_bindObject:activeRequests forKey:@"activeRequest"];
}

- (NSMutableSet<LKConnectionRequest *> *)activeRequests {
    return [self lookin_getBindObjectForKey:@"activeRequest"];
}

@end

@implementation ECOChannelDeviceInfo (LKConnection)

- (void)setActiveRequests:(NSMutableSet<LKConnectionRequest *> *)activeRequests {
	[self lookin_bindObject:activeRequests forKey:@"activeRequest"];
}

- (NSMutableSet<LKConnectionRequest *> *)activeRequests {
	return [self lookin_getBindObjectForKey:@"activeRequest"];
}

@end

@interface LKSimulatorConnectionPort : NSObject

@property(nonatomic, assign) int portNumber;

@property(nonatomic, strong) Lookin_PTChannel *connectedChannel;

@end

@implementation LKSimulatorConnectionPort

- (NSString *)description {
    return [NSString stringWithFormat:@"number:%@", @(self.portNumber)];
}

@end

@interface LKUSBConnectionPort : NSObject

@property(nonatomic, assign) int portNumber;

@property(nonatomic, strong) NSNumber *deviceID;

@property(nonatomic, strong) Lookin_PTChannel *connectedChannel;

/// 本次 USB 插入会话内是否已提示过「连接被拒」，避免每轮轮询刷屏
@property(nonatomic, assign) BOOL hasLoggedConnectRefusal;

@end

@implementation LKUSBConnectionPort

- (NSString *)description {
    return [NSString stringWithFormat:@"number:%@, deviceID:%@, connectedChannel:%@", @(self.portNumber), self.deviceID, self.connectedChannel];
}

@end

@interface LKConnectionManager () <Lookin_PTChannelDelegate>

@property(nonatomic, copy) NSArray<LKSimulatorConnectionPort *> *allSimulatorPorts;
@property(nonatomic, strong) NSMutableArray<LKUSBConnectionPort *> *allUSBPorts;
@property(nonatomic, strong) NSMutableArray<ECOChannelDeviceInfo *> *connectWirelessDevices;
@property(nonatomic, strong) NSMutableArray<ECOChannelDeviceInfo *> *notConnectWirelessDevices;
@property(nonatomic, strong) ECOChannelManager *wirelessChannel;
@property(nonatomic, strong) NSMutableDictionary *authStateChangedBlocks;
/// 进行中的配对：device.hash → 6 位配对码
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pairingCodes;

@end

@implementation LKConnectionManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static LKConnectionManager *instance = nil;
    dispatch_once(&onceToken,^{
        instance = [[super allocWithZone:NULL] init];
    });
    return instance;
}

+ (id)allocWithZone:(struct _NSZone *)zone {
    return [self sharedInstance];
}

- (instancetype)init {
    if (self = [super init]) {
        _channelWillEnd = [RACSubject subject];
        _didReceivePush = [RACSubject subject];
        
        self.allSimulatorPorts = ({
            NSMutableArray<LKSimulatorConnectionPort *> *ports = [NSMutableArray array];
            for (int number = LookinSimulatorIPv4PortNumberStart; number <= LookinSimulatorIPv4PortNumberEnd; number++) {
                LKSimulatorConnectionPort *port = [LKSimulatorConnectionPort new];
                port.portNumber = number;
                [ports addObject:port];
            }
            ports;
        });
        self.allUSBPorts = [NSMutableArray array];
		self.connectWirelessDevices = [NSMutableArray array];
		self.notConnectWirelessDevices = [NSMutableArray array];
		self.authStateChangedBlocks = [NSMutableDictionary dictionary];
		
		[self _startListeningForWirelessDevices];
        [self _startListeningForUSBDevices];
        
        [[LKServerVersionRequestor shared] preload];
    }
    return self;
}

- (NSArray *)getAllWirelessDevices {
	// connect 与 notConnect 在历史竞态下可能短暂出现同设备双条目，展示前统一按 isEqual:（uuid+appId）去重；
	// 该方法由主线程 UI 调用，而设备增删均已收敛到主线程，读写同域安全
	NSMutableArray *devices = [NSMutableArray array];
	for (ECOChannelDeviceInfo *device in [self.connectWirelessDevices copy]) {
		if (![devices containsObject:device]) {
			[devices addObject:device];
		}
	}
	for (ECOChannelDeviceInfo *device in [self.notConnectWirelessDevices copy]) {
		if (![devices containsObject:device]) {
			[devices addObject:device];
		}
	}
	return devices.copy;
}

- (LKChannelTransport)transportOfChannel:(id)channel {
	if (!channel) {
		return LKChannelTransportLocal;
	}
	if ([channel isKindOfClass:ECOChannelDeviceInfo.class]) {
		return LKChannelTransportWireless;
	}
	NSNumber *bound = [(Lookin_PTChannel *)channel lookin_getBindObjectForKey:Key_BindingChannelTransport];
	if (bound) {
		return bound.integerValue;
	}
	return LKChannelTransportLocal;
}

- (RACSignal<ECOChannelDeviceInfo *> *)connectToWireless:(ECOChannelDeviceInfo *)device {
	return [self _tryToConnectToWirelessDevice:device];
}

- (NSString *)pairingCodeForDevice:(ECOChannelDeviceInfo *)device {
	return self.pairingCodes[@(device.hash)];
}

- (void)unpairDevice:(ECOChannelDeviceInfo *)device {
	[self.wirelessChannel removePairedDevice:device];
	// Deny 帧会同步清除手机侧的配对记录
	[self.wirelessChannel sendAuthorizationMessageToDevice:device state:ECOAuthorizeResponseType_Deny showAuthAlert:NO pairCode:nil];
	[self.connectWirelessDevices removeObject:device];
	[self.notConnectWirelessDevices removeObject:device];
	[self.pairingCodes removeObjectForKey:@(device.hash)];
	[self.channelWillEnd sendNext:device];
}

/// 对未配对设备发起蓝牙式配对：生成/复用 6 位码，携带在授权请求里发给手机；新配对时通知 UI 弹出设备列表
- (void)_beginPairingWithDevice:(ECOChannelDeviceInfo *)device {
	NSString *code = self.pairingCodes[@(device.hash)];
	BOOL isNewPairing = !code.length;
	if (isNewPairing) {
		code = [NSString stringWithFormat:@"%06ld", (long)(arc4random_uniform(1000000))];
		self.pairingCodes[@(device.hash)] = code;
	}
	[self.wirelessChannel sendAuthorizationMessageToDevice:device
	                                                 state:ECOAuthorizeResponseType_AllowAlways
	                                          showAuthAlert:YES
	                                              pairCode:code];
	if (isNewPairing) {
		//用户在弹层里点击设备行触发的重发沿用同一个码，不再重复弹窗
		dispatch_async(dispatch_get_main_queue(), ^{
			[[NSNotificationCenter defaultCenter] postNotificationName:LKUnpairedWirelessDeviceDidArriveNotification object:device];
		});
	}
}

#pragma mark - Ports Connect

- (RACSignal *)tryToConnectAllPorts {
    return [[RACSignal zip:@[[self _tryToConnectAllSimulatorPorts],
                             [self _tryToConnectAllUSBDevices],
							 [self _tryToConnectToAllWirelessDevice]]] map:^id _Nullable(RACTuple * _Nullable value) {
		RACTupleUnpack(NSArray<Lookin_PTChannel *> *simulatorChannels, NSArray<Lookin_PTChannel *> *usbChannels, NSArray<ECOChannelDeviceInfo *> *wirelessDevices) = value;
		NSArray *connectedChannels = [[simulatorChannels arrayByAddingObjectsFromArray:usbChannels] arrayByAddingObjectsFromArray:wirelessDevices];
        return connectedChannels;
    }];
}

/// 返回的 x 为所有已成功链接的 Lookin_PTChannel 数组，该方法不会 sendError:
- (RACSignal *)_tryToConnectAllSimulatorPorts {
    NSArray<RACSignal *> *tries = [self.allSimulatorPorts lookin_map:^id(NSUInteger idx, LKSimulatorConnectionPort *port) {
        return [[self _connectToSimulatorPort:port] catch:^RACSignal * _Nonnull(NSError * _Nonnull error) {
            return [RACSignal return:nil];
        }];
    }];
    return [[RACSignal zip:tries] map:^id _Nullable(RACTuple * _Nullable value) {
        NSArray<Lookin_PTChannel *> *connectedChannels = [value.allObjects lookin_filter:^BOOL(id obj) {
            return (obj != [NSNull null]);
        }];
        return connectedChannels;
    }];
}

/// 返回的 x 为成功链接的 Lookin_PTChannel
/// 注意，如果某个 app 被退到了后台但是没有被 kill，则在这个方法里它的 channel 仍然会被成功连接
- (RACSignal *)_connectToSimulatorPort:(LKSimulatorConnectionPort *)port {
    RACSignal *signal = [RACSignal createSignal:^RACDisposable * _Nullable(id<RACSubscriber>  _Nonnull subscriber) {
        if (port.connectedChannel) {
            // 该 port 本来就已经成功连接
            [subscriber sendNext:port.connectedChannel];
            [subscriber sendCompleted];
            return nil;
        }

        Lookin_PTChannel *localChannel = [Lookin_PTChannel channelWithDelegate:self];
        [localChannel lookin_bindObject:@(LKChannelTransportLocal) forKey:Key_BindingChannelTransport];
        [localChannel connectToPort:port.portNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error, Lookin_PTAddress *address) {
            if (error) {
                if (error.domain == NSPOSIXErrorDomain && (error.code == ECONNREFUSED || error.code == ETIMEDOUT)) {
                    // 没有 iOS 客户端
                } else {
                    // 意外
                }
                [localChannel close];
                [subscriber sendError:error];
            } else {
                port.connectedChannel = localChannel;
                [subscriber sendNext:localChannel];
                [subscriber sendCompleted];
            }
        }];
        return nil;
    }];
    // 个别端口的连接回调可能长时间不返回，超时兜底保证上层 zip 一定能完成，
    // 避免 App 列表因单个端口挂起而整体无法刷新
    return [signal timeout:5 onScheduler:[RACScheduler scheduler]];
}

/// 返回的 x 为所有已成功链接的 Lookin_PTChannel 数组，该方法不会 sendError:
- (RACSignal *)_tryToConnectAllUSBDevices {
    if (!self.allUSBPorts.count) {
        return [RACSignal return:[NSArray array]];
    }
    NSArray<RACSignal *> *tries = [self.allUSBPorts lookin_map:^id(NSUInteger idx, LKUSBConnectionPort *port) {
        return [[self _connectToUSBPort:port] catch:^RACSignal * _Nonnull(NSError * _Nonnull error) {
            // 「连接被拒」已在 _connectToUSBPort 内按会话记录；这里补记其余错误（含 RAC 超时：
            // 锁屏/未信任的设备会让 usbmux 连接回调永不触发，只能靠 5 秒超时兑底）
            if (!(error.domain == Lookin_PTUSBHubErrorDomain && error.code == PTUSBHubErrorConnectionRefused)) {
                NSLog(@"Lookin - USB 端口 %@ 连接未完成（超时或内部错误）：%@, deviceID:%@", @(port.portNumber), error, port.deviceID);
            }
            return [RACSignal return:nil];
        }];
    }];
    return [[RACSignal zip:tries] map:^id _Nullable(RACTuple * _Nullable value) {
        NSArray<Lookin_PTChannel *> *connectedChannels = [value.allObjects lookin_filter:^BOOL(id obj) {
            return (obj != [NSNull null]);
        }];
        return connectedChannels;
    }];
}

/// 返回的 x 为成功链接的 Lookin_PTChannel
- (RACSignal *)_connectToUSBPort:(LKUSBConnectionPort *)port {
    RACSignal *signal = [RACSignal createSignal:^RACDisposable * _Nullable(id<RACSubscriber>  _Nonnull subscriber) {
        if (port.connectedChannel) {
            // 该 port 本来就已经成功连接
            [subscriber sendNext:port.connectedChannel];
            [subscriber sendCompleted];
            return nil;
        }

        Lookin_PTChannel *channel = [Lookin_PTChannel channelWithDelegate:self];
        [channel lookin_bindObject:@(LKChannelTransportUSB) forKey:Key_BindingChannelTransport];
        [channel connectToPort:port.portNumber overUSBHub:Lookin_PTUSBHub.sharedHub deviceID:port.deviceID callback:^(NSError *error) {
            if (error) {
                if (error.domain == Lookin_PTUSBHubErrorDomain && error.code == PTUSBHubErrorConnectionRefused) {
                    // 设备未监听该端口（正常情况：App 只占用 5 个端口中的 1 个，其余端口每轮都会被拒）。
                    // 按 USB 插入会话只提示一次；若所有端口均被拒，说明手机端 App 未运行或 Peertalk 监听已丢失
                    if (!port.hasLoggedConnectRefusal) {
                        port.hasLoggedConnectRefusal = YES;
                        NSLog(@"Lookin - USB 端口 %@ 连接被拒（设备未监听）。若所有端口均被拒，请检查手机端 App 是否在前台运行，deviceID:%@", @(port.portNumber), port.deviceID);
                    }
                } else {
                    // 意外错误在 _tryToConnectAllUSBDevices 的 catch 中统一记录
                }
                [channel close];
                [subscriber sendError:error];
            } else {
                // succ
                NSLog(@"Lookin - USB 端口 %@ 连接成功, deviceID:%@", @(port.portNumber), port.deviceID);
                port.connectedChannel = channel;
                [subscriber sendNext:channel];
                [subscriber sendCompleted];
            }
        }];
        return nil;
    }];
    // 锁屏、未信任或状态异常的 USB 设备可能让 usbmux 的连接回调永不触发，
    // 超时兜底避免它阻塞上层 zip，导致所有端口（含模拟器）的 App 列表都无法刷新
    return [signal timeout:5 onScheduler:[RACScheduler scheduler]];
}

- (RACSignal *)_tryToConnectToAllWirelessDevice {
	void (^work)(void) = ^{
		NSArray *devices = [self.connectWirelessDevices lookin_filter:^BOOL(ECOChannelDeviceInfo *obj) {
			return obj.isConnected;
		}];
		if (devices.count != self.connectWirelessDevices.count) {
			self.connectWirelessDevices = [NSMutableArray arrayWithArray:devices];
		}
	};
	// 可能从 RAC 后台 scheduler 调入，而设备列表的增删均收敛在主线程，这里同步切到主线程读写，
	// 避免与 deviceBlock / authStateChangedBlock 并发改写 NSMutableArray。主线程等待链上不会同步等
	// 待本方法，不会死锁；主线程直接调用时原地执行
	if (NSThread.isMainThread) {
		work();
	} else {
		dispatch_sync(dispatch_get_main_queue(), work);
	}
	NSArray *devices = [self.connectWirelessDevices lookin_filter:^BOOL(ECOChannelDeviceInfo *obj) {
		return obj.isConnected;
	}];
	return [RACSignal return:devices];
}

#pragma mark - Request

- (void)pushWithType:(unsigned int)pushType data:(NSObject *)data channel:(Lookin_PTChannel *)channel {
    if (!channel || !channel.isConnected) {
        return;
    }
    NSError *archiveError = nil;
    dispatch_data_t payload = [[NSKeyedArchiver archivedDataWithRootObject:data requiringSecureCoding:YES error:&archiveError] createReferencingDispatchData];
    if (archiveError) {
        NSAssert(NO, @"");
    }
    NSLog(@"LookinClient - pushData, type:%@", @(pushType));
    [channel sendFrameOfType:pushType tag:0 withPayload:payload callback:nil];
}

- (RACSignal *)requestWithType:(unsigned int)requestType data:(NSObject *)requestData channel:(Lookin_PTChannel *)channel {
    return [RACSignal createSignal:^RACDisposable * _Nullable(id<RACSubscriber>  _Nonnull subscriber) {
        //        NSLog(@"LookinClient, level1 - will ping for request:%@, port:%@", @(type), @(channel.portNumber));
        NSTimeInterval timeoutInterval;
        if (requestType == LookinRequestTypeApp) {
            // 如果某个 iOS app 连接上了 channel 却又处于后台的话，而这个 timeout 时间又过长的话，就会导致初次进入 launch 时非常慢（因为必须等到 timeoutInterval 结束），因此这里为了体验缩小这个时间
            timeoutInterval = .5;
        } else {
            timeoutInterval = 2;
        }
        
        [self _requestWithType:LookinRequestTypePing channel:channel data:nil timeoutInterval:timeoutInterval succ:^(LookinConnectionResponseAttachment *pingResponse) {
            // ping 成功了
            // NSLog(@"LookinClient, level1 - ping succ, will send request:%@, port:%@", @(type), @(channel.portNumber));
            NSError *versionErr = [self _checkServerVersionWithResponse:pingResponse];
            if (versionErr) {
                // LookinServer 版本有问题
                [subscriber sendError:versionErr];
            } else {
                // 没问题，开始发真正请求
                [self _requestWithType:requestType channel:channel data:requestData timeoutInterval:5 succ:^(id responseData) {
                    RACTuple *tupleResult = [RACTuple tupleWithObjects:responseData, channel, nil];
                    [subscriber sendNext:tupleResult];
                } fail:^(NSError *error) {
                    [subscriber sendError:error];
                } completion:^{
                    [subscriber sendCompleted];
                }];
            }

        } fail:^(NSError *error) {
            // ping 失败了
            [subscriber sendError:error];

        } completion:nil];
        return nil;
    }];
}

- (NSError *)_checkServerVersionWithResponse:(LookinConnectionResponseAttachment *)pingResponse {
    int serverVersion = pingResponse.lookinServerVersion;
    if (serverVersion == -1 || serverVersion == 100) {
        // 说明用的还是旧版本的内部版本 LookinServer，这里兼容一下
        NSError *versionErr = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_ServerVersionTooLow userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"Fail to inspect this iOS app due to a version problem.", nil), NSLocalizedRecoverySuggestionErrorKey:NSLocalizedString(@"Please update LookinServer.framework linked with target iOS App to a newer version. Visit the website below to get detailed instructions:\nhttps://lookin.work/faq/server-version-too-low/", nil)}];
        return versionErr;
    }
    
    if (serverVersion > LOOKIN_SUPPORTED_SERVER_MAX) {
        // server 版本过高，需要升级 client
        NSError *versionErr = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_ServerVersionTooHigh userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"Lookin app version is too low.", nil), NSLocalizedRecoverySuggestionErrorKey:NSLocalizedString(@"Target iOS app is linked with a higher version LookinServer.framework. Please click \"Lookin\"-\"Check for Updates\" near the top-left corner or visit https://lookin.work to update your Lookin app.", nil)}];
        return versionErr;
        
    }
    
    if (serverVersion < LOOKIN_SUPPORTED_SERVER_MIN) {
        // server 版本过低，需要升级 server
        NSError *versionErr = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_ServerVersionTooLow userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"Fail to inspect this iOS app due to a version problem.", nil), NSLocalizedRecoverySuggestionErrorKey:NSLocalizedString(@"Please update LookinServer.framework linked with target iOS App to a newer version. Visit the website below to get detailed instructions:\nhttps://lookin.work/faq/server-version-too-low/", nil)}];
        return versionErr;
    }
    
    return nil;
}

#pragma mark - Private

- (void)_requestWithType:(unsigned int)requestType channel:(id<LookinChannelProtocol>)channel data:(NSObject *)data timeoutInterval:(NSTimeInterval)timeoutInterval succ:(void (^)(id data))succBlock fail:(void (^)(NSError *error))failBlock completion:(void (^)(void))completionBlock {
    if (!channel) {
        NSAssert(NO, @"");
        if (failBlock) {
            failBlock(LookinErr_Inner);
        }
        return;
    }
    if (!channel.isConnected) {
        if (failBlock) {
            failBlock(LookinErr_NoConnect);
        }
        return;
    }
	
	ECOChannelDeviceInfo *device;
	Lookin_PTChannel *ptChannel;
	if ([channel isKindOfClass:ECOChannelDeviceInfo.class]) {
		device = (ECOChannelDeviceInfo *)channel;
		if (!NSThread.isMainThread) {
			// 无线通道的请求收发统一收敛到主线程：activeRequests 等可变状态只在主线程读写，
			// 与 receivedBlock / 超时派发（主队列）保持同一执行域，消除并发回调队列带来的竞态
			dispatch_async(dispatch_get_main_queue(), ^{
				[self _requestWithType:requestType channel:channel data:data timeoutInterval:timeoutInterval succ:succBlock fail:failBlock completion:completionBlock];
			});
			return;
		}
	}
	if ([channel isKindOfClass:Lookin_PTChannel.class]) {
		ptChannel = (Lookin_PTChannel *)channel;
	}
	
    if (channel.activeRequests.count && requestType != LookinRequestTypePing) {
        // 检查是否有相同 type 的旧请求尚在进行中，如果有则移除之前的旧请求（旧请求会被报告 error）
        NSSet<LKConnectionRequest *> *requestsToBeDiscarded = [channel.activeRequests lookin_filter:^BOOL(LKConnectionRequest *obj) {
            return (obj.type == requestType);
        }];
        [requestsToBeDiscarded enumerateObjectsUsingBlock:^(LKConnectionRequest * _Nonnull obj, BOOL * _Nonnull stop) {
            if (obj.failBlock) {
                NSError *error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_Discard userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"The request is discarded due to a newer same request.", nil)}];
                obj.failBlock(error);
            }
            [obj endTimeoutCount];
            [channel.activeRequests removeObject:obj];
            
            NSLog(@"LookinClient - will discard request, type:%@, tag:%@", @(obj.type), @(obj.tag));
        }];
    }
    
    LKConnectionRequest *request = [[LKConnectionRequest alloc] init];
    request.type = requestType;
    request.tag = (uint32_t)[[NSDate date] timeIntervalSince1970];
    request.succBlock = succBlock;
    request.failBlock = failBlock;
    request.completionBlock = completionBlock;
    request.timeoutInterval = timeoutInterval;
    @weakify(channel);
    request.timeoutBlock = ^(LKConnectionRequest *selfRequest) {
        @strongify(channel);
        NSError *error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_Timeout userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"Request timeout", nil), NSLocalizedRecoverySuggestionErrorKey:LookinErrorText_Timeout}];
        selfRequest.failBlock(error);
        [channel.activeRequests removeObject:selfRequest];
    };
    
    LookinConnectionAttachment *attachment = [LookinConnectionAttachment new];
    attachment.data = data;
    NSError *archiveError = nil;
	NSData *sendData = [NSKeyedArchiver archivedDataWithRootObject:attachment requiringSecureCoding:YES error:&archiveError];
    dispatch_data_t payload = [sendData createReferencingDispatchData];
    if (archiveError) {
        NSAssert(NO, @"");
    }
	
	if (device) {
		[self.wirelessChannel sendPacket:sendData extraInfo:@{@"tag": @(request.tag), @"type": @(request.type)} toDevice:device];
		if (!device.activeRequests) {
			device.activeRequests = [NSMutableSet set];
		}
		[device.activeRequests addObject:request];
		[request resetTimeoutCount];
	}
	if (ptChannel) {
		[ptChannel sendFrameOfType:requestType tag:request.tag withPayload:payload callback:^(NSError *error) {
			//        NSLog(@"LookinClient - sendRequest, type:%@", @(requestType));
			if (error) {
				if (failBlock) {
					NSError *error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_PeerTalk userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"The operation failed due to an inner error.", nil)}];
					failBlock(error);
				}
			} else {
				// 成功发出了该 request
				if (!channel.activeRequests) {
					channel.activeRequests = [NSMutableSet set];
				}
				[channel.activeRequests addObject:request];
				[request resetTimeoutCount];
			}
		}];
	}
}

- (void)cancelRequestWithType:(unsigned int)requestType channel:(Lookin_PTChannel *)channel {
    LKConnectionRequest *activeRequest = [channel.activeRequests lookin_firstFiltered:^BOOL(LKConnectionRequest *obj) {
        return obj.type == requestType;
    }];
    if (!activeRequest) {
        return;
    }
    [activeRequest endTimeoutCount];
    [channel.activeRequests removeObject:activeRequest];
    if (activeRequest.completionBlock) {
        activeRequest.completionBlock();
    }
    NSLog(@"Lookin - 用户手动取消 request, type:%@", @(requestType));
}

- (void)_startListeningForUSBDevices {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    [nc addObserverForName:Lookin_PTUSBDeviceDidAttachNotification object:Lookin_PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
        NSNumber *deviceID = [note.userInfo objectForKey:@"DeviceID"];
        
        /// 仅一台真机 device 上的所有 app 共享同一批端口（在 Lookin 里是 47175 ~ 47179 这 5 个），不同真机互不影响。比如依次启动“真机 A 的 app1”、“真机 A 的 app2”、“真机 B 的 app3”，则它们依次会占用 47175、47176、47175（注意不是 47177）这几个端口
        for (int number = LookinUSBDeviceIPv4PortNumberStart; number <= LookinUSBDeviceIPv4PortNumberEnd; number++) {
            LKUSBConnectionPort *port = [LKUSBConnectionPort new];
            port.portNumber = number;
            port.deviceID = deviceID;
            [self.allUSBPorts addObject:port];
        }
        NSLog(@"Lookin - USB 设备插入，DeviceID: %@", deviceID);
    }];
    
    [nc addObserverForName:Lookin_PTUSBDeviceDidDetachNotification object:Lookin_PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
        NSNumber *deviceID = [note.userInfo objectForKey:@"DeviceID"];
        [self.allUSBPorts.copy enumerateObjectsUsingBlock:^(LKUSBConnectionPort * _Nonnull port, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([port.deviceID isEqual:deviceID]) {
                [self.allUSBPorts removeObject:port];
            }
        }];
        NSLog(@"Lookin - USB 设备拔出，DeviceID: %@", deviceID);
    }];
}

- (void)_startListeningForWirelessDevices {
	if (!self.wirelessChannel) {
		self.wirelessChannel = ECOChannelManager.new;
	}
	@weakify(self);
	// 接收到数据回调（每个数据包都会进来，不要在这里 NSLog，会刷屏）。
	// 统一派发到主线程：device.activeRequests 与设备列表的读写全部收敛在主线程，
	// 与 deviceBlock / authStateChangedBlock / 超时派发（主队列）同一执行域
	self.wirelessChannel.receivedBlock = ^(ECOChannelDeviceInfo *device, NSData *data, NSDictionary *extraInfo) {
		dispatch_async(dispatch_get_main_queue(), ^{
			NSNumber *tag = extraInfo[@"tag"];
			NSNumber *type = extraInfo[@"type"];
			LKConnectionRequest *activeRequest = [device.activeRequests lookin_firstFiltered:^BOOL(LKConnectionRequest *obj) {
				return [@(obj.type) isEqualToNumber:type] && [@(obj.tag) isEqualToNumber:tag];
			}];
			if (!activeRequest) {
				// 也许在 shouldAcceptFrameOfType 和 didReceiveFrame 两个时机之间，该 request 因为超时而被销毁了？有点玄学但确实偶尔会走到这里。
				return;
			}
			[self_weak_ _didReceiveDataWithChannel:device data:data activeRequest:activeRequest];
		});
	};
	// 设备连接变更：同样收敛到主线程（列表增删与 UI 弹层都由这些回调驱动）
	self.wirelessChannel.deviceBlock = ^(ECOChannelDeviceInfo *device, BOOL isConnected) {
		dispatch_async(dispatch_get_main_queue(), ^{
			NSLog(@"🚀 Lookin deviceBlock device:%@ connected:%@", device, @(isConnected));
			if (isConnected && ![self_weak_.connectWirelessDevices containsObject:device]) {
				if (!device.authorizedType) {
					// 未配对设备连入：加入待配对列表并发起蓝牙式配对（UI 会自动弹出设备列表展示配对码）
					if (![self_weak_.notConnectWirelessDevices containsObject:device]) {
						[self_weak_.notConnectWirelessDevices addObject:device];
					}
					[self_weak_ _beginPairingWithDevice:device];
				} else {
					RACSignal *signal = [self_weak_ _connectToWirelessDevice:device];
					[signal subscribeNext:^(ECOChannelDeviceInfo * _Nullable x) {
						NSLog(@"%@", x);
					}];
				}
			} else if (!isConnected) {
				[self_weak_.notConnectWirelessDevices removeObject:device];
				[self_weak_.connectWirelessDevices removeObject:device];
				[self_weak_.channelWillEnd sendNext:device];
			}
		});
	};
	// 授权状态变更回调
	self.wirelessChannel.authStateChangedBlock = ^(ECOChannelDeviceInfo *device, ECOAuthorizeResponseType authState) {
		dispatch_async(dispatch_get_main_queue(), ^{
			NSLog(@"🚀 Lookin authStateChangedBlock device:%@", device);
			void(^block)(ECOChannelDeviceInfo *device, ECOAuthorizeResponseType authState) = self_weak_.authStateChangedBlocks[@(device.hash)];
			if (block) {
				block(device, authState);
			} else if (authState && ![self_weak_.connectWirelessDevices containsObject:device]) {
				// 手机上确认配对后：直接自动连接（配对的意义就是免二次交互）
				[self_weak_.pairingCodes removeObjectForKey:@(device.hash)];
				[[self_weak_ _connectToWirelessDevice:device] subscribeNext:^(ECOChannelDeviceInfo * _Nullable x) {
					NSLog(@"🚀 Lookin auto connect paired device success. device:%@", x);
				}];
			}
			if (!authState) {
				[self_weak_.pairingCodes removeObjectForKey:@(device.hash)];
				if ([self_weak_.connectWirelessDevices containsObject:device]) {
					[self_weak_.connectWirelessDevices removeObject:device];
					[self_weak_.channelWillEnd sendNext:device];
				}
			}
		});
	};
	// 请求授权状态认证回调
	self.wirelessChannel.requestAuthBlock = ^(ECOChannelDeviceInfo *device, ECOAuthorizeResponseType authState) {
		NSLog(@"🚀 Lookin requestAuthBlock device:%@ authState:%ld", device, authState);
	};
}

- (RACSignal<ECOChannelDeviceInfo *> *)_tryToConnectToWirelessDevice:(ECOChannelDeviceInfo *)device {
	if (!device.isConnected)
		return [RACSignal error:LookinErr_Inner];
	
	if (!device.authorizedType) {
		// 未信任
		@weakify(self);
		RACSignal *signal = [[RACSignal createSignal:^RACDisposable * _Nullable(id<RACSubscriber>  _Nonnull subscriber) {
			self_weak_.authStateChangedBlocks[@(device.hash)] = ^(ECOChannelDeviceInfo *device, ECOAuthorizeResponseType authState) {
				if (authState) {
					[subscriber sendNext:device];
					[subscriber sendCompleted];
                    NSLog(@"🚀 Lookin connect device success. device:%@", device);
				} else {
                    NSError *error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_Inner userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Wireless Connection rejected", nil)}];
                    NSLog(@"🚀 Lookin connect reject. device:%@", device);
                    dispatch_async(dispatch_get_main_queue(),  ^{
                        AlertErrorText(NSLocalizedString(@"Wireless Connections", nil), NSLocalizedString(@"Wireless Connection rejected", nil), CurrentKeyWindow);
                    });
					[subscriber sendError:error];
				}
			};
			return nil;
		}] flattenMap:^__kindof RACSignal * _Nullable(ECOChannelDeviceInfo *device) {
			return [self_weak_ _connectToWirelessDevice:device];
		}];
		[self_weak_ _beginPairingWithDevice:device];
		return signal;
	} else {
		return [self _connectToWirelessDevice:device];
	}
}

- (RACSignal<ECOChannelDeviceInfo *> *)_connectToWirelessDevice:(ECOChannelDeviceInfo *)device {
	if (!device.isConnected)
		return [RACSignal error:LookinErr_Inner];

	if (![self.connectWirelessDevices containsObject:device]) {
		// 已信任
		@weakify(self);
		return [RACSignal createSignal:^RACDisposable * _Nullable(id<RACSubscriber>  _Nonnull subscriber) {
			[self_weak_ _pingWirelessDevice:device attempts:0 subscriber:subscriber];
			return nil;
		}];
	}
	return [RACSignal error:LookinErr_Inner];
}

/// 无线连接刚建立时 App 可能仍在「解锁 → 前台」的过渡中，此时 Ping 会被 server 判定为后台状态。
/// 若把这一次失败当成最终结果，设备再也不会被加入 connectWirelessDevices，Lookin 也无法自动恢复。
/// 因此对后台 / 超时 / 未连接这类瞬时失败做重试，直到 App 真正活跃或 socket 断开。
- (void)_pingWirelessDevice:(ECOChannelDeviceInfo *)device
                   attempts:(NSUInteger)attempts
                 subscriber:(id<RACSubscriber>)subscriber {
	if (!device.isConnected || device.authorizedType == ECOAuthorizeResponseType_Deny) {
		// socket 已断开，或用户刚刚取消配对：不再重试
		[subscriber sendError:LookinErr_NoConnect];
		return;
	}
	if ([self.connectWirelessDevices containsObject:device]) {
		// 并发的另一次握手已经成功
		[subscriber sendNext:device];
		[subscriber sendCompleted];
		return;
	}

	@weakify(self);
	// Ping测试
	[self _requestWithType:LookinRequestTypePing channel:device data:nil timeoutInterval:2 succ:^(LookinConnectionResponseAttachment *pingResponse) {
		@strongify(self);
		// deviceBlock / authStateChangedBlock / 用户点击可能在同一时刻并发发起握手，
		// 两条握手都会走到这里，不判重会把同一设备加两遍，导致 app 列表出现重复的无线条目
		if (![self.connectWirelessDevices containsObject:device]) {
			[self.connectWirelessDevices addObject:device];
		}
		[self.notConnectWirelessDevices removeObject:device];
		[subscriber sendNext:device];
		[subscriber sendCompleted];
	} fail:^(NSError *error) {
		@strongify(self);
		BOOL isTransient = (error.code == LookinErrCode_PingFailForBackgroundState ||
							error.code == LookinErrCode_Timeout ||
							error.code == LookinErrCode_NoConnect);
		if (!isTransient || !device.isConnected || device.authorizedType == ECOAuthorizeResponseType_Deny) {
			[subscriber sendError:error];
			return;
		}
		// 前几次快速重试，之后降低频率，避免熄屏期间过于频繁地唤醒
		NSTimeInterval delay = attempts < 5 ? 1.0 : 3.0;
		NSLog(@"Lookin - wireless device is not ready (%@), retry in %.0fs", error.localizedDescription, delay);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			@strongify(self);
			[self _pingWirelessDevice:device attempts:attempts + 1 subscriber:subscriber];
		});
	} completion:nil];
}

#pragma mark - <Lookin_PTChannelDelegate>

- (BOOL)ioFrameChannel:(Lookin_PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    if ([PushFrameTypeList() containsIndex:type]) {
        return YES;
    }
    
    LKConnectionRequest *activeRequest = [channel.activeRequests lookin_firstFiltered:^BOOL(LKConnectionRequest *obj) {
        return (obj.type == type && obj.tag == tag);
    }];
    if (activeRequest) {
        return YES;
    } else {
        NSLog(@"LookinClient - will refuse, type:%@, tag:%@", @(type), @(tag));
        return NO;
    }
}

- (void)ioFrameChannel:(Lookin_PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(Lookin_PTData*)payload {
    if ([PushFrameTypeList() containsIndex:type]) {
        NSData *data = [NSData dataWithContentsOfDispatchData:payload.dispatchData];
        NSError *unarchiveError = nil;
        NSObject *unarchivedData = [LKHelper lookinUnarchivedObjectFromData:data error:&unarchiveError];
        if (unarchiveError) {
            //        NSAssert(NO, @"");
        }
        
        RACTuple *tuple = [RACTuple tupleWithObjects:channel, @(type), unarchivedData, nil];
        [self.didReceivePush sendNext:tuple];
        return;
    }
    
//    NSLog(@"LookinClient - did receive, port:%@, type:%@, tag:%@", @(channel.portNumber), @(type), @(tag));
    LKConnectionRequest *activeRequest = [channel.activeRequests lookin_firstFiltered:^BOOL(LKConnectionRequest *obj) {
        return (obj.type == type && obj.tag == tag);
    }];
    if (!activeRequest) {
        // 也许在 shouldAcceptFrameOfType 和 didReceiveFrame 两个时机之间，该 request 因为超时而被销毁了？有点玄学但确实偶尔会走到这里。
        return;
    }

    NSData *data = [NSData dataWithContentsOfDispatchData:payload.dispatchData];
    NSError *unarchiveError = nil;
    LookinConnectionResponseAttachment *attachment = [LKHelper lookinUnarchivedObjectFromData:data error:&unarchiveError];
    if (unarchiveError) {
        NSLog(@"Error:%@", unarchiveError);
//        NSAssert(NO, @"");
    }
    
	[self _didReceiveDataWithChannel:channel data:data activeRequest:activeRequest];
}

- (void)_didReceiveDataWithChannel:(id<LookinChannelProtocol>)channel data:(NSData *)data activeRequest:(LKConnectionRequest *)activeRequest {
	NSError *unarchiveError = nil;
	LookinConnectionResponseAttachment *attachment = [LKHelper lookinUnarchivedObjectFromData:data error:&unarchiveError];
	if (unarchiveError) {
//        NSAssert(NO, @"");
	}
	
	if (attachment.appIsInBackground) {
		// app 处于后台模式
		
		[activeRequest endTimeoutCount];
		[channel.activeRequests removeObject:activeRequest];
		
		if (activeRequest.failBlock) {
			NSError *error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_PingFailForBackgroundState userInfo:@{NSLocalizedDescriptionKey:NSLocalizedString(@"The operation failed because target iOS app has entered to the background state.", nil)}];
			activeRequest.failBlock(error);
		}
		
		NSLog(@"Lookin - iOS app 报告自己处于后台，request fail");
		
		return;
	}
	
	if (activeRequest.succBlock) {
		activeRequest.succBlock(attachment);
	}
	
	static NSUInteger dataSize = 0;
	static CFTimeInterval startTime = 0;
	if (activeRequest.receivedDataCount == 0) {
		dataSize = 0;
		startTime = CACurrentMediaTime();
	}
	dataSize += data.length;
	
	BOOL hasReceivedAllResponses = NO;
	if (attachment.dataTotalCount > 0) {
		activeRequest.receivedDataCount += attachment.currentDataCount;
		if (activeRequest.receivedDataCount >= attachment.dataTotalCount) {
			hasReceivedAllResponses = YES;
		}
	} else {
		hasReceivedAllResponses = YES;
	}
	
	if (hasReceivedAllResponses) {
		[activeRequest endTimeoutCount];
		[channel.activeRequests removeObject:activeRequest];
		if (activeRequest.completionBlock) {
			activeRequest.completionBlock();
		}
		
		CFTimeInterval timeDuration = CACurrentMediaTime() - startTime;
		CGFloat totalSize = dataSize / 1024.0 / 1024.0;
		if (totalSize > 0.5) {
			NSMutableString *logString = [[NSMutableString alloc] initWithString:@"Lookin - "];
			[logString appendFormat:@"已收到全部请求 %@ / %@，总耗时:%.2f, 数据总大小:%.2fM", @(activeRequest.receivedDataCount), @(attachment.dataTotalCount), timeDuration, totalSize];
			NSLog(@"%@", logString);
		}
	} else {
		/// 对于多 response 的请求，每收到一次 response 则重置 timeout 倒计时
		[activeRequest resetTimeoutCount];
//        NSLog(@"Lookin - 收到请求 %@ / %@", @(activeRequest.receivedDataCount), @(attachment.dataTotalCount));
	}
}

- (void)ioFrameChannel:(Lookin_PTChannel*)channel didEndWithError:(NSError*)error {
    // iOS 客户端断开
    __block BOOL wasConnected = NO;
    [self.allSimulatorPorts enumerateObjectsUsingBlock:^(LKSimulatorConnectionPort * _Nonnull port, NSUInteger idx, BOOL * _Nonnull stop) {
        if (port.connectedChannel == channel) {
            port.connectedChannel = nil;
            wasConnected = YES;
        }
    }];
    [self.allUSBPorts enumerateObjectsUsingBlock:^(LKUSBConnectionPort * _Nonnull port, NSUInteger idx, BOOL * _Nonnull stop) {
        if (port.connectedChannel == channel) {
            port.connectedChannel = nil;
            wasConnected = YES;
        }
    }];
    if (!wasConnected) {
        // USB 端口被拒时 usbmux 的 onEnd 也会走到这里，但这种通道从未连上、任何业务都没持有它，
        // 不算“断开”。若照常广播，启动页会在手机 App 不在前台（所有 USB 端口被拒）时陷入
        // “fetch → 端口被拒 → didEnd → 立即 refetch” 的死循环，主线程被打满、进度条与缩略图全部卡死
        [channel close];
        return;
    }
    [self.channelWillEnd sendNext:channel];

    [channel close];
}

- (NSMutableDictionary<NSNumber *,NSString *> *)pairingCodes {
	if (!_pairingCodes) {
		_pairingCodes = [NSMutableDictionary dictionary];
	}
	return _pairingCodes;
}

@end
