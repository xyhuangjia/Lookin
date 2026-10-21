//
//  LKConnectionManager.h
//  Lookin
//
//  Created by Li Kai on 2018/11/2.
//  https://lookin.work
//

#import <Foundation/Foundation.h>
#import "ECOChannelManager.h"
#import "Lookin_PTChannel.h"

@class LKConnectionRequest;

/// app 实际经由的连接通道类型。设备同时以 USB 和 Wi-Fi 接入时，
/// 同一个 app 会在列表中出现多条，需要靠该标识区分
typedef NS_ENUM(NSInteger, LKChannelTransport) {
	/// 模拟器、iOS-on-Mac 等本机回环连接
	LKChannelTransportLocal = 0,
	LKChannelTransportUSB,
	LKChannelTransportWireless,
};

/// 与某个 iOS app 之间的连接通道。USB（PeerTalk）与无线（ECOChannel）两种传输各有一个实现，
/// 调用方只见此 interface，不感知、也不应分支判断具体传输类型
@protocol LKAppChannel <NSObject>

@property (readonly) BOOL isConnected;

/// 来源通道类型（USB / 无线 / 本机回环），创建时由连接层绑定
@property(nonatomic, readonly) LKChannelTransport transport;

@end

/**
 iOS 是 Server 端，macOS 是 Client 端

 **线程契约（interface 的一部分）**：本类对外输出的 RACSignal（tryToConnectAllPorts / requestWithType /
 connectToWireless）以及 channelWillEnd / didReceivePush 两个 subject，其 next / error / completed
 一律在主线程投递——USB（PeerTalk）与无线（GCDAsyncSocket）的回调线程差异由本类内部吸收。
 调用方无需、也不应再自行 dispatch 到主线程。

 - 把 app 退到后台不会 kill 掉 server channel，仍旧会占用着端口（但可能无法执行代码）
 - 把 app kill 掉后，server channel 也会被 kill，端口占用会被释放
 
 - 一台电脑上的所有模拟器里的所有 app 共享同一批端口（在 Lookin 里是 47164 ～ 47169 这 6 个），比如依次启动“模拟器 A 的 app1”、“模拟器 A 的 app2”、“模拟器 B 的 app3”，则它们依次会占用 47164、47165、47166 这几个端口
 - 一台真机上的所有 app 共享同一批端口（在 Lookin 里是 47175 ~ 47179 这 5 个），比如依次启动“真机 A 的 app1”、“真机 A 的 app2”、“真机 B 的 app3”，则它们依次会占用 47175、47176、47175（注意不是 47177）这几个端口
 
 */
@interface LKConnectionManager : NSObject

+ (instancetype)sharedInstance;

/// 尝试连接所有可能的 Simulator、USB 端口与已配对无线设备，data 为数组，内含所有成功连接的
/// channel（id<LKAppChannel>，虽然成功连接但是 app 可能在后台之类的无法执行代码）
/// 该方法不会 sendError
- (RACSignal *)tryToConnectAllPorts;

/// 返回的 data 为 RACTuple<LookinConnectionResponseAttachment *, id<LKAppChannel>>
/// 在调用该方法发请求时，如果已有相同 type 的旧 request 尚未返回结果，则之前的旧 request 会被报告 Error，然后被丢弃
- (RACSignal *)requestWithType:(unsigned int)requestType data:(NSObject *)requestData channel:(id<LKAppChannel>)channel;

- (RACSignal<ECOChannelDeviceInfo *> *)connectToWireless:(ECOChannelDeviceInfo *)device;

- (NSArray<ECOChannelDeviceInfo *> *)getAllWirelessDevices;

/// 该设备当前进行中的配对码（6 位数字），未在配对中返回 nil，供设备行展示「配对码 xxx xxx」
- (NSString *)pairingCodeForDevice:(ECOChannelDeviceInfo *)device;

/// 取消与某设备的配对（双端清除配对记录，下次连接需重新配对）
- (void)unpairDevice:(ECOChannelDeviceInfo *)device;

/// 未配对的无线设备连入时发出（object 为 ECOChannelDeviceInfo），UI 据此自动弹出无线设备列表展示配对码
extern NSString *const LKUnpairedWirelessDeviceDidArriveNotification;

/// 取消先前使用 requestWithType:data:channel: 方法发送的尚未完成的 request，这个 request 会被报告为 completion
- (void)cancelRequestWithType:(unsigned int)requestType channel:(id<LKAppChannel>)channel;

/// 如果发送的消息不需要 server 端回复，则请使用该方法而非 requestWithType:
/// 如果此时 server 端不在前台或处于断点等模式，则 server 端可能无法收到该消息
- (void)pushWithType:(unsigned int)pushType data:(NSObject *)requestData channel:(id<LKAppChannel>)channel;

/// 即将关闭某个 channel，一般是因为 server 端断开（比如 iOS app 被 kill 掉或 USB 被拔掉）。
/// 在主线程投递
@property(nonatomic, strong, readonly) RACSubject *channelWillEnd;

/// 收到了 server 端发送的 push 消息，tuple 分别为 channel, pushType, data。在主线程投递
@property(nonatomic, strong, readonly) RACSubject *didReceivePush;

@end

/// 两种传输类型对 LKAppChannel 的适配。请求簿记（activeRequests）是连接层私有状态，
/// 通过 associated object 绑定在 channel 对象上，不进入公开 interface
@interface Lookin_PTChannel (LKConnection) <LKAppChannel>
@end

@interface ECOChannelDeviceInfo (LKConnection) <LKAppChannel>
@end
