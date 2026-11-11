import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:remote_desktop_ffi/remote_desktop_ffi.dart';
import 'package:remote_desktop_platform_interface/remote_desktop_platform_interface.dart';

import 'scancodes.dart';

/// 세션의 화면을 받을 플랫폼 텍스처를 관리합니다.
///
/// 픽셀은 Dart를 거치지 않습니다. 네이티브 bridge가 텍스처의 프레임 싱크에 직접 씁니다.
class RemoteViewController extends ChangeNotifier {
  RemoteViewController._(
    this.session,
    this._texture,
    this._width,
    this._height,
  );

  /// 텍스처를 만들고 [session]에 연결합니다. `session.connect()` 전에 부르세요.
  static Future<RemoteViewController> create(
    RemoteSession session, {
    int width = 1280,
    int height = 720,
  }) async {
    final platform = RemoteDesktopPlatform.instance;
    final texture = await platform.createTexture(width, height);
    final controller = RemoteViewController._(session, texture, width, height);
    session.attachSink(texture.sinkAddress);
    controller._eventSub = session.events.listen(controller._onEvent);
    controller._surfaceSub = platform.surfaceAvailable
        .where((id) => id == texture.textureId)
        .listen((_) => session.requestRedraw());
    return controller;
  }

  final RemoteSession session;
  final RemoteTexture _texture;
  int _width;
  int _height;
  StreamSubscription<RemoteEvent>? _eventSub;
  StreamSubscription<int>? _surfaceSub;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;

  int get textureId => _texture.textureId;

  /// 원격 화면 크기(픽셀).
  Size get desktopSize => Size(_width.toDouble(), _height.toDouble());

  void _onEvent(RemoteEvent event) {
    if (event is! RemoteDesktopSize) return;
    final width = event.width;
    final height = event.height;
    // 크기 변경은 순서대로 처리합니다.
    _pending = _pending.then((_) async {
      if (_disposed) return;
      await RemoteDesktopPlatform.instance.resizeTexture(
        textureId,
        width,
        height,
      );
      if (_disposed) return;
      _width = width;
      _height = height;
      session.requestRedraw(); // 텍스처가 새로 만들어졌으므로 전체를 다시 그림
      notifyListeners();
    });
  }

  /// 텍스처를 해제합니다. 세션은 닫지 않습니다(`session.dispose()`는 따로 부르세요).
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _eventSub?.cancel();
    _surfaceSub?.cancel();
    session.detachSink(); // 이 호출이 끝나면 네이티브가 더는 싱크를 쓰지 않음
    unawaited(RemoteDesktopPlatform.instance.disposeTexture(textureId));
    super.dispose();
  }
}

/// 원격 화면을 보여 주고 키보드·마우스·터치 입력을 세션으로 보냅니다.
///
/// 터치: 탭 = 클릭, 길게 누르기 = 우클릭, 끌기 = 왼쪽 버튼 끌기, 두 손가락 끌기 = 스크롤.
/// 소프트 키보드는 `GlobalKey<RemoteViewState>`로 [RemoteViewState.showSoftKeyboard]를 부릅니다.
class RemoteView extends StatefulWidget {
  const RemoteView({
    super.key,
    required this.controller,
    this.autofocus = true,
    this.matchViewSize = false,
    this.resolutionScale = 1.0,
  });

  final RemoteViewController controller;
  final bool autofocus;

  /// true이면 위젯 크기가 바뀔 때(화면 회전 등) 원격 해상도를 맞추도록 요청합니다.
  final bool matchViewSize;

  /// [matchViewSize]에서 논리 픽셀에 곱하는 값. 1.0이면 글자가 읽기 좋은 크기입니다.
  final double resolutionScale;

  @override
  State<RemoteView> createState() => RemoteViewState();
}

enum _TouchMode { none, pending, dragging, longPressed, scrolling }

class RemoteViewState extends State<RemoteView> {
  static const _dragSlop = 12.0; // 이보다 많이 움직이면 끌기
  static const _scrollStep = 20.0; // 휠 한 칸에 해당하는 손가락 이동(논리 픽셀)
  static const _longPressTime = Duration(milliseconds: 500);

  final _focusNode = FocusNode(debugLabel: 'RemoteView');
  late final _SoftKeyboard _keyboard = _SoftKeyboard(() => _session);

  double _scale = 1;

  // 터치
  final Map<int, Offset> _touches = {};
  _TouchMode _mode = _TouchMode.none;
  Offset _downPosition = Offset.zero;
  Timer? _longPressTimer;
  double _scrollY = 0;
  double _scrollAccumulated = 0;

  // 마우스
  int _mouseButtons = 0;

  // 해상도 맞춤
  Timer? _resizeTimer;
  int _requestedWidth = 0;
  int _requestedHeight = 0;

  RemoteSession get _session => widget.controller.session;

  void showSoftKeyboard() => _keyboard.show(View.of(context).viewId);

  void hideSoftKeyboard() => _keyboard.hide();

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _resizeTimer?.cancel();
    _keyboard.hide();
    _focusNode.dispose();
    super.dispose();
  }

  // ---- 좌표: 위젯 → 원격 화면 픽셀

  ({int x, int y}) _remote(Offset local) {
    final size = widget.controller.desktopSize;
    return (
      x: (local.dx / _scale).round().clamp(0, size.width.toInt() - 1),
      y: (local.dy / _scale).round().clamp(0, size.height.toInt() - 1),
    );
  }

  void _move(Offset local) {
    final p = _remote(local);
    _session.sendMouseMove(p.x, p.y);
  }

  void _button(RemoteMouseButton button, Offset local, {required bool down}) {
    final p = _remote(local);
    _session.sendMouseButton(button, p.x, p.y, down: down);
  }

  void _click(RemoteMouseButton button, Offset local) {
    _move(local);
    _button(button, local, down: true);
    _button(button, local, down: false);
  }

  // ---- 마우스 (하드웨어)

  static const _buttonBits = {
    kPrimaryMouseButton: RemoteMouseButton.left,
    kSecondaryMouseButton: RemoteMouseButton.right,
    kMiddleMouseButton: RemoteMouseButton.middle,
  };

  void _syncMouseButtons(int buttons, Offset local) {
    for (final entry in _buttonBits.entries) {
      final was = _mouseButtons & entry.key != 0;
      final now = buttons & entry.key != 0;
      if (was != now) _button(entry.value, local, down: now);
    }
    _mouseButtons = buttons;
  }

  // ---- 포인터 이벤트

  bool _isMouse(PointerEvent event) => event.kind == PointerDeviceKind.mouse;

  void _onPointerDown(PointerDownEvent event) {
    _focusNode.requestFocus();
    if (_isMouse(event)) {
      _move(event.localPosition);
      _syncMouseButtons(event.buttons, event.localPosition);
      return;
    }
    _touches[event.pointer] = event.localPosition;
    if (_touches.length == 1) {
      _mode = _TouchMode.pending;
      _downPosition = event.localPosition;
      _longPressTimer?.cancel();
      _longPressTimer = Timer(_longPressTime, () {
        if (_mode != _TouchMode.pending) return;
        _mode = _TouchMode.longPressed;
        HapticFeedback.selectionClick();
        _click(RemoteMouseButton.right, _downPosition);
      });
    } else if (_touches.length == 2) {
      _longPressTimer?.cancel();
      if (_mode == _TouchMode.dragging) {
        _button(RemoteMouseButton.left, _downPosition, down: false);
      }
      _mode = _TouchMode.scrolling;
      _scrollY = _averageTouchY();
      _scrollAccumulated = 0;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_isMouse(event)) {
      _move(event.localPosition);
      _syncMouseButtons(event.buttons, event.localPosition);
      return;
    }
    if (!_touches.containsKey(event.pointer)) return;
    _touches[event.pointer] = event.localPosition;

    switch (_mode) {
      case _TouchMode.pending:
        if ((event.localPosition - _downPosition).distance > _dragSlop) {
          _longPressTimer?.cancel();
          _mode = _TouchMode.dragging;
          _move(_downPosition);
          _button(RemoteMouseButton.left, _downPosition, down: true);
          _move(event.localPosition);
        }
      case _TouchMode.dragging:
        _move(event.localPosition);
      case _TouchMode.scrolling:
        if (_touches.length < 2) return;
        final y = _averageTouchY();
        _scrollAccumulated += y - _scrollY;
        _scrollY = y;
        // 손가락을 아래로 끌면 내용이 따라 내려오도록(위쪽 휠) 보냅니다.
        while (_scrollAccumulated.abs() >= _scrollStep) {
          final up = _scrollAccumulated > 0;
          _session.sendWheel(up ? 120 : -120);
          _scrollAccumulated += up ? -_scrollStep : _scrollStep;
        }
      case _TouchMode.none:
      case _TouchMode.longPressed:
        break;
    }
  }

  void _onPointerEnd(PointerEvent event, {required bool cancelled}) {
    if (_isMouse(event)) {
      _syncMouseButtons(0, event.localPosition);
      return;
    }
    if (_touches.remove(event.pointer) == null || _touches.isNotEmpty) return;

    _longPressTimer?.cancel();
    if (_mode == _TouchMode.pending && !cancelled) {
      _click(RemoteMouseButton.left, _downPosition);
    } else if (_mode == _TouchMode.dragging) {
      _button(RemoteMouseButton.left, event.localPosition, down: false);
    }
    _mode = _TouchMode.none;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta;
    if (delta.dy != 0) _session.sendWheel(delta.dy > 0 ? -120 : 120);
    if (delta.dx != 0)
      _session.sendWheel(delta.dx > 0 ? 120 : -120, horizontal: true);
  }

  double _averageTouchY() {
    var sum = 0.0;
    for (final position in _touches.values) {
      sum += position.dy;
    }
    return sum / _touches.length;
  }

  // ---- 하드웨어 키보드

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final scancode = rdpScancodeFor(event.physicalKey);
    if (scancode == null) return KeyEventResult.ignored;
    _session.sendKey(
      scancode.code,
      extended: scancode.extended,
      down: event is! KeyUpEvent,
    );
    return KeyEventResult.handled;
  }

  // ---- 해상도 맞춤

  void _scheduleResize(Size box) {
    if (!widget.matchViewSize || !box.isFinite) return;
    final width = (box.width * widget.resolutionScale).round();
    final height = (box.height * widget.resolutionScale).round();
    if (width == _requestedWidth && height == _requestedHeight) return;
    _requestedWidth = width;
    _requestedHeight = height;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 400), () {
      _session.resize(width, height);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final desktop = widget.controller.desktopSize;
          final box = constraints.biggest.isFinite
              ? constraints.biggest
              : desktop;
          _scheduleResize(box);
          _scale = math.min(
            box.width / desktop.width,
            box.height / desktop.height,
          );
          if (!_scale.isFinite || _scale <= 0) _scale = 1;

          return Center(
            child: SizedBox(
              width: desktop.width * _scale,
              height: desktop.height * _scale,
              child: Focus(
                focusNode: _focusNode,
                autofocus: widget.autofocus,
                onKeyEvent: _onKey,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: (event) =>
                      _onPointerEnd(event, cancelled: false),
                  onPointerCancel: (event) =>
                      _onPointerEnd(event, cancelled: true),
                  onPointerHover: (event) => _move(event.localPosition),
                  onPointerSignal: _onPointerSignal,
                  child: Texture(
                    textureId: widget.controller.textureId,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 소프트 키보드(Android·iOS) 입력을 세션으로 보냅니다.
///
/// 입력란에는 항상 자리 표시 글자 하나만 둡니다. 글자가 늘면 확정된 부분을 유니코드로
/// 보내고, 자리 표시 글자가 지워지면 Backspace를 보냅니다. 한글처럼 조합 중인 글자는
/// 조합이 끝났을 때 한꺼번에 보냅니다.
class _SoftKeyboard with TextInputClient {
  _SoftKeyboard(this._session);

  final RemoteSession Function() _session;

  static const _anchor = TextEditingValue(
    text: ' ',
    selection: TextSelection.collapsed(offset: 1),
  );

  TextInputConnection? _connection;
  TextEditingValue _value = _anchor;

  void show(int viewId) {
    var connection = _connection;
    if (connection == null || !connection.attached) {
      connection = TextInput.attach(
        this,
        TextInputConfiguration(
          viewId: viewId,
          inputType: TextInputType.multiline,
          inputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
        ),
      );
      _connection = connection;
      _reset();
    }
    connection.show();
  }

  void hide() {
    _connection?.close();
    _connection = null;
  }

  void _reset() {
    _value = _anchor;
    _connection?.setEditingState(_anchor);
  }

  void _sendKey(RdpScancode key) {
    _session()
      ..sendKey(key.code, extended: key.extended, down: true)
      ..sendKey(key.code, extended: key.extended, down: false);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    if (value.text.isEmpty) {
      _sendKey(RdpScancode.backspace);
      _reset();
      return;
    }
    if (value.composing.isValid && !value.composing.isCollapsed) return; // 조합 중

    final committed = value.text.startsWith(_anchor.text)
        ? value.text.substring(_anchor.text.length)
        : value.text;
    if (committed.isEmpty) return;
    for (final part in committed.split('\n').indexed) {
      if (part.$1 > 0) _sendKey(RdpScancode.enter);
      if (part.$2.isNotEmpty) _session().sendText(part.$2);
    }
    _reset();
  }

  @override
  void performAction(TextInputAction action) => _sendKey(RdpScancode.enter);

  @override
  void connectionClosed() {
    _connection = null;
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
}
