import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'remote_session.dart';

class RdpConfig {
  const RdpConfig({
    required this.host,
    this.port = 3389,
    this.username,
    this.domain,
    this.width = 1280,
    this.height = 720,
    this.dynamicResolution = true,
    this.clipboard = true,
    this.audioPlayback = true,
    this.microphone = false,
    this.certificatePolicy = CertificatePolicy.ask,
    this.configDir,
  });

  final String host;
  final int port;
  final String? username;
  final String? domain;

  /// 처음 요청할 원격 화면 크기(픽셀).
  final int width;
  final int height;
  final bool dynamicResolution;
  final bool clipboard;
  final bool audioPlayback;
  final bool microphone;
  final CertificatePolicy certificatePolicy;

  /// 알려진 인증서를 저장할 폴더. null이면 `$HOME/.config/freerdp`.
  final String? configDir;
}

// rdpb_send_mouse의 flags (rdp_bridge.h)
const _mouseMove = 0x0800;
const _mouseDown = 0x8000;
const _mouseButtons = {
  RemoteMouseButton.left: 0x1000,
  RemoteMouseButton.right: 0x2000,
  RemoteMouseButton.middle: 0x4000,
};

// rdpb_cert_flags
const _certChanged = 1;
const _certMismatch = 2;

/// FreeRDP(rdp_bridge) 세션.
class RdpSession implements RemoteSession {
  RdpSession(RdpConfig config, {RdpBridge? bridge})
      : _bridge = bridge ?? RdpBridge.shared {
    _callable = NativeCallable<RdpbEventCallback>.listener(_onEvent);
    using((arena) {
      final cfg = arena<RdpbConfig>();
      cfg.ref
        ..host = config.host.toNativeUtf8(allocator: arena)
        ..port = config.port
        ..username = _nullable(config.username, arena)
        ..domain = _nullable(config.domain, arena)
        ..width = config.width
        ..height = config.height
        ..dynamicResolution = config.dynamicResolution ? 1 : 0
        ..clipboard = config.clipboard ? 1 : 0
        ..audioPlayback = config.audioPlayback ? 1 : 0
        ..microphone = config.microphone ? 1 : 0
        ..certPolicy = config.certificatePolicy.index
        ..configDir = _nullable(config.configDir, arena);
      _handle = _bridge.create(cfg, _callable.nativeFunction, nullptr);
    });
    if (_handle == nullptr) {
      _callable.close();
      throw StateError('rdpb_create 실패 (호스트: ${config.host})');
    }
  }

  final RdpBridge _bridge;
  late final NativeCallable<RdpbEventCallback> _callable;
  Pointer<RdpbSession> _handle = nullptr;
  final _events = StreamController<RemoteEvent>.broadcast();

  static Pointer<Utf8> _nullable(String? value, Allocator allocator) =>
      value == null ? nullptr : value.toNativeUtf8(allocator: allocator);

  @override
  Stream<RemoteEvent> get events => _events.stream;

  // 세션 스레드가 보낸 이벤트. 이 함수는 Dart isolate에서 나중에 실행되므로
  // 네이티브가 힙에 둔 이벤트를 읽은 뒤 반드시 풀어 줍니다.
  void _onEvent(Pointer<Void> user, Pointer<RdpbEvent> pointer) {
    try {
      if (_events.isClosed) return;
      final ev = pointer.ref;
      final text = ev.text == nullptr ? null : ev.text.toDartString();
      switch (ev.type) {
        case RdpbEventType.state:
          final index = ev.code - 1;
          if (index >= 0 && index < RemoteState.values.length) {
            _events.add(
              RemoteStateChanged(
                RemoteState.values[index],
                errorCode: ev.a & 0xFFFFFFFF,
                errorName: text,
              ),
            );
          }
        case RdpbEventType.authRequest:
          _events.add(RemoteAuthRequest(username: text));
        case RdpbEventType.certVerify:
          final lines = (text ?? '').split('\n');
          String line(int i) => i < lines.length ? lines[i] : '';
          _events.add(
            RemoteCertificateRequest(
              host: line(0),
              port: ev.a,
              commonName: line(1),
              subject: line(2),
              issuer: line(3),
              fingerprint: line(4),
              oldFingerprint:
                  lines.length > 5 && lines[5].isNotEmpty ? lines[5] : null,
              changed: ev.code & _certChanged != 0,
              hostMismatch: ev.code & _certMismatch != 0,
            ),
          );
        case RdpbEventType.desktopSize:
          _events.add(RemoteDesktopSize(ev.a, ev.b));
        case RdpbEventType.clipboardText:
          _events.add(RemoteClipboardText(text ?? ''));
      }
    } finally {
      _bridge.eventFree(pointer);
    }
  }

  bool get _alive => _handle != nullptr;

  @override
  void connect() {
    if (!_alive) throw StateError('이미 dispose된 세션입니다.');
    if (_bridge.connect(_handle) != 0) {
      throw StateError('rdpb_connect 실패 (이미 접속을 시작했을 수 있음)');
    }
  }

  @override
  void disconnect() {
    if (_alive) _bridge.disconnect(_handle);
  }

  @override
  void dispose() {
    if (!_alive) return;
    final handle = _handle;
    _handle = nullptr;
    _bridge.attachSink(handle, nullptr);
    _bridge.destroy(handle); // 세션 스레드가 끝날 때까지 기다림
    _callable.close();
    _events.close();
  }

  @override
  void answerAuth({required bool ok, String? password}) {
    if (!_alive) return;
    using((arena) {
      _bridge.answerAuth(_handle, ok ? 1 : 0, _nullable(password, arena));
    });
  }

  @override
  void answerCertificate({required bool accept, bool remember = false}) {
    if (_alive) _bridge.answerCert(_handle, accept ? 1 : 0, remember ? 1 : 0);
  }

  @override
  void sendKey(int scancode, {bool extended = false, required bool down}) {
    if (_alive) {
      _bridge.sendKey(_handle, scancode, extended ? 1 : 0, down ? 1 : 0);
    }
  }

  @override
  void sendText(String text) {
    if (!_alive) return;
    for (final unit in text.codeUnits) {
      _bridge.sendUnicode(_handle, unit, 1);
      _bridge.sendUnicode(_handle, unit, 0);
    }
  }

  @override
  void sendMouseMove(int x, int y) {
    if (_alive) _bridge.sendMouse(_handle, _mouseMove, x, y);
  }

  @override
  void sendMouseButton(
    RemoteMouseButton button,
    int x,
    int y, {
    required bool down,
  }) {
    if (_alive) {
      _bridge.sendMouse(
        _handle,
        _mouseButtons[button]! | (down ? _mouseDown : 0),
        x,
        y,
      );
    }
  }

  @override
  void sendWheel(int delta, {bool horizontal = false}) {
    if (_alive) _bridge.sendWheel(_handle, delta, horizontal ? 1 : 0);
  }

  @override
  void resize(int width, int height) {
    if (_alive) _bridge.resize(_handle, width, height);
  }

  @override
  void setClipboardText(String text) {
    if (!_alive) return;
    using((arena) {
      _bridge.clipboardSetText(_handle, text.toNativeUtf8(allocator: arena));
    });
  }

  @override
  void attachSink(int sinkAddress) {
    if (_alive) {
      _bridge.attachSink(
        _handle,
        Pointer<RdpbFrameSink>.fromAddress(sinkAddress),
      );
    }
  }

  @override
  void detachSink() {
    if (_alive) _bridge.attachSink(_handle, nullptr);
  }

  @override
  void requestRedraw() {
    if (_alive) _bridge.requestRedraw(_handle);
  }
}
