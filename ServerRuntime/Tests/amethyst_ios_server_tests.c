#include "amethyst_ios_server.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_abi_version(void)
{
    assert(ais_abi_version() == AIS_ABI_VERSION);
}

static void test_initialize_rejects_empty_java_home(void)
{
    ais_result result = ais_runtime_initialize(NULL);
    assert(result == AIS_ERROR_INVALID_ARGUMENT);
    assert(ais_runtime_get_state() == AIS_RUNTIME_FAILED);
    assert(strstr(ais_last_error(), "java_home") != NULL);
}

static void test_jit_probe_reaches_a_terminal_status(void)
{
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
    if (ais_jit_get_status() != AIS_JIT_AVAILABLE) {
        return;
    }

    ais_result result = ais_runtime_initialize("/definitely/not/a/java/home");
    assert(result == AIS_ERROR_RUNTIME_NOT_FOUND);
    assert(ais_runtime_get_state() == AIS_RUNTIME_FAILED);
    assert(strstr(ais_last_error(), "libjli.dylib") != NULL);
    assert(ais_runtime_jli_launch_available() == 0);
}

int main(void)
{
    test_abi_version();
    test_initialize_rejects_empty_java_home();
    test_jit_probe_reaches_a_terminal_status();
    test_missing_runtime_is_reported_after_successful_jit_probe();
    puts("Amethyst iOS Server runtime tests passed.");
    return 0;
}

