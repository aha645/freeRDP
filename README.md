# FreeRDP 3.24.2: 타깃별 자동 빌드

**타깃을 지정해 스크립트 하나만 실행하면** 다음 과정이 자동으로 진행됩니다.
소스·도구 다운로드 → SHA-256 확인 → 압축 해제 → 빌드 → 결과물 생성.
Docker나 가상 머신은 사용하지 않습니다. 현재 호스트에서 빌드할 수 없는 타깃은 이유를 출력하고 즉시 종료합니다.

```sh
bash scripts/build.sh <타깃>
```

## 호스트와 타깃

호스트는 빌드하는 컴퓨터입니다. **Windows PC에서는 WSL2(Windows에 내장된 Ubuntu)** 안에서 실행합니다.

| 타깃 | 결과물 | macOS 호스트 (iMac) | Linux 호스트 (Windows의 WSL2) |
| --- | --- | --- | --- |
| `macos-x86_64` | `dist/macos-x86_64/sdl-freerdp` | ✅ 빌드·실행 확인 | ❌ Apple SDK가 macOS에만 있음 |
| `macos-arm64` | `dist/macos-arm64/sdl-freerdp` | ✅ 빌드 확인 | ❌ |
| `windows-x86_64` | `dist/windows-x86_64/sdl-freerdp.exe`, `connect.bat` | ✅ 빌드 확인 | 지원 (미검증) |
| `android-arm64` | `dist/android-arm64/{include,lib}` 앱용 정적 라이브러리 | ✅ 빌드·링크 확인 | 지원 (미검증) |
| `android-x86_64` | `dist/android-x86_64/{include,lib}` 에뮬레이터용 | 지원 (미검증) | 지원 (미검증) |
| `linux-x86_64` | `dist/linux-x86_64/sdl-freerdp` | ❌ | 지원 (미검증) |
| `linux-arm64` | `dist/linux-arm64/sdl-freerdp` | ❌ | 지원 (미검증, 교차 빌드) |

- **데스크톱 타깃:** SDL3 클라이언트 실행 파일 하나를 만듭니다. 다른 라이브러리를 정적으로 포함하므로 이 파일만 복사하면 대상 컴퓨터에서 실행됩니다(Linux는 X11·PulseAudio 같은 데스크톱 시스템 라이브러리 사용).
- **android-arm64, android-x86_64:** 실행 파일이 아니라 Flutter 앱(plugin)에 넣을 FreeRDP·OpenSSL 헤더와 정적 라이브러리를 만듭니다. 설계는 [docs/plugin-design.md](docs/plugin-design.md), plugin과 앱 빌드 방법은 [packages/README.md](packages/README.md)를 참고하세요.
- **"미검증":** Linux 호스트용 스크립트는 작성했지만 WSL2에서 아직 실제로 빌드해 보지 않았다는 뜻입니다.

## 폴더 구조

```
rdp/
├── scripts/
│   ├── build.sh        # 빌드: bash scripts/build.sh <타깃>
│   ├── fetch.sh        # 소스·도구의 URL·SHA-256 목록, 다운로드·압축 해제
│   ├── connect.sh      # 접속(macOS): bash scripts/connect.sh <사용자ID> [서버:포트]
│   └── connect.bat     # 접속(Windows): 빌드 시 dist/windows-x86_64/에 함께 복사
├── docs/
│   └── plugin-design.md  # Flutter FFI plugin 설계
├── native/rdp_bridge/  # Flutter plugin용 C bridge (FreeRDP 위의 작은 API)
├── packages/           # Flutter plugin (Android 우선)과 예제 앱
├── src/                # (자동 생성) 소스 압축 파일과 압축을 푼 소스
│   ├── openssl-3.5.0/   SDL3-3.2.28/   freetype-2.13.3/
│   ├── SDL3_ttf-3.2.2/  freerdp-3.24.2/
│   └── *.tar.gz
├── tools/              # (자동 생성) 빌드 도구 — 호스트에 맞는 배포판을 받음
│   ├── macos/ | linux/     # 호스트 공통 도구: CMake 3.31.6, Ninja 1.12.1
│   ├── windows-x86_64/     # Windows 타깃용 크로스 컴파일러: llvm-mingw
│   └── android/            # Android 타깃용 NDK r27c
├── build/<타깃>/       # (자동 생성) 중간 산출물. deps/ 아래에 정적 의존성 라이브러리
└── dist/<타깃>/         # (자동 생성) 결과물
```

- `src/`, `tools/`, `build/`, `dist/`는 Git에 포함하지 않습니다. 스크립트를 실행하면 다시 생성됩니다.
- 이미 받은 파일은 다시 받지 않고, 이미 빌드한 의존성은 다시 빌드하지 않습니다.
- 타깃 전용 컴파일러의 출처:
  - macOS 타깃: Xcode Command Line Tools의 Apple Clang
  - Linux 타깃: Ubuntu 패키지(gcc, arm64는 `gcc-aarch64-linux-gnu`)
  - Windows·Android 타깃: `tools/` 아래에 자동으로 받습니다.

## build.sh 처리 순서

1. **다운로드·압축 해제** (`fetch.sh`): 소스와 현재 호스트용 도구를 `src/`, `tools/`에 받습니다. SHA-256을 확인한 뒤 압축을 풉니다.
2. **도구 설정**: 호스트용 CMake·Ninja와 타깃용 컴파일러(llvm-mingw, NDK, gcc)를 선택합니다.
3. **정적 의존성 빌드**: 아래 순서로 빌드해 `build/<타깃>/deps`에 설치합니다.
   OpenSSL 3.5.0 → SDL 3.2.28 → FreeType 2.13.3 → SDL_ttf 3.2.2
   Android는 화면을 앱이 그리므로 OpenSSL만 빌드합니다.
4. **FreeRDP 3.24.2 빌드**: 데스크톱 타깃은 SDL3 클라이언트를, Android는 라이브러리만 빌드합니다. FFmpeg, Kerberos, 스마트카드 등 부가 기능은 끕니다. 클립보드, 소리, 마이크, 해상도 변경 채널은 켜져 있습니다.
5. **검사·패키징**:
   - 결과물의 CPU 종류를 확인합니다.
   - 실행 파일이 OpenSSL·SDL·FreeRDP를 동적 라이브러리로 요구하지 않는지 확인합니다.
   - `dist/<타깃>/`에 복사합니다.
   - 호스트와 같은 타깃이면 `sdl-freerdp /version`을 실행해 동작을 확인합니다.

## 사용한 소스와 라이선스

결과물에는 아래 라이브러리가 정적으로 포함됩니다. 이 실행 파일은 개인·내부 사용을 전제로 합니다. 다른 사람에게 배포할 때는 각 라이선스 전문(`src/` 아래 각 소스의 LICENSE 파일)을 함께 제공해야 합니다.

| 이름 | 버전 | 라이선스 | 출처 |
| --- | --- | --- | --- |
| FreeRDP | 3.24.2 | Apache-2.0 | https://www.freerdp.com |
| OpenSSL | 3.5.0 | Apache-2.0 | https://www.openssl.org |
| SDL | 3.2.28 | zlib | https://libsdl.org |
| SDL_ttf | 3.2.2 | zlib | https://github.com/libsdl-org/SDL_ttf |
| FreeType | 2.13.3 | FreeType License (FTL) | https://freetype.org |
| mingw-w64 런타임 (Windows만) | llvm-mingw 20250528 | MIT·ZPL 등 | https://github.com/mstorsjo/llvm-mingw |

Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.

## 처음 한 번 준비

### macOS 호스트 (iMac)

Xcode Command Line Tools만 설치하면 됩니다(`clang`, `make`, `perl`, `curl`, `tar` 제공). 나머지는 모두 스크립트가 자동으로 받습니다.

```sh
xcode-select --install
```

### Windows 호스트 (WSL2)

1. PowerShell(관리자)에서 WSL2와 Ubuntu를 설치하고 재부팅합니다.
   ```powershell
   wsl --install -d Ubuntu-24.04
   ```
2. Ubuntu 터미널에서 기본 도구를 설치하고 저장소를 받습니다. 저장소는 `/mnt/c/...`가 아닌 **WSL 홈 폴더 안**에 두세요. Windows 드라이브 위에서 빌드하면 매우 느립니다.
   ```sh
   sudo apt-get update
   sudo apt-get install -y build-essential perl pkg-config curl unzip file git
   git clone https://github.com/aha645/freeRDP.git && cd freeRDP
   bash scripts/build.sh windows-x86_64     # 또는 android-arm64
   ```
3. Linux 타깃에 필요한 패키지가 없으면 `build.sh`가 설치 명령을 출력합니다. `linux-x86_64`는 그 명령을 그대로 실행하면 됩니다.
4. **linux-arm64 준비(처음 한 번):** arm64 패키지를 받을 저장소(ports.ubuntu.com)를 추가해야 합니다. Ubuntu 24.04 기준입니다.
   ```sh
   # 기존 저장소는 amd64 전용으로 제한
   sudo sed -i 's/^Types: deb$/Types: deb\nArchitectures: amd64/' /etc/apt/sources.list.d/ubuntu.sources
   # arm64 저장소 추가
   sudo tee /etc/apt/sources.list.d/ubuntu-ports.sources >/dev/null <<'EOF'
   Types: deb
   URIs: http://ports.ubuntu.com/ubuntu-ports
   Suites: noble noble-updates noble-security
   Components: main restricted universe multiverse
   Architectures: arm64
   Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
   EOF
   sudo dpkg --add-architecture arm64
   sudo apt-get update
   bash scripts/build.sh linux-arm64          # 이어서 출력되는 apt 명령을 실행
   ```

참고:
- 병렬 작업 수는 `JOBS=4 bash scripts/build.sh <타깃>`처럼 지정합니다. 기본값은 CPU 코어 수입니다.
- 처음부터 다시 빌드하려면 `build/<타깃>/`을 지우고 실행합니다.
- Android NDK는 약 700MB~800MB입니다. 첫 `android-arm64` 빌드 때 한 번만 받습니다.

## 실행 방법

SSH 터널을 먼저 연 뒤, 사용자 ID만 넣어 접속 스크립트를 실행합니다. 비밀번호는 실행 중에 입력합니다.

macOS:

```sh
bash scripts/connect.sh RDP사용자명                    # 기본 서버: 127.0.0.1:13389
bash scripts/connect.sh RDP사용자명 127.0.0.1:23389    # 서버 주소·포트 지정
```

Windows: `dist/windows-x86_64/` 폴더(`sdl-freerdp.exe`, `connect.bat`)를 Windows PC에 복사한 뒤, 그 폴더의 명령 프롬프트에서 실행합니다.

```bat
connect.bat RDP사용자명
connect.bat RDP사용자명 127.0.0.1:23389
```

접속 스크립트(`connect.sh` / `connect.bat`)가 하는 일:
- 실행 파일을 찾습니다. macOS는 현재 CPU에 맞는 `dist/macos-<CPU>/sdl-freerdp`, Windows는 같은 폴더의 `sdl-freerdp.exe`입니다.
- 서버 포트가 열려 있는지 먼저 확인합니다. 터널이 꺼져 있으면 바로 알려줍니다.
- 아래 옵션을 붙여 실행합니다.
  - `/dynamic-resolution`: 창 크기에 맞춰 원격 해상도를 바꿉니다.
  - `/cert:ignore`: 서버 인증서 확인을 건너뜁니다. 이 옵션이 없으면 인증서 확인 질문에 답하지 못한 채 대기하다 서버가 연결을 끊을 수 있습니다. SSH 터널(`127.0.0.1`)로 접속할 때만 사용하세요. 터널 없이 직접 접속할 때는 `/cert:tofu`(첫 접속 인증서를 저장하고 이후 변경 시 경고)로 실행 파일을 직접 실행하세요.

SSH 터널 명령은 Windows 10 이상에 기본 포함된 OpenSSH에서도 같습니다.

macOS 실행 파일은 코드 서명·공증을 하지 않았습니다. 다른 Mac에 내려받아 실행하려면 먼저 아래 명령을 한 번 실행하세요.

```sh
xattr -d com.apple.quarantine sdl-freerdp
```
