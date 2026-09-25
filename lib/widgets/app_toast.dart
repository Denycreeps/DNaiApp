// lib/widgets/app_toast.dart
//
// 화면 아래에 잠깐 뜨는 알림(SnackBar) 공통 헬퍼.
//
// 예전에는 같은 5줄짜리 코드가 64곳에 흩어져 있었고 표시 시간이 제각각이었다.
// (2400ms 48곳 / 지정 없음=4초 9곳 / 2000ms 3곳 / 5초 2곳 …)
// 같은 성격의 알림인데 화면마다 다르게 사라져서 통일했다.
import 'package:flutter/material.dart';

/// 알림이 떠 있는 시간.
///  · [short]  1초 미만. 연속으로 뜨는 가벼운 피드백(복사됨 등)
///  · [normal] 기본값. 대부분의 완료·실패 알림
///  · [long]   경로처럼 사용자가 읽어야 하는 긴 내용
enum ToastLength { short, normal, long }

const Map<ToastLength, Duration> _durations = {
  ToastLength.short: Duration(milliseconds: 900),
  ToastLength.normal: Duration(milliseconds: 2400),
  ToastLength.long: Duration(seconds: 5),
};

/// 알림을 띄운다.
///
/// [context]가 이미 화면에서 떨어졌으면 아무것도 하지 않는다.
/// (비동기 작업 뒤에 부르는 경우가 많아 매번 mounted를 검사하기 번거롭기 때문)
///
/// ```dart
/// showToast(context, "저장했어요");
/// showToast(context, "저장 위치: $path", length: ToastLength.long);
/// ```
void showToast(
  BuildContext context,
  String message, {
  ToastLength length = ToastLength.normal,

  /// 화면 아래에 띄우되 다른 UI 위에 겹쳐 보이게 한다.
  /// 갤러리처럼 화면을 꽉 채우는 곳에서 쓴다.
  bool floating = false,

  /// 글자 크기를 줄인다 (짧게 스쳐 지나가는 알림용).
  bool small = false,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: small ? const TextStyle(fontSize: 12) : null,
      ),
      duration: _durations[length]!,
      behavior: floating ? SnackBarBehavior.floating : null,
      margin: floating ? const EdgeInsets.all(8) : null,
    ),
  );
}
