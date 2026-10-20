#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <stdint.h>
#import <sys/stat.h>
#import <libproc.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>

#ifndef SLATE_RUNTIME_DEVELOPMENT
#define SLATE_RUNTIME_DEVELOPMENT 0
#endif

extern int SlatePrepareLayoutApp(void);

static int fail(NSString *message, int status) {
    NSString *name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"Slate Terminal";
    fprintf(stderr, "%s could not start: %s (%d)\n", name.UTF8String, message.UTF8String, status);
    if (![NSProcessInfo.processInfo.environment[@"SLATE_TERM_INTEGRATION"] isEqual:@"1"]) {
        NSAlert *alert = [NSAlert new]; alert.messageText = [name stringByAppendingString:@" could not start"];
        alert.informativeText = message; [alert addButtonWithTitle:@"Quit"]; [alert runModal];
    }
    return status;
}

int SlateValidateRuntime(NSString *path) {
    struct stat metadata;
    if (lstat(path.fileSystemRepresentation, &metadata) != 0 || !S_ISDIR(metadata.st_mode)) {
        return errSecCSBadBundleFormat;
    }
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    // The publisher and identifier are fixed in the shell, never read from mutable runtime metadata.
    NSString *predicate = @"anchor apple generic and certificate leaf[subject.OU] = \"YWRT8FQN6F\" and identifier \"com.slateterm.runtime\"";
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) {
        status = SecRequirementCreateWithString((__bridge CFStringRef)predicate, kSecCSDefaultFlags, &requirement);
    }
    if (status == errSecSuccess) {
        status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSRestrictSymlinks, requirement);
    }
#if SLATE_RUNTIME_DEVELOPMENT
    // Only Debug shells compile this local-development exception. Release shells cannot enable it at runtime.
    if (status != errSecSuccess && code) {
        CFDictionaryRef information = NULL;
        OSStatus infoStatus = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
        if (infoStatus == errSecSuccess) {
            NSDictionary *info = CFBridgingRelease(information);
            uint32_t flags = [info[(__bridge NSString *)kSecCodeInfoFlags] unsignedIntValue];
            NSString *identifier = info[(__bridge NSString *)kSecCodeInfoIdentifier];
            if ((flags & kSecCodeSignatureAdhoc) && [identifier isEqualToString:@"com.slateterm.runtime"]) {
                status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSRestrictSymlinks, NULL);
            }
        }
    }
#endif
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    return status;
}

// A restart helper never loads the runtime or acquires its workspace lease.
static int RelaunchAfterExit(int argc, const char *argv[]) {
    if (argc != 11 || strcmp(argv[1], "--slate-relaunch-after") || strcmp(argv[3], "--slate-relaunch-identity")
        || strcmp(argv[5], "--slate-parent-path") || strcmp(argv[7], "--slate-expected-parent-revision")
        || strcmp(argv[9], "--slate-expected-parent-code-hash")) return 64;
    NSBundle *shell = NSBundle.mainBundle;
    NSString *appID = [shell objectForInfoDictionaryKey:@"SlateLayoutAppID"];
    NSUUID *uuid = [appID isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:appID] : nil;
    if (!uuid || ![shell.bundleIdentifier isEqual:[@"com.slateterm.layoutapp." stringByAppendingString:uuid.UUIDString.lowercaseString]]) return 64;
    char *end = NULL;
    long value = strtol(argv[2], &end, 10);
    if (!end || *end || value <= 1 || value > INT_MAX) return 64;
    pid_t pid = (pid_t)value;
    if (pid != getppid()) return 64;
    NSString *expected = [NSString stringWithUTF8String:argv[4]];
    NSString *parentPath = [NSString stringWithUTF8String:argv[6]];
    NSString *parentRevision = [NSString stringWithUTF8String:argv[8]];
    NSString *parentCodeHash = [NSString stringWithUTF8String:argv[10]];
    if (!parentPath.isAbsolutePath || parentRevision.length != 64 || parentCodeHash.length != 40) return 64;
    struct proc_bsdinfo original = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &original, sizeof(original)) != sizeof(original)) return 75;
    NSString *identity = [NSString stringWithFormat:@"%llu:%llu", original.pbi_start_tvsec, original.pbi_start_tvusec];
    if (![expected isEqual:identity]) return 75;
    // The caller quits only after the installed shell acknowledges this protocol.
    if (fprintf(stdout, "READY\n") < 0 || fflush(stdout)) return 75;
    BOOL exited = NO;
    for (int attempt = 0; attempt < 1200; ++attempt) {
        struct proc_bsdinfo info = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
            NSString *identity = [NSString stringWithFormat:@"%llu:%llu", info.pbi_start_tvsec, info.pbi_start_tvusec];
            if (![expected isEqual:identity]) { exited = YES; break; }
        } else if (kill(pid, 0) == -1 && errno == ESRCH) { exited = YES; break; }
        // An exited process can remain visible until its parent reaps it.
        usleep(100000);
    }
    if (!exited) return 75;
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.createsNewApplicationInstance = YES;
    configuration.activates = YES;
    configuration.arguments = @[@"--slate-parent-path", parentPath, @"--slate-expected-parent-revision", parentRevision, @"--slate-expected-parent-code-hash", parentCodeHash];
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    if ([environment[@"SLATE_TERM_INTEGRATION"] isEqual:@"1"]) {
        NSMutableDictionary *isolated = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"SLATE_TERM_INTEGRATION", @"SLATE_TERM_STATE_DIR", @"SLATE_TERM_CONFIG_FILE", @"SLATE_TERM_TEST_REAL_SHELL", @"ZDOTDIR"]) {
            if (environment[key]) isolated[key] = environment[key];
        }
        configuration.environment = isolated;
    }
    __block BOOL completed = NO;
    __block int result = 75;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:shell.bundleURL configuration:configuration completionHandler:^(NSRunningApplication *application, NSError *error) {
        result = application && !error ? 0 : 75;
        completed = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return result;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (![NSThread isMainThread]) return fail(@"The runtime must start on the main thread", 64);
        if (argc > 1 && !strcmp(argv[1], "--slate-relaunch-after")) return RelaunchAfterExit(argc, argv);
        NSBundle *shell = NSBundle.mainBundle;
        if ([shell objectForInfoDictionaryKey:@"SlateLayoutAppID"]) {
            int status = SlatePrepareLayoutApp();
            if (status != 0) return status == 10 ? 0 : status;
        }
        NSURL *runtime = [shell.bundleURL URLByAppendingPathComponent:@"Contents/Frameworks/SlateRuntime.framework" isDirectory:YES];
        // Reject external payload links before signature checking or loading.
        NSString *expected = [[[shell.bundleURL URLByResolvingSymlinksInPath]
            URLByAppendingPathComponent:@"Contents/Frameworks/SlateRuntime.framework"].path stringByStandardizingPath];
        if (![[runtime URLByResolvingSymlinksInPath].path isEqualToString:expected]) {
            return fail(@"The private runtime must be inside this app", 65);
        }
        OSStatus status = SlateValidateRuntime(runtime.path);
        if (status != errSecSuccess) return fail(@"The runtime signature is not trusted", (int)status);
        NSBundle *runtimeBundle = [NSBundle bundleWithURL:runtime];
        id abi = [runtimeBundle objectForInfoDictionaryKey:@"SlateRuntimeABI"];
        if (!(([abi isKindOfClass:NSNumber.class] && [abi isEqual:@1]) || [abi isEqual:@"1"])) {
            return fail(@"This shell does not support the installed runtime", 66);
        }
        void *handle = dlopen(runtimeBundle.executableURL.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) return fail([NSString stringWithUTF8String:dlerror()], 67);
        int32_t (*entry)(uint32_t) = (int32_t (*)(uint32_t))dlsym(handle, "SlateRuntimeMain");
        if (!entry) return fail(@"The runtime entry point is missing", 68);
        // The framework remains loaded until process exit; Ghostty owns process-global state.
        return entry(1);
    }
}
