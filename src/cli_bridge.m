#import <Foundation/Foundation.h>
#import "cli_bridge.h"
#import "core_simulator_bridge.h"
#include <sys/file.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <spawn.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <errno.h>
extern char **environ;

static void fail(NSString *message) { @throw [NSException exceptionWithName:@"SimutexError" reason:message userInfo:nil]; }
static NSString *absolute(NSString *path, NSString *base) {
    return [(path.isAbsolutePath ? path : [base stringByAppendingPathComponent:path]) stringByStandardizingPath];
}
static NSString *statePath(void) {
    NSString *path = NSProcessInfo.processInfo.environment[@"SIMUTEX_STATE_DIR"];
    return absolute(path ?: [(NSProcessInfo.processInfo.environment[@"TMPDIR"] ?: @"/tmp") stringByAppendingPathComponent:@"simutex"], NSFileManager.defaultManager.currentDirectoryPath);
}
static NSString *metadataPath(void) {
    NSString *path = NSProcessInfo.processInfo.environment[@"SIMUTEX_METADATA_PATH"];
    return absolute(path ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/simutex/metadata.json"], NSFileManager.defaultManager.currentDirectoryPath);
}
static void mkdirs(NSString *path) {
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) fail(error.localizedDescription);
}
int simutex_guard_acquire(int directory_fd) {
    int fd = -1;
    // Open an existing guard first. Racing O_CREAT opens on APFS can transiently
    // report ENOENT; exclusive creation plus reopening handles both contenders.
    for (int attempt=0; attempt<32; attempt++) {
        fd = openat(directory_fd, ".mutation-guard", O_RDWR|O_CLOEXEC|O_NOFOLLOW);
        if (fd >= 0) break;
        if (errno == EINTR) continue;
        if (errno != ENOENT) return -1;
        fd = openat(directory_fd, ".mutation-guard", O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC|O_NOFOLLOW, 0600);
        if (fd >= 0) break;
        if (errno != EEXIST && errno != ENOENT && errno != EINTR) return -1;
        usleep(1000);
    }
    if (fd < 0) return -1;
    while (flock(fd, LOCK_EX) < 0) { if (errno != EINTR) { int saved = errno; close(fd); errno = saved; return -1; } }
    return fd;
}
void simutex_guard_release(int fd) { if (fd >= 0) close(fd); }
static int guard(NSString *directory) {
    mkdirs(directory);
    int d = open(directory.fileSystemRepresentation, O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (d < 0) fail(@"Cannot open state directory");
    int fd = simutex_guard_acquire(d); int saved = errno; close(d); errno = saved;
    if (fd < 0) fail([NSString stringWithFormat:@"Cannot acquire mutation guard: %s", strerror(errno)]);
    return fd;
}
static NSDictionary *readJSON(NSString *path, BOOL missingOK) {
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!data) {
        if (missingOK && error.code == NSFileReadNoSuchFileError) return @{};
        fail([NSString stringWithFormat:@"Cannot read %@: %@", path, error.localizedDescription]);
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (![json isKindOfClass:NSDictionary.class]) fail([NSString stringWithFormat:@"Expected JSON object in %@: %@ (%lu bytes)", path, error.localizedDescription, (unsigned long)data.length]);
    return json;
}
static NSData *jsonData(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    if (!data) fail(error.localizedDescription);
    return data;
}
static void printJSON(id object) { NSData *d = jsonData(object); fwrite(d.bytes, 1, d.length, stdout); puts(""); fflush(stdout); }
static NSDictionary *metadata(void) {
    NSDictionary *root = readJSON(metadataPath(), YES);
    if (root[@"devices"] && ![root[@"devices"] isKindOfClass:NSDictionary.class]) fail(@"Invalid metadata devices");
    return root;
}
static NSDictionary *deviceMetadata(NSDictionary *root, NSString *udid) {
    id value = root[@"devices"][udid];
    if (value && ![value isKindOfClass:NSDictionary.class]) fail(@"Invalid simulator metadata");
    if (value[@"description"] && ![value[@"description"] isKindOfClass:NSString.class]) fail(@"Invalid simulator description");
    if (value[@"hooks"] && ![value[@"hooks"] isKindOfClass:NSDictionary.class]) fail(@"Invalid simulator hooks");
    return value ?: @{};
}
static void validUDID(NSString *udid) {
    if (!udid.length || [udid lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128 || [udid rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\\n\r\0"]].location != NSNotFound || [udid isEqual:@"."] || [udid isEqual:@".."]) fail(@"Invalid simulator UDID");
}
static BOOL canonicalOwner(NSString *owner) {
    NSUInteger prefix = [owner hasPrefix:@"manual:"] ? 7 : ([owner hasPrefix:@"agent:"] ? 6 : 0);
    return prefix && owner.length > prefix && [owner lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 256 && [owner rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static NSString *lockPath(NSString *udid) { validUDID(udid); return [statePath() stringByAppendingPathComponent:[udid stringByAppendingString:@".lock"]]; }
static NSString *ownerOf(NSString *udid) {
    char bytes[257]; ssize_t n = readlink(lockPath(udid).fileSystemRepresentation, bytes, sizeof(bytes));
    if (n < 0) { if (errno == ENOENT) return nil; fail(@"Cannot read simulator lock (expected symbolic link)"); }
    NSString *owner = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)n encoding:NSUTF8StringEncoding];
    if (!owner.length || n > 256) fail(@"Invalid simulator lock");
    return owner;
}
static void mutateMetadata(NSString *udid, void (^edit)(NSMutableDictionary *)) {
    validUDID(udid);
    NSString *path = metadataPath(); int fd = guard(path.stringByDeletingLastPathComponent);
    @try {
        NSMutableDictionary *root = [metadata() mutableCopy];
        NSMutableDictionary *devices = [root[@"devices"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *device = [deviceMetadata(root, udid) mutableCopy];
        edit(device); devices[udid] = device; root[@"devices"] = devices; root[@"version"] = @1;
        NSData *data = jsonData(root);
        NSString *temporary = [path stringByAppendingFormat:@".tmp-%@", NSUUID.UUID.UUIDString];
        int out = open(temporary.fileSystemRepresentation, O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC, 0600);
        if (out < 0) fail(@"Cannot create metadata temporary file");
        @try {
            size_t offset = 0;
            while (offset < data.length) {
                ssize_t n = write(out, (const char *)data.bytes + offset, data.length-offset);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) fail(@"Cannot write metadata");
                offset += (size_t)n;
            }
            if (fsync(out) || rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation)) fail(@"Cannot commit metadata");
        } @finally { close(out); unlink(temporary.fileSystemRepresentation); }
    } @finally { close(fd); }
}
char *simutex_copy_description(const char *udid) {
    @autoreleasepool { @try { NSString *description = deviceMetadata(metadata(), @(udid))[@"description"] ?: @""; return strdup([[[description componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "] UTF8String]); } @catch (NSException *e) { return strdup(""); } }
}

static NSDictionary *normalizeHook(id value, NSString *base) {
    if (value == NSNull.null) return (id)NSNull.null;
    if (![value isKindOfClass:NSDictionary.class]) fail(@"Hook must be an object or null (disabled)");
    NSArray *argv = value[@"argv"];
    if (![argv isKindOfClass:NSArray.class] || !argv.count) fail(@"Hook requires a nonempty argv array");
    for (id a in argv) if (![a isKindOfClass:NSString.class] || [a rangeOfString:@"\0"].location != NSNotFound) fail(@"Hook arguments must be strings without NUL");
    if (![argv[0] length]) fail(@"Hook executable is empty");
    id timeout = value[@"timeout_seconds"] ?: @60;
    if (![timeout isKindOfClass:NSNumber.class] || !isfinite([timeout doubleValue]) || [timeout doubleValue] <= 0 || [timeout doubleValue] > 86400) fail(@"Hook timeout_seconds must be between 0 and 86400");
    id cwd = value[@"cwd"] ?: base;
    if (![cwd isKindOfClass:NSString.class]) fail(@"Hook cwd must be a string");
    NSMutableArray *args = [argv mutableCopy]; args[0] = absolute(args[0], base);
    return @{ @"argv":args, @"cwd":absolute(cwd, base), @"timeout_seconds":timeout };
}
static NSDictionary *effectiveHooks(NSString *udid, NSDictionary *options) {
    NSString *cwd = NSFileManager.defaultManager.currentDirectoryPath;
    NSString *file = options[@"--hooks"] ?: NSProcessInfo.processInfo.environment[@"SIMUTEX_HOOKS"];
    NSDictionary *defaults = file ? readJSON(absolute(file, cwd), NO) : @{};
    NSDictionary *device = deviceMetadata(metadata(), udid)[@"hooks"] ?: @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *event in @[@"pre_claim", @"post_claim"]) {
        NSString *flag = [@"--" stringByAppendingString:[event stringByReplacingOccurrencesOfString:@"_" withString:@"-"]];
        NSString *disable = [@"--no-" stringByAppendingString:[event stringByReplacingOccurrencesOfString:@"_" withString:@"-"]];
        id value = defaults[event]; NSString *base = file ? absolute(file, cwd).stringByDeletingLastPathComponent : cwd;
        if (device[event]) { value = device[event]; base = metadataPath().stringByDeletingLastPathComponent; }
        if (options[flag]) { value = @{ @"argv":@[options[flag]] }; base = cwd; }
        if (options[disable]) value = NSNull.null;
        result[event] = value ? normalizeHook(value, base) : NSNull.null;
    }
    return result;
}
static void runHook(id hook, NSString *event, NSString *udid, NSString *owner, NSString *previous, NSString *operation) {
    if (!hook || hook == NSNull.null) return;
    NSArray *args = hook[@"argv"];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"SIMUTEX_HOOK_EVENT"] = [event stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    env[@"SIMUTEX_UDID"] = udid; env[@"SIMUTEX_OWNER"] = owner; env[@"SIMUTEX_PREVIOUS_OWNER"] = previous ?: @"";
    env[@"SIMUTEX_OPERATION"] = operation; env[@"SIMUTEX_STATE_DIR"] = statePath(); env[@"SIMUTEX_METADATA_PATH"] = metadataPath();
    char **argv = calloc(args.count + 1, sizeof(char *)), **envp = calloc(env.count + 1, sizeof(char *));
    if (!argv || !envp) { free(argv); free(envp); fail(@"Out of memory"); }
    for (NSUInteger i=0; i<args.count; i++) argv[i] = strdup([args[i] UTF8String]);
    NSUInteger i=0; for (NSString *key in env) envp[i++] = strdup([[NSString stringWithFormat:@"%@=%@", key, env[key]] UTF8String]);
    posix_spawnattr_t attr; posix_spawnattr_init(&attr); posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP); posix_spawnattr_setpgroup(&attr, 0);
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    posix_spawn_file_actions_addchdir_np(&actions, [hook[@"cwd"] fileSystemRepresentation]);
#pragma clang diagnostic pop
    pid_t pid; int rc = posix_spawn(&pid, argv[0], &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
    for (NSUInteger j=0; argv[j]; j++) free(argv[j]); free(argv);
    for (NSUInteger j=0; envp[j]; j++) free(envp[j]); free(envp);
    if (rc) fail([NSString stringWithFormat:@"%@ hook could not launch: %s", event, strerror(rc)]);
    double deadline = NSProcessInfo.processInfo.systemUptime + [hook[@"timeout_seconds"] doubleValue];
    int status = 0;
    while (true) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid) break;
        if (result < 0 && errno != EINTR) fail(@"Cannot wait for hook");
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            kill(-pid, SIGTERM); usleep(100000); kill(-pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            fail([NSString stringWithFormat:@"%@ hook timed out", event]);
        }
        usleep(10000);
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status)) fail([NSString stringWithFormat:@"%@ hook failed (%d)", event, WIFEXITED(status) ? WEXITSTATUS(status) : -1]);
}

static NSDictionary *inventoryJSON(SimutexCoreSimulatorConnection *connection) {
    char *error = NULL; char *json = connection ? simutex_core_simulator_connection_copy_inventory_json(connection, &error) : NULL;
    if (error) simutex_core_simulator_string_free(error);
    if (json) {
        NSData *data = [NSData dataWithBytes:json length:strlen(json)]; simutex_core_simulator_string_free(json);
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([root isKindOfClass:NSDictionary.class]) return root;
    }
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"]; task.arguments = @[@"simctl", @"list", @"devices", @"available", @"--json"];
    NSPipe *pipe = [NSPipe pipe]; task.standardOutput = pipe; task.standardError = NSFileHandle.fileHandleWithStandardError;
    NSError *e = nil; if (![task launchAndReturnError:&e]) fail(e.localizedDescription);
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit];
    if (task.terminationStatus) fail(@"xcrun simctl failed; select a full Xcode with DEVELOPER_DIR or xcode-select");
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) fail(@"Invalid simulator inventory");
    return root;
}
static NSArray *snapshot(SimutexCoreSimulatorConnection *connection) {
    NSDictionary *root = inventoryJSON(connection), *meta = metadata();
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *runtime in [root[@"devices"] allKeys]) {
        if (![runtime containsString:@".iOS-"]) continue;
        for (NSDictionary *device in root[@"devices"][runtime]) {
            if (![device[@"isAvailable"] boolValue]) continue;
            NSString *udid = device[@"udid"]; validUDID(udid);
            NSDictionary *dm = deviceMetadata(meta, udid);
            [result addObject:@{@"udid":udid, @"name":device[@"name"] ?: @"", @"runtime":runtime, @"state":device[@"state"] ?: @"Unknown", @"owner":ownerOf(udid) ?: (id)NSNull.null, @"description":dm[@"description"] ?: @"", @"hooks":dm[@"hooks"] ?: @{}}];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(id a,id b) { NSComparisonResult c = [a[@"name"] compare:b[@"name"]]; return c == NSOrderedSame ? [a[@"udid"] compare:b[@"udid"]] : c; }];
    return result;
}
static NSString *plain(NSString *value) {
    return [[value componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
}
static void printRows(NSArray *rows) {
    for (NSDictionary *d in rows) printf("%s\t%s\t%s\t%s\t%s\n", [d[@"udid"] UTF8String], [d[@"state"] UTF8String], [plain(d[@"name"]) UTF8String], d[@"owner"] == NSNull.null ? "available" : [plain(d[@"owner"]) UTF8String], [plain(d[@"description"]) UTF8String]);
}
static BOOL acquire(NSString *udid, NSString *owner, NSString *expected, NSDictionary *options) {
    NSString *previous = ownerOf(udid);
    if ([previous isEqual:owner]) return YES;
    if (expected && ![previous isEqual:expected]) fail(@"Owner changed; takeover cancelled");
    if (!expected && previous) return NO;
    if (!canonicalOwner(owner)) fail(@"New owner must be manual:<username> or agent:<purpose> (maximum 256 bytes, no control characters)");
    NSDictionary *hooks = effectiveHooks(udid, options);
    runHook(hooks[@"pre_claim"], @"pre_claim", udid, owner, previous, expected ? @"takeover" : @"claim");
    int fd = guard(statePath()); BOOL acquired = NO;
    @try {
        NSString *now = ownerOf(udid);
        if ([now isEqual:owner]) return YES;
        if (expected) {
            if (![now isEqual:expected]) fail(@"Owner changed; takeover cancelled");
            NSString *tmp = [statePath() stringByAppendingPathComponent:[@".takeover-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            if (symlink(owner.UTF8String, tmp.fileSystemRepresentation)) fail(@"Cannot create replacement lock");
            if (rename(tmp.fileSystemRepresentation, lockPath(udid).fileSystemRepresentation)) { unlink(tmp.fileSystemRepresentation); fail(@"Cannot replace lock"); }
            acquired = YES;
        } else if (!now) {
            if (symlink(owner.UTF8String, lockPath(udid).fileSystemRepresentation)) { if (errno != EEXIST) fail(@"Cannot create simulator lock"); }
            else acquired = YES;
        }
    } @finally { close(fd); }
    if (!acquired) return NO;
    @try {
        if (![ownerOf(udid) isEqual:owner]) fail(@"Ownership changed before post-claim");
        runHook(hooks[@"post_claim"], @"post_claim", udid, owner, previous, expected ? @"takeover" : @"claim");
        if (![ownerOf(udid) isEqual:owner]) fail(@"Ownership changed during post-claim");
    } @catch (NSException *e) {
        fail([NSString stringWithFormat:@"%@; simulator %@ current owner: %@. No lock was released; inspect before cleanup.", e.reason, udid, ownerOf(udid) ?: @"available"]);
    }
    return YES;
}

static void watchDevices(SimutexCoreSimulatorConnection *connection) {
    mkdirs(statePath()); mkdirs(metadataPath().stringByDeletingLastPathComponent);
    int kq = kqueue(); if (kq < 0) fail(@"Cannot create watch queue");
    NSMutableArray *fds = [NSMutableArray array];
    for (NSString *path in @[statePath(), metadataPath().stringByDeletingLastPathComponent]) {
        int fd = open(path.fileSystemRepresentation, O_EVTONLY|O_CLOEXEC);
        if (fd >= 0) { [fds addObject:@(fd)]; struct kevent ev; EV_SET(&ev, fd, EVFILT_VNODE, EV_ADD|EV_CLEAR, NOTE_WRITE|NOTE_RENAME|NOTE_DELETE, 0, NULL); kevent(kq,&ev,1,NULL,0,NULL); }
    }
    int corefd = connection ? simutex_core_simulator_connection_event_fd(connection) : -1;
    if (corefd >= 0) { struct kevent ev; EV_SET(&ev,corefd,EVFILT_READ,EV_ADD|EV_CLEAR,0,0,NULL); kevent(kq,&ev,1,NULL,0,NULL); }
    NSData *last = nil;
    @try { while (true) { @autoreleasepool {
        NSArray *devices = snapshot(connection); NSData *data = jsonData(@{@"version":@1, @"devices":devices});
        if (![data isEqual:last]) { fwrite(data.bytes,1,data.length,stdout); puts(""); if (fflush(stdout)) break; last = data; }
        struct kevent events[8]; struct timespec timeout = {.tv_sec = corefd >= 0 ? 30 : 1};
        int n = kevent(kq,NULL,0,events,8,&timeout);
        if (n < 0 && errno != EINTR) fail(@"Watch failed");
        if (corefd >= 0) simutex_core_simulator_connection_drain_events(connection);
    } } } @finally { for (NSNumber *fd in fds) close(fd.intValue); close(kq); }
}

int simutex_cli_run(int argc, const char * const *argv) {
    @autoreleasepool {
        SimutexCoreSimulatorConnection *connection = NULL;
        @try {
            NSMutableArray<NSString *> *pos = [NSMutableArray array]; NSMutableDictionary *opt = [NSMutableDictionary dictionary];
            NSSet *values = [NSSet setWithArray:@[@"--owner",@"--expected-owner",@"--hooks",@"--pre-claim",@"--post-claim",@"--event",@"--config"]];
            NSSet *flags = [NSSet setWithArray:@[@"--json",@"--no-pre-claim",@"--no-post-claim"]];
            BOOL positionalOnly=NO;
            for (int i=0;i<argc;i++) {
                NSString *s = @(argv[i]);
                if (!positionalOnly && [s isEqual:@"--"]) { positionalOnly=YES; continue; }
                if (positionalOnly) { [pos addObject:s]; continue; }
                if ([values containsObject:s]) { if (opt[s] || i+1>=argc) fail(@"Invalid arguments"); opt[s] = @(argv[++i]); }
                else if ([flags containsObject:s]) { if (opt[s]) fail(@"Duplicate option"); opt[s] = @YES; }
                else if ([s hasPrefix:@"--"]) fail([@"Unknown option: " stringByAppendingString:s]);
                else [pos addObject:s];
            }
            for (NSString *e in @[@"pre-claim",@"post-claim"]) if (opt[[@"--" stringByAppendingString:e]] && opt[[@"--no-" stringByAppendingString:e]]) fail(@"Conflicting hook overrides");
            NSString *command = pos.firstObject;
            if (!command) fail(@"Missing command");
            NSMutableSet *allowed = [NSMutableSet set];
            if ([@[@"list",@"available",@"status",@"watch"] containsObject:command]) [allowed addObject:@"--json"];
            if ([@[@"claim",@"takeover"] containsObject:command]) [allowed addObjectsFromArray:@[@"--owner",@"--hooks",@"--pre-claim",@"--post-claim",@"--no-pre-claim",@"--no-post-claim"]];
            if ([command isEqual:@"takeover"]) [allowed addObject:@"--expected-owner"];
            if ([command isEqual:@"release"]) [allowed addObject:@"--owner"];
            if ([command isEqual:@"hooks"]) {
                if (pos.count > 1 && [pos[1] isEqual:@"show"]) [allowed addObjectsFromArray:@[@"--json",@"--hooks"]];
                else { [allowed addObject:@"--event"]; if(pos.count > 1 && [pos[1] isEqual:@"set"]) [allowed addObject:@"--config"]; }
            }
            for (NSString *key in opt) if (![allowed containsObject:key]) fail([NSString stringWithFormat:@"%@ is not valid for %@",key,command]);
            if ([command isEqual:@"describe"]) {
                if (pos.count != 3 || opt.count) fail(@"Usage: simutex describe UDID DESCRIPTION");
                mutateMetadata(pos[1], ^(NSMutableDictionary *d) { d[@"description"] = pos[2]; }); return 0;
            }
            if ([command isEqual:@"hooks"]) {
                if (pos.count != 3) fail(@"Usage: simutex hooks show|set|disable|inherit UDID [--event pre-claim|post-claim] [--config FILE]");
                validUDID(pos[2]); NSString *action = pos[1];
                if ([action isEqual:@"show"]) { printJSON(@{@"udid":pos[2], @"overrides":deviceMetadata(metadata(),pos[2])[@"hooks"] ?: @{}, @"effective":effectiveHooks(pos[2],opt)}); return 0; }
                NSString *event = [opt[@"--event"] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
                if (![@[@"pre_claim",@"post_claim"] containsObject:event]) fail(@"Expected --event pre-claim or post-claim");
                id value = nil;
                if ([action isEqual:@"set"]) {
                    if (!opt[@"--config"]) fail(@"hooks set requires --config FILE");
                    NSString *file = absolute(opt[@"--config"],NSFileManager.defaultManager.currentDirectoryPath);
                    value = normalizeHook(readJSON(file,NO),file.stringByDeletingLastPathComponent);
                } else if ([action isEqual:@"disable"]) value = NSNull.null;
                else if (![action isEqual:@"inherit"]) fail(@"Unknown hooks action");
                mutateMetadata(pos[2], ^(NSMutableDictionary *d) { NSMutableDictionary *h = [d[@"hooks"] mutableCopy] ?: [NSMutableDictionary dictionary]; if (value) h[event]=value; else [h removeObjectForKey:event]; d[@"hooks"]=h; }); return 0;
            }
            mkdirs(statePath());
            if ([command isEqual:@"release"] || [command isEqual:@"reset"]) {
                BOOL reset = [command isEqual:@"reset"];
                NSString *owner = opt[@"--owner"] ?: NSProcessInfo.processInfo.environment[@"SIMUTEX_AGENT"];
                if (pos.count != (reset ? 1 : 2) || (!reset && !owner.length)) fail(@"release requires UDID and --owner or SIMUTEX_AGENT");
                int fd = guard(statePath()); NSUInteger count=0;
                @try {
                    NSArray *udids = reset ? [NSFileManager.defaultManager contentsOfDirectoryAtPath:statePath() error:nil] : @[ [pos[1] stringByAppendingString:@".lock"] ];
                    for (NSString *name in udids) {
                        if (![name hasSuffix:@".lock"]) continue;
                        NSString *udid = [name substringToIndex:name.length-5]; NSString *current = ownerOf(udid);
                        if (current && !reset && ![current isEqual:owner]) fail([@"Simulator owned by " stringByAppendingString:current]);
                        if (current) { if (unlink(lockPath(udid).fileSystemRepresentation)) fail(@"Cannot release lock"); count++; }
                    }
                } @finally { close(fd); }
                if (reset) printf("reset\t%lu\n",(unsigned long)count); else puts(count ? "released" : "not locked"); return 0;
            }
            if (![@[@"list",@"available",@"status",@"claim",@"takeover",@"watch"] containsObject:command]) fail(@"Unknown command (run simutex help)");
            if ([command isEqual:@"watch"]) { char *err=NULL; connection=simutex_core_simulator_connection_create(&err); if(err)simutex_core_simulator_string_free(err); if (pos.count != 1 || !opt[@"--json"]) fail(@"Usage: simutex watch --json"); watchDevices(connection); return 0; }
            if ([command isEqual:@"status"]) {
                if (pos.count != 2) fail(@"status requires UDID"); validUDID(pos[1]);
                NSDictionary *dm = deviceMetadata(metadata(),pos[1]);
                NSDictionary *d = @{@"udid":pos[1],@"owner":ownerOf(pos[1]) ?: (id)NSNull.null,@"description":dm[@"description"] ?: @"",@"hooks":dm[@"hooks"] ?: @{}};
                if (opt[@"--json"]) printJSON(d); else printf("%s\t%s\n", d[@"owner"] == NSNull.null ? "available" : [plain(d[@"owner"]) UTF8String], [plain(d[@"description"]) UTF8String]); return 0;
            }
            char *err = NULL; connection = simutex_core_simulator_connection_create(&err); if (err) simutex_core_simulator_string_free(err);
            NSArray *devices = snapshot(connection);
            if ([command isEqual:@"list"] || [command isEqual:@"available"]) { if (pos.count != 1) fail(@"list takes no UDID"); if (opt[@"--json"]) printJSON(@{@"version":@1,@"devices":devices}); else printRows(devices); return 0; }
            BOOL takeover = [command isEqual:@"takeover"];
            if (pos.count > 2 || (takeover && (pos.count != 2 || !opt[@"--expected-owner"]))) fail(@"takeover requires UDID and --expected-owner");
            NSString *owner = opt[@"--owner"] ?: NSProcessInfo.processInfo.environment[@"SIMUTEX_AGENT"];
            if (!owner.length) fail(@"Owner required; use --owner or SIMUTEX_AGENT");
            for (NSDictionary *d in devices) {
                NSString *udid=d[@"udid"]; if (pos.count == 2 && ![pos[1] isEqual:udid]) continue;
                if (acquire(udid,owner,takeover ? opt[@"--expected-owner"] : nil,opt)) { puts(udid.UTF8String); return 0; }
                if (pos.count == 2) fail([NSString stringWithFormat:@"Simulator %@ is locked by %@",udid,ownerOf(udid)]);
            }
            fail(pos.count == 2 ? @"Simulator was not found or is unavailable" : @"No unlocked iOS simulator is available");
        } @catch (NSException *e) { fprintf(stderr,"simutex: %s\n",e.reason.UTF8String); return 1; }
        @finally { if (connection) simutex_core_simulator_connection_destroy(connection); }
    }
    return 0;
}

int simutex_metadata_directory_fd(void) { @autoreleasepool { @try { NSString *p = metadataPath().stringByDeletingLastPathComponent; mkdirs(p); return open(p.fileSystemRepresentation, O_EVTONLY|O_CLOEXEC); } @catch (NSException *e) { return -1; } } }
