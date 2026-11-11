/// Flutter 원격 데스크톱 플러그인.
///
/// ```dart
/// final session = RdpSession(RdpConfig(host: '127.0.0.1', port: 13389, username: 'me'));
/// session.events.listen(onEvent);              // 비밀번호·인증서 질문, 상태
/// final view = await RemoteViewController.create(session);
/// session.connect();
/// // build(): RemoteView(controller: view)
/// ```
library;

export 'package:remote_desktop_ffi/remote_desktop_ffi.dart';

export 'src/remote_view.dart';
export 'src/scancodes.dart';
