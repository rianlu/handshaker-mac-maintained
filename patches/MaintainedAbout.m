#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSString *const HSProjectURLString = @"https://github.com/rianlu/handshaker-mac-maintained";
static NSWindow *HSLicenseWindow;
static BOOL HSUpdateCheckInFlight;

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

static NSString *HSPlainTextFromHTML(NSString *html) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    NSString *stripped = [expression stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0, html.length) withTemplate:@""];
    return [[stripped stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"]
            stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
}

static void HSFinishDownload(NSURL *fileURL, NSString *version, NSError *error) {
    HSUpdateCheckInFlight = NO;
    if (error || !fileURL) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"更新下载失败";
        alert.informativeText = error.localizedDescription ?: @"请稍后再试。";
        [alert runModal];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:fileURL];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"已下载 %@", version];
    alert.informativeText = @"安装包已打开。请将 HandShaker 拖入“应用程序”文件夹并替换当前版本，然后重新打开。";
    [alert runModal];
}

static void HSDownloadAndOpen(NSURL *url, NSString *version) {
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSURL *saved = nil;
        NSError *failure = error;
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!failure && status >= 400) {
            failure = [NSError errorWithDomain:NSURLErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: @"下载更新失败。"}];
        }
        if (!failure && location) {
            NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"HandShaker.dmg";
            NSURL *destination = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:[@"Downloads/" stringByAppendingPathComponent:name]]];
            [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
            if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:destination error:&failure]) {
                saved = destination;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            HSFinishDownload(saved, version, failure);
        });
    }];
    [task resume];
}

static void HSCheckForMaintainedUpdate(BOOL interactive) {
    if (HSUpdateCheckInFlight) {
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
            NSString *notes = HSPlainTextFromHTML([[item elementsForName:@"description"].firstObject stringValue] ?: @"");
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
            alert.informativeText = notes.length ? notes : @"可以下载安装包。";
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
