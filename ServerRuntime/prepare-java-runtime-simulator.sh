#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
artifacts_dir="$script_dir/artifacts"
device_runtime="$artifacts_dir/java-21-ios-arm64"
simulator_runtime="$artifacts_dir/java-21-iossimulator-arm64"

if [ ! -f "$device_runtime/.archive.sha256" ] || \
   [ ! -f "$device_runtime/lib/libjli.dylib" ] || \
   [ ! -f "$device_runtime/lib/server/libjvm.dylib" ]; then
    echo "缺少已校验的设备 Runtime。请先运行 prepare-java-runtime.sh。" >&2
    exit 1
fi

for tool in xcrun vtool codesign file
do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "缺少 Simulator Runtime 转换工具：$tool" >&2
        exit 1
    fi
done

sdk_version=$(xcrun --sdk iphonesimulator --show-sdk-version)
work_dir=$(mktemp -d "$artifacts_dir/.prepare-java-simulator.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
staged_runtime="$work_dir/runtime"
mach_o_list="$work_dir/mach-o-files.txt"

/usr/bin/ditto "$device_runtime" "$staged_runtime"
: > "$mach_o_list"

/usr/bin/find "$staged_runtime" -type f | while IFS= read -r candidate
do
    if file "$candidate" | /usr/bin/grep -Fq "Mach-O 64-bit"; then
        printf '%s\n' "$candidate" >> "$mach_o_list"
    fi
done

mach_o_count=$(/usr/bin/wc -l < "$mach_o_list" | /usr/bin/tr -d ' ')
if [ "$mach_o_count" -lt 1 ]; then
    echo "转换失败：Runtime 中没有找到 Mach-O 文件。" >&2
    exit 1
fi

while IFS= read -r candidate
do
    converted="$candidate.simulator"
    vtool \
        -arch arm64 \
        -set-build-version 7 17.0 "$sdk_version" \
        -replace \
        -output "$converted" \
        "$candidate"
    mv "$converted" "$candidate"
    codesign --force --sign - "$candidate"

    if ! vtool -show-build "$candidate" | /usr/bin/grep -Fq "platform IOSSIMULATOR"; then
        echo "转换失败：$candidate 仍不是 IOSSIMULATOR Mach-O。" >&2
        exit 1
    fi
done < "$mach_o_list"

device_sha256=$(/usr/bin/tr -d '\r\n' < "$device_runtime/.archive.sha256")
{
    echo "deviceArchiveSha256=$device_sha256"
    echo "simulatorSdk=$sdk_version"
    echo "convertedMachOCount=$mach_o_count"
} > "$staged_runtime/.simulator-derived"

rm -rf "$simulator_runtime"
mv "$staged_runtime" "$simulator_runtime"

echo "Simulator Java Runtime 已准备完成：$simulator_runtime"
echo "已将 $mach_o_count 个 Mach-O 转换为 IOSSIMULATOR 并进行临时签名。"
echo "该派生 Runtime 仅用于 Apple Silicon 上的 Xcode Simulator，不能用于真机或发布。"
