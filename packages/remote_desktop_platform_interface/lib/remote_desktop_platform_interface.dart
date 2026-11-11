import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/method_channel_remote_desktop.dart';

/// 플랫폼 plugin이 만든 텍스처.
class RemoteTexture {
  const RemoteTexture({required this.textureId, required this.sinkAddress});

  /// Flutter `Texture` 위젯에 넘기는 ID.
  final int textureId;

  /// 네이티브 `rdpb_frame_sink` 구조체의 주소. `RemoteSession.attachSink`에 넘깁니다.
  final int sinkAddress;
}

/// 플랫폼별 텍스처 plugin의 공통 인터페이스 (설계 3·4장).
///
/// 픽셀은 이 인터페이스를 거치지 않습니다. 네이티브 bridge가 싱크에 직접 씁니다.
abstract class RemoteDesktopPlatform extends PlatformInterface {
  RemoteDesktopPlatform() : super(token: _token);

  static final Object _token = Object();

  static RemoteDesktopPlatform _instance = MethodChannelRemoteDesktop();

  static RemoteDesktopPlatform get instance => _instance;

  static set instance(RemoteDesktopPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// 원격 화면 크기(픽셀)의 텍스처와 프레임 싱크를 만듭니다.
  Future<RemoteTexture> createTexture(int width, int height);

  /// 원격 화면 크기가 바뀌었을 때 텍스처 크기를 맞춥니다.
  Future<void> resizeTexture(int textureId, int width, int height);

  /// 텍스처와 싱크를 해제합니다. 호출 전에 세션에서 싱크를 떼어야 합니다.
  Future<void> disposeTexture(int textureId);

  /// 텍스처의 그리기 대상이 새로 만들어졌을 때(앱이 백그라운드에서 돌아온 경우 등)
  /// 해당 textureId를 내보냅니다. 받은 쪽은 화면 전체를 다시 그려야 합니다.
  Stream<int> get surfaceAvailable;
}
