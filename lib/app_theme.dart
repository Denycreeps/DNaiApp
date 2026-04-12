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

  // 액센트 (탭별 테마)
  static const Color accent = Colors.deepPurpleAccent;
  static const Color teal = Color(0xFF00BFA5); // 긍정적 프롬프트
  static const Color blue = Color(0xFF29B6F6); // 선행 프롬프트
  static const Color orange = Color(0xFFFFA000); // 후행 프롬프트
  static const Color red = Color(0xFFFF5252); // 부정적 프롬프트
  static const Color purple = Color(0xFF8B5CF6); // 캐릭터

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
