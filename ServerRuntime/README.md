# Server Runtime

此目录提供用于 iOS/iPadOS 的小型 C ABI Runtime Bridge，以及可复现的 Java Runtime 准备和验证工具。

## 构建原生 Bridge

```sh
./build-ios.sh Debug
```

原生库输出到 `build-ios/Debug-iphoneos/libAmethystIOSServer.a`。

当前 C ABI 版本为 v3。Bridge 在专用原生线程调用 `JLI_Launch`，并按“一次 App 进程只启动一次 JVM”约束管理状态；JVM 返回后必须重启宿主 App，不能直接再次创建 JVM。

Host 状态机测试：

```sh
cmake -S . -B build-host -DBUILD_TESTING=ON
cmake --build build-host
ctest --test-dir build-host --output-on-failure
```

Host 测试只验证 C ABI、参数所有权和状态转换，不能替代已签名真机上的 HotSpot/JIT 验证。

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
