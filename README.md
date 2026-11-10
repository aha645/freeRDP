# FreeRDP SDL 클라이언트 — macOS · Linux · Windows

FreeRDP 3.24.2의 SDL3 클라이언트를 운영체제별로 빌드하고, 실행 파일과 개발용 정적 라이브러리를 GitHub Releases에 각각 배포하기 위한 프로젝트입니다.

**현재 상태:** 자동 빌드·패키징 설정을 추가했습니다. 네 플랫폼 전체의 실제 빌드와 RDP 접속 검증은 아직 완료하지 않았으며, Releases에 파일이 생성되기 전에는 다운로드할 수 없습니다. 기존 로컬 `bin/sdl-freerdp`는 macOS x86_64용 동적 링크 빌드이므로 새 정적 링크 배포 파일과 다릅니다.

## 지원 빌드 대상

| 플랫폼 | CPU | 빌드 환경 | 실행 파일 패키지 |
| --- | --- | --- | --- |
| macOS | Intel x86_64 | macOS 15, Apple Clang | `freerdp-3.24.2-macos-x86_64.tar.gz` |
| macOS | Apple Silicon arm64 | macOS 15, Apple Clang | `freerdp-3.24.2-macos-arm64.tar.gz` |
| Linux | x86_64 | Ubuntu 22.04, GCC | `freerdp-3.24.2-linux-x86_64.tar.gz` |
| Windows | x86_64 | Windows 2022, MSYS2 UCRT64 GCC | `freerdp-3.24.2-windows-x86_64.zip` |

이는 빌드 대상 목록입니다. 모든 OS 버전에서의 실행을 보장하지 않습니다. Linux는 glibc 및 GUI·오디오 시스템 라이브러리에 의존하며, 배포판별 호환성 확인이 필요합니다. Windows ARM64·32비트 및 Linux ARM64는 현재 구성에 포함하지 않습니다. macOS 패키지는 코드 서명·공증을 하지 않습니다.

## 실행 파일과 정적 라이브러리 다운로드

[GitHub Releases](https://github.com/aha645/freeRDP/releases)에서 사용할 운영체제와 CPU에 맞는 파일을 선택합니다.

- **실행용:** `freerdp-3.24.2-<플랫폼>-<CPU>` 압축 파일. 개발 도구 없이 클라이언트를 실행할 때 사용합니다.
- **개발용 SDK:** `freerdp-deps-<플랫폼>-<CPU>.tar.gz`. OpenSSL 3.5.0, zlib 1.3.1, SDL 3.2.28, SDL_ttf 3.2.2 및 vendored FreeType의 정적 라이브러리(`.a`), 헤더, CMake/pkg-config 설정, 라이선스와 `sdk.json`을 포함합니다. FreeRDP 본체는 포함하지 않습니다.
- **무결성 확인:** 각 압축 파일의 `.sha256` 파일을 함께 제공합니다.

정적 라이브러리는 실행 파일에 링크되므로 SDL/OpenSSL의 `.so`나 `.dylib`를 별도로 설치할 필요가 없도록 구성합니다. 운영체제·컴파일러 런타임까지 완전 정적으로 링크하는 것은 아닙니다. Windows 실행용 패키지에는 필요한 MinGW 런타임 DLL을 함께 넣습니다. SDK는 같은 OS·CPU·호환 컴파일러에서 사용하며, Windows용 `.a`는 MSVC용 `.lib`와 호환되지 않습니다. 빌드 환경은 `sdk.json`을 확인하세요.

압축을 푼 뒤 실행합니다. Windows PowerShell에서는 실행 파일에 `.exe`를 붙입니다.

```sh
./bin/sdl-freerdp /v:127.0.0.1:13389 /u:RDP사용자명 /dynamic-resolution
```

```powershell
.\bin\sdl-freerdp.exe /v:127.0.0.1:13389 /u:RDP사용자명 /dynamic-resolution
```

아래 SSH 터널 절차와 함께 사용하세요. 비밀번호는 명령에 저장하지 않고 실행 중 입력합니다.

## 전체 소스 빌드

Git, CMake 3.31 이상, Ninja, Python 3, Perl, make 및 C/C++ 컴파일러를 준비합니다. Windows에서는 **MSYS2 UCRT64** 셸을 사용합니다. 플랫폼별 개발 패키지 설치 명령은 [빌드 워크플로](.github/workflows/build.yml)에 있습니다. macOS에서는 Xcode Command Line Tools도 필요합니다.

프로젝트 루트에서:

```sh
bash scripts/build.sh
```

소스와 빌드는 `.build/`, 압축 결과는 `dist/`에 저장됩니다. 기존 `src/`, `bin/`, `lib/` 설치 결과와 분리됩니다. CPU 병렬 작업 수는 `BUILD_JOBS=6 bash scripts/build.sh`처럼 설정합니다.

SDL_ttf는 배포 tar.gz의 vendored 의존성 누락으로 발생했던 오류를 피하기 위해 **Git에서 `--recurse-submodules --shallow-submodules`로 받습니다.** HarfBuzz·PlutoSVG·샘플은 비활성화합니다. OpenSSL·SDL·SDL_ttf·FreeRDP는 정적 링크 설정으로 빌드하며 FFmpeg, Kerberos 등은 기존 설정대로 비활성화합니다.

## 플랫폼별 빌드 방법

아래 명령은 각 운영체제에서 직접 실행하는 네이티브 빌드입니다. 다른 운영체제용 바이너리를 만드는 크로스 컴파일은 지원하지 않습니다. 경로에 공백이 없는 작업 폴더를 사용하세요. 이미 저장소를 받았다면 `git clone`을 생략하고 해당 프로젝트 폴더로 이동합니다.

### macOS — Intel / Apple Silicon

Xcode Command Line Tools가 없다면 아래 명령을 실행하고 설치 창의 절차를 완료합니다.

```sh
xcode-select --install
```

[Homebrew](https://brew.sh/)가 설치된 터미널에서 도구를 준비합니다. CMake는 별도 Python 가상환경에 3.31.6으로 고정합니다.

```sh
brew install git ninja python pkgconf

git clone https://github.com/aha645/freeRDP.git
cd freeRDP
python3 -m venv .build-tools
source .build-tools/bin/activate
python -m pip install cmake==3.31.6

uname -m
cmake --version
BUILD_JOBS=6 bash scripts/build.sh
```

Intel Mac은 `uname -m`이 `x86_64`, Apple Silicon은 `arm64`여야 합니다. Apple Silicon에서는 Rosetta로 실행한 터미널을 사용하지 말고 arm64 Homebrew·Python·컴파일러를 사용하세요. 스크립트는 현재 CPU에 맞춰 OpenSSL 타깃을 자동 선택합니다.

결과는 Intel의 경우 `dist/freerdp-3.24.2-macos-x86_64.tar.gz`와 `dist/freerdp-deps-macos-x86_64.tar.gz`, Apple Silicon의 경우 각각 `macos-arm64` 파일입니다.

### Linux — Ubuntu 22.04 x86_64

Ubuntu 22.04를 기준으로 필요한 컴파일러와 GUI·오디오 개발 라이브러리를 설치합니다. 다른 배포판은 이에 대응하는 개발 패키지를 설치해야 합니다.

```sh
sudo apt-get update
sudo apt-get install -y \
  git build-essential ninja-build perl python3 python3-venv pkg-config \
  libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxfixes-dev \
  libxss-dev libxtst-dev libasound2-dev libpulse-dev libwayland-dev \
  libxkbcommon-dev libgl1-mesa-dev libegl1-mesa-dev libudev-dev

git clone https://github.com/aha645/freeRDP.git
cd freeRDP
python3 -m venv .build-tools
source .build-tools/bin/activate
python -m pip install cmake==3.31.6

uname -m
cmake --version
BUILD_JOBS=6 bash scripts/build.sh
```

`uname -m`은 `x86_64`여야 합니다. 결과는 `dist/freerdp-3.24.2-linux-x86_64.tar.gz`와 `dist/freerdp-deps-linux-x86_64.tar.gz`입니다. GUI 클라이언트 실행에는 X11 또는 Wayland 데스크톱 환경이 필요합니다.

### Windows — x86_64 / MSYS2 UCRT64

[MSYS2](https://www.msys2.org/)를 설치하고 시작 메뉴에서 **MSYS2 UCRT64** 터미널을 엽니다. PowerShell, Git Bash 및 MSYS 셸에서 아래 빌드를 실행하지 마세요.

먼저 MSYS2를 업데이트합니다.

```sh
pacman -Syu
```

업데이트 과정에서 터미널 종료를 요구하면 종료한 뒤 **MSYS2 UCRT64**를 다시 열고 `pacman -Syu`를 한 번 더 실행합니다. 이후 도구를 설치합니다.

```sh
pacman -S --needed \
  git make perl \
  mingw-w64-ucrt-x86_64-gcc \
  mingw-w64-ucrt-x86_64-cmake \
  mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-python \
  mingw-w64-ucrt-x86_64-pkgconf

mkdir -p /c/dev
cd /c/dev
git clone https://github.com/aha645/freeRDP.git
cd freeRDP

echo "$MSYSTEM"
cmake --version
BUILD_JOBS=6 bash scripts/build.sh
```

`echo "$MSYSTEM"`의 결과는 `UCRT64`여야 합니다. CMake는 3.31 이상을 사용합니다. Windows SDK는 이 GCC/MinGW 환경용이며 MSVC 프로젝트에 그대로 링크할 수 없습니다.

결과는 `dist/freerdp-3.24.2-windows-x86_64.zip`와 `dist/freerdp-deps-windows-x86_64.tar.gz`입니다. 실행용 ZIP은 포함된 DLL을 `bin/sdl-freerdp.exe`와 같은 폴더에 유지한 채 배포합니다.

### 빌드 결과 확인과 SDK 선택

전체 빌드가 성공하면 스크립트가 패키징한 실행 파일의 `/version`을 자동 실행합니다. 설치 폴더의 실행 파일도 직접 확인할 수 있습니다.

```sh
# macOS / Linux
.build/install/bin/sdl-freerdp /version

# Windows: MSYS2 UCRT64
.build/install/bin/sdl-freerdp.exe /version
```

필요한 개발 도구를 설치한 뒤 아래 표의 SDK를 사용하면 의존성 빌드를 생략할 수 있습니다. SDK 추출과 실행 명령은 다음 절을 따릅니다.

| 빌드 환경 | 사용할 정적 라이브러리 SDK |
| --- | --- |
| Intel Mac | `freerdp-deps-macos-x86_64.tar.gz` |
| Apple Silicon Mac | `freerdp-deps-macos-arm64.tar.gz` |
| Ubuntu x86_64 | `freerdp-deps-linux-x86_64.tar.gz` |
| Windows MSYS2 UCRT64 | `freerdp-deps-windows-x86_64.tar.gz` |

## 미리 빌드된 SDK로 빠르게 빌드

전체 라이브러리를 다시 빌드하지 않으려면 같은 릴리스의 플랫폼별 SDK를 내려받아 **새로운 빈 설치 경로**에 풉니다. 아래 예시는 Linux x86_64이며 macOS·Windows에서는 파일명을 해당 플랫폼으로 바꿉니다. Windows 명령은 MSYS2 UCRT64에서 실행합니다.

```sh
mkdir -p .build/install
# 다운로드한 SDK의 실제 경로로 바꿉니다.
tar xzf /다운로드경로/freerdp-deps-linux-x86_64.tar.gz \
  --strip-components=1 -C .build/install
USE_PREBUILT_DEPS=1 bash scripts/build.sh
```

이 모드에서는 SDK의 OS·CPU를 검사하고 의존성 빌드를 생략하여 FreeRDP만 다운로드·빌드합니다. 컴파일러 ABI와 시스템 라이브러리 호환성은 사용자가 `sdk.json`과 빌드 환경을 비교해야 합니다. 이미 다른 빌드에 사용한 `.build/`와 섞지 마세요. 필요하면 `BUILD_ROOT="$PWD/.build-sdk"`를 사용하고 SDK를 `.build-sdk/install`에 풉니다. CI에는 SDK를 다른 경로에 풀어 FreeRDP를 다시 빌드하는 검증 단계가 포함됩니다. 첫 CI 실행 전에는 재배치 호환성이 확인되지 않은 상태입니다.

## GitHub Actions와 Releases

`main` push, PR 또는 Actions의 **Run workflow**로 네 플랫폼을 빌드합니다. 성공하면 Actions 실행 페이지에서 실행 파일과 SDK를 Artifact로 다운로드할 수 있습니다. 빌드 과정에는 패키징된 실행 파일의 `/version` 실행 및 로컬 빌드 경로에 대한 동적 의존성 검사가 포함됩니다. 실제 원격 접속 테스트는 포함하지 않습니다.

버전 태그를 push하면 모든 플랫폼 빌드가 성공한 뒤 GitHub Release를 생성하고 실행 파일·SDK·SHA-256 파일을 첨부합니다. 아래 버전은 예시이며 이미 존재하는 태그를 재사용하지 마세요.

```sh
git push origin main
git tag v0.1.0
git push origin v0.1.0
```

워크플로의 릴리스 작업에는 `contents: write` 권한이 필요합니다. 바이너리는 Git 소스 이력에 직접 넣지 않고 Releases에 보관합니다. `.build/`, `dist/`, 외부 소스 및 로컬 인증·접속 파일은 `.gitignore`로 제외합니다. 정적 라이브러리에 보안 업데이트가 있으면 실행 파일도 다시 빌드·배포해야 합니다.

## 기존 macOS 수동 빌드 기록

아래는 기존 Intel Mac 설치를 재현하기 위한 **동적 라이브러리 방식** 기록입니다. 위 자동화된 정적 빌드 방식과 설치 경로·옵션이 다릅니다.

### 기존 수동 빌드 구성

| 구성 요소 | 버전 |
| --- | --- |
| CMake | 3.31.6 |
| OpenSSL | 3.5.0 |
| SDL | 3.2.28 |
| SDL_ttf | 3.2.2 |
| FreeRDP | 3.24.2 |

`src/`에는 외부 소스, 압축 파일 및 빌드 디렉터리가 있으며, `bin/`, `include/`, `lib/`, `share/`에는 설치 결과가 저장됩니다. 이 경로들은 `.gitignore`로 제외합니다. 직접 작성하는 소스나 스크립트는 이 경로 밖에 두세요.

## 준비

Xcode Command Line Tools, Git, curl, tar, make가 필요합니다. 개발 도구가 없다면 다음 명령으로 설치합니다.

```sh
xcode-select --install
```

아래 명령은 같은 터미널에서 순서대로 실행합니다. 소스 다운로드 및 `git clone` 단계는 새 디렉터리를 기준으로 하며, 이미 소스가 있다면 해당 다운로드·복제 단계를 건너뜁니다. 각 단계가 성공한 뒤 다음 단계로 진행하세요.

```sh
export P="$HOME/rdp"
mkdir -p "$P/src"
cd "$P/src"
```

## 1. CMake

```sh
cd "$P/src"
curl -fLO https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-macos-universal.tar.gz
tar xzf cmake-3.31.6-macos-universal.tar.gz
export PATH="$P/src/cmake-3.31.6-macos-universal/CMake.app/Contents/bin:$PATH"
cmake --version
```

새 터미널에서는 `P`와 위 `PATH`를 다시 설정합니다.

## 2. OpenSSL

```sh
cd "$P/src"
curl -fLO https://github.com/openssl/openssl/releases/download/openssl-3.5.0/openssl-3.5.0.tar.gz
tar xzf openssl-3.5.0.tar.gz
cd openssl-3.5.0
./Configure darwin64-x86_64-cc --prefix="$P" no-tests
make -j6 && make install_sw
```

## 3. SDL3

기존 프로젝트의 SDL 3.2.28 소스와 CMake 설정을 기준으로 보완한 단계입니다. SDL_ttf보다 먼저 설치합니다.

```sh
cd "$P/src"
curl -fLO https://github.com/libsdl-org/SDL/releases/download/release-3.2.28/SDL3-3.2.28.tar.gz
tar xzf SDL3-3.2.28.tar.gz
cmake -S SDL3-3.2.28 -B build-sdl \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake --build build-sdl -j6 && cmake --install build-sdl
```

## 4. SDL_ttf

```sh
cd "$P/src"
git clone --depth 1 --branch release-3.2.2 \
  --recurse-submodules --shallow-submodules \
  https://github.com/libsdl-org/SDL_ttf.git

cmake -S SDL_ttf -B build-ttf \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" \
  -DCMAKE_PREFIX_PATH="$P" -DSDLTTF_VENDORED=ON \
  -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF
cmake --build build-ttf -j6 && cmake --install build-ttf
```

## 5. FreeRDP

```sh
cd "$P/src"
git clone --depth 1 --branch 3.24.2 https://github.com/FreeRDP/FreeRDP.git

cmake -S FreeRDP -B build-freerdp \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" \
  -DCMAKE_PREFIX_PATH="$P" -DOPENSSL_ROOT_DIR="$P" \
  -DWITH_CLIENT_SDL=ON -DWITH_CLIENT_SDL3=ON -DWITH_CLIENT_SDL2=OFF \
  -DWITH_CLIENT_MAC=OFF -DWITH_X11=OFF \
  -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_SAMPLE=OFF \
  -DWITH_MANPAGES=OFF -DBUILD_TESTING=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_CAIRO=OFF \
  -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_PKCS11=OFF -DWITH_WEBVIEW=OFF \
  -DWITH_OPUS=OFF -DWITH_CUPS=OFF -DCHANNEL_URBDRC=OFF

cmake --build build-freerdp -j6 && cmake --install build-freerdp
ls "$P/bin" | grep -i freerdp
```

설치된 클라이언트 경로는 `$P/bin/sdl-freerdp`입니다.

## SSH 터널로 접속

SSH 서버에서 `127.0.0.1:3389`로 RDP 서비스에 접근할 수 있어야 합니다. 별도 터미널에서 아래 터널을 실행하고 접속 중에는 유지합니다. `SSH서버주소`를 실제 주소로 바꾸세요.

```sh
ssh -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:13389:127.0.0.1:3389 aha@SSH서버주소
```

클라이언트 터미널에서 `RDP사용자명`을 실제 사용자명으로 바꿔 실행합니다. SSH 계정 `aha`와 RDP 계정은 별개입니다.

```sh
export P="$HOME/rdp"
"$P/bin/sdl-freerdp" /v:127.0.0.1:13389 /u:RDP사용자명 /cert:ignore /dynamic-resolution
```

`/dynamic-resolution`은 창 크기에 맞춰 원격 해상도를 변경합니다. `/cert:ignore`는 서버 인증서 검증을 생략하므로, 서버를 확인할 수 있는 신뢰된 환경에서 사용하세요. 비밀번호는 명령에 넣지 않고 실행 시 입력합니다. 실제 서버 주소, 계정, 비밀번호, 개인 키 및 접속 설정은 Git에 올리지 않습니다.
