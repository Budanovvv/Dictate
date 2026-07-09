#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block; if it raises an NSException (AVFoundation does this for
/// invalid audio formats — Swift `try` cannot catch those), converts the
/// exception into an NSError instead of crashing the process.
BOOL DictateCatchObjCException(void (NS_NOESCAPE ^block)(void),
                               NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
