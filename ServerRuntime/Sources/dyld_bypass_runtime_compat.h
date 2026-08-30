#pragma once

#import <Foundation/Foundation.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NSDebugLog(...) NSLog(__VA_ARGS__)

typedef enum {
    JIT_FLAG_IS_IOS_26 = 1 << 0,
    JIT_FLAG_FORCE_MIRRORED = 1 << 1,
    JIT_FLAG_HAS_TXM = 1 << 2,
} JITFlags;

extern uint64_t hwRedirectOrig[6];
extern uint64_t hwRedirectTarget[6];

bool DeviceHasTXM(void);
BOOL DeviceHasJITFlags(JITFlags flags);
void *JIT26PrepareRegion(void *address, size_t length);
void JIT26PrepareRegionForPatching(void *address, size_t length);
