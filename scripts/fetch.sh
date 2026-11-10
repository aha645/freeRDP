#!/usr/bin/env bash
# 소스와 빌드 도구를 내려받아(SHA-256 확인) 압축을 풉니다.
#   src/<이름-버전>/          소스
#   tools/macos/              호스트(iMac) 도구: CMake, Ninja
#   tools/<타깃>/             타깃 전용 컴파일러
# 단독 실행: bash scripts/fetch.sh [타깃]
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
HOST_TOOLS=(
  "macos|cmake-3.31.6-macos-universal|https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-macos-universal.tar.gz|330b9514f5112e5ed4fb08b8b05803b776fd9b539a6ae12927d14dcc0ee2ba8d"
  "macos|ninja-1.12.1|https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-mac.zip|89a287444b5b3e98f88a945afa50ce937b8ffd1dcc59c555ad9b1baf855298c9"
)
WINDOWS_TOOLS=(
  "windows-x86_64|llvm-mingw-20250528-ucrt-macos-universal|https://github.com/mstorsjo/llvm-mingw/releases/download/20250528/llvm-mingw-20250528-ucrt-macos-universal.tar.xz|c0890a78c769dbea0d09455d7dba4e33880acca53fd47952428d7ed9a9bade16"
)

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
  echo "$sha  $archive" | shasum -a 256 -c - >/dev/null \
    || { echo "체크섬 불일치: $archive (파일을 지우고 다시 실행하세요)" >&2; exit 1; }
  echo "압축 해제: $archive"
  local tmp="$dir/.extract-$name"
  rm -rf "$tmp"; mkdir -p "$tmp"
  case "$archive" in
    *.zip) unzip -q "$archive" -d "$tmp/$name" ;;            # ninja: 최상위 폴더 없음
    *)     tar xf "$archive" -C "$tmp" ;;
  esac
  mv "$tmp/$name" "$dir/$name"
  rm -rf "$tmp"
}

fetch_all() {
  local target="${1:-}" entry where name url sha
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url sha <<<"$entry"; fetch "$ROOT/src" "$name" "$url" "$sha"
  done
  local tools=("${HOST_TOOLS[@]}")
  [[ "$target" == windows-x86_64 ]] && tools+=("${WINDOWS_TOOLS[@]}")
  for entry in "${tools[@]}"; do
    IFS='|' read -r where name url sha <<<"$entry"; fetch "$ROOT/tools/$where" "$name" "$url" "$sha"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then fetch_all "${1:-}"; fi
