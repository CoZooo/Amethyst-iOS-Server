# Server Runtime

此目录提供用于 iOS/iPadOS 的小型 C ABI Runtime Bridge，以及可复现的 Java Runtime 准备和验证工具。

## 构建原生 Bridge

```sh
./build-ios.sh Debug
```

原生库输出到 `build-ios/Debug-iphoneos/libAmethystIOSServer.a`。

当前 C ABI 版本为 v6。宿主必须依次调用 `ais_jit_probe`、`ais_jit_prepare`、`ais_runtime_initialize` 和 `ais_java_start`。需要交互式 Console 时，还必须在启动 Java 前调用一次 `ais_console_prepare`。Bridge 在专用原生线程调用 `JLI_Launch`，并按“一次 App 进程只启动一次 JVM”约束管理状态；JVM 返回后必须重启宿主 App，不能直接再次创建 JVM。

iOS/iPadOS 26 及以上真机需要在进程启动时使用 `universal.js` 附加 debugger。`ais_jit_prepare` 会在加载 HotSpot 前完成旧版 `brk #0x69` 探测并注入 Universal 扩展；当前实现会在 HotSpot 建立 CodeCache 期间保持 debugger 连接，避免过早分离导致可执行页失效。宿主确认 JVM 已经可以执行应用代码后，必须调用一次幂等的 `ais_jit_release_debugger_after_jvm_ready`，否则 debugger 会继续拦截 HotSpot 信号。没有匹配脚本时会返回 `AIS_ERROR_JIT_PREPARATION_FAILED`，不会继续启动 JVM。宿主链接器必须保留并动态导出 `_DeviceHasTXM`、`_JIT26Detach` 和 `_JIT26PrepareRegion`。

Host 状态机测试：

```sh
cmake -S . -B build-host -DBUILD_TESTING=ON
cmake --build build-host
ctest --test-dir build-host --output-on-failure
```

Host 测试只验证 C ABI、参数所有权和状态转换，不能替代已签名真机上的 HotSpot/JIT 验证。

## Xcode Simulator

原始 Runtime 的 Mach-O 平台是 `IOS`，不能直接装入 Simulator。Apple Silicon 开发机可以显式生成一个仅供调试的派生版本：

```sh
./prepare-java-runtime.sh
./prepare-java-runtime-simulator.sh
./build-ios-simulator.sh Debug
```

转换脚本会复制已经过 SHA-256 校验的设备 Runtime，把副本中的 Mach-O `LC_BUILD_VERSION` 改为 `IOSSIMULATOR`，然后进行临时签名。原始设备 Runtime 不会被修改。

此路径可用于验证 C ABI、`JLI_Launch`、Java 逻辑和基础网络，但 Simulator 实际使用 Mac 的 CPU、内存和调度环境，不能验证真机 JIT 获取方式、entitlement、Jetsam、后台挂起、温控、耗电或真实性能。派生 Runtime 不能分发，也不能放入真机 App。

OpenJDK 的 Apple launcher 会从辅助线程再次调用进程的 `main`。本模块在 iOS 构建中提供入口路由：宿主构建必须把原有入口重命名为 `ais_host_main`，并把模块提供的 `_main` 加入动态导出符号。首次调用进入宿主运行时，Java 启动期间的第二次调用进入 `JLI_Launch`。如果宿主没有完成该重命名，链接阶段会因入口符号冲突而失败；如果没有导出 `_main`，`libjli` 将无法通过 `dlsym` 找到入口。

Apple launcher 在 Java 主类返回后会调用 `exit`。本模块只重绑定 `libjli` 自身导入的 `exit`，让 Apple 辅助线程退出并保留宿主进程，同时记录 `JLI_Launch` 的退出码。HotSpot 仍不支持在这个进程内安全地创建第二个 JVM，因此服务器停止后仍需重启宿主 App。

## Console 管道

`ais_console_prepare` 会把进程的 stdin、stdout 和 stderr 接到 Runtime 管理的 pipe。宿主通过 `ais_console_read` 非阻塞读取 stdout/stderr，通过 `ais_console_write` 写入 UTF-8 命令。重定向是进程级且不可撤销，必须在 `ais_java_start` 之前完成。

Console 闭环验证包使用同一条 `java -jar ... nogui` 启动路径，并同时验证 stdout、stderr、stdin、工作目录和退出码：

```sh
./build-console-probe.sh
java -jar artifacts/validation/console-probe.jar nogui
```

## 准备 Java 21 Runtime

```sh
./prepare-java-runtime.sh
```

脚本仅在显式执行时下载制品，并完成以下检查：

- 固定下载地址和 SHA-256；
- 阻止归档路径穿越；
- 验证 Java 版本和 OpenJDK 源码指纹；
- 验证 `libjli.dylib`、`libjvm.dylib` 和许可证文件；
- 完整保留 Runtime 的 `legal/` 目录。

为避免 Microsoft.iOS 在跟随 `legal/` 内的相对符号链接后把同一许可证识别为重复资源，准备脚本会把这些许可证链接实体化为普通文件；内容和原有模块目录结构不变。

准备后的目录是 `artifacts/java-21-ios-arm64`。该目录不会提交到 Git。

当前制品是 AngelaAuraMC 提供的第三方 iOS OpenJDK 构建，清单已锁定其字节级哈希，但不能等同于 Azul 官方发行版。OpenJDK Runtime 按 GPL-2.0 + Classpath Exception 分发，其随附的 `legal/` 内容必须保留。

Runtime 中的 Mach-O 动态库在装入设备 App 前仍需使用最终签名身份逐个签名。准备脚本不会伪造或替代 App 打包阶段的签名。

## 构建 HelloJit

```sh
./build-hello-jit.sh
java -Xlog:jit+compilation=debug -jar artifacts/validation/hello-jit.jar
```

输出必须包含 `HELLO_JIT_OK`、HotSpot 编译器名称和非负的累计编译时间。真机测试还应保存 `-Xlog:jit+compilation` 日志，确认 `HelloJit::mix` 被编译；仅通过可执行内存探测不能证明 HotSpot JIT 已经工作。
