#import "RunnerObjC.h"

NSString *_Nullable RunnerCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"(no reason)"];
    }
}

/// Keeps XCTest from screen-recording the runner.
///
/// Since Xcode 15 a UI test asks testmanagerd for a diagnostic screen recording
/// at test-case start and deletes it only when the test PASSES. The runner's one
/// test runs for hours and ends killed, so every session leaves its video behind
/// in testmanagerd's container — out of this sandbox's reach, not cleared by a
/// reboot, and it accumulates as "System Data" until the disk fills.
///
/// XCTest reads these two keys from the runner's standard defaults right before
/// it starts a recording / an interaction screenshot. Registering them at bundle
/// load, before any test case starts, covers every launcher (`test-without-building`,
/// devicectl, an IDE) rather than only the scheme this project generates.
@interface RunnerDiagnosticCaptureDisabler : NSObject
@end

@implementation RunnerDiagnosticCaptureDisabler

+ (void)load {
    // Registration domain: not persisted, and it loses only to a launcher that
    // explicitly passes the key as NO.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"DisableDiagnosticScreenRecordings": @YES,
        @"DisableDiagnosticScreenshots": @YES,
    }];
}

@end
