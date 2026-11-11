import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remote_desktop/remote_desktop.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '원격 데스크톱',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const ConnectPage(),
    );
  }
}

/// 접속 정보 입력 화면.
class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '13389');
  final _user = TextEditingController();
  final _password = TextEditingController();
  var _policy = CertificatePolicy.ask;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _connect() {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    // 화면 크기(논리 픽셀)를 첫 원격 해상도로 요청합니다. 너비는 짝수여야 합니다.
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final width =
        (size.width - padding.horizontal).round().clamp(640, 4096) & ~1;
    final height = (size.height - padding.vertical - kToolbarHeight)
        .round()
        .clamp(360, 4096);

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(
          config: RdpConfig(
            host: host,
            port: int.tryParse(_port.text) ?? 3389,
            username: _user.text.trim().isEmpty ? null : _user.text.trim(),
            width: width,
            height: height,
            certificatePolicy: _policy,
          ),
          password: _password.text.isEmpty ? null : _password.text,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('원격 데스크톱 접속')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _host,
            decoration: const InputDecoration(labelText: '서버 주소'),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          TextField(
            controller: _port,
            decoration: const InputDecoration(labelText: '포트'),
            keyboardType: TextInputType.number,
          ),
          TextField(
            controller: _user,
            decoration: const InputDecoration(labelText: '사용자 이름'),
            autocorrect: false,
          ),
          TextField(
            controller: _password,
            decoration: const InputDecoration(
              labelText: '비밀번호',
              helperText: '비워 두면 접속 중에 묻습니다',
            ),
            obscureText: true,
          ),
          const SizedBox(height: 16),
          DropdownMenu<CertificatePolicy>(
            initialSelection: _policy,
            label: const Text('서버 인증서'),
            expandedInsets: EdgeInsets.zero,
            dropdownMenuEntries: const [
              DropdownMenuEntry(value: CertificatePolicy.ask, label: '매번 확인'),
              DropdownMenuEntry(
                value: CertificatePolicy.trustOnFirstUse,
                label: '처음 본 인증서는 저장',
              ),
              DropdownMenuEntry(
                value: CertificatePolicy.ignore,
                label: '확인 안 함 (SSH 터널 전용)',
              ),
            ],
            onSelected: (value) => setState(() => _policy = value ?? _policy),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _connect, child: const Text('접속')),
        ],
      ),
    );
  }
}

/// 원격 화면.
class SessionPage extends StatefulWidget {
  const SessionPage({super.key, required this.config, this.password});

  final RdpConfig config;
  final String? password;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  final _viewKey = GlobalKey<RemoteViewState>();
  late final RdpSession _session;
  StreamSubscription<RemoteEvent>? _events;
  RemoteViewController? _view;
  RemoteState _state = RemoteState.connecting;
  String? _error;
  bool _passwordUsed = false;

  @override
  void initState() {
    super.initState();
    _session = RdpSession(widget.config);
    _events = _session.events.listen(_onEvent);
    _start();
  }

  Future<void> _start() async {
    final view = await RemoteViewController.create(
      _session,
      width: widget.config.width,
      height: widget.config.height,
    );
    if (!mounted) {
      view.dispose();
      return;
    }
    setState(() => _view = view);
    _session.connect();
  }

  @override
  void dispose() {
    _events?.cancel();
    _view?.dispose(); // 텍스처를 먼저 떼고
    _session.dispose(); // 세션을 닫습니다
    super.dispose();
  }

  void _onEvent(RemoteEvent event) {
    switch (event) {
      case RemoteStateChanged():
        setState(() {
          _state = event.state;
          if (event.state == RemoteState.disconnected && event.errorCode != 0) {
            _error =
                event.errorName ?? '0x${event.errorCode.toRadixString(16)}';
          }
        });
      case RemoteAuthRequest():
        _answerAuth(event);
      case RemoteCertificateRequest():
        _answerCertificate(event);
      case RemoteClipboardText():
        Clipboard.setData(ClipboardData(text: event.text));
      case RemoteDesktopSize():
        break; // RemoteViewController가 처리
    }
  }

  Future<void> _answerAuth(RemoteAuthRequest request) async {
    // 입력해 둔 비밀번호는 한 번만 씁니다. 틀리면 다시 물을 때 직접 입력받습니다.
    if (widget.password != null && !_passwordUsed) {
      _passwordUsed = true;
      _session.answerAuth(ok: true, password: widget.password);
      return;
    }
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${request.username ?? '사용자'} 비밀번호'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    controller.dispose();
    _session.answerAuth(ok: password != null, password: password);
  }

  Future<void> _answerCertificate(RemoteCertificateRequest request) async {
    // null = 거부, false = 이번만, true = 저장
    final remember = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(request.changed ? '서버 인증서가 바뀌었습니다' : '서버 인증서 확인'),
        content: SingleChildScrollView(
          child: Text(
            [
              if (request.changed)
                '저장해 둔 인증서와 다릅니다. 서버를 다시 설치한 것이 아니라면 접속하지 마세요.\n',
              if (request.hostMismatch) '인증서의 이름이 접속 주소와 다릅니다.\n',
              '서버: ${request.host}:${request.port}',
              '이름: ${request.commonName}',
              '발급자: ${request.issuer}',
              '지문: ${request.fingerprint}',
              if (request.oldFingerprint != null)
                '이전 지문: ${request.oldFingerprint}',
            ].join('\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('거부'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('이번만 접속'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('저장하고 접속'),
          ),
        ],
      ),
    );
    _session.answerCertificate(
      accept: remember != null,
      remember: remember ?? false,
    );
  }

  Future<void> _pasteToRemote() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) _session.setClipboardText(text);
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false, // 키보드가 올라와도 화면 크기를 바꾸지 않음
      appBar: AppBar(
        title: Text(widget.config.host),
        actions: [
          IconButton(
            tooltip: '이 기기의 클립보드를 원격으로 보내기',
            icon: const Icon(Icons.content_paste_go),
            onPressed: _pasteToRemote,
          ),
          IconButton(
            tooltip: '키보드',
            icon: const Icon(Icons.keyboard),
            onPressed: () => _viewKey.currentState?.showSoftKeyboard(),
          ),
        ],
      ),
      body: switch (_state) {
        RemoteState.connected when view != null => RemoteView(
            key: _viewKey,
            controller: view,
            matchViewSize: true,
          ),
        RemoteState.disconnected => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error == null ? '연결이 끝났습니다' : '연결 실패: $_error',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('돌아가기'),
                ),
              ],
            ),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
