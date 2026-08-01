//
//  ROBSystemDependencyManager.h
//  Cerebro
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ROBSystemDependenciesDidChangeNotification;
FOUNDATION_EXPORT NSString * const ROBSystemDependencyErrorDomain;

typedef NS_ENUM(NSInteger, ROBSystemDependencyErrorCode) {
    ROBSystemDependencyErrorHomebrewUnavailable = 1,
    ROBSystemDependencyErrorInstallFailed,
    ROBSystemDependencyErrorToolUnavailable,
    ROBSystemDependencyErrorLaunchFailed,
};

typedef void (^ROBSystemDependencyCompletion)(BOOL success,
                                               NSString *output,
                                               NSError * _Nullable error);

/// Resolves optional command-line tools used by Cerebro and coalesces their
/// asynchronous installation. It never installs Homebrew itself or blocks the
/// main thread.
@interface ROBSystemDependencyManager : NSObject

@property (class, nonatomic, readonly) ROBSystemDependencyManager *sharedManager;

@property (nonatomic, copy, readonly, nullable) NSString *sshpassPath;
@property (nonatomic, copy, readonly, nullable) NSString *homebrewPath;
@property (nonatomic, assign, readonly, getter=isInstallingSSHpass) BOOL installingSSHpass;
@property (nonatomic, strong, readonly, nullable) NSError *lastSSHpassError;

/// Installs sshpass with an existing Homebrew installation when necessary.
/// Concurrent requests share one installation task and receive the same result.
- (void)ensureSSHpassInstalledWithCompletion:(nullable ROBSystemDependencyCompletion)completion;

/// Creates a task that uses the resolved sshpass and macOS OpenSSH binaries.
/// The password is supplied later through an anonymous pipe, not argv.
- (nullable NSTask *)newSSHpassTaskWithSSHArguments:(NSArray<NSString *> *)sshArguments
                                              error:(NSError **)error;

/// Launches a task returned above and supplies the password through sshpass's
/// inherited file-descriptor mode. Returns an NSError instead of raising for a
/// missing or inaccessible executable.
- (BOOL)launchSSHpassTask:(NSTask *)task
                 password:(NSString *)password
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
