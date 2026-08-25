#include "amethyst_ios_server.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IOS && !defined(AIS_TESTING)
#include <mach-o/dyld.h>
#include "fishhook.h"
#endif

#define AIS_CS_DEBUGGED 0x10000000u
#define AIS_CS_OPS_STATUS 0u
#define AIS_UNIVERSAL_LEGACY_SENTINEL ((uintptr_t)0x690000E0u)

#if !defined(AIS_TESTING)
static const char g_universal_jit_extension[] =
    "logLevel = LOG_INFO;\n"
    "let detachAfterFirstBr = false;\n"
    "legacyCommands[0x69] = function(brkResponse) {\n"
    "    x1 = x0;\n"
    "    x0 = 0;\n"
    "    JIT26PrepareRegion(brkResponse);\n"
    "    if (detachAfterFirstBr) { JIT26Detach(); }\n"
    "};\n"
    "commands[3] = function(brkResponse) {\n"
    "    detachAfterFirstBr = x0 != 0;\n"
    "    log(`JIT26SetDetachAfterFirstBr(${detachAfterFirstBr}) called`);\n"
    "};\n";
#endif

typedef int (*ais_csops_fn)(int pid, unsigned int operations, void *user_address, size_t user_size);
typedef int (*ais_jli_launch_fn)(
    int argc,
    char **argv,
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

typedef struct ais_launch_context {
    int argc;
    char **argv;
    ais_jli_launch_fn launch;
} ais_launch_context;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static ais_jit_status g_jit_status = AIS_JIT_UNKNOWN;
static ais_runtime_state g_runtime_state = AIS_RUNTIME_UNINITIALIZED;
static void *g_libjli_handle = NULL;
static ais_jli_launch_fn g_jli_launch = NULL;
static int g_jvm_started = 0;
static int g_java_exited = 0;
static int g_java_exit_code = 0;
static int g_universal_debugger_pending = 0;
static int g_universal_debugger_release_requested = 0;
static ais_jli_launch_fn g_jli_reentry_launch = NULL;
static int g_console_prepared = 0;
static int g_console_stdout_read = -1;
static int g_console_stderr_read = -1;
static int g_console_stdin_write = -1;
static char g_last_error[512] = "";

#if defined(__APPLE__) && TARGET_OS_IOS && !defined(AIS_TESTING)
static _Thread_local int g_is_jli_reentry_thread = 0;
static void (*g_original_libjli_exit)(int) = NULL;
#endif

#if defined(AIS_TESTING)
static int g_test_requires_universal_jit = 0;
static int g_test_is_debugged = 0;
static uintptr_t g_test_legacy_result = AIS_UNIVERSAL_LEGACY_SENTINEL;
static int g_test_script_sent = 0;
static int g_test_detach_configured = -1;
static int g_test_debugger_detach_request_count = 0;
#endif

static int ais_requires_universal_jit(void)
{
#if defined(AIS_TESTING)
    return g_test_requires_universal_jit;
#elif defined(__APPLE__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR
    if (__builtin_available(iOS 26.0, *)) {
        return 1;
    }
    return 0;
#else
    return 0;
#endif
}

#if defined(__APPLE__) && defined(__aarch64__) && !defined(AIS_TESTING)
__attribute__((visibility("default"), used, noinline, optnone, naked))
void JIT26Detach(void)
{
    __asm__(
        "mov x16, #0\n"
        "brk #0xf00d\n"
        "ret\n");
}

__attribute__((visibility("default"), used, noinline, optnone, naked))
void *JIT26PrepareRegion(
    void *address __attribute__((unused)),
    size_t length __attribute__((unused)))
{
    __asm__(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        "ret\n");
}

__attribute__((noinline, optnone, naked))
static void *ais_jit26_create_region_legacy(size_t length __attribute__((unused)))
{
    __asm__(
        "brk #0x69\n"
        "ret\n");
}

__attribute__((noinline, optnone, naked))
static void ais_jit26_send_script(
    const char *script __attribute__((unused)),
    size_t length __attribute__((unused)))
{
    __asm__(
        "mov x16, #2\n"
        "brk #0xf00d\n"
        "ret\n");
}

__attribute__((noinline, optnone, naked))
static void ais_jit26_set_detach_after_first_breakpoint(int enabled __attribute__((unused)))
{
    __asm__(
        "mov x16, #3\n"
        "brk #0xf00d\n"
        "ret\n");
}
#endif

__attribute__((visibility("default"), used)) bool DeviceHasTXM(void)
{
    return ais_requires_universal_jit() != 0;
}

static void *ais_run_legacy_jit_handshake(size_t length)
{
#if defined(AIS_TESTING)
    (void)length;
    return (void *)g_test_legacy_result;
#elif defined(__APPLE__) && defined(__aarch64__)
    return ais_jit26_create_region_legacy(length);
#else
    (void)length;
    return NULL;
#endif
}

static void ais_install_universal_jit_extension(void)
{
#if defined(AIS_TESTING)
    g_test_script_sent = 1;
#elif defined(__APPLE__) && defined(__aarch64__)
    ais_jit26_send_script(g_universal_jit_extension, strlen(g_universal_jit_extension));
#endif
}

static void ais_keep_debugger_attached_for_hotspot_setup(void)
{
#if defined(AIS_TESTING)
    g_test_detach_configured = 0;
#elif defined(__APPLE__) && defined(__aarch64__)
    /*
     * HotSpot creates its writable CodeCache alias after the debugger has
     * prepared the RX region. Detaching inside the legacy region handler is
     * therefore too early and iOS 27 may invalidate the executable pages.
     * Keep the debugger attached until the runtime can explicitly detach
     * after the allocator has finished initializing.
     */
    ais_jit26_set_detach_after_first_breakpoint(0);
#endif
}

static void ais_request_universal_debugger_detach(void)
{
#if defined(AIS_TESTING)
    ++g_test_debugger_detach_request_count;
#elif defined(__APPLE__) && defined(__aarch64__)
    JIT26Detach();
#endif
}

static int ais_is_universal_handshake_result(uintptr_t result)
{
    /*
     * StikDebug exposes the raw little-endian register bytes as 0x690000E0,
     * while JITserver may decode the same P0 payload as the numeric value
     * 0xE0000069. Some debugserver implementations only update w0 and leave
     * x0's upper 32 bits undefined, so the handshake ABI must only inspect
     * the low 32 bits.
     */
    const uint32_t handshake = (uint32_t)result;
    return handshake == (uint32_t)AIS_UNIVERSAL_LEGACY_SENTINEL || handshake == UINT32_C(0xE0000069);
}

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

static void ais_close_fd(int *descriptor)
{
    if (*descriptor >= 0) {
        (void)close(*descriptor);
        *descriptor = -1;
    }
}

static int ais_set_nonblocking(int descriptor)
{
    int flags = fcntl(descriptor, F_GETFL);
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0;
}

ais_result ais_console_prepare(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_console_prepared) {
        ais_set_error_locked(NULL);
        pthread_mutex_unlock(&g_lock);
        return AIS_OK;
    }
    if (g_jvm_started) {
        ais_set_error_locked("Console redirection must be prepared before Java starts.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }

    int stdout_pipe[2] = { -1, -1 };
    int stderr_pipe[2] = { -1, -1 };
    int stdin_pipe[2] = { -1, -1 };
    int saved_standard[3] = { -1, -1, -1 };
    const char *failed_operation = NULL;
    int failure_errno = 0;

    if (pipe(stdout_pipe) != 0) {
        failed_operation = "pipe(stdout)";
        goto fail;
    }
    if (pipe(stderr_pipe) != 0) {
        failed_operation = "pipe(stderr)";
        goto fail;
    }
    if (pipe(stdin_pipe) != 0) {
        failed_operation = "pipe(stdin)";
        goto fail;
    }

    saved_standard[0] = dup(STDIN_FILENO);
    saved_standard[1] = dup(STDOUT_FILENO);
    saved_standard[2] = dup(STDERR_FILENO);
    if (saved_standard[0] < 0 || saved_standard[1] < 0 || saved_standard[2] < 0) {
        failed_operation = "dup(stdio)";
        goto fail;
    }

    (void)fflush(NULL);
    if (dup2(stdin_pipe[0], STDIN_FILENO) < 0) {
        failed_operation = "dup2(stdin)";
        goto fail;
    }
    if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0) {
        failed_operation = "dup2(stdout)";
        goto fail;
    }
    if (dup2(stderr_pipe[1], STDERR_FILENO) < 0) {
        failed_operation = "dup2(stderr)";
        goto fail;
    }
    if (!ais_set_nonblocking(stdout_pipe[0]) || !ais_set_nonblocking(stderr_pipe[0])) {
        failed_operation = "fcntl(O_NONBLOCK)";
        goto fail;
    }
#if defined(F_SETNOSIGPIPE)
    if (fcntl(stdin_pipe[1], F_SETNOSIGPIPE, 1) != 0) {
        failed_operation = "fcntl(F_SETNOSIGPIPE)";
        goto fail;
    }
#endif

    g_console_stdout_read = stdout_pipe[0];
    stdout_pipe[0] = -1;
    g_console_stderr_read = stderr_pipe[0];
    stderr_pipe[0] = -1;
    g_console_stdin_write = stdin_pipe[1];
    stdin_pipe[1] = -1;
    g_console_prepared = 1;

    ais_close_fd(&stdout_pipe[1]);
    ais_close_fd(&stderr_pipe[1]);
    ais_close_fd(&stdin_pipe[0]);
    for (size_t index = 0; index < 3u; ++index) {
        ais_close_fd(&saved_standard[index]);
    }
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);
    return AIS_OK;

fail:
    failure_errno = errno;
    if (saved_standard[0] >= 0) {
        (void)dup2(saved_standard[0], STDIN_FILENO);
    }
    if (saved_standard[1] >= 0) {
        (void)dup2(saved_standard[1], STDOUT_FILENO);
    }
    if (saved_standard[2] >= 0) {
        (void)dup2(saved_standard[2], STDERR_FILENO);
    }
    ais_close_fd(&stdout_pipe[0]);
    ais_close_fd(&stdout_pipe[1]);
    ais_close_fd(&stderr_pipe[0]);
    ais_close_fd(&stderr_pipe[1]);
    ais_close_fd(&stdin_pipe[0]);
    ais_close_fd(&stdin_pipe[1]);
    for (size_t index = 0; index < 3u; ++index) {
        ais_close_fd(&saved_standard[index]);
    }
    (void)snprintf(
        g_last_error,
        sizeof(g_last_error),
        "%s failed: %s (%d)",
        failed_operation == NULL ? "console preparation" : failed_operation,
        strerror(failure_errno),
        failure_errno);
    pthread_mutex_unlock(&g_lock);
    return AIS_ERROR_CONSOLE_FAILED;
}

int ais_console_read(ais_console_stream stream, void *buffer, size_t capacity)
{
    if (buffer == NULL || capacity == 0 || capacity > (size_t)INT_MAX) {
        pthread_mutex_lock(&g_lock);
        ais_set_error_locked("Console read requires a non-empty destination buffer.");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    pthread_mutex_lock(&g_lock);
    int descriptor = stream == AIS_CONSOLE_STDOUT
        ? g_console_stdout_read
        : stream == AIS_CONSOLE_STDERR ? g_console_stderr_read : -1;
    int prepared = g_console_prepared;
    pthread_mutex_unlock(&g_lock);
    if (!prepared || descriptor < 0) {
        pthread_mutex_lock(&g_lock);
        ais_set_error_locked(
            prepared ? "Unknown console output stream." : "Console redirection has not been prepared.");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    ssize_t count;
    do {
        count = read(descriptor, buffer, capacity);
    } while (count < 0 && errno == EINTR);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return 0;
    }
    if (count < 0) {
        pthread_mutex_lock(&g_lock);
        ais_set_errno_error_locked("read(console)");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    return (int)count;
}

ais_result ais_console_write(const void *bytes, size_t length)
{
    pthread_mutex_lock(&g_lock);
    int descriptor = g_console_stdin_write;
    int prepared = g_console_prepared;
    if (!prepared || descriptor < 0) {
        ais_set_error_locked("Console redirection has not been prepared.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    pthread_mutex_unlock(&g_lock);

    if (bytes == NULL || length == 0) {
        pthread_mutex_lock(&g_lock);
        ais_set_error_locked("Console write requires at least one byte.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_ARGUMENT;
    }

    const unsigned char *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = write(descriptor, cursor, remaining);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            pthread_mutex_lock(&g_lock);
            ais_set_errno_error_locked("write(console)");
            pthread_mutex_unlock(&g_lock);
            return AIS_ERROR_CONSOLE_FAILED;
        }
        cursor += count;
        remaining -= (size_t)count;
    }

    return AIS_OK;
}

#if defined(__APPLE__) && TARGET_OS_IOS && !defined(AIS_TESTING)
__attribute__((noreturn))
static void ais_libjli_exit(int exit_code)
{
    if (g_is_jli_reentry_thread) {
        pthread_exit((void *)(intptr_t)exit_code);
    }

    g_original_libjli_exit(exit_code);
    __builtin_unreachable();
}

static int ais_install_libjli_exit_hook(ais_jli_launch_fn launch)
{
    Dl_info image_info;
    if (dladdr((void *)(uintptr_t)launch, &image_info) == 0 || image_info.dli_fbase == NULL) {
        return 0;
    }

    const struct mach_header *header = image_info.dli_fbase;
    intptr_t slide = 0;
    int image_found = 0;
    uint32_t image_count = _dyld_image_count();
    for (uint32_t index = 0; index < image_count; ++index) {
        if (_dyld_get_image_header(index) == header) {
            slide = _dyld_get_image_vmaddr_slide(index);
            image_found = 1;
            break;
        }
    }
    if (!image_found) {
        return 0;
    }

    struct rebinding exit_rebinding = {
        .name = "exit",
        .replacement = (void *)(uintptr_t)ais_libjli_exit,
        .replaced = (void **)&g_original_libjli_exit
    };
    if (rebind_symbols_image((void *)header, slide, &exit_rebinding, 1) != 0) {
        return 0;
    }

    return g_original_libjli_exit != NULL;
}
#endif

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

static void ais_free_launch_context(ais_launch_context *context)
{
    if (context == NULL) {
        return;
    }

    if (context->argv != NULL) {
        for (int index = 0; index < context->argc; ++index) {
            free(context->argv[index]);
        }
        free(context->argv);
    }
    free(context);
}

static ais_launch_context *ais_copy_launch_context(
    int argc,
    const char *const *argv,
    ais_jli_launch_fn launch)
{
    ais_launch_context *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        return NULL;
    }

    context->argc = argc;
    context->launch = launch;
    context->argv = calloc((size_t)argc + 1u, sizeof(*context->argv));
    if (context->argv == NULL) {
        ais_free_launch_context(context);
        return NULL;
    }

    for (int index = 0; index < argc; ++index) {
        size_t length = strlen(argv[index]);
        context->argv[index] = malloc(length + 1u);
        if (context->argv[index] == NULL) {
            ais_free_launch_context(context);
            return NULL;
        }
        memcpy(context->argv[index], argv[index], length + 1u);
    }

    return context;
}

static void ais_record_java_exit(int exit_code)
{
    pthread_mutex_lock(&g_lock);
    if (!g_java_exited) {
        g_java_exit_code = exit_code;
        g_java_exited = 1;
        g_runtime_state = AIS_RUNTIME_RESTART_REQUIRED;
        ais_set_error_locked(NULL);
    }
    pthread_mutex_unlock(&g_lock);
}

static void *ais_java_launch_thread(void *argument)
{
    ais_launch_context *context = argument;

    pthread_mutex_lock(&g_lock);
    g_jli_reentry_launch = context->launch;
    g_runtime_state = AIS_RUNTIME_RUNNING;
    pthread_mutex_unlock(&g_lock);

    int exit_code = context->launch(
        context->argc,
        context->argv,
        0,
        NULL,
        0,
        NULL,
        "1.8.0-internal",
        "1.8",
        "java",
        "openjdk",
        0,
        1,
        0,
        1);

    ais_free_launch_context(context);

    ais_record_java_exit(exit_code);
    return NULL;
}

/*
 * OpenJDK's Apple launcher resolves and invokes the process main symbol from a
 * helper pthread. apple_jli_main.cpp calls these functions on that second
 * entry. They are intentionally not part of the public C ABI.
 */
int ais_jli_reentry_is_active(void)
{
    pthread_mutex_lock(&g_lock);
    int active = g_jli_reentry_launch != NULL;
    pthread_mutex_unlock(&g_lock);
    return active;
}

int ais_jli_reentry_launch(int argc, char **argv)
{
    pthread_mutex_lock(&g_lock);
    ais_jli_launch_fn launch = g_jli_reentry_launch;
    pthread_mutex_unlock(&g_lock);

    if (launch == NULL) {
        return EXIT_FAILURE;
    }

#if defined(__APPLE__) && TARGET_OS_IOS && !defined(AIS_TESTING)
    g_is_jli_reentry_thread = 1;
#endif

    int exit_code = launch(
        argc,
        argv,
        0,
        NULL,
        0,
        NULL,
        "1.8.0-internal",
        "1.8",
        "java",
        "openjdk",
        0,
        1,
        0,
        1);

    ais_record_java_exit(exit_code);

    pthread_mutex_lock(&g_lock);
    g_jli_reentry_launch = NULL;
    pthread_mutex_unlock(&g_lock);
    return exit_code;
}

uint32_t ais_abi_version(void)
{
    return AIS_ABI_VERSION;
}

ais_result ais_jit_probe(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_jvm_started) {
        ais_set_error_locked("JIT capability cannot be probed after the JVM launch has started.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    if (g_jit_status == AIS_JIT_PREPARED) {
        ais_set_error_locked(NULL);
        pthread_mutex_unlock(&g_lock);
        return AIS_OK;
    }
    pthread_mutex_unlock(&g_lock);

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
#if defined(AIS_TESTING)
    return g_test_is_debugged;
#else
    ais_csops_fn csops_function = (ais_csops_fn)dlsym(RTLD_DEFAULT, "csops");
    if (csops_function == NULL) {
        return 0;
    }

    uint32_t flags = 0;
    if (csops_function(getpid(), AIS_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return 0;
    }

    return (flags & AIS_CS_DEBUGGED) != 0u;
#endif
}

ais_result ais_jit_prepare(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_jvm_started) {
        ais_set_error_locked("JIT cannot be prepared after the JVM launch has started.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    if (g_jit_status == AIS_JIT_PREPARED) {
        ais_set_error_locked(NULL);
        pthread_mutex_unlock(&g_lock);
        return AIS_OK;
    }
    if (g_jit_status != AIS_JIT_AVAILABLE) {
        ais_set_error_locked("Call ais_jit_probe successfully before preparing JIT.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    pthread_mutex_unlock(&g_lock);

    if (!ais_requires_universal_jit()) {
        pthread_mutex_lock(&g_lock);
        g_jit_status = AIS_JIT_PREPARED;
        g_universal_debugger_pending = 0;
        g_universal_debugger_release_requested = 1;
        ais_set_error_locked(NULL);
        pthread_mutex_unlock(&g_lock);
        return AIS_OK;
    }

    if (!ais_jit_is_debugged()) {
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
        ais_set_error_locked(
            "Universal JIT preparation requires a debugger running universal.js.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_JIT_PREPARATION_FAILED;
    }

    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
        ais_set_error_locked("Unable to determine the page size for Universal JIT preparation.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_JIT_PREPARATION_FAILED;
    }

    void *handshake_result = ais_run_legacy_jit_handshake((size_t)page_size);
    uintptr_t handshake_value = (uintptr_t)handshake_result;
    if (!ais_is_universal_handshake_result(handshake_value)) {
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
        (void)snprintf(
            g_last_error,
            sizeof(g_last_error),
            "Universal JIT handshake failed (x0=0x%llx). Attach with universal.js before starting Java.",
            (unsigned long long)handshake_value);
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_JIT_PREPARATION_FAILED;
    }

    ais_install_universal_jit_extension();
    ais_keep_debugger_attached_for_hotspot_setup();

    if (setenv("XNU_HAS_TXM", "1", 1) != 0) {
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
        ais_set_errno_error_locked("setenv(XNU_HAS_TXM)");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_ENVIRONMENT_FAILED;
    }

    pthread_mutex_lock(&g_lock);
    g_jit_status = AIS_JIT_PREPARED;
    g_universal_debugger_pending = 1;
    g_universal_debugger_release_requested = 0;
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);
    return AIS_OK;
}

ais_result ais_jit_release_debugger_after_jvm_ready(void)
{
    int requires_universal_jit = ais_requires_universal_jit();

    pthread_mutex_lock(&g_lock);
    if (g_jit_status != AIS_JIT_PREPARED) {
        ais_set_error_locked("JIT must be prepared before releasing the Universal JIT debugger.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    if (!requires_universal_jit) {
        ais_set_error_locked(NULL);
        pthread_mutex_unlock(&g_lock);
        return AIS_OK;
    }
    if (!g_jvm_started ||
        (g_runtime_state != AIS_RUNTIME_RUNNING &&
         g_runtime_state != AIS_RUNTIME_RESTART_REQUIRED)) {
        ais_set_error_locked(
            "The Universal JIT debugger cannot be released before the host confirms that the JVM is ready.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    if (!g_universal_debugger_pending || g_universal_debugger_release_requested) {
        ais_set_error_locked(NULL);
        pthread_mutex_unlock(&g_lock);
        return AIS_OK;
    }

    g_universal_debugger_release_requested = 1;
    pthread_mutex_unlock(&g_lock);

    ais_request_universal_debugger_detach();

    pthread_mutex_lock(&g_lock);
    g_universal_debugger_pending = 0;
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);
    return AIS_OK;
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
    if (g_runtime_state == AIS_RUNTIME_READY || g_jvm_started) {
        ais_set_error_locked("The Java runtime is already initialized.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    if (g_jit_status != AIS_JIT_PREPARED) {
        g_runtime_state = AIS_RUNTIME_JIT_REQUIRED;
        ais_set_error_locked(
            "JIT is not prepared. Call ais_jit_probe and ais_jit_prepare before initialization.");
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

    if (setenv("JAVA_HOME", java_home, 1) != 0) {
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_FAILED;
        ais_set_errno_error_locked("setenv(JAVA_HOME)");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_ENVIRONMENT_FAILED;
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

#if defined(__APPLE__) && TARGET_OS_IOS && !defined(AIS_TESTING)
    if (!ais_install_libjli_exit_hook(launch)) {
        pthread_mutex_lock(&g_lock);
        g_runtime_state = AIS_RUNTIME_FAILED;
        ais_set_error_locked("Unable to isolate libjli exit() from the host process.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_DLOPEN_FAILED;
    }
#endif

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

ais_result ais_java_start(int argc, const char *const *argv)
{
    if (argc <= 0 || argv == NULL || argv[0] == NULL || argv[0][0] == '\0') {
        pthread_mutex_lock(&g_lock);
        ais_set_error_locked("argc must be positive and argv[0] must be a non-empty launcher name.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_ARGUMENT;
    }

    for (int index = 0; index < argc; ++index) {
        if (argv[index] == NULL) {
            pthread_mutex_lock(&g_lock);
            ais_set_error_locked("argv entries must not be null.");
            pthread_mutex_unlock(&g_lock);
            return AIS_ERROR_INVALID_ARGUMENT;
        }
    }

    pthread_mutex_lock(&g_lock);
    if (g_jvm_started) {
        ais_set_error_locked("A JVM has already been launched in this process; restart is required.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_JVM_ALREADY_USED;
    }
    if (g_runtime_state != AIS_RUNTIME_READY || g_jli_launch == NULL) {
        ais_set_error_locked("The Java runtime is not ready. Initialize libjli before starting Java.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    ais_jli_launch_fn launch = g_jli_launch;
    pthread_mutex_unlock(&g_lock);

    ais_launch_context *context = ais_copy_launch_context(argc, argv, launch);
    if (context == NULL) {
        pthread_mutex_lock(&g_lock);
        ais_set_error_locked("Unable to copy Java launch arguments.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_ALLOCATION_FAILED;
    }

    pthread_mutex_lock(&g_lock);
    if (g_jvm_started || g_runtime_state != AIS_RUNTIME_READY) {
        ais_set_error_locked("The Java runtime state changed before launch could begin.");
        pthread_mutex_unlock(&g_lock);
        ais_free_launch_context(context);
        return AIS_ERROR_INVALID_STATE;
    }
    g_jvm_started = 1;
    g_java_exited = 0;
    g_java_exit_code = 0;
    g_runtime_state = AIS_RUNTIME_STARTING;
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);

    pthread_t thread;
    int thread_result = pthread_create(&thread, NULL, ais_java_launch_thread, context);
    if (thread_result != 0) {
        ais_free_launch_context(context);
        pthread_mutex_lock(&g_lock);
        g_jvm_started = 0;
        g_runtime_state = AIS_RUNTIME_READY;
        (void)snprintf(
            g_last_error,
            sizeof(g_last_error),
            "pthread_create failed: %s (%d)",
            strerror(thread_result),
            thread_result);
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_THREAD_CREATE_FAILED;
    }

    (void)pthread_detach(thread);
    return AIS_OK;
}

int ais_java_is_running(void)
{
    pthread_mutex_lock(&g_lock);
    int running = g_runtime_state == AIS_RUNTIME_STARTING ||
                  g_runtime_state == AIS_RUNTIME_RUNNING;
    pthread_mutex_unlock(&g_lock);
    return running;
}

int ais_java_has_exited(void)
{
    pthread_mutex_lock(&g_lock);
    int exited = g_java_exited;
    pthread_mutex_unlock(&g_lock);
    return exited;
}

ais_result ais_java_get_exit_code(int *exit_code)
{
    if (exit_code == NULL) {
        pthread_mutex_lock(&g_lock);
        ais_set_error_locked("exit_code must not be null.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_ARGUMENT;
    }

    pthread_mutex_lock(&g_lock);
    if (!g_java_exited) {
        ais_set_error_locked("JLI_Launch has not returned yet.");
        pthread_mutex_unlock(&g_lock);
        return AIS_ERROR_INVALID_STATE;
    }
    *exit_code = g_java_exit_code;
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);
    return AIS_OK;
}

#if defined(AIS_TESTING)
void ais_test_reset(void)
{
    pthread_mutex_lock(&g_lock);
    g_jit_status = AIS_JIT_UNKNOWN;
    g_runtime_state = AIS_RUNTIME_UNINITIALIZED;
    g_libjli_handle = NULL;
    g_jli_launch = NULL;
    g_jvm_started = 0;
    g_java_exited = 0;
    g_java_exit_code = 0;
    g_universal_debugger_pending = 0;
    g_universal_debugger_release_requested = 0;
    g_jli_reentry_launch = NULL;
    g_test_requires_universal_jit = 0;
    g_test_is_debugged = 0;
    g_test_legacy_result = AIS_UNIVERSAL_LEGACY_SENTINEL;
    g_test_script_sent = 0;
    g_test_detach_configured = -1;
    g_test_debugger_detach_request_count = 0;
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);
}

void ais_test_set_runtime_ready(ais_jli_launch_fn launch)
{
    pthread_mutex_lock(&g_lock);
    g_jit_status = AIS_JIT_PREPARED;
    g_runtime_state = AIS_RUNTIME_READY;
    g_libjli_handle = (void *)(uintptr_t)1u;
    g_jli_launch = launch;
    g_jvm_started = 0;
    g_java_exited = 0;
    g_java_exit_code = 0;
    g_jli_reentry_launch = NULL;
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);
}

void ais_test_set_reentry_launch(ais_jli_launch_fn launch)
{
    pthread_mutex_lock(&g_lock);
    g_jli_reentry_launch = launch;
    g_jvm_started = 1;
    g_java_exited = 0;
    g_java_exit_code = 0;
    g_runtime_state = AIS_RUNTIME_RUNNING;
    ais_set_error_locked(NULL);
    pthread_mutex_unlock(&g_lock);
}

void ais_test_configure_universal_jit(
    int required,
    int debugged,
    uintptr_t handshake_result)
{
    g_test_requires_universal_jit = required;
    g_test_is_debugged = debugged;
    g_test_legacy_result = handshake_result;
}

int ais_test_universal_script_was_sent(void)
{
    return g_test_script_sent;
}

int ais_test_detach_after_first_breakpoint(void)
{
    return g_test_detach_configured;
}

int ais_test_debugger_detach_request_count(void)
{
    return g_test_debugger_detach_request_count;
}
#endif

const char *ais_last_error(void)
{
    return g_last_error;
}
