#include "amethyst_ios_server.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define AIS_CS_DEBUGGED 0x10000000u
#define AIS_CS_OPS_STATUS 0u

typedef int (*ais_csops_fn)(int pid, unsigned int operations, void *user_address, size_t user_size);
typedef int (*ais_jli_launch_fn)(
    int argc,
    const char **argv,
    int jargc,
    const char **jargv,
    int appclassc,
    const char **appclassv,
    const char *fullversion,
    const char *dotversion,
    const char *pname,
    const char *lname,
    unsigned char javaargs,
    unsigned char cpwildcard,
    unsigned char javaw,
    int ergo);

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static ais_jit_status g_jit_status = AIS_JIT_UNKNOWN;
static ais_runtime_state g_runtime_state = AIS_RUNTIME_UNINITIALIZED;
static void *g_libjli_handle = NULL;
static ais_jli_launch_fn g_jli_launch = NULL;
static char g_last_error[512] = "";

static void ais_set_error_locked(const char *message)
{
    if (message == NULL) {
        g_last_error[0] = '\0';
        return;
    }

    (void)snprintf(g_last_error, sizeof(g_last_error), "%s", message);
}

static void ais_set_errno_error_locked(const char *operation)
{
    (void)snprintf(
        g_last_error,
        sizeof(g_last_error),
        "%s failed: %s (%d)",
        operation,
        strerror(errno),
        errno);
}

static int ais_find_libjli(const char *java_home, char *destination, size_t destination_size)
{
    static const char *relative_paths[] = {
        "/lib/libjli.dylib",
        "/lib/jli/libjli.dylib"
    };

    for (size_t index = 0; index < sizeof(relative_paths) / sizeof(relative_paths[0]); ++index) {
        int length = snprintf(destination, destination_size, "%s%s", java_home, relative_paths[index]);
        if (length > 0 && (size_t)length < destination_size && access(destination, R_OK) == 0) {
            return 1;
        }
    }

    destination[0] = '\0';
    return 0;
}

uint32_t ais_abi_version(void)
{
    return AIS_ABI_VERSION;
}

ais_result ais_jit_probe(void)
{
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        pthread_mutex_lock(&g_lock);
        g_jit_status = AIS_JIT_UNAVAILABLE;
        g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
        ais_set_error_locked("Unable to determine the process page size.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_JIT_UNAVAILABLE;
    }

    void *mapping = mmap(
        NULL,
        (size_t)page_size,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS,
        -1,
        0);

    if (mapping == MAP_FAILED) {
        pthread_mutex_lock(&g_lock);
        g_jit_status = AIS_JIT_UNAVAILABLE;
        g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
        ais_set_errno_error_locked("mmap(RW)");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_JIT_UNAVAILABLE;
    }

    errno = 0;
    int protection_result = mprotect(mapping, (size_t)page_size, PROT_READ | PROT_EXEC);
    int protection_errno = errno;
    (void)munmap(mapping, (size_t)page_size);

    pthread_mutex_lock(&g_lock);
    if (protection_result == 0) {
        g_jit_status = AIS_JIT_AVAILABLE;
        if (g_runtime_state == AIS_RUNTIME_JIT_REQUIRED) {
            g_runtime_state = AIS_RUNTIME_UNINITIALIZED;
        }
        ais_set_error_locked(NULL);
        pthread_mutex_unlock(&g_lock);
        return AIS_OK;
    }

    errno = protection_errno;
    g_jit_status = AIS_JIT_UNAVAILABLE;
    g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
    ais_set_errno_error_locked("mprotect(RX)");
    pthread_mutex_unlock(&g_lock);
    return AIS_ERROR_JIT_UNAVAILABLE;
}

ais_jit_status ais_jit_get_status(void)
{
    pthread_mutex_lock(&g_lock);
    ais_jit_status status = g_jit_status;
    pthread_mutex_unlock(&g_lock);
    return status;
}

int ais_jit_is_debugged(void)
{
    ais_csops_fn csops_function = (ais_csops_fn)dlsym(RTLD_DEFAULT, "csops");
    if (csops_function == NULL) {
        return 0;
    }

    uint32_t flags = 0;
    if (csops_function(getpid(), AIS_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return 0;
    }

    return (flags & AIS_CS_DEBUGGED) != 0u;
}

ais_result ais_runtime_initialize(const char *java_home)
{
    if (java_home == NULL || java_home[0] == '\0') {
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_FAILED;
        ais_set_error_locked("java_home must be a non-empty UTF-8 path.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_ARGUMENT;
    }

    pthread_mutex_lock(&g_lock);
    if (g_runtime_state == AIS_RUNTIME_READY) {
        ais_set_error_locked("The Java runtime is already initialized.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    if (g_jit_status != AIS_JIT_AVAILABLE) {
        g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
        ais_set_error_locked("JIT executable mapping is not available. Call ais_jit_probe after enabling JIT.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_JIT_UNAVAILABLE;
    }
    pthread_mutex_unlock(&g_lock);

    char libjli_path[4096];
    if (!ais_find_libjli(java_home, libjli_path, sizeof(libjli_path))) {
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_FAILED;
        ais_set_error_locked("libjli.dylib was not found under java_home/lib or java_home/lib/jli.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_RUNTIME_NOT_FOUND;
    }

    void *handle = dlopen(libjli_path, RTLD_NOW | RTLD_GLOBAL);
    if (handle == NULL) {
        const char *dynamic_loader_error = dlerror();
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_FAILED;
        ais_set_error_locked(dynamic_loader_error == NULL ? "dlopen(libjli) failed." : dynamic_loader_error);
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_DLOPEN_FAILED;
    }

    ais_jli_launch_fn launch = (ais_jli_launch_fn)dlsym(handle, "JLI_Launch");
    if (launch == NULL) {
        const char *dynamic_loader_error = dlerror();
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_FAILED;
        ais_set_error_locked(dynamic_loader_error == NULL ? "JLI_Launch was not exported by libjli." : dynamic_loader_error);
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_JLI_SYMBOL_MISSING;
    }

    pthread_mutex_lock(&g_lock);
    g_libjli_handle = handle;
    g_jli_launch = launch;
    g_runtime_state = AIS_RUNTIME_READY;
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);
    return AIS_OK;
}

ais_runtime_state ais_runtime_get_state(void)
{
    pthread_mutex_lock(&g_lock);
    ais_runtime_state state = g_runtime_state;
    pthread_mutex_unlock(&g_lock);
    return state;
}

int ais_runtime_jli_launch_available(void)
{
    pthread_mutex_lock(&g_lock);
    int available = g_libjli_handle != NULL && g_jli_launch != NULL;
    pthread_mutex_unlock(&g_lock);
    return available;
}

const char *ais_last_error(void)
{
    return g_last_error;
}

