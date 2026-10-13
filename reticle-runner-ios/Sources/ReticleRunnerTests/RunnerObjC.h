#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, returning nil, or the `name: reason` of an Objective-C exception
/// it raised.
///
/// XCTest raises NSException from plain-looking reads (`exists`, `isHittable`,
/// a snapshot) when the cross-process query cannot be answered. Swift cannot
/// catch those — `try?` only sees Swift `throws` — so one escapes into XCTest's
/// terminate handler and the runner dies with SIGABRT, which the host sees only as
/// a vanished process.
FOUNDATION_EXPORT NSString *_Nullable RunnerCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
