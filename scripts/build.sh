#!/usr/bin/env bash
# FreeRDP 3.24.2 SDL3 클라이언트를 iMac(macOS)에서 타깃별로 빌드합니다.
#   사용법: bash scripts/build.sh <타깃>
#   타깃:   macos-arm64 | macos-x86_64 | windows-x86_64 | linux-arm64 | linux-x86_64
# 소스·도구 다운로드 → 압축 해제 → 의존성 빌드 → FreeRDP 빌드 → dist/<타깃>/ 생성
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
FREERDP_VERSION=3.24.2

die() { echo "오류: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || die "호스트는 macOS(iMac)여야 합니다."

case "$TARGET" in
  macos-arm64)    SSL_TARGET=darwin64-arm64-cc ;;
  macos-x86_64)   SSL_TARGET=darwin64-x86_64-cc ;;
  windows-x86_64) SSL_TARGET=mingw64 ;;
  linux-arm64|linux-x86_64)
    die "$TARGET 타깃은 iMac에서 빌드할 수 없습니다. Linux용 크로스 컴파일러와 시스템 라이브러리(X11 등)가 tools/에 없습니다. 해당 Linux 컴퓨터에서 직접 빌드하세요." ;;
  *) die "사용법: bash scripts/build.sh <macos-arm64|macos-x86_64|windows-x86_64|linux-arm64|linux-x86_64>" ;;
esac

# 1) 다운로드 + 압축 해제
source "$ROOT/scripts/fetch.sh"
fetch_all "$TARGET"

# 2) 도구 경로
export PATH="$ROOT/tools/macos/cmake-3.31.6-macos-universal/CMake.app/Contents/bin:$ROOT/tools/macos/ninja-1.12.1:$PATH"
command -v clang >/dev/null && command -v make >/dev/null \
  || die "Xcode Command Line Tools가 필요합니다: xcode-select --install"

SRC="$ROOT/src"
WORK="$ROOT/build/$TARGET"     # 중간 산출물
DEPS="$WORK/deps"              # 정적 의존성 설치 위치
OUT="$ROOT/dist/$TARGET"       # 최종 결과물
mkdir -p "$WORK" "$DEPS"

CMAKE_ARGS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_PREFIX_PATH="$DEPS" -DCMAKE_FIND_ROOT_PATH="$DEPS")
EXE=sdl-freerdp
FREERDP_EXTRA=()

if [[ "$TARGET" == macos-* ]]; then
  ARCH="${TARGET#macos-}"
  export MACOSX_DEPLOYMENT_TARGET=11.0
  CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH")
  [[ "$ARCH" == "$(uname -m)" ]] || CMAKE_ARGS+=(-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$ARCH")
  SSL_ENV=()
else
  # Windows: tools/windows-x86_64 의 llvm-mingw 크로스 컴파일러 사용
  MINGW="$ROOT/tools/windows-x86_64/llvm-mingw-20250528-ucrt-macos-universal/bin"
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
fi

# cmake_build <이름> <소스 폴더> <설치 위치> [추가 옵션...]
cmake_build() {
  local name="$1" src="$2" prefix="$3"; shift 3
  echo "=== $name ($TARGET) ==="
  cmake -S "$src" -B "$WORK/$name" "${CMAKE_ARGS[@]}" -DCMAKE_INSTALL_PREFIX="$prefix" "$@"
  cmake --build "$WORK/$name" --parallel "$JOBS"
  cmake --install "$WORK/$name"
}

# 3) 의존성 (정적 라이브러리) — 이미 설치되었으면 건너뜀
if [[ ! -f "$DEPS/lib/libssl.a" ]]; then
  echo "=== OpenSSL ($TARGET) ==="
  mkdir -p "$WORK/openssl"
  (cd "$WORK/openssl" &&
    env ${SSL_ENV[@]+"${SSL_ENV[@]}"} perl "$SRC/openssl-3.5.0/Configure" "$SSL_TARGET" \
      --prefix="$DEPS" --libdir=lib no-shared no-tests no-module no-asm &&
    make -j"$JOBS" && make install_sw)
fi
[[ -f "$DEPS/lib/cmake/SDL3/SDL3Config.cmake" ]] || cmake_build SDL "$SRC/SDL3-3.2.28" "$DEPS" \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF
[[ -f "$DEPS/lib/libfreetype.a" ]] || cmake_build freetype "$SRC/freetype-2.13.3" "$DEPS" \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
[[ -f "$DEPS/lib/cmake/SDL3_ttf/SDL3_ttfConfig.cmake" ]] || cmake_build SDL_ttf "$SRC/SDL3_ttf-3.2.2" "$DEPS" \
  -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF

# 4) FreeRDP SDL3 클라이언트
cmake_build FreeRDP "$SRC/freerdp-$FREERDP_VERSION" "$WORK/install" \
  -DOPENSSL_ROOT_DIR="$DEPS" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF -DWITH_SDL_LINK_SHARED=OFF \
  -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_WINDOWS=OFF -DWITH_X11=OFF \
  -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_SAMPLE=OFF \
  -DWITH_MANPAGES=OFF -DBUILD_TESTING=OFF -DWITH_SMARTCARD_EMULATE=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_CAIRO=OFF \
  -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_PKCS11=OFF -DWITH_WEBVIEW=OFF \
  -DWITH_OPUS=OFF -DWITH_CUPS=OFF -DCHANNEL_URBDRC=OFF -DWITH_ALSA=OFF -DWITH_PULSE=OFF \
  -DWITH_PCSC=OFF -DWITH_JPEG=OFF -DWITH_OPENH264=OFF -DWITH_SDL_IMAGE_DIALOGS=OFF \
  ${FREERDP_EXTRA[@]+"${FREERDP_EXTRA[@]}"}

# 5) 결과물: dist/<타깃>/ 실행 파일 (사용한 라이브러리·라이선스는 README.md에 명시)
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$WORK/install/bin/$EXE" "$OUT/"
[[ "$TARGET" == windows-* ]] && cp "$ROOT/scripts/connect.bat" "$OUT/"   # Windows용 접속 스크립트

# 시스템 외 동적 라이브러리에 의존하지 않는지 확인
if [[ "$TARGET" == macos-* ]]; then
  lipo -archs "$OUT/$EXE" | grep -qx "$ARCH" || die "아키텍처 불일치: $(lipo -archs "$OUT/$EXE")"
  if otool -L "$OUT/$EXE" | tail -n +2 | grep -vE '^\s+/(usr/lib|System/Library)/'; then
    die "위 라이브러리가 정적으로 링크되지 않았습니다."
  fi
else
  file "$OUT/$EXE" | grep -q "PE32+ executable.*x86-64" || die "Windows x86_64 실행 파일이 아닙니다."
  if "$P-objdump" -p "$OUT/$EXE" | grep 'DLL Name:' | grep -iE 'c\+\+|unwind|winpthread|ssl|crypto|sdl'; then
    die "위 DLL이 정적으로 링크되지 않았습니다."
  fi
fi

# 호스트와 같은 타깃이면 실행 확인, 아니면 대상 컴퓨터에서 확인 필요
if [[ "$TARGET" == "macos-$(uname -m)" ]]; then
  "$OUT/$EXE" /version
fi

echo
echo "완료: $OUT/$EXE"
