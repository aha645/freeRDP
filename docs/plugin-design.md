# Flutter 원격 데스크톱 앱 — FFI plugin 설계

FreeRDP 3.24.2(C)를 플랫폼별로 빌드해 두고, Flutter 앱이 `dart:ffi`와 플랫폼 텍스처로 이를 사용하는 구조의 설계입니다.

- 대상: Android, iOS, macOS, Windows, Linux 앱, 웹(게이트웨이 경유)
- 프로토콜: RDP(FreeRDP). VNC는 같은 구조로 나중에 추가합니다(10장).
- 1차 접속 대상 서버: Ubuntu의 gnome-remote-desktop(RDP)

> 표시: ✅ 확인함, 🔧 구현 필요, ❓ 서버나 기기에서 확인 필요

---

## 1. 전체 구조

```
┌──────────────────────── Flutter 앱 (Dart) ────────────────────────┐
│ UI · 접속 목록 · 설정 · 입력 처리                                   │
│ RemoteSession 인터페이스 ── RdpSession (dart:ffi) / VncSession(추후) │
│        │ 제어: 접속·종료·키보드·마우스·클립보드·해상도               │
│        │ 이벤트: 상태·인증 요청·인증서 확인·커서 (NativeCallable)     │
│ Texture(textureId) ◀── 픽셀은 Dart를 거치지 않음                    │
└────────┼──────────────────────────────────────────▲───────────────┘
         ▼                                          │ 새 프레임 알림
┌──── rdp_bridge (C, 우리가 작성) ────┐     ┌── 플랫폼 텍스처 plugin ──┐
│ 단순한 C API (2장)                  │────▶│ Android: Kotlin + JNI    │
│ FreeRDP 콜백 → 이벤트·프레임 전달    │프레임│ iOS/macOS: Swift         │
└────────┬────────────────────────────┘     │ Windows: C++             │
         ▼                                  │ Linux: C (GTK)           │
┌──── FreeRDP + OpenSSL (정적 라이브러리, scripts/build.sh로 빌드) ────┐
│ 프로토콜 · NLA 인증 · 코덱 · 채널(클립보드·소리·마이크·해상도)        │
└──────────────────────────────────────────────────────────────────────┘
```

원칙
1. **Dart는 FreeRDP를 직접 부르지 않습니다.** FreeRDP API는 크고 구조체가 복잡하므로, 우리가 만든 `rdp_bridge`의 작은 C API만 FFI로 노출합니다.
2. **픽셀은 네이티브 안에서만 움직입니다.** `rdp_bridge`가 플랫폼 plugin이 넘겨준 "프레임 싱크"에 바로 씁니다(4장).
3. **모든 플랫폼이 같은 C API를 씁니다.** 플랫폼별 코드는 텍스처 연결뿐입니다.

---

## 2. rdp_bridge C API (`native/rdp_bridge/rdp_bridge.h`)

```c
typedef struct rdpb_session rdpb_session;               /* 불투명 핸들 */

typedef enum { RDPB_CERT_ASK, RDPB_CERT_IGNORE, RDPB_CERT_TOFU } rdpb_cert_policy;

typedef struct {
    const char* host; int32_t port;
    const char* username; const char* domain;   /* 비밀번호는 auth 이벤트로 받음 */
    int32_t width, height;
    int32_t dynamic_resolution;                   /* disp 채널 */
    int32_t clipboard, audio_playback, microphone; /* cliprdr / rdpsnd / audin */
    int32_t cert_policy;
    const char* config_dir;                       /* 알려진 인증서 저장 폴더 (NULL = 기본) */
} rdpb_config;

typedef enum {
    RDPB_EV_STATE,          /* 접속 중 / 연결됨 / 끊김(+오류 코드) */
    RDPB_EV_AUTH_REQUEST,   /* 비밀번호 필요 → rdpb_answer_auth() */
    RDPB_EV_CERT_VERIFY,    /* 인증서 확인 필요 → rdpb_answer_cert() */
    RDPB_EV_DESKTOP_SIZE,   /* 원격 해상도 변경 */
    RDPB_EV_CURSOR,         /* (예약) 커서 모양 변경 — 아직 보내지 않음 */
    RDPB_EV_CLIPBOARD_TEXT  /* 원격 클립보드 텍스트 (UTF-8) */
} rdpb_event_type;

typedef struct { int32_t type; int32_t code; int32_t a, b; const char* text;
                 const uint8_t* data; int32_t data_len; } rdpb_event;

/* 임의 스레드에서 호출. 이벤트는 힙에 있으며 받은 쪽이 rdpb_event_free()로 해제 */
typedef void (*rdpb_event_cb)(void* user, rdpb_event* ev);

/* 프레임 싱크: 플랫폼 plugin이 구현 (4장) */
typedef struct { int32_t x, y, w, h; } rdpb_rect;
typedef struct rdpb_frame_sink {
    /* 버퍼 잠금. dirty는 입출력: 싱크가 영역을 넓혀 돌려줄 수 있음(새 버퍼 등) */
    int32_t (*begin)(void* user, int32_t width, int32_t height, rdpb_rect* dirty,
                     uint8_t** pixels, int32_t* stride);
    void (*end)(void* user);                                  /* 해제 + 알림 */
    void* user;
} rdpb_frame_sink;

rdpb_session* rdpb_create(const rdpb_config* cfg, rdpb_event_cb cb, void* user);
int32_t rdpb_attach_sink(rdpb_session* s, const rdpb_frame_sink* sink);  /* NULL = 떼기 */
int32_t rdpb_connect(rdpb_session* s);         /* 비동기: 자체 스레드에서 접속 */
void rdpb_disconnect(rdpb_session* s);
void rdpb_destroy(rdpb_session* s);
void rdpb_event_free(rdpb_event* ev);

void rdpb_answer_auth(rdpb_session* s, int32_t ok, const char* password);
void rdpb_answer_cert(rdpb_session* s, int32_t accept, int32_t remember);

void rdpb_send_key(rdpb_session* s, uint16_t scancode, int32_t extended, int32_t down);
void rdpb_send_unicode(rdpb_session* s, uint16_t codeunit, int32_t down);  /* 소프트 키보드용 */
void rdpb_send_mouse(rdpb_session* s, uint16_t flags, int32_t x, int32_t y); /* 버튼·이동 */
void rdpb_send_wheel(rdpb_session* s, int32_t delta, int32_t horizontal);
void rdpb_resize(rdpb_session* s, int32_t width, int32_t height);          /* disp 채널 */
void rdpb_clipboard_set_text(rdpb_session* s, const char* utf8);
void rdpb_request_redraw(rdpb_session* s);     /* 화면 전체를 싱크에 다시 그림 */
```

스레드 규칙
- FreeRDP는 세션마다 자체 스레드에서 돕니다. 여기에 **동적 채널 스레드**가 하나 더 있어, 그래픽 파이프라인(rdpgfx)의 화면 갱신과 해상도 변경(disp) 콜백은 그 스레드에서 옵니다. 따라서 `rdpb_event_cb`와 프레임 싱크는 두 스레드 중 어느 쪽에서도 호출될 수 있습니다(동시에 호출되지는 않습니다).
- 여러 스레드가 함께 쓰는 자원과 잠금: 명령 큐·응답·클립보드 텍스트(`lock`), 싱크 포인터와 싱크 사용 구간(`sink_lock`), 해상도 변경 상태(`disp_lock`), 화면 버퍼(FreeRDP의 update 잠금), Android Surface(싱크 안의 mutex). 잠그는 순서는 항상 update 잠금 → `sink_lock` → Surface mutex입니다.
- 인증·인증서 확인은 **블로킹하지 않는 요청/응답 방식**으로 처리합니다. FreeRDP 콜백 안에서 조건 변수로 기다리고, Dart가 `rdpb_answer_*`를 호출하면 깨어납니다. 앞서 `/cert:ignore` 없이 접속하면 보이지 않는 인증서 질문 때문에 멈췄습니다. 그 문제를 UI에서 질문을 띄우는 방식으로 해결합니다.
- 입력 함수(`rdpb_send_*`)는 어느 스레드에서 불러도 됩니다. bridge의 명령 큐에 넣고 세션 스레드가 꺼내 FreeRDP로 보냅니다.

초안에서 바뀐 점 (P0 구현 중 확인)
- **이벤트는 힙에 두고 `rdpb_event_free`로 해제합니다.** `NativeCallable.listener`는 네이티브 콜백이 끝난 뒤에 Dart에서 실행되므로, 콜백 안에서만 유효한 포인터를 넘기면 Dart가 읽을 때는 이미 사라져 있습니다.
- **싱크 `begin`이 무효 영역을 입출력으로 받습니다.** Android `ANativeWindow_lock`은 잠글 때 바뀔 영역을 받아 나머지를 이전 프레임에서 복사해 주고, 복사할 수 없으면(첫 프레임, 크기 변경) 영역을 전체로 넓혀 돌려줍니다. 그래서 영역을 `end`가 아니라 `begin`에서 주고받아야 합니다.
- **`rdpb_request_redraw` 추가.** 텍스처의 Surface가 새로 만들어지면(백그라운드 복귀, 크기 변경) 원격 화면이 바뀌지 않아도 전체를 다시 그려야 합니다.
- **`config_dir` 추가.** FreeRDP는 알려진 인증서를 `$HOME/.config/freerdp`에 저장하는데 Android에는 `HOME`이 없습니다. Android plugin이 시작할 때 `HOME`을 앱 전용 폴더로 설정하고, 다른 플랫폼은 이 필드로 지정할 수 있습니다.
- **Android 빌드는 `WITH_UNICODE_BUILTIN=ON`.** FreeRDP 기본값은 문자열 변환을 JNI(Java String)로 하는데, JavaVM 등록(`JNI_OnLoad`)이 필요하고 변환마다 스레드를 붙였다 뗍니다. FFI로 쓰는 구조에는 맞지 않아 내장 변환으로 바꿨습니다.

FreeRDP와의 연결 지점(구현 메모)
| bridge 기능 | FreeRDP 쪽 |
| --- | --- |
| 접속 스레드 | `freerdp_client_context_new` → `freerdp_client_start` (`client/common`) |
| 프레임 | GDI(`gdi_init`, BGRA32) + `EndPaint` 콜백에서 무효 영역을 싱크로 복사 |
| 인증 | `instance->AuthenticateEx` |
| 인증서 | `instance->VerifyCertificateEx` / `VerifyChangedCertificateEx` |
| 키·마우스 | `freerdp_input_send_keyboard_event_ex`, `freerdp_input_send_unicode_keyboard_event`, `freerdp_input_send_mouse_event` |
| 해상도 | disp 채널 `DispClientContext->SendMonitorLayout` |
| 클립보드 | cliprdr 채널 `CliprdrClientContext` (텍스트·이미지 형식) |
| 소리·마이크 | rdpsnd·audin 채널. **플랫폼 백엔드가 FreeRDP 안에서 직접 재생·녹음** (7장) |

---

## 3. Dart 패키지 구성 (federated plugin)

```
packages/
├── remote_desktop/                     # 앱이 쓰는 API: RemoteSession, RemoteView 위젯
├── remote_desktop_platform_interface/  # 플랫폼 공통 인터페이스
├── remote_desktop_ffi/                 # rdp_bridge FFI 바인딩 (직접 작성) — 웹 제외 공통
├── remote_desktop_android/             # Kotlin: SurfaceProducer + JNI 싱크, rdp_bridge.so 포함
├── remote_desktop_darwin/              # Swift: iOS·macOS 공용 FlutterTexture 싱크
├── remote_desktop_windows/             # C++: 픽셀 버퍼 텍스처 싱크
├── remote_desktop_linux/               # C: FlPixelBufferTexture 싱크
└── remote_desktop_web/                 # WebSocket 게이트웨이 클라이언트 (9장)
```

앱 쪽 사용 흐름
```dart
final session = RemoteSession.rdp(config);            // rdpb_create
final view = await RemoteView.create(session);        // plugin이 텍스처 생성 → (textureId, sinkPtr)
//   내부: rdpb_attach_sink(session, Pointer.fromAddress(sinkPtr))
session.events.listen(onEvent);                       // NativeCallable.listener → Stream
await session.connect();                              // rdpb_connect
// build(): Texture(textureId: view.textureId) + 입력 처리 위젯
```

- 플랫폼 plugin의 MethodChannel(`remote_desktop/texture`) 호출은 `createTexture`, `resizeTexture`, `disposeTexture` 세 개입니다. `createTexture`는 `textureId`와 `sinkPtr`(네이티브 `rdpb_frame_sink` 구조체 주소)을 돌려줍니다. 반대 방향으로는 Surface가 새로 만들어졌을 때 `surfaceAvailable(textureId)`를 보내고, Dart가 `rdpb_request_redraw`를 부릅니다.
- `resizeTexture`가 필요한 이유: Android `SurfaceProducer`는 `setSize`를 부르면 Surface를 새로 만들기 때문에, 원격 해상도가 바뀔 때 Kotlin에서 새 Surface를 싱크에 다시 넘겨야 합니다.
- 해제 순서: `rdpb_attach_sink(session, NULL)`(Dart) → `disposeTexture`(plugin). 순서가 바뀌면 세션 스레드가 해제된 싱크에 그립니다.
- 이후 픽셀 경로는 bridge → 싱크 → 엔진입니다. Dart는 관여하지 않습니다.
- 이벤트 콜백은 `NativeCallable<rdpb_event_cb>.listener`로 만듭니다. FreeRDP 스레드에서 호출되어도 Dart isolate로 안전하게 전달됩니다.

---

## 4. 플랫폼별 텍스처 싱크

| 플랫폼 | Flutter 텍스처 | 싱크 `begin` / `end` 구현 | plugin 언어 |
| --- | --- | --- | --- |
| Android | `TextureRegistry.SurfaceProducer` → `Surface` | JNI로 `ANativeWindow_fromSurface`. `begin` = `ANativeWindow_setBuffersGeometry` + `ANativeWindow_lock`(무효 영역 전달), `end` = `ANativeWindow_unlockAndPost`(알림 포함) | Kotlin + C(JNI, bridge .so에 포함) |
| iOS·macOS | `FlutterTexture` (`copyPixelBuffer`) | `CVPixelBufferPool`(IOSurface 지원)에서 **프레임마다 새 버퍼**를 받아 화면 전체를 복사합니다. `begin` = `CVPixelBufferLockBaseAddress`, `end` = unlock + 최신 프레임 교체 + `textureFrameAvailable`. 버퍼 2개를 교대로 쓰면 엔진이 읽는 버퍼에 다시 쓰게 되어, 넘긴 버퍼에는 다시 쓰지 않는 방식으로 바꿨습니다(전체 복사 비용은 추후 최적화) | Swift + C 함수 포인터 |
| Windows | `FlutterDesktopPixelBufferTextureConfig` | 내부 BGRA 버퍼 2개를 교대로 씁니다. `end` = `MarkTextureFrameAvailable`, 엔진이 콜백으로 최신 버퍼를 가져갑니다. 성능이 부족하면 D3D11 공유 텍스처(`FlutterDesktopGpuSurfaceDescriptor`)로 바꿉니다 | C++ |
| Linux | `FlPixelBufferTexture` 서브클래스 | 내부 버퍼 2개를 교대로 쓰고 `fl_texture_registrar_mark_texture_frame_available`로 알립니다 | C (GTK) |

공통 사항
- **픽셀 형식:** FreeRDP GDI는 `PIXEL_FORMAT_BGRA32`로 설정합니다. Android는 `RGBA_8888`이라 bridge가 FreeRDP 형식을 `RGBX32`로 맞춥니다.
- **무효 영역만 복사:** `EndPaint`의 invalid region만 싱크에 복사합니다. 버퍼를 교대로 쓰는 플랫폼은 이전 프레임의 무효 영역도 함께 복사해 두 버퍼를 일치시킵니다.
- **스레드:** 싱크는 FreeRDP 스레드에서 실행됩니다. 엔진은 래스터 스레드에서 읽으므로 버퍼 교대와 잠금으로 경합을 막습니다.
- **H.264(추후):** Android는 MediaCodec 출력을 같은 `Surface`로 바로 보내고, Apple은 VideoToolbox의 `CVPixelBuffer`를 그대로 넘깁니다(8장).

---

## 5. 빌드 환경과 산출물

### 5.1 호스트 역할

| 호스트 | 빌드 대상 |
| --- | --- |
| **Windows PC (주 환경)** | Flutter: Android, Windows, 웹 앱. **WSL2(Ubuntu)**: `scripts/build.sh`로 FreeRDP `windows-x86_64`, `android-arm64`, `linux-x86_64`, `linux-arm64`, 그리고 Flutter Linux 앱 |
| **iMac** | Flutter: iOS, macOS 앱. `scripts/build.sh`로 FreeRDP `macos-*` (iOS 타깃은 추가 예정, Xcode 전체 설치 필요) |

### 5.2 FreeRDP 산출물 현황과 plugin용으로 필요한 형태

| 타깃 | 현재 `build.sh` 산출물 | plugin용으로 필요한 형태 | 상태 |
| --- | --- | --- | --- |
| android-arm64 | `dist/android-arm64/{include,lib}` 정적 라이브러리 7개 | 그대로 사용. plugin의 CMake가 `rdp_bridge` + 정적 라이브러리를 `librdp_bridge.so` 하나로 링크 | ✅ FreeRDP 빌드·링크 확인 (iMac), 🔧 plugin과 함께 APK 빌드는 미검증 |
| android-x86_64 | `dist/android-x86_64/{include,lib}` (에뮬레이터용, Intel 호스트) | 위와 같음 | 🔧 타깃 추가, 실빌드 미검증 |
| windows-x86_64 | `sdl-freerdp.exe` | **`rdp_bridge.dll`** (llvm-mingw, C 함수만 내보냄). Flutter C++ plugin(MSVC)은 이 DLL을 링크하지 않고 `sinkPtr`만 주고받으므로 컴파일러가 달라도 됩니다 | 🔧 bridge 추가 |
| macos-* | `sdl-freerdp` + `lib/libfreerdp_all.a`, `lib/librdp_bridge.a` | 두 정적 라이브러리를 `packages/remote_desktop_darwin/macos/Libraries/`에 복사(여러 CPU는 `lipo`로 합침). plugin의 podspec이 자기 프레임워크에 링크하고 Dart는 `DynamicLibrary.process()`로 찾음 | 🔧 스크립트·plugin 작성됨, Mac 빌드 미검증 |
| ios-arm64 / 시뮬레이터 | 없음 | 정적 라이브러리 xcframework | 🔧 타깃 추가 (Xcode 필요) |
| linux-x86_64 / arm64 | `sdl-freerdp` (WSL2) | 정적 라이브러리 → `librdp_bridge.so` | 🔧 SDK 출력 추가, ❓ WSL2 실빌드 미검증 |

다음 단계로 `build.sh`에 `native/rdp_bridge/`를 함께 빌드해 `dist/<타깃>/`에 넣는 기능을 추가합니다.

---

## 6. 입력

| 항목 | 방식 | 비고 |
| --- | --- | --- |
| 하드웨어 키보드 | Flutter `HardwareKeyboard`의 `PhysicalKeyboardKey`(USB HID 코드) → RDP 스캔코드 표 → `rdpb_send_key` | 표 하나로 모든 플랫폼을 처리합니다(FreeRDP `libfreerdp/locale` 참고) |
| 소프트 키보드 (Android·iOS) | 확정된 문자 → `rdpb_send_unicode` | 스캔코드가 없는 입력에 사용합니다 |
| **한글** | 하드웨어 키보드는 한/영(`0x72`)과 한자(`0x71`) 스캔코드를 보내 **서버 쪽 입력기로 조합**합니다. 소프트 키보드는 조합이 끝난 글자를 유니코드로 보냅니다 | ❓ gnome-remote-desktop의 유니코드 입력 처리, ❓ 플랫폼별 Flutter IME 동작 |
| 마우스·터치 | 포인터 이벤트 → 원격 좌표로 변환 → `rdpb_send_mouse`. 터치는 탭=클릭, 길게 누르기=우클릭, 두 손가락=스크롤 | |
| 브라우저 제약 | Ctrl+W, Alt+Tab 등은 브라우저나 OS가 먼저 가져가 전달되지 않습니다 | 웹만 해당 |

---

## 7. 부가 기능 지원 현황

FreeRDP 빌드 설정(`build/<타깃>/FreeRDP/CMakeCache.txt`)에서 확인한 채널과 백엔드 기준입니다. 서버 지원 여부는 gnome-remote-desktop 버전에 따라 다르므로 ❓로 표시했습니다.

| 기능 | FreeRDP 채널 | 빌드 상태 | 플랫폼 백엔드 | 앱에서 할 일 | 서버 |
| --- | --- | --- | --- | --- | --- |
| 키보드·마우스 | 기본 입력 | ✅ | — | 6장 매핑 | ✅ |
| 화면 해상도 자동 변경 | disp | ✅ 전 타깃 ON | — | 창·화면 회전 시 `rdpb_resize` | ❓ 모드에 따라 다름 |
| 클립보드 텍스트·이미지 | cliprdr | ✅ 전 타깃 ON | — | 플랫폼 클립보드와 형식 변환 (bridge에서 구현) | ✅ (텍스트) ❓ (이미지) |
| 클립보드 파일 복사 | cliprdr (FileContents) | ⚠️ FreeRDP의 파일 클립보드 도우미는 FUSE를 쓰는데 현재 OFF | — | 파일 목록·내용 요청을 bridge에서 직접 처리 🔧 | ❓ 버전에 따라 다름 |
| 소리 재생 | rdpsnd | ✅ 전 타깃 ON | Android: OpenSL ES ✅ / macOS: CoreAudio ✅ / Windows: WinMM ✅ / Linux: PulseAudio(새 스크립트에서 ON, 미검증) / iOS: AudioQueue 🔧 | 켜기·끄기만 설정 | ✅ |
| 마이크 입력 | audin | ✅ 전 타깃 ON | 위와 같은 백엔드 | **OS 권한 요청 필요**: Android `RECORD_AUDIO`, iOS `NSMicrophoneUsageDescription`, macOS 마이크 권한 | ❓ 최신 버전부터 지원 |
| 파일 전송 (드라이브 공유) | rdpdr + drive | ✅ ON | — | 공유 폴더 경로 설정 | ❓ 지원하지 않을 가능성이 큼 → 클립보드 파일 복사로 대체 |
| H.264 화면 | rdpgfx AVC | ❌ OpenH264·FFmpeg·MediaCodec 모두 OFF | — | 8장 | ❓ |

정리하면:
- **키보드, 마우스, 해상도 변경, 클립보드 텍스트, 소리 재생**은 FreeRDP가 이미 갖추고 있습니다. bridge에서 연결만 하면 됩니다.
- **마이크**는 FreeRDP가 지원합니다. 앱에서 OS 권한을 받는 처리와 서버 지원 확인이 필요합니다.
- **파일 전송**은 가장 손이 많이 갑니다. 서버가 드라이브 공유를 지원하지 않으면 클립보드 파일 복사를 직접 구현해야 합니다.
- **반드시 먼저 확인할 것:** 서버에서 `apt policy gnome-remote-desktop`으로 버전을 보고, `sdl-freerdp /log-level:DEBUG` 접속 로그로 서버가 실제로 여는 채널(cliprdr, rdpsnd, audin, rdpdr, disp)을 확인합니다.

---

## 8. 화면 코덱 계획

- **현재:** H.264가 꺼져 있어 서버는 RemoteFX·Progressive 같은 CPU 코덱으로 보냅니다. FreeRDP의 SIMD 최적화(x86: SSE·AVX, arm64: NEON)로 디코딩합니다. 1단계에서는 이대로 갑니다.
- **2단계(성능 개선):** 하드웨어 H.264 디코딩을 추가합니다.
  - Android: FreeRDP의 `WITH_MEDIACODEC` 옵션(실험적)을 쓰거나, bridge에서 AVC 데이터를 받아 MediaCodec → 텍스처 `Surface`로 직접 보냅니다.
  - iOS·macOS: VideoToolbox → `CVPixelBuffer` → 텍스처.
  - Windows: FreeRDP의 Media Foundation 백엔드(`h264_mf.c`)를 씁니다.
  - AVC444(영상 두 개를 합치는 방식)는 서버 설정에 따라 필요할 수 있습니다. ❓

---

## 9. 웹

웹은 **프로그램이 2개**입니다.

```
[브라우저] remote_desktop_web (Flutter Web)  ── 화면 표시·입력
     │ HTTPS + WebSocket(WSS)
     ▼
[서버] 게이트웨이 ── rdp_bridge(FFI) + FreeRDP (Linux 빌드)
     │ RDP
     ▼
[Ubuntu] gnome-remote-desktop :3389
```

| 프로그램 | 실행 위치 | 내용 |
| --- | --- | --- |
| 웹 앱 | 사용자 브라우저 (파일은 게이트웨이가 제공) | `Texture` 대신 canvas 또는 WebCodecs로 그립니다. 입력은 WebSocket으로 보냅니다 |
| 게이트웨이 | **Ubuntu 서버 자체(권장, `127.0.0.1:3389` 직접 접속)** 또는 별도 서버 | rdp_bridge로 접속합니다. 싱크로 받은 무효 영역을 JPEG·WebP로 압축해 전송합니다(나중에 H.264 전달). 입력 메시지를 `rdpb_send_*`로 넘깁니다 |

- **게이트웨이 언어:** **Dart 서버(`dart:ffi`)**로 만들면 앱과 같은 `remote_desktop_ffi` 바인딩을 그대로 재사용할 수 있습니다.
- **WebSocket 메시지(초안):** `frame{x,y,w,h,codec,bytes}`, `cursor`, `clipboard`, `state` / `key{scancode,ext,down}`, `unicode`, `mouse`, `wheel`, `resize`, `clipboard`
- **보안:** 외부에 공개되므로 HTTPS, 로그인, 접속 대상 화이트리스트가 필수입니다. 지금처럼 SSH 터널로만 들어가는 구조보다 노출이 커집니다.
- **대안:** 이미 만들어진 Apache Guacamole을 게이트웨이로 쓰고 웹 UI만 만들 수 있습니다.

---

## 10. VNC (추후)

- `RemoteSession` 인터페이스와 프레임 싱크를 그대로 재사용합니다. 싱크 구조체가 프로토콜과 무관하기 때문입니다.
- **libvncclient는 GPL-2.0입니다.** 앱을 배포하면 앱 소스 공개 의무가 생길 수 있습니다.
- RFB 프로토콜(RFC 6143)은 단순하므로 **C로 직접 구현**하는 것을 권합니다(`vnc_bridge`, 같은 C API 형태). Raw·CopyRect·ZRLE 인코딩과 인증부터 시작합니다. gnome-remote-desktop VNC의 인증 방식은 확인이 필요합니다. ❓

---

## 11. 단계별 진행

| 단계 | 내용 | 완료 기준 |
| --- | --- | --- |
| P0 | `rdp_bridge` C API + Android plugin | Android에서 접속, 화면 표시, 키보드·마우스 동작. **코드 작성됨**(`native/rdp_bridge`, `packages/`). bridge와 Dart FFI는 Linux에서 FreeRDP 예제 서버로 확인, Android 기기 실행은 미검증 |
| P1 | 인증·인증서 UI, 해상도 변경, 클립보드 텍스트, 소리 재생 | gnome-remote-desktop에서 일상 사용 가능 |
| P2 | Windows(`rdp_bridge.dll`) · macOS plugin | 데스크톱 2종 동작. **macOS 코드 작성됨**(`packages/remote_desktop_darwin`), Mac 빌드·실행은 미검증. Windows는 시작 전 |
| P3 | iOS (Xcode, AudioQueue 백엔드, 백그라운드 처리) | iPhone 동작 |
| P4 | Linux plugin (WSL2 빌드 검증 포함) | Linux 동작 |
| P5 | 마이크, 클립보드 파일·이미지 | 서버 지원 범위 안에서 동작 |
| P6 | 웹 게이트웨이 + 웹 앱 | 브라우저 접속 |
| P7 | H.264 하드웨어 디코딩, VNC | 성능 개선, 프로토콜 추가 |

## 12. 미해결 항목

1. gnome-remote-desktop 버전과 지원 채널 확인 (7장의 ❓ 항목)
2. 한글 입력: 서버 입력기 방식과 유니코드 방식의 실제 동작
3. WSL2에서 `linux-*`, `windows-x86_64`, `android-arm64` 실빌드 검증
4. Windows: mingw로 빌드한 `rdp_bridge.dll`과 MSVC Flutter 앱의 조합 검증
5. iOS: 백그라운드 전환 시 연결 유지 정책
6. Android: `SurfaceProducer`(ImageReader)의 Surface에 `ANativeWindow_lock`으로 CPU에서 쓰는 방식이 Impeller(Vulkan) 기기에서 문제없는지 실제 기기 확인
7. gnome-remote-desktop은 그래픽 파이프라인(rdpgfx)으로 화면을 보냅니다. bridge는 이를 켜 두었지만 예제 서버는 이 경로를 쓰지 않아 실제 서버 확인이 필요합니다. 해상도 변경(disp)과 클립보드(cliprdr)도 같습니다.
8. 커서: 원격 커서 모양(`RDPB_EV_CURSOR`)은 아직 전달하지 않습니다. 터치에서는 필요 없고, 하드웨어 마우스를 쓰면 Android 시스템 커서가 보입니다.
9. `scripts/build.sh`의 `linux-*` 타깃은 WinPR이 ICU를 요구해 `libicu-dev` 없이는 실패합니다. `-DWITH_UNICODE_BUILTIN=ON`을 주면 됩니다(Android에는 적용함).
10. 라이선스: FreeRDP·OpenSSL은 Apache-2.0이라 정적 링크와 상용 배포가 가능합니다(고지 필요). GPL 라이브러리는 사용하지 않습니다.
