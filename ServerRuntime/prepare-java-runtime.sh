#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
manifest="$script_dir/RuntimeManifests/java-21-ios-arm64.json"
artifacts_dir="$script_dir/artifacts"
cache_dir="$artifacts_dir/cache"
runtime_dir="$artifacts_dir/java-21-ios-arm64"

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$manifest"
}

archive_url=$(manifest_value archiveUrl)
archive_name=$(manifest_value archiveFileName)
archive_sha256=$(manifest_value archiveSha256)
archive_member=$(manifest_value archiveMember)
expected_java_version=$(manifest_value javaVersion)
expected_openjdk_revision=$(manifest_value openJdkRevision)
archive_path="$cache_dir/$archive_name"

mkdir -p "$cache_dir"

if [ ! -f "$archive_path" ]; then
    echo "正在下载 Java 21 iOS Runtime：$archive_url"
    partial_path="$archive_path.partial"
    rm -f "$partial_path"
    /usr/bin/curl --fail --location --retry 3 --output "$partial_path" "$archive_url"
    mv "$partial_path" "$archive_path"
fi

actual_sha256=$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')
if [ "$actual_sha256" != "$archive_sha256" ]; then
    echo "Runtime 校验失败：SHA-256 不匹配。" >&2
    echo "期望：$archive_sha256" >&2
    echo "实际：$actual_sha256" >&2
    echo "请删除缓存文件后重试：$archive_path" >&2
    exit 1
fi

work_dir=$(mktemp -d "$artifacts_dir/.prepare-java-21.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

/usr/bin/unzip -q "$archive_path" -d "$work_dir/archive"
inner_archive="$work_dir/archive/$archive_member"
if [ ! -f "$inner_archive" ]; then
    echo "Runtime 校验失败：外层 ZIP 中缺少 $archive_member" >&2
    exit 1
fi

if ! /usr/bin/tar -tf "$inner_archive" | /usr/bin/awk '
    /^\// || /(^|\/)\.\.($|\/)/ { invalid = 1 }
    END { exit invalid ? 1 : 0 }
'; then
    echo "Runtime 校验失败：归档中包含不安全路径。" >&2
    exit 1
fi

staged_runtime="$work_dir/runtime"
mkdir -p "$staged_runtime"
/usr/bin/tar -xJf "$inner_archive" -C "$staged_runtime"

# Microsoft.iOS BundleResource follows legal/ symlinks and then reports the
# resolved file more than once. Materialize only these license links so every
# module keeps its expected legal path inside the final App bundle.
/usr/bin/find "$staged_runtime/legal" -type l | while IFS= read -r legal_link
do
    materialized_link="$legal_link.materialized"
    /bin/cp -pL "$legal_link" "$materialized_link"
    rm -f "$legal_link"
    mv "$materialized_link" "$legal_link"
done

for required_path in \
    release \
    lib/libjli.dylib \
    lib/server/libjvm.dylib \
    legal/java.base/LICENSE \
    legal/java.base/ASSEMBLY_EXCEPTION
do
    if [ ! -f "$staged_runtime/$required_path" ]; then
        echo "Runtime 校验失败：缺少 $required_path" >&2
        exit 1
    fi
done

if ! /usr/bin/grep -Fq "JAVA_VERSION=\"$expected_java_version\"" "$staged_runtime/release"; then
    echo "Runtime 校验失败：release 中的 Java 版本不符合清单。" >&2
    exit 1
fi

release_revision=$(/usr/bin/sed -n 's/^SOURCE="\.:git:\([0-9a-f]*\)+"$/\1/p' "$staged_runtime/release")
case "$expected_openjdk_revision" in
    "$release_revision"*) ;;
    *)
        echo "Runtime 校验失败：release 中的 OpenJDK 源码指纹不符合清单。" >&2
        exit 1
        ;;
esac

legal_file_count=$(/usr/bin/find "$staged_runtime/legal" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')
if [ "$legal_file_count" -lt 1 ]; then
    echo "Runtime 校验失败：legal 目录为空。" >&2
    exit 1
fi

printf '%s\n' "$archive_sha256" > "$staged_runtime/.archive.sha256"
rm -rf "$runtime_dir"
mv "$staged_runtime" "$runtime_dir"

echo "Java 21 iOS Runtime 已准备完成：$runtime_dir"
echo "已保留 $legal_file_count 个 legal 文件；所有 dylib 尚需在 App 打包阶段按实际签名身份签名。"
