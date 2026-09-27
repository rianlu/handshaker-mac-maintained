#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSString *const HSProjectURLString = @"https://github.com/rianlu/handshaker-mac-maintained";
static NSWindow *HSLicenseWindow;
static NSWindow *HSDownloadWindow;
static BOOL HSUpdateCheckInFlight;

@interface HSUpdateDownload : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) NSString *version;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) NSTextField *label;
@end

static NSString *HSBundleString(NSString *key) {
    id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static void HSOpenProjectPage(void) {
    NSURL *url = [NSURL URLWithString:HSProjectURLString];
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

static void HSShowLicense(void) {
    if (HSLicenseWindow) {
        [HSLicenseWindow makeKeyAndOrderFront:nil];
        return;
    }
    NSString *path = [[NSBundle mainBundle] pathForResource:@"Credits" ofType:@"rtf"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSAttributedString *text = data ? [[NSAttributedString alloc] initWithRTF:data documentAttributes:nil] : nil;
    if (!text.length) {
        text = [[NSAttributedString alloc] initWithString:@"未找到许可说明。"];
    }

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 420)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    NSTextView *view = [[NSTextView alloc] initWithFrame:scroll.bounds];
    view.editable = NO;
    view.drawsBackground = YES;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view.textStorage setAttributedString:text];
    scroll.documentView = view;

    HSLicenseWindow = [[NSWindow alloc] initWithContentRect:scroll.frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    HSLicenseWindow.title = @"许可说明";
    HSLicenseWindow.contentView = scroll;
    HSLicenseWindow.releasedWhenClosed = NO;
    [HSLicenseWindow center];
    [HSLicenseWindow makeKeyAndOrderFront:nil];
}

static void HSShowMaintainedAbout(id self, SEL _cmd, id sender) {
    (void)self;
    (void)_cmd;
    (void)sender;

    NSString *version = HSBundleString(@"CFBundleShortVersionString");
    NSString *build = HSBundleString(@"CFBundleVersion");
    NSString *copyright = HSBundleString(@"NSHumanReadableCopyright");
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"HandShaker";
    alert.informativeText = [NSString stringWithFormat:@"非官方维护版\n版本 %@ (%@)\n\n%@", version, build, copyright];
    NSImage *icon = [NSApp applicationIconImage];
    if (icon) {
        alert.icon = icon;
    }
    [alert addButtonWithTitle:@"访问项目主页"];
    [alert addButtonWithTitle:@"许可说明"];
    [alert addButtonWithTitle:@"关闭"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        HSOpenProjectPage();
    } else if (response == NSAlertSecondButtonReturn) {
        HSShowLicense();
    }
}

static NSAttributedString *HSUpdateNotes(NSString *html) {
    NSMutableString *text = [html mutableCopy] ?: [NSMutableString string];
    NSDictionary<NSString *, NSString *> *breaks = @{
        @"<li>" : @"\n• ",
        @"</li>" : @"",
        @"<p>" : @"",
        @"</p>" : @"\n",
        @"<ul>" : @"\n",
        @"</ul>" : @"\n",
        @"<br>" : @"\n",
        @"<br/>" : @"\n",
        @"<br />" : @"\n",
    };
    for (NSString *tag in breaks) {
        [text replaceOccurrencesOfString:tag withString:breaks[tag] options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
    }
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    [tags replaceMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    [text replaceOccurrencesOfString:@"&lt;" withString:@"<" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&gt;" withString:@">" options:0 range:NSMakeRange(0, text.length)];

    NSFont *font = [NSFont systemFontOfSize:13];
    NSMutableParagraphStyle *body = [NSMutableParagraphStyle new];
    body.paragraphSpacing = 8;
    NSMutableParagraphStyle *item = [NSMutableParagraphStyle new];
    item.firstLineHeadIndent = 2;
    item.headIndent = 16;
    item.paragraphSpacing = 4;
    NSMutableAttributedString *notes = [NSMutableAttributedString new];
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!line.length) {
            continue;
        }
        BOOL bullet = [line hasPrefix:@"• "];
        [notes appendAttributedString:[[NSAttributedString alloc] initWithString:[line stringByAppendingString:@"\n"]
                                                                       attributes:@{
                                                                           NSFontAttributeName : font,
                                                                           NSParagraphStyleAttributeName : bullet ? item : body,
                                                                       }]];
    }
    return notes;
}

static NSView *HSNotesView(NSAttributedString *notes) {
    NSTextView *view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 440, 10)];
    view.editable = NO;
    view.drawsBackground = NO;
    view.textContainerInset = NSMakeSize(0, 2);
    view.textContainer.widthTracksTextView = YES;
    view.textContainer.containerSize = NSMakeSize(440, CGFLOAT_MAX);
    [view.textStorage setAttributedString:notes];
    [view.layoutManager ensureLayoutForTextContainer:view.textContainer];
    CGFloat textHeight = [view.layoutManager usedRectForTextContainer:view.textContainer].size.height + 8;
    view.frame = NSMakeRect(0, 0, 440, textHeight);
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 440, MIN(MAX(textHeight, 80), 260))];
    scroll.hasVerticalScroller = textHeight > 260;
    scroll.drawsBackground = NO;
    scroll.documentView = view;
    return scroll;
}

static void HSCloseDownloadWindow(void) {
    [HSDownloadWindow close];
    HSDownloadWindow = nil;
}

static void HSFinishDownload(NSURL *fileURL, NSString *version, NSError *error) {
    HSUpdateCheckInFlight = NO;
    HSCloseDownloadWindow();
    NSAlert *alert = [[NSAlert alloc] init];
    if (error || !fileURL) {
        alert.messageText = @"更新下载失败";
        alert.informativeText = error.localizedDescription ?: @"请稍后再试。";
        [alert runModal];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:fileURL];
    alert.messageText = [NSString stringWithFormat:@"已下载 %@", version];
    alert.informativeText = @"安装包已打开。请将 HandShaker 拖入“应用程序”文件夹并替换当前版本，然后重新打开。";
    [alert runModal];
}

@implementation HSUpdateDownload
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (totalBytesExpectedToWrite > 0) {
            self.progress.indeterminate = NO;
            self.progress.maxValue = totalBytesExpectedToWrite;
            self.progress.doubleValue = totalBytesWritten;
            self.label.stringValue = [NSString stringWithFormat:@"正在下载 %@，已完成 %.0f%%", self.version, 100.0 * totalBytesWritten / totalBytesExpectedToWrite];
        }
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSError *failure = nil;
    NSURL *saved = nil;
    NSInteger status = [(NSHTTPURLResponse *)task.response statusCode];
    if (status >= 400) {
        failure = [NSError errorWithDomain:NSURLErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: @"下载更新失败。"}];
    } else {
        NSString *name = task.originalRequest.URL.lastPathComponent.length ? task.originalRequest.URL.lastPathComponent : @"HandShaker.dmg";
        NSURL *destination = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:[@"Downloads/" stringByAppendingPathComponent:name]]];
        [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
        if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:destination error:&failure]) {
            saved = destination;
        }
    }
    NSString *version = self.version;
    dispatch_async(dispatch_get_main_queue(), ^{
        [session finishTasksAndInvalidate];
        HSFinishDownload(saved, version, failure);
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) {
        return;
    }
    NSString *version = self.version;
    dispatch_async(dispatch_get_main_queue(), ^{
        [session finishTasksAndInvalidate];
        HSFinishDownload(nil, version, error);
    });
}
@end

static HSUpdateDownload *HSActiveDownload;

static void HSShowDownloadWindow(NSString *version) {
    NSTextField *label = [NSTextField labelWithString:[NSString stringWithFormat:@"正在下载 %@…", version]];
    label.frame = NSMakeRect(20, 58, 360, 40);
    NSProgressIndicator *progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 24, 360, 20)];
    progress.indeterminate = YES;
    progress.style = NSProgressIndicatorStyleBar;
    [progress startAnimation:nil];
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 110)];
    [content addSubview:label];
    [content addSubview:progress];
    HSDownloadWindow = [[NSWindow alloc] initWithContentRect:content.frame
                                                     styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    HSDownloadWindow.title = @"正在下载更新";
    HSDownloadWindow.contentView = content;
    HSDownloadWindow.releasedWhenClosed = NO;
    [HSDownloadWindow center];
    [HSDownloadWindow makeKeyAndOrderFront:nil];
    HSActiveDownload.label = label;
    HSActiveDownload.progress = progress;
}

static void HSDownloadAndOpen(NSURL *url, NSString *version) {
    HSActiveDownload = [HSUpdateDownload new];
    HSActiveDownload.version = version;
    HSShowDownloadWindow(version);
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    HSActiveDownload.session = [NSURLSession sessionWithConfiguration:configuration delegate:HSActiveDownload delegateQueue:nil];
    [[HSActiveDownload.session downloadTaskWithURL:url] resume];
}

static void HSCheckForMaintainedUpdate(BOOL interactive) {
    if (HSUpdateCheckInFlight) {
        if (HSDownloadWindow) {
            [HSDownloadWindow makeKeyAndOrderFront:nil];
        }
        return;
    }
    HSUpdateCheckInFlight = YES;
    NSString *feed = HSBundleString(@"SUFeedURL");
    NSURL *feedURL = [NSURL URLWithString:feed];
    if (!feedURL) {
        HSUpdateCheckInFlight = NO;
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:feedURL];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *parseError = nil;
            NSXMLDocument *document = data ? [[NSXMLDocument alloc] initWithData:data options:0 error:&parseError] : nil;
            NSArray *items = [document nodesForXPath:@"//item" error:nil];
            NSXMLElement *item = items.firstObject;
            NSXMLElement *enclosure = [[item elementsForName:@"enclosure"] firstObject];
            NSString *remoteBuild = nil;
            NSString *remoteVersion = nil;
            NSString *fileURLString = nil;
            for (NSXMLNode *attribute in enclosure.attributes) {
                if ([attribute.name hasSuffix:@"version"] && ![attribute.name hasSuffix:@"shortVersionString"] && ![attribute.name containsString:@"System"]) {
                    remoteBuild = attribute.stringValue;
                } else if ([attribute.name hasSuffix:@"shortVersionString"]) {
                    remoteVersion = attribute.stringValue;
                } else if ([attribute.name isEqualToString:@"url"]) {
                    fileURLString = attribute.stringValue;
                }
            }
            NSAttributedString *notes = HSUpdateNotes([[item elementsForName:@"description"].firstObject stringValue] ?: @"");
            long long localBuild = HSBundleString(@"CFBundleVersion").longLongValue;
            BOOL newer = remoteBuild.longLongValue > localBuild && fileURLString.length;
            HSUpdateCheckInFlight = NO;
            if (error || !newer) {
                if (interactive) {
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = error || !document ? @"检查更新失败" : @"已是最新版本";
                    alert.informativeText = error.localizedDescription ?: (document ? @"当前没有新版本。" : @"无法读取更新说明。");
                    [alert runModal];
                }
                return;
            }
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [NSString stringWithFormat:@"发现新版本 %@", remoteVersion ?: remoteBuild];
            alert.informativeText = @" ";
            if (notes.length) {
                alert.accessoryView = HSNotesView(notes);
            }
            [alert addButtonWithTitle:@"下载并打开"];
            [alert addButtonWithTitle:@"稍后"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                HSUpdateCheckInFlight = YES;
                HSDownloadAndOpen([NSURL URLWithString:fileURLString], remoteVersion ?: remoteBuild);
            }
        });
    }] resume];
}

static void HSCheckForUpdates(id self, SEL _cmd, id sender) {
    (void)self;
    (void)_cmd;
    (void)sender;
    HSCheckForMaintainedUpdate(YES);
}

static void HSCheckForUpdatesInBackground(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    HSCheckForMaintainedUpdate(NO);
}

static void HSInstallMaintainedUI(void) {
    Class applicationClass = [NSApplication class];
    SEL aboutSelectors[] = {
        NSSelectorFromString(@"orderFrontStandardAboutPanel:"),
        NSSelectorFromString(@"orderFrontStandardAboutPanelWithOptions:"),
    };
    for (NSUInteger index = 0; index < sizeof(aboutSelectors) / sizeof(aboutSelectors[0]); index += 1) {
        Method method = class_getInstanceMethod(applicationClass, aboutSelectors[index]);
        if (method) {
            method_setImplementation(method, (IMP)HSShowMaintainedAbout);
        }
    }

    Class updaterClass = NSClassFromString(@"SUUpdater");
    Method manual = class_getInstanceMethod(updaterClass, NSSelectorFromString(@"checkForUpdates:"));
    if (manual) {
        method_setImplementation(manual, (IMP)HSCheckForUpdates);
    }
    Method background = class_getInstanceMethod(updaterClass, NSSelectorFromString(@"checkForUpdatesInBackground"));
    if (background) {
        method_setImplementation(background, (IMP)HSCheckForUpdatesInBackground);
    }
}

__attribute__((constructor))
static void HSMaintainedAboutEntry(void) {
    HSInstallMaintainedUI();
}
