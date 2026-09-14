#import "SimulatorBridge.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <unistd.h>
#import <mach/mach.h>
#import <xpc/xpc.h>
#import <objc/message.h>

// Private ABI declarations verified against Xcode 27. See desktop/COMPATIBILITY.md.
@interface NSObject (SXPrivate)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)directory error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)availableDevices;
- (NSUUID *)UDID;
- (id)io;
- (NSArray *)ioPorts;
- (id)descriptor;
- (id)framebufferSurface;
- (id)ioSurface;
- (CGSize)displaySize;
- (id)screenProperties;
- (NSInteger)uiOrientation;
- (void)registerCallbackWithUUID:(NSUUID *)uuid damageRectanglesCallback:(void (^)(id))block;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfaceChangeCallback:(void (^)(id))block;
- (void)registerCallbackWithUUID:(NSUUID *)uuid ioSurfacesChangeCallback:(void (^)(id))block;
- (void)unregisterDamageRectanglesCallbackWithUUID:(NSUUID *)uuid;
- (void)unregisterIOSurfaceChangeCallbackWithUUID:(NSUUID *)uuid;
- (void)unregisterIOSurfacesChangeCallbackWithUUID:(NSUUID *)uuid;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid callbackQueue:(dispatch_queue_t)queue frameCallback:(void (^)(void))frame surfacesChangedCallback:(void (^)(id,id))surfaces propertiesChangedCallback:(void (^)(id))properties;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
- (id)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message freeWhenDone:(BOOL)freeWhenDone completionQueue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
@end

// Simulator.app builds hardware buttons as IndigoHIDMessageForButton(keyCode,
// 1 for press / 2 for release, target). Its -homeButtonPressed: sends keycode 0
// on anything that is not an Apple TV, and takes the target from
// SimDeviceScreen.buttonTarget, which is 0x33 for a device with an internal
// display: every iPhone and iPad simulator, the only runtimes this app lists.
// The Apple TV remote pair (0x190, 0x15) does not press Home on an iOS runtime;
// it restarts SpringBoard, which also tears the device's Indigo HID session
// down, so every later event fails with "Mach port invalid, device
// disconnected" until the transport is rebuilt.
static const int kIndigoHomeKeyCode = 0x0;
static const int kIndigoHomeTarget = 0x33;

static NSError *sxError(NSString *message) { return [NSError errorWithDomain:@"simutex.simulator" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static BOOL loadFrameworks(NSString *directory, NSError **error) {
    if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW|RTLD_GLOBAL)) { if(error)*error=sxError(@"CoreSimulator is unavailable. Select a full Xcode installation in Settings."); return NO; }
    NSString *contents = directory.stringByDeletingLastPathComponent;
    NSArray *paths = @[[contents stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"], [directory stringByAppendingPathComponent:@"Applications/Simulator.app/Contents/Frameworks/SimulatorKit.framework/SimulatorKit"], [directory stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"]];
    for (NSString *path in paths) if (dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) return YES;
    if(error)*error=sxError(@"SimulatorKit is unavailable in this Xcode. Choose a supported Xcode installation."); return NO;
}

@implementation SXSimulatorSession {
    id _device, _display, _legacy;
    NSUUID *_uuid;
    IOSurfaceRef _surface;
    uint64_t _generation;
    NSInteger _orientation;
    xpc_connection_t _connection;
    NSString *_inputError;
    NSString *_lockPath, *_owner;
    BOOL _closed, _touching, _modern;
    CGPoint _point;
    double _touchStart;
    uint64_t _touchSerial;
    BOOL _pendingEnd;
    NSMutableSet<NSNumber *> *_pressedKeys;
}
- (instancetype)initWithUDID:(NSString *)udid developerDirectory:(NSString *)directory error:(NSError **)error {
    if (!(self=[super init])) return nil;
    @try {
        if (!loadFrameworks(directory,error)) return nil;
        id context = [NSClassFromString(@"SimServiceContext") sharedServiceContextForDeveloperDir:directory error:error];
        id set = [context defaultDeviceSetWithError:error];
        for (id device in [set availableDevices]) if ([[device UDID].UUIDString isEqual:udid]) { _device=device; break; }
        if (!_device) { if(error && !*error)*error=sxError(@"Simulator is unavailable"); return nil; }
        for (id port in [[_device io] ioPorts]) {
            id descriptor = [port descriptor];
            Protocol *protocol = NSProtocolFromString(@"SimDisplayIOSurfaceRenderable");
            if (protocol && [descriptor conformsToProtocol:protocol]) {
                CGSize size = [descriptor displaySize];
                if (size.width > 0 && size.height > 0) { _display=descriptor; break; }
            }
        }
        if (!_display) { if(error)*error=sxError(@"Display is not ready. Wait for the simulator to finish booting, then retry."); return nil; }
        _uuid=NSUUID.UUID; _orientation=1; _pressedKeys=[NSMutableSet set];
        __weak SXSimulatorSession *weakSelf=self;
        if ([_display respondsToSelector:@selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)]) {
            @try {
                [_display registerScreenCallbacksWithUUID:_uuid callbackQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0) frameCallback:^{
                    SXSimulatorSession *s=weakSelf; if(s) @synchronized(s) { if(!s->_closed)s->_generation++; }
                } surfacesChangedCallback:^(id surface,id masked) {
                    (void)masked; SXSimulatorSession *s=weakSelf; if(s) @synchronized(s) {
                        if(s->_closed)return;
                        if(surface && CFGetTypeID((__bridge CFTypeRef)surface)==IOSurfaceGetTypeID()) {
                            IOSurfaceRef next=(__bridge IOSurfaceRef)surface;CFRetain(next);if(s->_surface)CFRelease(s->_surface);s->_surface=next;s->_generation++;
                        }
                    }
                } propertiesChangedCallback:^(id properties) {
                    SXSimulatorSession *s=weakSelf; if(s) @synchronized(s) { if(!s->_closed && properties) { s->_orientation=[properties uiOrientation];s->_generation++; } }
                }];
                _modern=YES;
            } @catch(NSException *e) {}
        }
        if(!_modern) {
            [_display registerCallbackWithUUID:_uuid damageRectanglesCallback:^(id damage) { (void)damage; SXSimulatorSession *s=weakSelf; if(s) @synchronized(s) { if(!s->_closed)s->_generation++; } }];
            @try { [_display registerCallbackWithUUID:_uuid ioSurfaceChangeCallback:^(id surface) { (void)surface; [weakSelf updateSurface]; }]; } @catch(NSException *e) {}
            @try { [_display registerCallbackWithUUID:_uuid ioSurfacesChangeCallback:^(id surface) { (void)surface; [weakSelf updateSurface]; }]; } @catch(NSException *e) {}
        }
        [self updateSurface];
    } @catch(NSException *e) { if(error)*error=sxError(e.reason); [self close]; return nil; }
    return self;
}
- (void)updateSurface {
    @synchronized(self) {
        if (_closed) return;
        @try {
            id value=[_display framebufferSurface] ?: [_display ioSurface];
            if (value && CFGetTypeID((__bridge CFTypeRef)value)==IOSurfaceGetTypeID()) {
                IOSurfaceRef next=(__bridge IOSurfaceRef)value; CFRetain(next);
                if(_surface)CFRelease(_surface); _surface=next; _generation++;
            }
            if ([_display respondsToSelector:@selector(screenProperties)]) {
                id p=[_display screenProperties]; if(p) _orientation=[p uiOrientation];
            }
        } @catch(NSException *e) { _inputError=e.reason; }
    }
}
- (uint64_t)generation { @synchronized(self) { return _generation; } }
- (NSInteger)orientation { @synchronized(self) { return _orientation; } }
- (NSString *)inputError { @synchronized(self) { return _inputError; } }
- (NSString *)takeInputError { @synchronized(self) { NSString *value=_inputError; _inputError=nil; return value; } }
- (IOSurfaceRef)copySurface { @synchronized(self) { return _surface ? (IOSurfaceRef)CFRetain(_surface) : NULL; } }
- (void)sendDTU:(NSString *)type payload:(xpc_object_t)payload {
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);
    xpc_dictionary_set_string(message,"messageType",type.UTF8String);
    xpc_dictionary_set_bool(message,"isBarrier",false);
    xpc_dictionary_set_string(message,"featureIdentifier","com.apple.coredevice.feature.remote.hid.digitizer");
    xpc_dictionary_set_value(message,"payload",payload);
    if(_connection)xpc_connection_send_message(_connection,message);
}
- (void)setOwnershipLockPath:(NSString *)path owner:(NSString *)owner { @synchronized(self) { _lockPath=[path copy]; _owner=[owner copy]; } }
- (BOOL)ownsLock {
    char bytes[257];
    ssize_t n=_lockPath ? readlink(_lockPath.fileSystemRepresentation,bytes,sizeof(bytes)) : -1;
    NSString *current=n>0 && n<=256 ? [[NSString alloc] initWithBytes:bytes length:(NSUInteger)n encoding:NSUTF8StringEncoding] : nil;
    if(!current || ![current isEqual:_owner]) { _inputError=@"Manual reservation was released or changed."; return NO; }
    return YES;
}
- (BOOL)enableInput:(NSError **)error {
    @synchronized(self) {
        if(_closed) { if(error)*error=sxError(@"Simulator disconnected");return NO; }
        if(![self ownsLock]) { if(error)*error=sxError(_inputError); return NO; }
        if(_connection || _legacy)return YES;
        _inputError=nil;
        @try {
            // Xcode 27's Device Hub can suppress legacy HID. Prefer its DTUHID endpoint.
            xpc_object_t (*endpoint)(mach_port_t,uint64_t,uint64_t)=dlsym(RTLD_DEFAULT,"xpc_endpoint_create_mach_port_4sim");
            xpc_connection_t (*connect)(xpc_object_t)=dlsym(RTLD_DEFAULT,"xpc_connection_create_from_endpoint");
            void (*enable)(xpc_connection_t)=dlsym(RTLD_DEFAULT,"xpc_connection_enable_sim2host_4sim");
            NSError *lookupError=nil;
            mach_port_t port=endpoint && connect && enable ? [_device lookup:@"com.apple.coredevice.feature.remote.hid.digitizer" error:&lookupError] : MACH_PORT_NULL;
            if(port) {
                xpc_object_t ep=endpoint(port,0,0); mach_port_deallocate(mach_task_self(),port);
                if(ep)_connection=connect(ep);
                if(_connection) {
                    enable(_connection);
                    __weak SXSimulatorSession *weakSelf=self;
                    xpc_connection_set_event_handler(_connection,^(xpc_object_t event) {
                        if(xpc_get_type(event)==XPC_TYPE_ERROR) { SXSimulatorSession *s=weakSelf; if(s) @synchronized(s) { s->_inputError=@"Simulator input disconnected. Retry the display connection."; } }
                    });
                    xpc_connection_resume(_connection);
                    xpc_object_t prime=xpc_dictionary_create(NULL,NULL,0); xpc_dictionary_set_uint64(prime,"usageCode",0); xpc_dictionary_set_uint64(prime,"state",2);
                    [self sendDTU:@"IndigoKeyboardButtonEvent" payload:prime];
                    // Happens on the setup queue, never the UI thread.
                    [NSThread sleepForTimeInterval:0.5]; return YES;
                }
            }
            Class cls=NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient") ?: NSClassFromString(@"SimDeviceLegacyHIDClient");
            if(!cls || !dlsym(RTLD_DEFAULT,"IndigoHIDMessageForMouseNSEvent") || !dlsym(RTLD_DEFAULT,"IndigoHIDMessageForKeyboardArbitrary")) { if(error)*error=sxError(@"This Xcode does not provide supported simulator input APIs."); return NO; }
            _legacy=[[cls alloc] initWithDevice:_device error:error]; return _legacy!=nil;
        } @catch(NSException *e) { if(error)*error=sxError(e.reason); return NO; }
    }
}
// A runtime that drops its Indigo HID session fails every later event until the
// transport is rebuilt. Callers retry through this when failures persist.
- (BOOL)recoverInput:(NSError **)error {
    @synchronized(self) {
        if(_closed) { if(error)*error=sxError(@"Simulator disconnected"); return NO; }
        if(!_connection && !_legacy) { if(error)*error=sxError(@"Manual input is not enabled"); return NO; }
        [self disableInput];
        _inputError=nil;
    }
    return [self enableInput:error];
}
- (void)sendLegacy:(void *)message {
    if(!message)return;
    if(!_legacy) { free(message); return; }
    __weak SXSimulatorSession *weakSelf=self;
    [_legacy sendWithMessage:message freeWhenDone:YES completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0) completion:^(NSError *error) { if(error){ SXSimulatorSession *s=weakSelf; if(s) @synchronized(s){ s->_inputError=error.localizedDescription; } } }];
}
- (void)touchX:(double)x y:(double)y phase:(NSInteger)phase {
    @synchronized(self) {
        if(_closed || (!_legacy && !_connection))return;
        if(phase!=2 && ![self ownsLock])return;
        if(phase==0 && _pendingEnd) { _touchStart=0; _pendingEnd=NO; [self touchX:_point.x y:_point.y phase:2]; }
        if(phase==0) { _touchStart=NSProcessInfo.processInfo.systemUptime; _touchSerial++; }
        if(phase==2 && _touching) {
            double remaining=0.04-(NSProcessInfo.processInfo.systemUptime-_touchStart);
            if(remaining>0) {
                _pendingEnd=YES; uint64_t serial=_touchSerial;
                __weak SXSimulatorSession *weakSelf=self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(remaining*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{
                    SXSimulatorSession *s=weakSelf; if(s) @synchronized(s) { if(s->_touchSerial==serial && s->_pendingEnd) { s->_pendingEnd=NO; [s touchX:x y:y phase:2]; } }
                }); return;
            }
        }
        _pendingEnd=NO;
        _point=CGPointMake(fmax(0,fmin(1,x)),fmax(0,fmin(1,y)));
        if(_connection) {
            xpc_object_t p=xpc_dictionary_create(NULL,NULL,0), point=xpc_dictionary_create(NULL,NULL,0);
            xpc_dictionary_set_double(point,"x",_point.x); xpc_dictionary_set_double(point,"y",_point.y);
            xpc_dictionary_set_value(p,"pointOne",point); xpc_dictionary_set_uint64(p,"eventType",phase==2 ? 2 : (_touching ? 1 : 0));
            xpc_dictionary_set_uint64(p,"edge",0); xpc_dictionary_set_uint64(p,"target",0);
            [self sendDTU:@"IndigoDigitizerEvent" payload:p];
        } else {
            void *(*build)(CGPoint *,CGPoint *,uint32_t,NSUInteger,CGSize,uint32_t)=dlsym(RTLD_DEFAULT,"IndigoHIDMessageForMouseNSEvent");
            if(build)[self sendLegacy:build(&_point,NULL,0x32,phase==2 ? 2 : 1,CGSizeMake(1,1),0)];
        }
        _touching=phase!=2;
    }
}
- (void)keyUsage:(unsigned int)usage down:(BOOL)down {
    @synchronized(self) {
        if(_closed)return;
        if(down && ![self ownsLock])return;
        if(down)[_pressedKeys addObject:@(usage)];else [_pressedKeys removeObject:@(usage)];
        if(_connection){xpc_object_t p=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_uint64(p,"usageCode",usage);xpc_dictionary_set_uint64(p,"state",down?1:2);[self sendDTU:@"IndigoKeyboardButtonEvent" payload:p];}
        else {void *(*build)(int,int)=dlsym(RTLD_DEFAULT,"IndigoHIDMessageForKeyboardArbitrary");if(build)[self sendLegacy:build((int)usage,down?1:2)];}
    }
}
- (void)homeState:(int)state {
    @synchronized(self) {
        if(_closed || (state==1 && ![self ownsLock]))return;
        if(_connection){xpc_object_t p=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_uint64(p,"usagePage",0x0c);xpc_dictionary_set_uint64(p,"usageCode",0x40);xpc_dictionary_set_uint64(p,"state",state);[self sendDTU:@"IndigoButtonEvent" payload:p];}
        else {void *(*build)(int,int,int)=dlsym(RTLD_DEFAULT,"IndigoHIDMessageForButton");if(build)[self sendLegacy:build(kIndigoHomeKeyCode,state,kIndigoHomeTarget)];}
    }
}
- (void)home {
    [self homeState:1];
    __weak SXSimulatorSession *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{ [weakSelf homeState:2]; });
}
- (BOOL)rotate:(NSInteger)orientation error:(NSError **)error {
    @synchronized(self) {
        if(_closed || (!_legacy && !_connection)) {if(error)*error=sxError(@"Manual input is not enabled");return NO;}
        if(![self ownsLock]) { if(error)*error=sxError(_inputError);return NO; }
        mach_port_t port=[_device lookup:@"PurpleWorkspacePort" error:error];if(!port)return NO;
        // GSEvent orientation ABI (idb PrivateHeaders/SimulatorApp/GSEvent.h).
        uint32_t message[28]={0};mach_msg_header_t *header=(void *)message;
        header->msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0);header->msgh_size=108;header->msgh_remote_port=port;header->msgh_id=123;
        message[6]=50|0x20000;message[18]=4;message[19]=(uint32_t)orientation;
        kern_return_t result=mach_msg(header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,108,0,MACH_PORT_NULL,100,MACH_PORT_NULL);
        mach_port_deallocate(mach_task_self(),port);
        if(result!=KERN_SUCCESS && error)*error=sxError(@"Could not deliver rotation"); return result==KERN_SUCCESS;
    }
}
- (void)disableInput {
    @synchronized(self) {
        _touchStart=0; _pendingEnd=NO; _touchSerial++;
        if(_touching)[self touchX:_point.x y:_point.y phase:2];
        for(NSNumber *key in [_pressedKeys copy])[self keyUsage:key.unsignedIntValue down:NO];
        if(_connection){ xpc_connection_cancel(_connection);_connection=nil; }_legacy=nil;
    }
}
- (void)close {
    @synchronized(self) {
        if(_closed)return;
        [self disableInput];_closed=YES;
        if(_display && _uuid) @try {
            if(_modern) { @try { [_display unregisterScreenCallbacksWithUUID:_uuid]; } @catch(NSException *e) {} }
            @try { [_display unregisterDamageRectanglesCallbackWithUUID:_uuid]; } @catch(NSException *e) {}
            @try { [_display unregisterIOSurfaceChangeCallbackWithUUID:_uuid]; } @catch(NSException *e) {}
            @try { [_display unregisterIOSurfacesChangeCallbackWithUUID:_uuid]; } @catch(NSException *e) {}
        } @catch(NSException *e) { /* A disconnected simulator may already have removed registrations. */ }
        _display=nil;_device=nil;if(_surface)CFRelease(_surface);_surface=NULL;
    }
}
- (void)dealloc { [self close]; }
@end
