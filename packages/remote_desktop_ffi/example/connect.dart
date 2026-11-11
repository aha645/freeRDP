// 기기 없이 Dart FFI 경로를 확인하는 명령줄 예제.
//   dart run example/connect.dart <librdp_bridge.so 경로> <호스트> <포트> <사용자> <비밀번호>
// 화면은 받지 않고(싱크 없음) 접속·인증·이벤트만 확인한 뒤 3초 후 종료합니다.
import 'dart:async';
import 'dart:io';

import 'package:remote_desktop_ffi/remote_desktop_ffi.dart';

Future<void> main(List<String> args) async {
  if (args.length < 5) {
    stderr.writeln(
      '사용법: dart run example/connect.dart <라이브러리> <호스트> <포트> <사용자> <비밀번호>',
    );
    exit(2);
  }
  final session = RdpSession(
    RdpConfig(
      host: args[1],
      port: int.parse(args[2]),
      username: args[3],
      audioPlayback: false,
    ),
    bridge: RdpBridge.open(args[0]),
  );
  final done = Completer<bool>();
  var connected = false;

  session.events.listen((event) {
    stdout.writeln('이벤트: $event');
    switch (event) {
      case RemoteAuthRequest():
        session.answerAuth(ok: true, password: args[4]);
      case RemoteCertificateRequest():
        session.answerCertificate(accept: true);
      case RemoteStateChanged(state: RemoteState.connected):
        connected = true;
        session
          ..sendMouseMove(10, 10)
          ..sendText('한글')
          ..setClipboardText('dart');
        Timer(const Duration(seconds: 3), session.disconnect);
      case RemoteStateChanged(state: RemoteState.disconnected):
        done.complete(connected);
      default:
    }
  });

  session.connect();
  final ok = await done.future.timeout(
    const Duration(seconds: 30),
    onTimeout: () => false,
  );
  session.dispose();
  stdout.writeln(ok ? '성공' : '실패');
  exit(ok ? 0 : 1);
}
