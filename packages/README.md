# Flutter 원격 데스크톱 plugin (Android 우선)

설계는 [docs/plugin-design.md](../docs/plugin-design.md)를 참고하세요. 현재 단계는 P0(Android)입니다.

```
native/rdp_bridge/                    # C: FreeRDP 위의 작은 API + Android 프레임 싱크(JNI)
packages/
├── remote_desktop/                   # 앱이 쓰는 패키지: RdpSession, RemoteView 위젯, example/
├── remote_desktop_platform_interface/  # 텍스처 생성·해제 인터페이스 (MethodChannel 기본 구현)
├── remote_desktop_ffi/               # rdp_bridge의 dart:ffi 바인딩 (Flutter 없이도 사용)
└── remote_desktop_android/           # Kotlin: SurfaceProducer 텍스처, librdp_bridge.so 빌드
```

## Android 앱 빌드 (macOS, Linux/WSL2 공통)

Android 앱은 macOS에서도 빌드됩니다. iOS와 달리 호스트 제약이 없습니다.

### 1. 도구 준비 (관리자 권한 없이 홈 폴더에 설치 가능)

| 도구 | 설치 |
| --- | --- |
| Flutter SDK (3.29 이상) | `git clone -b stable https://github.com/flutter/flutter.git ~/tools/flutter` 후 `~/tools/flutter/bin`을 PATH에 추가 |
| JDK 17 | Android Studio에 포함된 JDK를 쓰거나, Temurin 17 `tar.gz`를 `~/tools`에 풀고 `JAVA_HOME` 지정 |
| Android SDK | Android Studio(사용자 `Applications` 폴더에 설치 가능)의 SDK Manager, 또는 명령줄 도구를 `~/Library/Android/sdk/cmdline-tools/latest`에 풀고 `sdkmanager` 사용 |
| SDK 구성 요소 | `platform-tools`, `platforms;android-36`, `build-tools`, **NDK**, **CMake 3.22.1** |

```sh
sdkmanager "platform-tools" "platforms;android-36" "cmake;3.22.1"   # NDK는 첫 빌드 때 Gradle이 받습니다
flutter doctor --android-licenses
flutter doctor
```

### 2. FreeRDP 정적 라이브러리 빌드

저장소 최상위에서 실행합니다. 쓰려는 대상에 맞는 것만 빌드하면 됩니다.

```sh
bash scripts/build.sh android-arm64     # 실제 기기 (거의 모든 폰·태블릿)
bash scripts/build.sh android-x86_64    # Intel Mac·Windows PC의 에뮬레이터
```

plugin의 Gradle은 `dist/android-*`가 있는 ABI만 앱에 넣습니다. 이전에 만들어 둔 `dist/android-arm64`가 있어도
문자열 변환 설정(`WITH_UNICODE_BUILTIN`)이 바뀌었으므로 한 번 다시 실행하세요.

### 3. 예제 앱 실행

```sh
cd packages/remote_desktop/example
flutter create --platforms=android --org com.aha645 --project-name remote_desktop_example .   # android/ 폴더 생성 (처음 한 번, lib/는 유지됨)
flutter run                                              # 연결된 기기 또는 에뮬레이터
flutter build apk --target-platform android-arm64        # 배포용 APK
```

SSH 터널로 접속하려면 폰에서 터널을 열 수 없으므로, PC에서 `adb reverse tcp:13389 tcp:13389`를 실행해
폰의 `127.0.0.1:13389`를 PC의 터널로 연결합니다(USB 디버깅 중일 때).

## 기기 없이 확인하기

bridge와 Dart FFI는 Linux에서 FreeRDP 예제 서버(`sfreerdp-server`)로 확인할 수 있습니다.

```sh
cmake -S native/rdp_bridge -B build/bridge-host -DRDPB_FREERDP_DIR=<FreeRDP 설치 폴더>
cmake --build build/bridge-host
build/bridge-host/rdp_bridge_test 127.0.0.1 13389 사용자 비밀번호          # C: 프레임 수신 확인
cd packages/remote_desktop_ffi
dart run example/connect.dart ../../build/bridge-host/librdp_bridge.so 127.0.0.1 13389 사용자 비밀번호
```

## 앱에서 사용

```dart
final session = RdpSession(RdpConfig(host: '127.0.0.1', port: 13389, username: 'me'));
session.events.listen((event) {
  switch (event) {
    case RemoteAuthRequest():        session.answerAuth(ok: true, password: '...');
    case RemoteCertificateRequest(): session.answerCertificate(accept: true);
    default:
  }
});
final view = await RemoteViewController.create(session);
session.connect();
// build(): RemoteView(controller: view, matchViewSize: true)
// 끝낼 때: view.dispose(); session.dispose();   ← 이 순서
```
