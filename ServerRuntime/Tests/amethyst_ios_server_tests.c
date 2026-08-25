#include "amethyst_ios_server.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef int (*ais_test_jli_launch_fn)(
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

void ais_test_reset(void);
void ais_test_set_runtime_ready(ais_test_jli_launch_fn launch);

static atomic_int g_fake_launch_release;
static int g_fake_argc;
static char g_fake_second_argument[64];

static void sleep_one_millisecond(void)
{
    const struct timespec duration = { .tv_sec = 0, .tv_nsec = 1000000L };
    (void)nanosleep(&duration, NULL);
}

static int fake_jli_launch(
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
    int ergo)
{
    (void)jargc;
    (void)jargv;
    (void)appclassc;
    (void)appclassv;
    (void)fullversion;
    (void)dotversion;
    (void)pname;
    (void)lname;
    (void)javaargs;
    (void)cpwildcard;
    (void)javaw;
    (void)ergo;

    while (atomic_load_explicit(&g_fake_launch_release, memory_order_acquire) == 0) {
        sleep_one_millisecond();
    }

    g_fake_argc = argc;
    (void)snprintf(
        g_fake_second_argument,
        sizeof(g_fake_second_argument),
        "%s",
        argc > 1 ? argv[1] : "");
    return 23;
}

static void wait_for_java_exit(void)
{
    for (int attempt = 0; attempt < 5000; ++attempt) {
        if (ais_java_has_exited()) {
            return;
        }
        sleep_one_millisecond();
    }

    assert(!"Timed out waiting for the fake JLI launcher to return.");
}

static void test_abi_version(void)
{
    assert(ais_abi_version() == AIS_ABI_VERSION);
}

static void test_initialize_rejects_empty_java_home(void)
{
    ais_test_reset();
    ais_result result = ais_runtime_initialize(NULL);
    assert(result == AIS_ERROR_INVALID_ARGUMENT);
    assert(ais_runtime_get_state() == AIS_RUNTIME_FAILED);
    assert(strstr(ais_last_error(), "java_home") != NULL);
}

static void test_jit_probe_reaches_a_terminal_status(void)
{
    ais_test_reset();
    ais_result result = ais_jit_probe();
    ais_jit_status status = ais_jit_get_status();

    assert(status == AIS_JIT_AVAILABLE || status == AIS_JIT_UNAVAILABLE);
    if (result == AIS_OK) {
        assert(status == AIS_JIT_AVAILABLE);
    } else {
        assert(result == AIS_ERROR_JIT_UNAVAILABLE);
        assert(status == AIS_JIT_UNAVAILABLE);
    }
}

static void test_missing_runtime_is_reported_after_successful_jit_probe(void)
{
    ais_test_reset();
    (void)ais_jit_probe();
    if (ais_jit_get_status() != AIS_JIT_AVAILABLE) {
        return;
    }

    ais_result result = ais_runtime_initialize("/definitely/not/a/java/home");
    assert(result == AIS_ERROR_RUNTIME_NOT_FOUND);
    assert(ais_runtime_get_state() == AIS_RUNTIME_FAILED);
    assert(strstr(ais_last_error(), "libjli.dylib") != NULL);
    assert(ais_runtime_jli_launch_available() == 0);
}

static void test_java_start_requires_initialized_runtime(void)
{
    ais_test_reset();
    const char *arguments[] = { "java", "-version" };
    const char *arguments_with_null[] = { "java", NULL };
    int exit_code = 0;

    assert(ais_java_start(0, NULL) == AIS_ERROR_INVALID_ARGUMENT);
    assert(ais_java_start(2, arguments_with_null) == AIS_ERROR_INVALID_ARGUMENT);
    assert(ais_java_start(2, arguments) == AIS_ERROR_INVALID_STATE);
    assert(ais_java_get_exit_code(&exit_code) == AIS_ERROR_INVALID_STATE);
    assert(ais_java_is_running() == 0);
    assert(ais_java_has_exited() == 0);
}

static void test_java_start_copies_arguments_and_enforces_one_shot_lifecycle(void)
{
    ais_test_reset();
    atomic_store_explicit(&g_fake_launch_release, 0, memory_order_release);
    g_fake_argc = 0;
    g_fake_second_argument[0] = '\0';
    ais_test_set_runtime_ready(fake_jli_launch);

    char launcher[] = "java";
    char version_argument[] = "-version";
    const char *arguments[] = { launcher, version_argument };

    assert(ais_java_start(2, arguments) == AIS_OK);
    assert(ais_java_is_running() != 0);
    assert(ais_java_start(2, arguments) == AIS_ERROR_JVM_ALREADY_USED);
    assert(ais_jit_probe() == AIS_ERROR_INVALID_STATE);
    assert(ais_runtime_initialize("/unused") == AIS_ERROR_INVALID_STATE);

    int exit_code = 0;
    assert(ais_java_get_exit_code(&exit_code) == AIS_ERROR_INVALID_STATE);

    (void)snprintf(version_argument, sizeof(version_argument), "%s", "changed");
    atomic_store_explicit(&g_fake_launch_release, 1, memory_order_release);
    wait_for_java_exit();

    assert(ais_java_is_running() == 0);
    assert(ais_runtime_get_state() == AIS_RUNTIME_RESTART_REQUIRED);
    assert(g_fake_argc == 2);
    assert(strcmp(g_fake_second_argument, "-version") == 0);

    assert(ais_java_get_exit_code(&exit_code) == AIS_OK);
    assert(exit_code == 23);
    assert(ais_java_start(2, arguments) == AIS_ERROR_JVM_ALREADY_USED);
}

int main(void)
{
    test_abi_version();
    test_initialize_rejects_empty_java_home();
    test_jit_probe_reaches_a_terminal_status();
    test_missing_runtime_is_reported_after_successful_jit_probe();
    test_java_start_requires_initialized_runtime();
    test_java_start_copies_arguments_and_enforces_one_shot_lifecycle();
    puts("Amethyst iOS Server runtime tests passed.");
    return 0;
}
