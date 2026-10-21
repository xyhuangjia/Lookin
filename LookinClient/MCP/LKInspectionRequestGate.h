//
//  LKInspectionRequestGate.h
//  Lookin
//
//  MCP 与 UI 共用同一个 channel。LookinServer 对同类型请求只保留最新一个，
//  因此并发访问需要协调。完整的协调协议（policy 的唯一文字归属）：
//
//  1. 占用声明：MCP 每次工具调用前后成对调用 beginMCPOperation / endMCPOperation；
//  2. 让路：UI 在发起 detail 请求前用 -uiMaySendDetailRequest 查询，MCP 忙碌时以 0.1s
//     间隔重试（见 LKStaticAsyncUpdateManager -sendTasks:）；
//  3. 取消在途：MCP 发请求前先取消 UI 在途的 detail 请求（endUpdating），并对服务端
//     返回的 Discard(-406) 错误做一次退避重试（见 LKMCPService -fetchDetails / -awaitSignalWithRetry）。
//

#import <Foundation/Foundation.h>

@interface LKInspectionRequestGate : NSObject

+ (instancetype)sharedGate;

/// 当前是否有 MCP 操作正在使用 channel
@property(nonatomic, assign, readonly) BOOL mcpBusy;

/// UI 发起 detail 请求前查询：MCP 空闲时为 YES；为 NO 时调用方应稍后（建议 0.1s）重试
- (BOOL)uiMaySendDetailRequest;

/// MCP tool 调用前后成对调用
- (void)beginMCPOperation;
- (void)endMCPOperation;

@end
