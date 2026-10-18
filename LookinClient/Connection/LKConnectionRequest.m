//
//  LKConnectionRequest.m
//  Lookin
//
//  Created by Li Kai on 2019/6/24.
//  https://lookin.work
//

#import "LKConnectionRequest.h"

@interface LKConnectionRequest ()

/// 每次 reset / end / 触发超时都会自增，使旧的 dispatch_after 失效
@property(nonatomic, assign) NSUInteger timeoutToken;

@end

@implementation LKConnectionRequest

- (void)resetTimeoutCount {
    [self endTimeoutCount];
    if (self.timeoutInterval > 0) {
        __weak typeof(self) weakSelf = self;
        NSUInteger token;
        @synchronized (self) {
            self.timeoutToken += 1;
            token = self.timeoutToken;
        }
        // 无线连接的 response 回调来自 GCD 队列（没有 runloop），不能用 performSelector:afterDelay:，
        // 否则后台线程的重置无法推迟主线程上已排定的超时，长传输会在 5s 处被误杀
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.timeoutInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            BOOL shouldFire = NO;
            @synchronized (strongSelf) {
                shouldFire = (strongSelf.timeoutToken == token);
                if (shouldFire) {
                    strongSelf.timeoutToken += 1;
                }
            }
            if (shouldFire) {
                [strongSelf _handleTimeout];
            }
        });
    } else {
        NSAssert(NO, @"timeoutInterval 为 0");
    }
}

- (void)endTimeoutCount {
    @synchronized (self) {
        self.timeoutToken += 1;
    }
}

- (void)_handleTimeout {
    if (self.timeoutBlock) {
        self.timeoutBlock(self);
    }
}

@end
