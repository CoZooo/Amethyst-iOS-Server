#ifndef AMETHYST_IOS_SERVER_H
#define AMETHYST_IOS_SERVER_H

#include <stdint.h>

#if defined(__GNUC__)
#define AIS_EXPORT __attribute__((visibility("default")))
#else
#define AIS_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define AIS_ABI_VERSION 1u

typedef enum ais_result {
    AIS_OK = 0,
    AIS_ERROR_INVALID_ARGUMENT = -1,
    AIS_ERROR_JIT_UNAVAILABLE = -2,
    AIS_ERROR_RUNTIME_NOT_FOUND = -3,
    AIS_ERROR_DLOPEN_FAILED = -4,
    AIS_ERROR_JLI_SYMBOL_MISSING = -5,
    AIS_ERROR_INVALID_STATE = -6
} ais_result;

typedef enum ais_jit_status {
    AIS_JIT_UNKNOWN = 0,
    AIS_JIT_UNAVAILABLE = 1,
    AIS_JIT_AVAILABLE = 2
} ais_jit_status;

typedef enum ais_runtime_state {
    AIS_RUNTIME_UNINITIALIZED = 0,
    AIS_RUNTIME_JIT_REQUIRED = 1,
    AIS_RUNTIME_READY = 2,
    AIS_RUNTIME_FAILED = 3
} ais_runtime_state;

/** Returns the C ABI version implemented by this library. */
AIS_EXPORT uint32_t ais_abi_version(void);

/**
 * Probes whether this process can create an executable mapping.
 * This is a capability probe, not proof that HotSpot C1/C2 compiled a method.
 */
AIS_EXPORT ais_result ais_jit_probe(void);

/** Returns the most recent JIT capability result. */
AIS_EXPORT ais_jit_status ais_jit_get_status(void);

/** Returns non-zero when the process has the CS_DEBUGGED code-signing flag. */
AIS_EXPORT int ais_jit_is_debugged(void);

/**
 * Validates java_home, loads libjli with RTLD_GLOBAL, and resolves JLI_Launch.
 * JIT must be available before this function is called.
 */
AIS_EXPORT ais_result ais_runtime_initialize(const char *java_home);

/** Returns the current native runtime state. */
AIS_EXPORT ais_runtime_state ais_runtime_get_state(void);

/** Returns non-zero after libjli and JLI_Launch have been loaded. */
AIS_EXPORT int ais_runtime_jli_launch_available(void);

/**
 * Returns a process-owned UTF-8 diagnostic string.
 * The pointer remains valid until the next call that changes native state.
 */
AIS_EXPORT const char *ais_last_error(void);

#ifdef __cplusplus
}
#endif

#endif

