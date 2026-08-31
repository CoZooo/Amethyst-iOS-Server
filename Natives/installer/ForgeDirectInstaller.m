//
//  ForgeDirectInstaller.m
//  Amethyst
//
//  Direct Forge installer (old + new format) based on FCL / ZalithLauncher2 logic.
//
//  新格式（Forge 1.13+）：参照 ZL2/HMCL 的 ForgeNewInstallTask，在本地执行
//  install_profile.json 的 processors（binarypatcher、jarsplitter、
//  ForgeAutoRenamingTool、installertools 等），生成 FML 运行必需的
//  PATCHED / MC_SRG / MC_EXTRA artifact。processors 由进程内 headless JVM
//  中的 ForgeProcessorRunner 执行（iOS 沙箱禁止 fork/exec，无法 spawn 子 JVM），
//  共用核心见 ForgeProcessorExecutor。
//
//  JarJar（JarInJar）机制是运行期由 modlauncher 的 JarInJarDependencyLocator 处理，
//  安装期无需任何 processor 介入。
//
//  1.12.2 及以下旧格式 Forge 没有 processors，直装直接放 universal jar + version.json 即可。
//

#import "ForgeDirectInstaller.h"
#if !defined(AMETHYST_SERVER_RUNTIME)
#import "PLProfiles.h"
#import "PLMirrorCenter.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#endif
#import "ForgeProcessorExecutor.h"
#import "external/UnzipKit/UZKArchive.h"

#if defined(AMETHYST_SERVER_RUNTIME)
#include "amethyst_ios_server.h"
#endif
#include <stddef.h>
#include <stdio.h>
#include <string.h>

NSString *const ForgeDirectInstallerErrorDomain = @"ForgeDirectInstallerErrorDomain";

static NSError *AISWriteJSONFile(NSDictionary *object, NSString *path)
{
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:&error];
    if (!data) return error;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) return error;
    return nil;
}

static BOOL AISPathIsInsideDirectory(NSString *path, NSString *directory)
{
    NSString *root = [[directory stringByStandardizingPath] stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    root = [@"/" stringByAppendingString:root];
    NSString *candidate = [path stringByStandardizingPath];
    NSString *prefix = [root stringByAppendingString:@"/"];
    return [candidate isEqualToString:root] || [candidate hasPrefix:prefix];
}

static NSString *AISExpandServerPath(NSString *value,
                                     NSString *root,
                                     NSString *libraries,
                                     NSString *minecraftJar,
                                     NSString *minecraftVersion,
                                     NSString *installer)
{
    NSMutableString *expanded = [value mutableCopy];
    NSDictionary *variables = @{
        @"ROOT": root,
        @"LIBRARY_DIR": libraries,
        @"MINECRAFT_JAR": minecraftJar,
        @"MINECRAFT_VERSION": minecraftVersion,
        @"INSTALLER": installer,
        @"SIDE": @"server"
    };
    for (NSString *key in variables) {
        [expanded replaceOccurrencesOfString:[NSString stringWithFormat:@"{%@}", key]
                                  withString:variables[key]
                                     options:0
                                       range:NSMakeRange(0, expanded.length)];
    }
    NSString *candidate = [expanded copy];
    if (![candidate hasPrefix:@"/"]) candidate = [root stringByAppendingPathComponent:candidate];
    return [candidate stringByStandardizingPath];
}

static BOOL AISProfileIsNeoForge(NSDictionary *profile, NSDictionary *version)
{
    for (id candidate in @[profile[@"profile"] ?: @"",
                           profile[@"path"] ?: @"",
                           profile[@"version"] ?: @"",
                           version[@"id"] ?: @""]) {
        if ([candidate isKindOfClass:[NSString class]] &&
            [[(NSString *)candidate lowercaseString] containsString:@"neoforge"]) {
            return YES;
        }
        if ([candidate isKindOfClass:[NSString class]] &&
            [[(NSString *)candidate lowercaseString] hasPrefix:@"net.neoforged:"]) {
            return YES;
        }
    }
    for (id collection in @[profile[@"libraries"] ?: @[], version[@"libraries"] ?: @[]]) {
        if (![collection isKindOfClass:[NSArray class]]) continue;
        for (id item in (NSArray *)collection) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
            if ([name.lowercaseString hasPrefix:@"net.neoforged:"]) return YES;
        }
    }
    return NO;
}

@implementation ForgeDirectInstaller

#pragma mark - Public

#if !defined(AMETHYST_SERVER_RUNTIME)
+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                            error:(NSError **)error {
    return [self installForgeFromInstaller:installerPath versionId:versionId progress:nil error:error];
}

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                          progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error {
    return [self installForgeFromInstaller:installerPath
                                  versionId:versionId
                              customGameDir:nil
                        skipRegisterVersion:NO
                                   progress:progress
                                     error:error];
}

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                    customGameDir:(nullable NSString *)customGameDir
              skipRegisterVersion:(BOOL)skipRegisterVersion
                         progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error {
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    @try {
        NSLog(@"[ForgeDirect] Starting installation: %@", versionId);
        reportProgress(0.0, localize(@"i18n_str_1266", nil));
        if (error) {
            *error = nil;
        }

        // Step 1 & 2: Open jar as ZIP and read install_profile.json
        NSLog(@"[ForgeDirect] Reading install_profile.json");
        reportProgress(0.05, localize(@"i18n_str_1267", nil));
        NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:error];
        if (!profileData) {
            NSLog(@"[ForgeDirect] Failed to read install_profile.json");
            if (error && !*error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorMissingProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing install_profile.json in installer"}];
            }
            return NO;
        }
        NSLog(@"[ForgeDirect] Successfully read install_profile.json (%lu bytes)", (unsigned long)profileData.length);

        // Step 3: Parse install_profile.json
        NSLog(@"[ForgeDirect] Parsing install_profile.json");
        reportProgress(0.1, localize(@"i18n_str_1320", nil));
        NSError *jsonError = nil;
        NSMutableDictionary *installProfile = [NSJSONSerialization JSONObjectWithData:profileData
                                                                              options:NSJSONReadingMutableContainers
                                                                                error:&jsonError];
        NSLog(@"[ForgeDirect] JSON parsing completed, error=%@", jsonError ?: @"none");
        if (![installProfile isKindOfClass:[NSDictionary class]] || jsonError) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse install_profile.json"}];
            }
            return NO;
        }

        // Step 4: Determine format
        NSLog(@"[ForgeDirect] Detecting installer format");
        BOOL isNewFormat = (installProfile[@"spec"] != nil);
        BOOL isOldFormat = (installProfile[@"install"] != nil && installProfile[@"versionInfo"] != nil);
        NSLog(@"[ForgeDirect] Format detection: new=%d, old=%d", isNewFormat, isOldFormat);

        if (!isNewFormat && !isOldFormat) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Unknown install_profile format"}];
            }
            return NO;
        }

        // 整合包导入时使用自定义 gameDir；否则使用默认 POJAV_GAME_DIR
        // 注意：gameDir（user.dir，mods/saves/configs 隔离目录）用 customGameDir，
        // 但 versionDir 和 librariesDir 必须始终用 POJAV_GAME_DIR（主目录）。
        // 原因：Minecraft 启动器（Java 端 Tools.java）的 DIR_HOME_VERSION 和 DIR_HOME_LIBRARY
        // 固定指向 POJAV_GAME_DIR/versions 和 POJAV_GAME_DIR/libraries，不从 profile gameDir 读取。
        // 之前把 versionDir/librariesDir 放到 customGameDir 下会导致启动时"找不到版本信息"。
        NSString *gameDir = customGameDir.length > 0 ? customGameDir : [self gameDirectory];
        NSString *mainGameDir = [self gameDirectory];  // 始终用主目录存放 versions 和 libraries
        NSString *librariesDir = [mainGameDir stringByAppendingPathComponent:@"libraries"];
        NSLog(@"[ForgeDirect] Game directory (user.dir): %@", gameDir);
        NSLog(@"[ForgeDirect] Main game directory (versions/libraries): %@", mainGameDir);
        NSLog(@"[ForgeDirect] Libraries directory: %@", librariesDir);
        reportProgress(0.15, localize(@"i18n_str_1268", nil));

        // 提前创建 libraries 目录，避免后续下载/解压失败
        [[NSFileManager defaultManager] createDirectoryAtPath:librariesDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        BOOL success = NO;
        if (isOldFormat) {
            NSLog(@"[ForgeDirect] Using old format installer");
            success = [self installOldFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                    gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        } else {
            NSLog(@"[ForgeDirect] Using new format installer");
            success = [self installNewFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                    gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        }

        if (!success) {
            NSLog(@"[ForgeDirect] Installation failed");
            return NO;
        }

        // Step 7: Register version in launcher_profiles.json (must run on main thread)
        // 整合包导入时跳过（由 ModpackImportService.createProfileForModpack 统一注册）
        if (!skipRegisterVersion) {
            NSLog(@"[ForgeDirect] Registering version on main thread");
            reportProgress(0.95, localize(@"i18n_str_1269", nil));
            if ([NSThread isMainThread]) {
                [self registerVersion:versionId];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self registerVersion:versionId];
                });
            }
            NSLog(@"[ForgeDirect] Version registered successfully");
        }

        NSLog(@"[ForgeDirect] Installation completed successfully");
        reportProgress(1.0, localize(@"i18n_str_1270", nil));
        return YES;
    }
    @catch (NSException *exception) {
        NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
        NSLog(@"[ForgeDirect] EXCEPTION: name=%@, reason=%@, callStack=%@", exception.name, exception.reason, stack);
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                          code:ForgeDirectInstallerErrorException
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1117", nil), exception.reason ?: localize(@"i18n_str_1118", nil)],
                                          NSLocalizedFailureReasonErrorKey: exception.name ?: @"UnknownException"
                                      }];
        }
        return NO;
    }
}

+ (BOOL)isNewFormatInstaller:(NSString *)installerPath {
    NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:nil];
    if (!profileData) {
        return NO;
    }

    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:profileData options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    return dict[@"spec"] != nil;
}
#endif

+ (BOOL)installForgeServerFromInstaller:(NSString *)installerPath
                            instanceRoot:(NSString *)instanceRoot
                       vanillaServerJar:(NSString *)vanillaServerJar
                              javaHome:(NSString *)javaHome
                               progress:(void (^)(double, NSString *))progress
                                 result:(NSDictionary **)result
                                  error:(NSError **)error {
    if (result) *result = nil;
    if (error) *error = nil;

    void (^report)(double, NSString *) = ^(double value, NSString *message) {
        NSLog(@"[ForgeDirect][server] %.2f %@", value, message);
        if (progress) progress(value, message);
    };
    NSString *root = [instanceRoot stringByStandardizingPath];
    NSString *vanilla = [vanillaServerJar stringByStandardizingPath];
    if (installerPath.length == 0 || root.length == 0 || vanilla.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:installerPath] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:vanilla]) {
        if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                  code:ForgeDirectInstallerErrorInvalidArchive
                                              userInfo:@{NSLocalizedDescriptionKey: @"服务端安装器参数或原版服务端 JAR 不存在。"}];
        return NO;
    }

    @try {
        report(0.02, @"正在读取 Forge 安装器");
        NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:error];
        NSDictionary *profile = profileData
            ? [NSJSONSerialization JSONObjectWithData:profileData options:NSJSONReadingMutableContainers error:error]
            : nil;
        if (![profile isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                                  code:ForgeDirectInstallerErrorInvalidProfile
                                                              userInfo:@{NSLocalizedDescriptionKey: @"无法解析 install_profile.json。"}];
            return NO;
        }

        BOOL oldFormat = profile[@"install"] != nil && profile[@"versionInfo"] != nil;
        NSString *versionEntry = [profile[@"json"] isKindOfClass:[NSString class]] ? profile[@"json"] : @"version.json";
        NSData *versionData = oldFormat ? nil : [self dataFromZip:installerPath
                                                              entry:[versionEntry stringByTrimmingCharactersInSet:
                                                                          [NSCharacterSet characterSetWithCharactersInString:@"/"]]
                                                              error:error];
        NSDictionary *version = oldFormat
            ? ([profile[@"versionInfo"] isKindOfClass:[NSDictionary class]] ? profile[@"versionInfo"] : nil)
            : (versionData ? [NSJSONSerialization JSONObjectWithData:versionData options:NSJSONReadingMutableContainers error:error] : nil);
        if (![version isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                                  code:ForgeDirectInstallerErrorInvalidProfile
                                                              userInfo:@{NSLocalizedDescriptionKey: @"无法解析 Forge 版本信息。"}];
            return NO;
        }

        NSString *minecraft = [version[@"inheritsFrom"] isKindOfClass:[NSString class]]
            ? version[@"inheritsFrom"]
            : ([profile[@"minecraft"] isKindOfClass:[NSString class]] ? profile[@"minecraft"] : nil);
        if (minecraft.length == 0 && oldFormat) {
            minecraft = profile[@"install"][@"minecraft"];
        }
        NSString *loader = [profile[@"version"] isKindOfClass:[NSString class]]
            ? profile[@"version"]
            : ([version[@"id"] isKindOfClass:[NSString class]] ? version[@"id"] : nil);
        if (loader.length == 0 && oldFormat) loader = profile[@"install"][@"version"];
        if (minecraft.length == 0 || loader.length == 0) {
            if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                      code:ForgeDirectInstallerErrorInvalidProfile
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Forge 安装器缺少 Minecraft 或 Loader 版本。"}];
            return NO;
        }

        NSString *libraries = [root stringByAppendingPathComponent:@"libraries"];
        [[NSFileManager defaultManager] createDirectoryAtPath:libraries
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:error];
        if (oldFormat) {
            report(0.20, @"正在解压 Forge 服务端核心");
            NSDictionary *install = profile[@"install"];
            NSString *entry = [install[@"filePath"] isKindOfClass:[NSString class]] ? install[@"filePath"] : nil;
            if (entry.length == 0) {
                if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                          code:ForgeDirectInstallerErrorInvalidProfile
                                                      userInfo:@{NSLocalizedDescriptionKey: @"旧版 Forge 安装器缺少 universal JAR。"}];
                return NO;
            }
            NSString *destination = [install[@"path"] isKindOfClass:[NSString class]]
                ? [libraries stringByAppendingPathComponent:[self mavenPathToRelativePath:install[@"path"]]]
                : [root stringByAppendingPathComponent:entry.lastPathComponent];
            if (![self extractFile:installerPath entry:entry to:destination error:error]) return NO;
            NSDictionary *serverResult = @{
                @"kind": @"Forge",
                @"minecraftVersion": minecraft,
                @"loaderVersion": loader,
                @"executableJar": destination
            };
            if (result) *result = serverResult;
            report(1.0, @"Forge 服务端安装完成");
            return YES;
        }

        report(0.12, @"正在准备 Forge 运行库");
        [self extractAllMavenEntries:installerPath toLibrariesDir:libraries];
        NSArray *runtimeLibraries = [version[@"libraries"] isKindOfClass:[NSArray class]] ? version[@"libraries"] : @[];
#if defined(AMETHYST_SERVER_RUNTIME)
        if (![self downloadMissingLibraries:runtimeLibraries
                               librariesDir:libraries
                                   progress:^(double p, NSString *message) {
            report(0.12 + p * 0.20, message);
        } baseProgress:0.0 progressSpan:1.0 error:error]) return NO;
#else
        [self downloadMissingLibraries:runtimeLibraries librariesDir:libraries progress:^(double p, NSString *message) {
            report(0.12 + p * 0.20, message);
        } baseProgress:0.0 progressSpan:1.0];
#endif
        NSArray *processorLibraries = [profile[@"libraries"] isKindOfClass:[NSArray class]] ? profile[@"libraries"] : @[];
#if defined(AMETHYST_SERVER_RUNTIME)
        if (![self downloadMissingLibraries:processorLibraries
                               librariesDir:libraries
                                   progress:^(double p, NSString *message) {
            report(0.32 + p * 0.13, message);
        } baseProgress:0.0 progressSpan:1.0 error:error]) return NO;
#else
        [self downloadMissingLibraries:processorLibraries librariesDir:libraries progress:^(double p, NSString *message) {
            report(0.32 + p * 0.13, message);
        } baseProgress:0.0 progressSpan:1.0];
#endif

        NSMutableDictionary *serverVersion = [version mutableCopy];
        serverVersion[@"id"] = loader;
        NSString *versionDir = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", loader]];
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:error];
        NSString *versionPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", loader]];
        NSError *writeError = AISWriteJSONFile(serverVersion, versionPath);
        if (writeError) {
            if (error) *error = writeError;
            return NO;
        }

        NSString *serverJarPath = [profile[@"serverJarPath"] isKindOfClass:[NSString class]] ? profile[@"serverJarPath"] : nil;
        if (serverJarPath.length == 0) serverJarPath = @"server.jar";
        serverJarPath = AISExpandServerPath(serverJarPath, root, libraries, vanilla, minecraft, installerPath);
        if (!serverJarPath || !AISPathIsInsideDirectory(serverJarPath, root)) {
            if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                      code:ForgeDirectInstallerErrorWriteFailed
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Forge serverJarPath 超出实例目录。"}];
            return NO;
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:[serverJarPath stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:error];
        [[NSFileManager defaultManager] removeItemAtPath:serverJarPath error:nil];
        if (![[NSFileManager defaultManager] copyItemAtPath:vanilla toPath:serverJarPath error:error]) return NO;

        report(0.48, @"正在执行 Forge 服务端处理器");
        if (![ForgeProcessorExecutor runProcessorsWithProfile:profile
                                                 installerPath:installerPath
                                              minecraftVersion:minecraft
                                                     mainGameDir:root
                                                 vanillaJarPath:serverJarPath
                                                            side:@"server"
                                                         javaHome:javaHome
                                                     baseProgress:0.48
                                                    progressSpan:0.42
                                                        progress:^(double p, NSString *message) {
            report(p, message);
        } error:error]) return NO;

        BOOL isNeoForge = AISProfileIsNeoForge(profile, version);
        NSMutableDictionary *serverResult = [@{
            @"kind": isNeoForge ? @"NeoForge" : @"Forge",
            @"minecraftVersion": minecraft,
            @"loaderVersion": loader,
            @"serverJarPath": serverJarPath
        } mutableCopy];
        NSString *argumentsFile = [self serverArgumentsFileForProfile:profile
                                                               version:version
                                                          librariesDir:libraries];
        if (argumentsFile.length == 0) {
            if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                      code:ForgeDirectInstallerErrorWriteFailed
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                                                 @"安装器未生成当前 Forge/NeoForge 版本的 unix_args.txt。"}];
            return NO;
        }
        serverResult[@"argumentsFile"] = argumentsFile;
        if (result) *result = serverResult;
        report(1.0, @"Forge 服务端安装完成");
        return YES;
    }
    @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                  code:ForgeDirectInstallerErrorException
                                              userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Forge 服务端安装异常。"}];
        return NO;
    }
}

#pragma mark - Helpers

#if !defined(AMETHYST_SERVER_RUNTIME)
// 游戏目录：与 JavaLauncher.m 中 [launchTarget isKindOfClass:NSDictionary.class] 分支保持一致
// 即 $POJAV_HOME/instances/<general.game_directory>/<profile.gameDir>
// 但直装时还没有 profile，无法读 gameDir，使用默认 "."
+ (NSString *)gameDirectory {
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        return [@(env) stringByStandardizingPath];
    }
    return NSHomeDirectory();
}

/// 阶段6修复（参照 FCL）：用 NSURLSession 替代已废弃的 NSURLConnection sendSynchronousRequest:
/// 进行同步 HTTP 下载。原 NSURLConnection 在 iOS 13+ 已废弃，BMCLAPI 等镜像源在某些 iOS 版本
/// 下表现不稳定（TLS 协商失败、超时不生效、不跟随 302 重定向等），导致 ensureParentVersionExists:
/// 拉取父版本 JSON 失败 → Forge/NeoForge 版本 inheritsFrom 找不到原版 → 启动崩溃。
/// 这里复用 downloadFileFromURL: 中已验证可用的 NSURLSession + 信号量模式。
+ (NSData *)downloadDataForRequest:(NSURLRequest *)request error:(NSError **)error {
    if (!request) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil request"}];
        }
        return nil;
    }
    __block NSData *resultData = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            resultError = taskError;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                   code:statusCode
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, request.URL.absoluteString]}];
            } else {
                resultData = data;
            }
        } else {
            resultData = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    if (waitResult != 0) {
        [task cancel];
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1119", nil), request.URL.absoluteString]}];
        }
        return nil;
    }
    if (error) *error = resultError;
    return resultData;
}

/// 带候选轮换与简单退避的同步下载：经 PLMirrorCenter（GameFile 类型）生成
/// 官方/镜像候选 URL，最多尝试 3 次，每次失败后在候选间轮换（官方↔镜像），
/// 重试间隔线性退避（0.5s / 1s）。用于父版本 manifest / version JSON 等
/// 小体积关键元数据下载，替代原先"单次请求、无重试、bmclapi 分支硬编码"的行为，
/// 同时消除"偏好为 mcim 时不走镜像直接回退官方"的不一致（PLMirrorCenter 已把
/// mcim/bmclapi 意图统一映射为 BMCLAPI 镜像候选）。
+ (NSData *)downloadDataForURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil url"}];
        }
        return nil;
    }
    NSArray<NSURL *> *candidates = [PLMirrorCenter candidateURLsForOriginalURL:url
                                                                   resourceType:PLMirrorResourceTypeGameFile];
    if (candidates.count == 0) candidates = @[url];

    NSData *data = nil;
    NSError *lastError = nil;
    // 简单退避：最多 3 次尝试，候选轮换（第 i 次取 candidates[i % count]）
    for (NSInteger attempt = 0; attempt < 3 && !data; attempt++) {
        if (attempt > 0) {
            [NSThread sleepForTimeInterval:0.5 * attempt];
        }
        NSURL *candidate = candidates[attempt % candidates.count];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:candidate];
        request.timeoutInterval = 30.0;
        request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

        NSError *attemptError = nil;
        data = [self downloadDataForRequest:request error:&attemptError];
        if (!data) {
            lastError = attemptError;
            NSLog(@"[ForgeDirect] Attempt %ld failed for %@: %@", (long)attempt, candidate.absoluteString, attemptError.localizedDescription ?: @"unknown");
        }
    }
    if (!data && error) *error = lastError;
    return data;
}

/// 参照 FCL/HMCL：确保父版本（vanilla MC）的 version JSON 已存在。
/// Forge/NeoForge 的 version.json 含 "inheritsFrom": "1.20.1" 等字段，启动时 Java 端
/// Tools.getVersionInfo() 会读取 versions/{inheritsFrom}/{inheritsFrom}.json 与当前版本合并。
/// 若用户尚未安装原版，启动会因 FileNotFoundException 崩溃。
/// 本方法仅下载父版本的 version JSON（不下载原版 client.jar，因为 iOS 启动器使用
/// 自有渲染管线，不需要原版 client.jar；但需要 JSON 以提供 mainClass、arguments、
/// assetIndex、vanilla libraries 等元数据）。
+ (BOOL)ensureParentVersionExists:(NSString *)parentVersionId error:(NSError **)error {
    if (parentVersionId.length == 0) return YES;

    NSString *mainGameDir = [self gameDirectory];
    NSString *parentVersionDir = [mainGameDir stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"versions/%@", parentVersionId]];
    NSString *parentJsonPath = [parentVersionDir stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@.json", parentVersionId]];

    // 1. 父版本 JSON 已存在，无需下载
    if ([NSFileManager.defaultManager fileExistsAtPath:parentJsonPath]) {
        NSLog(@"[ForgeDirect] Parent version JSON already exists: %@", parentJsonPath);
        return YES;
    }

    NSLog(@"[ForgeDirect] Parent version JSON missing, downloading: %@", parentVersionId);

    // 2. 拉取 Mojang 版本清单（统一走 PLMirrorCenter GameFile 候选：官方/镜像轮换重试，
    //    消除旧实现"偏好为 mcim 时不走镜像"的不一致）
    NSURL *manifestURL = [NSURL URLWithString:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"];
    if (!manifestURL) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid manifest URL"}];
        }
        return NO;
    }

    NSData *manifestData = [self downloadDataForURL:manifestURL error:error];
    if (!manifestData) {
        NSLog(@"[ForgeDirect] Failed to download version manifest: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    NSArray *versions = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"versions"] : nil;
    if (![versions isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid version manifest format"}];
        }
        return NO;
    }

    // 3. 查找匹配的版本条目，获取 version JSON URL
    NSString *versionJSONURL = nil;
    for (NSDictionary *v in versions) {
        if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:parentVersionId]) {
            versionJSONURL = [v[@"url"] isKindOfClass:[NSString class]] ? v[@"url"] : nil;
            break;
        }
    }
    if (!versionJSONURL) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Version %@ not found in manifest", parentVersionId]}];
        }
        return NO;
    }

    NSLog(@"[ForgeDirect] Downloading parent version JSON from: %@", versionJSONURL);

    // 4. 下载 version JSON（统一走 PLMirrorCenter GameFile 候选：官方/镜像轮换重试，
    //    无论 manifest 从哪个源取得，此处 URL 均为官方域名，由候选机制完成镜像映射）
    NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
    if (!jsonURL) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid version JSON URL"}];
        }
        return NO;
    }

    NSData *jsonData = [self downloadDataForURL:jsonURL error:error];
    if (!jsonData) {
        NSLog(@"[ForgeDirect] Failed to download parent version JSON: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    // 5. 创建父版本目录并写入 JSON
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:parentVersionDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        NSLog(@"[ForgeDirect] Failed to create parent version dir: %@", dirError.localizedDescription);
        if (error) *error = dirError;
        return NO;
    }

    NSError *writeErr = nil;
    if (![jsonData writeToFile:parentJsonPath options:NSDataWritingAtomic error:&writeErr]) {
        NSLog(@"[ForgeDirect] Failed to write parent version JSON: %@", writeErr.localizedDescription);
        if (error) *error = writeErr;
        return NO;
    }

    NSLog(@"[ForgeDirect] Parent version JSON saved: %@ (%lu bytes)", parentJsonPath, (unsigned long)jsonData.length);
    return YES;
}

+ (void)registerVersion:(NSString *)versionId {
    NSLog(@"[ForgeDirect] registerVersion called: %@", versionId);
    PLProfiles *profiles = [PLProfiles current];
    NSLog(@"[ForgeDirect] PLProfiles current: %@", profiles ? @"ok" : @"nil");
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    // 改回原来的"游戏目录切换"机制：所有版本共享根目录（gameDir="."）
    // 用户通过设置中的"游戏目录切换"功能手动切换不同的 gameDir
    profileDict[@"gameDir"] = @".";
    profileDict[@"type"] = @"custom";
    profileDict[@"created"] = [NSDate date].description;
    // 推断 Java 版本：Forge 1.20.5+ 需 Java 21，1.18+ 需 Java 17，1.17 需 Java 16，其他 Java 8
    // versionId 形如 "1.20.1-forge-47.3.0" 或 "Forge-1.20.1-47.3.0"，提取 MC 版本
    NSInteger javaMajor = [self inferJavaMajorVersionFromVersionId:versionId];
    // 写入 NSString 而非 NSDictionary，与 ProfileSettingsViewController 等所有读取方一致
    // JavaLauncher 通过 .intValue 读取，"17".intValue = 17
    profileDict[@"javaVersion"] = [NSString stringWithFormat:@"%ld", (long)javaMajor];
    [profiles saveProfile:profileDict withName:versionId];
    // 与 Fabric / Vanilla 安装路径保持一致：自动选中新建的 profile，避免用户回到主界面仍启动旧版本
    profiles.selectedProfileName = versionId;
    NSLog(@"[ForgeDirect] Profile saved and selected (javaVersion=%ld, gameDir=%@)", (long)javaMajor, profileDict[@"gameDir"]);
}

/// 从 versionId 中推断所需 Java 主版本号
/// versionId 形如 "1.20.1-forge-47.3.0"、"Forge-1.20.1-47.3.0"、"1.18.2-forge-40.2.0"
+ (NSInteger)inferJavaMajorVersionFromVersionId:(NSString *)versionId {
    // 提取 1.x.x 格式的 MC 版本（锚定开头或分隔符，避免误匹配 loader 版本号中的 "1.x"）
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[-_])1\\.(\\d+)(?:\\.(\\d+))?"
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
    if (!match || match.numberOfRanges < 2) return 8;
    NSString *minorStr = [versionId substringWithRange:[match rangeAtIndex:1]];
    NSInteger minor = [minorStr integerValue];
    NSString *patchStr = match.numberOfRanges >= 3 && [match rangeAtIndex:2].location != NSNotFound
                        ? [versionId substringWithRange:[match rangeAtIndex:2]]
                        : @"0";
    NSInteger patch = [patchStr integerValue];
    if (minor >= 21) return 21;                  // 1.21+
    if (minor >= 20 && patch >= 5) return 21;    // 1.20.5+
    if (minor >= 18) return 17;                  // 1.18+
    if (minor >= 17) return 17;                  // 1.17（项目未捆绑 Java 16，Java 17 可向后兼容运行 1.17）
    return 8;                                     // 1.16.5 及以下
}

#pragma mark - Old format (Forge 1.12.2-)

+ (BOOL)installOldFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[ForgeDirect] installOldFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    NSDictionary *versionInfo = installProfile[@"versionInfo"];
    if (![versionInfo isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing versionInfo in install_profile.json"}];
        }
        return NO;
    }

    NSMutableDictionary *mutableVersionInfo = [versionInfo mutableCopy];
    mutableVersionInfo[@"id"] = versionId;

    // Prepare version directory
    // 版本 JSON 必须写入 POJAV_GAME_DIR/versions/（主目录），而非 profile gameDir。
    // Minecraft 启动器 Java 端固定从 POJAV_GAME_DIR/versions 加载版本 JSON。
    NSString *versionDir = [[self gameDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[ForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Extract universal jar
    NSLog(@"[ForgeDirect] Extracting universal jar");
    reportProgress(0.4, localize(@"i18n_str_1273", nil));
    NSDictionary *installDict = installProfile[@"install"];
    id filePathObj = installDict[@"filePath"];
    id mavenPathObj = installDict[@"path"];
    NSString *filePath = [filePathObj isKindOfClass:[NSString class]] ? filePathObj : nil;
    NSString *mavenPath = [mavenPathObj isKindOfClass:[NSString class]] ? mavenPathObj : nil;

    if (filePath.length > 0) {
        NSString *destPath;
        if (mavenPath.length > 0) {
            destPath = [librariesDir stringByAppendingPathComponent:[self mavenPathToRelativePath:mavenPath]];
        } else {
            destPath = [versionDir stringByAppendingPathComponent:[filePath lastPathComponent]];
        }
        NSLog(@"[ForgeDirect] Extracting universal jar to: %@", destPath);

        if (![self extractFile:installerPath entry:filePath to:destPath error:error]) {
            return NO;
        }
        NSLog(@"[ForgeDirect] Universal jar extracted successfully");
    } else {
        // filePath 缺失：universal jar 是老版本 Forge 的核心运行时依赖
        // 若 mavenPath 存在，后续 extractAllMavenEntries 可能会提取到（zip 内 maven/ 路径下）
        // 若 mavenPath 也缺失，启动时可能 NoClassDefFoundError
        NSLog(@"[ForgeDirect] Warning: install.filePath missing, universal jar will rely on extractAllMavenEntries or subsequent downloadMissingLibraries");
    }
    reportProgress(0.7, localize(@"i18n_str_1273", nil));

    // 老格式也需要解压 installer.jar 内 maven/ 下的所有依赖
    // 老版本 Forge 通常 libraries 是运行时从 Maven 下载的，但 installer.jar 内可能也带了一部分
    reportProgress(0.75, localize(@"i18n_str_1261", nil));
    [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];

    // 下载 versionInfo.libraries 中缺失的库（老格式也可能有 libraries 数组）
    NSArray *libs = mutableVersionInfo[@"libraries"];
    if ([libs isKindOfClass:[NSArray class]] && libs.count > 0) {
        reportProgress(0.8, localize(@"i18n_str_1262", nil));
        [self downloadMissingLibraries:libs librariesDir:librariesDir progress:progress baseProgress:0.8 progressSpan:0.1];
    }

    // Write version JSON
    NSLog(@"[ForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, localize(@"i18n_str_1263", nil));
    NSError *writeError = saveJSONToFile(mutableVersionInfo, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Version JSON written successfully");

    // 参照 FCL/HMCL：老格式 Forge 1.12- 的 versionInfo 也可能含 inheritsFrom，
    // 确保父版本（vanilla MC）的 version JSON 已存在。
    NSString *oldInheritsFrom = [mutableVersionInfo[@"inheritsFrom"] isKindOfClass:[NSString class]] ? mutableVersionInfo[@"inheritsFrom"] : nil;
    if (oldInheritsFrom.length > 0 && ![oldInheritsFrom isEqualToString:versionId]) {
        NSLog(@"[ForgeDirect] Checking parent vanilla version (old format): %@", oldInheritsFrom);
        NSError *parentError = nil;
        if (![self ensureParentVersionExists:oldInheritsFrom error:&parentError]) {
            NSLog(@"[ForgeDirect] Warning: parent version %@ auto-completion failed: %@", oldInheritsFrom, parentError.localizedDescription ?: @"Unknown error");
        } else {
            NSLog(@"[ForgeDirect] Parent vanilla version ensured: %@", oldInheritsFrom);
        }
    }

    NSLog(@"[ForgeDirect] installOldFormat completed");
    return YES;
}

#pragma mark - New format (Forge 1.13+)

+ (BOOL)installNewFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[ForgeDirect] installNewFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    // Read version.json
    NSLog(@"[ForgeDirect] Reading version.json");
    NSString *versionJsonEntry = installProfile[@"json"];
    if (!versionJsonEntry || ![versionJsonEntry isKindOfClass:[NSString class]]) {
        versionJsonEntry = @"version.json";
    }
    // version.json 路径可能以 "/" 开头，统一去掉
    if ([versionJsonEntry hasPrefix:@"/"]) {
        versionJsonEntry = [versionJsonEntry substringFromIndex:1];
    }
    NSLog(@"[ForgeDirect] version.json entry: %@", versionJsonEntry);

    NSData *versionData = [self dataFromZip:installerPath entry:versionJsonEntry error:error];
    if (!versionData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorMissingProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing version.json in installer"}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Successfully read version.json (%lu bytes)", (unsigned long)versionData.length);

    NSLog(@"[ForgeDirect] Parsing version.json");
    NSMutableDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:versionData
                                                                       options:NSJSONReadingMutableContainers
                                                                         error:nil];
    if (![versionJson isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse version.json"}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] version.json parsed successfully");

    // 注意：不再把 install_profile.libraries 合并进 version.json。
    // profile 的 libraries 是安装期 processor 工具链（binarypatcher、jarsplitter、
    // installertools、ASM 不同版本等）的依赖，仅供 ForgeProcessorExecutor 使用，
    // 全部下载到 libraries/ 后由 processor 消费；合并进 version.json 会污染
    // 运行期 classpath（与游戏依赖版本冲突），参照 ZL2/HMCL 均不合并。
    versionJson[@"id"] = versionId;

    // Prepare version directory
    // 版本 JSON 必须写入 POJAV_GAME_DIR/versions/（主目录），而非 profile gameDir。
    // Minecraft 启动器 Java 端固定从 POJAV_GAME_DIR/versions 加载版本 JSON。
    NSString *versionDir = [[self gameDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[ForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Step A: 解压 installer.jar 内 maven/ 下的所有依赖到 libraries 目录
    // 这是 installer 自带的依赖，必装
    NSLog(@"[ForgeDirect] Extracting all maven entries from installer jar");
    reportProgress(0.2, localize(@"i18n_str_1261", nil));
    NSUInteger extractedCount = [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];
    NSLog(@"[ForgeDirect] Extracted %lu maven entries", (unsigned long)extractedCount);

    // Step B: 下载 versionJson.libraries 中未在 installer.jar 内的库
    // version.json 的 libraries 包含 vanilla mc、modlauncher、bootstraplauncher 等
    // 这些不在 installer.jar 内，必须从 maven 下载
    NSLog(@"[ForgeDirect] Downloading missing libraries from maven");
    reportProgress(0.3, localize(@"i18n_str_1262", nil));
    NSArray *allLibraries = versionJson[@"libraries"];
    if ([allLibraries isKindOfClass:[NSArray class]]) {
        [self downloadMissingLibraries:allLibraries librariesDir:librariesDir progress:progress baseProgress:0.3 progressSpan:0.2];
    }

    // Step C: 下载 install_profile.libraries（processor 工具链依赖）
    // processor 的 jar 与 classpath 全部来自这份清单，必须先就位
    NSLog(@"[ForgeDirect] Downloading processor libraries");
    reportProgress(0.5, localize(@"i18n_str_1271", nil));
    NSArray *processorLibraries = installProfile[@"libraries"];
    if ([processorLibraries isKindOfClass:[NSArray class]] && processorLibraries.count > 0) {
        [self downloadMissingLibraries:processorLibraries librariesDir:librariesDir progress:progress baseProgress:0.5 progressSpan:0.05];
    }

    // Step D: 关键步骤——执行 install_profile processors 生成 PATCHED / MC_SRG 等 artifact
    // 参照 ZL2/HMCL ForgeNewInstallTask：processor 在本地 headless JVM 中执行，
    // 生成 FML 运行必需的 :client（PATCHED）、:srg（MC_SRG）、:extra（MC_EXTRA）jar。
    // 之前"直接从 maven 下载预打补丁 jar"的方案是错的——官方 maven 从未发布过
    // 这些 processor 输出产物（实测 client/universal classifier 均 404）。
    NSString *minecraftVersion = [versionJson[@"inheritsFrom"] isKindOfClass:[NSString class]] ? versionJson[@"inheritsFrom"] : nil;
    if (minecraftVersion.length == 0) {
        NSLog(@"[ForgeDirect] version.json missing inheritsFrom, cannot run processors");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1125", nil)}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Running processors for Minecraft %@", minecraftVersion);
    reportProgress(0.55, localize(@"i18n_str_1272", nil));
    if (![ForgeProcessorExecutor runProcessorsWithProfile:installProfile
                                             installerPath:installerPath
                                          minecraftVersion:minecraftVersion
                                                mainGameDir:[self gameDirectory]
                                               baseProgress:0.55
                                              progressSpan:0.3
                                                   progress:progress
                                                      error:error]) {
        NSLog(@"[ForgeDirect] Processor execution failed");
        return NO;
    }

    // Write version JSON
    NSLog(@"[ForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, localize(@"i18n_str_1263", nil));
    NSError *writeError = saveJSONToFile(versionJson, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Version JSON written successfully");

    // 参照 FCL/HMCL：确保父版本（vanilla MC）的 version JSON 已存在。
    // Forge 1.13+ 的 version.json 含 "inheritsFrom": "1.20.1" 等字段，启动时 Java 端会
    // 读取 versions/{inheritsFrom}/{inheritsFrom}.json 与 Forge 版本合并。
    // 若用户尚未安装原版，启动会因 FileNotFoundException 崩溃。
    // 这里在直装完成后自动补全缺失的父版本 JSON（仅下载 JSON，不下载原版客户端 jar，
    // 因为 iOS 启动器使用自有渲染管线，不需要原版 client.jar）。
    NSString *inheritsFrom = [versionJson[@"inheritsFrom"] isKindOfClass:[NSString class]] ? versionJson[@"inheritsFrom"] : nil;
    if (inheritsFrom.length > 0 && ![inheritsFrom isEqualToString:versionId]) {
        NSLog(@"[ForgeDirect] Checking parent vanilla version: %@", inheritsFrom);
        NSError *parentError = nil;
        if (![self ensureParentVersionExists:inheritsFrom error:&parentError]) {
            // 父版本缺失只发出警告，不阻断安装（用户可能后续手动安装原版）
            NSLog(@"[ForgeDirect] Warning: parent version %@ auto-completion failed: %@", inheritsFrom, parentError.localizedDescription ?: @"Unknown error");
        } else {
            NSLog(@"[ForgeDirect] Parent vanilla version ensured: %@", inheritsFrom);
        }
    }

NSLog(@"[ForgeDirect] installNewFormat completed");
    return YES;
}
#endif

#pragma mark - Maven entry Extraction

#if defined(AMETHYST_SERVER_RUNTIME)
+ (BOOL)ensureParentVersionExists:(NSString *)parentVersionId error:(NSError **)error {
    if (error) *error = nil;
    if (parentVersionId.length == 0) return YES;
    NSLog(@"[ForgeDirect][server] Parent version completion is handled by the server deployment context: %@", parentVersionId);
    return YES;
}
#endif

// 解压 installer.jar 内 maven/ 目录下所有文件到 libraries 目录
// 返回成功解压的文件数
+ (NSUInteger)extractAllMavenEntries:(NSString *)installerPath toLibrariesDir:(NSString *)librariesDir {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:installerPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to list filenames: %@", listError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSUInteger count = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in filenames) {
        // 只处理 maven/ 前缀的文件
        if (![name hasPrefix:@"maven/"]) continue;
        // 跳过目录条目（以 / 结尾），避免 extractDataFromFile 返回空数据产生误报日志
        if ([name hasSuffix:@"/"]) continue;

        // 转换为相对路径：去掉 "maven/" 前缀
        NSString *relativePath = [name substringFromIndex:@"maven/".length];
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];
        // 已存在的文件跳过，避免重复解压（重复安装场景）
        if ([fm fileExistsAtPath:destPath]) {
            count++;
            continue;
        }

        // 直接用已打开的 archive 实例提取，避免每个文件都重新打开 zip（性能优化）
        NSError *extractError = nil;
        NSData *data = [archive extractDataFromFile:name error:&extractError];
        if (!data || extractError) {
            NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to extract %@: %@", name, extractError.localizedDescription ?: @"unknown");
            continue;
        }

        // 创建目标目录（处理同名文件冲突）
        NSString *destDir = [destPath stringByDeletingLastPathComponent];
        [self ensureDirectoryExists:destDir error:nil];

        // 写入文件
        NSError *writeError = nil;
        if (![data writeToFile:destPath options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to write %@: %@", destPath, writeError.localizedDescription ?: @"unknown");
            continue;
        }
        count++;
    }
    return count;
}

#if !defined(AMETHYST_SERVER_RUNTIME)
#pragma mark - Library Download

// 下载 version.json.libraries 中尚未存在的库
// 优先用 library.downloads.artifact.url；若没有则用 maven 仓库拼接
+ (void)downloadMissingLibraries:(NSArray *)libraries
                   librariesDir:(NSString *)librariesDir
                       progress:(void (^)(double, NSString *))progress
                   baseProgress:(double)base
                  progressSpan:(double)span {
    NSUInteger total = libraries.count;
    if (total == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger downloaded = 0;
    NSUInteger skipped = 0;
    NSUInteger failed = 0;
    NSUInteger processed = 0;  // 已处理数（用于进度计算，包含成功/跳过/失败）
    NSMutableArray<NSString *> *criticalFailures = [NSMutableArray array];  // 关键库失败清单

    for (NSDictionary *library in libraries) {
        if (![library isKindOfClass:[NSDictionary class]]) continue;

        NSString *name = [library[@"name"] isKindOfClass:[NSString class]] ? library[@"name"] : nil;
        if (!name) continue;

        // 参照 FCL/HMCL：评估库的 OS rules，iOS 视为 osx。
        // 跳过仅在 Windows/Linux 上启用的库（如 natives-windows、twitch 平台库等），
        // 避免下载无用的二进制 natives 和潜在的 404 失败。
        id rulesObj = library[@"rules"];
        if ([rulesObj isKindOfClass:[NSArray class]] && [(NSArray *)rulesObj count] > 0) {
            if (![MinecraftResourceUtils evaluateRules:(NSArray *)rulesObj]) {
                NSLog(@"[ForgeDirect] Skipping library %@ (OS rules disallow osx/iOS)", name);
                skipped++;
                processed++;
                continue;
            }
        }

        // 解析目标路径
        NSString *relativePath = nil;
        NSDictionary *downloads = library[@"downloads"];
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            NSDictionary *artifact = downloads[@"artifact"];
            if ([artifact isKindOfClass:[NSDictionary class]]) {
                id artifactPathObj = artifact[@"path"];
                if ([artifactPathObj isKindOfClass:[NSString class]] && [(NSString *)artifactPathObj length] > 0) {
                    relativePath = (NSString *)artifactPathObj;
                }
            }
        }
        if (!relativePath) {
            relativePath = [self mavenPathToRelativePath:name];
        }
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];

        // 已存在则跳过
        if ([fm fileExistsAtPath:destPath]) {
            skipped++;
            processed++;
            continue;
        }

        // 拼 URL
        NSString *url = nil;
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            NSDictionary *artifact = downloads[@"artifact"];
            if ([artifact isKindOfClass:[NSDictionary class]]) {
                id urlObj = artifact[@"url"];
                if ([urlObj isKindOfClass:[NSString class]] && [(NSString *)urlObj length] > 0) {
                    url = (NSString *)urlObj;
                }
            }
        }
        if (!url) {
            // 用 maven 仓库拼接（Forge 库走 maven.minecraftforge.net，其他走 libraries.minecraft.net）
            url = [self buildMavenURLForLibrary:name relativePath:relativePath];
        }

        if (!url) {
            NSLog(@"[ForgeDirect] Cannot build URL for library %@, skipping", name);
            failed++;
            processed++;
            continue;
        }

        // 用 processed 计算进度（避免失败时进度停滞）
        if (progress) {
            double p = base + span * ((double)processed / (double)total);
            progress(p, [NSString stringWithFormat:localize(@"i18n_str_1127", nil), (unsigned long)(processed + 1), (unsigned long)total, name]);
        }

        NSError *downloadError = nil;
        if ([self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
            downloaded++;
            NSLog(@"[ForgeDirect] Downloaded library: %@", name);
        } else {
            // 主源失败：尝试 fallback 源（BMCLAPI ↔ 官方源）
            NSLog(@"[ForgeDirect] Primary source failed for %@, trying fallback: %@", name, downloadError.localizedDescription ?: @"unknown");
            NSString *fallbackURL = [self buildFallbackURLForLibrary:name relativePath:relativePath];
            if (fallbackURL && ![fallbackURL isEqualToString:url]) {
                NSError *fallbackError = nil;
                if ([self downloadFileFromURL:fallbackURL toPath:destPath error:&fallbackError]) {
                    downloaded++;
                    NSLog(@"[ForgeDirect] Downloaded library via fallback: %@", name);
                    processed++;
                    continue;
                }
                NSLog(@"[ForgeDirect] Fallback also failed for %@: %@", name, fallbackError.localizedDescription ?: @"unknown");
            }
            failed++;
            // 关键库（modlauncher、bootstraplauncher、mixin、asm、forge/neoforged 自家库）失败会启动崩溃，记录警告
            if ([self isCriticalLibrary:name]) {
                [criticalFailures addObject:name];
                NSLog(@"[ForgeDirect] Warning: critical library download failed (app will crash on launch): %@", name);
            } else {
                NSLog(@"[ForgeDirect] Failed to download library %@ (both sources failed)", name);
            }
            // 不中断流程，部分库可能不重要或可由游戏启动时再次下载
        }
        processed++;
    }

    NSLog(@"[ForgeDirect] Library download summary: downloaded=%lu, skipped=%lu, failed=%lu, total=%lu, criticalFailures=%lu",
          (unsigned long)downloaded, (unsigned long)skipped, (unsigned long)failed, (unsigned long)total, (unsigned long)criticalFailures.count);
    if (criticalFailures.count > 0) {
        NSLog(@"[ForgeDirect] Warning: critical library download failures: %@", criticalFailures);
    }
}

/// 判断是否为关键库（缺失会导致启动崩溃）
+ (BOOL)isCriticalLibrary:(NSString *)name {
    if (!name.length) return NO;
    // modlauncher、bootstraplauncher、mixin、asm、forge/neoforged 自家库、jimfs 等核心运行时依赖
    NSArray<NSString *> *criticalPrefixes = @[
        @"cpw.mods:modlauncher",
        @"net.minecraftforge.bootstraplauncher",
        @"net.minecraftforge:forge",
        @"net.minecraftforge:fmlloader",
        @"net.minecraftforge:javafmllanguage",
        @"net.minecraftforge:lowcodelanguage",
        @"net.minecraftforge:mclanguage",
        @"net.neoforged:forge",
        @"net.neoforged:neoforge",
        @"net.neoforged.fancymodloader",
        @"org.spongepowered:mixin",
        @"org.ow2.asm:asm",
        @"com.google.guava:guava",
        @"com.google.code.gson:gson",
        @"org.lwjgl:lwjgl",
        @"com.mojang:authlib",
        @"com.mojang:brigadier",
        @"com.mojang:datafixerupper",
        @"com.mojang:minecraft"
    ];
    for (NSString *prefix in criticalPrefixes) {
        if ([name hasPrefix:prefix]) return YES;
    }
    return NO;
}

// 为 library 构建 maven URL
// 优化路由：根据 groupId 精确匹配到正确的 maven 仓库，避免 404
+ (NSString *)buildMavenURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // Forge 自家库走 maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // NeoForge 自家库走 maven.neoforged.net
    if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
    }

    // cpw.mods:modlauncher 是 Forge 1.13+ 核心依赖，主源是 Forge maven
    if ([name hasPrefix:@"cpw.mods:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // SpongePowered (mixin、asm 等) 走 repo.spongepowered.org
    if ([name hasPrefix:@"org.spongepowered:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
    }

    // oceanlabs (mcp_config、mcp_mappings 等) 走 maven.minecraftforge.net（Forge 镜像了这些）
    if ([name hasPrefix:@"de.oceanlabs.mcp:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // asm (ow2 asm) 走 maven.minecraftforge.net（Forge 镜像了 asm）
    if ([name hasPrefix:@"org.ow2.asm:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // MojoHaus (bootstraplauncher、installertools 等) 优先走 maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge.installertools:"] ||
        [name hasPrefix:@"net.minecraftforge.bootstraplauncher:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // JitPack (部分 modlauncher 依赖)
    if ([name hasPrefix:@"com.machinezoo.noexception:"] ||
        [name hasPrefix:@"org.codehaus.mojo:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // 其他库（Mojang、lwjgl、gson 等）走 libraries.minecraft.net（BMCLAPI 镜像）
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
    }
    return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
}

/// 构建 fallback URL（当主源失败时切换到 BMCLAPI 镜像，或反之）
+ (NSString *)buildFallbackURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // 主源是 BMCLAPI 时，fallback 到官方源；主源是官方源时，fallback 到 BMCLAPI
    if (useBMCLAPI) {
        // 从 BMCLAPI 失败，尝试官方源
        if ([name hasPrefix:@"net.minecraftforge:"] || [name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"] || [name hasPrefix:@"cpw.mods:"]) {
            return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
        }
        if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."]) {
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
        }
        if ([name hasPrefix:@"org.spongepowered:"]) {
            return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
    }
    // 从官方源失败，尝试 BMCLAPI 镜像
    return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
}

#else
#pragma mark - ServerRuntime Library Download

+ (BOOL)downloadMissingLibraries:(NSArray *)libraries
                   librariesDir:(NSString *)librariesDir
                       progress:(void (^)(double, NSString *))progress
                   baseProgress:(double)base
                  progressSpan:(double)span
                          error:(NSError **)error {
    if (error) *error = nil;
    NSUInteger total = libraries.count;
    if (total == 0) return YES;

    NSUInteger processed = 0;
    for (id item in libraries) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            processed++;
            continue;
        }
        NSDictionary *library = (NSDictionary *)item;
        NSString *name = [library[@"name"] isKindOfClass:[NSString class]] ? library[@"name"] : nil;
        NSArray *rules = [library[@"rules"] isKindOfClass:[NSArray class]] ? library[@"rules"] : nil;
        if (rules.count > 0) {
            BOOL allowed = NO;
            for (id ruleItem in rules) {
                if (![ruleItem isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *rule = (NSDictionary *)ruleItem;
                NSDictionary *os = [rule[@"os"] isKindOfClass:[NSDictionary class]] ? rule[@"os"] : nil;
                NSDictionary *features = [rule[@"features"] isKindOfClass:[NSDictionary class]] ? rule[@"features"] : nil;
                NSString *osName = [os[@"name"] isKindOfClass:[NSString class]] ? os[@"name"] : nil;
                NSString *arch = [os[@"arch"] isKindOfClass:[NSString class]] ? os[@"arch"] : nil;
                BOOL matches = features.count == 0 &&
                    (osName.length == 0 || [osName isEqualToString:@"osx"]) &&
                    (arch.length == 0 || [arch isEqualToString:@"arm64"] || [arch isEqualToString:@"aarch64"]);
                if (matches) allowed = [rule[@"action"] isEqualToString:@"allow"];
            }
            if (!allowed) {
                processed++;
                continue;
            }
        }
        NSDictionary *downloads = [library[@"downloads"] isKindOfClass:[NSDictionary class]] ? library[@"downloads"] : nil;
        NSDictionary *artifact = [downloads[@"artifact"] isKindOfClass:[NSDictionary class]] ? downloads[@"artifact"] : nil;
        NSString *relativePath = [artifact[@"path"] isKindOfClass:[NSString class]] ? artifact[@"path"] : nil;
        if (relativePath.length == 0 && name.length > 0) relativePath = [self mavenPathToRelativePath:name];
        if (relativePath.length == 0) {
            if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                      code:ForgeDirectInstallerErrorInvalidProfile
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                                                 [NSString stringWithFormat:@"运行库缺少有效 Maven 坐标：%@", name ?: @"<unknown>"]}];
            return NO;
        }

        NSString *destination = [librariesDir stringByAppendingPathComponent:relativePath];
        if (![[NSFileManager defaultManager] fileExistsAtPath:destination]) {
            NSString *url = [artifact[@"url"] isKindOfClass:[NSString class]] ? artifact[@"url"] : nil;
            if (url.length == 0) {
                NSString *declaredBase = [library[@"url"] isKindOfClass:[NSString class]] ? library[@"url"] : nil;
                if (declaredBase.length > 0) {
                    url = [[declaredBase stringByAppendingString:[declaredBase hasSuffix:@"/"] ? @"" : @"/"]
                        stringByAppendingString:relativePath];
                }
            }
            if (url.length == 0 && name.length > 0) {
                NSString *lower = name.lowercaseString;
                NSString *baseURL = @"https://libraries.minecraft.net/";
                if ([lower hasPrefix:@"net.neoforged:"] || [lower hasPrefix:@"net.neoforged."]) {
                    baseURL = @"https://maven.neoforged.net/releases/";
                } else if ([lower hasPrefix:@"net.minecraftforge:"] || [lower hasPrefix:@"cpw.mods:"] ||
                           [lower hasPrefix:@"org.ow2.asm:"] || [lower hasPrefix:@"de.oceanlabs.mcp:"]) {
                    baseURL = @"https://maven.minecraftforge.net/";
                }
                url = [baseURL stringByAppendingString:relativePath];
            }
            if (url.length == 0) {
                if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                          code:ForgeDirectInstallerErrorInvalidProfile
                                                      userInfo:@{NSLocalizedDescriptionKey:
                                                                     [NSString stringWithFormat:@"运行库缺少下载地址：%@", name ?: relativePath]}];
                return NO;
            }
            NSError *downloadError = nil;
            if (![self downloadFileFromURL:url toPath:destination error:&downloadError]) {
                if (error) *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                          code:ForgeDirectInstallerErrorWriteFailed
                                                      userInfo:@{NSLocalizedDescriptionKey:
                                                                     [NSString stringWithFormat:@"运行库下载失败 %@：%@",
                                                                      name ?: relativePath,
                                                                      downloadError.localizedDescription ?: @"unknown"]}];
                return NO;
            }
        }

        processed++;
        if (progress) {
            double fraction = (double)processed / (double)total;
            progress(base + span * fraction,
                     [NSString stringWithFormat:@"正在准备运行库（%lu/%lu）",
                      (unsigned long)processed, (unsigned long)total]);
        }
    }
    return YES;
}
#endif

// 安全创建目录：若路径上存在同名普通文件（之前安装失败残留），先删除再创建。
// APFS 不允许同名文件和目录共存，直接 createDirectoryAtPath 会失败。
+ (BOOL)ensureDirectoryExists:(NSString *)path error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (isDir) return YES; // 目录已存在
        // 存在同名普通文件，删除它
        NSError *removeError = nil;
        if (![fm removeItemAtPath:path error:&removeError]) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorWriteFailed
                                         userInfo:@{NSLocalizedDescriptionKey:
#if defined(AMETHYST_SERVER_RUNTIME)
                                                        [NSString stringWithFormat:@"Failed to replace file with directory %@: %@", path, removeError.localizedDescription]
#else
                                                        [NSString stringWithFormat:localize(@"i18n_str_1128", nil), path, removeError.localizedDescription]
#endif
                                                    }];
            }
            return NO;
        }
    }
    NSError *createError = nil;
    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&createError];
    if (createError) {
        if (error) *error = createError;
        return NO;
    }
    return YES;
}

// 同步下载文件到指定路径（带 60 秒超时）
+ (BOOL)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destPath error:(NSError **)error {
    if (error) *error = nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid URL: %@", urlString]}];
        }
        return NO;
    }

    // 创建目标目录（处理同名文件冲突）
    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    if (![self ensureDirectoryExists:destDir error:&dirError]) {
        if (error) {
            *error = dirError ?: [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                   code:ForgeDirectInstallerErrorWriteFailed
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    // 使用 Amethyst 原有的同步 Foundation 下载路径。此方法由后台安装
    // 线程调用；不通过 NSURLSession completion block 跨线程回写 __block
    // NSData，避免 iOS 上下载失败分支出现失效对象指针。
    NSError *requestError = nil;
    NSData *resultData = [NSData dataWithContentsOfURL:url
                                               options:NSDataReadingMappedIfSafe
                                                 error:&requestError];
    if (requestError) {
        if (error) *error = requestError;
        return NO;
    }
    if (!resultData || resultData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Empty response: %@", urlString]}];
        }
        return NO;
    }

    BOOL written = [resultData writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        return NO;
    }

    NSLog(@"[ForgeDirect] Downloaded %@ (%lu bytes) -> %@", urlString.lastPathComponent ?: urlString, (unsigned long)resultData.length, destPath);
    return YES;
}

#pragma mark - ZIP / UnzipKit helpers

+ (NSData *)dataFromZip:(NSString *)zipPath entry:(NSString *)entryPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[ForgeDirect] Failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidArchive
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open installer archive: %@", openError.localizedDescription ?: @"unknown"]}];
        }
        return nil;
    }

    NSError *extractError = nil;
    NSData *result = [archive extractDataFromFile:entryPath error:&extractError];
    if (!result) {
        // 部分版本 entry 路径带前导 "/"，尝试兼容
        if ([entryPath hasPrefix:@"/"]) {
            NSString *altPath = [entryPath substringFromIndex:1];
            result = [archive extractDataFromFile:altPath error:&extractError];
        }
    }
    if (!result) {
        NSLog(@"[ForgeDirect] Failed to extract entry '%@': %@", entryPath, extractError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@: %@", entryPath, extractError.localizedDescription ?: @"not found"]}];
        }
        return nil;
    }

    NSLog(@"[ForgeDirect] Extracted entry '%@' (%lu bytes)", entryPath, (unsigned long)result.length);
    return result;
}

+ (BOOL)entryExists:(NSString *)zipPath entry:(NSString *)entryPath {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&openError];
    if (!archive || openError) {
        return NO;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        return NO;
    }

    for (NSString *name in filenames) {
        if ([name isEqualToString:entryPath]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)extractFile:(NSString *)zipPath entry:(NSString *)entryPath to:(NSString *)destPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    NSData *data = [self dataFromZip:zipPath entry:entryPath error:error];
    if (!data) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@ from installer", entryPath]}];
        }
        return NO;
    }

    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&dirError];
    if (dirError) {
        NSLog(@"[ForgeDirect] Failed to create directory '%@': %@", destDir, dirError.localizedDescription);
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        NSLog(@"[ForgeDirect] Failed to write file '%@'", destPath);
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %@", destPath]}];
        }
        return NO;
    }

    NSLog(@"[ForgeDirect] Written file '%@' (%lu bytes)", destPath, (unsigned long)data.length);
    return YES;
}

#pragma mark - Maven path utilities

+ (NSString *)serverArgumentsFileForProfile:(NSDictionary *)profile
                                     version:(NSDictionary *)version
                                librariesDir:(NSString *)librariesDir {
    NSMutableOrderedSet<NSString *> *coordinates = [NSMutableOrderedSet orderedSet];
    NSString *profilePath = [profile[@"path"] isKindOfClass:[NSString class]] ? profile[@"path"] : nil;
    if (profilePath.length > 0) [coordinates addObject:profilePath];

    for (id collection in @[version[@"libraries"] ?: @[], profile[@"libraries"] ?: @[]]) {
        if (![collection isKindOfClass:[NSArray class]]) continue;
        for (id item in (NSArray *)collection) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
            if (name.length > 0) [coordinates addObject:name];
        }
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *coordinate in coordinates) {
        NSString *lower = coordinate.lowercaseString;
        BOOL isForge = [lower hasPrefix:@"net.minecraftforge:forge:"];
        BOOL isNeoForge = [lower hasPrefix:@"net.neoforged:neoforge:"] ||
            [lower hasPrefix:@"net.neoforged:forge:"];
        if (!isForge && !isNeoForge) continue;

        NSString *artifactPath = [self mavenPathToRelativePath:coordinate];
        NSString *candidate = [librariesDir stringByAppendingPathComponent:
            [[artifactPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"unix_args.txt"]];
        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:candidate isDirectory:&isDirectory] && !isDirectory) {
            return [candidate stringByStandardizingPath];
        }
    }
    return nil;
}

+ (NSString *)mavenPathToRelativePath:(NSString *)mavenPath {
    // Format: groupId:artifactId:version[:classifier][@extension]
    NSArray *parts = [mavenPath componentsSeparatedByString:@":"];
    if (parts.count < 3) {
        return mavenPath;
    }

    NSString *groupId = parts[0];
    NSString *artifactId = parts[1];
    NSString *version = parts[2];
    NSString *classifier = (parts.count > 3) ? parts[3] : nil;
    NSString *extension = @"jar";
    NSRange classifierExtension = classifier.length > 0
        ? [classifier rangeOfString:@"@"]
        : NSMakeRange(NSNotFound, 0);
    if (classifierExtension.location != NSNotFound) {
        extension = [classifier substringFromIndex:NSMaxRange(classifierExtension)];
        classifier = [classifier substringToIndex:classifierExtension.location];
    } else {
        NSRange versionExtension = [version rangeOfString:@"@"];
        if (versionExtension.location != NSNotFound) {
            extension = [version substringFromIndex:NSMaxRange(versionExtension)];
            version = [version substringToIndex:versionExtension.location];
        }
    }

    NSString *groupPath = [groupId stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    NSString *jarName;
    if (classifier.length > 0) {
        jarName = [NSString stringWithFormat:@"%@-%@-%@.%@", artifactId, version, classifier, extension];
    } else {
        jarName = [NSString stringWithFormat:@"%@-%@.%@", artifactId, version, extension];
    }

    return [NSString stringWithFormat:@"%@/%@/%@/%@", groupPath, artifactId, version, jarName];
}

+ (NSString *)mavenNameToPath:(NSString *)name {
    // Same format as mavenPathToRelativePath
    return [self mavenPathToRelativePath:name];
}

@end

static char g_ais_forge_server_error[1024];

static void AISSetForgeServerError(NSString *message)
{
    const char *value = message.UTF8String ?: "Forge server installation failed.";
    snprintf(g_ais_forge_server_error, sizeof(g_ais_forge_server_error), "%s", value);
}

int ais_forge_server_install(const char *installerPath,
                             const char *instanceRoot,
                             const char *vanillaServerJar,
                             const char *javaHome,
                             char *resultBuffer,
                             size_t resultCapacity)
{
    g_ais_forge_server_error[0] = '\0';
    if (!installerPath || !instanceRoot || !vanillaServerJar || !resultBuffer || resultCapacity < 2) {
        AISSetForgeServerError(@"Invalid Forge server installer arguments.");
        return -1;
    }

    NSString *installer = [NSString stringWithUTF8String:installerPath];
    NSString *root = [NSString stringWithUTF8String:instanceRoot];
    NSString *vanilla = [NSString stringWithUTF8String:vanillaServerJar];
    NSString *java = [NSString stringWithUTF8String:javaHome ?: ""];
    NSError *error = nil;
    NSDictionary *result = nil;
    BOOL ok = [ForgeDirectInstaller installForgeServerFromInstaller:installer
                                                         instanceRoot:root
                                                    vanillaServerJar:vanilla
                                                          javaHome:java
                                                            progress:nil
                                                              result:&result
                                                               error:&error];
    if (!ok || !result) {
        AISSetForgeServerError(error.localizedDescription);
        return error.code != 0 ? (int)error.code : -2;
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
    if (!json || json.length + 1 > resultCapacity) {
        AISSetForgeServerError(error.localizedDescription ?: @"Forge server installer result is too large.");
        return -3;
    }
    memcpy(resultBuffer, json.bytes, json.length);
    resultBuffer[json.length] = '\0';
    return 0;
}

const char *ais_forge_server_last_error(void)
{
    return g_ais_forge_server_error;
}
