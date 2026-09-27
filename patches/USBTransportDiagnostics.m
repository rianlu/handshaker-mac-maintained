#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <libkern/OSCacheControl.h>
#import <pthread.h>
#import <stdint.h>
#import <limits.h>
#import <mach-o/loader.h>

extern void HSLogUSBDiagnostic(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

typedef int (*HSBulkIMP)(void *, unsigned char, unsigned char *, int, int *, unsigned int);
typedef signed char (*HSDataIMP)(id, SEL, id, unsigned int, signed char);
typedef signed char (*HSPhaseIMP)(id, SEL, int, id __autoreleasing *);
static HSBulkIMP HSNativeBulk;
static HSDataIMP HSDataOriginal;
static HSPhaseIMP HSPhase01Original, HSPhase02Original;
static IMP HSReadOriginal, HSWriteOriginal, HSEnqueueOriginal, HSEnqueueFirstOriginal, HSHandshakeOriginal;
static NSLock *HSTraceLock;
static NSMutableDictionary *HSActiveBulk, *HSCounters;
static unsigned long long HSTraceSequence;
static char HSConnectionKey;
static dispatch_source_t HSTraceTimer;
static NSString *const HSContextKey = @"HandShaker.USB.Trace";
static char HSFileTraceKey;
static NSMapTable<NSString *, id> *HSFileTransfers;
static IMP HSFileRequestOriginal, HSFileDataOriginal;
static BOOL HSFileCallbacksReady;

@interface HSFileTrace : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *connection;
@property(nonatomic, copy) NSString *direction;
@property(nonatomic, copy) NSString *transport;
@property(nonatomic, weak) id operation;
@property(nonatomic, weak) id transportDevice;
@property(nonatomic) unsigned int sid;
@property(nonatomic) unsigned long long bytes;
@property(nonatomic) unsigned long long size;
@property(nonatomic) BOOL sizeKnown;
@property(nonatomic) BOOL finished;
@property(nonatomic) double started;
@property(nonatomic) double wallStarted;
@property(nonatomic) double lastProgress;
@end
@implementation HSFileTrace
@end

// Verify every original direct call before rewriting it. Never replace libusb itself.
static const uintptr_t HSBulkCallOffsets[] = {
    0x75249, 0x769b5, 0x76a55, 0x76c87, 0x77029,
    0x77c1f, 0x77c98, 0x782bf, 0x78803, 0x78ce2
};
static uintptr_t HSCoreBase;

static id HSTraceValue(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused NSException *error) { return nil; }
}

static NSString *HSConnection(id device) {
    @synchronized(device) {
        NSString *value = objc_getAssociatedObject(device, &HSConnectionKey);
        if (!value) {
            value = NSUUID.UUID.UUIDString;
            objc_setAssociatedObject(device, &HSConnectionKey, value, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        return value;
    }
}

static NSString *HSFileFields(HSFileTrace *trace) {
    return [NSString stringWithFormat:@"fileTask=%@ connection=%@ sid=%u direction=%@ transport=%@ fileBytes=%@ completedBytes=%llu",
            trace.identifier, trace.connection ?: @"unknown", trace.sid, trace.direction, trace.transport ?: @"unknown",
            trace.sizeKnown ? @(trace.size).stringValue : @"unknown", trace.bytes];
}

// Validate block ABI before wrapping an original callback. Never invoke a guessed signature.
static BOOL HSFileCallbackMatches(id block, BOOL progress) {
    if (!block) return YES;
    struct HSBlockLayout { void *isa; int flags; int reserved; void *invoke; void *descriptor; };
    const struct HSBlockLayout *layout = (__bridge const void *)block;
    if (!(layout->flags & (1 << 30))) return NO;
    uintptr_t *descriptor = layout->descriptor;
    descriptor += 2;
    if (layout->flags & (1 << 25)) descriptor += 2;
    const char *encoding = *(const char **)descriptor;
    if (!encoding) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (signature.numberOfArguments != 3) return NO;
    if (progress) return strcmp(signature.methodReturnType, "c") == 0 &&
        strcmp([signature getArgumentTypeAtIndex:1], "Q") == 0 && strcmp([signature getArgumentTypeAtIndex:2], "Q") == 0;
    return strcmp(signature.methodReturnType, "v") == 0 &&
        [signature getArgumentTypeAtIndex:1][0] == '@' && [signature getArgumentTypeAtIndex:2][0] == '@';
}

static void HSFileProgress(HSFileTrace *trace);
static void HSFileComplete(HSFileTrace *trace, id failure);

static void HSRegisterFile(id operation) {
    if (!HSFileCallbacksReady || !operation || objc_getAssociatedObject(operation, &HSFileTraceKey)) return;
    NSString *kind = NSStringFromClass([operation class]);
    BOOL upload = [kind isEqualToString:@"SSPUploadFileRequestOperation"];
    if (!upload && ![kind isEqualToString:@"SSPDownloadFileRequestOperation"]) return;
    id callback = HSTraceValue(operation, @"finishBlock");
    id progress = HSTraceValue(operation, @"progress");
    if (!callback || !HSFileCallbackMatches(callback, NO) || !HSFileCallbackMatches(progress, YES)) {
        HSLogUSBDiagnostic(@"event=FILE_DIAGNOSTIC_UNAVAILABLE reason=callback-signature class=%@", kind);
        return;
    }
    id device = HSTraceValue(HSTraceValue(operation, @"sspManager"), @"device");
    if (!device) return;
    HSFileTrace *trace = [HSFileTrace new];
    trace.identifier = NSUUID.UUID.UUIDString;
    trace.direction = upload ? @"Mac-to-Android" : @"Android-to-Mac";
    trace.operation = operation;
    trace.sid = [HSTraceValue(operation, @"sessionId") unsignedIntValue];
    trace.connection = HSConnection(device);
    trace.transport = @"unknown";
    trace.key = [NSString stringWithFormat:@"%@:%u", trace.connection, trace.sid];
    if (upload) {
        NSNumber *size = HSTraceValue(operation, @"bodySize");
        if ([size isKindOfClass:NSNumber.class]) { trace.size = size.unsignedLongLongValue; trace.sizeKnown = YES; }
    }
    void (^originalCallback)(id, id) = callback;
    void (^completion)(id, id) = ^(id result, id failure) {
        HSFileComplete(trace, failure);
        originalCallback(result, failure);
    };
    signed char (^originalProgress)(unsigned long long, unsigned long long) = progress;
    if (originalProgress) {
        signed char (^wrappedProgress)(unsigned long long, unsigned long long) = ^signed char(unsigned long long bytes, unsigned long long total) {
            @synchronized(trace) {
                trace.size = total; trace.sizeKnown = YES;
                if (!upload) trace.bytes += bytes;
                HSFileProgress(trace);
            }
            return originalProgress(bytes, total);
        };
        [operation setValue:[wrappedProgress copy] forKey:@"progress"];
    }
    [operation setValue:[completion copy] forKey:@"finishBlock"];
    objc_setAssociatedObject(operation, &HSFileTraceKey, trace, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [HSTraceLock lock];
    [HSFileTransfers setObject:trace forKey:trace.key];
    [HSTraceLock unlock];
    HSLogUSBDiagnostic(@"event=FILE_QUEUED %@", HSFileFields(trace));
}

static HSFileTrace *HSFileForDevice(id device, long long sid) {
    NSString *key = [NSString stringWithFormat:@"%@:%u", HSConnection(device), (unsigned int)sid];
    [HSTraceLock lock];
    HSFileTrace *trace = [HSFileTransfers objectForKey:key];
    [HSTraceLock unlock];
    if (trace) @synchronized(trace) {
        if (!trace.started && !trace.finished) {
            trace.transportDevice = device;
            trace.transport = [device isKindOfClass:NSClassFromString(@"SFUSBDevice")] ? @"USB-AOA" :
                [device isKindOfClass:NSClassFromString(@"SFWifiDevice")] ? @"Wi-Fi" : @"unknown";
            trace.started = NSProcessInfo.processInfo.systemUptime;
            trace.wallStarted = NSDate.date.timeIntervalSince1970 * 1000.0;
            HSLogUSBDiagnostic(@"event=FILE_BEGIN %@ startWallMs=%.0f clock=monotonic scope=file-request-to-callback", HSFileFields(trace), trace.wallStarted);
        }
    }
    return trace;
}

static void HSFileProgress(HSFileTrace *trace) {
    double now = NSProcessInfo.processInfo.systemUptime;
    if (trace.started && !trace.finished && now - trace.lastProgress >= 5) {
        trace.lastProgress = now;
        HSLogUSBDiagnostic(@"event=FILE_PROGRESS %@ elapsedMs=%.3f", HSFileFields(trace), (now - trace.started) * 1000);
    }
}

static void HSFileComplete(HSFileTrace *trace, id failure) {
    @synchronized(trace) {
        if (trace.finished) return;
        trace.finished = YES;
        id currentDevice = HSTraceValue(HSTraceValue(trace.operation, @"sspManager"), @"device");
        if (trace.started && currentDevice != trace.transportDevice) {
            trace.transport = @"changed-or-unknown";
        }
        if ([trace.direction isEqualToString:@"Android-to-Mac"]) {
            // The native operation increments this only for file body data, excluding its header.
            id operation = trace.operation;
            NSNumber *bytes = HSTraceValue(operation, @"transferedSize");
            NSNumber *size = HSTraceValue(operation, @"bodySize");
            if ([bytes isKindOfClass:NSNumber.class]) trace.bytes = bytes.unsignedLongLongValue;
            if (HSTraceValue(operation, @"header") && [size isKindOfClass:NSNumber.class]) {
                trace.size = size.unsignedLongLongValue; trace.sizeKnown = YES;
            }
        }
        double elapsed = trace.started ? (NSProcessInfo.processInfo.systemUptime - trace.started) * 1000 : -1;
        BOOL verified = trace.sizeKnown && trace.bytes == trace.size;
        BOOL rateValid = !failure && verified && elapsed > 0;
        NSError *error = [failure isKindOfClass:NSError.class] ? failure : nil;
        NSString *rate = rateValid ? [NSString stringWithFormat:@"%.3f", trace.bytes / 1048576.0 / (elapsed / 1000.0)] : @"unknown";
        HSLogUSBDiagnostic(@"event=FILE_END %@ status=%@ bytesVerified=%d elapsedMs=%.3f averageMiBps=%@ startWallMs=%.0f endWallMs=%.0f errorDomain=%@ errorCode=%ld byteAccounting=successful-file-body-data",
                           HSFileFields(trace), failure ? @"failed" : @"completed", verified, elapsed, rate,
                           trace.wallStarted, NSDate.date.timeIntervalSince1970 * 1000.0, error.domain ?: (failure ? @"unknown" : @"none"), (long)error.code);
        if (trace.key) {
            [HSTraceLock lock];
            [HSFileTransfers removeObjectForKey:trace.key];
            [HSTraceLock unlock];
        }
    }
}

typedef signed char (*HSFileSendIMP)(id, SEL, id, long long, id __autoreleasing *);
static signed char HSFileRequest(id self, SEL cmd, id data, long long sid, id __autoreleasing *error) {
    HSFileForDevice(self, sid);
    return ((HSFileSendIMP)HSFileRequestOriginal)(self, cmd, data, sid, error);
}
static signed char HSFileData(id self, SEL cmd, id data, long long sid, id __autoreleasing *error) {
    HSFileTrace *trace = HSFileForDevice(self, sid);
    signed char result = ((HSFileSendIMP)HSFileDataOriginal)(self, cmd, data, sid, error);
    if (trace && result && [data isKindOfClass:NSData.class]) @synchronized(trace) {
        if (trace.finished) return result;
        trace.bytes += [data length];
        HSFileProgress(trace);
    }
    return result;
}

static NSDictionary *HSPushTrace(id device, NSString *phase, unsigned int sid, signed char flag) {
    NSMutableDictionary *storage = NSThread.currentThread.threadDictionary;
    NSDictionary *previous = storage[HSContextKey];
    storage[HSContextKey] = @{@"connection": HSConnection(device), @"phase": phase,
                             @"sid": @(sid), @"flag": @((unsigned char)flag)};
    return previous;
}

static void HSPopTrace(NSDictionary *previous) {
    if (previous) NSThread.currentThread.threadDictionary[HSContextKey] = previous;
    else [NSThread.currentThread.threadDictionary removeObjectForKey:HSContextKey];
}

static BOOL HSObserve(NSString *key) {
    [HSTraceLock lock];
    NSMutableDictionary *counter = HSCounters[key];
    if (!counter) HSCounters[key] = counter = [NSMutableDictionary dictionary];
    unsigned long long count = [counter[@"count"] unsignedLongLongValue] + 1;
    double now = NSProcessInfo.processInfo.systemUptime;
    BOOL detailed = count <= 32 || now - [counter[@"last"] doubleValue] >= 5.0;
    counter[@"count"] = @(count);
    if (detailed) counter[@"last"] = @(now);
    // Bound counters across repeated device re-enumeration.
    if (HSCounters.count > 1024) [HSCounters removeAllObjects];
    [HSTraceLock unlock];
    return detailed;
}

static int HSBulkTrace(void *handle, unsigned char endpoint, unsigned char *data,
                       int length, int *transferred, unsigned int timeout) {
    @autoreleasepool {
        NSDictionary *context = NSThread.currentThread.threadDictionary[HSContextKey] ?: @{};
        NSString *direction = (endpoint & 0x80) ? @"IN" : @"OUT";
        NSString *connection = context[@"connection"] ?: @"unknown";
        NSString *phase = context[@"phase"] ?: @"legacy";
        BOOL detailed = HSObserve([NSString stringWithFormat:@"bulk:%@:%p:%@", connection, handle, direction]);
        uint64_t thread = 0;
        pthread_threadid_np(NULL, &thread);
        double started = NSProcessInfo.processInfo.systemUptime;
        uintptr_t callsite = (uintptr_t)__builtin_return_address(0) - HSCoreBase;
        [HSTraceLock lock];
        NSNumber *identifier = @(++HSTraceSequence);
        NSString *fields = [NSString stringWithFormat:@"transfer=%@ connection=%@ phase=%@ sid=%@ flag=%@ direction=%@ endpoint=0x%02x requested=%d timeoutMs=%u handle=%p ownerTid=%llu site=0x%lx",
                            identifier, connection, phase, context[@"sid"] ?: @0, context[@"flag"] ?: @0,
                            direction, endpoint, length, timeout, handle, (unsigned long long)thread, (unsigned long)callsite];
        HSActiveBulk[identifier] = [@{@"fields": fields, @"started": @(started), @"timeout": @(timeout), @"last": @0} mutableCopy];
        [HSTraceLock unlock];
        if (detailed) HSLogUSBDiagnostic(@"event=BULK_BEGIN %@", fields);
        int result = HSNativeBulk(handle, endpoint, data, length, transferred, timeout);
        double elapsed = (NSProcessInfo.processInfo.systemUptime - started) * 1000.0;
        [HSTraceLock lock];
        [HSActiveBulk removeObjectForKey:identifier];
        [HSTraceLock unlock];
        if (detailed || result != 0 || elapsed >= 2000) {
            // Submission errors can return before libusb initializes the caller's output slot.
            BOOL actualKnown = transferred && (result == 0 || result == -7);
            HSLogUSBDiagnostic(@"event=BULK_END %@ rc=%d actual=%d actualKnown=%d elapsedMs=%.3f",
                               fields, result, actualKnown ? *transferred : -1, actualKnown, elapsed);
        }
        return result;
    }
}

static NSUInteger HSInstallBulkCallsites(void) {
    Dl_info image = {0};
    HSNativeBulk = (HSBulkIMP)dlsym(RTLD_DEFAULT, "libusb_bulk_transfer");
    if (!HSNativeBulk || !dladdr((void *)HSNativeBulk, &image)) return 0;
    HSCoreBase = (uintptr_t)image.dli_fbase;
    const struct mach_header_64 *header = image.dli_fbase;
    const uint8_t expectedUUID[16] = {0x6a,0xe0,0x64,0x06,0x7a,0x9d,0x34,0x57,0xad,0xcb,0xcc,0x6a,0x55,0xf0,0xdd,0xa4};
    BOOL knownImage = NO;
    if (header->magic == MH_MAGIC_64 && header->cputype == CPU_TYPE_X86_64) {
        const struct load_command *command = (const void *)(header + 1);
        for (uint32_t index = 0; index < header->ncmds; index++) {
            if (command->cmd == LC_UUID) knownImage = memcmp(((const struct uuid_command *)command)->uuid, expectedUUID, 16) == 0;
            command = (const void *)((const uint8_t *)command + command->cmdsize);
        }
    }
    if (!knownImage) {
        HSLogUSBDiagnostic(@"event=BULK_PATCH_REJECTED reason=unknown-core-image");
        return 0;
    }
    for (NSUInteger index = 0; index < sizeof(HSBulkCallOffsets) / sizeof(HSBulkCallOffsets[0]); index++) {
        uint8_t *call = (uint8_t *)(HSCoreBase + HSBulkCallOffsets[index]);
        int32_t original = 0;
        memcpy(&original, call + 1, sizeof(original));
        intptr_t replacement = (intptr_t)HSBulkTrace - (intptr_t)(call + 5);
        if (call[0] != 0xe8 || call + 5 + original != (uint8_t *)HSNativeBulk ||
            replacement < INT32_MIN || replacement > INT32_MAX) {
            HSLogUSBDiagnostic(@"event=BULK_PATCH_REJECTED site=0x%lx reason=call-target-or-range", (unsigned long)HSBulkCallOffsets[index]);
            return 0;
        }
    }
    NSUInteger installed = 0;
    for (NSUInteger index = 0; index < sizeof(HSBulkCallOffsets) / sizeof(HSBulkCallOffsets[0]); index++) {
        uint8_t *call = (uint8_t *)(HSCoreBase + HSBulkCallOffsets[index]);
        vm_address_t page = (vm_address_t)call & ~((vm_address_t)vm_page_size - 1);
        // Keep the original code executable even if restoring page protection fails.
        // Refuse installation when this process cannot temporarily write its own code page.
        kern_return_t result = vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY);
        if (result != KERN_SUCCESS) {
            HSLogUSBDiagnostic(@"event=BULK_PATCH_REJECTED site=0x%lx reason=page-protection rc=%d", (unsigned long)HSBulkCallOffsets[index], result);
            break;
        }
        int32_t displacement = (int32_t)((intptr_t)HSBulkTrace - (intptr_t)(call + 5));
        memcpy(call + 1, &displacement, sizeof(displacement));
        sys_icache_invalidate(call, 5);
        result = vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        if (result != KERN_SUCCESS) {
            HSLogUSBDiagnostic(@"event=BULK_PATCH_REJECTED site=0x%lx reason=restore-protection rc=%d", (unsigned long)HSBulkCallOffsets[index], result);
            break;
        }
        installed++;
    }
    return installed;
}

static id HSHandshakeTrace(id self, SEL command, int timeout) {
    NSDictionary *previous = HSPushTrace(self, @"handshake", 0, 0);
    @try { return ((id (*)(id, SEL, int))HSHandshakeOriginal)(self, command, timeout); }
    @finally { HSPopTrace(previous); }
}

static signed char HSDataTrace(id self, SEL command, id data, unsigned int sid, signed char flag) {
    NSDictionary *previous = HSPushTrace(self, @"ssp", sid, flag);
    NSString *connection = HSConnection(self);
    BOOL detailed = HSObserve([@"send:" stringByAppendingString:connection]);
    NSUInteger length = [data isKindOfClass:NSData.class] ? [data length] : 0;
    double started = NSProcessInfo.processInfo.systemUptime;
    if (detailed) HSLogUSBDiagnostic(@"event=SSP_SEND_BEGIN connection=%@ sid=%u flag=%u bytes=%lu bulkTimeoutMs=500", connection, sid, (unsigned char)flag, (unsigned long)length);
    @try {
        signed char result = HSDataOriginal(self, command, data, sid, flag);
        if (detailed || !result) HSLogUSBDiagnostic(@"event=SSP_SEND_END connection=%@ sid=%u success=%d elapsedMs=%.3f", connection, sid, result != 0, (NSProcessInfo.processInfo.systemUptime - started) * 1000.0);
        return result;
    } @catch (NSException *error) {
        HSLogUSBDiagnostic(@"event=SSP_SEND_EXCEPTION connection=%@ sid=%u type=%@", connection, sid, error.name);
        @throw;
    } @finally { HSPopTrace(previous); }
}

static signed char HSPhaseTrace(id self, SEL command, int timeout, id __autoreleasing *error, HSPhaseIMP original) {
    NSString *phase = NSStringFromSelector(command);
    HSLogUSBDiagnostic(@"event=SSP_PHASE_BEGIN connection=%@ phase=%@ requestedTimeoutMs=%d", HSConnection(self), phase, timeout);
    double started = NSProcessInfo.processInfo.systemUptime;
    signed char result = original(self, command, timeout, error);
    NSError *failure = !result && error ? *error : nil;
    HSLogUSBDiagnostic(@"event=SSP_PHASE_END connection=%@ phase=%@ success=%d elapsedMs=%.3f errorDomain=%@ errorCode=%ld", HSConnection(self), phase, result != 0, (NSProcessInfo.processInfo.systemUptime - started) * 1000.0, failure.domain ?: @"none", (long)failure.code);
    return result;
}

static signed char HSPhase01Trace(id self, SEL command, int timeout, id __autoreleasing *error) { return HSPhaseTrace(self, command, timeout, error, HSPhase01Original); }
static signed char HSPhase02Trace(id self, SEL command, int timeout, id __autoreleasing *error) { return HSPhaseTrace(self, command, timeout, error, HSPhase02Original); }

static void HSReadTrace(id self, SEL command) {
    NSDictionary *previous = HSPushTrace(self, @"message-read", 0, 0);
    HSLogUSBDiagnostic(@"event=USB_READER_BEGIN connection=%@", HSConnection(self));
    @try { ((void (*)(id, SEL))HSReadOriginal)(self, command); }
    @finally {
        HSLogUSBDiagnostic(@"event=USB_READER_END connection=%@ canceled=%@ running=%@", HSConnection(self), HSTraceValue(self, @"readThreadCanceled"), HSTraceValue(self, @"readThreadRunning"));
        HSPopTrace(previous);
    }
}

static void HSWriteTrace(id self, SEL command) {
    HSLogUSBDiagnostic(@"event=SSP_WRITER_BEGIN manager=%p", (__bridge void *)self);
    @try { ((void (*)(id, SEL))HSWriteOriginal)(self, command); }
    @finally { HSLogUSBDiagnostic(@"event=SSP_WRITER_END manager=%p canceled=%@ queued=%@", (__bridge void *)self, HSTraceValue(self, @"writeThreadCanceled"), HSTraceValue(HSTraceValue(self, @"sessionQueue"), @"count")); }
}

static void HSEnqueueTrace(id self, SEL command, id operation) {
    HSRegisterFile(operation);
    if (HSObserve([NSString stringWithFormat:@"queue:%p", (__bridge void *)self])) {
        HSLogUSBDiagnostic(@"event=SSP_ENQUEUE manager=%p operation=%p type=%@ sid=%@ timeout=%@", (__bridge void *)self, (__bridge void *)operation, NSStringFromClass([operation class]), HSTraceValue(operation, @"sessionId"), HSTraceValue(operation, @"timeout"));
    }
    IMP original = command == NSSelectorFromString(@"enqueueOperationToFirst:") ? HSEnqueueFirstOriginal : HSEnqueueOriginal;
    ((void (*)(id, SEL, id))original)(self, command, operation);
}

static BOOL HSTraceHook(NSString *className, NSString *name, const char *types, IMP implementation, IMP *original) {
    Class target = NSClassFromString(className);
    Method method = class_getInstanceMethod(target, NSSelectorFromString(name));
    if (!method || strcmp(method_getTypeEncoding(method), types) != 0) {
        HSLogUSBDiagnostic(@"event=TRANSPORT_HOOK_REJECTED class=%@ method=%@", className, name);
        return NO;
    }
    *original = method_setImplementation(method, implementation);
    return YES;
}

static BOOL HSFileCallbackLayout(NSString *className) {
    Class target = NSClassFromString(className);
    NSArray *names = @[@"progress", @"setProgress:", @"finishBlock", @"setFinishBlock:"];
    const char *types[] = {"@?16@0:8", "v24@0:8@?16", "@?16@0:8", "v24@0:8@?16"};
    for (NSUInteger index = 0; index < names.count; index++) {
        Method method = class_getInstanceMethod(target, NSSelectorFromString(names[index]));
        if (!method || strcmp(method_getTypeEncoding(method), types[index]) != 0) {
            HSLogUSBDiagnostic(@"event=TRANSPORT_HOOK_REJECTED class=%@ method=%@ reason=file-callback-layout", className, names[index]);
            return NO;
        }
    }
    return YES;
}

void HSInstallUSBTransportDiagnostics(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (strcmp(getenv("HS_USB_DIAGNOSTICS") ?: "", "1") != 0) return;
        HSTraceLock = [[NSLock alloc] init];
        HSActiveBulk = [NSMutableDictionary dictionary];
        HSCounters = [NSMutableDictionary dictionary];
        HSFileTransfers = [NSMapTable strongToWeakObjectsMapTable];
        NSUInteger hooks = 0;
        hooks += HSTraceHook(@"SFUSBDevice", @"sendHandShakeRequestWithMSTimeout:", "@20@0:8i16", (IMP)HSHandshakeTrace, &HSHandshakeOriginal);
        hooks += HSTraceHook(@"SFUSBDevice", @"sendData:withSessionId:withFlag:", "c32@0:8@16I24c28", (IMP)HSDataTrace, (IMP *)&HSDataOriginal);
        hooks += HSTraceHook(@"SFUSBDevice", @"sendHandShakeRequest01WithMSTimeout:error:", "c28@0:8i16^@20", (IMP)HSPhase01Trace, (IMP *)&HSPhase01Original);
        hooks += HSTraceHook(@"SFUSBDevice", @"sendHandShakeRequest02WithMSTimeout:error:", "c28@0:8i16^@20", (IMP)HSPhase02Trace, (IMP *)&HSPhase02Original);
        hooks += HSTraceHook(@"SFUSBDevice", @"messageReadingThreadMain", "v16@0:8", (IMP)HSReadTrace, &HSReadOriginal);
        hooks += HSTraceHook(@"SSPManager", @"writeThreadMain", "v16@0:8", (IMP)HSWriteTrace, &HSWriteOriginal);
        hooks += HSTraceHook(@"SSPManager", @"enqueueOperation:", "v24@0:8@16", (IMP)HSEnqueueTrace, &HSEnqueueOriginal);
        hooks += HSTraceHook(@"SSPManager", @"enqueueOperationToFirst:", "v24@0:8@16", (IMP)HSEnqueueTrace, &HSEnqueueFirstOriginal);
        NSUInteger bulk = HSInstallBulkCallsites();
        NSUInteger fileHooks = 0;
        fileHooks += HSTraceHook(@"SFGenericDevice", @"sendRequestData:withSessionId:error:", "c40@0:8@16q24^@32", (IMP)HSFileRequest, &HSFileRequestOriginal);
        fileHooks += HSTraceHook(@"SFGenericDevice", @"sendFileData:withSessionId:error:", "c40@0:8@16q24^@32", (IMP)HSFileData, &HSFileDataOriginal);
        HSFileCallbacksReady = HSFileCallbackLayout(@"SSPUploadFileRequestOperation") && HSFileCallbackLayout(@"SSPDownloadFileRequestOperation");
        HSLogUSBDiagnostic(@"event=DIAGNOSTIC_CAPABILITIES schema=3 hooks=%lu bulkSites=%lu fileHooks=%lu fileCallbacks=%d expectedHooks=8 expectedBulkSites=10 expectedFileHooks=2 payloads=0", (unsigned long)hooks, (unsigned long)bulk, (unsigned long)fileHooks, HSFileCallbacksReady);
        HSTraceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(HSTraceTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(HSTraceTimer, ^{
            @autoreleasepool {
                NSMutableArray *pending = [NSMutableArray array];
                double now = NSProcessInfo.processInfo.systemUptime;
                [HSTraceLock lock];
                for (NSMutableDictionary *state in HSActiveBulk.allValues) {
                    double age = (now - [state[@"started"] doubleValue]) * 1000.0;
                    if (age >= 2000 && now - [state[@"last"] doubleValue] >= 10) {
                        state[@"last"] = @(now);
                        unsigned int timeout = [state[@"timeout"] unsignedIntValue];
                        [pending addObject:[NSString stringWithFormat:@"event=BULK_PENDING %@ elapsedMs=%.3f deadlineExceeded=%d", state[@"fields"], age, timeout > 0 && age > timeout + 1000.0]];
                    }
                }
                [HSTraceLock unlock];
                for (NSString *record in pending) HSLogUSBDiagnostic(@"%@", record);
            }
        });
        dispatch_resume(HSTraceTimer);
    });
}
