# macOS용 FreeRDP SDL 클라이언트

macOS에서 FreeRDP 3.24.2를 SDL3 클라이언트로 빌드하고, SSH 터널을 통해 RDP 서버에 접속하는 절차입니다. 이 폴더는 소스 다운로드, 빌드 및 설치 경로를 함께 사용합니다.

현재 설치된 `bin/sdl-freerdp`는 **x86_64** 실행 파일입니다. 아래 명령은 Intel Mac 환경을 기준으로 합니다. Apple Silicon에서 네이티브 빌드할 경우 OpenSSL 타깃을 `darwin64-arm64-cc`로 바꾸고 모든 의존성을 같은 아키텍처로 빌드해야 합니다.

## 구성

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

## Git 관리

현재 프로젝트 루트는 Git 저장소로 초기화되어 있지 않습니다. `.gitignore`는 저장소 초기화 후 다운로드한 외부 소스, 설치 산출물, 캐시, 로그 및 로컬 인증·접속 파일이 추가되는 것을 방지합니다. 이미 추적 중인 파일에는 소급 적용되지 않습니다.

이 문서는 제공된 명령과 기존 빌드 산출물·CMake 캐시를 검토하여 작성했으며, 전체 재빌드와 실제 원격 접속은 별도로 검증해야 합니다.
# freeRDP
