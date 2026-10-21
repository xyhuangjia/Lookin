//
//  LKUpdateToken.h
//  LookinClient
//
//  Created by huangj on 2026/10/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 递增式取消令牌：异步流程发起时记录 -currentGeneration，回调抵达时用 -isCurrent: 判断是否仍然有效；
/// 断连、手动刷新等任何使旧结果失效的事件调用 -invalidate。
/// LKStaticWindowController 的 hierarchy 拉取与 LKStaticAsyncUpdateManager 的 detail 请求
/// 各持一个实例——两者生命周期不同（整页拉取 vs 批量 detail），但失效语义完全一致，故共用同一实现。
@interface LKUpdateToken : NSObject

/// 当前代数，随每次 -invalidate 自增
@property(nonatomic, readonly) NSUInteger currentGeneration;

/// 使此前发出的所有 generation 失效
- (void)invalidate;

/// 该 generation 是否仍然有效（未被后续 -invalidate 作废）
- (BOOL)isCurrent:(NSUInteger)generation;

@end

NS_ASSUME_NONNULL_END
