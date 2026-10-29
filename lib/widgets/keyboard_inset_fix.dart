// lib/widgets/keyboard_inset_fix.dart
//
// 다른 앱에 갔다 오면 키보드 자리가 검게 남거나, 아래쪽 화면이 내비게이션 바(홈 버튼 줄)에 묻히는 문제를 고친다
// (Flutter 엔진 버그 — 아직 고쳐지지 않았다).
//
// 무슨 일인가:
//  키보드가 떠 있을 때(또는 내려가는 중에) 다른 앱으로 가면, 안드로이드는 키보드를 치우지만 Flutter 엔진은
//  '키보드가 내려가는 애니메이션' 이 끝났다는 소식을 끝내 못 받는다. 그러면 엔진이 그 뒤로 오는 화면 여백 소식을
//  '애니메이션 중' 이라며 전부 버리고, 마지막에 알던 값을 계속 들고 있다:
//   · 키보드 높이(viewInsets.bottom)가 남는다 → Scaffold 가 그만큼 줄어 아래가 검게(배경색) 남는다
//   · 내비게이션 바 높이(viewPadding.bottom)가 틀린다(0) → 아래 버튼이 바에 묻힌다 (키보드를 올렸다 내린 뒤에도)
//  키보드 높이가 잠깐 0 이 됐다가 다시 남는 값으로 돌아오기도 해서, 돌아온 순간 한 번 보는 것으로는 놓친다.
//  → flutter/flutter#191156 (안드로이드, 3.47 에서도 재현), #189051 (iOS 의 같은 증상)
//
// 고치는 법 — 안드로이드 쪽에서 지금의 '진짜' 여백을 FlutterView 에 직접 넘긴다 (MainActivity.kt 의 reapplyInsets —
//  멈춘 엔진 리스너를 거치지 않는다. 같은 값이면 아무 일도 없다). 진짜 값은 안드로이드만 안다 — 화면 쪽에서는
//  바 높이를 알아낼 방법이 없다.
//  · 언제: 창이 다시 포커스를 받을 때 (MainActivity 가 알아서) + 여기서 키보드 · 화면이 멈춘 뒤 · 포커스가 바뀐 뒤 (0.6초 뒤 한 번)
//  · 넘긴 직후 엔진이 돌려보내는 '바뀜' 소식은 다시 넘길 이유가 아니다 (고리를 막는다)
//  · MainActivity 가 옛것이라 채널이 없으면(MissingPluginException) 화면에서 할 수 있는 만큼만:
//    입력칸에 커서가 있으면 돌아온 직후에 키보드를 다시 띄우고, 입력칸이 없는데 키보드 높이가 남았으면 그 높이를
//    0 으로 덮어쓴다 (진짜 키보드가 움직이면 그만둔다).
//  ⚠️ 덮어쓸 때 아래 padding 도 내비게이션 바 높이로 되돌린다 — 엔진은 키보드가 바를 덮는다고 보고 padding 을 0 으로 준다.
//     예전엔 키보드 높이만 0 으로 해서, 검은 자리가 사라지는 대신 화면이 바 밑으로 들어갔다.
//  ⚠️ 포커스를 옮기지 않는다 (DEVNOTES 4) — 키보드만 띄운다.
//  ⚠️ 덮어쓰지 않을 때도 MediaQuery 로 감싼다 — 감쌌다 풀었다 하면 앱 전체 화면이 새로 만들어진다.
//  쓰는 곳: main.dart 의 MaterialApp(builder:) — 다이얼로그 · 아래 창까지 다 덮이게 Navigator 바깥에 둔다.
import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart'; // SystemChannels (키보드 띄우기) · MethodChannel
import 'package:flutter/widgets.dart';

class KeyboardInsetFix extends StatefulWidget {
  final Widget child;

  const KeyboardInsetFix({super.key, required this.child});

  @override
  State<KeyboardInsetFix> createState() => _KeyboardInsetFixState();
}

class _KeyboardInsetFixState extends State<KeyboardInsetFix> with WidgetsBindingObserver {
  /// 안드로이드 쪽 보정 (MainActivity.kt)
  static const MethodChannel _native = MethodChannel('dnaiapp/insets');

  /// 키보드 · 화면이 움직임을 멈추고 이만큼 지나면 한 번 본다 (키보드 애니메이션은 0.3초 안팎)
  static const Duration _settle = Duration(milliseconds: 600);

  /// 다시 넘긴 직후 엔진이 돌려보내는 '바뀜' 소식으로 보는 시간 — 이 안의 소식으로는 다시 넘기지 않는다
  static const Duration _echo = Duration(milliseconds: 300);

  /// 남아 있는 키보드 높이 (물리 픽셀 — 화면(view)이 주는 단위). null 이면 덮어쓰지 않는다. (네이티브 보정이 없을 때만)
  double? _staleBottom;

  Timer? _check;

  /// 다음 확인이 '앱에 돌아온 뒤' 확인인지 — 입력칸이면 키보드를 다시 띄우는 건 이때만
  bool _afterResume = false;

  /// 안드로이드 쪽 보정이 없다 (MainActivity 가 옛것) — 더 부르지 않는다
  bool _nativeMissing = false;

  DateTime _lastReapply = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_schedule); // 포커스가 바뀌면 키보드가 움직인다
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_schedule);
    _check?.cancel();
    super.dispose();
  }

  /// 화면(view)이 주는 키보드 높이 (물리 픽셀) — 위젯의 MediaQuery 가 아니라 원래 값 (덮어쓴 값이 아니다)
  double _viewBottom() =>
      WidgetsBinding.instance.platformDispatcher.implicitView?.viewInsets.bottom ?? 0;

  /// 멈춘 뒤에 한 번 보기 — 다시 불리면 처음부터 다시 기다린다
  void _schedule() {
    _check?.cancel();
    _check = Timer(_settle, _runCheck);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _afterResume = true;
      _schedule();
    } else {
      _check?.cancel();
    }
  }

  @override
  void didChangeMetrics() {
    // 진짜 키보드가 움직였다(높이가 바뀌었다) — 이제 엔진 값이 맞다, 덮어쓰기를 그만둔다
    final double? stale = _staleBottom;
    if (stale != null && (_viewBottom() - stale).abs() > 0.5) {
      setState(() => _staleBottom = null);
    }
    // 키보드 · 화면이 움직였다 — 멈춘 뒤에 한 번 진짜 여백을 다시 넘긴다 (방금 넘긴 것의 메아리는 빼고)
    if (DateTime.now().difference(_lastReapply) > _echo) {
      _schedule();
    }
  }

  Future<void> _runCheck() async {
    if (!mounted || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final bool afterResume = _afterResume;
    _afterResume = false;
    if (await _reapply()) {
      return; // 엔진이 진짜 여백을 받았다 — 그래도 남은 키보드 높이는 진짜 키보드다
    }
    // ↓ 안드로이드 쪽 보정이 없을 때 — 화면에서 할 수 있는 만큼
    if (!mounted || _staleBottom != null) {
      return;
    }
    final double bottom = _viewBottom();
    if (bottom <= 0) {
      return;
    }
    // 입력칸에 커서가 있는지 — 포커스 칸이 EditableText 안이면 입력칸이다
    //  (콜백이라 MediaQuery.of 는 부르지 않는다 — 조상을 찾기만 한다)
    //  ⚠️ 이 context 는 이 State 의 것이 아니다 — 위의 mounted 로는 지켜지지 않아, 그 칸이 아직 살아 있는지(focused.mounted) 따로 본다
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    final bool typing =
        focused != null &&
        focused.mounted &&
        focused.findAncestorStateOfType<EditableTextState>() != null;
    if (typing) {
      if (afterResume) {
        // 나가기 전처럼 키보드를 다시 띄운다 — 애니메이션이 새로 돌아 엔진이 풀린다 (이미 떠 있으면 아무 일도 없다)
        SystemChannels.textInput.invokeMethod('TextInput.show');
      }
    } else {
      setState(() => _staleBottom = bottom); // 입력칸이 없는데 키보드 높이 — 남은 값이다
    }
  }

  /// 안드로이드 쪽에서 지금의 진짜 여백을 다시 넘긴다 (MainActivity.kt). 넘겼으면 true.
  Future<bool> _reapply() async {
    if (_nativeMissing) {
      return false;
    }
    try {
      _lastReapply = DateTime.now();
      return await _native.invokeMethod<bool>('reapply') ?? false;
    } on MissingPluginException {
      _nativeMissing = true; // 옛 MainActivity — 이번 실행 동안은 화면 쪽 보정만
      return false;
    } catch (_) {
      return false; // 잠깐 실패 — 다음에 키보드 · 화면이 움직이면 다시 넘긴다
    }
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    return MediaQuery(
      data: _staleBottom == null
          ? mq
          : mq.copyWith(
              viewInsets: mq.viewInsets.copyWith(bottom: 0),
              // 엔진은 키보드가 내비게이션 바를 덮는다고 보고 아래 padding 을 0 으로 준다 — 바 높이로 되돌린다
              padding: mq.padding.copyWith(bottom: max(mq.padding.bottom, mq.viewPadding.bottom)),
            ),
      child: widget.child,
    );
  }
}
