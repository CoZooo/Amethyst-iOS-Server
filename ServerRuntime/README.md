# Amethyst iOS Server Runtime

This directory contains the server-oriented native runtime Module maintained
by the GPL-licensed **Amethyst iOS Server** project. It is derived from
Amethyst iOS Remastered while preserving upstream history and copyright
notices.

The external interface is the C ABI in
`Include/amethyst_ios_server.h`. Consumers must not depend on Amethyst
Objective-C classes, Pojav client launcher state, or private JIT implementation
details.

## Current milestone

The initial implementation deliberately stops at PoC Gate 1:

- stable ABI version and result/state enums;
- executable mapping capability probe;
- `CS_DEBUGGED` observation;
- Java 8 and Java 11+ `libjli.dylib` discovery;
- `RTLD_GLOBAL` loading and `JLI_Launch` symbol validation.

It does not start a JVM yet. Dedicated JVM threading, console pipes, one-shot
lifecycle enforcement, and `JLI_Launch` invocation belong to the next gate.

## Host verification

```sh
cmake -S ServerRuntime -B ServerRuntime/build-host
cmake --build ServerRuntime/build-host
ctest --test-dir ServerRuntime/build-host --output-on-failure
```

Host success proves the C interface and state transitions compile and run. It
does not prove iOS JIT readiness; that requires a signed host application on a
physical device.

Build the device ARM64 static library with:

```sh
ServerRuntime/build-ios.sh Debug
```

Consumer projects may invoke this script as part of their device build.
