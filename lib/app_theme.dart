// lib/app_theme.dart
// 앱 전체에서 반복 사용되는 색상, 스타일 상수 모음
// 점진적으로 하드코딩된 값들을 이 파일의 상수로 교체 가능
import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // 배경색
  static const Color background = Color(0xFF121212);
  static const Color surface = Color(0xFF1E1E1E); // 카드, 다이얼로그 배경
  static const Color surfaceAlt = Color(0xFF2A2A2D); // 대체 표면색
  static const Color surfaceButton = Color(0xFF2A2A35); // 버튼 배경

  // 액센트 — 런타임에 사용자가 바꿀 수 있어 non-const.
  //  ⚠️ 값이 실행 중에 바뀌므로 const 문맥(const Icon(...) 등)에서는 쓸 수 없다.
  //     이 색을 쓰는 위젯은 const를 떼야 한다.
  //  대입 지점: AppState.setThemeAccent() / loadInitialData() / importSettings()
  static Color accent = defaultAccent;

  /// 기본 액센트 (deepPurpleAccent와 동일한 값을 const로 고정)
  static const Color defaultAccent = Color(0xFF7C4DFF);

  /// 사용자가 고를 수 있는 액센트 후보.
  ///  ⚠️ 자유 컬러 피커를 쓰지 않는 이유:
  ///     아래 teal/blue/orange/red/purple은 "긍정/선행/후행/부정/캐릭터"라는
  ///     의미가 이미 고정된 색이다. 액센트가 그 색과 겹치면 UI에서 둘을
  ///     구분할 수 없게 되므로, 의미색과 충분히 떨어진 값만 후보로 둔다.
  static const List<({String name, Color color})> accentPalette = [
    (name: '기본 보라', color: defaultAccent),
    (name: '인디고', color: Color(0xFF5C6BC0)),
    (name: '자홍', color: Color(0xFFD81B60)),
    (name: '청록', color: Color(0xFF00ACC1)),
    (name: '라임', color: Color(0xFF9CCC65)),
    (name: '호박', color: Color(0xFFFFB300)),
    (name: '장미', color: Color(0xFFFF7043)),
    (name: '회백', color: Color(0xFF90A4AE)),
  ];
  static const Color teal = Color(0xFF00BFA5); // 긍정적 프롬프트
  static const Color blue = Color(0xFF29B6F6); // 선행 프롬프트
  static const Color orange = Color(0xFFFFA000); // 후행 프롬프트
  static const Color red = Color(0xFFFF5252); // 부정적 프롬프트
  // 캐릭터 마커가 대표 용도지만, 프롬프트탭의 보조 강조(섹션 헤더·배치 버튼 등)에도
  // 같은 색을 쓴다. 액센트와 달리 사용자가 바꿀 수 없는 고정색이다.
  static const Color purple = Color(0xFF8B5CF6); // 캐릭터 · 보조 강조

  // 텍스트
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Colors.white70;
  static const Color textHint = Colors.white30;
  static const Color textMuted = Colors.white54;
}

class AppTextStyles {
  AppTextStyles._();

  static const TextStyle title = TextStyle(
    color: Colors.white,
    fontSize: 18,
    fontWeight: FontWeight.bold,
  );

  static const TextStyle label = TextStyle(color: Colors.white, fontWeight: FontWeight.bold);

  static const TextStyle body = TextStyle(color: Colors.white, fontSize: 14);

  static const TextStyle caption = TextStyle(color: Colors.white54, fontSize: 12);

  static const TextStyle chipBold = TextStyle(
    color: Colors.white,
    fontWeight: FontWeight.bold,
    fontSize: 13,
  );

  static const TextStyle chipMuted = TextStyle(
    color: Colors.white54,
    fontWeight: FontWeight.normal,
    fontSize: 13,
  );
}
