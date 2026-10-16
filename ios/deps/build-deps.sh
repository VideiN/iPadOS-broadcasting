#!/usr/bin/env bash
# iOS arm64용 의존성 크로스컴파일 (macOS에서 실행)
#
# 사용법: ios/deps/build-deps.sh <iphoneos|iphonesimulator> [설치 경로]
#   기본 설치 경로: <저장소>/.deps/ios-<플랫폼>
#
# 버전은 OBS 32.2.2가 쓰는 obs-deps(2026-07-15)에 맞췄다.
# 이 파일이나 ios/config.env가 바뀌면 CI 캐시 키가 바뀌어 다시 빌드된다.
#
# FFmpeg는 libobs가 쓰는 부분(swscale, swresample, 이미지 디코딩)만 켠다.
# 비디오/오디오 코덱(h264, hevc, aac 등)은 넣지 않고 nonfree도 켜지 않는다.

set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../config.env
. "$root_dir/ios/config.env"

FFMPEG_VERSION=8.1.2
FFMPEG_SHA256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
JANSSON_VERSION=2.14.1
JANSSON_SHA256=6bd82d3043dadbcd58daaf903d974891128d22aab7dada5d399cb39094af49ce
SIMDE_VERSION=0.8.2
SIMDE_SHA256=ed2a3268658f2f2a9b5367628a85ccd4cf9516460ed8604eed369653d49b25fb
UTHASH_VERSION=2.3.0
UTHASH_SHA256=e10382ab75518bad8319eb922ad04f907cb20cccb451a3aa980c9d005e661acc
CMOCKA_VERSION=1.1.8
CMOCKA_SHA256=58435b558766d7f4c729ba163bdf3aec38bed3bc766dab684e3526ed0aa7c780
# RTMPS (obs-outputs). 릴리스 tarball에는 생성 파일과 framework가 들어 있어 GEN_FILES=OFF로 빌드된다.
MBEDTLS_VERSION=3.6.4
MBEDTLS_SHA256=ec35b18a6c593cf98c3e30db8b98ff93e8940a8c4e690e66b41dfc011d678110

platform=${1:?usage: build-deps.sh <iphoneos|iphonesimulator> [prefix]}
case "$platform" in
  iphoneos) target_triple="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" ;;
  iphonesimulator) target_triple="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" ;;
  *)
    echo "unknown platform: $platform" >&2
    exit 1
    ;;
esac

prefix=${2:-$root_dir/.deps/ios-$platform}
src_dir=$root_dir/.deps/src
work_dir=$root_dir/.deps/build-$platform
sdk_path=$(xcrun --sdk "$platform" --show-sdk-path)
cc=$(xcrun --sdk "$platform" --find clang)
jobs=$(sysctl -n hw.ncpu)

mkdir -p "$prefix/include" "$prefix/lib" "$src_dir" "$work_dir"

# fetch <파일 이름> <URL> <sha256>
fetch() {
  local file="$src_dir/$1"
  if [ ! -f "$file" ]; then
    curl -fsSL --retry 3 -o "$file.tmp" "$2"
    mv "$file.tmp" "$file"
  fi
  echo "$3  $file" | shasum -a 256 -c -
}

# unpack <압축 파일> <풀 디렉터리>
unpack() {
  rm -rf "$2"
  mkdir -p "$2"
  tar -xf "$1" -C "$2" --strip-components 1
}

# cmake_ios <소스 디렉터리> <빌드 디렉터리> [추가 인자...]
cmake_ios() {
  local src=$1 build=$2
  shift 2
  cmake -S "$src" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.10 \
    "$@"
  cmake --build "$build" --parallel "$jobs"
  cmake --install "$build"
}

echo "::group::simde $SIMDE_VERSION"
fetch "simde-$SIMDE_VERSION.tar.gz" \
  "https://github.com/simd-everywhere/simde/archive/refs/tags/v$SIMDE_VERSION.tar.gz" "$SIMDE_SHA256"
unpack "$src_dir/simde-$SIMDE_VERSION.tar.gz" "$work_dir/simde"
rm -rf "$prefix/include/simde"
cp -R "$work_dir/simde/simde" "$prefix/include/simde"
echo "::endgroup::"

echo "::group::uthash $UTHASH_VERSION"
fetch "uthash-$UTHASH_VERSION.tar.gz" \
  "https://github.com/troydhanson/uthash/archive/refs/tags/v$UTHASH_VERSION.tar.gz" "$UTHASH_SHA256"
unpack "$src_dir/uthash-$UTHASH_VERSION.tar.gz" "$work_dir/uthash"
cp "$work_dir/uthash/src/"*.h "$prefix/include/"
echo "::endgroup::"

echo "::group::jansson $JANSSON_VERSION"
fetch "jansson-$JANSSON_VERSION.tar.bz2" \
  "https://github.com/akheron/jansson/releases/download/v$JANSSON_VERSION/jansson-$JANSSON_VERSION.tar.bz2" \
  "$JANSSON_SHA256"
unpack "$src_dir/jansson-$JANSSON_VERSION.tar.bz2" "$work_dir/jansson"
cmake_ios "$work_dir/jansson" "$work_dir/jansson/build" \
  -DJANSSON_BUILD_SHARED_LIBS=OFF \
  -DJANSSON_BUILD_DOCS=OFF \
  -DJANSSON_EXAMPLES=OFF \
  -DJANSSON_WITHOUT_TESTS=ON
echo "::endgroup::"

echo "::group::mbedtls $MBEDTLS_VERSION"
fetch "mbedtls-$MBEDTLS_VERSION.tar.bz2" \
  "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/mbedtls-$MBEDTLS_VERSION.tar.bz2" \
  "$MBEDTLS_SHA256"
unpack "$src_dir/mbedtls-$MBEDTLS_VERSION.tar.bz2" "$work_dir/mbedtls"
# obs-deps와 같이 pthread 뮤텍스를 켠다 (obs-deps patches/mbedtls/0001-enable-posix-threading-support.patch)
sed -i '' \
  -e 's|^//#define MBEDTLS_THREADING_PTHREAD$|#define MBEDTLS_THREADING_PTHREAD|' \
  -e 's|^//#define MBEDTLS_THREADING_C$|#define MBEDTLS_THREADING_C|' \
  "$work_dir/mbedtls/include/mbedtls/mbedtls_config.h"
grep -q '^#define MBEDTLS_THREADING_C$' "$work_dir/mbedtls/include/mbedtls/mbedtls_config.h"
grep -q '^#define MBEDTLS_THREADING_PTHREAD$' "$work_dir/mbedtls/include/mbedtls/mbedtls_config.h"
cmake_ios "$work_dir/mbedtls" "$work_dir/mbedtls/build" \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
  -DENABLE_PROGRAMS=OFF \
  -DENABLE_TESTING=OFF \
  -DGEN_FILES=OFF
echo "::endgroup::"

echo "::group::cmocka $CMOCKA_VERSION (unit tests)"
fetch "cmocka-$CMOCKA_VERSION.tar.xz" \
  "https://cmocka.org/files/1.1/cmocka-$CMOCKA_VERSION.tar.xz" "$CMOCKA_SHA256"
unpack "$src_dir/cmocka-$CMOCKA_VERSION.tar.xz" "$work_dir/cmocka"
cmake_ios "$work_dir/cmocka" "$work_dir/cmocka/build" \
  -DBUILD_SHARED_LIBS=OFF \
  -DWITH_EXAMPLES=OFF \
  -DUNIT_TESTING=OFF
echo "::endgroup::"

echo "::group::FFmpeg $FFMPEG_VERSION"
fetch "ffmpeg-$FFMPEG_VERSION.tar.xz" \
  "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
unpack "$src_dir/ffmpeg-$FFMPEG_VERSION.tar.xz" "$work_dir/ffmpeg"
mkdir -p "$work_dir/ffmpeg/build"
(
  cd "$work_dir/ffmpeg/build"
  ../configure \
    --prefix="$prefix" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch=arm64 \
    --cc="$cc" \
    --host-cc=clang \
    --extra-cflags="-target $target_triple -isysroot $sdk_path" \
    --extra-ldflags="-target $target_triple -isysroot $sdk_path" \
    --enable-static \
    --disable-shared \
    --enable-pic \
    --disable-programs \
    --disable-doc \
    --disable-autodetect \
    --enable-pthreads \
    --enable-zlib \
    --disable-everything \
    --disable-avdevice \
    --disable-avfilter \
    --enable-protocol=file \
    --enable-demuxer=image2,image_png_pipe,image_jpeg_pipe,image_webp_pipe,image_bmp_pipe,image_gif_pipe,gif \
    --enable-decoder=png,mjpeg,gif,webp,bmp,targa
  make -j"$jobs"
  make install
)
echo "::endgroup::"

# 빌드 결과에 들어간 버전을 남겨 둔다 (Release에 소스를 첨부할 때 참고)
cat > "$prefix/VERSIONS" <<EOF
ffmpeg $FFMPEG_VERSION
jansson $JANSSON_VERSION
mbedtls $MBEDTLS_VERSION
simde $SIMDE_VERSION
uthash $UTHASH_VERSION
cmocka $CMOCKA_VERSION
EOF

echo "installed to $prefix"
