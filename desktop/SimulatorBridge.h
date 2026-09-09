#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
@interface SXSimulatorSession : NSObject
- (nullable instancetype)initWithUDID:(NSString *)udid developerDirectory:(NSString *)directory error:(NSError **)error;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) NSInteger orientation;
@property(nonatomic, readonly, nullable) NSString *inputError;
- (nullable IOSurfaceRef)copySurface CF_RETURNS_RETAINED;
- (void)setOwnershipLockPath:(NSString *)path owner:(NSString *)owner;
- (BOOL)enableInput:(NSError **)error;
- (void)disableInput;
- (void)touchX:(double)x y:(double)y phase:(NSInteger)phase;
- (void)keyUsage:(unsigned int)usage down:(BOOL)down;
- (void)home;
- (BOOL)rotate:(NSInteger)orientation error:(NSError **)error;
- (void)close;
@end
NS_ASSUME_NONNULL_END
