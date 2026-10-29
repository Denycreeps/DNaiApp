// lib/utils/ui_safety.dart
//
// 화면을 다룰 때 반복해서 앱을 죽였던 실수들을 한곳에 묶어 둔다.
//
// 이 파일이 생긴 이유:
//  2026-09, 같은 증상(앱이 멈췄다가 강제 종료)이 다섯 번 넘게 재발했다.
//  매번 원인이 달라 보였지만 뿌리는 "위젯이 아직 살아 있는데 그게 쓰는 것을
//  먼저 치워 버린다" 하나였다. 같은 실수를 다시 하지 않도록 안전한 방법을
//  함수로 만들어 두고, 그 이유를 여기에 적어 둔다.
import 'package:flutter/services.dart'; // SystemChannels (키보드 내리기)
import 'package:flutter/widgets.dart';

/// 다이얼로그가 완전히 사라진 뒤에 [cleanup] 을 실행한다.
///
/// 주로 그 다이얼로그에서 쓰던 TextEditingController 를 버릴 때 쓴다.
///
/// ## 왜 바로 버리면 안 되나
///
/// `showDialog(...)` 가 돌려주는 future 는 `Navigator.pop` 이 불린 **즉시**
/// 완료된다. 하지만 다이얼로그는 그 뒤로도 0.2초 남짓 사라지는 애니메이션을
/// 그리고, 그동안 안의 TextField 가 계속 다시 그려진다.
///
/// 그때 컨트롤러가 이미 버려져 있으면 이렇게 된다.
/// ```
/// A TextEditingController was used after being disposed.
///   → 화면 트리가 무너짐
///   → '_dependents.isEmpty': is not true
///   → 앱이 멈췄다가 강제 종료
/// ```
///
/// ## addPostFrameCallback 은 부족하다
///
/// 한 프레임만 미루는 것으로는 안 된다. 사라지는 동안 여러 프레임이 더 그려지기
/// 때문이다. 애니메이션보다 넉넉히 기다려야 한다.
///
/// ```dart
/// showDialog(...).then((_) => disposeAfterDialog(ctrl.dispose));
/// ```
void disposeAfterDialog(VoidCallback cleanup) {
  Future.delayed(_dialogSettleDelay, cleanup);
}

/// 다이얼로그가 사라지는 데 걸리는 시간 + 여유.
///  기본 다이얼로그 전환이 150~200ms 이므로 넉넉히 잡았다.
const Duration _dialogSettleDelay = Duration(milliseconds: 400);

/// [node] 의 입력칸이 키보드를 띄워 두었으면 키보드만 내린다 — 포커스는 건드리지 않는다 (DEVNOTES 4).
///
/// ## 왜 unfocus() 를 쓰지 않나
///
/// 글자를 드래그로 골라 둔 상태(선택 핸들 · 돋보기)에서 포커스를 옮기면, 프레임워크가 포커스 전환과
/// 화면 정리를 동시에 하다 멈춘다. 입력 채널에 '키보드만 내려 줘' 라고만 한다.
///
/// 이미 내려가 있으면 부르지 않는다 (안드로이드가 ALREADY_HIDDEN 로그만 쌓는다).
/// ⚠️ 탭 안의 MediaQuery 는 Scaffold 가 키보드 높이를 빼고 줘서 늘 0 이다 — 화면(view)에서 직접 본다.
void hideKeyboardIfShown(FocusNode node) {
  final double keyboard =
      WidgetsBinding.instance.platformDispatcher.implicitView?.viewInsets.bottom ?? 0;
  if (node.hasFocus && keyboard > 0) {
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }
}

/// 입력칸이 쥐고 있는 포커스를 **입력칸 자신에서** 놓는다 — 창(아래 시트 · 다이얼로그)이 뜰 때([TextFocusReleaseObserver]),
/// 빈 곳을 눌러 키보드를 내릴 때.
///  지금 포커스가 입력칸이 아니면 아무것도 안 한다.
///
/// ## 왜 필요한가 — 창이 닫히면 키보드가 저절로 뜬다
///
/// Flutter 는 창이 닫히면 아래 화면의 포커스를 '창을 띄우기 전 자리' 로 되돌린다
/// (닫힌 창 아래 화면이 다시 맨 위가 되며 그 화면의 포커스 범위가 '마지막으로 포커스를 가졌던 칸' 을 다시 부른다).
/// 그 칸이 입력칸이면 입력 연결이 새로 열리며 키보드가 올라온다 — 그 칸이 다른 탭에 숨어 있어도.
/// 이 앱은 탭을 넘길 때 키보드만 내리고 포커스는 그대로 둔다(규칙 4) — 그래서 프롬프트탭에서 글을 쓰다 i2i 로 와서
/// 확장의 '상세' 창을 열었다 닫으면, 안 보이는 프롬프트 칸 때문에 키보드가 뜨고 화면이 그만큼 눌렸다.
///
/// ## 왜 `FocusScope.of(context).unfocus()` 로는 안 되나
///
/// 범위(FocusScope)에 unfocus 를 부르면 '그 위' 범위의 기억만 지우고 포커스를 그 위로 옮긴다.
/// 입력칸이 든 범위는 그 입력칸을 여전히 기억해서, 창이 닫힐 때 그리로 돌아간다.
/// 입력칸 자신에게 unfocus 를 불러야 그 칸이 든 범위의 기억까지 지워진다.
///
/// ## 규칙 4(포커스를 옮기지 않는다)의 예외
///
/// 창을 띄우면 어차피 포커스가 창으로 옮겨 가고, 빈 곳을 누를 때도 예전부터 포커스를 옮겨 왔다 —
/// 옮기는 자리만 바로잡을 뿐 새로 옮기는 게 아니다. 탭 넘기기 · 입력 중에는 쓰지 않는다.
///
/// [pageOnly] — 입력칸이 화면(페이지)에 있을 때만 놓는다. 창 안의 입력칸은 그대로 둔다 ([TextFocusReleaseObserver]).
void releaseTextFocus({bool pageOnly = false}) {
  final FocusNode? node = FocusManager.instance.primaryFocus;
  final BuildContext? ctx = node?.context;
  if (node == null || ctx == null || !ctx.mounted) {
    return;
  }
  // 포커스 칸이 EditableText 안이면 입력칸이다 (KeyboardInsetFix 와 같은 판별)
  if (ctx.findAncestorStateOfType<EditableTextState>() == null) {
    return;
  }
  // 다이얼로그 · 아래 시트는 모두 PopupRoute 다 — 그 안의 입력칸이면 놔둔다
  if (pageOnly && ModalRoute.of(ctx) is PopupRoute) {
    return;
  }
  node.unfocus();
}

/// 창(다이얼로그 · 아래 시트 · 메뉴 · 새 화면)이 뜰 때마다 [releaseTextFocus] 를 불러 주는 관찰자.
///  MaterialApp.navigatorObservers 에 단다 (main.dart).
///
/// ## 왜 창을 띄우는 곳마다 부르지 않고 여기서 하나
///
/// 창은 앱 곳곳(수십 곳)에서 띄운다. 띄우는 곳마다 부르면 한 곳만 빠져도 같은 버그가 난다 —
/// 실제로 i2i '상세' 창만 고쳤더니, 프롬프트탭 검색칸(찾을 태그 · 제외할 태그)을 한 번 누른 뒤
/// 긍정 · 선행 같은 확대 입력창을 열었다 닫으면 똑같이 검색칸에 키보드가 떴다 (2026-10).
///
/// ## 언제 불리나 — 창 띄우기 직전에 부르는 것과 같다
///
/// Navigator 는 새 창을 쌓는 그 자리에서(같은 흐름 안에서) 관찰자를 부른다. 새 창은 처음 그려질 때 포커스를
/// 가져가므로(_ModalScopeState) 이 순간엔 포커스가 아직 입력칸에 있다 → 입력칸 자신에서 놓을 수 있다.
/// (창이 '닫힐 때' 하면 늦다 — 그땐 이미 입력칸이 포커스를 되찾기로 정해져 키보드가 한 번 올라온다)
///
/// ## 창 안의 입력칸은 놔둔다 (pageOnly)
///
/// 확대 입력창에서 쓰다가 '사전' · '되돌리기' 같은 작은 창을 열었다 닫으면, 이어서 쓰도록 키보드가 돌아오는 게 맞다.
class TextFocusReleaseObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    releaseTextFocus(pageOnly: true);
  }
}
