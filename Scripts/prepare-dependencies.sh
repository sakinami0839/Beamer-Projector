#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

root="$PWD"
vendor="$root/.build/vendor"
deps="${BEAMER_DEPS_DIR:-$root/.build/XcodeDependencies}"
obs="${OBS_APP:-/Applications/OBS.app}"
framework="${SYPHON_FRAMEWORK:-$obs/Contents/Frameworks/Syphon.framework}"
qpdf="$vendor/qpdf"
jpeg_source="$vendor/jpeg"
syphon="$vendor/syphon"
jpeg="$deps/jpeg"
qpdf_build="$deps/qpdf"
stage="$deps/Frameworks/Syphon.framework"

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -f "$framework/Syphon" || ! -f "$framework/Resources/default.metallib" ]]; then
    printf 'error: Missing Metal-capable Syphon.framework. Install OBS Studio in /Applications or set SYPHON_FRAMEWORK.\n' >&2
    exit 1
fi
if ! lipo "$framework/Syphon" -verify_arch arm64 || ! lipo "$framework/Syphon" -verify_arch x86_64; then
    printf 'error: SYPHON_FRAMEWORK must contain arm64 and x86_64 slices.\n' >&2
    exit 1
fi

mkdir -p "$vendor" "$deps/Frameworks" "$deps/Notices"
# The command-line wrapper and Xcode may share this cache.
lock="$vendor/.prepare.lock"
while ! shlock -p "$$" -f "$lock"; do sleep 1; done
trap 'rm -f "$lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

download() {
    local archive="$1" destination="$2" url="$3" checksum="$4"
    if [[ -f "$destination/.beamer-source-sha256" &&
          "$(< "$destination/.beamer-source-sha256")" == "$checksum" ]]; then
        return
    fi
    if [[ ! -f "$archive" ]]; then
        curl -fsSL --retry 2 "$url" -o "$archive.part"
        mv "$archive.part" "$archive"
    fi
    printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c
    mkdir -p "$destination"
    tar -xzf "$archive" -C "$destination" --strip-components=1
    printf '%s\n' "$checksum" > "$destination/.beamer-source-sha256"
}

download "$vendor/qpdf.tar.gz" "$qpdf" https://codeload.github.com/qpdf/qpdf/tar.gz/refs/tags/v12.4.2 \
    88ddeb5f25c6e9156f3113fc3994d3a5e0cdfeee398cd09dd00fabc9dac9f573
download "$vendor/syphon.tar.gz" "$syphon" https://codeload.github.com/Syphon/Syphon-Framework/tar.gz/71351d4 \
    9a15697befea491762dfaed57d130508a81bc1362d0a70717ebb09f08652acac
download "$vendor/jpeg.tar.gz" "$jpeg_source" https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/refs/tags/3.1.2 \
    560f6338b547544c4f9721b18d8b87685d433ec78b3c644c70d77adad22c55e6

if [[ ! -f "$jpeg/lib/libjpeg.a" || ! -f "$qpdf_build/libqpdf/libqpdf.a" ]]; then
    for program in cmake ninja pkg-config; do
        if ! command -v "$program" >/dev/null; then
            printf 'error: Missing %s. Install build tools with brew install cmake ninja pkgconf.\n' "$program" >&2
            exit 1
        fi
    done
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    cmake_options=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$sdk"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}")
    if [[ ! -f "$jpeg/lib/libjpeg.a" ]]; then
        for architecture in arm64 x86_64; do
            slice="$deps/jpeg-$architecture"
            if [[ ! -f "$slice/lib/libjpeg.a" ]]; then
                cmake -S "$jpeg_source" -B "$deps/jpeg-build-$architecture" "${cmake_options[@]}" \
                    -DCMAKE_OSX_ARCHITECTURES="$architecture" -DCMAKE_INSTALL_PREFIX="$slice" -DCMAKE_INSTALL_LIBDIR=lib \
                    -DENABLE_SHARED=OFF -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
                cmake --build "$deps/jpeg-build-$architecture" --parallel 8
                cmake --install "$deps/jpeg-build-$architecture"
            fi
        done
        # libjpeg-turbo requires one architecture per CMake invocation.
        mkdir -p "$jpeg/lib/pkgconfig"
        ditto "$deps/jpeg-arm64/include" "$jpeg/include"
        sed 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$deps/jpeg-arm64/lib/pkgconfig/libjpeg.pc" \
            > "$jpeg/lib/pkgconfig/libjpeg.pc"
        lipo -create "$deps/jpeg-arm64/lib/libjpeg.a" "$deps/jpeg-x86_64/lib/libjpeg.a" -output "$jpeg/lib/libjpeg.a.tmp"
        mv "$jpeg/lib/libjpeg.a.tmp" "$jpeg/lib/libjpeg.a"
    fi
    if [[ ! -f "$qpdf_build/libqpdf/libqpdf.a" ]]; then
        PKG_CONFIG_PATH="$jpeg/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
            cmake -S "$qpdf" -B "$qpdf_build" "${cmake_options[@]}" \
            -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
            -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_DOC=OFF \
            -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON -DSTATIC_JPEG=ON -DCMAKE_PREFIX_PATH="$jpeg"
        cmake --build "$qpdf_build" --target libqpdf --parallel 8
    fi
fi

copy_if_different() {
    if ! cmp -s "$1" "$2"; then cp "$1" "$2"; fi
}

if ! cmp -s "$framework/Syphon" "$stage/Syphon" ||
   ! cmp -s "$framework/Resources/default.metallib" "$stage/Resources/default.metallib"; then
    ditto "$framework" "$stage"
fi
versioned="$stage/Versions/Current"
mkdir -p "$versioned/Headers" "$versioned/Modules"
headers=(Syphon SyphonOpenGLServer SyphonServerBase SyphonServer SyphonOpenGLClient
    SyphonClientBase SyphonClient SyphonOpenGLImage SyphonImageBase SyphonImage SyphonServerDirectory
    SyphonSubclassing SyphonMetalClient)
for header in "${headers[@]}"; do
    copy_if_different "$syphon/$header.h" "$versioned/Headers/$header.h"
done
# The upstream header documents a nil result but declares the initializer as nonnullable.
if ! sed 's/- (id)initWithName:/- (nullable instancetype)initWithName:/' "$syphon/SyphonMetalServer.h" |
    cmp -s - "$versioned/Headers/SyphonMetalServer.h"; then
    sed 's/- (id)initWithName:/- (nullable instancetype)initWithName:/' "$syphon/SyphonMetalServer.h" \
        > "$versioned/Headers/SyphonMetalServer.h"
fi
copy_if_different "$syphon/Syphon.modulemap" "$versioned/Modules/module.modulemap"
[[ -L "$stage/Headers" ]] || ln -s Versions/Current/Headers "$stage/Headers"
[[ -L "$stage/Modules" ]] || ln -s Versions/Current/Modules "$stage/Modules"

copy_if_different "$syphon/License.txt" "$deps/Notices/Syphon-License.txt"
copy_if_different "$qpdf/LICENSE.txt" "$deps/Notices/qpdf-License.txt"
copy_if_different "$jpeg_source/LICENSE.md" "$deps/Notices/libjpeg-turbo-License.md"
copy_if_different "$jpeg_source/README.ijg" "$deps/Notices/libjpeg-README.ijg"
