import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public final class ConsoleProbe {
    public static void main(String[] args) throws Exception {
        System.out.println("CONSOLE_PROBE_STDOUT_READY");
        System.err.println("CONSOLE_PROBE_STDERR_READY");

        BufferedReader input = new BufferedReader(
            new InputStreamReader(System.in, StandardCharsets.UTF_8)
        );
        String command;
        while ((command = input.readLine()) != null) {
            System.out.println("CONSOLE_PROBE_COMMAND=" + command);
            if (command.equalsIgnoreCase("stop")) {
                String marker = "CONSOLE_PROBE_OK";
                Files.writeString(
                    Path.of("console-probe-result.txt"),
                    marker + System.lineSeparator(),
                    StandardCharsets.UTF_8
                );
                System.out.println(marker);
                return;
            }
        }

        throw new IllegalStateException("stdin closed before the stop command");
    }
}
