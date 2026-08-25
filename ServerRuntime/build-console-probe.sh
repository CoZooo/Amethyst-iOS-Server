#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
artifacts_dir="$script_dir/artifacts/validation"
output_jar="$artifacts_dir/console-probe.jar"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/console-probe.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

if ! command -v javac >/dev/null 2>&1 || ! command -v jar >/dev/null 2>&1; then
    echo "需要 JDK 21 的 javac 和 jar 才能构建 ConsoleProbe。" >&2
    exit 1
fi

javac_version=$(javac -version 2>&1)
case "$javac_version" in
    "javac 21"*) ;;
    *)
        echo "当前 javac 不是 Java 21：$javac_version" >&2
        exit 1
        ;;
esac

mkdir -p "$work_dir/classes" "$artifacts_dir"
javac --release 21 -d "$work_dir/classes" "$script_dir/Validation/ConsoleProbe.java"
jar \
    --create \
    --file "$output_jar" \
    --date=2024-01-01T00:00:00Z \
    --main-class ConsoleProbe \
    -C "$work_dir/classes" .

echo "ConsoleProbe 验证包已生成：$output_jar"
