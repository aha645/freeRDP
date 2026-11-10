#!/usr/bin/env bash
# Native builds only: macOS, Linux, or Windows in an MSYS2 UCRT64 shell.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${BUILD_ROOT:-$ROOT/.build}"
PREFIX="$WORK/install"
JOBS="${BUILD_JOBS:-4}"
case "$(uname -s)" in
  Darwin)
    OS=macos
    case "$(uname -m)" in
      arm64) ARCH=arm64; SSL_TARGET=darwin64-arm64-cc ;;
      x86_64) ARCH=x86_64; SSL_TARGET=darwin64-x86_64-cc ;;
      *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
    esac
    ;;
  Linux)
    OS=linux; ARCH="$(uname -m)"
    [[ "$ARCH" == x86_64 ]] || { echo 'Linux x86_64 required' >&2; exit 1; }
    SSL_TARGET=linux-x86_64
    ;;
  MINGW*|MSYS*)
    [[ "${MSYSTEM:-}" == UCRT64 ]] || { echo 'Use MSYS2 UCRT64' >&2; exit 1; }
    OS=windows; ARCH=x86_64; SSL_TARGET=mingw64
    ;;
  *) echo 'Unsupported platform' >&2; exit 1 ;;
esac
mkdir -p "$WORK/sources" "$PREFIX" "$ROOT/dist"
clone() {
  local name="$1" url="$2" tag="$3"
  if [[ ! -d "$WORK/sources/$name" ]]; then
    git clone --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules \
      "$url" "$WORK/sources/$name"
  fi
  [[ "$(git -C "$WORK/sources/$name" describe --tags --exact-match)" == "$tag" ]]
  [[ -z "$(git -C "$WORK/sources/$name" status --porcelain)" ]] || {
    echo "Source tree is modified: $name" >&2; exit 1;
  }
}
build() {
  local name="$1"; shift
  cmake -S "$WORK/sources/$name" -B "$WORK/build-$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX" -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
  cmake --build "$WORK/build-$name" --parallel "$JOBS"
  cmake --install "$WORK/build-$name"
}
export PACKAGE_OS="$OS" PACKAGE_ARCH="$ARCH" PACKAGE_PREFIX="$PREFIX"
if [[ "$OS" == windows ]]; then
  export PACKAGE_PREFIX="$(cygpath -w "$PREFIX")"
fi
if [[ "${USE_PREBUILT_DEPS:-0}" != 1 ]]; then
clone openssl https://github.com/openssl/openssl.git openssl-3.5.0
clone zlib https://github.com/madler/zlib.git v1.3.1
clone SDL https://github.com/libsdl-org/SDL.git release-3.2.28
clone SDL_ttf https://github.com/libsdl-org/SDL_ttf.git release-3.2.2
(
  cd "$WORK/sources/openssl"
  # No assembler dependency or loadable OpenSSL modules in the release bundle.
  perl ./Configure "$SSL_TARGET" --prefix="$PREFIX" --libdir=lib no-shared no-tests no-module no-asm
  make -j"$JOBS"
  make install_sw
)
build zlib -DZLIB_BUILD_EXAMPLES=OFF
build SDL -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF \
  -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF
build SDL_ttf -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=OFF \
  -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF -DSDLTTF_RELOCATABLE=ON
python3 "$ROOT/scripts/package-deps.py"
else
  # Use a fresh prefix containing only the extracted dependency SDK.
  python3 -c 'import json,os,pathlib; m=json.loads((pathlib.Path(os.environ["PACKAGE_PREFIX"])/"sdk.json").read_text()); assert (m["platform"],m["architecture"]) == (os.environ["PACKAGE_OS"],os.environ["PACKAGE_ARCH"]), "SDK platform mismatch"'
fi
clone FreeRDP https://github.com/FreeRDP/FreeRDP.git 3.24.2
build FreeRDP -DZLIB_USE_STATIC_LIBS=ON -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF \
  -DWITH_SDL_LINK_SHARED=OFF -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_WINDOWS=OFF \
  -DWITH_X11=OFF -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF \
  -DWITH_SAMPLE=OFF -DWITH_MANPAGES=OFF -DBUILD_TESTING=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_CAIRO=OFF \
  -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_PKCS11=OFF -DWITH_WEBVIEW=OFF \
  -DWITH_OPUS=OFF -DWITH_CUPS=OFF -DCHANNEL_URBDRC=OFF \
  -DWITH_ALSA=OFF -DWITH_PULSE=OFF -DWITH_PCSC=OFF -DWITH_JPEG=OFF \
  -DWITH_OPENH264=OFF -DWITH_SDL_IMAGE_DIALOGS=OFF
export PACKAGE_OS="$OS" PACKAGE_ARCH="$ARCH" PACKAGE_PREFIX="$PREFIX"
if [[ "$OS" == windows ]]; then
  export PACKAGE_PREFIX="$(cygpath -w "$PREFIX")"
fi
python3 "$ROOT/scripts/package.py"
