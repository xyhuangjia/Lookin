//
//  LKInspectionRequestGate.m
//  Lookin
//

#import "LKInspectionRequestGate.h"
#import <os/lock.h>

@interface LKInspectionRequestGate ()

@property(nonatomic, assign) NSUInteger operationCount;
@property(nonatomic, assign) os_unfair_lock gateLock;

@end

@implementation LKInspectionRequestGate

+ (instancetype)sharedGate {
    static dispatch_once_t onceToken;
    static LKInspectionRequestGate *instance = nil;
    dispatch_once(&onceToken, ^{
        instance = [[super allocWithZone:NULL] init];
    });
    return instance;
}

+ (id)allocWithZone:(struct _NSZone *)zone {
    return [self sharedGate];
}

- (instancetype)init {
    if (self = [super init]) {
        _gateLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (BOOL)mcpBusy {
    os_unfair_lock_lock(&_gateLock);
    BOOL busy = self.operationCount > 0;
    os_unfair_lock_unlock(&_gateLock);
    return busy;
}

- (void)beginMCPOperation {
    os_unfair_lock_lock(&_gateLock);
    self.operationCount += 1;
    os_unfair_lock_unlock(&_gateLock);
}

- (void)endMCPOperation {
    os_unfair_lock_lock(&_gateLock);
    if (self.operationCount > 0) {
        self.operationCount -= 1;
    }
    os_unfair_lock_unlock(&_gateLock);
}

@end
