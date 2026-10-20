//
//  LKReloadSingleItemUpdateTaskMaker.m
//  LookinClient
//
//  Created by likai.123 on 2024/3/3.
//  Copyright © 2024 hughkli. All rights reserved.
//

#import "LKReloadSingleItemUpdateTaskMaker.h"
#import "LKStaticAsyncUpdateManager.h"
#import "LKAppsManager.h"
#import "LKVersionComparer.h"

@implementation LKReloadSingleItemUpdateTaskMaker

+ (NSArray<LookinStaticAsyncUpdateTask *> *)makeWithItem:(LookinDisplayItem *)item {
    if (!item || [LKStaticAsyncUpdateManager sharedInstance].isUpdating) {
        NSAssert(NO, @"");
        return nil;
    }
    NSString *serverVersion = [[LKAppsManager sharedInstance] inspectingApp].appInfo.serverReadableVersion;
    BOOL supported = [LKVersionComparer compareWithExpectedVersion:@"1.2.7" realVersion:serverVersion];
    if (!supported) {
        AlertErrorText(NSLocalizedString(@"Operation failed.", nil), NSLocalizedString(@"Please upgrade the LookinServer SDK version in your iOS project to 1.2.7 or higher.", nil), CurrentKeyWindow);
        return nil;
    }
    NSMutableArray<LookinStaticAsyncUpdateTask *> *tasks = [NSMutableArray array];

    if (item.doNotFetchScreenshotReason == LookinFetchScreenshotPermitted) {
        LookinStaticAsyncUpdateTask *task = [self taskFromItem:item];
        task.taskType = LookinStaticAsyncUpdateTaskTypeGroupScreenshot;
        if (task) {
            [tasks addObject:task];
        }

        if (item.isExpandable) {
            LookinStaticAsyncUpdateTask *task2 = [self taskFromItem:item];
            task2.taskType = LookinStaticAsyncUpdateTaskTypeSoloScreenshot;
            if (task2) {
                [tasks addObject:task2];
            }
        }
    } else {
        LookinStaticAsyncUpdateTask *task = [self taskFromItem:item];
        task.taskType = LookinStaticAsyncUpdateTaskTypeNoScreenshot;
        if (task) {
            [tasks addObject:task];
        }
    }
    [tasks firstObject].needBasisVisualInfo = YES;
    return tasks;
}

+ (LookinStaticAsyncUpdateTask *)taskFromItem:(LookinDisplayItem *)item {
    // window 等无 layer 的 item oid 为 0，服务端必然返回 -1，直接跳过
    if (item.layerObject.oid == 0) {
        return nil;
    }
    LookinStaticAsyncUpdateTask *task = [LookinStaticAsyncUpdateTask new];
    task.oid = item.layerObject.oid;
    task.frameSize = item.frame.size;
    task.clientReadableVersion = [LKHelper lookinReadableVersion];
    return task;
}

@end
