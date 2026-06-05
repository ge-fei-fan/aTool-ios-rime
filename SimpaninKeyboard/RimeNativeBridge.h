#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const RimeNativeBridgeErrorDomain;

@interface RimeNativeCandidate : NSObject

@property (nonatomic, copy, readonly) NSString *text;
@property (nonatomic, copy, nullable, readonly) NSString *comment;
@property (nonatomic, assign, readonly) NSInteger index;
@property (nonatomic, assign, readonly) NSInteger consumeLength;

- (instancetype)initWithText:(NSString *)text
                     comment:(nullable NSString *)comment
                       index:(NSInteger)index
               consumeLength:(NSInteger)consumeLength NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface RimeNativeContext : NSObject

@property (nonatomic, copy, readonly) NSString *input;
@property (nonatomic, copy, readonly) NSString *preedit;
@property (nonatomic, assign, readonly) NSInteger caretPosition;
@property (nonatomic, copy, readonly) NSArray<RimeNativeCandidate *> *candidates;

- (instancetype)initWithInput:(NSString *)input
                      preedit:(NSString *)preedit
                caretPosition:(NSInteger)caretPosition
                   candidates:(NSArray<RimeNativeCandidate *> *)candidates NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface RimeNativeBridge : NSObject

@property (class, nonatomic, readonly) BOOL nativeAvailable;
@property (nonatomic, readonly) BOOL initialized;

- (BOOL)initializeWithSharedDataDirectory:(NSString *)sharedDataDirectory
                        userDataDirectory:(NSString *)userDataDirectory
                           deployIfNeeded:(BOOL)deployIfNeeded
                                    error:(NSError **)error;
- (void)reset;
- (BOOL)processKeyCode:(NSInteger)keyCode mask:(NSInteger)mask;
- (void)clearComposition;
- (void)setCaretPosition:(NSInteger)caretPosition;
- (nullable NSString *)consumeCommitText;
- (nullable RimeNativeContext *)currentContext;
- (BOOL)selectCandidateAtIndex:(NSUInteger)index;
- (nullable NSString *)commitComposition;
- (BOOL)selectSchema:(NSString *)schemaID;
- (void)setOption:(NSString *)option enabled:(BOOL)enabled;
- (BOOL)getOption:(NSString *)option;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
