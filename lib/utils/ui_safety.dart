// lib/utils/ui_safety.dart
//
// 화면을 다룰 때 반복해서 앱을 죽였던 실수들을 한곳에 묶어 둔다.
//
// 이 파일이 생긴 이유:
//  2026-09, 같은 증상(앱이 멈췄다가 강제 종료)이 다섯 번 넘게 재발했다.
//  매번 원인이 달라 보였지만 뿌리는 "위젯이 아직 살아 있는데 그게 쓰는 것을
//  먼저 치워 버린다" 하나였다. 같은 실수를 다시 하지 않도록 안전한 방법을
//  함수로 만들어 두고, 그 이유를 여기에 적어 둔다.
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
