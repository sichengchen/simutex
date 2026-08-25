#import "core_simulator_bridge.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

@interface NSObject (SimutexCoreSimulatorPrivate)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)developerDirectory
                                    error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)availableDevices;
- (NSString *)runtimeIdentifier;
- (NSString *)name;
- (NSUUID *)UDID;
- (NSString *)stateString;
- (uint64_t)registerNotificationHandlerOnQueue:(dispatch_queue_t)queue
                                       handler:(void (^)(NSDictionary *notification))handler;
- (BOOL)unregisterNotificationHandler:(uint64_t)registrationID
                                 error:(NSError **)error;
@end

@interface SimutexCoreSimulatorClient : NSObject
@property(nonatomic, strong) id serviceContext;
@property(nonatomic, strong) id deviceSet;
@property(nonatomic) dispatch_queue_t notificationQueue;
@property(nonatomic) uint64_t notificationRegistrationID;
@property(nonatomic) BOOL notificationRegistered;
@property(nonatomic) int eventReadFD;
@property(nonatomic) int eventWriteFD;
@end

static char *copyString(NSString *string) {
    const char *utf8 = string.UTF8String;
    return strdup(utf8 != NULL ? utf8 : "Unknown CoreSimulator error");
}

static void setErrorMessage(char **errorMessage, NSString *message) {
    if (errorMessage != NULL) {
        *errorMessage = copyString(message);
    }
}

static void *coreSimulatorFrameworkHandle(void) {
    static void *handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
        handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    });
    return handle;
}

static NSString *developerDirectory(NSError **error) {
    NSString *override = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (override.length > 0) {
        return override;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    task.arguments = @[@"--print-path"];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:error]) {
        return nil;
    }

    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"simutex.CoreSimulator"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"xcode-select could not locate the developer directory"
                                     }];
        }
        return nil;
    }

    NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    path = [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (path.length == 0 && error != NULL) {
        *error = [NSError errorWithDomain:@"simutex.CoreSimulator"
                                     code:2
                                 userInfo:@{
                                     NSLocalizedDescriptionKey:
                                         @"xcode-select returned an empty developer directory"
                                 }];
    }
    return path.length > 0 ? path : nil;
}

static BOOL configurePipe(int descriptors[2], NSError **error) {
    if (pipe(descriptors) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:nil];
        }
        return NO;
    }

    for (int index = 0; index < 2; index++) {
        int statusFlags = fcntl(descriptors[index], F_GETFL);
        int descriptorFlags = fcntl(descriptors[index], F_GETFD);
        if (statusFlags < 0 || descriptorFlags < 0 ||
            fcntl(descriptors[index], F_SETFL, statusFlags | O_NONBLOCK) < 0 ||
            fcntl(descriptors[index], F_SETFD, descriptorFlags | FD_CLOEXEC) < 0) {
            int savedErrno = errno;
            close(descriptors[0]);
            close(descriptors[1]);
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:savedErrno
                                         userInfo:nil];
            }
            return NO;
        }
    }
    return YES;
}

@implementation SimutexCoreSimulatorClient

- (instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _eventReadFD = -1;
    _eventWriteFD = -1;

    if (coreSimulatorFrameworkHandle() == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"simutex.CoreSimulator"
                                         code:3
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"CoreSimulator.framework could not be loaded"
                                     }];
        }
        return nil;
    }

    NSString *developerPath = developerDirectory(error);
    if (developerPath == nil) {
        return nil;
    }

    Class serviceContextClass = NSClassFromString(@"SimServiceContext");
    if (serviceContextClass == Nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"simutex.CoreSimulator"
                                         code:4
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             @"CoreSimulator does not expose SimServiceContext"
                                     }];
        }
        return nil;
    }

    _serviceContext = [serviceContextClass sharedServiceContextForDeveloperDir:developerPath
                                                                         error:error];
    if (_serviceContext == nil) {
        return nil;
    }

    _deviceSet = [_serviceContext defaultDeviceSetWithError:error];
    if (_deviceSet == nil) {
        return nil;
    }

    int descriptors[2];
    if (!configurePipe(descriptors, error)) {
        return nil;
    }
    _eventReadFD = descriptors[0];
    _eventWriteFD = descriptors[1];

    _notificationQueue = dispatch_queue_create(
        "com.sichengchen.simutex.CoreSimulator.notifications",
        DISPATCH_QUEUE_SERIAL
    );
    int eventWriteFD = _eventWriteFD;
    _notificationRegistrationID = [_deviceSet
        registerNotificationHandlerOnQueue:_notificationQueue
                                   handler:^(__unused NSDictionary *notification) {
        uint8_t byte = 1;
        ssize_t result;
        do {
            result = write(eventWriteFD, &byte, sizeof(byte));
        } while (result < 0 && errno == EINTR);
    }];
    _notificationRegistered = YES;

    return self;
}

- (void)dealloc {
    if (_deviceSet != nil && _notificationRegistered) {
        [_deviceSet unregisterNotificationHandler:_notificationRegistrationID error:nil];
    }
    if (_notificationQueue != nil) {
        dispatch_sync(_notificationQueue, ^{});
    }
    if (_eventReadFD >= 0) {
        close(_eventReadFD);
    }
    if (_eventWriteFD >= 0) {
        close(_eventWriteFD);
    }
}

- (char *)copyInventoryJSONWithError:(NSError **)error {
    NSMutableDictionary<NSString *, NSMutableArray *> *devicesByRuntime =
        [NSMutableDictionary dictionary];

    for (id device in [_deviceSet availableDevices]) {
        NSString *runtimeIdentifier = [device runtimeIdentifier];
        if ([runtimeIdentifier rangeOfString:@".iOS-"].location == NSNotFound) {
            continue;
        }

        NSString *name = [device name];
        NSString *udid = [[device UDID] UUIDString];
        NSString *state = [device stateString];
        if (name == nil || udid == nil || state == nil) {
            continue;
        }

        NSMutableArray *devices = devicesByRuntime[runtimeIdentifier];
        if (devices == nil) {
            devices = [NSMutableArray array];
            devicesByRuntime[runtimeIdentifier] = devices;
        }
        [devices addObject:@{
            @"name": name,
            @"udid": udid,
            @"state": state,
            @"isAvailable": @YES,
        }];
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"devices": devicesByRuntime}
                                                   options:NSJSONWritingSortedKeys
                                                     error:error];
    if (data == nil) {
        return NULL;
    }

    char *json = malloc(data.length + 1);
    if (json == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
        }
        return NULL;
    }
    memcpy(json, data.bytes, data.length);
    json[data.length] = '\0';
    return json;
}

@end

SimutexCoreSimulatorConnection *simutex_core_simulator_connection_create(
    char **errorMessage
) {
    @autoreleasepool {
        if (errorMessage != NULL) {
            *errorMessage = NULL;
        }
        @try {
            NSError *error = nil;
            SimutexCoreSimulatorClient *client =
                [[SimutexCoreSimulatorClient alloc] initWithError:&error];
            if (client == nil) {
                setErrorMessage(errorMessage, error.localizedDescription);
                return NULL;
            }
            return (__bridge_retained SimutexCoreSimulatorConnection *)client;
        } @catch (NSException *exception) {
            setErrorMessage(errorMessage, exception.reason);
            return NULL;
        }
    }
}

void simutex_core_simulator_connection_destroy(
    SimutexCoreSimulatorConnection *connection
) {
    if (connection == NULL) {
        return;
    }
    @autoreleasepool {
        SimutexCoreSimulatorClient *client =
            (__bridge_transfer SimutexCoreSimulatorClient *)connection;
        client = nil;
    }
}

int simutex_core_simulator_connection_event_fd(
    SimutexCoreSimulatorConnection *connection
) {
    SimutexCoreSimulatorClient *client =
        (__bridge SimutexCoreSimulatorClient *)connection;
    return client.eventReadFD;
}

void simutex_core_simulator_connection_drain_events(
    SimutexCoreSimulatorConnection *connection
) {
    SimutexCoreSimulatorClient *client =
        (__bridge SimutexCoreSimulatorClient *)connection;
    uint8_t buffer[256];
    while (true) {
        ssize_t result = read(client.eventReadFD, buffer, sizeof(buffer));
        if (result > 0) {
            continue;
        }
        if (result < 0 && errno == EINTR) {
            continue;
        }
        return;
    }
}

char *simutex_core_simulator_connection_copy_inventory_json(
    SimutexCoreSimulatorConnection *connection,
    char **errorMessage
) {
    @autoreleasepool {
        if (errorMessage != NULL) {
            *errorMessage = NULL;
        }
        @try {
            SimutexCoreSimulatorClient *client =
                (__bridge SimutexCoreSimulatorClient *)connection;
            NSError *error = nil;
            char *json = [client copyInventoryJSONWithError:&error];
            if (json == NULL) {
                setErrorMessage(errorMessage, error.localizedDescription);
            }
            return json;
        } @catch (NSException *exception) {
            setErrorMessage(errorMessage, exception.reason);
            return NULL;
        }
    }
}

void simutex_core_simulator_string_free(char *string) {
    free(string);
}
