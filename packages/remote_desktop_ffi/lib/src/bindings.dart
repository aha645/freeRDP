// native/rdp_bridge/rdp_bridge.h 의 dart:ffi 바인딩.
// 헤더를 바꾸면 이 파일도 같이 고쳐야 합니다(필드 순서·형식이 같아야 함).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class RdpbSession extends Opaque {}

final class RdpbFrameSink extends Opaque {}

final class RdpbConfig extends Struct {
  external Pointer<Utf8> host;
  @Int32()
  external int port;
  external Pointer<Utf8> username;
  external Pointer<Utf8> domain;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int dynamicResolution;
  @Int32()
  external int clipboard;
  @Int32()
  external int audioPlayback;
  @Int32()
  external int microphone;
  @Int32()
  external int certPolicy;
  external Pointer<Utf8> configDir;
}

final class RdpbEvent extends Struct {
  @Int32()
  external int type;
  @Int32()
  external int code;
  @Int32()
  external int a;
  @Int32()
  external int b;
  external Pointer<Utf8> text;
  external Pointer<Uint8> data;
  @Int32()
  external int dataLen;
}

typedef RdpbEventCallback = Void Function(
  Pointer<Void> user,
  Pointer<RdpbEvent> event,
);

/// rdpb_event_type
abstract final class RdpbEventType {
  static const state = 0;
  static const authRequest = 1;
  static const certVerify = 2;
  static const desktopSize = 3;
  static const cursor = 4;
  static const clipboardText = 5;
}

/// 불러온 rdp_bridge 라이브러리의 함수 모음.
class RdpBridge {
  RdpBridge(DynamicLibrary lib)
    : create = lib
          .lookupFunction<
            Pointer<RdpbSession> Function(
              Pointer<RdpbConfig>,
              Pointer<NativeFunction<RdpbEventCallback>>,
              Pointer<Void>,
            ),
            Pointer<RdpbSession> Function(
              Pointer<RdpbConfig>,
              Pointer<NativeFunction<RdpbEventCallback>>,
              Pointer<Void>,
            )
          >('rdpb_create'),
      attachSink = lib
          .lookupFunction<
            Int32 Function(Pointer<RdpbSession>, Pointer<RdpbFrameSink>),
            int Function(Pointer<RdpbSession>, Pointer<RdpbFrameSink>)
          >('rdpb_attach_sink'),
      connect = lib
          .lookupFunction<
            Int32 Function(Pointer<RdpbSession>),
            int Function(Pointer<RdpbSession>)
          >('rdpb_connect'),
      disconnect = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>),
            void Function(Pointer<RdpbSession>)
          >('rdpb_disconnect'),
      destroy = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>),
            void Function(Pointer<RdpbSession>)
          >('rdpb_destroy'),
      eventFree = lib
          .lookupFunction<
            Void Function(Pointer<RdpbEvent>),
            void Function(Pointer<RdpbEvent>)
          >('rdpb_event_free'),
      answerAuth = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>, Int32, Pointer<Utf8>),
            void Function(Pointer<RdpbSession>, int, Pointer<Utf8>)
          >('rdpb_answer_auth'),
      answerCert = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>, Int32, Int32),
            void Function(Pointer<RdpbSession>, int, int)
          >('rdpb_answer_cert'),
      sendKey = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>, Uint16, Int32, Int32),
            void Function(Pointer<RdpbSession>, int, int, int)
          >('rdpb_send_key'),
      sendUnicode = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>, Uint16, Int32),
            void Function(Pointer<RdpbSession>, int, int)
          >('rdpb_send_unicode'),
      sendMouse = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>, Uint16, Int32, Int32),
            void Function(Pointer<RdpbSession>, int, int, int)
          >('rdpb_send_mouse'),
      sendWheel = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>, Int32, Int32),
            void Function(Pointer<RdpbSession>, int, int)
          >('rdpb_send_wheel'),
      resize = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>, Int32, Int32),
            void Function(Pointer<RdpbSession>, int, int)
          >('rdpb_resize'),
      clipboardSetText = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>, Pointer<Utf8>),
            void Function(Pointer<RdpbSession>, Pointer<Utf8>)
          >('rdpb_clipboard_set_text'),
      requestRedraw = lib
          .lookupFunction<
            Void Function(Pointer<RdpbSession>),
            void Function(Pointer<RdpbSession>)
          >('rdpb_request_redraw');

  /// 플랫폼 기본 이름으로 라이브러리를 엽니다. [path]를 주면 그 파일을 엽니다.
  factory RdpBridge.open([String? path]) {
    if (path != null) return RdpBridge(DynamicLibrary.open(path));
    if (Platform.isWindows)
      return RdpBridge(DynamicLibrary.open('rdp_bridge.dll'));
    if (Platform.isMacOS || Platform.isIOS) {
      return RdpBridge(DynamicLibrary.open('rdp_bridge.framework/rdp_bridge'));
    }
    return RdpBridge(DynamicLibrary.open('librdp_bridge.so')); // Android, Linux
  }

  static RdpBridge? _shared;

  /// 앱 전체가 함께 쓰는 인스턴스.
  static RdpBridge get shared => _shared ??= RdpBridge.open();

  final Pointer<RdpbSession> Function(
    Pointer<RdpbConfig>,
    Pointer<NativeFunction<RdpbEventCallback>>,
    Pointer<Void>,
  )
  create;
  final int Function(Pointer<RdpbSession>, Pointer<RdpbFrameSink>) attachSink;
  final int Function(Pointer<RdpbSession>) connect;
  final void Function(Pointer<RdpbSession>) disconnect;
  final void Function(Pointer<RdpbSession>) destroy;
  final void Function(Pointer<RdpbEvent>) eventFree;
  final void Function(Pointer<RdpbSession>, int ok, Pointer<Utf8> password)
  answerAuth;
  final void Function(Pointer<RdpbSession>, int accept, int remember)
  answerCert;
  final void Function(
    Pointer<RdpbSession>,
    int scancode,
    int extended,
    int down,
  )
  sendKey;
  final void Function(Pointer<RdpbSession>, int codeUnit, int down) sendUnicode;
  final void Function(Pointer<RdpbSession>, int flags, int x, int y) sendMouse;
  final void Function(Pointer<RdpbSession>, int delta, int horizontal)
  sendWheel;
  final void Function(Pointer<RdpbSession>, int width, int height) resize;
  final void Function(Pointer<RdpbSession>, Pointer<Utf8>) clipboardSetText;
  final void Function(Pointer<RdpbSession>) requestRedraw;
}
