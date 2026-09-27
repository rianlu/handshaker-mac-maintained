#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSString *const HSProjectURLString = @"https://github.com/rianlu/handshaker-mac-maintained";

static void HSShowMaintainedAbout(id self, SEL _cmd, id sender) {
    (void)self;
    (void)_cmd;
    (void)sender;

    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"];
    NSString *build = info[@"CFBundleVersion"];
    if (![version isKindOfClass:[NSString class]] || !version.length) {
        version = @"";
    }
    if (![build isKindOfClass:[NSString class]] || !build.length) {
        build = @"";
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"HandShaker";
    alert.informativeText = [NSString stringWithFormat:@"非官方维护版\n版本 %@ (%@)", version, build];
    NSImage *icon = [NSApp applicationIconImage];
    if (icon) {
        alert.icon = icon;
    }
    [alert addButtonWithTitle:@"访问项目主页"];
    [alert addButtonWithTitle:@"关闭"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:HSProjectURLString];
        if (url) {
            [[NSWorkspace sharedWorkspace] openURL:url];
        }
    }
}

static void HSInstallMaintainedAbout(void) {
    Class applicationClass = [NSApplication class];
    SEL selectors[] = {
        NSSelectorFromString(@"orderFrontStandardAboutPanel:"),
        NSSelectorFromString(@"orderFrontStandardAboutPanelWithOptions:"),
    };
    for (NSUInteger index = 0; index < sizeof(selectors) / sizeof(selectors[0]); index += 1) {
        Method method = class_getInstanceMethod(applicationClass, selectors[index]);
        if (method) {
            method_setImplementation(method, (IMP)HSShowMaintainedAbout);
        }
    }
}

__attribute__((constructor))
static void HSMaintainedAboutEntry(void) {
    HSInstallMaintainedAbout();
}
