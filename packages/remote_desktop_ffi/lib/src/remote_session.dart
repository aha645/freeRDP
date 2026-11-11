// 프로토콜과 무관한 세션 인터페이스와 이벤트 (설계 3장). VNC도 같은 인터페이스를 구현합니다.

enum RemoteState { connecting, connected, disconnected }

/// 인증서 확인 방식.
enum CertificatePolicy {
  /// 항상 [RemoteCertificateRequest]로 묻습니다.
  ask,

  /// 확인하지 않습니다. SSH 터널(127.0.0.1)로 접속할 때만 쓰세요.
  ignore,

  /// 처음 본 인증서는 저장하고, 바뀌었을 때만 묻습니다.
  trustOnFirstUse,
}

/// 마우스 버튼. [RemoteSession.sendMouseButton]에 씁니다.
enum RemoteMouseButton { left, right, middle }

sealed class RemoteEvent {
  const RemoteEvent();
}

class RemoteStateChanged extends RemoteEvent {
  const RemoteStateChanged(this.state, {this.errorCode = 0, this.errorName});
  final RemoteState state;

  /// FreeRDP 오류 코드. 0이면 정상 종료.
  final int errorCode;
  final String? errorName;

  @override
  String toString() =>
      'RemoteStateChanged($state, 0x${errorCode.toRadixString(16)} $errorName)';
}

/// 비밀번호가 필요합니다. [RemoteSession.answerAuth]로 답합니다.
class RemoteAuthRequest extends RemoteEvent {
  const RemoteAuthRequest({this.username});
  final String? username;

  @override
  String toString() => 'RemoteAuthRequest($username)';
}

/// 서버 인증서를 믿을지 묻습니다. [RemoteSession.answerCertificate]로 답합니다.
class RemoteCertificateRequest extends RemoteEvent {
  const RemoteCertificateRequest({
    required this.host,
    required this.port,
    required this.commonName,
    required this.subject,
    required this.issuer,
    required this.fingerprint,
    this.oldFingerprint,
    required this.changed,
    required this.hostMismatch,
  });
  final String host;
  final int port;
  final String commonName;
  final String subject;
  final String issuer;
  final String fingerprint;

  /// [changed]일 때, 저장해 두었던 이전 인증서의 지문.
  final String? oldFingerprint;

  /// 저장해 둔 인증서와 다릅니다(중간자 공격 가능성).
  final bool changed;

  /// 인증서의 이름이 접속한 주소와 다릅니다.
  final bool hostMismatch;

  @override
  String toString() =>
      'RemoteCertificateRequest($host:$port $fingerprint changed=$changed)';
}

class RemoteDesktopSize extends RemoteEvent {
  const RemoteDesktopSize(this.width, this.height);
  final int width;
  final int height;

  @override
  String toString() => 'RemoteDesktopSize(${width}x$height)';
}

class RemoteClipboardText extends RemoteEvent {
  const RemoteClipboardText(this.text);
  final String text;

  @override
  String toString() => 'RemoteClipboardText(${text.length}자)';
}

abstract interface class RemoteSession {
  /// 세션 이벤트(broadcast). [connect] 전에 구독하세요.
  Stream<RemoteEvent> get events;

  /// 접속을 시작합니다. 결과는 [RemoteStateChanged]로 옵니다. 세션당 한 번만 부를 수 있습니다.
  void connect();
  void disconnect();

  /// 세션을 끝내고 자원을 풉니다. 이후에는 어떤 함수도 부르면 안 됩니다.
  void dispose();

  void answerAuth({required bool ok, String? password});
  void answerCertificate({required bool accept, bool remember = false});

  /// 키보드 스캔코드(세트 1). [extended]는 E0 접두 키(방향키, 오른쪽 Ctrl 등).
  void sendKey(int scancode, {bool extended = false, required bool down});

  /// 문자를 유니코드로 직접 입력합니다(소프트 키보드용). 누름과 뗌을 함께 보냅니다.
  void sendText(String text);

  /// 마우스 이동. 좌표는 원격 화면 픽셀.
  void sendMouseMove(int x, int y);
  void sendMouseButton(
    RemoteMouseButton button,
    int x,
    int y, {
    required bool down,
  });

  /// 휠. [delta]는 한 칸에 120, 양수가 위(또는 오른쪽).
  void sendWheel(int delta, {bool horizontal = false});

  /// 원격 해상도 변경을 요청합니다(서버가 지원할 때).
  void resize(int width, int height);
  void setClipboardText(String text);

  /// 플랫폼 텍스처의 프레임 싱크(네이티브 주소)를 연결합니다.
  void attachSink(int sinkAddress);
  void detachSink();

  /// 화면 전체를 싱크에 다시 그립니다.
  void requestRedraw();
}
