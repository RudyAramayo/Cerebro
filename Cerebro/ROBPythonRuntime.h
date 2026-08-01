//
//  ROBPythonRuntime.h
//  Cerebro
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ROBPythonRuntimeDidChangeNotification;
FOUNDATION_EXPORT NSString * const ROBPythonRuntimeConfigurationRequiredNotification;
FOUNDATION_EXPORT NSString * const ROBPythonRuntimeErrorDomain;

typedef NS_ENUM(NSInteger, ROBPythonRuntimeErrorCode) {
    ROBPythonRuntimeErrorNoInterpreter = 1,
    ROBPythonRuntimeErrorInvalidInterpreter,
    ROBPythonRuntimeErrorLaunchFailed,
    ROBPythonRuntimeErrorCommandFailed,
    ROBPythonRuntimeErrorManagedEnvironmentFailed,
};

typedef void (^ROBPythonRuntimeCompletion)(BOOL success, NSString *output, NSError * _Nullable error);

/// Owns the Python interpreter used by every in-process Cerebro Python task.
/// The selected value is the interpreter executable itself, not a shell
/// activation command, so virtualenv, Conda, Homebrew, and system installs all
/// use the same launch path.
@interface ROBPythonRuntime : NSObject

@property (class, nonatomic, readonly) ROBPythonRuntime *sharedRuntime;

/// The saved path, including a stale path that is no longer accessible.
@property (nonatomic, copy, readonly, nullable) NSString *configuredPythonPath;

/// The validated saved path, or an automatically discovered interpreter when
/// the user has not saved a choice. Returns nil rather than raising.
@property (nonatomic, copy, readonly, nullable) NSString *effectivePythonPath;

@property (nonatomic, copy, readonly) NSString *managedEnvironmentDirectory;
@property (nonatomic, copy, readonly) NSArray<NSString *> *requiredPackages;

/// Valid interpreter candidates in preference order.
- (NSArray<NSString *> *)availablePythonPaths;

/// Accepts either an interpreter executable or an environment directory that
/// contains bin/python3 (or bin/python).
- (nullable NSString *)interpreterPathForSelection:(NSString *)selection
                                              error:(NSError **)error;
- (BOOL)selectPythonAtPath:(NSString *)selection error:(NSError **)error;

/// Creates an NSTask configured with the selected interpreter, bundle-aware
/// PYTHONPATH, and unbuffered output. The caller owns its pipes and lifecycle.
- (nullable NSTask *)newTaskWithArguments:(NSArray<NSString *> *)arguments
                                    error:(NSError **)error;

/// Intended for existing Cerebro background queues that need complete output.
- (nullable NSString *)runPythonWithArguments:(NSArray<NSString *> *)arguments
                                         error:(NSError **)error;

- (void)validateEnvironmentWithCompletion:(ROBPythonRuntimeCompletion)completion;
- (void)installDependenciesWithCompletion:(ROBPythonRuntimeCompletion)completion;
- (void)createManagedEnvironmentWithCompletion:(ROBPythonRuntimeCompletion)completion;

@end

NS_ASSUME_NONNULL_END
