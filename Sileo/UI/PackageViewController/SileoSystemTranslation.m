#import "../../SileoSystemTranslation.h"
#import <TargetConditionals.h>
#import <dlfcn.h>

// Translation.framework integration adapted from Irisin (OwnGoal Studio, MIT).
// See LICENSE-Irisin in the repository root.
// The engine is private, so never link it or assume that an individual selector exists.
@interface NSObject (SileoTranslationEngine)
+ (void)availableLocalePairsForTask:(NSInteger)task completion:(void (^)(NSArray *))completion;
- (instancetype)initWithSourceLocale:(NSLocale *)source targetLocale:(NSLocale *)target;
- (void)translate:(id)request;
@end

static Class translatorClass;
static Class requestClass;

BOOL SileoSystemTranslationAvailable(void) {
#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
    if (@available(iOS 15.0, *)) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            if (!dlopen("/System/Library/Frameworks/Translation.framework/Translation", RTLD_LAZY) &&
                !dlopen("/System/Library/PrivateFrameworks/Translation.framework/Translation", RTLD_LAZY)) {
                return;
            }
            translatorClass = NSClassFromString(@"_LTTranslator");
            requestClass = NSClassFromString(@"_LTTextTranslationRequest");
        });
        return [translatorClass respondsToSelector:@selector(availableLocalePairsForTask:completion:)] &&
            [translatorClass instancesRespondToSelector:@selector(translate:)] &&
            [requestClass instancesRespondToSelector:@selector(initWithSourceLocale:targetLocale:)] &&
            [requestClass instancesRespondToSelector:NSSelectorFromString(@"setText:")] &&
            [requestClass instancesRespondToSelector:NSSelectorFromString(@"setForcedOfflineTranslation:")] &&
            ([requestClass instancesRespondToSelector:NSSelectorFromString(@"setTranslationHandler:")] ||
             [requestClass instancesRespondToSelector:NSSelectorFromString(@"setCompletionHandler:")]);
    }
#endif
    return NO;
}

static id ReadProperty(id object, NSString *key) {
    return [object respondsToSelector:NSSelectorFromString(key)] ? [object valueForKey:key] : nil;
}

// The service may deliver multiple callbacks, or none when it rejects the client.
// Finish on the main queue and break the request/handler lifetime on timeout.
static void (^FinishOnce(void (^completion)(id)))(id) {
    __block void (^pending)(id) = [completion copy];
    void (^finishOnMain)(id) = ^(id value) {
        void (^callback)(id) = pending;
        pending = nil;
        if (callback) callback(value);
    };
    void (^finish)(id) = ^(id value) {
        dispatch_async(dispatch_get_main_queue(), ^{ finishOnMain(value); });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        finishOnMain(nil);
    });
    return finish;
}

void SileoSystemTranslationPairs(void (^completion)(NSArray<NSArray<NSString *> *> *)) {
    if (!SileoSystemTranslationAvailable()) {
        completion(nil);
        return;
    }
    void (^finish)(id) = FinishOnce(^(id value) { completion(value); });
    @try {
        [translatorClass availableLocalePairsForTask:1 completion:^(NSArray *items) {
            @try {
                NSMutableArray *pairs = [NSMutableArray array];
                if ([items isKindOfClass:NSArray.class]) {
                    for (id item in items) {
                        NSLocale *source = ReadProperty(item, @"sourceLocale");
                        NSLocale *target = ReadProperty(item, @"targetLocale");
                        if ([source isKindOfClass:NSLocale.class] && [target isKindOfClass:NSLocale.class]) {
                            [pairs addObject:@[source.localeIdentifier, target.localeIdentifier]];
                        }
                    }
                }
                finish(pairs.count ? pairs : nil);
            } @catch (NSException *exception) {
                finish(nil);
            }
        }];
    } @catch (NSException *exception) {
        finish(nil);
    }
}

static NSString *TranslatedText(id result) {
    id text = ReadProperty(result, @"translatedText");
    if ([text isKindOfClass:NSAttributedString.class]) return [text string];
    if ([text isKindOfClass:NSString.class]) return text;
    id candidates = ReadProperty(result, @"translations");
    if (![candidates isKindOfClass:NSArray.class]) return nil;
    text = ReadProperty([candidates firstObject], @"formattedString");
    return [text isKindOfClass:NSString.class] ? text : nil;
}

void SileoSystemTranslate(NSString *text, NSString *source, NSString *target, BOOL offline,
                          void (^completion)(NSString *)) {
    if (!SileoSystemTranslationAvailable()) {
        completion(nil);
        return;
    }
    __block id translator;
    __block id request;
    void (^finish)(id) = FinishOnce(^(id value) {
        translator = nil;
        request = nil;
        completion(value);
    });
    @try {
        translator = [translatorClass new];
        request = [[requestClass alloc] initWithSourceLocale:[NSLocale localeWithLocaleIdentifier:source]
                                               targetLocale:[NSLocale localeWithLocaleIdentifier:target]];
        if (!translator || !request) {
            finish(nil);
            return;
        }
        [request setValue:[[NSAttributedString alloc] initWithString:text] forKey:@"text"];
        [request setValue:@(offline) forKey:@"forcedOfflineTranslation"];
        void (^handler)(id, id) = ^(id first, id second) {
            @try {
                if ([first isKindOfClass:NSError.class] || [second isKindOfClass:NSError.class]) {
                    finish(nil);
                    return;
                }
                NSString *answer = TranslatedText(first) ?: TranslatedText(second);
                if (answer.length) finish(answer);
            } @catch (NSException *exception) {
                finish(nil);
            }
        };
        if ([request respondsToSelector:NSSelectorFromString(@"setTranslationHandler:")]) {
            [request setValue:[handler copy] forKey:@"translationHandler"];
        }
        if ([request respondsToSelector:NSSelectorFromString(@"setCompletionHandler:")]) {
            [request setValue:[handler copy] forKey:@"completionHandler"];
        }
        [translator translate:request];
    } @catch (NSException *exception) {
        finish(nil);
    }
}
