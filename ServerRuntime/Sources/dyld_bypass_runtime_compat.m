#import "dyld_bypass_runtime_compat.h"

#include <sys/mman.h>
#include <unistd.h>

uint64_t hwRedirectOrig[6];
uint64_t hwRedirectTarget[6];

static BOOL ais_can_create_rx_mapping(void)
{
    const size_t length = (size_t)getpagesize();
    void *mapping = mmap(
        NULL,
        length,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS,
        -1,
        0);
    if (mapping == MAP_FAILED) {
        return NO;
    }

    const BOOL available = mprotect(mapping, length, PROT_READ | PROT_EXEC) == 0;
    (void)munmap(mapping, length);
    return available;
}

static JITFlags ais_device_jit_flags(void)
{
    static JITFlags cachedFlags;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        JITFlags flags = 0;
        if (@available(iOS 26.0, *)) {
            flags |= JIT_FLAG_IS_IOS_26;
            if (!ais_can_create_rx_mapping()) {
                flags |= JIT_FLAG_FORCE_MIRRORED;
            }
        }
        if (DeviceHasTXM()) {
            flags |= JIT_FLAG_HAS_TXM;
        }
        cachedFlags = flags;
        NSLog(@"[DyldLVBypass] ServerRuntime JIT flags: 0x%X", flags);
    });
    return cachedFlags;
}

BOOL DeviceHasJITFlags(JITFlags flags)
{
    return (ais_device_jit_flags() & flags) == flags;
}
