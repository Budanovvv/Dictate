#import "ObjCExceptionCatcher.h"

BOOL DictateCatchObjCException(void (NS_NOESCAPE ^block)(void),
                               NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"Dictate"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}
