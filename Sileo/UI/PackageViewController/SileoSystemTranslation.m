#import "../../SileoSystemTranslation.h"
#import <TargetConditionals.h>
#import <dlfcn.h>

// Translation.framework integration adapted from Irisin (OwnGoal Studio, MIT).
// See LICENSE-Irisin in the repository root.
// The engine is private, so never link it or assume that an individual selector exists.
@interface NSObject (SileoTranslationEngine)
+ (void)availableLocalePairsForTask:(NSInteger)task completion:(void (^)(NSArray *))completion;
- (void)startTranslationSession;
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
            ([requestClass instancesRespondToSelector:NSSelectorFromString(@"setTextTranslationHandler:")] ||
             [requestClass instancesRespondToSelector:NSSelectorFromString(@"setTranslationHandler:")] ||
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

// One translator and its session serve the whole app. iOS 16 starts a text
// session on the translator itself, and a translator made per sentence is
// answered with nothing at all.
static id SileoTranslationEngine(void) {
    static id translator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        translator = [translatorClass new];
        if ([translator respondsToSelector:NSSelectorFromString(@"startTranslationSession")]) {
            [translator performSelector:NSSelectorFromString(@"startTranslationSession")];
        }
    });
    return translator;
}

static void SileoRestartTranslationSession(void) {
    id translator = SileoTranslationEngine();
    if ([translator respondsToSelector:NSSelectorFromString(@"startTranslationSession")]) {
        [translator performSelector:NSSelectorFromString(@"startTranslationSession")];
    }
}

// A job is kept until it answers: its blocks hold it weakly, so the registry
// is what keeps a request alive while the engine works on it.
static NSMutableSet *SileoActiveTranslationJobs(void) {
    static NSMutableSet *jobs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ jobs = [NSMutableSet set]; });
    return jobs;
}

// The engine answers some requests with an empty result rather than a
// translation; another ask usually succeeds, so each text gets three tries
// before it counts as untranslated.
@interface SileoTranslationJob : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *target;
@property (nonatomic) BOOL offline;
@property (nonatomic) NSInteger attempt;
@property (nonatomic) NSInteger token;
@property (nonatomic, strong) id request;
@property (nonatomic, copy) void (^completion)(NSString *);
@end

@implementation SileoTranslationJob

- (void)start {
    if (!self.completion) return;
    [SileoActiveTranslationJobs() addObject:self];
    if (self.attempt >= 3) {
        [self finish:nil];
        return;
    }
    self.attempt++;
    NSInteger token = self.token + 1;
    self.token = token;
    __weak SileoTranslationJob *weakSelf = self;
    void (^answer)(NSString *) = ^(NSString *value) {
        SileoTranslationJob *job = weakSelf;
        if (!job || job.token != token) return;
        if (value.length) {
            [job finish:value];
        } else {
            [job retry];
        }
    };
    @try {
        // The session has to exist before the request does: a request made
        // first is accepted and then never answered.
        id translator = SileoTranslationEngine();
        id request = [[requestClass alloc] initWithSourceLocale:[NSLocale localeWithLocaleIdentifier:self.source]
                                                 targetLocale:[NSLocale localeWithLocaleIdentifier:self.target]];
        if (!request || !translator) {
            [self finish:nil];
            return;
        }
        [request setValue:[[NSAttributedString alloc] initWithString:self.text] forKey:@"text"];
        if ([request respondsToSelector:NSSelectorFromString(@"setForcedOfflineTranslation:")]) {
            [request setValue:@(self.offline) forKey:@"forcedOfflineTranslation"];
        }
        void (^handler)(id, id) = ^(id first, id second) {
            @try {
                if ([first isKindOfClass:NSError.class] || [second isKindOfClass:NSError.class]) {
                    answer(nil);
                    return;
                }
                answer(TranslatedText(first) ?: TranslatedText(second));
            } @catch (NSException *exception) {
                answer(nil);
            }
        };
        if ([request respondsToSelector:NSSelectorFromString(@"setTextTranslationHandler:")]) {
            [request setValue:[handler copy] forKey:@"textTranslationHandler"];
        }
        if ([request respondsToSelector:NSSelectorFromString(@"setTranslationHandler:")]) {
            [request setValue:[handler copy] forKey:@"translationHandler"];
        }
        if ([request respondsToSelector:NSSelectorFromString(@"setCompletionHandler:")]) {
            [request setValue:[handler copy] forKey:@"completionHandler"];
        }
        self.request = request;
        [translator translate:request];
    } @catch (NSException *exception) {
        [self finish:nil];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SileoTranslationJob *job = weakSelf;
        if (job && job.token == token) [job retry];
    });
}

- (void)retry {
    // A session can end while the app sits in the background; begin another
    // before asking again.
    SileoRestartTranslationSession();
    self.request = nil;
    [self start];
}

- (void)finish:(NSString *)answer {
    void (^completion)(NSString *) = self.completion;
    self.completion = nil;
    self.request = nil;
    [SileoActiveTranslationJobs() removeObject:self];
    if (completion) completion(answer);
}

@end

void SileoSystemTranslate(NSString *text, NSString *source, NSString *target, BOOL offline,
                          void (^completion)(NSString *)) {
    if (!SileoSystemTranslationAvailable()) {
        completion(nil);
        return;
    }
    SileoTranslationJob *job = [[SileoTranslationJob alloc] init];
    job.text = text;
    job.source = source;
    job.target = target;
    job.offline = offline;
    job.completion = completion;
    [job start];
}
