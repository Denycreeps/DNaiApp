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

  /// 설정에 동그라미로 늘어놓는 액센트 후보 (그 뒤 무지개 칸에서 직접 고를 수도 있다 —
  ///  widgets/accent_color_sheet.dart).
  ///  ⚠️ 아래 teal/blue/orange/red/purple 등은 "긍정/선행/후행/부정/캐릭터"처럼 의미가 고정된 색이라,
  ///     액센트가 그 색과 아주 비슷하면 화면에서 둘이 헷갈릴 수 있다. 예전엔 그래서 자유 선택을 막았는데,
  ///     후보 중에도 비슷한 색(기본 보라≈캐릭터 보라, 호박≈즐겨찾기 호박)이 이미 있어 막는 의미가 적었다.
  ///     지금은 직접 고르기를 열어 두고, 그 창에서 '읽기 어려운 색(너무 어둡거나 밝음)'만 알려 준다.
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
  // 조건부 규칙 (프롬프트탭의 조건부 섹션, 설정 탭의 섹션 칩).
  //  예전엔 이 값이 두 파일에 숫자로 15번 적혀 있었다.
  static const Color pink = Color(0xFFEC4899);
  // 호박색 — 즐겨찾기(★)·갤러리/폴더·히스토리 '세팅' 정보·경고·작업 중 표시.
  //  예전엔 같은 색을 Color(0xFFFFC107) 와 Colors.amber 두 가지로 섞어 적었다 (값은 같다).
  static const Color amber = Color(0xFFFFC107);

  /// 캐릭터 번호별 기본 색 — 캐릭터탭 칩·캔버스 마커·프롬프트탭 서랍이 같은 색을 쓴다.
  ///  (예전엔 캐릭터탭 안에 이 목록이 두 벌 있었고, 서랍은 색을 쓰지 않았다)
  static const List<Color> characterPalette = [
    purple,
    teal,
    Color(0xFFFF7043),
    Color(0xFF42A5F5),
    Color(0xFFEC407A),
    Color(0xFF9CCC65),
    Color(0xFFFFCA28),
    Color(0xFF26C6DA),
  ];

  /// 색 고르기 창에서 기본 색 뒤에 더 보여 주는 후보
  static const List<Color> characterExtraSwatches = [
    Color(0xFFEF5350),
    Color(0xFFAB47BC),
    Color(0xFF5C6BC0),
    Color(0xFF66BB6A),
    Color(0xFFFFA726),
    Color(0xFF78909C),
    Color(0xFFD4E157),
    Color(0xFFFFFFFF),
  ];

  /// 캐릭터 색 — 사용자가 정한 색([argb])이 있으면 그 색, 없으면 [index] 번째 기본 색.
  static Color characterColor(int? argb, int index) =>
      argb != null ? Color(argb) : characterPalette[index % characterPalette.length];

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
