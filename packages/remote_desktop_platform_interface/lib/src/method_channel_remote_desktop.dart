import 'dart:async';

import 'package:flutter/services.dart';

import '../remote_desktop_platform_interface.dart';

/// MethodChannel `remote_desktop/texture`를 쓰는 기본 구현.
/// Android·iOS·macOS·Windows·Linux plugin이 같은 채널 규약을 따릅니다.
class MethodChannelRemoteDesktop extends RemoteDesktopPlatform {
  MethodChannelRemoteDesktop() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final _channel = const MethodChannel('remote_desktop/texture');
  final _surfaceAvailable = StreamController<int>.broadcast();

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'surfaceAvailable') {
      _surfaceAvailable.add(call.arguments as int);
    }
  }

  @override
  Future<RemoteTexture> createTexture(int width, int height) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'createTexture',
      {'width': width, 'height': height},
    );
    return RemoteTexture(
      textureId: result!['textureId']! as int,
      sinkAddress: result['sinkPtr']! as int,
    );
  }

  @override
  Future<void> resizeTexture(int textureId, int width, int height) {
    return _channel.invokeMethod<void>('resizeTexture', {
      'textureId': textureId,
      'width': width,
      'height': height,
    });
  }

  @override
  Future<void> disposeTexture(int textureId) {
    return _channel.invokeMethod<void>('disposeTexture', {
      'textureId': textureId,
    });
  }

  @override
  Stream<int> get surfaceAvailable => _surfaceAvailable.stream;
}
