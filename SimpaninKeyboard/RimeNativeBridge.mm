#import "RimeNativeBridge.h"

#import <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#import "rime_api.h"
#pragma clang diagnostic pop
#include <string>
#endif

NSErrorDomain const RimeNativeBridgeErrorDomain = @"com.local.simpanin.rime.native";
static const char *SimpaninRimeSchemaID = "wanxiang";

static NSError *RimeNativeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:RimeNativeBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation RimeNativeCandidate

- (instancetype)initWithText:(NSString *)text
                     comment:(NSString *)comment
                       index:(NSInteger)index
               consumeLength:(NSInteger)consumeLength {
    self = [super init];
    if (self) {
        _text = [text copy];
        _comment = [comment copy];
        _index = index;
        _consumeLength = consumeLength;
    }
    return self;
}

@end

@implementation RimeNativeContext

- (instancetype)initWithInput:(NSString *)input
                      preedit:(NSString *)preedit
                caretPosition:(NSInteger)caretPosition
                   candidates:(NSArray<RimeNativeCandidate *> *)candidates {
    self = [super init];
    if (self) {
        _input = [input copy];
        _preedit = [preedit copy];
        _caretPosition = caretPosition;
        _candidates = [candidates copy];
    }
    return self;
}

@end

@interface RimeNativeBridge ()
#if !TARGET_OS_SIMULATOR
{
    RimeApi *_api;
    RimeSessionId _sessionID;
}
#endif
@property (nonatomic, readwrite) BOOL initialized;
@end

@implementation RimeNativeBridge

+ (BOOL)nativeAvailable {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    return YES;
#endif
}

- (void)dealloc {
#if !TARGET_OS_SIMULATOR
    [self shutdown];
#endif
}

- (BOOL)initializeWithSharedDataDirectory:(NSString *)sharedDataDirectory
                        userDataDirectory:(NSString *)userDataDirectory
                           deployIfNeeded:(BOOL)deployIfNeeded
                                    error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    if (error) {
        *error = RimeNativeError(1, @"librime is only linked for iPhoneOS in this project.");
    }
    return NO;
#else
    if (self.initialized && _sessionID) {
        return YES;
    }

    _api = rime_get_api();
    if (!_api || !_api->setup || !_api->initialize || !_api->create_session) {
        if (error) {
            *error = RimeNativeError(2, @"librime API is incomplete.");
        }
        return NO;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:sharedDataDirectory]) {
        if (error) {
            *error = RimeNativeError(3, [NSString stringWithFormat:@"Missing Rime shared data directory: %@", sharedDataDirectory]);
        }
        return NO;
    }
    if (![fileManager fileExistsAtPath:userDataDirectory]) {
        if (error) {
            *error = RimeNativeError(4, [NSString stringWithFormat:@"Missing Rime user data directory: %@", userDataDirectory]);
        }
        return NO;
    }

    NSString *logDirectory = [userDataDirectory stringByAppendingPathComponent:@"logs"];
    [fileManager createDirectoryAtPath:logDirectory withIntermediateDirectories:YES attributes:nil error:nil];

    std::string sharedDataPath([sharedDataDirectory fileSystemRepresentation]);
    std::string userDataPath([userDataDirectory fileSystemRepresentation]);
    std::string logPath([logDirectory fileSystemRepresentation]);
    std::string prebuiltDataPath([[sharedDataDirectory stringByAppendingPathComponent:@"build"] fileSystemRepresentation]);
    std::string stagingDataPath([[userDataDirectory stringByAppendingPathComponent:@"build"] fileSystemRepresentation]);

    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = sharedDataPath.c_str();
    traits.user_data_dir = userDataPath.c_str();
    traits.distribution_name = "Simpanin";
    traits.distribution_code_name = "simpanin";
    traits.distribution_version = "1.0";
    traits.app_name = "rime.simpanin";
    traits.min_log_level = 2;
    traits.log_dir = logPath.c_str();
    traits.prebuilt_data_dir = prebuiltDataPath.c_str();
    traits.staging_dir = stagingDataPath.c_str();
    // Keep the keyboard-extension runtime as small as possible. The iOS schema
    // used by this target is intentionally Lua-free; loading librime-lua here
    // adds startup/memory pressure and can make the extension get killed while
    // switching keyboards.
    traits.modules = nullptr;

    _api->setup(&traits);

    if (deployIfNeeded) {
        if (!_api->deployer_initialize || !_api->deploy) {
            if (error) {
                *error = RimeNativeError(5, @"librime deployer API is unavailable.");
            }
            return NO;
        }

        const char *deployerModules[] = {"deployer", nullptr};
        RimeTraits deployerTraits = traits;
        deployerTraits.modules = deployerModules;
        _api->deployer_initialize(&deployerTraits);
        if (!_api->deploy()) {
            if (error) {
                *error = RimeNativeError(6, @"librime deployment failed.");
            }
            return NO;
        }
    }

    _api->initialize(&traits);
    _sessionID = _api->create_session();
    if (!_sessionID) {
        if (error) {
            *error = RimeNativeError(7, @"Failed to create Rime session.");
        }
        return NO;
    }

    if (_api->select_schema && !_api->select_schema(_sessionID, SimpaninRimeSchemaID)) {
        if (error) {
            *error = RimeNativeError(8, @"Failed to select schema: wanxiang.");
        }
        _api->destroy_session(_sessionID);
        _sessionID = 0;
        return NO;
    }

    if (_api->set_option) {
        // iOS 键盘启动后应默认处于中文输入状态。某些 Rime 用户目录会记住
        // ascii_mode=true，导致按拼音时没有中文候选，仅表现为键盘可见但候选栏为空。
        _api->set_option(_sessionID, "ascii_mode", false);
    }

    self.initialized = YES;
    return YES;
#endif
}

- (void)reset {
#if !TARGET_OS_SIMULATOR
    if (_api && _sessionID && _api->clear_composition) {
        _api->clear_composition(_sessionID);
    }
    if (_api && _sessionID && _api->set_option) {
        _api->set_option(_sessionID, "ascii_mode", false);
    }
#endif
}

- (BOOL)processKeyCode:(NSInteger)keyCode mask:(NSInteger)mask {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    if (!_api || !_sessionID || !_api->process_key) {
        return NO;
    }
    return _api->process_key(_sessionID, (int)keyCode, (int)mask) != 0;
#endif
}

- (void)clearComposition {
#if !TARGET_OS_SIMULATOR
    if (_api && _sessionID && _api->clear_composition) {
        _api->clear_composition(_sessionID);
    }
#endif
}

- (void)setCaretPosition:(NSInteger)caretPosition {
#if !TARGET_OS_SIMULATOR
    if (_api && _sessionID && _api->set_caret_pos) {
        _api->set_caret_pos(_sessionID, (size_t)MAX(0, caretPosition));
    }
#endif
}

- (NSString *)consumeCommitText {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    if (!_api || !_sessionID || !_api->get_commit) {
        return nil;
    }

    NSMutableString *result = [NSMutableString string];
    while (true) {
        RIME_STRUCT(RimeCommit, commit);
        if (!_api->get_commit(_sessionID, &commit)) {
            break;
        }
        if (commit.text) {
            [result appendString:[NSString stringWithUTF8String:commit.text] ?: @""];
        }
        if (_api->free_commit) {
            _api->free_commit(&commit);
        }
    }
    return result.length > 0 ? result : nil;
#endif
}

- (RimeNativeContext *)currentContext {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    if (!_api || !_sessionID) {
        return nil;
    }

    NSString *input = @"";
    if (_api->get_input) {
        const char *rawInput = _api->get_input(_sessionID);
        if (rawInput) {
            input = [NSString stringWithUTF8String:rawInput] ?: @"";
        }
    }

    NSInteger caretPosition = 0;
    if (_api->get_caret_pos) {
        caretPosition = (NSInteger)_api->get_caret_pos(_sessionID);
    }

    NSString *preedit = @"";
    NSInteger selectedSegmentEnd = 0;
    if (_api->get_context) {
        RIME_STRUCT(RimeContext, context);
        if (_api->get_context(_sessionID, &context)) {
            if (context.composition.preedit) {
                preedit = [NSString stringWithUTF8String:context.composition.preedit] ?: @"";
            }
            caretPosition = context.composition.cursor_pos;
            selectedSegmentEnd = context.composition.sel_end;
            if (_api->free_context) {
                _api->free_context(&context);
            }
        }
    }

    NSInteger candidateConsumeLength = input.length;
    if (selectedSegmentEnd > 0) {
        candidateConsumeLength = MIN((NSInteger)input.length, selectedSegmentEnd);
    }
    candidateConsumeLength = MAX(1, candidateConsumeLength);

    NSMutableArray<RimeNativeCandidate *> *candidates = [NSMutableArray array];
    if (_api->candidate_list_begin && _api->candidate_list_next && _api->candidate_list_end) {
        RimeCandidateListIterator iterator = {0};
        if (_api->candidate_list_begin(_sessionID, &iterator)) {
            while (_api->candidate_list_next(&iterator)) {
                NSString *text = iterator.candidate.text ? ([NSString stringWithUTF8String:iterator.candidate.text] ?: @"") : @"";
                NSString *comment = iterator.candidate.comment ? [NSString stringWithUTF8String:iterator.candidate.comment] : nil;
                RimeNativeCandidate *candidate = [[RimeNativeCandidate alloc] initWithText:text
                                                                                  comment:comment
                                                                                    index:iterator.index
                                                                            consumeLength:candidateConsumeLength];
                [candidates addObject:candidate];
                if (candidates.count >= 50) {
                    break;
                }
            }
            _api->candidate_list_end(&iterator);
        }
    }

    return [[RimeNativeContext alloc] initWithInput:input
                                           preedit:preedit.length > 0 ? preedit : input
                                     caretPosition:caretPosition
                                        candidates:candidates];
#endif
}

- (BOOL)selectCandidateAtIndex:(NSUInteger)index {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    if (!_api || !_sessionID || !_api->select_candidate) {
        return NO;
    }
    return _api->select_candidate(_sessionID, index) != 0;
#endif
}

- (NSString *)commitComposition {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    if (!_api || !_sessionID || !_api->commit_composition) {
        return nil;
    }
    if (!_api->commit_composition(_sessionID)) {
        return nil;
    }
    return [self consumeCommitText];
#endif
}

- (BOOL)selectSchema:(NSString *)schemaID {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    if (!_api || !_sessionID || !_api->select_schema) {
        return NO;
    }
    return _api->select_schema(_sessionID, schemaID.UTF8String) != 0;
#endif
}

- (void)setOption:(NSString *)option enabled:(BOOL)enabled {
#if !TARGET_OS_SIMULATOR
    if (!_api || !_sessionID || !_api->set_option) {
        return;
    }
    _api->set_option(_sessionID, option.UTF8String, enabled ? true : false);
#endif
}

- (BOOL)getOption:(NSString *)option {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    if (!_api || !_sessionID || !_api->get_option) {
        return NO;
    }
    return _api->get_option(_sessionID, option.UTF8String) != 0;
#endif
}

- (void)shutdown {
#if !TARGET_OS_SIMULATOR
    if (_api) {
        if (_sessionID && _api->destroy_session) {
            _api->destroy_session(_sessionID);
            _sessionID = 0;
        }
        // Keyboard extensions are created and torn down frequently while users
        // switch keyboards. Finalizing librime's process-wide runtime here can
        // race with subsequent extension activation and has been observed to
        // make keyboard switching unstable. Keep shutdown scoped to this bridge
        // instance/session; the OS will reclaim the process-wide runtime when
        // the extension process exits.
    }
    self.initialized = NO;
    _api = nullptr;
#endif
}

@end
