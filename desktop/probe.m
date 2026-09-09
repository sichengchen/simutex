#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import "SimulatorBridge.h"
int main(int argc, const char **argv) { @autoreleasepool {
    if(argc<2){fprintf(stderr,"Usage: probe UDID [--input]\n");return 2;}
    NSError *error=nil;
    SXSimulatorSession *session=[[SXSimulatorSession alloc] initWithUDID:@(argv[1]) developerDirectory:NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"] ?: @"/Applications/Xcode-beta.app/Contents/Developer" error:&error];
    if(!session){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    IOSurfaceRef surface=NULL;
    while(!surface && deadline.timeIntervalSinceNow>0){[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];surface=[session copySurface];}
    if(!surface){fprintf(stderr,"No framebuffer delivered\n");[session close];return 1;}
    printf("surface %zux%zu generation %llu orientation %ld\n",IOSurfaceGetWidth(surface),IOSurfaceGetHeight(surface),session.generation,(long)session.orientation);
    if(argc>2) {
        NSString *state=NSProcessInfo.processInfo.environment[@"SIMUTEX_STATE_DIR"] ?: [(NSProcessInfo.processInfo.environment[@"TMPDIR"] ?: @"/tmp") stringByAppendingPathComponent:@"simutex"];
        NSString *owner=NSProcessInfo.processInfo.environment[@"SIMUTEX_AGENT"];
        if(!owner){fprintf(stderr,"Set SIMUTEX_AGENT to the owner of the reserved simulator before input probing\n");return 2;}
        [session setOwnershipLockPath:[state stringByAppendingPathComponent:[@(argv[1]) stringByAppendingString:@".lock"]] owner:owner];
        if(![session enableInput:&error]){fprintf(stderr,"input: %s\n",error.localizedDescription.UTF8String);CFRelease(surface);[session close];return 1;}
        [session home]; [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        if (!strcmp(argv[2],"--input")) { [session touchX:0.85 y:0.49 phase:0]; [NSThread sleepForTimeInterval:0.08]; [session touchX:0.85 y:0.49 phase:2]; }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        printf("input %s generation %llu\n", session.inputError.UTF8String ?: "connected", session.generation);
    }
    CFRelease(surface); surface=[session copySurface];
    CIImage *image=[CIImage imageWithIOSurface:surface];
    CIContext *context=[CIContext contextWithOptions:nil];
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    [context writePNGRepresentationOfImage:image toURL:[NSURL fileURLWithPath:@"/tmp/simutex-frame.png"] format:kCIFormatRGBA8 colorSpace:space options:@{} error:&error];
    CGColorSpaceRelease(space);CFRelease(surface);[session close];
    return error ? 1 : 0;
} }
