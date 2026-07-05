#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef void (*HSParserIMP)(id, SEL, id);
typedef void (*HSReloadIMP)(id, SEL, BOOL, id);
typedef void (*HSObjectSetterIMP)(id, SEL, id);
typedef void (*HSVMsgSend)(id, SEL);
typedef id (*HSInitMsgSend)(id, SEL);
typedef id (*HSIdLongLongMsgSend)(id, SEL, long long);

@interface HSPreparedPhotoImageBox : NSObject
@property(nonatomic) NSSize targetSize;
@property(nonatomic) CGFloat scale;
@property(nonatomic, strong) NSImage *image;
@end

@implementation HSPreparedPhotoImageBox
@end

static HSParserIMP HSOriginalParser = NULL;
static HSReloadIMP HSOriginalReload = NULL;
static HSVMsgSend HSOriginalReloadGrid = NULL;
static HSObjectSetterIMP HSOriginalSetImage = NULL;
static HSInitMsgSend HSOriginalPhotoItemInit = NULL;
static HSObjectSetterIMP HSOriginalSetRepresentedObject = NULL;
static __weak id HSLastPhotoViewController = nil;
static char HSPreparedPhotoImageKey;
static char HSPhotoLoadingOverlayKey;
static char HSPhotoLibraryParsingKey;
static char HSPhotoLibraryParseTokenKey;
static char HSPhotoItemLastImageKey;
static char HSPhotoItemConfiguredKey;
static dispatch_queue_t HSPhotoParserQueue;
static NSUInteger HSPhotoLibraryParseGeneration = 0;
static BOOL HSSwizzledParser = NO;
static BOOL HSSwizzledReload = NO;
static BOOL HSSwizzledReloadGrid = NO;
static BOOL HSSwizzledPhotoItemImageSetter = NO;
static BOOL HSSwizzledPhotoItemLifecycle = NO;
static BOOL HSLoggedInstall = NO;

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
                        HSRefreshPhotoViewController(controller);
                        if (controller) {
                            objc_setAssociatedObject(controller, &HSPhotoLibraryParsingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(controller, &HSPhotoLibraryParseTokenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        }
                        HSUpdatePhotoLoading(controller);
                    }
                });
            }
        }
    });
}

static void HSReloadDataFromDevice(id self, SEL _cmd, BOOL ignoreCache, id completion) {
    HSLastPhotoViewController = self;

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
    if (!HSPhotoParserQueue) {
        HSPhotoParserQueue = dispatch_queue_create("com.handshaker.maintained.photo-library-parser", DISPATCH_QUEUE_SERIAL);
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
        NSLog(@"[HandShakerMaintained] Photo library async/thumbnail/layer patch installed");
    }
}

__attribute__((constructor))
static void HSPhotoLibraryAsyncPatchEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        HSInstallPhotoLibraryAsyncPatch();

        [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            HSInstallPhotoLibraryAsyncPatch();
        }];
    });
}
