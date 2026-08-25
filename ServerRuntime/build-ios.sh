#!/bin/sh

set -eu

configuration="${1:-Debug}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$script_dir/build-ios"

cmake \
  -S "$script_dir" \
  -B "$build_dir" \
  -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DBUILD_TESTING=OFF

cmake --build "$build_dir" --config "$configuration" --parallel

