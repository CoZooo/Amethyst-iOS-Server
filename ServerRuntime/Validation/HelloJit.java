import java.lang.management.CompilationMXBean;
import java.lang.management.ManagementFactory;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public final class HelloJit {
    private static long mix(long value) {
        value ^= value << 13;
        value ^= value >>> 7;
        value ^= value << 17;
        return value * 0x9E3779B97F4A7C15L;
    }

    public static void main(String[] args) throws Exception {
        long checksum = 0x1234ABCD5678EF90L;
        for (int iteration = 0; iteration < 5_000_000; iteration++) {
            checksum = mix(checksum + iteration);
        }

        CompilationMXBean compiler = ManagementFactory.getCompilationMXBean();
        if (compiler == null || !compiler.isCompilationTimeMonitoringSupported()) {
            throw new IllegalStateException("HotSpot JIT compilation monitoring is unavailable");
        }

        String compilerName = compiler.getName();
        long compilationTime = compiler.getTotalCompilationTime();
        if (compilationTime <= 0) {
            throw new IllegalStateException("HotSpot reported no JIT compilation time");
        }

        String marker = String.format(
            "HELLO_JIT_OK checksum=%016x compiler=%s compilationTimeMs=%d",
            checksum,
            compilerName,
            compilationTime
        );
        System.out.println(marker);

        if (args.length > 0) {
            Files.writeString(Path.of(args[0]), marker + System.lineSeparator(), StandardCharsets.UTF_8);
        }
    }
}
