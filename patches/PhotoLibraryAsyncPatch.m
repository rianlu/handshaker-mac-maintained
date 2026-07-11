#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <limits.h>
#import <signal.h>

typedef void (*HSParserIMP)(id, SEL, id);
typedef void (*HSReloadIMP)(id, SEL, BOOL, id);
typedef void (*HSObjectSetterIMP)(id, SEL, id);
typedef void (*HSVMsgSend)(id, SEL);
typedef id (*HSInitMsgSend)(id, SEL);
typedef id (*HSIdLongLongMsgSend)(id, SEL, long long);
typedef void (*HSSetMaskIMP)(id, SEL, NSUInteger);
typedef id (*HSUSBHandshakeIMP)(id, SEL, int);

@interface HSPreparedPhotoImageBox : NSObject
@property(nonatomic) NSSize targetSize;
@property(nonatomic) CGFloat scale;
@property(nonatomic, strong) NSImage *image;
@end

@implementation HSPreparedPhotoImageBox
@end

@interface HSPhotoCacheFileEntry : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) unsigned long long size;
@property(nonatomic, strong) NSDate *date;
@end

@implementation HSPhotoCacheFileEntry
@end

static HSParserIMP HSOriginalParser = NULL;
static HSReloadIMP HSOriginalReload = NULL;
static HSVMsgSend HSOriginalReloadGrid = NULL;
static HSObjectSetterIMP HSOriginalSetImage = NULL;
static HSInitMsgSend HSOriginalPhotoItemInit = NULL;
static HSObjectSetterIMP HSOriginalSetRepresentedObject = NULL;
static HSVMsgSend HSOriginalFRLogAsking = NULL;
static HSSetMaskIMP HSOriginalSetExceptionHandlingMask = NULL;
static HSSetMaskIMP HSOriginalSetExceptionHangingMask = NULL;
static HSUSBHandshakeIMP HSOriginalUSBHandshake = NULL;
static __weak id HSLastPhotoViewController = nil;
static char HSPreparedPhotoImageKey;
static char HSPhotoLoadingOverlayKey;
static char HSPhotoLibraryParsingKey;
static char HSPhotoLibraryParseTokenKey;
static char HSPhotoItemLastImageKey;
static char HSPhotoItemConfiguredKey;
static dispatch_queue_t HSPhotoParserQueue;
static dispatch_queue_t HSPhotoCacheCleanupQueue;
static NSUInteger HSPhotoLibraryParseGeneration = 0;
static BOOL HSPhotoCacheCleanupScheduled = NO;
static BOOL HSSwizzledParser = NO;
static BOOL HSSwizzledReload = NO;
static BOOL HSSwizzledReloadGrid = NO;
static BOOL HSSwizzledPhotoItemImageSetter = NO;
static BOOL HSSwizzledPhotoItemLifecycle = NO;
static BOOL HSSwizzledFRLogAsking = NO;
static BOOL HSSwizzledExceptionHandlerMasks = NO;
static BOOL HSSwizzledUSBHandshake = NO;
static BOOL HSRegisteredLegacyPromptDefaults = NO;
static BOOL HSLoggedInstall = NO;
static BOOL HSDiagnosticsLogged = NO;

static const unsigned long long HSPhotoCacheDefaultMaxBytes = 1024ULL * 1024ULL * 1024ULL;
static const unsigned long long HSPhotoCacheDefaultTargetBytes = 768ULL * 1024ULL * 1024ULL;
static const unsigned long long HSPhotoCacheLowDiskMaxBytes = 512ULL * 1024ULL * 1024ULL;
static const unsigned long long HSPhotoCacheLowDiskTargetBytes = 384ULL * 1024ULL * 1024ULL;
static const unsigned long long HSPhotoCacheLowDiskFreeBytes = 10ULL * 1024ULL * 1024ULL * 1024ULL;
static const int HSUSBHandshakeTimeoutMilliseconds = 15000;

static void HSCallIfResponds(id target, SEL selector) {
    if (target && [target respondsToSelector:selector]) {
        ((HSVMsgSend)objc_msgSend)(target, selector);
    }
}

static CGFloat HSBackingScaleForView(NSView *view) {
    CGFloat scale = view.window.backingScaleFactor;
    return scale > 0.0 ? scale : 1.0;
}

static id HSValueForKey(id target, NSString *key) {
    if (!target || !key) {
        return nil;
    }

    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void HSSetValueForKey(id target, NSString *key, id value) {
    if (!target || !key || !value) {
        return;
    }

    @try {
        [target setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static NSView *HSViewForController(id controller) {
    if ([controller isKindOfClass:[NSViewController class]]) {
        return ((NSViewController *)controller).view;
    }

    id view = HSValueForKey(controller, @"view");
    return [view isKindOfClass:[NSView class]] ? view : nil;
}

static long long HSLongLongForKey(id target, NSString *key, BOOL *hasValue) {
    id value = HSValueForKey(target, key);
    BOOL valid = value && value != [NSNull null] && [value respondsToSelector:@selector(longLongValue)];
    if (hasValue) {
        *hasValue = valid;
    }
    return valid ? [value longLongValue] : 0;
}

static id HSAlbumForAlbumId(id albums, long long albumId) {
    SEL selector = NSSelectorFromString(@"itemForAlbumId:");
    if (!albums || albumId == 0 || ![albums respondsToSelector:selector]) {
        return nil;
    }
    return ((HSIdLongLongMsgSend)objc_msgSend)(albums, selector, albumId);
}

static BOOL HSIsAlbumsViewModel(id model) {
    Class albumsClass = NSClassFromString(@"SFPhotoAlbumsViewModel");
    return albumsClass && model && [model isKindOfClass:albumsClass];
}

static NSString *HSHandShakerApplicationSupportPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *basePath = paths.firstObject;
    return basePath.length ? [basePath stringByAppendingPathComponent:@"HandShaker"] : nil;
}

static NSString *HSPhotoThumbnailCachePath(void) {
    return [[HSHandShakerApplicationSupportPath() stringByAppendingPathComponent:@"thumbnails"] stringByStandardizingPath];
}

static unsigned long long HSDirectorySizeAtPath(NSString *path) {
    if (!path.length) {
        return 0;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
        return 0;
    }

    if (!isDirectory) {
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];
        return [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
    }

    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:[NSURL fileURLWithPath:path isDirectory:YES]
                                         includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLTotalFileAllocatedSizeKey, NSURLFileSizeKey]
                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                       errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
        return YES;
    }];

    for (NSURL *url in enumerator) {
        NSNumber *isRegularFile = nil;
        if (![url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil] || ![isRegularFile boolValue]) {
            continue;
        }

        NSNumber *fileSize = nil;
        if (![url getResourceValue:&fileSize forKey:NSURLTotalFileAllocatedSizeKey error:nil] || !fileSize) {
            [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        }
        total += [fileSize unsignedLongLongValue];
    }

    return total;
}

static unsigned long long HSFreeBytesForPath(NSString *path) {
    if (!path.length) {
        return ULLONG_MAX;
    }

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:nil];
    NSNumber *freeSize = [attributes objectForKey:NSFileSystemFreeSize];
    return freeSize ? [freeSize unsignedLongLongValue] : ULLONG_MAX;
}

static void HSLogRuntimeDiagnostics(void) {
    if (HSDiagnosticsLogged) {
        return;
    }
    HSDiagnosticsLogged = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            @try {
                NSProcessInfo *processInfo = [NSProcessInfo processInfo];
                NSString *supportPath = HSHandShakerApplicationSupportPath();
                NSString *thumbnailPath = HSPhotoThumbnailCachePath();
                NSString *deviceCachePath = [supportPath stringByAppendingPathComponent:@"DeviceCache"];
                NSLog(@"[HandShakerMaintained] Runtime diagnostics pid=%d os=%@ app=%@ support=%@ thumbnails=%lluMB deviceCache=%lluMB",
                      processInfo.processIdentifier,
                      processInfo.operatingSystemVersionString,
                      [[NSBundle mainBundle] bundlePath],
                      supportPath ?: @"",
                      HSDirectorySizeAtPath(thumbnailPath) / 1024ULL / 1024ULL,
                      HSDirectorySizeAtPath(deviceCachePath) / 1024ULL / 1024ULL);
            } @catch (NSException *exception) {
                NSLog(@"[HandShakerMaintained] Runtime diagnostics failed: %@", exception);
            }
        }
    });
}

static void HSRemoveEmptyDirectoriesAtPath(NSString *rootPath) {
    if (!rootPath.length) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:[NSURL fileURLWithPath:rootPath isDirectory:YES]
                                         includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                       errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
        return YES;
    }];

    NSMutableArray *directories = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        NSNumber *isDirectory = nil;
        if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil] && [isDirectory boolValue]) {
            [directories addObject:url.path];
        }
    }

    for (NSString *path in [directories reverseObjectEnumerator]) {
        NSArray *children = [fileManager contentsOfDirectoryAtPath:path error:nil];
        if (children && children.count == 0) {
            [fileManager removeItemAtPath:path error:nil];
        }
    }
}

static void HSCleanupPhotoThumbnailCache(NSString *reason) {
    @autoreleasepool {
        NSString *cachePath = HSPhotoThumbnailCachePath();
        if (!cachePath.length) {
            return;
        }

        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:cachePath isDirectory:&isDirectory] || !isDirectory) {
            return;
        }

        unsigned long long freeBytes = HSFreeBytesForPath(cachePath);
        unsigned long long maxBytes = freeBytes < HSPhotoCacheLowDiskFreeBytes ? HSPhotoCacheLowDiskMaxBytes : HSPhotoCacheDefaultMaxBytes;
        unsigned long long targetBytes = freeBytes < HSPhotoCacheLowDiskFreeBytes ? HSPhotoCacheLowDiskTargetBytes : HSPhotoCacheDefaultTargetBytes;
        unsigned long long totalBytes = 0;
        NSMutableArray<HSPhotoCacheFileEntry *> *files = [NSMutableArray array];

        NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:[NSURL fileURLWithPath:cachePath isDirectory:YES]
                                             includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLTotalFileAllocatedSizeKey, NSURLFileSizeKey, NSURLContentModificationDateKey]
                                                                options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
            return YES;
        }];

        for (NSURL *url in enumerator) {
            NSNumber *isRegularFile = nil;
            if (![url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil] || ![isRegularFile boolValue]) {
                continue;
            }

            NSNumber *fileSize = nil;
            if (![url getResourceValue:&fileSize forKey:NSURLTotalFileAllocatedSizeKey error:nil] || !fileSize) {
                [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            }

            HSPhotoCacheFileEntry *entry = [HSPhotoCacheFileEntry new];
            entry.path = url.path;
            entry.size = [fileSize unsignedLongLongValue];
            NSDate *date = nil;
            [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
            entry.date = date ?: [NSDate distantPast];
            totalBytes += entry.size;
            [files addObject:entry];
        }

        unsigned long long deviceCacheBytes = HSDirectorySizeAtPath([HSHandShakerApplicationSupportPath() stringByAppendingPathComponent:@"DeviceCache"]);
        NSLog(@"[HandShakerMaintained] Photo cache scan reason=%@ thumbnails=%lluMB files=%lu deviceCache=%lluMB free=%lluMB limit=%lluMB",
              reason ?: @"unknown",
              totalBytes / 1024ULL / 1024ULL,
              (unsigned long)files.count,
              deviceCacheBytes / 1024ULL / 1024ULL,
              freeBytes == ULLONG_MAX ? 0 : freeBytes / 1024ULL / 1024ULL,
              maxBytes / 1024ULL / 1024ULL);

        if (totalBytes <= maxBytes) {
            return;
        }

        [files sortUsingComparator:^NSComparisonResult(HSPhotoCacheFileEntry *first, HSPhotoCacheFileEntry *second) {
            return [first.date compare:second.date];
        }];

        unsigned long long removedBytes = 0;
        NSUInteger removedCount = 0;
        for (HSPhotoCacheFileEntry *entry in files) {
            if (totalBytes <= targetBytes) {
                break;
            }

            if ([fileManager removeItemAtPath:entry.path error:nil]) {
                totalBytes = totalBytes > entry.size ? totalBytes - entry.size : 0;
                removedBytes += entry.size;
                removedCount += 1;
            }
        }

        HSRemoveEmptyDirectoriesAtPath(cachePath);
        NSLog(@"[HandShakerMaintained] Photo cache cleanup removed=%lluMB files=%lu remaining=%lluMB target=%lluMB",
              removedBytes / 1024ULL / 1024ULL,
              (unsigned long)removedCount,
              totalBytes / 1024ULL / 1024ULL,
              targetBytes / 1024ULL / 1024ULL);
    }
}

static void HSSchedulePhotoCacheCleanup(NSString *reason) {
    if (!HSPhotoCacheCleanupQueue) {
        HSPhotoCacheCleanupQueue = dispatch_queue_create("com.handshaker.maintained.photo-cache-cleanup", DISPATCH_QUEUE_SERIAL);
    }

    @synchronized ([NSApplication class]) {
        if (HSPhotoCacheCleanupScheduled) {
            return;
        }
        HSPhotoCacheCleanupScheduled = YES;
    }

    NSString *cleanupReason = [reason copy];
    dispatch_async(HSPhotoCacheCleanupQueue, ^{
        HSCleanupPhotoThumbnailCache(cleanupReason);
        @synchronized ([NSApplication class]) {
            HSPhotoCacheCleanupScheduled = NO;
        }
    });
}

static void HSRestorePhotoSelectionAfterParse(id controller) {
    id albums = HSValueForKey(controller, @"pmodelAlbums");
    if (!albums) {
        return;
    }

    id openedAlbum = HSValueForKey(controller, @"pmodelOpenedAlbum");
    BOOL hasAlbumId = NO;
    long long albumId = HSLongLongForKey(openedAlbum, @"albumId", &hasAlbumId);
    id refreshedOpenedAlbum = hasAlbumId ? HSAlbumForAlbumId(albums, albumId) : nil;
    if (refreshedOpenedAlbum) {
        openedAlbum = refreshedOpenedAlbum;
        HSSetValueForKey(controller, @"pmodelOpenedAlbum", openedAlbum);
    }

    BOOL hasLastFolderSelection = NO;
    long long lastFolderSelection = HSLongLongForKey(controller, @"lastFolderSelection", &hasLastFolderSelection);
    id targetModel = nil;
    if (hasLastFolderSelection && lastFolderSelection == 1) {
        targetModel = HSValueForKey(albums, @"totalCameraAlbum");
    } else if (hasLastFolderSelection && lastFolderSelection == 0) {
        targetModel = HSValueForKey(albums, @"entireAlbum");
    } else if (openedAlbum) {
        targetModel = openedAlbum;
    } else {
        id currentModel = HSValueForKey(controller, @"currentModel");
        if (!currentModel || HSIsAlbumsViewModel(currentModel)) {
            targetModel = HSValueForKey(albums, @"totalCameraAlbum") ?: HSValueForKey(albums, @"entireAlbum");
        }
    }

    if (targetModel) {
        HSSetValueForKey(controller, @"currentModel", targetModel);
    }
}

static NSRect HSRectFromSelector(id target, SEL selector) {
    if (!target || ![target respondsToSelector:selector]) {
        return NSZeroRect;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType, @encode(NSRect)) != 0) {
        return NSZeroRect;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation invoke];

    NSRect rect = NSZeroRect;
    [invocation getReturnValue:&rect];
    return rect;
}

static NSImage *HSPreparedPhotoImageForView(id itemView, id imageValue) {
    if (![itemView isKindOfClass:[NSView class]] || ![imageValue isKindOfClass:[NSImage class]]) {
        return imageValue;
    }

    NSView *view = (NSView *)itemView;
    NSImage *image = (NSImage *)imageValue;
    NSRect imageRect = HSRectFromSelector(itemView, NSSelectorFromString(@"imageRect"));
    if (NSIsEmptyRect(imageRect)) {
        imageRect = view.bounds;
    }
    if (NSIsEmptyRect(imageRect)) {
        return image;
    }

    NSSize targetSize = NSMakeSize(ceil(NSWidth(imageRect)), ceil(NSHeight(imageRect)));
    if (targetSize.width < 1.0 || targetSize.height < 1.0) {
        return image;
    }

    CGFloat scale = HSBackingScaleForView(view);
    NSInteger pixelsWide = (NSInteger)ceil(targetSize.width * scale);
    NSInteger pixelsHigh = (NSInteger)ceil(targetSize.height * scale);
    if (pixelsWide < 1 || pixelsHigh < 1) {
        return image;
    }

    NSSize sourceSize = image.size;
    if (sourceSize.width <= targetSize.width + 1.0 && sourceSize.height <= targetSize.height + 1.0) {
        return image;
    }

    HSPreparedPhotoImageBox *box = objc_getAssociatedObject(image, &HSPreparedPhotoImageKey);
    if (box && NSEqualSizes(box.targetSize, targetSize) && fabs(box.scale - scale) < 0.01 && box.image) {
        return box.image;
    }

    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                       pixelsWide:pixelsWide
                                                                       pixelsHigh:pixelsHigh
                                                                    bitsPerSample:8
                                                                  samplesPerPixel:4
                                                                         hasAlpha:YES
                                                                         isPlanar:NO
                                                                   colorSpaceName:NSDeviceRGBColorSpace
                                                                      bytesPerRow:0
                                                                     bitsPerPixel:0];
    if (!bitmap) {
        return image;
    }
    bitmap.size = targetSize;

    NSImage *preparedImage = [[NSImage alloc] initWithSize:targetSize];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    context.imageInterpolation = NSImageInterpolationHigh;
    [image drawInRect:NSMakeRect(0.0, 0.0, targetSize.width, targetSize.height)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    [preparedImage addRepresentation:bitmap];
    preparedImage.cacheMode = NSImageCacheAlways;

    box = [HSPreparedPhotoImageBox new];
    box.targetSize = targetSize;
    box.scale = scale;
    box.image = preparedImage;
    objc_setAssociatedObject(image, &HSPreparedPhotoImageKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return preparedImage;
}

static void HSConfigurePhotoItemView(id itemView) {
    if (![itemView isKindOfClass:[NSView class]]) {
        return;
    }

    NSNumber *configured = objc_getAssociatedObject(itemView, &HSPhotoItemConfiguredKey);
    if ([configured boolValue]) {
        return;
    }

    NSView *view = (NSView *)itemView;
    view.wantsLayer = YES;
    view.canDrawSubviewsIntoLayer = YES;
    view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    view.layer.drawsAsynchronously = YES;
    objc_setAssociatedObject(itemView, &HSPhotoItemConfiguredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void HSRefreshPhotoViewController(id controller) {
    HSRestorePhotoSelectionAfterParse(controller);
    HSCallIfResponds(controller, NSSelectorFromString(@"reloadDataRememberState"));
    HSCallIfResponds(controller, NSSelectorFromString(@"reloadGrid"));
    HSCallIfResponds(controller, NSSelectorFromString(@"updateEmptyView"));
}

static BOOL HSIsPhotoLibraryParsing(id controller) {
    NSNumber *parsing = controller ? objc_getAssociatedObject(controller, &HSPhotoLibraryParsingKey) : nil;
    return [parsing respondsToSelector:@selector(boolValue)] && [parsing boolValue];
}

static NSUInteger HSNextPhotoLibraryParseToken(void) {
    @synchronized ([NSApplication class]) {
        HSPhotoLibraryParseGeneration += 1;
        return HSPhotoLibraryParseGeneration;
    }
}

static NSString *HSPhotoLoadingTextForController(id controller) {
    if (!HSIsPhotoLibraryParsing(controller)) {
        return nil;
    }

    id currentModel = HSValueForKey(controller, @"currentModel");
    if (HSIsAlbumsViewModel(currentModel)) {
        return @"正在整理相册...";
    }

    BOOL hasLastFolderSelection = NO;
    long long lastFolderSelection = HSLongLongForKey(controller, @"lastFolderSelection", &hasLastFolderSelection);
    if (hasLastFolderSelection && lastFolderSelection == 1) {
        return @"正在整理相机相册...";
    }

    return nil;
}

static void HSSetPhotoLoadingVisible(id controller, NSString *text) {
    NSView *hostView = HSViewForController(controller);
    if (!hostView) {
        return;
    }

    NSView *overlay = objc_getAssociatedObject(controller, &HSPhotoLoadingOverlayKey);
    if (!text.length) {
        [overlay removeFromSuperview];
        return;
    }

    [overlay removeFromSuperview];
    overlay = nil;

    if (!overlay) {
        overlay = [[NSView alloc] initWithFrame:hostView.bounds];
        overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        overlay.wantsLayer = YES;
        overlay.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.86] CGColor];

        NSProgressIndicator *indicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0.0, 0.0, 28.0, 28.0)];
        indicator.style = NSProgressIndicatorStyleSpinning;
        indicator.indeterminate = YES;
        indicator.displayedWhenStopped = YES;
        indicator.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
        indicator.frame = NSMakeRect((NSWidth(overlay.bounds) - 28.0) / 2.0,
                                     (NSHeight(overlay.bounds) - 28.0) / 2.0 + 16.0,
                                     28.0,
                                     28.0);
        [indicator startAnimation:nil];
        [overlay addSubview:indicator];

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0.0,
                                                                           NSMinY(indicator.frame) - 34.0,
                                                                           NSWidth(overlay.bounds),
                                                                           22.0)];
        label.stringValue = text;
        label.alignment = NSTextAlignmentCenter;
        label.editable = NO;
        label.selectable = NO;
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.textColor = [NSColor secondaryLabelColor];
        label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
        [overlay addSubview:label];

        objc_setAssociatedObject(controller, &HSPhotoLoadingOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    overlay.frame = hostView.bounds;
    if (overlay.superview != hostView) {
        [hostView addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    }
}

static void HSUpdatePhotoLoading(id controller) {
    HSSetPhotoLoadingVisible(controller, HSPhotoLoadingTextForController(controller));
}

static void HSParserPhotoLibraryData(id self, SEL _cmd, id photoLibraryData) {
    if (!HSOriginalParser) {
        return;
    }

    if (![NSThread isMainThread]) {
        HSOriginalParser(self, _cmd, photoLibraryData);
        return;
    }

    id parserTarget = self;
    id parserData = photoLibraryData;
    id controller = HSLastPhotoViewController;
    NSUInteger token = HSNextPhotoLibraryParseToken();
    NSDate *parseStart = [NSDate date];
    NSLog(@"[HandShakerMaintained] Photo library parse scheduled token=%lu parser=%@ data=%@ controller=%@",
          (unsigned long)token,
          NSStringFromClass([parserTarget class]),
          NSStringFromClass([parserData class]),
          controller ? NSStringFromClass([controller class]) : @"");
    if (controller) {
        objc_setAssociatedObject(controller, &HSPhotoLibraryParsingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, &HSPhotoLibraryParseTokenKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    HSUpdatePhotoLoading(controller);

    dispatch_async(HSPhotoParserQueue, ^{
        @autoreleasepool {
            @try {
                HSOriginalParser(parserTarget, _cmd, parserData);
            } @catch (NSException *exception) {
                NSLog(@"[HandShakerMaintained] Photo library parse failed: %@", exception);
            } @finally {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSNumber *currentToken = controller ? objc_getAssociatedObject(controller, &HSPhotoLibraryParseTokenKey) : nil;
                    if (!currentToken || [currentToken unsignedIntegerValue] == token) {
                        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:parseStart];
                        NSLog(@"[HandShakerMaintained] Photo library parse finished token=%lu elapsed=%.3fs controller=%@",
                              (unsigned long)token,
                              elapsed,
                              controller ? NSStringFromClass([controller class]) : @"");
                        HSRefreshPhotoViewController(controller);
                        if (controller) {
                            objc_setAssociatedObject(controller, &HSPhotoLibraryParsingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(controller, &HSPhotoLibraryParseTokenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        }
                        HSUpdatePhotoLoading(controller);
                        HSSchedulePhotoCacheCleanup(@"photo-library-parsed");
                    }
                });
            }
        }
    });
}

static void HSReloadDataFromDevice(id self, SEL _cmd, BOOL ignoreCache, id completion) {
    HSLastPhotoViewController = self;
    NSLog(@"[HandShakerMaintained] Photo reload requested controller=%@ ignoreCache=%d completion=%@",
          NSStringFromClass([self class]),
          ignoreCache,
          completion ? NSStringFromClass([completion class]) : @"");

    if (HSOriginalReload) {
        HSOriginalReload(self, _cmd, ignoreCache, completion);
    }
}

static void HSReloadGrid(id self, SEL _cmd) {
    if (HSOriginalReloadGrid) {
        HSOriginalReloadGrid(self, _cmd);
    }
    HSUpdatePhotoLoading(self);
}

static id HSPhotoItemInit(id self, SEL _cmd) {
    id result = HSOriginalPhotoItemInit ? HSOriginalPhotoItemInit(self, _cmd) : self;
    HSConfigurePhotoItemView(result);
    return result;
}

static void HSSetRepresentedObject(id self, SEL _cmd, id value) {
    if (HSOriginalSetRepresentedObject) {
        HSOriginalSetRepresentedObject(self, _cmd, value);
    }
    HSConfigurePhotoItemView(self);
}

static void HSSetPhotoItemImage(id self, SEL _cmd, id value) {
    if (HSOriginalSetImage) {
        HSConfigurePhotoItemView(self);
        id preparedImage = HSPreparedPhotoImageForView(self, value);
        id lastImage = objc_getAssociatedObject(self, &HSPhotoItemLastImageKey);
        if (lastImage == preparedImage) {
            return;
        }

        objc_setAssociatedObject(self, &HSPhotoItemLastImageKey, preparedImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        HSOriginalSetImage(self, _cmd, preparedImage);
    }
}

static BOOL HSSwizzleInstanceMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return NO;
    }

    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static BOOL HSSwizzleInstanceMethodOnce(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (*original) {
        return YES;
    }

    return HSSwizzleInstanceMethod(cls, selector, replacement, original);
}

static id HSSendUSBHandshake(id self, SEL _cmd, int timeout) {
    int effectiveTimeout = timeout > 0 ? timeout : HSUSBHandshakeTimeoutMilliseconds;
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    NSLog(@"[HandShakerMaintained] USB handshake started requestedTimeout=%d effectiveTimeout=%d", timeout, effectiveTimeout);
    id result = HSOriginalUSBHandshake ? HSOriginalUSBHandshake(self, _cmd, effectiveTimeout) : nil;
    NSLog(@"[HandShakerMaintained] USB handshake finished elapsed=%.3fs result=%@",
          CFAbsoluteTimeGetCurrent() - startedAt,
          result);
    return result;
}

static void HSInstallUSBHandshakePatch(void) {
    Class deviceClass = NSClassFromString(@"SFUSBDevice");
    if (!deviceClass || HSSwizzledUSBHandshake) {
        return;
    }

    HSSwizzledUSBHandshake = HSSwizzleInstanceMethodOnce(deviceClass,
                                                         NSSelectorFromString(@"sendHandShakeRequestWithMSTimeout:"),
                                                         (IMP)HSSendUSBHandshake,
                                                         (IMP *)&HSOriginalUSBHandshake);
    if (HSSwizzledUSBHandshake) {
        NSLog(@"[HandShakerMaintained] USB handshake timeout patch installed timeout=%dms", HSUSBHandshakeTimeoutMilliseconds);
    }
}

static void HSInstallPhotoItemRenderPatch(void) {
    Class itemClass = NSClassFromString(@"SFPhotoItemView");
    if (!itemClass) {
        return;
    }

    if (!HSSwizzledPhotoItemImageSetter) {
        HSSwizzledPhotoItemImageSetter = HSSwizzleInstanceMethodOnce(itemClass,
                                                                    NSSelectorFromString(@"setImage:"),
                                                                    (IMP)HSSetPhotoItemImage,
                                                                    (IMP *)&HSOriginalSetImage);
    }
    if (!HSSwizzledPhotoItemLifecycle) {
        BOOL ok = YES;
        ok = HSSwizzleInstanceMethodOnce(itemClass,
                                         NSSelectorFromString(@"init"),
                                         (IMP)HSPhotoItemInit,
                                         (IMP *)&HSOriginalPhotoItemInit) && ok;
        ok = HSSwizzleInstanceMethodOnce(itemClass,
                                         NSSelectorFromString(@"setRepresentedObject:"),
                                         (IMP)HSSetRepresentedObject,
                                         (IMP *)&HSOriginalSetRepresentedObject) && ok;
        HSSwizzledPhotoItemLifecycle = ok;
    }
}

static void HSInstallPhotoLibraryAsyncPatch(void) {
    @try {
        if (!HSPhotoParserQueue) {
            HSPhotoParserQueue = dispatch_queue_create("com.handshaker.maintained.photo-library-parser", DISPATCH_QUEUE_SERIAL);
        }
        if (!HSPhotoCacheCleanupQueue) {
            HSPhotoCacheCleanupQueue = dispatch_queue_create("com.handshaker.maintained.photo-cache-cleanup", DISPATCH_QUEUE_SERIAL);
        }

        Class albumsClass = NSClassFromString(@"SFPhotoAlbumsViewModel");
        if (albumsClass && !HSSwizzledParser) {
            HSSwizzledParser = HSSwizzleInstanceMethod(albumsClass,
                                                       NSSelectorFromString(@"parserPhotoLibraryData:"),
                                                       (IMP)HSParserPhotoLibraryData,
                                                       (IMP *)&HSOriginalParser);
        }

        Class photoViewControllerClass = NSClassFromString(@"SFPhotoViewController");
        if (photoViewControllerClass && !HSSwizzledReload) {
            HSSwizzledReload = HSSwizzleInstanceMethod(photoViewControllerClass,
                                                       NSSelectorFromString(@"reloadDataFromDeviceWithIgnoreCache:completion:"),
                                                       (IMP)HSReloadDataFromDevice,
                                                       (IMP *)&HSOriginalReload);
        }
        if (photoViewControllerClass && !HSSwizzledReloadGrid) {
            HSSwizzledReloadGrid = HSSwizzleInstanceMethod(photoViewControllerClass,
                                                           NSSelectorFromString(@"reloadGrid"),
                                                           (IMP)HSReloadGrid,
                                                           (IMP *)&HSOriginalReloadGrid);
        }

        HSInstallPhotoItemRenderPatch();

        if (HSSwizzledParser && HSSwizzledReload && HSSwizzledReloadGrid && HSSwizzledPhotoItemImageSetter && HSSwizzledPhotoItemLifecycle && !HSLoggedInstall) {
            HSLoggedInstall = YES;
            HSSchedulePhotoCacheCleanup(@"patch-installed");
            NSLog(@"[HandShakerMaintained] Photo library async/thumbnail/layer/cache-cleanup patch installed");
        }
    } @catch (NSException *exception) {
        NSLog(@"[HandShakerMaintained] Photo library patch install failed: %@", exception);
    }

    HSLogRuntimeDiagnostics();
}

static void HSFRLogAskingNoOp(__unused id self, __unused SEL _cmd) {
    NSLog(@"[HandShakerMaintained] Legacy user-experience prompt suppressed");
}

static void HSSetExceptionHandlingMaskZero(id self, SEL _cmd, __unused NSUInteger mask) {
    if (HSOriginalSetExceptionHandlingMask) {
        HSOriginalSetExceptionHandlingMask(self, _cmd, 0);
    }
}

static void HSSetExceptionHangingMaskZero(id self, SEL _cmd, __unused NSUInteger mask) {
    if (HSOriginalSetExceptionHangingMask) {
        HSOriginalSetExceptionHangingMask(self, _cmd, 0);
    }
}

static void HSZeroExceptionHandlerMasks(void) {
    Class handlerClass = NSClassFromString(@"NSExceptionHandler");
    SEL defaultHandlerSelector = NSSelectorFromString(@"defaultExceptionHandler");
    if (!handlerClass || ![(id)handlerClass respondsToSelector:defaultHandlerSelector]) {
        return;
    }

    id handler = ((HSInitMsgSend)objc_msgSend)((id)handlerClass, defaultHandlerSelector);
    if (!handler) {
        return;
    }

    SEL handlingSelector = NSSelectorFromString(@"setExceptionHandlingMask:");
    if ([handler respondsToSelector:handlingSelector]) {
        ((HSSetMaskIMP)objc_msgSend)(handler, handlingSelector, 0);
    }

    SEL hangingSelector = NSSelectorFromString(@"setExceptionHangingMask:");
    if ([handler respondsToSelector:hangingSelector]) {
        ((HSSetMaskIMP)objc_msgSend)(handler, hangingSelector, 0);
    }
}

static void HSInstallLegacyReporterGuards(BOOL zeroExistingMasks) {
    @try {
        if (!HSRegisteredLegacyPromptDefaults) {
            HSRegisteredLegacyPromptDefaults = YES;
            [[NSUserDefaults standardUserDefaults] registerDefaults:@{
                @"FRDidAskUXProgram" : @YES,
                @"FRAutomaticallySendUsageDataToSmartisan" : @NO,
            }];
        }

        if (!HSSwizzledFRLogAsking) {
            Class frLogClass = NSClassFromString(@"FRLog");
            if (frLogClass) {
                HSSwizzledFRLogAsking = HSSwizzleInstanceMethodOnce(frLogClass,
                                                                    NSSelectorFromString(@"asking"),
                                                                    (IMP)HSFRLogAskingNoOp,
                                                                    (IMP *)&HSOriginalFRLogAsking);
            }
        }

        if (!HSSwizzledExceptionHandlerMasks) {
            Class handlerClass = NSClassFromString(@"NSExceptionHandler");
            if (handlerClass) {
                BOOL ok = YES;
                ok = HSSwizzleInstanceMethodOnce(handlerClass,
                                                 NSSelectorFromString(@"setExceptionHandlingMask:"),
                                                 (IMP)HSSetExceptionHandlingMaskZero,
                                                 (IMP *)&HSOriginalSetExceptionHandlingMask) && ok;
                ok = HSSwizzleInstanceMethodOnce(handlerClass,
                                                 NSSelectorFromString(@"setExceptionHangingMask:"),
                                                 (IMP)HSSetExceptionHangingMaskZero,
                                                 (IMP *)&HSOriginalSetExceptionHangingMask) && ok;
                HSSwizzledExceptionHandlerMasks = ok;
                if (ok && HSSwizzledFRLogAsking) {
                    NSLog(@"[HandShakerMaintained] Legacy reporter guards installed (UX prompt + exception masks)");
                }
            }
        }

        if (zeroExistingMasks && HSSwizzledExceptionHandlerMasks) {
            HSZeroExceptionHandlerMasks();
        }
    } @catch (NSException *exception) {
        NSLog(@"[HandShakerMaintained] Legacy reporter guard install failed: %@", exception);
    }
}

static void HSResetCrashSignalHandlers(NSString *reason) {
    static const int crashSignals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGSYS};
    int resetCount = 0;
    for (size_t index = 0; index < sizeof(crashSignals) / sizeof(crashSignals[0]); index += 1) {
        sig_t previousHandler = signal(crashSignals[index], SIG_DFL);
        if (previousHandler != SIG_DFL && previousHandler != SIG_ERR) {
            resetCount += 1;
        }
    }
    NSLog(@"[HandShakerMaintained] Crash signal handlers reset custom=%d reason=%@", resetCount, reason ?: @"");
}

static void HSScheduleLegacyReporterTeardown(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HSInstallLegacyReporterGuards(YES);
        HSResetCrashSignalHandlers(@"post-launch-3s");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HSInstallLegacyReporterGuards(YES);
        HSResetCrashSignalHandlers(@"post-launch-15s");
    });
}

__attribute__((constructor))
static void HSPhotoLibraryAsyncPatchEntry(void) {
    HSInstallLegacyReporterGuards(NO);
    HSInstallUSBHandshakePatch();

    dispatch_async(dispatch_get_main_queue(), ^{
        HSInstallLegacyReporterGuards(YES);
        HSInstallPhotoLibraryAsyncPatch();
        HSScheduleLegacyReporterTeardown();

        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            HSInstallLegacyReporterGuards(YES);
            HSInstallPhotoLibraryAsyncPatch();
        }];
    });
}
