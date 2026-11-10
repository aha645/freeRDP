#!/usr/bin/env bash
# FreeRDP 3.24.2를 타깃별로 빌드합니다.
#   사용법: bash scripts/build.sh <타깃>
#
#   호스트(빌드하는 컴퓨터)        빌드 가능한 타깃
#   macOS (iMac)                  macos-arm64, macos-x86_64, windows-x86_64, android-arm64
#   Linux x86_64 (Windows의 WSL2) windows-x86_64, android-arm64, linux-x86_64, linux-arm64
#
#   데스크톱 타깃 → dist/<타깃>/sdl-freerdp(.exe)        (SDL3 클라이언트 실행 파일)
#   android-arm64 → dist/android-arm64/{include,lib}     (앱에 넣을 정적 라이브러리)
#
# 소스·도구 다운로드 → 압축 해제 → 의존성 빌드 → FreeRDP 빌드 → dist/<타깃>/ 생성
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"
FREERDP_VERSION=3.24.2
ANDROID_API=24

die() { echo "오류: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 호스트 확인
case "$(uname -s)-$(uname -m)" in
  Darwin-*)      HOST=macos; JOBS="${JOBS:-$(sysctl -n hw.ncpu)}" ;;
  Linux-x86_64)  HOST=linux; JOBS="${JOBS:-$(nproc)}" ;;
  *) die "지원하는 호스트: macOS, Linux x86_64(Windows의 WSL2 포함)" ;;
esac

USAGE="사용법: bash scripts/build.sh <macos-arm64|macos-x86_64|windows-x86_64|android-arm64|linux-x86_64|linux-arm64>"
case "$TARGET" in
  macos-arm64)    SSL_TARGET=darwin64-arm64-cc ;;
  macos-x86_64)   SSL_TARGET=darwin64-x86_64-cc ;;
  windows-x86_64) SSL_TARGET=mingw64 ;;
  android-arm64)  SSL_TARGET=android-arm64 ;;
  linux-x86_64)   SSL_TARGET=linux-x86_64 ;;
  linux-arm64)    SSL_TARGET=linux-aarch64 ;;
  *) die "$USAGE" ;;
esac
[[ "$TARGET" != macos-* || "$HOST" == macos ]] \
  || die "$TARGET 타깃은 macOS(iMac)에서만 빌드할 수 있습니다. Apple SDK가 macOS에만 있습니다."
[[ "$TARGET" != linux-* || "$HOST" == linux ]] \
  || die "$TARGET 타깃은 macOS에서 빌드할 수 없습니다. Linux 또는 Windows의 WSL2에서 빌드하세요."

# Linux 타깃은 Ubuntu 패키지(컴파일러, X11·PulseAudio 개발 파일)를 사용합니다.
if [[ "$TARGET" == linux-* ]]; then
  if [[ "$TARGET" == linux-arm64 ]]; then
    A=":arm64"; CROSS=aarch64-linux-gnu-
    export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
  else
    A=""; CROSS=""
  fi
  PKGS="libx11-dev$A libxext-dev$A libxrandr-dev$A libxcursor-dev$A libxi-dev$A libxfixes-dev$A libxss-dev$A libxkbcommon-dev$A libpulse-dev$A"
  missing=0
  command -v "${CROSS}gcc" >/dev/null && command -v "${CROSS}g++" >/dev/null || missing=1
  for tool in make perl pkg-config curl unzip file; do command -v "$tool" >/dev/null || missing=1; done
  pkg-config --exists x11 xext xrandr xcursor xi xfixes xscrnsaver xkbcommon libpulse 2>/dev/null || missing=1
  if (( missing )); then
    echo "필요한 Ubuntu 패키지가 없습니다. 아래 명령으로 설치한 뒤 다시 실행하세요." >&2
    if [[ "$TARGET" == linux-arm64 ]]; then
      cat >&2 <<'EOF'

  # (처음 한 번) arm64 패키지 저장소 추가 — README.md의 "linux-arm64 준비" 참고
  sudo dpkg --add-architecture arm64
EOF
      echo "  sudo apt-get update && sudo apt-get install -y build-essential perl pkg-config curl unzip file gcc-aarch64-linux-gnu g++-aarch64-linux-gnu $PKGS" >&2
    else
      echo "" >&2
      echo "  sudo apt-get update && sudo apt-get install -y build-essential perl pkg-config curl unzip file $PKGS" >&2
    fi
    exit 1
  fi
fi

# ---------------------------------------------------------------- 1) 다운로드 + 압축 해제
source "$ROOT/scripts/fetch.sh"
fetch_all "$HOST" "$TARGET"

# ---------------------------------------------------------------- 2) 도구
if [[ "$HOST" == macos ]]; then
  export PATH="$ROOT/tools/macos/cmake-3.31.6-macos-universal/CMake.app/Contents/bin:$ROOT/tools/macos/ninja-1.12.1:$PATH"
  command -v clang >/dev/null && command -v make >/dev/null \
    || die "Xcode Command Line Tools가 필요합니다: xcode-select --install"
else
  export PATH="$ROOT/tools/linux/cmake-3.31.6-linux-x86_64/bin:$ROOT/tools/linux/ninja-1.12.1:$PATH"
  command -v make >/dev/null && command -v perl >/dev/null && command -v cc >/dev/null \
    || die "빌드 도구가 필요합니다: sudo apt-get install -y build-essential perl curl unzip file"
fi

SRC="$ROOT/src"
WORK="$ROOT/build/$TARGET"     # 중간 산출물
DEPS="$WORK/deps"              # 정적 의존성 설치 위치
OUT="$ROOT/dist/$TARGET"       # 최종 결과물
mkdir -p "$WORK" "$DEPS"

CMAKE_ARGS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_PREFIX_PATH="$DEPS" -DCMAKE_FIND_ROOT_PATH="$DEPS")
SSL_ENV=()
FREERDP_EXTRA=()
EXE=sdl-freerdp

case "$TARGET" in
  macos-*)
    ARCH="${TARGET#macos-}"
    export MACOSX_DEPLOYMENT_TARGET=11.0
    CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH")
    [[ "$ARCH" == "$(uname -m)" ]] || CMAKE_ARGS+=(-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$ARCH")
    ;;

  windows-x86_64)
    # tools/windows-x86_64 의 llvm-mingw 크로스 컴파일러 (호스트별 배포판)
    MINGW="$(echo "$ROOT"/tools/windows-x86_64/llvm-mingw-20250528-ucrt-*/bin)"
    P="$MINGW/x86_64-w64-mingw32"
    cat >"$WORK/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $P-clang)
set(CMAKE_CXX_COMPILER $P-clang++)
set(CMAKE_RC_COMPILER $P-windres)
set(CMAKE_AR $P-ar)
set(CMAKE_RANLIB $P-ranlib)
set(CMAKE_C_COMPILER_AR $P-ar)
set(CMAKE_CXX_COMPILER_AR $P-ar)
set(CMAKE_C_COMPILER_RANLIB $P-ranlib)
set(CMAKE_CXX_COMPILER_RANLIB $P-ranlib)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
# mingw-w64에는 C11 <threads.h>가 없음 → FreeRDP가 __thread 를 사용하도록 함
set(CMAKE_C_FLAGS_INIT "-D__STDC_NO_THREADS__")
EOF
    CMAKE_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="$WORK/toolchain.cmake")
    SSL_ENV=(CC="$P-clang" AR="$P-ar" RANLIB="$P-ranlib" RC="$P-windres")
    EXE=sdl-freerdp.exe
    FREERDP_EXTRA=(-DUSE_UNWIND=OFF)   # unwind 백트레이스는 dlfcn.h(POSIX) 필요
    ;;

  android-arm64)
    # tools/android 의 Android NDK (호스트별 배포판)
    NDK="$ROOT/tools/android/android-ndk-r27c"
    NDK_HOST=linux-x86_64; [[ "$HOST" == macos ]] && NDK_HOST=darwin-x86_64
    export ANDROID_NDK_ROOT="$NDK"
    export PATH="$NDK/toolchains/llvm/prebuilt/$NDK_HOST/bin:$PATH"
    CMAKE_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$ANDROID_API)
    SSL_ENV=(CFLAGS="-D__ANDROID_API__=$ANDROID_API")
    # 화면은 앱(Flutter 텍스처)이 그리므로 SDL 클라이언트 없이 라이브러리만 빌드
    # 소리·마이크: OpenSL ES, MD4/MD5/RC4: FreeRDP 내장 구현 (공식 Android 빌드와 동일)
    # LTO 끔: 앱 빌드 시 다른 NDK 버전으로도 링크되도록 일반 기계어(.o)로 보관
    FREERDP_EXTRA=(-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
      -DWITH_CLIENT_SDL=OFF -DWITHOUT_FREERDP_3x_DEPRECATED=ON -DWITH_OPENSLES=ON
      -DWITH_MEDIACODEC=OFF -DWITH_INTERNAL_RC4=ON -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON)
    ;;

  linux-*)
    if [[ "$TARGET" == linux-arm64 ]]; then
      cat >"$WORK/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
      CMAKE_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="$WORK/toolchain.cmake")
      SSL_ENV=(CC=aarch64-linux-gnu-gcc AR=aarch64-linux-gnu-ar RANLIB=aarch64-linux-gnu-ranlib)
    fi
    # 화면: X11 (Wayland 데스크톱에서는 XWayland로 동작), 소리·마이크: PulseAudio
    FREERDP_EXTRA=(-DWITH_PULSE=ON -DWITH_WAYLAND=OFF -DWITH_LIBSYSTEMD=OFF)
    ;;
esac

# cmake_build <이름> <소스 폴더> <설치 위치> [추가 옵션...]
cmake_build() {
  local name="$1" src="$2" prefix="$3"; shift 3
  echo "=== $name ($TARGET) ==="
  cmake -S "$src" -B "$WORK/$name" "${CMAKE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="$prefix" "$@"
  cmake --build "$WORK/$name" --parallel "$JOBS"
  cmake --install "$WORK/$name"
}

# ---------------------------------------------------------------- 3) 의존성 (정적 라이브러리)
# 이미 설치되었으면 건너뜀
if [[ ! -f "$DEPS/lib/libssl.a" ]]; then
  echo "=== OpenSSL ($TARGET) ==="
  mkdir -p "$WORK/openssl"
  (cd "$WORK/openssl" &&
    env ${SSL_ENV[@]+"${SSL_ENV[@]}"} perl "$SRC/openssl-3.5.0/Configure" "$SSL_TARGET" \
      --prefix="$DEPS" --libdir=lib no-shared no-tests no-module no-asm &&
    make -j"$JOBS" && make install_sw)
fi
if [[ "$TARGET" != android-* ]]; then   # SDL 클라이언트용 (Android는 앱이 화면을 그림)
  [[ -f "$DEPS/lib/cmake/SDL3/SDL3Config.cmake" ]] || cmake_build SDL "$SRC/SDL3-3.2.28" "$DEPS" \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_WAYLAND=OFF
  [[ -f "$DEPS/lib/libfreetype.a" ]] || cmake_build freetype "$SRC/freetype-2.13.3" "$DEPS" \
    -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
  [[ -f "$DEPS/lib/cmake/SDL3_ttf/SDL3_ttfConfig.cmake" ]] || cmake_build SDL_ttf "$SRC/SDL3_ttf-3.2.2" "$DEPS" \
    -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF
  FREERDP_EXTRA+=(-DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF
    -DWITH_SDL_LINK_SHARED=OFF -DWITH_SDL_IMAGE_DIALOGS=OFF)
fi

# ---------------------------------------------------------------- 4) FreeRDP
cmake_build FreeRDP "$SRC/freerdp-$FREERDP_VERSION" "$WORK/install" \
  -DOPENSSL_ROOT_DIR="$DEPS" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_WINDOWS=OFF -DWITH_X11=OFF \
  -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_SAMPLE=OFF \
  -DWITH_MANPAGES=OFF -DBUILD_TESTING=OFF -DWITH_SMARTCARD_EMULATE=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_CAIRO=OFF \
  -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_PKCS11=OFF -DWITH_WEBVIEW=OFF \
  -DWITH_OPUS=OFF -DWITH_CUPS=OFF -DCHANNEL_URBDRC=OFF -DWITH_ALSA=OFF \
  -DWITH_PCSC=OFF -DWITH_JPEG=OFF -DWITH_OPENH264=OFF \
  ${FREERDP_EXTRA[@]+"${FREERDP_EXTRA[@]}"}

# ---------------------------------------------------------------- 5) 결과물 + 검사
rm -rf "$OUT"; mkdir -p "$OUT"

if [[ "$TARGET" == android-* ]]; then
  # 앱(Flutter plugin)에 넣을 헤더와 정적 라이브러리
  mkdir -p "$OUT/lib"
  cp -R "$WORK/install/include" "$OUT/"
  cp -R "$DEPS/include/openssl" "$OUT/include/"
  find "$WORK/install/lib" "$DEPS/lib" -maxdepth 1 -name '*.a' -exec cp {} "$OUT/lib/" \;
  # 설치되지 않는 채널 내부 라이브러리 (libfreerdp-client3.a 가 참조)
  find "$WORK/FreeRDP/channels" -name '*-common.a' -exec cp {} "$OUT/lib/" \;
  for lib in "$OUT"/lib/libfreerdp3.a "$OUT"/lib/libssl.a; do
    [[ -f "$lib" ]] || die "라이브러리가 없습니다: $lib"
  done
  for lib in "$OUT"/lib/*.a; do
    formats="$(llvm-objdump -f "$lib" | grep -o 'file format .*' | sort -u)"
    [[ "$formats" == "file format elf64-littleaarch64" ]] || die "arm64 라이브러리가 아닙니다: $lib ($formats)"
  done
  echo
  echo "완료: $OUT/lib ($(ls "$OUT/lib" | wc -l | tr -d ' ')개 정적 라이브러리), $OUT/include"
  exit 0
fi

cp "$WORK/install/bin/$EXE" "$OUT/"
[[ "$TARGET" == windows-* ]] && cp "$ROOT/scripts/connect.bat" "$OUT/"   # Windows용 접속 스크립트

# 시스템 외 동적 라이브러리에 의존하지 않는지 확인
case "$TARGET" in
  macos-*)
    lipo -archs "$OUT/$EXE" | grep -qx "$ARCH" || die "아키텍처 불일치: $(lipo -archs "$OUT/$EXE")"
    if otool -L "$OUT/$EXE" | tail -n +2 | grep -vE '^\s+/(usr/lib|System/Library)/'; then
      die "위 라이브러리가 정적으로 링크되지 않았습니다."
    fi ;;
  windows-*)
    file "$OUT/$EXE" | grep -q "PE32+ executable.*x86-64" || die "Windows x86_64 실행 파일이 아닙니다."
    if "$P-objdump" -p "$OUT/$EXE" | grep 'DLL Name:' | grep -iE 'c\+\+|unwind|winpthread|ssl|crypto|sdl'; then
      die "위 DLL이 정적으로 링크되지 않았습니다."
    fi ;;
  linux-*)
    want=x86-64; [[ "$TARGET" == linux-arm64 ]] && want=aarch64
    file "$OUT/$EXE" | grep -q "ELF 64-bit.*$want" || die "Linux $want 실행 파일이 아닙니다."
    if readelf -d "$OUT/$EXE" | grep NEEDED | grep -iE 'ssl|crypto|SDL|freerdp|winpr'; then
      die "위 라이브러리가 정적으로 링크되지 않았습니다."
    fi ;;
esac

# 호스트와 같은 타깃이면 실행 확인, 아니면 대상 컴퓨터에서 확인 필요
if [[ "$TARGET" == "macos-$(uname -m)" || ( "$HOST" == linux && "$TARGET" == linux-x86_64 ) ]]; then
  "$OUT/$EXE" /version
fi

echo
echo "완료: $OUT/$EXE"
