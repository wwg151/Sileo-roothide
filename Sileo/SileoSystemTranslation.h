#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL SileoSystemTranslationAvailable(void);
void SileoSystemTranslationPairs(void (^completion)(NSArray<NSArray<NSString *> *> * _Nullable pairs));
void SileoSystemTranslate(NSString *text, NSString *source, NSString *target, BOOL offline,
                          void (^completion)(NSString * _Nullable translation));

NS_ASSUME_NONNULL_END
