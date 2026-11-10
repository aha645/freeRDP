#!/usr/bin/env bash
# 소스와 빌드 도구를 내려받아(SHA-256 확인) 압축을 풉니다.
#   src/<이름-버전>/          소스 (모든 호스트 공통)
#   tools/macos/ , tools/linux/   호스트 도구: CMake, Ninja (빌드하는 컴퓨터용)
#   tools/<타깃>/             타깃 전용 컴파일러 (빌드하는 컴퓨터용 배포판)
# 단독 실행: bash scripts/fetch.sh <macos|linux> [타깃]
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

#        압축 해제 폴더     | 다운로드 URL | SHA-256
SOURCES=(
  "openssl-3.5.0|https://github.com/openssl/openssl/releases/download/openssl-3.5.0/openssl-3.5.0.tar.gz|344d0a79f1a9b08029b0744e2cc401a43f9c90acd1044d09a530b4885a8e9fc0"
  "SDL3-3.2.28|https://github.com/libsdl-org/SDL/releases/download/release-3.2.28/SDL3-3.2.28.tar.gz|1330671214d146f8aeb1ed399fc3e081873cdb38b5189d1f8bb6ab15bbc04211"
  "freetype-2.13.3|https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz|5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747"
  "SDL3_ttf-3.2.2|https://github.com/libsdl-org/SDL_ttf/releases/download/release-3.2.2/SDL3_ttf-3.2.2.tar.gz|63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d"
  "freerdp-3.24.2|https://pub.freerdp.com/releases/freerdp-3.24.2.tar.gz|f0fd5a627ad0216da205c9ec0926b968448b35fcb5c8a3c6bd84018fea8dcc34"
)

#  호스트 | 대상(host=모든 타깃) | 보관 폴더 | 압축 해제 폴더 | URL | SHA-256
TOOLS=(
  "macos|host|macos|cmake-3.31.6-macos-universal|https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-macos-universal.tar.gz|330b9514f5112e5ed4fb08b8b05803b776fd9b539a6ae12927d14dcc0ee2ba8d"
  "macos|host|macos|ninja-1.12.1|https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-mac.zip|89a287444b5b3e98f88a945afa50ce937b8ffd1dcc59c555ad9b1baf855298c9"
  "macos|windows-x86_64|windows-x86_64|llvm-mingw-20250528-ucrt-macos-universal|https://github.com/mstorsjo/llvm-mingw/releases/download/20250528/llvm-mingw-20250528-ucrt-macos-universal.tar.xz|c0890a78c769dbea0d09455d7dba4e33880acca53fd47952428d7ed9a9bade16"
  "macos|android-arm64|android|android-ndk-r27c|https://dl.google.com/android/repository/android-ndk-r27c-darwin.zip|8c5685457c58a88527367d46d3f14e8c727d962c39f85344cff0c0768a73c3b7"

  "linux|host|linux|cmake-3.31.6-linux-x86_64|https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.tar.gz|5a1133ff103c71eb5120e2cc3de922733e7d8a26a98ae716397e8676adb367bf"
  "linux|host|linux|ninja-1.12.1|https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip|6f98805688d19672bd699fbbfa2c2cf0fc054ac3df1f0e6a47664d963d530255"
  "linux|windows-x86_64|windows-x86_64|llvm-mingw-20250528-ucrt-ubuntu-22.04-x86_64|https://github.com/mstorsjo/llvm-mingw/releases/download/20250528/llvm-mingw-20250528-ucrt-ubuntu-22.04-x86_64.tar.xz|b6a446193e65ef43ac393dd0767824e4a2c0a6a099505d990a5e56b867a47b40"
  "linux|android-arm64|android|android-ndk-r27c|https://dl.google.com/android/repository/android-ndk-r27c-linux.zip|59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc"
)

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# fetch <보관 폴더> <압축 해제 폴더 이름> <URL> <SHA-256>
fetch() {
  local dir="$1" name="$2" url="$3" sha="$4"
  local archive="$dir/${url##*/}"
  [[ -d "$dir/$name" ]] && return 0
  mkdir -p "$dir"
  if [[ ! -f "$archive" ]]; then
    echo "다운로드: $url"
    curl -fL --retry 3 -o "$archive.part" "$url"
    mv "$archive.part" "$archive"
  fi
  [[ "$(sha256 "$archive")" == "$sha" ]] \
    || { echo "체크섬 불일치: $archive (파일을 지우고 다시 실행하세요)" >&2; exit 1; }
  echo "압축 해제: $archive"
  local tmp="$dir/.extract-$name"
  rm -rf "$tmp"; mkdir -p "$tmp"
  case "$archive" in
    *ninja*.zip) unzip -q "$archive" -d "$tmp/$name" ;;       # ninja: 최상위 폴더 없음
    *.zip)       unzip -q "$archive" -d "$tmp" ;;
    *)           tar xf "$archive" -C "$tmp" ;;
  esac
  mv "$tmp/$name" "$dir/$name"
  rm -rf "$tmp"
}

# fetch_all <호스트: macos|linux> [타깃]
fetch_all() {
  local host="$1" target="${2:-}" entry h t where name url sha
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url sha <<<"$entry"; fetch "$ROOT/src" "$name" "$url" "$sha"
  done
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r h t where name url sha <<<"$entry"
    [[ "$h" == "$host" && ( "$t" == host || "$t" == "$target" ) ]] || continue
    fetch "$ROOT/tools/$where" "$name" "$url" "$sha"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then fetch_all "${1:?사용법: bash scripts/fetch.sh <macos|linux> [타깃]}" "${2:-}"; fi
