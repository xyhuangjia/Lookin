//
//  LookinDocument.m
//  Lookin
//
//  Created by Li Kai on 2019/6/26.
//  https://lookin.work
//

#import "LookinDocument.h"
#import "LookinHierarchyFile.h"
#import "LKReadWindowController.h"
#import "LKNavigationManager.h"
#import "LKHelper.h"

// 点击 menu 里的 “打开文件” 会走到这里的一系列方法
@implementation LookinDocument

// 显式声明不使用自动保存，避免新版 AppKit 打印 "default value of NO for autosavesInPlace" 警告。
// 默认值即为 NO，此处的返回值不改变现有行为。
// Declare NO explicitly to silence AppKit's default-value warning; behavior is unchanged.
+ (BOOL)autosavesInPlace {
    return NO;
}

- (void)makeWindowControllers {
    LKReadWindowController *wc = [[LKReadWindowController alloc] initWithFile:self.hierarchyFile];
    [self addWindowController:wc];
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError {
    if (!self.hierarchyFile) {
        NSAssert(NO, @"");
        if (outError) {
            *outError = LookinErr_Inner;
        }
        return nil;
    }
    
    if ([typeName isEqualToString:@"com.lookin.lookin"]) {
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.hierarchyFile requiringSecureCoding:YES error:outError];
        return data;
    }
    
    if (outError) {
        *outError = LookinErr_Inner;
    }
    return nil;
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError {    
    NSError *unarchiveError = nil;
    LookinHierarchyFile *hierarchyFile = [LKHelper lookinUnarchivedObjectFromData:data error:&unarchiveError];
    
    if (unarchiveError) {
        if (outError) {
            *outError = unarchiveError;
        }
        return NO;
    }
    
    NSError *verifyError = [LookinHierarchyFile verifyHierarchyFile:hierarchyFile];
    if (verifyError) {
        if (outError) {
            *outError = verifyError;
        }
        return NO;
    }

    self.hierarchyFile = hierarchyFile;
    return YES;
}

@end
