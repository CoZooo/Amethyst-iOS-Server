#import <Foundation/Foundation.h>

#include <stddef.h>

/// Adapts Amethyst's installer data model to an instance-scoped MSLX server.
/// The result is a compact JSON object written to resultBuffer.
int ais_forge_server_prepare(const char *installerPath,
                             const char *instanceRoot,
                             const char *vanillaServerJar,
                             char *resultBuffer,
                             size_t resultCapacity);

const char *ais_forge_server_last_error(void);
