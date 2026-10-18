#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <netinet/in.h>

#import "LookinAppInfo.h"
#import "LookinAttribute.h"
#import "LookinAttributeModification.h"
#import "LookinAttributesGroup.h"
#import "LookinAttributesSection.h"
#import "LookinAutoLayoutConstraint.h"
#import "LookinConnectionAttachment.h"
#import "LookinConnectionResponseAttachment.h"
#import "LookinCustomAttrModification.h"
#import "LookinDefines.h"
#import "LookinDisplayItem.h"
#import "LookinDisplayItemDetail.h"
#import "LookinEventHandler.h"
#import "LookinHierarchyInfo.h"
#import "LookinIvarTrace.h"
#import "LookinObject.h"
#import "LookinStaticAsyncUpdateTask.h"
#import "LookinTuple.h"
#import "Lookin_PTChannel.h"
#import "Lookin_PTProtocol.h"
#import "Lookin_PTUSBHub.h"

static NSString *LKCVersion = @"0.2.0";
static NSString *LKCClientReadableVersion = @"1.0.7";

@class LKCConnectedApp;
static NSString *LKCAppSerial(LKCConnectedApp *app);

static BOOL LKCDebugEnabled(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        enabled = [[[NSProcessInfo processInfo] environment][@"LOOKINCTL_DEBUG"] boolValue];
    });
    return enabled;
}

static void LKCDebug(NSString *format, ...) {
    if (!LKCDebugEnabled()) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "[lookinctl] %s\n", message.UTF8String);
}

@interface LKCResponse : NSObject
@property(nonatomic, strong) id data;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, assign) BOOL done;
@property(nonatomic, assign) NSUInteger receivedDataCount;
@property(nonatomic, strong) NSMutableArray *chunks;
@end

@implementation LKCResponse
@end

@interface LKCConnectedApp : NSObject
@property(nonatomic, strong) LookinAppInfo *appInfo;
@property(nonatomic, strong) Lookin_PTChannel *channel;
@property(nonatomic, copy) NSString *transport;
@property(nonatomic, assign) NSInteger port;
@property(nonatomic, strong) NSNumber *deviceID;
@end

@implementation LKCConnectedApp
@end

@interface LKCClient : NSObject <Lookin_PTChannelDelegate>
@property(nonatomic, strong) NSMutableDictionary<NSString *, LKCResponse *> *activeResponses;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *usbDeviceIDs;
- (NSArray<LKCConnectedApp *> *)discoverAppsWithImages:(BOOL)needImages wait:(NSTimeInterval)wait timeout:(NSTimeInterval)timeout;
- (LKCConnectedApp *)findAppWithSelector:(NSString *)selector wait:(NSTimeInterval)wait timeout:(NSTimeInterval)timeout;
- (LKCResponse *)requestType:(uint32_t)type data:(id)data channel:(Lookin_PTChannel *)channel timeout:(NSTimeInterval)timeout pingFirst:(BOOL)pingFirst;
- (NSError *)pushType:(uint32_t)type data:(id)data channel:(Lookin_PTChannel *)channel timeout:(NSTimeInterval)timeout;
@end

@implementation LKCClient

- (instancetype)init {
    if (self = [super init]) {
        _activeResponses = [NSMutableDictionary dictionary];
        _usbDeviceIDs = [NSMutableArray array];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(handleUSBDeviceAttach:) name:Lookin_PTUSBDeviceDidAttachNotification object:nil];
        [center addObserver:self selector:@selector(handleUSBDeviceDetach:) name:Lookin_PTUSBDeviceDidDetachNotification object:nil];
    }
    return self;
}

- (void)handleUSBDeviceAttach:(NSNotification *)note {
    NSNumber *deviceID = note.userInfo[@"DeviceID"];
    if (deviceID && ![self.usbDeviceIDs containsObject:deviceID]) {
        [self.usbDeviceIDs addObject:deviceID];
    }
}

- (void)handleUSBDeviceDetach:(NSNotification *)note {
    NSNumber *deviceID = note.userInfo[@"DeviceID"];
    if (deviceID) {
        [self.usbDeviceIDs removeObject:deviceID];
    }
}

- (NSArray<LKCConnectedApp *> *)discoverAppsWithImages:(BOOL)needImages wait:(NSTimeInterval)wait timeout:(NSTimeInterval)timeout {
    [Lookin_PTUSBHub sharedHub];
    NSDate *usbDeadline = [NSDate dateWithTimeIntervalSinceNow:wait];
    while ([[NSDate date] compare:usbDeadline] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    NSMutableArray<LKCConnectedApp *> *apps = [NSMutableArray array];
    NSDictionary *params = @{@"needImages": @(needImages), @"local": @[]};

    for (int port = LookinSimulatorIPv4PortNumberStart; port <= LookinSimulatorIPv4PortNumberEnd; port++) {
        LKCConnectedApp *app = [self tryConnectPort:port deviceID:nil transport:@"simulator" appParams:params timeout:timeout];
        if (app) {
            [apps addObject:app];
        }
    }

    NSArray<NSNumber *> *deviceIDs = self.usbDeviceIDs.copy;
    for (NSNumber *deviceID in deviceIDs) {
        for (int port = LookinUSBDeviceIPv4PortNumberStart; port <= LookinUSBDeviceIPv4PortNumberEnd; port++) {
            LKCConnectedApp *app = [self tryConnectPort:port deviceID:deviceID transport:@"usb" appParams:params timeout:timeout];
            if (app) {
                [apps addObject:app];
            }
        }
    }

    return apps.copy;
}

- (LKCConnectedApp *)findAppWithSelector:(NSString *)selector wait:(NSTimeInterval)wait timeout:(NSTimeInterval)timeout {
    [Lookin_PTUSBHub sharedHub];
    NSDate *usbDeadline = [NSDate dateWithTimeIntervalSinceNow:wait];
    while ([[NSDate date] compare:usbDeadline] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    NSString *trimmedSelector = [selector stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    __block NSUInteger matchedIndex = 0;
    BOOL (^matches)(LKCConnectedApp *) = ^BOOL(LKCConnectedApp *app) {
        if (!app) {
            return NO;
        }
        NSUInteger currentIndex = matchedIndex++;
        if (!trimmedSelector.length) {
            return YES;
        }
        if ([trimmedSelector isEqualToString:[NSString stringWithFormat:@"%lu", (unsigned long)currentIndex]]) {
            return YES;
        }
        if ([trimmedSelector isEqualToString:LKCAppSerial(app)]) {
            return YES;
        }
        NSString *shortSerial = [NSString stringWithFormat:@"%@:%ld", app.transport, (long)app.port];
        if ([trimmedSelector isEqualToString:shortSerial]) {
            return YES;
        }
        if ([trimmedSelector isEqualToString:app.appInfo.appBundleIdentifier]) {
            return YES;
        }
        if ([trimmedSelector isEqualToString:app.appInfo.appName]) {
            return YES;
        }
        return NO;
    };

    NSDictionary *params = @{@"needImages": @NO, @"local": @[]};

    for (int port = LookinSimulatorIPv4PortNumberStart; port <= LookinSimulatorIPv4PortNumberEnd; port++) {
        LKCConnectedApp *app = [self tryConnectPort:port deviceID:nil transport:@"simulator" appParams:params timeout:timeout];
        if (matches(app)) {
            return app;
        }
        [app.channel close];
    }

    NSArray<NSNumber *> *deviceIDs = self.usbDeviceIDs.copy;
    for (NSNumber *deviceID in deviceIDs) {
        for (int port = LookinUSBDeviceIPv4PortNumberStart; port <= LookinUSBDeviceIPv4PortNumberEnd; port++) {
            LKCConnectedApp *app = [self tryConnectPort:port deviceID:deviceID transport:@"usb" appParams:params timeout:timeout];
            if (matches(app)) {
                return app;
            }
            [app.channel close];
        }
    }

    return nil;
}

- (LKCConnectedApp *)tryConnectPort:(int)port deviceID:(NSNumber *)deviceID transport:(NSString *)transport appParams:(NSDictionary *)params timeout:(NSTimeInterval)timeout {
    Lookin_PTChannel *channel = [Lookin_PTChannel channelWithDelegate:self];
    __block BOOL finished = NO;
    __block NSError *connectError = nil;

    if (deviceID) {
        LKCDebug(@"connect usb device=%@ port=%d", deviceID, port);
        [channel connectToPort:port overUSBHub:Lookin_PTUSBHub.sharedHub deviceID:deviceID callback:^(NSError *error) {
            connectError = error;
            finished = YES;
        }];
    } else {
        LKCDebug(@"connect simulator port=%d", port);
        [channel connectToPort:port IPv4Address:INADDR_LOOPBACK callback:^(NSError *error, Lookin_PTAddress *address) {
            connectError = error;
            finished = YES;
        }];
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!finished && [[NSDate date] compare:deadline] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    if (!finished || connectError || !channel.isConnected) {
        if (connectError && LKCDebugEnabled()) {
            LKCDebug(@"connect failed %@:%d %@", transport, port, connectError);
        }
        [channel close];
        return nil;
    }

    LKCResponse *response = [self requestType:LookinRequestTypeApp data:params channel:channel timeout:timeout pingFirst:YES];
    if (response.error || ![response.data isKindOfClass:[LookinAppInfo class]]) {
        if (response.error && LKCDebugEnabled()) {
            LKCDebug(@"app request failed %@:%d %@", transport, port, response.error);
        }
        [channel close];
        return nil;
    }

    LKCConnectedApp *app = [LKCConnectedApp new];
    app.channel = channel;
    app.appInfo = response.data;
    app.transport = transport;
    app.port = port;
    app.deviceID = deviceID;
    return app;
}

- (LKCResponse *)requestType:(uint32_t)type data:(id)data channel:(Lookin_PTChannel *)channel timeout:(NSTimeInterval)timeout pingFirst:(BOOL)pingFirst {
    LKCDebug(@"request type=%u pingFirst=%@", type, pingFirst ? @"YES" : @"NO");
    if (pingFirst && type != LookinRequestTypePing) {
        LKCResponse *ping = [self requestType:LookinRequestTypePing data:nil channel:channel timeout:MIN(timeout, 0.8) pingFirst:NO];
        if (ping.error) {
            return ping;
        }
        if ([ping.data isKindOfClass:[LookinConnectionResponseAttachment class]]) {
            LookinConnectionResponseAttachment *attachment = ping.data;
            if (attachment.lookinServerVersion < LOOKIN_SUPPORTED_SERVER_MIN || attachment.lookinServerVersion > LOOKIN_SUPPORTED_SERVER_MAX) {
                LKCResponse *versionResponse = [LKCResponse new];
                versionResponse.done = YES;
                NSString *message = [NSString stringWithFormat:@"Unsupported LookinServer protocol version %d. Supported range: %d...%d", attachment.lookinServerVersion, LOOKIN_SUPPORTED_SERVER_MIN, LOOKIN_SUPPORTED_SERVER_MAX];
                versionResponse.error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_ServerVersionTooHigh userInfo:@{NSLocalizedDescriptionKey: message}];
                return versionResponse;
            }
        }
    }

    LKCResponse *response = [LKCResponse new];
    uint32_t tag = [self nextTag];
    NSString *key = [self keyForType:type tag:tag];
    self.activeResponses[key] = response;

    LookinConnectionAttachment *attachment = [LookinConnectionAttachment new];
    attachment.data = data;
    NSError *archiveError = nil;
    NSData *payloadData = [NSKeyedArchiver archivedDataWithRootObject:attachment requiringSecureCoding:YES error:&archiveError];
    if (archiveError) {
        response.error = archiveError;
        response.done = YES;
        [self.activeResponses removeObjectForKey:key];
        return response;
    }

    dispatch_data_t payload = [payloadData createReferencingDispatchData];
    [channel sendFrameOfType:type tag:tag withPayload:payload callback:^(NSError *error) {
        if (error) {
            LKCDebug(@"send failed type=%u tag=%u %@", type, tag, error);
            LKCResponse *active = self.activeResponses[key];
            active.error = error;
            active.done = YES;
            [self.activeResponses removeObjectForKey:key];
        }
    }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!response.done && [[NSDate date] compare:deadline] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    if (!response.done) {
        response.done = YES;
        response.error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_Timeout userInfo:@{NSLocalizedDescriptionKey: @"Request timeout"}];
        [self.activeResponses removeObjectForKey:key];
    }
    return response;
}

- (NSError *)pushType:(uint32_t)type data:(id)data channel:(Lookin_PTChannel *)channel timeout:(NSTimeInterval)timeout {
    LookinConnectionAttachment *attachment = [LookinConnectionAttachment new];
    attachment.data = data;
    NSError *archiveError = nil;
    NSData *payloadData = [NSKeyedArchiver archivedDataWithRootObject:attachment requiringSecureCoding:YES error:&archiveError];
    if (archiveError) {
        return archiveError;
    }

    __block BOOL finished = NO;
    __block NSError *sendError = nil;
    dispatch_data_t payload = [payloadData createReferencingDispatchData];
    [channel sendFrameOfType:type tag:0 withPayload:payload callback:^(NSError *error) {
        sendError = error;
        finished = YES;
    }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!finished && [[NSDate date] compare:deadline] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    if (!finished) {
        return [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_Timeout userInfo:@{NSLocalizedDescriptionKey: @"Push timeout"}];
    }
    return sendError;
}

- (uint32_t)nextTag {
    static uint32_t tag = 0;
    if (tag == 0) {
        tag = (uint32_t)[[NSDate date] timeIntervalSince1970];
    }
    return ++tag;
}

- (NSString *)keyForType:(uint32_t)type tag:(uint32_t)tag {
    return [NSString stringWithFormat:@"%u-%u", type, tag];
}

- (BOOL)ioFrameChannel:(Lookin_PTChannel *)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    return self.activeResponses[[self keyForType:type tag:tag]] != nil;
}

- (void)ioFrameChannel:(Lookin_PTChannel *)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(Lookin_PTData *)payload {
    LKCDebug(@"receive type=%u tag=%u payload=%zu", type, tag, payload.length);
    NSString *key = [self keyForType:type tag:tag];
    LKCResponse *response = self.activeResponses[key];
    if (!response) {
        return;
    }

    NSData *data = [NSData dataWithContentsOfDispatchData:payload.dispatchData];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    LookinConnectionResponseAttachment *attachment = [NSKeyedUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
    if (![attachment isKindOfClass:[LookinConnectionResponseAttachment class]]) {
        response.error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_Inner userInfo:@{NSLocalizedDescriptionKey: @"Failed to decode response"}];
        response.done = YES;
        [self.activeResponses removeObjectForKey:key];
        return;
    }

    if (attachment.appIsInBackground) {
        response.error = [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_PingFailForBackgroundState userInfo:@{NSLocalizedDescriptionKey: @"Target app is in background"}];
        response.done = YES;
        [self.activeResponses removeObjectForKey:key];
        return;
    }

    if (attachment.error) {
        response.error = attachment.error;
        response.done = YES;
        [self.activeResponses removeObjectForKey:key];
        return;
    }

    if (type == LookinRequestTypePing) {
        response.data = attachment;
    } else if (attachment.dataTotalCount > 0) {
        if (!response.chunks) {
            response.chunks = [NSMutableArray array];
        }
        if ([attachment.data isKindOfClass:[NSArray class]]) {
            [response.chunks addObjectsFromArray:attachment.data];
        } else if (attachment.data) {
            [response.chunks addObject:attachment.data];
        }
        response.data = response.chunks.copy;
    } else {
        response.data = attachment.data;
    }

    if (attachment.dataTotalCount > 0) {
        response.receivedDataCount += attachment.currentDataCount;
        if (response.receivedDataCount >= attachment.dataTotalCount) {
            response.done = YES;
            [self.activeResponses removeObjectForKey:key];
        }
    } else {
        response.done = YES;
        [self.activeResponses removeObjectForKey:key];
    }
}

- (void)ioFrameChannel:(Lookin_PTChannel *)channel didEndWithError:(NSError *)error {
    LKCDebug(@"channel ended %@", error);
    for (NSString *key in self.activeResponses.allKeys) {
        LKCResponse *response = self.activeResponses[key];
        response.error = error ?: [NSError errorWithDomain:LookinErrorDomain code:LookinErrCode_NoConnect userInfo:@{NSLocalizedDescriptionKey: @"Connection closed"}];
        response.done = YES;
    }
    [self.activeResponses removeAllObjects];
}

@end

static NSString *LKCString(id value) {
    if (!value || value == [NSNull null]) {
        return @"";
    }
    return [value description] ?: @"";
}

static NSString *LKCAppSerial(LKCConnectedApp *app) {
    if ([app.transport isEqualToString:@"usb"]) {
        return [NSString stringWithFormat:@"usb:%@:%ld", app.deviceID ?: @0, (long)app.port];
    }
    return [NSString stringWithFormat:@"simulator:%ld", (long)app.port];
}

static NSString *LKCObjectClassName(LookinObject *object) {
    if (!object) {
        return @"";
    }
    NSString *raw = [object rawClassName];
    if (raw.length) {
        return raw;
    }
    return object.classChainList.firstObject ?: @"";
}

static NSString *LKCItemTitle(LookinDisplayItem *item) {
    if (item.customInfo.title.length) {
        return item.customInfo.title;
    }
    if (item.customDisplayTitle.length) {
        return item.customDisplayTitle;
    }
    NSString *viewName = LKCObjectClassName(item.viewObject);
    if (viewName.length) {
        return viewName;
    }
    NSString *layerName = LKCObjectClassName(item.layerObject);
    if (layerName.length) {
        return layerName;
    }
    return @"<unknown>";
}

static NSArray<LookinDisplayItem *> *LKCFlatItems(NSArray<LookinDisplayItem *> *items) {
    NSMutableArray<LookinDisplayItem *> *flat = [NSMutableArray array];
    for (LookinDisplayItem *item in items) {
        [flat addObject:item];
        [flat addObjectsFromArray:LKCFlatItems(item.subitems)];
    }
    return flat.copy;
}

static NSString *LKCAttrTypeName(LookinAttrType type) {
    switch (type) {
        case LookinAttrTypeNone: return @"none";
        case LookinAttrTypeVoid: return @"void";
        case LookinAttrTypeChar: return @"char";
        case LookinAttrTypeInt: return @"int";
        case LookinAttrTypeShort: return @"short";
        case LookinAttrTypeLong: return @"long";
        case LookinAttrTypeLongLong: return @"longLong";
        case LookinAttrTypeUnsignedChar: return @"unsignedChar";
        case LookinAttrTypeUnsignedInt: return @"unsignedInt";
        case LookinAttrTypeUnsignedShort: return @"unsignedShort";
        case LookinAttrTypeUnsignedLong: return @"unsignedLong";
        case LookinAttrTypeUnsignedLongLong: return @"unsignedLongLong";
        case LookinAttrTypeFloat: return @"float";
        case LookinAttrTypeDouble: return @"double";
        case LookinAttrTypeBOOL: return @"bool";
        case LookinAttrTypeSel: return @"selector";
        case LookinAttrTypeClass: return @"class";
        case LookinAttrTypeCGPoint: return @"point";
        case LookinAttrTypeCGVector: return @"vector";
        case LookinAttrTypeCGSize: return @"size";
        case LookinAttrTypeCGRect: return @"rect";
        case LookinAttrTypeCGAffineTransform: return @"affineTransform";
        case LookinAttrTypeUIEdgeInsets: return @"edgeInsets";
        case LookinAttrTypeUIOffset: return @"offset";
        case LookinAttrTypeNSString: return @"string";
        case LookinAttrTypeEnumInt: return @"enumInt";
        case LookinAttrTypeEnumLong: return @"enumLong";
        case LookinAttrTypeUIColor: return @"color";
        case LookinAttrTypeCustomObj: return @"customObject";
        case LookinAttrTypeEnumString: return @"enumString";
        case LookinAttrTypeShadow: return @"shadow";
        case LookinAttrTypeJson: return @"json";
    }
}

static id LKCJSONObject(id object);
static NSDictionary *LKCObjectJSON(LookinObject *object);
static NSDictionary *LKCItemJSON(LookinDisplayItem *item, NSUInteger depth, NSUInteger maxDepth);
static NSDictionary *LKCDetailJSON(LookinDisplayItemDetail *detail);
static NSArray<NSDictionary *> *LKCCurrentViewControllersJSON(NSArray<LookinDisplayItem *> *items);
static LookinStaticAsyncUpdateTask *LKCTaskForOid(unsigned long oid, LookinStaticAsyncUpdateTaskType screenshotType, LookinDetailUpdateTaskAttrRequest attrRequest, BOOL basis, BOOL subitems);
static NSDictionary *LKCItemSummaryJSON(LookinDisplayItem *item, CGRect absoluteFrame);

static NSDictionary *LKCAppInfoJSON(LKCConnectedApp *app, NSUInteger index) {
    LookinAppInfo *info = app.appInfo;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"index"] = @(index);
    dict[@"serial"] = LKCAppSerial(app);
    dict[@"name"] = LKCString(info.appName);
    dict[@"bundle"] = LKCString(info.appBundleIdentifier);
    dict[@"device"] = LKCString(info.deviceDescription);
    dict[@"os"] = LKCString(info.osDescription);
    dict[@"transport"] = LKCString(app.transport);
    dict[@"port"] = @(app.port);
    if (app.deviceID) {
        dict[@"deviceID"] = app.deviceID;
    }
    dict[@"screen"] = @{@"width": @(info.screenWidth), @"height": @(info.screenHeight), @"scale": @(info.screenScale)};
    dict[@"serverVersion"] = @(info.serverVersion);
    dict[@"serverReadableVersion"] = LKCString(info.serverReadableVersion);
    dict[@"swiftEnabledInLookinServer"] = @(info.swiftEnabledInLookinServer);
    return dict.copy;
}

static NSDictionary *LKCIvarTraceJSON(LookinIvarTrace *trace) {
    return @{
        @"relation": LKCString(trace.relation),
        @"hostClass": LKCString(trace.hostClassName),
        @"ivar": LKCString(trace.ivarName)
    };
}

static NSDictionary *LKCObjectJSON(LookinObject *object) {
    if (!object) {
        return @{};
    }
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"oid"] = @(object.oid);
    dict[@"class"] = LKCObjectClassName(object);
    dict[@"address"] = LKCString(object.memoryAddress);
    if (object.specialTrace.length) {
        dict[@"trace"] = object.specialTrace;
    }
    if (object.classChainList.count) {
        dict[@"classChain"] = object.classChainList;
    }
    if (object.ivarTraces.count) {
        NSMutableArray *traces = [NSMutableArray arrayWithCapacity:object.ivarTraces.count];
        for (LookinIvarTrace *trace in object.ivarTraces) {
            [traces addObject:LKCIvarTraceJSON(trace)];
        }
        dict[@"ivarTraces"] = traces.copy;
    }
    return dict.copy;
}

static NSDictionary *LKCImageJSON(NSImage *image) {
    if (!image) {
        return @{};
    }
    NSData *tiff = image.TIFFRepresentation;
    return @{
        @"width": @(image.size.width),
        @"height": @(image.size.height),
        @"bytes": @(tiff.length)
    };
}

static NSData *LKCPNGDataFromImage(NSImage *image) {
    if (!image) {
        return nil;
    }
    NSRect rect = NSMakeRect(0, 0, image.size.width, image.size.height);
    CGImageRef cgImage = [image CGImageForProposedRect:&rect context:nil hints:nil];
    if (cgImage) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
        return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    }
    NSData *tiff = image.TIFFRepresentation;
    if (!tiff.length) {
        return nil;
    }
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] ?: tiff;
}

static int LKCWriteImage(NSImage *image, NSString *outputPath) {
    NSData *data = LKCPNGDataFromImage(image);
    if (!data.length) {
        fprintf(stderr, "Screenshot failed: empty image.\n");
        return 1;
    }
    if (outputPath.length) {
        NSString *path = outputPath.stringByStandardizingPath;
        if (![data writeToFile:path atomically:YES]) {
            fprintf(stderr, "Failed to write %s\n", path.UTF8String);
            return 2;
        }
    } else {
        fwrite(data.bytes, 1, data.length, stdout);
    }
    return 0;
}

static NSDictionary *LKCValueJSON(NSValue *value) {
    if (!value) {
        return @{};
    }
    const char *type = value.objCType;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"objcType"] = [NSString stringWithUTF8String:type ?: ""];

    if (strcmp(type, @encode(CGPoint)) == 0 || strcmp(type, @encode(NSPoint)) == 0) {
        NSPoint point = value.pointValue;
        dict[@"x"] = @(point.x);
        dict[@"y"] = @(point.y);
        dict[@"kind"] = @"point";
    } else if (strcmp(type, @encode(CGSize)) == 0 || strcmp(type, @encode(NSSize)) == 0) {
        NSSize size = value.sizeValue;
        dict[@"width"] = @(size.width);
        dict[@"height"] = @(size.height);
        dict[@"kind"] = @"size";
    } else if (strcmp(type, @encode(CGRect)) == 0 || strcmp(type, @encode(NSRect)) == 0) {
        NSRect rect = value.rectValue;
        dict[@"x"] = @(rect.origin.x);
        dict[@"y"] = @(rect.origin.y);
        dict[@"width"] = @(rect.size.width);
        dict[@"height"] = @(rect.size.height);
        dict[@"kind"] = @"rect";
    } else if (strcmp(type, @encode(NSEdgeInsets)) == 0) {
        NSEdgeInsets insets = value.edgeInsetsValue;
        dict[@"top"] = @(insets.top);
        dict[@"left"] = @(insets.left);
        dict[@"bottom"] = @(insets.bottom);
        dict[@"right"] = @(insets.right);
        dict[@"kind"] = @"edgeInsets";
    } else if (strcmp(type, @encode(CGAffineTransform)) == 0) {
        CGAffineTransform transform;
        [value getValue:&transform];
        dict[@"a"] = @(transform.a);
        dict[@"b"] = @(transform.b);
        dict[@"c"] = @(transform.c);
        dict[@"d"] = @(transform.d);
        dict[@"tx"] = @(transform.tx);
        dict[@"ty"] = @(transform.ty);
        dict[@"kind"] = @"affineTransform";
    } else if (strcmp(type, @encode(CGVector)) == 0) {
        CGVector vector;
        [value getValue:&vector];
        dict[@"dx"] = @(vector.dx);
        dict[@"dy"] = @(vector.dy);
        dict[@"kind"] = @"vector";
    } else {
        dict[@"description"] = value.description ?: @"";
    }
    return dict.copy;
}

static NSDictionary *LKCTupleJSON(LookinStringTwoTuple *tuple) {
    return @{@"first": LKCString(tuple.first), @"second": LKCString(tuple.second)};
}

static NSDictionary *LKCEventHandlerJSON(LookinEventHandler *handler) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"type"] = handler.handlerType == LookinEventHandlerTypeGesture ? @"gesture" : @"targetAction";
    dict[@"event"] = LKCString(handler.eventName);
    if (handler.targetActions.count) {
        NSMutableArray *actions = [NSMutableArray arrayWithCapacity:handler.targetActions.count];
        for (LookinStringTwoTuple *tuple in handler.targetActions) {
            [actions addObject:LKCTupleJSON(tuple)];
        }
        dict[@"targetActions"] = actions.copy;
    }
    if (handler.inheritedRecognizerName.length) {
        dict[@"inheritedRecognizerName"] = handler.inheritedRecognizerName;
    }
    if (handler.recognizerOid) {
        dict[@"recognizerOid"] = @(handler.recognizerOid);
        dict[@"recognizerEnabled"] = @(handler.gestureRecognizerIsEnabled);
    }
    if (handler.gestureRecognizerDelegator.length) {
        dict[@"recognizerDelegator"] = handler.gestureRecognizerDelegator;
    }
    if (handler.recognizerIvarTraces.count) {
        dict[@"recognizerIvarTraces"] = handler.recognizerIvarTraces;
    }
    return dict.copy;
}

static NSDictionary *LKCAutoLayoutConstraintJSON(LookinAutoLayoutConstraint *constraint) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"effective"] = @(constraint.effective);
    dict[@"active"] = @(constraint.active);
    dict[@"archived"] = @(constraint.shouldBeArchived);
    dict[@"firstItem"] = LKCObjectJSON(constraint.firstItem);
    dict[@"firstItemType"] = @(constraint.firstItemType);
    dict[@"firstAttribute"] = @(constraint.firstAttribute);
    dict[@"relation"] = @(constraint.relation);
    dict[@"secondItem"] = LKCObjectJSON(constraint.secondItem);
    dict[@"secondItemType"] = @(constraint.secondItemType);
    dict[@"secondAttribute"] = @(constraint.secondAttribute);
    dict[@"multiplier"] = @(constraint.multiplier);
    dict[@"constant"] = @(constraint.constant);
    dict[@"priority"] = @(constraint.priority);
    if (constraint.identifier.length) {
        dict[@"identifier"] = constraint.identifier;
    }
    return dict.copy;
}

static NSDictionary *LKCAttributeJSON(LookinAttribute *attribute) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"identifier"] = LKCString(attribute.identifier);
    dict[@"displayTitle"] = LKCString(attribute.displayTitle);
    dict[@"attrType"] = @(attribute.attrType);
    dict[@"attrTypeName"] = LKCAttrTypeName(attribute.attrType);
    dict[@"value"] = LKCJSONObject(attribute.value);
    if (attribute.extraValue) {
        dict[@"extraValue"] = LKCJSONObject(attribute.extraValue);
    }
    if (attribute.customSetterID.length) {
        dict[@"customSetterID"] = attribute.customSetterID;
    }
    dict[@"custom"] = @([attribute isUserCustom]);
    return dict.copy;
}

static NSDictionary *LKCAttributesSectionJSON(LookinAttributesSection *section) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"identifier"] = LKCString(section.identifier);
    dict[@"custom"] = @([section isUserCustom]);
    NSMutableArray *attributes = [NSMutableArray arrayWithCapacity:section.attributes.count];
    for (LookinAttribute *attribute in section.attributes) {
        [attributes addObject:LKCAttributeJSON(attribute)];
    }
    dict[@"attributes"] = attributes.copy;
    return dict.copy;
}

static NSDictionary *LKCAttributesGroupJSON(LookinAttributesGroup *group) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"identifier"] = LKCString(group.identifier);
    dict[@"title"] = LKCString(group.userCustomTitle);
    dict[@"uniqueKey"] = LKCString([group uniqueKey]);
    dict[@"custom"] = @([group isUserCustom]);
    NSMutableArray *sections = [NSMutableArray arrayWithCapacity:group.attrSections.count];
    for (LookinAttributesSection *section in group.attrSections) {
        [sections addObject:LKCAttributesSectionJSON(section)];
    }
    dict[@"sections"] = sections.copy;
    return dict.copy;
}

static NSDictionary *LKCItemJSON(LookinDisplayItem *item, NSUInteger depth, NSUInteger maxDepth) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"oid"] = @([item displayingObject].oid);
    dict[@"title"] = LKCItemTitle(item);
    dict[@"hidden"] = @(item.isHidden);
    dict[@"alpha"] = @(item.alpha);
    dict[@"frame"] = @{@"x": @(item.frame.origin.x), @"y": @(item.frame.origin.y), @"width": @(item.frame.size.width), @"height": @(item.frame.size.height)};
    dict[@"bounds"] = @{@"x": @(item.bounds.origin.x), @"y": @(item.bounds.origin.y), @"width": @(item.bounds.size.width), @"height": @(item.bounds.size.height)};
    dict[@"view"] = LKCObjectJSON(item.viewObject);
    dict[@"layer"] = LKCObjectJSON(item.layerObject);
    if (item.hostViewControllerObject) {
        dict[@"viewController"] = LKCObjectJSON(item.hostViewControllerObject);
    }
    if (item.customInfo.title.length) {
        dict[@"customInfo"] = @{@"title": item.customInfo.title};
    }
    dict[@"representedAsKeyWindow"] = @(item.representedAsKeyWindow);
    dict[@"shouldCaptureImage"] = @(item.shouldCaptureImage);
    dict[@"eventHandlerCount"] = @(item.eventHandlers.count);
    if (item.eventHandlers.count) {
        NSMutableArray *handlers = [NSMutableArray arrayWithCapacity:item.eventHandlers.count];
        for (LookinEventHandler *handler in item.eventHandlers) {
            [handlers addObject:LKCEventHandlerJSON(handler)];
        }
        dict[@"eventHandlers"] = handlers.copy;
    }
    dict[@"attributeGroupCount"] = @(item.attributesGroupList.count + item.customAttrGroupList.count);
    if (depth < maxDepth && item.subitems.count) {
        NSMutableArray *children = [NSMutableArray arrayWithCapacity:item.subitems.count];
        for (LookinDisplayItem *child in item.subitems) {
            [children addObject:LKCItemJSON(child, depth + 1, maxDepth)];
        }
        dict[@"children"] = children.copy;
    }
    return dict.copy;
}

static BOOL LKCObjectHasClass(LookinObject *object, NSString *className) {
    if (!object || !className.length) {
        return NO;
    }
    if ([LKCObjectClassName(object) isEqualToString:className]) {
        return YES;
    }
    return [object.classChainList containsObject:className];
}

static BOOL LKCItemIsInteractableCandidate(LookinDisplayItem *item) {
    if (!item || item.isHidden || item.alpha <= 0.01) {
        return NO;
    }
    if (item.frame.size.width <= 0 || item.frame.size.height <= 0) {
        return NO;
    }
    return item.viewObject.oid > 0;
}

static NSDictionary *LKCItemSummaryJSON(LookinDisplayItem *item, CGRect absoluteFrame) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"title"] = LKCItemTitle(item);
    dict[@"view"] = LKCObjectJSON(item.viewObject);
    dict[@"layer"] = LKCObjectJSON(item.layerObject);
    dict[@"hidden"] = @(item.isHidden);
    dict[@"alpha"] = @(item.alpha);
    dict[@"frame"] = @{@"x": @(absoluteFrame.origin.x), @"y": @(absoluteFrame.origin.y), @"width": @(absoluteFrame.size.width), @"height": @(absoluteFrame.size.height)};
    if (item.hostViewControllerObject) {
        dict[@"viewController"] = LKCObjectJSON(item.hostViewControllerObject);
    }
    if (item.eventHandlers.count) {
        NSMutableArray *handlers = [NSMutableArray arrayWithCapacity:item.eventHandlers.count];
        for (LookinEventHandler *handler in item.eventHandlers) {
            [handlers addObject:LKCEventHandlerJSON(handler)];
        }
        dict[@"eventHandlers"] = handlers.copy;
    }
    return dict.copy;
}

static BOOL LKCFindHitPathInItems(NSArray<LookinDisplayItem *> *items, CGPoint point, CGPoint parentOrigin, NSMutableArray<LookinDisplayItem *> *path, NSMutableArray<NSValue *> *frames) {
    for (LookinDisplayItem *item in [items reverseObjectEnumerator]) {
        if (!LKCItemIsInteractableCandidate(item)) {
            continue;
        }
        CGRect absoluteFrame = CGRectOffset(item.frame, parentOrigin.x, parentOrigin.y);
        if (!CGRectContainsPoint(absoluteFrame, point)) {
            continue;
        }
        [path addObject:item];
        [frames addObject:[NSValue valueWithRect:absoluteFrame]];
        CGPoint childOrigin = CGPointMake(absoluteFrame.origin.x, absoluteFrame.origin.y);
        if (LKCFindHitPathInItems(item.subitems, point, childOrigin, path, frames)) {
            return YES;
        }
        return YES;
    }
    return NO;
}

static BOOL LKCFindHitPath(NSArray<LookinDisplayItem *> *roots, CGPoint point, BOOL includeOverlays, NSMutableArray<LookinDisplayItem *> *path, NSMutableArray<NSValue *> *frames) {
    NSMutableArray<LookinDisplayItem *> *candidateRoots = [NSMutableArray array];
    if (!includeOverlays) {
        for (LookinDisplayItem *root in roots) {
            if (root.representedAsKeyWindow) {
                [candidateRoots addObject:root];
            }
        }
    }
    if (!candidateRoots.count) {
        [candidateRoots addObjectsFromArray:roots];
    }
    return LKCFindHitPathInItems(candidateRoots, point, CGPointZero, path, frames);
}

static void LKCCollectHitPathsInItems(NSArray<LookinDisplayItem *> *items, CGPoint point, CGPoint parentOrigin, NSMutableArray<LookinDisplayItem *> *currentPath, NSMutableArray<NSValue *> *currentFrames, NSMutableArray<NSArray<LookinDisplayItem *> *> *paths, NSMutableArray<NSArray<NSValue *> *> *framesList) {
    for (LookinDisplayItem *item in [items reverseObjectEnumerator]) {
        if (!LKCItemIsInteractableCandidate(item)) {
            continue;
        }
        CGRect absoluteFrame = CGRectOffset(item.frame, parentOrigin.x, parentOrigin.y);
        if (!CGRectContainsPoint(absoluteFrame, point)) {
            continue;
        }
        [currentPath addObject:item];
        [currentFrames addObject:[NSValue valueWithRect:absoluteFrame]];
        CGPoint childOrigin = CGPointMake(absoluteFrame.origin.x, absoluteFrame.origin.y);
        LKCCollectHitPathsInItems(item.subitems, point, childOrigin, currentPath, currentFrames, paths, framesList);
        [paths addObject:currentPath.copy];
        [framesList addObject:currentFrames.copy];
        [currentPath removeLastObject];
        [currentFrames removeLastObject];
    }
}

static void LKCCollectHitPaths(NSArray<LookinDisplayItem *> *roots, CGPoint point, BOOL includeOverlays, NSMutableArray<NSArray<LookinDisplayItem *> *> *paths, NSMutableArray<NSArray<NSValue *> *> *framesList) {
    NSMutableArray<LookinDisplayItem *> *candidateRoots = [NSMutableArray array];
    if (!includeOverlays) {
        for (LookinDisplayItem *root in roots) {
            if (root.representedAsKeyWindow) {
                [candidateRoots addObject:root];
            }
        }
    }
    if (!candidateRoots.count) {
        [candidateRoots addObjectsFromArray:roots];
    }
    LKCCollectHitPathsInItems(candidateRoots, point, CGPointZero, [NSMutableArray array], [NSMutableArray array], paths, framesList);
}

static NSDictionary *LKCDetailJSON(LookinDisplayItemDetail *detail) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"displayItemOid"] = @(detail.displayItemOid);
    if (detail.failureCode) {
        dict[@"failureCode"] = @(detail.failureCode);
    }
    if (detail.groupScreenshot) {
        dict[@"groupScreenshot"] = LKCImageJSON(detail.groupScreenshot);
    }
    if (detail.soloScreenshot) {
        dict[@"soloScreenshot"] = LKCImageJSON(detail.soloScreenshot);
    }
    if (detail.frameValue) {
        dict[@"frame"] = LKCValueJSON(detail.frameValue);
    }
    if (detail.boundsValue) {
        dict[@"bounds"] = LKCValueJSON(detail.boundsValue);
    }
    if (detail.hiddenValue) {
        dict[@"hidden"] = detail.hiddenValue;
    }
    if (detail.alphaValue) {
        dict[@"alpha"] = detail.alphaValue;
    }
    if (detail.customDisplayTitle.length) {
        dict[@"customDisplayTitle"] = detail.customDisplayTitle;
    }
    if (detail.danceUISource.length) {
        dict[@"danceUISource"] = detail.danceUISource;
    }
    if (detail.attributesGroupList) {
        dict[@"attributes"] = LKCJSONObject(detail.attributesGroupList);
    }
    if (detail.customAttrGroupList) {
        dict[@"customAttributes"] = LKCJSONObject(detail.customAttrGroupList);
    }
    if (detail.subitems) {
        dict[@"subitems"] = LKCJSONObject(detail.subitems);
    }
    return dict.copy;
}

static BOOL LKCVCLooksLikeOverlay(NSString *vcClass, NSString *path) {
    NSArray<NSString *> *classPrefixes = @[@"UIInput", @"UIEditing", @"FLEX", @"BDTracker"];
    for (NSString *prefix in classPrefixes) {
        if ([vcClass hasPrefix:prefix]) {
            return YES;
        }
    }
    NSArray<NSString *> *pathPrefixes = @[@"UITextEffectsWindow", @"FLEXWindow", @"BDTrackerGUI"];
    for (NSString *prefix in pathPrefixes) {
        if ([path hasPrefix:prefix]) {
            return YES;
        }
    }
    return NO;
}

static void LKCCollectViewControllers(NSArray<LookinDisplayItem *> *items, NSArray<NSString *> *path, NSUInteger depth, NSMutableDictionary<NSString *, NSMutableDictionary *> *byKey) {
    for (LookinDisplayItem *item in items) {
        NSString *title = LKCItemTitle(item);
        NSArray<NSString *> *nextPath = [path arrayByAddingObject:title];
        LookinObject *vc = item.hostViewControllerObject;
        if (vc) {
            NSString *vcClass = LKCObjectClassName(vc);
            NSString *key = [NSString stringWithFormat:@"%@-%lu", vcClass, vc.oid];
            NSString *pathString = [nextPath componentsJoinedByString:@" > "];
            CGFloat area = MAX(0, item.frame.size.width) * MAX(0, item.frame.size.height);
            NSMutableDictionary *dict = byKey[key];
            if (!dict) {
                dict = [NSMutableDictionary dictionary];
                dict[@"count"] = @0;
                byKey[key] = dict;
            }
            dict[@"count"] = @([dict[@"count"] unsignedIntegerValue] + 1);
            CGFloat previousArea = [dict[@"area"] doubleValue];
            NSUInteger previousDepth = [dict[@"depth"] unsignedIntegerValue];
            if (!dict[@"class"] || area > previousArea || (area == previousArea && depth >= previousDepth)) {
                dict[@"class"] = vcClass;
                dict[@"oid"] = @(vc.oid);
                dict[@"address"] = LKCString(vc.memoryAddress);
                dict[@"depth"] = @(depth);
                dict[@"title"] = title;
                dict[@"path"] = pathString;
                dict[@"overlay"] = @(LKCVCLooksLikeOverlay(vcClass, pathString));
                dict[@"area"] = @(area);
                dict[@"frame"] = @{@"x": @(item.frame.origin.x), @"y": @(item.frame.origin.y), @"width": @(item.frame.size.width), @"height": @(item.frame.size.height)};
                dict[@"view"] = LKCObjectJSON(item.viewObject);
                dict[@"layer"] = LKCObjectJSON(item.layerObject);
            }
        }
        LKCCollectViewControllers(item.subitems, nextPath, depth + 1, byKey);
    }
}

static NSArray<NSDictionary *> *LKCCurrentViewControllersJSON(NSArray<LookinDisplayItem *> *items) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byKey = [NSMutableDictionary dictionary];
    LKCCollectViewControllers(items, @[], 0, byKey);
    NSArray<NSMutableDictionary *> *values = byKey.allValues;
    NSArray<NSMutableDictionary *> *sorted = [values sortedArrayUsingComparator:^NSComparisonResult(NSMutableDictionary *a, NSMutableDictionary *b) {
        BOOL overlayA = [a[@"overlay"] boolValue];
        BOOL overlayB = [b[@"overlay"] boolValue];
        if (overlayA != overlayB) {
            return overlayA ? NSOrderedDescending : NSOrderedAscending;
        }
        CGFloat areaA = [a[@"area"] doubleValue];
        CGFloat areaB = [b[@"area"] doubleValue];
        if (areaA != areaB) {
            return areaA > areaB ? NSOrderedAscending : NSOrderedDescending;
        }
        NSUInteger depthA = [a[@"depth"] unsignedIntegerValue];
        NSUInteger depthB = [b[@"depth"] unsignedIntegerValue];
        if (depthA != depthB) {
            return depthA > depthB ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a[@"class"] compare:b[@"class"]];
    }];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:sorted.count];
    [sorted enumerateObjectsUsingBlock:^(NSMutableDictionary *dict, NSUInteger idx, BOOL *stop) {
        NSMutableDictionary *copy = dict.mutableCopy;
        copy[@"rank"] = @(idx);
        [result addObject:copy.copy];
    }];
    return result.copy;
}

static id LKCJSONObject(id object) {
    if (!object) {
        return [NSNull null];
    }
    if ([object isKindOfClass:[NSString class]] || [object isKindOfClass:[NSNumber class]] || [object isKindOfClass:[NSNull class]]) {
        return object;
    }
    if ([object isKindOfClass:[NSData class]]) {
        return @{@"bytes": @([(NSData *)object length])};
    }
    if ([object isKindOfClass:[NSImage class]]) {
        return LKCImageJSON(object);
    }
    if ([object isKindOfClass:[NSValue class]]) {
        return LKCValueJSON(object);
    }
    if ([object isKindOfClass:[LookinObject class]]) {
        return LKCObjectJSON(object);
    }
    if ([object isKindOfClass:[LookinIvarTrace class]]) {
        return LKCIvarTraceJSON(object);
    }
    if ([object isKindOfClass:[LookinAttribute class]]) {
        return LKCAttributeJSON(object);
    }
    if ([object isKindOfClass:[LookinAttributesSection class]]) {
        return LKCAttributesSectionJSON(object);
    }
    if ([object isKindOfClass:[LookinAttributesGroup class]]) {
        return LKCAttributesGroupJSON(object);
    }
    if ([object isKindOfClass:[LookinDisplayItemDetail class]]) {
        return LKCDetailJSON(object);
    }
    if ([object isKindOfClass:[LookinDisplayItem class]]) {
        return LKCItemJSON(object, 0, NSUIntegerMax);
    }
    if ([object isKindOfClass:[LookinEventHandler class]]) {
        return LKCEventHandlerJSON(object);
    }
    if ([object isKindOfClass:[LookinAutoLayoutConstraint class]]) {
        return LKCAutoLayoutConstraintJSON(object);
    }
    if ([object isKindOfClass:[LookinStringTwoTuple class]]) {
        return LKCTupleJSON(object);
    }
    if ([object isKindOfClass:[NSError class]]) {
        NSError *error = object;
        return @{@"domain": LKCString(error.domain), @"code": @(error.code), @"message": LKCString(error.localizedDescription)};
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:[(NSArray *)object count]];
        for (id value in (NSArray *)object) {
            [array addObject:LKCJSONObject(value)];
        }
        return array.copy;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)object count]];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            dict[LKCString(key)] = LKCJSONObject(value);
        }];
        return dict.copy;
    }
    return @{@"class": NSStringFromClass([object class]), @"description": LKCString(object)};
}

static void LKCPrintJSON(id object, NSString *outputPath) {
    id jsonObject = LKCJSONObject(object);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:jsonObject options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data) {
        fprintf(stderr, "JSON error: %s\n", error.localizedDescription.UTF8String);
        exit(2);
    }
    if (outputPath.length) {
        NSString *path = outputPath.stringByStandardizingPath;
        if (![data writeToFile:path atomically:YES]) {
            fprintf(stderr, "Failed to write %s\n", path.UTF8String);
            exit(2);
        }
    } else {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
    }
}

static NSString *LKCArgValue(NSArray<NSString *> *args, NSString *name) {
    NSUInteger index = [args indexOfObject:name];
    if (index == NSNotFound || index + 1 >= args.count) {
        return nil;
    }
    return args[index + 1];
}

static BOOL LKCHasArg(NSArray<NSString *> *args, NSString *name) {
    return [args containsObject:name];
}

static NSString *LKCConsumeArg(NSMutableArray<NSString *> *args, NSString *name) {
    NSUInteger index = [args indexOfObject:name];
    if (index == NSNotFound || index + 1 >= args.count) {
        return nil;
    }
    NSString *value = args[index + 1];
    [args removeObjectAtIndex:index + 1];
    [args removeObjectAtIndex:index];
    return value;
}

static NSString *LKCConsumeArgEither(NSMutableArray<NSString *> *args, NSString *first, NSString *second) {
    NSString *value = LKCConsumeArg(args, first);
    if (value.length) {
        return value;
    }
    return LKCConsumeArg(args, second);
}

static BOOL LKCConsumeFlag(NSMutableArray<NSString *> *args, NSString *name) {
    NSUInteger index = [args indexOfObject:name];
    if (index == NSNotFound) {
        return NO;
    }
    [args removeObjectAtIndex:index];
    return YES;
}

static BOOL LKCParseBool(NSString *value) {
    NSString *lower = value.lowercaseString;
    return [lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"enable"] || [lower isEqualToString:@"enabled"];
}

static id LKCJSONFromString(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) {
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static NSArray<NSNumber *> *LKCNumberArrayFromString(NSString *string) {
    id json = LKCJSONFromString(string);
    if ([json isKindOfClass:[NSArray class]]) {
        NSMutableArray *numbers = [NSMutableArray array];
        for (id value in (NSArray *)json) {
            if ([value respondsToSelector:@selector(doubleValue)]) {
                [numbers addObject:@([value doubleValue])];
            }
        }
        return numbers.copy;
    }

    NSString *normalized = [[string stringByReplacingOccurrencesOfString:@"," withString:@" "] stringByReplacingOccurrencesOfString:@";" withString:@" "];
    NSArray *parts = [normalized componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *numbers = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length) {
            [numbers addObject:@(part.doubleValue)];
        }
    }
    return numbers.copy;
}

static NSDictionary<NSString *, NSNumber *> *LKCAttrTypeMap(void) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"none": @(LookinAttrTypeNone),
            @"void": @(LookinAttrTypeVoid),
            @"char": @(LookinAttrTypeChar),
            @"int": @(LookinAttrTypeInt),
            @"short": @(LookinAttrTypeShort),
            @"long": @(LookinAttrTypeLong),
            @"longlong": @(LookinAttrTypeLongLong),
            @"unsignedchar": @(LookinAttrTypeUnsignedChar),
            @"uchar": @(LookinAttrTypeUnsignedChar),
            @"unsignedint": @(LookinAttrTypeUnsignedInt),
            @"uint": @(LookinAttrTypeUnsignedInt),
            @"unsignedshort": @(LookinAttrTypeUnsignedShort),
            @"ushort": @(LookinAttrTypeUnsignedShort),
            @"unsignedlong": @(LookinAttrTypeUnsignedLong),
            @"ulong": @(LookinAttrTypeUnsignedLong),
            @"unsignedlonglong": @(LookinAttrTypeUnsignedLongLong),
            @"ulonglong": @(LookinAttrTypeUnsignedLongLong),
            @"float": @(LookinAttrTypeFloat),
            @"double": @(LookinAttrTypeDouble),
            @"bool": @(LookinAttrTypeBOOL),
            @"boolean": @(LookinAttrTypeBOOL),
            @"sel": @(LookinAttrTypeSel),
            @"selector": @(LookinAttrTypeSel),
            @"class": @(LookinAttrTypeClass),
            @"point": @(LookinAttrTypeCGPoint),
            @"cgpoint": @(LookinAttrTypeCGPoint),
            @"vector": @(LookinAttrTypeCGVector),
            @"cgvector": @(LookinAttrTypeCGVector),
            @"size": @(LookinAttrTypeCGSize),
            @"cgsize": @(LookinAttrTypeCGSize),
            @"rect": @(LookinAttrTypeCGRect),
            @"cgrect": @(LookinAttrTypeCGRect),
            @"affine": @(LookinAttrTypeCGAffineTransform),
            @"affinetransform": @(LookinAttrTypeCGAffineTransform),
            @"transform": @(LookinAttrTypeCGAffineTransform),
            @"edgeinsets": @(LookinAttrTypeUIEdgeInsets),
            @"insets": @(LookinAttrTypeUIEdgeInsets),
            @"offset": @(LookinAttrTypeUIOffset),
            @"string": @(LookinAttrTypeNSString),
            @"nsstring": @(LookinAttrTypeNSString),
            @"enumint": @(LookinAttrTypeEnumInt),
            @"enumlong": @(LookinAttrTypeEnumLong),
            @"color": @(LookinAttrTypeUIColor),
            @"uicolor": @(LookinAttrTypeUIColor),
            @"customobj": @(LookinAttrTypeCustomObj),
            @"customobject": @(LookinAttrTypeCustomObj),
            @"enumstring": @(LookinAttrTypeEnumString),
            @"shadow": @(LookinAttrTypeShadow),
            @"json": @(LookinAttrTypeJson)
        };
    });
    return map;
}

static BOOL LKCParseAttrType(NSString *string, LookinAttrType *outType) {
    if (!string.length) {
        return NO;
    }
    NSScanner *scanner = [NSScanner scannerWithString:string];
    NSInteger integer = 0;
    if ([scanner scanInteger:&integer] && scanner.isAtEnd) {
        *outType = (LookinAttrType)integer;
        return YES;
    }
    NSString *key = [[string.lowercaseString stringByReplacingOccurrencesOfString:@"lookinattrtype" withString:@""] stringByReplacingOccurrencesOfString:@"_" withString:@""];
    NSNumber *value = LKCAttrTypeMap()[key];
    if (!value) {
        return NO;
    }
    *outType = value.integerValue;
    return YES;
}

struct LKCUIOffset {
    CGFloat horizontal;
    CGFloat vertical;
};

static id LKCParseAttrValue(LookinAttrType type, NSString *string) {
    NSString *lower = string.lowercaseString;
    if ([lower isEqualToString:@"nil"] || [lower isEqualToString:@"null"]) {
        return nil;
    }
    NSArray<NSNumber *> *numbers = nil;
    switch (type) {
        case LookinAttrTypeChar:
        case LookinAttrTypeInt:
        case LookinAttrTypeShort:
        case LookinAttrTypeLong:
        case LookinAttrTypeLongLong:
        case LookinAttrTypeUnsignedChar:
        case LookinAttrTypeUnsignedInt:
        case LookinAttrTypeUnsignedShort:
        case LookinAttrTypeUnsignedLong:
        case LookinAttrTypeUnsignedLongLong:
        case LookinAttrTypeEnumInt:
        case LookinAttrTypeEnumLong:
            return @(string.longLongValue);
        case LookinAttrTypeFloat:
        case LookinAttrTypeDouble:
            return @(string.doubleValue);
        case LookinAttrTypeBOOL:
            return @(LKCParseBool(string));
        case LookinAttrTypeSel:
        case LookinAttrTypeClass:
        case LookinAttrTypeNSString:
        case LookinAttrTypeEnumString:
        case LookinAttrTypeCustomObj:
            return string;
        case LookinAttrTypeUIColor: {
            numbers = LKCNumberArrayFromString(string);
            if (numbers.count < 3) {
                return nil;
            }
            double r = numbers[0].doubleValue;
            double g = numbers[1].doubleValue;
            double b = numbers[2].doubleValue;
            double a = numbers.count > 3 ? numbers[3].doubleValue : 1.0;
            if (r > 1 || g > 1 || b > 1 || a > 1) {
                r /= 255.0;
                g /= 255.0;
                b /= 255.0;
                if (a > 1) {
                    a /= 255.0;
                }
            }
            return @[@(r), @(g), @(b), @(a)];
        }
        case LookinAttrTypeCGPoint: {
            numbers = LKCNumberArrayFromString(string);
            if (numbers.count < 2) return nil;
            return [NSValue valueWithPoint:NSMakePoint(numbers[0].doubleValue, numbers[1].doubleValue)];
        }
        case LookinAttrTypeCGVector: {
            numbers = LKCNumberArrayFromString(string);
            if (numbers.count < 2) return nil;
            CGVector vector = CGVectorMake(numbers[0].doubleValue, numbers[1].doubleValue);
            return [NSValue valueWithBytes:&vector objCType:@encode(CGVector)];
        }
        case LookinAttrTypeCGSize: {
            numbers = LKCNumberArrayFromString(string);
            if (numbers.count < 2) return nil;
            return [NSValue valueWithSize:NSMakeSize(numbers[0].doubleValue, numbers[1].doubleValue)];
        }
        case LookinAttrTypeCGRect: {
            numbers = LKCNumberArrayFromString(string);
            if (numbers.count < 4) return nil;
            return [NSValue valueWithRect:NSMakeRect(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue)];
        }
        case LookinAttrTypeCGAffineTransform: {
            numbers = LKCNumberArrayFromString(string);
            if (numbers.count < 6) return nil;
            CGAffineTransform transform = CGAffineTransformMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue, numbers[4].doubleValue, numbers[5].doubleValue);
            return [NSValue valueWithBytes:&transform objCType:@encode(CGAffineTransform)];
        }
        case LookinAttrTypeUIEdgeInsets: {
            numbers = LKCNumberArrayFromString(string);
            if (numbers.count < 4) return nil;
            return [NSValue valueWithEdgeInsets:NSEdgeInsetsMake(numbers[0].doubleValue, numbers[1].doubleValue, numbers[2].doubleValue, numbers[3].doubleValue)];
        }
        case LookinAttrTypeUIOffset: {
            numbers = LKCNumberArrayFromString(string);
            if (numbers.count < 2) return nil;
            struct LKCUIOffset offset = {numbers[0].doubleValue, numbers[1].doubleValue};
            return [NSValue valueWithBytes:&offset objCType:@encode(struct LKCUIOffset)];
        }
        case LookinAttrTypeJson:
        case LookinAttrTypeShadow: {
            id json = LKCJSONFromString(string);
            return json ?: string;
        }
        default:
            return nil;
    }
}

static LookinStaticAsyncUpdateTaskType LKCParseScreenshotType(NSString *value) {
    NSString *lower = value.lowercaseString;
    if ([lower isEqualToString:@"solo"]) {
        return LookinStaticAsyncUpdateTaskTypeSoloScreenshot;
    }
    if ([lower isEqualToString:@"group"]) {
        return LookinStaticAsyncUpdateTaskTypeGroupScreenshot;
    }
    return LookinStaticAsyncUpdateTaskTypeNoScreenshot;
}

static LookinDetailUpdateTaskAttrRequest LKCParseAttrRequest(NSString *value) {
    NSString *lower = value.lowercaseString;
    if ([lower isEqualToString:@"need"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"true"]) {
        return LookinDetailUpdateTaskAttrRequest_Need;
    }
    if ([lower isEqualToString:@"none"] || [lower isEqualToString:@"no"] || [lower isEqualToString:@"false"] || [lower isEqualToString:@"notneed"]) {
        return LookinDetailUpdateTaskAttrRequest_NotNeed;
    }
    return LookinDetailUpdateTaskAttrRequest_Automatic;
}

static LookinStaticAsyncUpdateTask *LKCTaskForOid(unsigned long oid, LookinStaticAsyncUpdateTaskType screenshotType, LookinDetailUpdateTaskAttrRequest attrRequest, BOOL basis, BOOL subitems) {
    LookinStaticAsyncUpdateTask *task = [LookinStaticAsyncUpdateTask new];
    task.oid = oid;
    task.taskType = screenshotType;
    task.attrRequest = attrRequest;
    task.needBasisVisualInfo = basis;
    task.needSubitems = subitems;
    task.clientReadableVersion = LKCClientReadableVersion;
    return task;
}

static NSMutableArray<NSNumber *> *LKCOidsFromArgs(NSArray<NSString *> *args) {
    NSMutableArray<NSNumber *> *oids = [NSMutableArray array];
    for (NSString *arg in args) {
        if ([arg hasPrefix:@"-"]) {
            continue;
        }
        NSArray *parts = [arg componentsSeparatedByString:@","];
        for (NSString *part in parts) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length) {
                [oids addObject:@(strtoul(trimmed.UTF8String, NULL, 10))];
            }
        }
    }
    return oids;
}

static BOOL LKCIsHelpToken(NSString *value) {
    return [value isEqualToString:@"help"] || [value isEqualToString:@"--help"] || [value isEqualToString:@"-h"];
}

static void LKCPrintDevicesHelp(void) {
    printf("Usage:\n");
    printf("  lookinctl devices [-l] [--json] [--wait seconds] [--timeout seconds]\n");
    printf("  lookinctl list [--json]\n");
    printf("\n");
    printf("Lists foreground iOS apps that have LookinServer integrated.\n");
    printf("Use the printed serial, bundle id, app name, or index as -s <target>.\n");
}

static void LKCPrintInputHelp(void) {
    printf("Usage:\n");
    printf("  lookinctl -s <target> shell input hit-test x y [--points] [--include-overlays] [-o file]\n");
    printf("  lookinctl -s <target> shell input tap x y [--points] [--dry-run] [--include-overlays] [-o file]\n");
    printf("\n");
    printf("Coordinates are screenshot pixels by default. Use --points for UIKit points.\n");
    printf("tap is a best-effort semantic activation using UIControl touchUpInside or accessibilityActivate.\n");
    printf("It is not physical UITouch injection. Failures are returned as JSON with code, reason, and suggestion.\n");
}

static void LKCPrintScreencapHelp(void) {
    printf("Usage:\n");
    printf("  lookinctl -s <target> shell screencap -p [-o file] [--preview]\n");
    printf("  lookinctl -s <target> shell lookin screenshot [-o file] [--preview]\n");
    printf("\n");
    printf("Writes a PNG screenshot to file or stdout. The default path uses high-quality layer screenshots.\n");
    printf("--preview uses the lower-resolution LookinServer app preview image.\n");
}

static void LKCPrintDumpHelp(void) {
    printf("Usage:\n");
    printf("  lookinctl -s <target> shell uiautomator dump [--output file] [--max-depth n]\n");
    printf("  lookinctl -s <target> shell lookin hierarchy [--output file] [--max-depth n]\n");
    printf("  lookinctl dump [--bundle bundle-id | --index n] [--output file] [--max-depth n]\n");
    printf("\n");
    printf("Exports the LookinServer hierarchy as JSON, including oid, frame, class chain, event handlers, and view controller hints.\n");
}

static void LKCPrintLookinHelp(void) {
    printf("Usage:\n");
    printf("  lookinctl -s <target> shell lookin <command> [args]\n");
    printf("\n");
    printf("Commands:\n");
    printf("  app [-o file]\n");
    printf("  ping [-o file]\n");
    printf("  hierarchy|dump [--max-depth n] [-o file]\n");
    printf("  screenshot|screencap [-p] [--preview] [-o file]\n");
    printf("  current-vc [-o file]\n");
    printf("  details <oid...> [--screenshot none|solo|group] [--attrs auto|need|none] [--basis] [--subitems] [-o file]\n");
    printf("  attrs <layer-oid> [-o file]\n");
    printf("  selectors|methods <class-name> [--has-arg] [-o file]\n");
    printf("  invoke <oid> <selector> [-o file]\n");
    printf("  object <oid> [-o file]\n");
    printf("  image <image-view-oid> [-o file]\n");
    printf("  recognizer <recognizer-oid> enable|disable\n");
    printf("  set-builtin <target-oid> <setter> <attr-type> <value> [-o file]\n");
    printf("  set-custom <custom-setter-id> <attr-type> <value>\n");
    printf("  patch <oid...> [--screenshot none|solo|group] [-o file]\n");
    printf("  cancel-details\n");
}

static void LKCPrintShellHelp(void) {
    printf("Usage:\n");
    printf("  lookinctl -s <target> shell <command> [args]\n");
    printf("\n");
    printf("adb-like shell commands:\n");
    printf("  uiautomator dump [--output file] [--max-depth n]\n");
    printf("  screencap -p [-o file] [--preview]\n");
    printf("  input hit-test x y [--points] [--include-overlays] [-o file]\n");
    printf("  input tap x y [--points] [--dry-run] [--include-overlays] [-o file]\n");
    printf("  dumpsys lookin [-o file]\n");
    printf("  lookin <command> [args]\n");
    printf("\n");
    printf("Run 'lookinctl help shell input' or 'lookinctl help shell lookin' for more detail.\n");
}

static void LKCUsage(void) {
    printf("lookinctl %s\n", LKCVersion.UTF8String);
    printf("Usage:\n");
    printf("  lookinctl help [topic]\n");
    printf("  lookinctl devices [-l] [--json] [--wait seconds] [--timeout seconds]\n");
    printf("  lookinctl -s <serial|bundle|index> shell <command> [args]\n");
    printf("  lookinctl dump [--bundle bundle-id | --index n] [--output file] [--max-depth n]\n");
    printf("\n");
    printf("Common commands:\n");
    printf("  lookinctl -s <target> shell input tap x y [--points] [--dry-run]\n");
    printf("  lookinctl -s <target> shell screencap -p [-o file] [--preview]\n");
    printf("  lookinctl -s <target> shell uiautomator dump [--output file] [--max-depth n]\n");
    printf("  lookinctl -s <target> shell lookin current-vc [-o file]\n");
    printf("\n");
    printf("Help topics:\n");
    printf("  devices | shell | shell input | shell lookin | screencap | dump\n");
    printf("\n");
    printf("The target iOS app must be running in foreground with LookinServer integrated.\n");
    printf("This CLI exposes LookinServer protocol abilities; it does not provide adb input tap injection.\n");
}

static int LKCPrintHelp(NSArray<NSString *> *rawTopics) {
    NSMutableArray<NSString *> *topics = [NSMutableArray array];
    for (NSString *topic in rawTopics) {
        if (![topic hasPrefix:@"-"] && ![topic isEqualToString:@"help"]) {
            [topics addObject:topic.lowercaseString];
        }
    }
    if (!topics.count) {
        LKCUsage();
        return 0;
    }

    NSString *first = topics.firstObject;
    NSString *second = topics.count > 1 ? topics[1] : nil;
    if ([first isEqualToString:@"devices"] || [first isEqualToString:@"list"]) {
        LKCPrintDevicesHelp();
        return 0;
    }
    if ([first isEqualToString:@"shell"]) {
        if ([second isEqualToString:@"input"]) {
            LKCPrintInputHelp();
        } else if ([second isEqualToString:@"lookin"]) {
            LKCPrintLookinHelp();
        } else if ([second isEqualToString:@"screencap"] || [second isEqualToString:@"screenshot"]) {
            LKCPrintScreencapHelp();
        } else if ([second isEqualToString:@"uiautomator"] || [second isEqualToString:@"dump"] || [second isEqualToString:@"hierarchy"]) {
            LKCPrintDumpHelp();
        } else {
            LKCPrintShellHelp();
        }
        return 0;
    }
    if ([first isEqualToString:@"input"]) {
        LKCPrintInputHelp();
        return 0;
    }
    if ([first isEqualToString:@"lookin"]) {
        LKCPrintLookinHelp();
        return 0;
    }
    if ([first isEqualToString:@"screencap"] || [first isEqualToString:@"screenshot"]) {
        LKCPrintScreencapHelp();
        return 0;
    }
    if ([first isEqualToString:@"dump"] || [first isEqualToString:@"hierarchy"] || [first isEqualToString:@"uiautomator"]) {
        LKCPrintDumpHelp();
        return 0;
    }

    fprintf(stderr, "Unknown help topic: %s\n", first.UTF8String);
    LKCUsage();
    return 2;
}

static int LKCPrintResponseError(NSString *prefix, LKCResponse *response) {
    fprintf(stderr, "%s: %s\n", prefix.UTF8String, response.error.localizedDescription.UTF8String);
    return 1;
}

static int LKCDumpHierarchy(LKCClient *client, LKCConnectedApp *target, NSArray<NSString *> *args, NSTimeInterval timeout) {
    NSString *outputPath = LKCArgValue(args, @"--output") ?: LKCArgValue(args, @"-o");
    NSDictionary *params = @{@"clientVersion": LKCClientReadableVersion};
    LKCResponse *response = [client requestType:LookinRequestTypeHierarchy data:params channel:target.channel timeout:MAX(timeout, 8.0) pingFirst:YES];
    if (response.error) {
        return LKCPrintResponseError(@"Dump failed", response);
    }
    if (![response.data isKindOfClass:[LookinHierarchyInfo class]]) {
        fprintf(stderr, "Dump failed: unexpected response.\n");
        return 1;
    }

    LookinHierarchyInfo *info = response.data;
    NSUInteger maxDepth = LKCArgValue(args, @"--max-depth").length ? (NSUInteger)LKCArgValue(args, @"--max-depth").integerValue : NSUIntegerMax;
    NSMutableArray *roots = [NSMutableArray array];
    for (LookinDisplayItem *item in info.displayItems) {
        [roots addObject:LKCItemJSON(item, 0, maxDepth)];
    }
    NSDictionary *json = @{
        @"app": LKCAppInfoJSON(target, 0),
        @"serverVersion": @(info.serverVersion),
        @"nodeCount": @(LKCFlatItems(info.displayItems).count),
        @"roots": roots.copy
    };
    LKCPrintJSON(json, outputPath);
    return 0;
}

static int LKCPreviewScreenshot(LKCClient *client, LKCConnectedApp *target, NSString *outputPath, NSTimeInterval timeout) {
    NSDictionary *params = @{@"needImages": @YES, @"local": @[]};
    LKCResponse *response = [client requestType:LookinRequestTypeApp data:params channel:target.channel timeout:MAX(timeout, 8.0) pingFirst:YES];
    if (response.error) {
        return LKCPrintResponseError(@"Screenshot failed", response);
    }
    if (![response.data isKindOfClass:[LookinAppInfo class]]) {
        fprintf(stderr, "Screenshot failed: unexpected response.\n");
        return 1;
    }
    LookinAppInfo *info = response.data;
    if (!info.screenshot) {
        fprintf(stderr, "Screenshot failed: server returned no screenshot.\n");
        return 1;
    }
    return LKCWriteImage(info.screenshot, outputPath);
}

static LookinDisplayItem *LKCPreferredScreenshotRoot(NSArray<LookinDisplayItem *> *items) {
    for (LookinDisplayItem *item in items) {
        if (item.representedAsKeyWindow && item.layerObject.oid) {
            return item;
        }
    }
    for (LookinDisplayItem *item in items) {
        NSString *title = LKCItemTitle(item);
        if ([title isEqualToString:@"UIWindow"] && item.layerObject.oid) {
            return item;
        }
    }
    for (LookinDisplayItem *item in items) {
        if (item.layerObject.oid) {
            return item;
        }
    }
    return nil;
}

static int LKCHighQualityScreenshot(LKCClient *client, LKCConnectedApp *target, NSString *outputPath, NSTimeInterval timeout) {
    NSDictionary *params = @{@"clientVersion": LKCClientReadableVersion};
    LKCResponse *hierarchyResponse = [client requestType:LookinRequestTypeHierarchy data:params channel:target.channel timeout:MAX(timeout, 8.0) pingFirst:YES];
    if (hierarchyResponse.error) {
        return LKCPrintResponseError(@"Screenshot hierarchy failed", hierarchyResponse);
    }
    if (![hierarchyResponse.data isKindOfClass:[LookinHierarchyInfo class]]) {
        fprintf(stderr, "Screenshot failed: unexpected hierarchy response.\n");
        return 1;
    }

    LookinHierarchyInfo *hierarchy = hierarchyResponse.data;
    LookinDisplayItem *root = LKCPreferredScreenshotRoot(hierarchy.displayItems);
    if (!root || !root.layerObject.oid) {
        fprintf(stderr, "Screenshot failed: no root layer found.\n");
        return 1;
    }

    LookinStaticAsyncUpdateTask *task = LKCTaskForOid(root.layerObject.oid, LookinStaticAsyncUpdateTaskTypeGroupScreenshot, LookinDetailUpdateTaskAttrRequest_NotNeed, NO, NO);
    LookinStaticAsyncUpdateTasksPackage *package = [LookinStaticAsyncUpdateTasksPackage new];
    package.tasks = @[task];
    LKCResponse *detailResponse = [client requestType:LookinRequestTypeHierarchyDetails data:@[package] channel:target.channel timeout:MAX(timeout, 12.0) pingFirst:YES];
    if (detailResponse.error) {
        return LKCPrintResponseError(@"Screenshot detail failed", detailResponse);
    }
    if (![detailResponse.data isKindOfClass:[NSArray class]] || ![(NSArray *)detailResponse.data count]) {
        fprintf(stderr, "Screenshot failed: no detail response.\n");
        return 1;
    }
    LookinDisplayItemDetail *detail = [(NSArray *)detailResponse.data firstObject];
    if (![detail isKindOfClass:[LookinDisplayItemDetail class]] || !detail.groupScreenshot) {
        fprintf(stderr, "Screenshot failed: server returned no high-quality screenshot.\n");
        return 1;
    }
    return LKCWriteImage(detail.groupScreenshot, outputPath);
}

static int LKCScreenshot(LKCClient *client, LKCConnectedApp *target, NSString *outputPath, NSTimeInterval timeout, BOOL preview) {
    if (preview) {
        return LKCPreviewScreenshot(client, target, outputPath, timeout);
    }
    return LKCHighQualityScreenshot(client, target, outputPath, timeout);
}

static int LKCDevices(LKCClient *client, NSArray<NSString *> *args, NSTimeInterval wait, NSTimeInterval timeout) {
    if (LKCHasArg(args, @"--help") || LKCHasArg(args, @"-h") || [args.firstObject isEqualToString:@"help"]) {
        LKCPrintDevicesHelp();
        return 0;
    }

    NSArray<LKCConnectedApp *> *apps = [client discoverAppsWithImages:NO wait:wait timeout:timeout];
    if (LKCHasArg(args, @"--json")) {
        NSMutableArray *json = [NSMutableArray arrayWithCapacity:apps.count];
        [apps enumerateObjectsUsingBlock:^(LKCConnectedApp *app, NSUInteger idx, BOOL *stop) {
            [json addObject:LKCAppInfoJSON(app, idx)];
        }];
        LKCPrintJSON(json, nil);
        return 0;
    }

    printf("List of LookinServer devices attached\n");
    [apps enumerateObjectsUsingBlock:^(LKCConnectedApp *app, NSUInteger idx, BOOL *stop) {
        LookinAppInfo *info = app.appInfo;
        printf("%-24s device index:%lu transport:%s port:%ld app:\"%s\" bundle:%s model:\"%s\" os:%s\n",
               LKCAppSerial(app).UTF8String,
               (unsigned long)idx,
               app.transport.UTF8String,
               (long)app.port,
               LKCString(info.appName).UTF8String,
               LKCString(info.appBundleIdentifier).UTF8String,
               LKCString(info.deviceDescription).UTF8String,
               LKCString(info.osDescription).UTF8String);
    }];
    return 0;
}

static NSDictionary *LKCInputPointJSON(double rawX, double rawY, CGPoint point, NSString *space, double scale) {
    return @{
        @"raw": @{@"x": @(rawX), @"y": @(rawY)},
        @"point": @{@"x": @(point.x), @"y": @(point.y)},
        @"coordinateSpace": space,
        @"scale": @(scale)
    };
}

static BOOL LKCInvokeResponseLooksTruthy(LKCResponse *response) {
    if (response.error) {
        return NO;
    }
    if (![response.data isKindOfClass:[NSDictionary class]]) {
        return response.data != nil;
    }
    NSString *description = LKCString(((NSDictionary *)response.data)[@"description"]).lowercaseString;
    if (!description.length) {
        return YES;
    }
    return [description isEqualToString:@"yes"] || [description isEqualToString:@"true"] || [description isEqualToString:@"1"];
}

static LKCResponse *LKCSendControlTouchUpInside(LKCClient *client, LKCConnectedApp *target, unsigned long oid, NSTimeInterval timeout) {
    LookinAttributeModification *modification = [LookinAttributeModification new];
    modification.targetOid = oid;
    modification.setterSelector = NSSelectorFromString(@"sendActionsForControlEvents:");
    modification.attrType = LookinAttrTypeUnsignedLong;
    modification.value = @(1UL << 6);
    modification.clientReadableVersion = LKCClientReadableVersion;
    return [client requestType:LookinRequestTypeInbuiltAttrModification data:modification channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
}

static LKCResponse *LKCInvokeNoArg(LKCClient *client, LKCConnectedApp *target, unsigned long oid, NSString *selector, NSTimeInterval timeout) {
    NSDictionary *params = @{@"oid": @(oid), @"text": selector};
    return [client requestType:LookinRequestTypeInvokeMethod data:params channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
}

static NSArray<NSDictionary *> *LKCHitPathJSON(NSArray<LookinDisplayItem *> *path, NSArray<NSValue *> *frames) {
    NSMutableArray *json = [NSMutableArray arrayWithCapacity:path.count];
    [path enumerateObjectsUsingBlock:^(LookinDisplayItem *item, NSUInteger idx, BOOL *stop) {
        CGRect frame = idx < frames.count ? [frames[idx] rectValue] : CGRectZero;
        [json addObject:LKCItemSummaryJSON(item, frame)];
    }];
    return json.copy;
}

static NSArray<NSDictionary *> *LKCHitMatchesJSON(NSArray<NSArray<LookinDisplayItem *> *> *allPaths, NSArray<NSArray<NSValue *> *> *allFrames, NSUInteger limit) {
    NSMutableArray *matches = [NSMutableArray array];
    NSUInteger count = MIN(limit, allPaths.count);
    for (NSUInteger idx = 0; idx < count; idx++) {
        NSArray<LookinDisplayItem *> *candidatePath = allPaths[idx];
        NSArray<NSValue *> *candidateFrames = allFrames[idx];
        if (!candidatePath.count) {
            continue;
        }
        [matches addObject:LKCItemSummaryJSON(candidatePath.lastObject, [candidateFrames.lastObject rectValue])];
    }
    return matches.copy;
}

static int LKCInputCommand(LKCClient *client, LKCConnectedApp *target, NSMutableArray<NSString *> *args, NSTimeInterval timeout) {
    NSString *command = args.firstObject;
    if (!command.length || [command isEqualToString:@"help"] || LKCHasArg(args, @"--help")) {
        LKCPrintInputHelp();
        return 0;
    }
    [args removeObjectAtIndex:0];

    NSString *outputPath = LKCConsumeArgEither(args, @"--output", @"-o");
    BOOL usePoints = LKCConsumeFlag(args, @"--points");
    LKCConsumeFlag(args, @"--pixels");
    BOOL includeOverlays = LKCConsumeFlag(args, @"--include-overlays");
    BOOL dryRun = LKCConsumeFlag(args, @"--dry-run") || [command isEqualToString:@"hit-test"] || [command isEqualToString:@"hit"];
    if (![command isEqualToString:@"tap"] && ![command isEqualToString:@"hit-test"] && ![command isEqualToString:@"hit"]) {
        fprintf(stderr, "Unknown input command: %s\n", command.UTF8String);
        return 2;
    }
    if (args.count < 2) {
        fprintf(stderr, "input %s requires x y.\n", command.UTF8String);
        return 2;
    }

    double rawX = args[0].doubleValue;
    double rawY = args[1].doubleValue;
    double scale = target.appInfo.screenScale > 0 ? target.appInfo.screenScale : 1;
    CGPoint point = usePoints ? CGPointMake(rawX, rawY) : CGPointMake(rawX / scale, rawY / scale);
    NSString *space = usePoints ? @"points" : @"pixels";

    NSDictionary *params = @{@"clientVersion": LKCClientReadableVersion};
    LKCResponse *response = [client requestType:LookinRequestTypeHierarchy data:params channel:target.channel timeout:MAX(timeout, 8.0) pingFirst:YES];
    if (response.error) {
        NSDictionary *json = @{
            @"ok": @NO,
            @"code": @"HIERARCHY_REQUEST_FAILED",
            @"reason": LKCString(response.error.localizedDescription),
            @"suggestion": @"Make sure the target app is foreground, LookinServer is connected, and no other lookinctl process is occupying the single LookinServer connection.",
            @"input": LKCInputPointJSON(rawX, rawY, point, space, scale)
        };
        LKCPrintJSON(json, outputPath);
        return 1;
    }
    if (![response.data isKindOfClass:[LookinHierarchyInfo class]]) {
        NSDictionary *json = @{
            @"ok": @NO,
            @"code": @"UNEXPECTED_HIERARCHY_RESPONSE",
            @"reason": @"LookinServer returned a response that is not LookinHierarchyInfo.",
            @"suggestion": @"Check LookinServer protocol compatibility and retry after refreshing the target app.",
            @"input": LKCInputPointJSON(rawX, rawY, point, space, scale)
        };
        LKCPrintJSON(json, outputPath);
        return 1;
    }

    LookinHierarchyInfo *info = response.data;
    NSMutableArray<NSArray<LookinDisplayItem *> *> *allPaths = [NSMutableArray array];
    NSMutableArray<NSArray<NSValue *> *> *allFrames = [NSMutableArray array];
    LKCCollectHitPaths(info.displayItems, point, includeOverlays, allPaths, allFrames);
    NSArray<LookinDisplayItem *> *path = allPaths.firstObject ?: @[];
    NSArray<NSValue *> *frames = allFrames.firstObject ?: @[];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"ok"] = @NO;
    result[@"mode"] = dryRun ? @"hit-test" : @"tap";
    result[@"input"] = LKCInputPointJSON(rawX, rawY, point, space, scale);
    result[@"path"] = LKCHitPathJSON(path, frames);
    result[@"matchCount"] = @(allPaths.count);
    if (path.count) {
        result[@"hit"] = LKCItemSummaryJSON(path.lastObject, [frames.lastObject rectValue]);
    }
    if (!allPaths.count) {
        result[@"code"] = @"NO_HIT";
        result[@"reason"] = @"No view matched the point in the selected window set.";
        result[@"suggestion"] = @"Default coordinates are screenshot pixels and are divided by screenScale. Use --points for UIKit point coordinates, or --include-overlays if you intentionally want to target overlay windows.";
        LKCPrintJSON(result, outputPath);
        return dryRun ? 0 : 1;
    }
    if (dryRun) {
        result[@"ok"] = @YES;
        result[@"matches"] = LKCHitMatchesJSON(allPaths, allFrames, 10);
        LKCPrintJSON(result, outputPath);
        return 0;
    }

    NSMutableArray *attempts = [NSMutableArray array];
    NSMutableSet<NSString *> *attemptedControlOids = [NSMutableSet set];
    for (NSUInteger pathIndex = 0; pathIndex < allPaths.count; pathIndex++) {
        NSArray<LookinDisplayItem *> *candidatePath = allPaths[pathIndex];
        NSArray<NSValue *> *candidateFrames = allFrames[pathIndex];
        for (NSInteger i = (NSInteger)candidatePath.count - 1; i >= 0; i--) {
            LookinDisplayItem *item = candidatePath[(NSUInteger)i];
            if (!LKCObjectHasClass(item.viewObject, @"UIControl")) {
                continue;
            }
            NSString *oidKey = [NSString stringWithFormat:@"%lu", item.viewObject.oid];
            if ([attemptedControlOids containsObject:oidKey]) {
                continue;
            }
            [attemptedControlOids addObject:oidKey];
            NSMutableDictionary *attempt = [NSMutableDictionary dictionary];
            attempt[@"method"] = @"sendActionsForControlEvents:UIControlEventTouchUpInside";
            attempt[@"target"] = LKCItemSummaryJSON(item, [candidateFrames[(NSUInteger)i] rectValue]);
            LKCResponse *actionResponse = LKCSendControlTouchUpInside(client, target, item.viewObject.oid, timeout);
            if (actionResponse.error) {
                attempt[@"ok"] = @NO;
                attempt[@"error"] = actionResponse.error.localizedDescription ?: @"";
                [attempts addObject:attempt.copy];
                continue;
            }
            attempt[@"ok"] = @YES;
            [attempts addObject:attempt.copy];
            result[@"ok"] = @YES;
            result[@"performed"] = attempt.copy;
            result[@"attempts"] = attempts.copy;
            LKCPrintJSON(result, outputPath);
            return 0;
        }
    }

    NSMutableSet<NSString *> *attemptedAccessibilityOids = [NSMutableSet set];
    for (NSUInteger pathIndex = 0; pathIndex < allPaths.count; pathIndex++) {
        NSArray<LookinDisplayItem *> *candidatePath = allPaths[pathIndex];
        NSArray<NSValue *> *candidateFrames = allFrames[pathIndex];
        for (NSInteger i = (NSInteger)candidatePath.count - 1; i >= 0; i--) {
            LookinDisplayItem *item = candidatePath[(NSUInteger)i];
            if (!item.viewObject.oid) {
                continue;
            }
            NSString *oidKey = [NSString stringWithFormat:@"%lu", item.viewObject.oid];
            if ([attemptedAccessibilityOids containsObject:oidKey]) {
                continue;
            }
            [attemptedAccessibilityOids addObject:oidKey];
            NSMutableDictionary *attempt = [NSMutableDictionary dictionary];
            attempt[@"method"] = @"accessibilityActivate";
            attempt[@"target"] = LKCItemSummaryJSON(item, [candidateFrames[(NSUInteger)i] rectValue]);
            LKCResponse *invokeResponse = LKCInvokeNoArg(client, target, item.viewObject.oid, @"accessibilityActivate", timeout);
            if (invokeResponse.error) {
                attempt[@"ok"] = @NO;
                attempt[@"error"] = invokeResponse.error.localizedDescription ?: @"";
                [attempts addObject:attempt.copy];
                continue;
            }
            attempt[@"response"] = LKCJSONObject(invokeResponse.data ?: @{});
            BOOL truthy = LKCInvokeResponseLooksTruthy(invokeResponse);
            attempt[@"ok"] = @(truthy);
            [attempts addObject:attempt.copy];
            if (truthy) {
                result[@"ok"] = @YES;
                result[@"performed"] = attempt.copy;
                result[@"attempts"] = attempts.copy;
                LKCPrintJSON(result, outputPath);
                return 0;
            }
        }
    }

    result[@"attempts"] = attempts.copy;
    result[@"matches"] = LKCHitMatchesJSON(allPaths, allFrames, 10);
    if (attempts.count) {
        result[@"code"] = @"ACTION_FAILED";
        result[@"reason"] = @"Matched views and tried semantic activation, but every attempt either failed or returned false.";
        result[@"suggestion"] = @"Inspect attempts[].error/response. This path only supports UIControl touchUpInside and accessibilityActivate; use a LookinServer input extension or WDA for physical touch injection.";
    } else {
        result[@"code"] = @"NO_ACTIONABLE_TARGET";
        result[@"reason"] = @"Matched views, but none of the candidates is an actionable UIControl and no candidate could be activated semantically.";
        result[@"suggestion"] = @"Run input hit-test on this coordinate, choose a different point inside a UIControl/accessibility element, or add native input support to LookinServer for this custom view.";
    }
    LKCPrintJSON(result, outputPath);
    return 1;
}

static int LKCLookinCommand(LKCClient *client, LKCConnectedApp *target, NSMutableArray<NSString *> *args, NSTimeInterval timeout) {
    NSString *command = args.firstObject;
    if (!command.length || [command isEqualToString:@"help"] || LKCHasArg(args, @"--help")) {
        LKCPrintLookinHelp();
        return 0;
    }
    [args removeObjectAtIndex:0];
    NSString *outputPath = LKCConsumeArgEither(args, @"--output", @"-o");

    if ([command isEqualToString:@"app"]) {
        LKCPrintJSON(LKCAppInfoJSON(target, 0), outputPath);
        return 0;
    }

    if ([command isEqualToString:@"ping"]) {
        LKCResponse *response = [client requestType:LookinRequestTypePing data:nil channel:target.channel timeout:timeout pingFirst:NO];
        if (response.error) {
            return LKCPrintResponseError(@"Ping failed", response);
        }
        LookinConnectionResponseAttachment *attachment = response.data;
        LKCPrintJSON(@{@"ok": @YES, @"serverVersion": @(attachment.lookinServerVersion)}, outputPath);
        return 0;
    }

    if ([command isEqualToString:@"hierarchy"] || [command isEqualToString:@"dump"]) {
        NSMutableArray *dumpArgs = args.mutableCopy;
        if (outputPath.length) {
            [dumpArgs addObject:@"--output"];
            [dumpArgs addObject:outputPath];
        }
        return LKCDumpHierarchy(client, target, dumpArgs, timeout);
    }

    if ([command isEqualToString:@"screenshot"] || [command isEqualToString:@"screencap"]) {
        LKCConsumeFlag(args, @"-p");
        BOOL preview = LKCConsumeFlag(args, @"--preview");
        return LKCScreenshot(client, target, outputPath, timeout, preview);
    }

    if ([command isEqualToString:@"current-vc"] || [command isEqualToString:@"currentvc"] || [command isEqualToString:@"vc"]) {
        NSDictionary *params = @{@"clientVersion": LKCClientReadableVersion};
        LKCResponse *response = [client requestType:LookinRequestTypeHierarchy data:params channel:target.channel timeout:MAX(timeout, 8.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Current VC failed", response);
        }
        if (![response.data isKindOfClass:[LookinHierarchyInfo class]]) {
            fprintf(stderr, "Current VC failed: unexpected response.\n");
            return 1;
        }
        LookinHierarchyInfo *info = response.data;
        NSArray<NSDictionary *> *vcs = LKCCurrentViewControllersJSON(info.displayItems);
        NSMutableArray *businessCandidates = [NSMutableArray array];
        NSMutableArray *overlays = [NSMutableArray array];
        for (NSDictionary *vc in vcs) {
            if ([vc[@"overlay"] boolValue]) {
                [overlays addObject:vc];
            } else {
                [businessCandidates addObject:vc];
            }
        }
        NSDictionary *json = @{
            @"app": LKCAppInfoJSON(target, 0),
            @"current": businessCandidates.firstObject ?: vcs.firstObject ?: @{},
            @"businessCandidates": businessCandidates.copy,
            @"overlays": overlays.copy,
            @"all": vcs
        };
        LKCPrintJSON(json, outputPath);
        return 0;
    }

    if ([command isEqualToString:@"details"]) {
        NSString *screenshot = LKCConsumeArg(args, @"--screenshot") ?: @"none";
        NSString *attrs = LKCConsumeArg(args, @"--attrs") ?: @"need";
        BOOL basis = LKCConsumeFlag(args, @"--basis") || !LKCHasArg(args, @"--no-basis");
        LKCConsumeFlag(args, @"--no-basis");
        BOOL subitems = LKCConsumeFlag(args, @"--subitems");
        NSMutableArray<NSNumber *> *oids = LKCOidsFromArgs(args);
        if (!oids.count) {
            fprintf(stderr, "details requires at least one oid.\n");
            return 2;
        }
        NSMutableArray *tasks = [NSMutableArray arrayWithCapacity:oids.count];
        for (NSNumber *oid in oids) {
            [tasks addObject:LKCTaskForOid(oid.unsignedLongValue, LKCParseScreenshotType(screenshot), LKCParseAttrRequest(attrs), basis, subitems)];
        }
        LookinStaticAsyncUpdateTasksPackage *package = [LookinStaticAsyncUpdateTasksPackage new];
        package.tasks = tasks.copy;
        LKCResponse *response = [client requestType:LookinRequestTypeHierarchyDetails data:@[package] channel:target.channel timeout:MAX(timeout, 10.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Details failed", response);
        }
        LKCPrintJSON(response.data ?: @[], outputPath);
        return 0;
    }

    if ([command isEqualToString:@"attrs"]) {
        if (!args.count) {
            fprintf(stderr, "attrs requires a layer oid.\n");
            return 2;
        }
        unsigned long oid = strtoul(args.firstObject.UTF8String, NULL, 10);
        LKCResponse *response = [client requestType:LookinRequestTypeAllAttrGroups data:@(oid) channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Attrs failed", response);
        }
        LKCPrintJSON(response.data ?: @[], outputPath);
        return 0;
    }

    if ([command isEqualToString:@"selectors"] || [command isEqualToString:@"methods"]) {
        BOOL hasArg = LKCConsumeFlag(args, @"--has-arg");
        if (!args.count) {
            fprintf(stderr, "selectors requires a class name.\n");
            return 2;
        }
        NSDictionary *params = @{@"className": args.firstObject, @"hasArg": @(hasArg)};
        LKCResponse *response = [client requestType:LookinRequestTypeAllSelectorNames data:params channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Selectors failed", response);
        }
        LKCPrintJSON(response.data ?: @[], outputPath);
        return 0;
    }

    if ([command isEqualToString:@"invoke"]) {
        if (args.count < 2) {
            fprintf(stderr, "invoke requires <oid> <selector>.\n");
            return 2;
        }
        NSDictionary *params = @{@"oid": @(strtoul(args[0].UTF8String, NULL, 10)), @"text": args[1]};
        LKCResponse *response = [client requestType:LookinRequestTypeInvokeMethod data:params channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Invoke failed", response);
        }
        LKCPrintJSON(response.data ?: @{}, outputPath);
        return 0;
    }

    if ([command isEqualToString:@"object"]) {
        if (!args.count) {
            fprintf(stderr, "object requires an oid.\n");
            return 2;
        }
        LKCResponse *response = [client requestType:LookinRequestTypeFetchObject data:@(strtoul(args.firstObject.UTF8String, NULL, 10)) channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Object fetch failed", response);
        }
        LKCPrintJSON(response.data ?: @{}, outputPath);
        return 0;
    }

    if ([command isEqualToString:@"image"]) {
        if (!args.count) {
            fprintf(stderr, "image requires an image view oid.\n");
            return 2;
        }
        LKCResponse *response = [client requestType:LookinRequestTypeFetchImageViewImage data:@(strtoul(args.firstObject.UTF8String, NULL, 10)) channel:target.channel timeout:MAX(timeout, 8.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Image fetch failed", response);
        }
        if (![response.data isKindOfClass:[NSData class]]) {
            fprintf(stderr, "Image fetch failed: unexpected response.\n");
            return 1;
        }
        NSData *imageData = response.data;
        if (outputPath.length) {
            NSString *path = outputPath.stringByStandardizingPath;
            if (![imageData writeToFile:path atomically:YES]) {
                fprintf(stderr, "Failed to write %s\n", path.UTF8String);
                return 2;
            }
        } else {
            fwrite(imageData.bytes, 1, imageData.length, stdout);
        }
        return 0;
    }

    if ([command isEqualToString:@"recognizer"] || [command isEqualToString:@"gesture-enable"]) {
        if (args.count < 2) {
            fprintf(stderr, "recognizer requires <recognizer-oid> enable|disable.\n");
            return 2;
        }
        BOOL enable = LKCParseBool(args[1]);
        NSDictionary *params = @{@"oid": @(strtoull(args[0].UTF8String, NULL, 10)), @"enable": @(enable)};
        LKCResponse *response = [client requestType:LookinRequestTypeModifyRecognizerEnable data:params channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Recognizer modification failed", response);
        }
        LKCPrintJSON(@{@"enabled": response.data ?: @NO}, outputPath);
        return 0;
    }

    if ([command isEqualToString:@"set-builtin"]) {
        if (args.count < 4) {
            fprintf(stderr, "set-builtin requires <target-oid> <setter> <attr-type> <value>.\n");
            return 2;
        }
        LookinAttrType attrType;
        if (!LKCParseAttrType(args[2], &attrType)) {
            fprintf(stderr, "Unknown attr type: %s\n", args[2].UTF8String);
            return 2;
        }
        id value = LKCParseAttrValue(attrType, args[3]);
        LookinAttributeModification *modification = [LookinAttributeModification new];
        modification.targetOid = strtoul(args[0].UTF8String, NULL, 10);
        modification.setterSelector = NSSelectorFromString(args[1]);
        modification.attrType = attrType;
        modification.value = value;
        modification.clientReadableVersion = LKCClientReadableVersion;
        LKCResponse *response = [client requestType:LookinRequestTypeInbuiltAttrModification data:modification channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Built-in modification failed", response);
        }
        LKCPrintJSON(response.data ?: @{}, outputPath);
        return 0;
    }

    if ([command isEqualToString:@"set-custom"]) {
        if (args.count < 3) {
            fprintf(stderr, "set-custom requires <custom-setter-id> <attr-type> <value>.\n");
            return 2;
        }
        LookinAttrType attrType;
        if (!LKCParseAttrType(args[1], &attrType)) {
            fprintf(stderr, "Unknown attr type: %s\n", args[1].UTF8String);
            return 2;
        }
        LookinCustomAttrModification *modification = [LookinCustomAttrModification new];
        modification.customSetterID = args[0];
        modification.attrType = attrType;
        modification.value = LKCParseAttrValue(attrType, args[2]);
        LKCResponse *response = [client requestType:LookinRequestTypeCustomAttrModification data:modification channel:target.channel timeout:MAX(timeout, 5.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Custom modification failed", response);
        }
        LKCPrintJSON(@{@"ok": @YES}, outputPath);
        return 0;
    }

    if ([command isEqualToString:@"patch"]) {
        NSString *screenshot = LKCConsumeArg(args, @"--screenshot") ?: @"none";
        NSMutableArray<NSNumber *> *oids = LKCOidsFromArgs(args);
        if (!oids.count) {
            fprintf(stderr, "patch requires at least one oid.\n");
            return 2;
        }
        NSMutableArray *tasks = [NSMutableArray arrayWithCapacity:oids.count];
        for (NSNumber *oid in oids) {
            [tasks addObject:LKCTaskForOid(oid.unsignedLongValue, LKCParseScreenshotType(screenshot), LookinDetailUpdateTaskAttrRequest_NotNeed, NO, NO)];
        }
        LKCResponse *response = [client requestType:LookinRequestTypeAttrModificationPatch data:tasks.copy channel:target.channel timeout:MAX(timeout, 8.0) pingFirst:YES];
        if (response.error) {
            return LKCPrintResponseError(@"Patch failed", response);
        }
        LKCPrintJSON(response.data ?: @[], outputPath);
        return 0;
    }

    if ([command isEqualToString:@"cancel-details"]) {
        NSError *error = [client pushType:LookinPush_CanceHierarchyDetails data:nil channel:target.channel timeout:timeout];
        if (error) {
            fprintf(stderr, "Cancel details failed: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        LKCPrintJSON(@{@"ok": @YES}, outputPath);
        return 0;
    }

    fprintf(stderr, "Unknown lookin command: %s\n", command.UTF8String);
    return 2;
}

static int LKCShellCommand(LKCClient *client, LKCConnectedApp *target, NSMutableArray<NSString *> *args, NSTimeInterval timeout) {
    NSString *command = args.firstObject;
    if (!command.length || LKCIsHelpToken(command)) {
        LKCPrintShellHelp();
        return 0;
    }
    [args removeObjectAtIndex:0];

    if ([command isEqualToString:@"uiautomator"]) {
        NSString *subcommand = args.firstObject;
        if ([subcommand isEqualToString:@"dump"]) {
            [args removeObjectAtIndex:0];
            return LKCDumpHierarchy(client, target, args, timeout);
        }
        fprintf(stderr, "Unknown uiautomator command: %s\n", LKCString(subcommand).UTF8String);
        return 2;
    }

    if ([command isEqualToString:@"screencap"]) {
        LKCConsumeFlag(args, @"-p");
        BOOL preview = LKCConsumeFlag(args, @"--preview");
        NSString *outputPath = LKCConsumeArgEither(args, @"--output", @"-o");
        return LKCScreenshot(client, target, outputPath, timeout, preview);
    }

    if ([command isEqualToString:@"input"]) {
        return LKCInputCommand(client, target, args, timeout);
    }

    if ([command isEqualToString:@"dumpsys"]) {
        NSString *service = args.firstObject;
        if ([service isEqualToString:@"lookin"]) {
            LKCPrintJSON(LKCAppInfoJSON(target, 0), LKCArgValue(args, @"--output") ?: LKCArgValue(args, @"-o"));
            return 0;
        }
        fprintf(stderr, "Unknown dumpsys service: %s\n", LKCString(service).UTF8String);
        return 2;
    }

    if ([command isEqualToString:@"lookin"]) {
        return LKCLookinCommand(client, target, args, timeout);
    }

    NSMutableArray *lookinArgs = [NSMutableArray arrayWithObject:command];
    [lookinArgs addObjectsFromArray:args];
    return LKCLookinCommand(client, target, lookinArgs, timeout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            [args addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        if (!args.count || [args.firstObject isEqualToString:@"--help"] || [args.firstObject isEqualToString:@"-h"]) {
            LKCUsage();
            return 0;
        }
        if ([args.firstObject isEqualToString:@"help"]) {
            [args removeObjectAtIndex:0];
            return LKCPrintHelp(args);
        }
        if ([args.firstObject isEqualToString:@"--version"] || [args.firstObject isEqualToString:@"version"]) {
            printf("%s\n", LKCVersion.UTF8String);
            return 0;
        }

        NSString *serial = LKCConsumeArgEither(args, @"-s", @"--serial");
        NSString *waitString = LKCConsumeArg(args, @"--wait");
        NSString *timeoutString = LKCConsumeArg(args, @"--timeout");
        NSTimeInterval wait = waitString.length ? waitString.doubleValue : 0.3;
        NSTimeInterval timeout = timeoutString.length ? timeoutString.doubleValue : 2.0;

        NSString *command = args.firstObject;
        if (!command.length) {
            LKCUsage();
            return 0;
        }
        [args removeObjectAtIndex:0];

        LKCClient *client = [LKCClient new];

        if ([command isEqualToString:@"devices"] || [command isEqualToString:@"list"]) {
            return LKCDevices(client, args, wait, timeout);
        }

        if ([command isEqualToString:@"dump"]) {
            if (LKCHasArg(args, @"--help") || LKCHasArg(args, @"-h") || [args.firstObject isEqualToString:@"help"]) {
                LKCPrintDumpHelp();
                return 0;
            }
            NSString *selector = serial ?: LKCConsumeArg(args, @"--bundle") ?: LKCConsumeArg(args, @"--index");
            LKCConnectedApp *target = [client findAppWithSelector:selector wait:wait timeout:timeout];
            if (!target) {
                fprintf(stderr, "No LookinServer app matched target: %s\n", LKCString(selector ?: @"<default>").UTF8String);
                return 1;
            }
            return LKCDumpHierarchy(client, target, args, timeout);
        }

        if ([command isEqualToString:@"shell"]) {
            if (!args.count || LKCIsHelpToken(args.firstObject) || LKCHasArg(args, @"--help") || LKCHasArg(args, @"-h")) {
                NSMutableArray<NSString *> *helpTopics = [NSMutableArray arrayWithObject:@"shell"];
                for (NSString *arg in args) {
                    if (![arg hasPrefix:@"-"] && ![arg isEqualToString:@"help"]) {
                        [helpTopics addObject:arg];
                    }
                }
                return LKCPrintHelp(helpTopics);
            }
            LKCConnectedApp *target = [client findAppWithSelector:serial wait:wait timeout:timeout];
            if (!target) {
                fprintf(stderr, "No LookinServer app matched target: %s\n", LKCString(serial ?: @"<default>").UTF8String);
                return 1;
            }
            return LKCShellCommand(client, target, args, timeout);
        }

        fprintf(stderr, "Unknown command: %s\n", command.UTF8String);
        LKCUsage();
        return 2;
    }
}
