//
//  ForgeDirectInstaller.h
//  Amethyst
//
//  Direct Forge installer (old + new format) based on FCL logic.
//

#import <Foundation/Foundation.h>

extern NSString *const ForgeDirectInstallerErrorDomain;

typedef NS_ENUM(NSInteger, ForgeDirectInstallerErrorCode) {
    ForgeDirectInstallerErrorInvalidArchive   = 1,
    ForgeDirectInstallerErrorMissingProfile   = 2,
    ForgeDirectInstallerErrorInvalidProfile   = 3,
    ForgeDirectInstallerErrorExtractionFailed = 4,
    ForgeDirectInstallerErrorWriteFailed      = 5,
    ForgeDirectInstallerErrorException        = 6
};

@interface ForgeDirectInstaller : NSObject

#if !defined(AMETHYST_SERVER_RUNTIME)
+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                            error:(NSError **)error;

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                          progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error;

// 整合包导入专用：支持自定义 gameDir（写入到 modpack 的 custom_gamedir 子目录）
// customGameDir 为 nil 时使用默认 POJAV_GAME_DIR；skipRegisterVersion=YES 时不写 profile（由调用方自行注册）
+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                    customGameDir:(nullable NSString *)customGameDir
              skipRegisterVersion:(BOOL)skipRegisterVersion
                         progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error;

+ (BOOL)isNewFormatInstaller:(NSString *)installerPath;
#endif

+ (BOOL)ensureParentVersionExists:(NSString *)minecraftVersion error:(NSError **)error;

/// Installs a Forge server directly into the supplied instance root using the
/// same installer implementation as the launcher. The caller supplies the
/// already downloaded vanilla server JAR.
+ (BOOL)installForgeServerFromInstaller:(NSString *)installerPath
                            instanceRoot:(NSString *)instanceRoot
                       vanillaServerJar:(NSString *)vanillaServerJar
                              javaHome:(NSString *)javaHome
                               progress:(void (^)(double progress, NSString *stageMessage))progress
                                 result:(NSDictionary **)result
                                  error:(NSError **)error;

@end
