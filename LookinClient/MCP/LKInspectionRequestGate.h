//
//  LKInspectionRequestGate.h
//  Lookin
//
//  MCP 与 UI 共用同一个 PeerTalk channel。LookinServer 对同类型请求
//  只保留最新一个，因此 MCP 执行 detail / screenshot / modification
//  期间需要让 UI 的自动刷新暂时让路，避免互相取消。
//

#import <Foundation/Foundation.h>

@interface LKInspectionRequestGate : NSObject

+ (instancetype)sharedGate;

/// 当前是否有 MCP 操作正在使用 channel
@property(nonatomic, assign, readonly) BOOL mcpBusy;

/// MCP tool 调用前后成对调用
- (void)beginMCPOperation;
- (void)endMCPOperation;

@end
