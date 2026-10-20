#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>
#import <libproc.h>
#import <errno.h>

extern int SlateValidateRuntime(NSString *path);
static int stateLease = -1;
static NSString *ProcessIdentity(pid_t pid) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return nil;
    return [NSString stringWithFormat:@"%llu:%llu", info.pbi_start_tvsec, info.pbi_start_tvusec];
}

static NSString *Argument(NSString *name) {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [args indexOfObject:name];
    return index != NSNotFound && index + 1 < args.count ? args[index + 1] : nil;
}
static BOOL PrivateDirectory(NSString *path) {
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&error]) return NO;
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)
        && info.st_uid == getuid() && (info.st_mode & 0777) == 0700;
}
static int Lock(NSString *path, NSTimeInterval timeout) {
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    struct stat info;
    if (fd < 0) return -1;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid()
        || (info.st_mode & 0777) != 0600) { close(fd); return -1; }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    BOOL reportedWait = NO;
    while (flock(fd, LOCK_EX | LOCK_NB)) {
        if ((errno != EWOULDBLOCK && errno != EAGAIN)
            || NSProcessInfo.processInfo.systemUptime >= deadline) { close(fd); return -1; }
        if (!reportedWait && [NSProcessInfo.processInfo.environment[@"SLATE_TERM_INTEGRATION"] isEqual:@"1"]) {
            fprintf(stderr, "layout app waiting for maintenance lease\n"); reportedWait = YES;
        }
        usleep(50000);
    }
    return fd;
}
static NSString *Revision(NSString *runtime) {
    NSData *data = [NSData dataWithContentsOfFile:[runtime stringByAppendingPathComponent:@"SlateRuntime"]];
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); ++i) [result appendFormat:@"%02x", digest[i]];
    return result;
}
static NSString *SignedCodeHash(NSString *path) {
    SecStaticCodeRef code = NULL;
    CFDictionaryRef information = NULL;
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path], 0, &code)) return nil;
    OSStatus status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    CFRelease(code);
    if (status) return nil;
    NSDictionary *fields = CFBridgingRelease(information);
    NSData *hash = fields[(__bridge NSString *)kSecCodeInfoUnique];
    if (![hash isKindOfClass:NSData.class]) return nil;
    NSMutableString *result = [NSMutableString string];
    const unsigned char *bytes = hash.bytes;
    for (NSUInteger i = 0; i < hash.length; ++i) [result appendFormat:@"%02x", bytes[i]];
    return result;
}
static BOOL ValidateShell(NSString *path) {
    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path], 0, &code);
    if (!status) status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckNestedCode, NULL);
    if (code) CFRelease(code);
    return status == errSecSuccess;
}
static NSString *Runtime(NSString *app) { return [app stringByAppendingPathComponent:@"Contents/Frameworks/SlateRuntime.framework"]; }
static NSDictionary *RuntimeInfo(NSString *runtime) {
    return [NSDictionary dictionaryWithContentsOfFile:[runtime stringByAppendingPathComponent:@"Resources/Info.plist"]] ?: @{};
}
static BOOL CompatibleInfo(NSDictionary *info) {
    id abi = info[@"SlateRuntimeABI"];
    id build = info[@"CFBundleVersion"];
    return (([abi isKindOfClass:NSNumber.class] && [abi isEqual:@1]) || [abi isEqual:@"1"])
        && [build isKindOfClass:NSString.class] && [build length] > 0 && [build length] <= 64;
}
static BOOL RemoveStage(NSString *stage) {
    NSString *directory = stage.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) return YES;
    return [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}
static BOOL Recover(NSString *base, NSString *runtime, NSString *shell) {
    NSString *journal = [base stringByAppendingPathComponent:@"refresh.plist"];
    NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:journal];
    if (!record) return ![NSFileManager.defaultManager fileExistsAtPath:journal];
    NSString *staged = record[@"staged"];
    NSString *previous = record[@"previousRevision"], *next = record[@"nextRevision"];
    if (![staged isKindOfClass:NSString.class] || ![previous isKindOfClass:NSString.class]
        || ![next isKindOfClass:NSString.class]
        || ![[staged.stringByDeletingLastPathComponent stringByDeletingLastPathComponent] isEqual:shell.stringByDeletingLastPathComponent]
        || ![staged.stringByDeletingLastPathComponent.lastPathComponent hasPrefix:@".slate-runtime-"]
        || ![staged.lastPathComponent isEqual:@"SlateRuntime.framework"]) return NO;
    struct stat transaction;
    if (lstat(staged.stringByDeletingLastPathComponent.fileSystemRepresentation, &transaction) == 0
        && (!S_ISDIR(transaction.st_mode) || transaction.st_uid != getuid() || (transaction.st_mode & 0777) != 0700)) return NO;
    NSString *installed = Revision(runtime);
    if (!([installed isEqual:previous] || [installed isEqual:next])) return NO;
    if (!ValidateShell(shell) || SlateValidateRuntime(runtime) || !CompatibleInfo(RuntimeInfo(runtime))) {
        if (![Revision(staged) isEqual:previous] || SlateValidateRuntime(staged)
            || !CompatibleInfo(RuntimeInfo(staged))
            || renamex_np(staged.fileSystemRepresentation, runtime.fileSystemRepresentation, RENAME_SWAP)
            || !ValidateShell(shell) || SlateValidateRuntime(runtime)) return NO;
    }
    if (!RemoveStage(staged)) return NO;
    return [NSFileManager.defaultManager removeItemAtPath:journal error:nil];
}
static int FailureCode(NSString *message, BOOL manual, int status) {
    fprintf(stderr, "%s\n", message.UTF8String);
    if (!manual && ![NSProcessInfo.processInfo.environment[@"SLATE_TERM_INTEGRATION"] isEqual:@"1"]) {
        NSAlert *alert = [NSAlert new]; alert.messageText = [NSString stringWithFormat:@"%@ could not start", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"This layout app"];
        alert.informativeText = message; [alert addButtonWithTitle:@"Quit"]; [alert runModal];
    }
    return status;
}
static int Failure(NSString *message, BOOL manual) { return FailureCode(message, manual, 70); }

// Runs before any runtime code, plugin, configuration writer, or terminal exists.
int SlatePrepareLayoutApp(void) {
    NSBundle *shell = NSBundle.mainBundle;
    BOOL manual = [NSProcessInfo.processInfo.arguments containsObject:@"--slate-refresh-only"];
    NSString *identifier = [shell objectForInfoDictionaryKey:@"SlateLayoutAppID"];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid || ![shell.bundleIdentifier isEqual:[@"com.slateterm.layoutapp." stringByAppendingString:uuid.UUIDString.lowercaseString]])
        return Failure(@"Invalid layout app identity.", manual);
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    BOOL integration = [environment[@"SLATE_TERM_INTEGRATION"] isEqual:@"1"];
    NSString *parentBase = integration ? environment[@"SLATE_TERM_STATE_DIR"] :
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/SlateTerm"];
    if (!parentBase.isAbsolutePath) return Failure(@"An isolated parent state directory is required.", manual);
    NSString *base = [parentBase stringByAppendingPathComponent:[@"LayoutApps/" stringByAppendingString:uuid.UUIDString.lowercaseString]];
    NSString *state = [base stringByAppendingPathComponent:@"state"];
    if (!PrivateDirectory(base) || !PrivateDirectory(state)) return Failure(@"Layout app state must be private and owned by this user.", manual);
    // Normal launches can outwait a slow refresh; explicit maintenance still refuses immediately.
    int maintenance = Lock([base stringByAppendingPathComponent:@"maintenance.lock"], manual ? 0 : 60);
    if (maintenance < 0) return FailureCode(@"This app is being refreshed; try again when it finishes.", manual, 75);
    stateLease = Lock([state stringByAppendingPathComponent:@"workspace.lock"], 0);
    if (stateLease < 0) {
        close(maintenance);
        if (!manual) {
            NSDictionary *owner = [NSDictionary dictionaryWithContentsOfFile:[base stringByAppendingPathComponent:@"owner.plist"]];
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:[owner[@"pid"] intValue]];
            if (app && [app.bundleIdentifier isEqual:shell.bundleIdentifier]
                && [app.bundleURL.path isEqual:owner[@"path"]]
                && [ProcessIdentity(app.processIdentifier) isEqual:owner[@"started"]]) {
                [app activateWithOptions:NSApplicationActivateIgnoringOtherApps]; return 10;
            }
        }
        return FailureCode(@"The app is running or its state is owned by another process.", manual, 75);
    }
    NSString *runtime = Runtime(shell.bundlePath);
    if (!Recover(base, runtime, shell.bundlePath)) { close(maintenance); return Failure(@"An interrupted runtime update needs repair; no workspace was started.", manual); }
    NSString *revision = Revision(runtime);
    NSString *expected = Argument(@"--expected-bundle-revision");
    if (manual && (!expected || ![expected isEqual:revision])) { close(maintenance); return FailureCode(@"The app changed; inspect it again before refreshing.", YES, 76); }
    if (!ValidateShell(shell.bundlePath) || SlateValidateRuntime(runtime)) { close(maintenance); return Failure(@"The installed app signature is invalid; restore the app before starting.", manual); }
    NSString *parentID = [shell objectForInfoDictionaryKey:@"SlateParentBundleID"];
    if (![parentID isKindOfClass:NSString.class] || !parentID.length) { close(maintenance); return Failure(@"Invalid parent identity.", manual); }
    NSString *explicitParent = Argument(@"--slate-parent-path");
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (explicitParent) { [candidates addObject:explicitParent]; }
    else {
        NSString *stored = [shell objectForInfoDictionaryKey:@"SlateParentPath"];
        if ([stored isKindOfClass:NSString.class]) [candidates addObject:stored];
        NSString *registered = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:parentID].path;
        if (registered && ![candidates containsObject:registered]) [candidates addObject:registered];
    }
    NSString *source = nil;
    NSDictionary *next = @{};
    for (NSString *path in candidates) {
        NSBundle *parent = [NSBundle bundleWithPath:path];
        if (!parent || ![parent.bundleIdentifier isEqual:parentID] || [parent objectForInfoDictionaryKey:@"SlateLayoutAppID"]) continue;
        NSString *candidate = Runtime(path);
        NSDictionary *info = RuntimeInfo(candidate);
        if (SlateValidateRuntime(candidate) || !CompatibleInfo(info)) continue;
        source = candidate; next = info; break;
    }
    BOOL compatible = source != nil;
    NSString *expectedParentRevision = Argument(@"--slate-expected-parent-revision");
    NSString *expectedParentCodeHash = Argument(@"--slate-expected-parent-code-hash");
    if ((expectedParentRevision && (!source || ![Revision(source) isEqual:expectedParentRevision]))
        || (expectedParentCodeHash && (!source || ![SignedCodeHash(source) isEqual:expectedParentCodeHash]))) {
        if (manual) {
            close(maintenance);
            return FailureCode(@"The selected Slate Terminal update changed or became unavailable. No runtime was replaced. Open Slate Terminal and check again.", YES, 76);
        }
        // A restart can still use its verified private runtime when the selected parent changes.
        compatible = NO; source = nil; next = @{};
    }
    NSDictionary *current = RuntimeInfo(runtime);
    NSString *nextBuild = next[@"CFBundleVersion"], *currentBuild = current[@"CFBundleVersion"];
    BOOL newer = compatible && [currentBuild isKindOfClass:NSString.class] && [nextBuild compare:currentBuild options:NSNumericSearch] == NSOrderedDescending;
    BOOL changed = source && ![Revision(source) isEqual:revision];
    BOOL eligible = compatible && [currentBuild isKindOfClass:NSString.class]
        && [nextBuild compare:currentBuild options:NSNumericSearch] != NSOrderedAscending;
    if (manual && !eligible) { close(maintenance); return FailureCode(@"A compatible Slate Terminal installation is unavailable.", YES, 77); }
    if ((newer || (manual && changed)) && eligible) {
        if (SlateValidateRuntime(source)) { close(maintenance); return Failure(@"The parent runtime signature is invalid. The existing app was preserved.", manual); }
        NSString *selectedRevision = expectedParentRevision ?: Revision(source);
        // Keep the backup outside the sealed app while validating its unchanged outer signature.
        NSString *transaction = [shell.bundlePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:
            [NSString stringWithFormat:@".slate-runtime-%@", NSUUID.UUID.UUIDString]];
        if (!PrivateDirectory(transaction)) { close(maintenance); return Failure(@"Could not create a private update directory.", manual); }
        NSString *stage = [transaction stringByAppendingPathComponent:@"SlateRuntime.framework"];
        NSError *error = nil;
        if (![NSFileManager.defaultManager copyItemAtPath:source toPath:stage error:&error] || SlateValidateRuntime(stage)
            || !CompatibleInfo(RuntimeInfo(stage)) || ![Revision(stage) isEqual:selectedRevision]
            || (expectedParentCodeHash && ![SignedCodeHash(stage) isEqual:expectedParentCodeHash])
            || ![RuntimeInfo(stage)[@"CFBundleVersion"] isEqual:nextBuild]) {
            RemoveStage(stage); close(maintenance);
            return Failure(@"Could not stage a verified runtime; the existing app was preserved.", manual);
        }
        NSString *journal = [base stringByAppendingPathComponent:@"refresh.plist"];
        NSDictionary *record = @{@"staged":stage, @"previousRevision":revision, @"nextRevision":Revision(stage) ?: @""};
        if (![record writeToFile:journal atomically:YES] || renamex_np(stage.fileSystemRepresentation, runtime.fileSystemRepresentation, RENAME_SWAP)) {
            RemoveStage(stage); close(maintenance);
            return Failure(@"Could not replace the private runtime; the existing app was preserved.", manual);
        }
        if (!ValidateShell(shell.bundlePath) || SlateValidateRuntime(runtime) || !CompatibleInfo(RuntimeInfo(runtime))) {
            BOOL rolledBack = renamex_np(stage.fileSystemRepresentation, runtime.fileSystemRepresentation, RENAME_SWAP) == 0;
            close(maintenance);
            return Failure(rolledBack ? @"The new runtime is incompatible with this shell; the previous runtime was restored." : @"Runtime recovery needs repair. No workspace was started.", manual);
        }
        RemoveStage(stage);
        [NSFileManager.defaultManager removeItemAtPath:journal error:nil];
    }
    if (!manual) {
        [@{@"pid":@(getpid()), @"path":shell.bundlePath, @"started":ProcessIdentity(getpid()) ?: @""} writeToFile:[base stringByAppendingPathComponent:@"owner.plist"] atomically:YES];
        setenv("SLATE_LAYOUT_STATE_FD", [[NSString stringWithFormat:@"%d", stateLease] UTF8String], 1);
    }
    close(maintenance);
    return manual ? 10 : 0;
}
