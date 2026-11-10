# FreeRDP SDL 클라이언트: iMac에서 타깃별 빌드

iMac(Intel, macOS)을 호스트로 사용합니다. **타깃을 지정해 스크립트 하나만 실행하면** 다음 과정이 자동으로 진행됩니다.
소스·도구 다운로드 → SHA-256 확인 → 압축 해제 → 빌드 → 결과물 생성.
Docker나 가상 머신은 사용하지 않습니다. iMac에서 실행되는 도구만으로 빌드할 수 없는 타깃은 "빌드할 수 없음" 메시지를 출력하고 즉시 종료합니다.

```sh
bash scripts/build.sh macos-x86_64     # Intel Mac용
bash scripts/build.sh macos-arm64      # Apple Silicon Mac용
bash scripts/build.sh windows-x86_64   # Windows 64비트용
```

빌드 결과는 실행 파일 하나입니다: `dist/<타깃>/sdl-freerdp` (Windows는 `sdl-freerdp.exe`).
다른 라이브러리를 정적으로 포함하므로 이 파일만 복사하면 대상 컴퓨터에서 실행됩니다. 포함된 라이브러리는 아래 "사용한 소스와 라이선스"에 적었습니다.

## 타깃별 지원 현황

| 타깃 | 상태 | 컴파일러 (위치) |
| --- | --- | --- |
| `macos-x86_64` | 빌드 가능, iMac에서 실행 확인 | Apple Clang (Xcode Command Line Tools) |
| `macos-arm64` | 빌드 가능, 실행 확인은 Apple Silicon Mac에서 | Apple Clang의 `-arch arm64` 교차 빌드 |
| `windows-x86_64` | 빌드 가능, 실행 확인은 Windows 10 이상에서 | llvm-mingw (`tools/windows-x86_64/`) |
| `linux-x86_64` | **iMac에서 빌드 불가** | — |
| `linux-arm64` | **iMac에서 빌드 불가** | — |

Linux 타깃을 빌드하려면 Linux용 크로스 컴파일러와, 대상 시스템의 X11 헤더·라이브러리(sysroot)가 필요합니다. 이 둘이 `tools/`에 없으므로 스크립트는 "빌드할 수 없습니다"를 출력하고 종료합니다. Linux용 결과물이 필요하면 해당 Linux 컴퓨터에서 직접 빌드해야 합니다.

## 폴더 구조

```
rdp/
├── scripts/
│   ├── build.sh        # 실행 진입점: bash scripts/build.sh <타깃>
│   └── fetch.sh        # 소스·도구의 URL·SHA-256 목록, 다운로드·압축 해제
├── src/                # (자동 생성) 소스 압축 파일과 압축을 푼 소스
│   ├── openssl-3.5.0/   SDL3-3.2.28/   freetype-2.13.3/
│   ├── SDL3_ttf-3.2.2/  freerdp-3.24.2/
│   └── *.tar.gz
├── tools/              # (자동 생성) 빌드 도구
│   ├── macos/              # iMac에서 실행되는 공통 도구 (모든 타깃이 사용)
│   │   ├── cmake-3.31.6-macos-universal/
│   │   └── ninja-1.12.1/
│   └── windows-x86_64/     # Windows 타깃용 크로스 컴파일러 (clang, windres, ar 등)
│       └── llvm-mingw-20250528-ucrt-macos-universal/
├── build/<타깃>/       # (자동 생성) 중간 산출물. deps/ 아래에 정적 의존성 라이브러리
└── dist/<타깃>/         # (자동 생성) 결과물: 실행 파일 1개
```

- `src/`, `tools/`, `build/`, `dist/`는 Git에 포함하지 않습니다. 스크립트를 실행하면 다시 생성됩니다.
- 이미 받은 파일은 다시 받지 않고, 이미 빌드한 의존성은 다시 빌드하지 않습니다.
- macOS 타깃은 별도의 타깃 전용 도구가 필요 없습니다. Xcode Command Line Tools의 Apple Clang이 Intel·ARM64를 모두 지원합니다.

## build.sh 처리 순서

1. **다운로드·압축 해제** (`fetch.sh`): 소스와 도구 압축 파일을 `src/`, `tools/`에 받습니다. SHA-256을 확인한 뒤 압축을 풉니다.
2. **도구 설정**: `tools/macos`의 CMake와 Ninja를 PATH에 추가합니다. Windows 타깃이면 `tools/windows-x86_64`의 llvm-mingw도 사용합니다.
3. **정적 의존성 빌드**: 아래 순서로 빌드해 `build/<타깃>/deps`에 설치합니다.
   OpenSSL 3.5.0 → SDL 3.2.28 → FreeType 2.13.3 → SDL_ttf 3.2.2
4. **FreeRDP 3.24.2 빌드**: SDL3 클라이언트를 빌드합니다. FFmpeg, Kerberos, 스마트카드 등 부가 기능은 끕니다.
5. **검사·패키징**:
   - 실행 파일의 CPU 종류를 확인합니다.
   - 시스템 기본 라이브러리 외에 따로 설치해야 하는 라이브러리가 없는지 확인합니다.
   - 실행 파일을 `dist/<타깃>/`에 복사합니다.
   - iMac과 같은 타깃(`macos-x86_64`)이면 `sdl-freerdp /version`을 실행해 동작을 확인합니다.

## 사용한 소스와 라이선스

실행 파일에는 아래 라이브러리가 정적으로 포함됩니다. 이 실행 파일은 개인·내부 사용을 전제로 합니다. 다른 사람에게 배포할 때는 각 라이선스 전문(`src/` 아래 각 소스의 LICENSE 파일)을 함께 제공해야 합니다.

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

Xcode Command Line Tools만 설치하면 됩니다(`clang`, `make`, `perl`, `curl`, `tar` 제공). 나머지는 모두 스크립트가 자동으로 받습니다.

```sh
xcode-select --install
```

참고:
- 병렬 작업 수는 `JOBS=4 bash scripts/build.sh <타깃>`처럼 지정합니다. 기본값은 CPU 코어 수입니다.
- 처음부터 다시 빌드하려면 `build/<타깃>/`을 지우고 실행합니다.

## 실행 방법

비밀번호는 명령에 넣지 말고, 실행 중에 입력하세요.

macOS:

```sh
cd dist/macos-x86_64
./sdl-freerdp /v:127.0.0.1:13389 /u:RDP사용자명 /dynamic-resolution
```

Windows (`sdl-freerdp.exe`를 Windows PC에 복사한 뒤):

```powershell
.\sdl-freerdp.exe /v:127.0.0.1:13389 /u:RDP사용자명 /dynamic-resolution
```

macOS 실행 파일은 코드 서명·공증을 하지 않았습니다. 다른 Mac에 내려받아 실행하려면 먼저 아래 명령을 한 번 실행하세요.

```sh
xattr -d com.apple.quarantine sdl-freerdp
```
