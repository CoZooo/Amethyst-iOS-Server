#import "ForgeServerInstallerAdapter.h"

#import "external/UnzipKit/UZKArchive.h"

#include <stdio.h>
#include <string.h>

static char g_server_installer_error[512];

static void set_error(NSString *message)
{
    (void)snprintf(g_server_installer_error,
                   sizeof(g_server_installer_error),
                   "%s",
                   message.UTF8String ?: "Forge server installer failed.");
}

static NSString *safe_path(NSString *root, NSString *relative)
{
    if (relative.length == 0 || [relative hasPrefix:@"/"]) {
        return nil;
    }
    for (NSString *component in [relative pathComponents]) {
        if ([component isEqualToString:@".."]) {
            return nil;
        }
    }
    NSString *rootWithSlash = [[root stringByStandardizingPath] stringByAppendingString:@"/"];
    NSString *path = [[root stringByAppendingPathComponent:relative] stringByStandardizingPath];
    return [path hasPrefix:rootWithSlash] ? path : nil;
}

static NSString *maven_path(NSString *descriptor)
{
    NSArray<NSString *> *parts = [descriptor componentsSeparatedByString:@":"];
    if (parts.count < 3 || parts.count > 4) return nil;

    NSString *extension = @"jar";
    NSMutableArray<NSString *> *mutableParts = [parts mutableCopy];
    NSArray<NSString *> *extensionParts = [parts.lastObject componentsSeparatedByString:@"@"];
    if (extensionParts.count == 2) {
        extension = extensionParts[1];
        mutableParts[mutableParts.count - 1] = extensionParts[0];
    }

    NSString *group = [mutableParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    NSString *classifier = mutableParts.count == 4
        ? [NSString stringWithFormat:@"-%@", mutableParts[3]]
        : @"";
    return [NSString stringWithFormat:@"%@/%@/%@/%@-%@%@.%@",
            group,
            mutableParts[1],
            mutableParts[2],
            mutableParts[1],
            mutableParts[2],
            classifier,
            extension];
}

static NSString *replace_tokens(NSString *value, NSDictionary<NSString *, NSString *> *variables)
{
    NSMutableString *result = [NSMutableString string];
    NSUInteger index = 0;
    while (index < value.length) {
        unichar character = [value characterAtIndex:index];
        if (character == '\\') {
            if (++index >= value.length) return nil;
            [result appendFormat:@"%C", [value characterAtIndex:index]];
            index++;
            continue;
        }
        if (character != '{' && character != '\'') {
            [result appendFormat:@"%C", character];
            index++;
            continue;
        }

        unichar closing = character == '{' ? '}' : '\'';
        NSRange searchRange = NSMakeRange(index + 1, value.length - index - 1);
        NSRange closingRange = [value rangeOfString:[NSString stringWithFormat:@"%C", closing]
                                            options:0
                                              range:searchRange];
        if (closingRange.location == NSNotFound) return nil;
        NSString *key = [value substringWithRange:NSMakeRange(
            index + 1, closingRange.location - index - 1)];
        NSString *replacement = character == '\''
            ? key
            : variables[key];
        if (!replacement) return nil;
        [result appendString:replacement];
        index = closingRange.location + 1;
    }
    return result;
}

static NSData *read_entry(UZKArchive *archive, NSString *entryName, NSError **error)
{
    NSData *data = [archive extractDataFromFile:entryName error:error];
    if (!data && [entryName hasPrefix:@"/"]) {
        data = [archive extractDataFromFile:[entryName substringFromIndex:1] error:error];
    }
    return data;
}

static BOOL extract_entry(UZKArchive *archive,
                          NSString *entryName,
                          NSString *destination,
                          NSError **error)
{
    NSData *data = read_entry(archive, entryName, error);
    if (!data) return NO;
    NSString *directory = [destination stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:error]) {
        return NO;
    }
    return [data writeToFile:destination options:NSDataWritingAtomic error:error];
}

static void extract_embedded_maven(UZKArchive *archive, NSString *libraries)
{
    NSError *error = nil;
    NSArray<NSString *> *entries = [archive listFilenames:&error];
    if (error) return;
    for (NSString *entry in entries) {
        if (![entry hasPrefix:@"maven/"] || [entry hasSuffix:@"/"]) continue;
        NSString *relative = [entry substringFromIndex:6];
        NSString *destination = safe_path(libraries, relative);
        if (!destination || [[NSFileManager defaultManager] fileExistsAtPath:destination]) continue;
        (void)extract_entry(archive, entry, destination, nil);
    }
}

int ais_forge_server_prepare(const char *installerPath,
                             const char *instanceRoot,
                             const char *vanillaServerJar,
                             char *resultBuffer,
                             size_t resultCapacity)
{
    g_server_installer_error[0] = '\0';
    if (!installerPath || !instanceRoot || !vanillaServerJar ||
        !resultBuffer || resultCapacity == 0) {
        set_error(@"Invalid Forge server installer arguments.");
        return -1;
    }

    NSString *installer = [NSString stringWithUTF8String:installerPath];
    NSString *root = [[NSString stringWithUTF8String:instanceRoot] stringByStandardizingPath];
    NSString *vanilla = [NSString stringWithUTF8String:vanillaServerJar];
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:installer error:&error];
    if (!archive) {
        set_error(error.localizedDescription ?: @"Unable to open installer archive.");
        return -2;
    }

    NSData *profileData = read_entry(archive, @"install_profile.json", &error);
    NSDictionary *profile = profileData
        ? [NSJSONSerialization JSONObjectWithData:profileData options:0 error:&error]
        : nil;
    if (![profile isKindOfClass:[NSDictionary class]]) {
        set_error(error.localizedDescription ?: @"Invalid install_profile.json.");
        return -3;
    }

    NSString *versionEntry = [profile[@"json"] isKindOfClass:[NSString class]]
        ? profile[@"json"]
        : @"version.json";
    versionEntry = [versionEntry stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSData *versionData = read_entry(archive, versionEntry, &error);
    NSDictionary *version = versionData
        ? [NSJSONSerialization JSONObjectWithData:versionData options:0 error:&error]
        : nil;
    if (![version isKindOfClass:[NSDictionary class]]) {
        set_error(error.localizedDescription ?: @"Invalid version.json.");
        return -4;
    }

    NSString *minecraft = [version[@"inheritsFrom"] isKindOfClass:[NSString class]]
        ? version[@"inheritsFrom"]
        : ([profile[@"minecraft"] isKindOfClass:[NSString class]] ? profile[@"minecraft"] : nil);
    NSString *loader = [profile[@"version"] isKindOfClass:[NSString class]]
        ? profile[@"version"]
        : ([version[@"id"] isKindOfClass:[NSString class]] ? version[@"id"] : nil);
    if (minecraft.length == 0 || loader.length == 0) {
        set_error(@"Installer is missing Minecraft or loader version.");
        return -5;
    }

    NSString *libraries = [root stringByAppendingPathComponent:@"libraries"];
    extract_embedded_maven(archive, libraries);
    NSString *cache = [root stringByAppendingPathComponent:@".mslx/forge/native-cache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];

    NSMutableDictionary<NSString *, NSString *> *variables = [@{
        @"SIDE": @"server",
        @"ROOT": root,
        @"INSTALLER": installer,
        @"LIBRARY_DIR": libraries,
        @"MINECRAFT_VERSION": minecraft,
        @"MINECRAFT_JAR": vanilla
    } mutableCopy];

    NSDictionary *data = [profile[@"data"] isKindOfClass:[NSDictionary class]]
        ? profile[@"data"]
        : @{};
    for (NSString *key in data) {
        NSDictionary *item = [data[key] isKindOfClass:[NSDictionary class]] ? data[key] : nil;
        NSString *literal = [item[@"server"] isKindOfClass:[NSString class]]
            ? item[@"server"]
            : nil;
        if (!literal) continue;

        if ([literal hasPrefix:@"["] && [literal hasSuffix:@"]"]) {
            NSString *relative = maven_path([literal substringWithRange:
                NSMakeRange(1, literal.length - 2)]);
            if (!relative) {
                set_error(@"Invalid processor Maven coordinate.");
                return -6;
            }
            variables[key] = [libraries stringByAppendingPathComponent:relative];
            continue;
        }
        if (literal.length >= 2 && [literal hasPrefix:@"'"] && [literal hasSuffix:@"'"]) {
            variables[key] = [literal substringWithRange:
                NSMakeRange(1, literal.length - 2)];
            continue;
        }
        NSString *expanded = replace_tokens(literal, variables);
        if (!expanded) {
            set_error(@"Invalid server processor variable.");
            return -7;
        }
        NSString *entry = [expanded hasPrefix:@"/"]
            ? [expanded substringFromIndex:1]
            : expanded;
        if (entry.length > 0) {
            NSString *destination = safe_path(cache, entry.lastPathComponent);
            if (!destination || !extract_entry(archive, entry, destination, &error)) {
                set_error(error.localizedDescription ?: @"Unable to extract installer data.");
                return -8;
            }
            variables[key] = destination;
        }
    }

    NSString *serverJarPath = [profile[@"serverJarPath"] isKindOfClass:[NSString class]]
        ? profile[@"serverJarPath"]
        : nil;
    NSString *destination = vanilla;
    if (serverJarPath.length > 0) {
        NSString *expanded = replace_tokens(serverJarPath, variables);
        destination = safe_path(root, expanded);
        if (!destination || ![destination hasPrefix:
            [[root stringByStandardizingPath] stringByAppendingString:@"/"]]) {
            set_error(@"Installer serverJarPath escapes the instance directory.");
            return -9;
        }
        if (![destination isEqualToString:vanilla]) {
            [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
            if (![[NSFileManager defaultManager] copyItemAtPath:vanilla
                                                            toPath:destination
                                                               error:&error]) {
                set_error(error.localizedDescription ?: @"Unable to materialize server JAR.");
                return -10;
            }
        }
    }

    NSDictionary *result = @{
        @"kind": ([installer.lowercaseString containsString:@"neoforge"] ||
                  [loader.lowercaseString containsString:@"neoforge"])
            ? @"NeoForge"
            : @"Forge",
        @"minecraftVersion": minecraft,
        @"loaderVersion": loader,
        @"serverJarPath": destination
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
    if (!json || json.length + 1 > resultCapacity) {
        set_error(@"Forge server installer result is too large.");
        return -11;
    }
    memcpy(resultBuffer, json.bytes, json.length);
    resultBuffer[json.length] = '\0';
    return 0;
}

const char *ais_forge_server_last_error(void)
{
    return g_server_installer_error;
}
