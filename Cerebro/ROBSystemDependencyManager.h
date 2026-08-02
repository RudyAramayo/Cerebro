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
    ROBSystemDependencyErrorPackageManagerUnavailable,
    ROBSystemDependencyErrorAdministratorAuthorizationRequired,
    ROBSystemDependencyErrorInstallInProgress,
    ROBSystemDependencyErrorInvalidPackageManager,
    ROBSystemDependencyErrorUntrustedPackageManager,
};

typedef NS_ENUM(NSInteger, ROBSystemPackageManager) {
    ROBSystemPackageManagerHomebrew = 0,
    ROBSystemPackageManagerMacPorts = 1,
};

FOUNDATION_EXPORT NSString *ROBSystemPackageManagerDisplayName(ROBSystemPackageManager packageManager);

typedef void (^ROBSystemDependencyCompletion)(BOOL success,
                                               NSString *output,
                                               NSError * _Nullable error);

/// Resolves optional command-line tools used by Cerebro and coalesces their
/// asynchronous installation. It never installs a package manager itself or
/// blocks the main thread.
@interface ROBSystemDependencyManager : NSObject

@property (class, nonatomic, readonly) ROBSystemDependencyManager *sharedManager;

@property (nonatomic, copy, readonly, nullable) NSString *sshpassPath;
@property (nonatomic, copy, readonly, nullable) NSString *homebrewPath;
@property (nonatomic, copy, readonly, nullable) NSString *macPortsPath;
@property (nonatomic, strong, readonly, nullable) NSError *macPortsValidationError;
/// The operator's persisted installer choice. If no choice has been saved,
/// Cerebro prefers the only detected manager and otherwise preserves the
/// historical Homebrew default.
@property (nonatomic, assign) ROBSystemPackageManager preferredPackageManager;
@property (nonatomic, assign, readonly, getter=isInstallingSSHpass) BOOL installingSSHpass;
@property (nonatomic, assign, readonly) ROBSystemPackageManager installingPackageManager;
@property (nonatomic, strong, readonly, nullable) NSError *lastSSHpassError;

/// Re-resolves sshpass after an external package-manager operation and notifies
/// all Cerebro windows only when availability changed.
- (void)refreshSSHpassAvailability;

/// Returns the detected executable for a package manager, if available.
- (nullable NSString *)pathForPackageManager:(ROBSystemPackageManager)packageManager;

/// Returns the exact command Cerebro will run or ask the operator to run.
- (nullable NSString *)sshpassInstallCommandForPackageManager:(ROBSystemPackageManager)packageManager;

/// Builds a command from the executable path captured for operator review.
- (nullable NSString *)sshpassInstallCommandForPackageManager:(ROBSystemPackageManager)packageManager
                                               executablePath:(NSString *)executablePath;

/// Standard MacPorts installations need administrator authorization. Cerebro
/// surfaces and copies that command for Terminal rather than collecting an
/// administrator password or invoking sudo through NSTask.
- (BOOL)requiresExternalAuthorizationForPackageManager:(ROBSystemPackageManager)packageManager;

/// Installs sshpass with the explicitly selected package manager when Cerebro
/// can do so without acquiring administrator credentials. Concurrent requests
/// for the same installer share one task and receive the same result. The
/// expected path must be the immutable path shown in the confirmation UI;
/// Cerebro rejects the operation if discovery changed before execution.
- (void)installSSHpassWithPackageManager:(ROBSystemPackageManager)packageManager
                  expectedExecutablePath:(NSString *)expectedExecutablePath
                              completion:(nullable ROBSystemDependencyCompletion)completion;

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
