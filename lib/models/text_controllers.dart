// lib/models/text_controllers.dart
//
// 프롬프트 입력창의 구문 강조 컨트롤러 모음.
//  app_state.dart가 7500줄을 넘어 성격별로 나눴다.
//  · SyntaxHighlightController — {a|b} 같은 문법 강조
//  · WeightRulesController     — 가중치 규칙 입력창 강조
//  · WeightHighlightController — 프롬프트의 숫자:: 가중치 강조
import 'package:flutter/material.dart';

class SyntaxHighlightController extends TextEditingController {
  SyntaxHighlightController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return buildSyntaxSpan(text, style);
  }

  // 카드 본문(접힌 미리보기)에서도 동일한 음영을 쓰기 위한 static 헬퍼.
  static TextSpan buildSyntaxSpan(String text, TextStyle? style) {
    final lines = text.split('\n');
    final List<TextSpan> spans = [];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('#')) {
        // 주석: 회색
        spans.add(
          TextSpan(
            text: line,
            style: style?.copyWith(color: Colors.grey),
          ),
        );
      } else {
        // 조건부 트리거: 줄 맨 앞이 '(' 로 시작하면 조건 부분( '(' ~ 첫 ':' )에 음영
        // 예: (e|q):*skirt=*skirt → "(e|q):" 부분에 배경색
        final trimmedStart = line.trimLeft();
        final indent = line.length - trimmedStart.length;
        if (trimmedStart.startsWith('(')) {
          final colonIdx = line.indexOf(':');
          if (colonIdx != -1) {
            // 들여쓰기(공백) + 조건부( '(' ~ ':' ) + 나머지
            if (indent > 0) {
              spans.add(TextSpan(text: line.substring(0, indent), style: style));
            }
            spans.add(
              TextSpan(
                text: line.substring(indent, colonIdx + 1), // '(...):'
                style: style?.copyWith(
                  backgroundColor: const Color(
                    0xFFEC4899,
                  ).withValues(alpha: 0.30), // 조건부 섹션 색(핑크)과 통일
                  fontWeight: FontWeight.bold,
                ),
              ),
            );
            spans.add(TextSpan(text: line.substring(colonIdx + 1), style: style));
          } else {
            spans.add(TextSpan(text: line, style: style));
          }
        } else {
          spans.add(TextSpan(text: line, style: style));
        }
      }

      if (i < lines.length - 1) {
        spans.add(TextSpan(text: '\n', style: style));
      }
    }
    return TextSpan(style: style, children: spans);
  }
}

// NovelAI 가중치 문법(숫자::프롬프트 ::) 색상 하이라이트 컨트롤러
// 가중치 규칙 입력창 전용 강조
//  - 규칙이 꺼져 있으면 전체를 흐리게 (꺼진 상태가 한눈에 보이도록)
//  - '#'부터 콤마/줄바꿈 전까지는 주석이므로 회색 처리
class WeightRulesController extends TextEditingController {
  WeightRulesController({super.text});

  // AppState의 weightRulesEnabled와 동기화되는 현재 상태
  static bool rulesEnabled = false;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return buildRulesSpan(text, style, rulesEnabled);
  }

  // 카드 미리보기에서도 같은 음영을 쓰기 위한 static 헬퍼
  static TextSpan buildRulesSpan(String text, TextStyle? style, bool enabled) {
    if (!enabled) {
      // 꺼짐: 전체를 흐린 회색으로
      return TextSpan(
        text: text,
        style: style?.copyWith(color: Colors.white30),
      );
    }
    final List<TextSpan> spans = [];
    int i = 0;
    while (i < text.length) {
      final hash = text.indexOf('#', i);
      if (hash == -1) {
        spans.add(TextSpan(text: text.substring(i), style: style));
        break;
      }
      if (hash > i) {
        spans.add(TextSpan(text: text.substring(i, hash), style: style));
      }
      // '#'부터 콤마/줄바꿈 직전까지가 주석 범위
      int end = text.length;
      for (int j = hash; j < text.length; j++) {
        if (text[j] == ',' || text[j] == '\n') {
          end = j;
          break;
        }
      }
      spans.add(
        TextSpan(
          text: text.substring(hash, end),
          style: style?.copyWith(color: Colors.grey, fontStyle: FontStyle.italic),
        ),
      );
      i = end;
    }
    return TextSpan(style: style, children: spans);
  }
}

class WeightHighlightController extends TextEditingController {
  WeightHighlightController({super.text});

  // 전역 토글 (설정에서 제어)
  static bool highlightEnabled = true; // AppState.weightHighlight와 동기화 (기본 ON)

  // '::' 구분자 전용 색 (가중치/프롬프트 경계를 확실히 구분)
  // 신택스 하이라이팅 배색 (Nord/Night Owl 계열 — 채도를 낮춰 눈에 편하게)
  //  숫자는 전통적으로 파랑 계열, 구분자는 톤 다운해 덜 튀게
  static const Color _separatorColor = Color(0xFFC3A6E0); // '::' 차분한 라벤더 (구분자, 은은하게)
  static const Color _weightNumColor = Color(0xFF82AAFF); // 가중치 숫자 (Night Owl 파랑 — 표준 숫자색)

  // 가중치 → 색상 매핑
  // 1.0 = 중립(색 없음), >1.0 어두운 갈색→(10.0)완전 빨강, <1.0 파랑→검정파랑
  static Color? _weightColor(double weight) {
    if (weight == 1.0) {
      return null;
    }
    if (weight > 1.0) {
      // 1.0 어두운 갈색 → 10.0 완전 빨강
      final t = ((weight - 1.0) / 9.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF6B4423), const Color(0xFFFF0000), t);
    } else {
      // 1.0 파랑 → 0.0 이하 검정파랑
      final t = ((1.0 - weight) / 2.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF4A90D9), const Color(0xFF0A1A4A), t);
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!highlightEnabled) {
      return TextSpan(text: text, style: style);
    }
    return buildWeightSpan(text, style);
  }

  // 가중치 문법을 색상 TextSpan으로 변환 (controller + RichText 공용)
  static TextSpan buildWeightSpan(String text, TextStyle? style) {
    final List<TextSpan> spans = [];
    // 가중치 시작: 단어 경계 뒤의 (숫자):: / 종료: ::
    // 단어 경계 = 문장 시작, 또는 앞 글자가 , [ ] { } 공백 중 하나
    // (artist:7010 같은 경우 숫자 앞이 ':' 또는 글자라 가중치로 인식 안 함)
    final startRegex = RegExp(r'(?:^|(?<=[,\[\]{}\s]))(-?\d+\.?\d*)\s*::');
    final endRegex = RegExp(r'::');

    int pos = 0;
    double? currentWeight;

    while (pos < text.length) {
      if (currentWeight == null) {
        // 가중치 시작 마커 찾기
        final m = startRegex.firstMatch(text.substring(pos));
        if (m == null) {
          // 더 이상 가중치 없음 → 나머지 일반 텍스트
          spans.add(TextSpan(text: text.substring(pos), style: style));
          break;
        }
        // 마커 이전 일반 텍스트
        if (m.start > 0) {
          spans.add(TextSpan(text: text.substring(pos, pos + m.start), style: style));
        }
        currentWeight = double.tryParse(m.group(1)!);
        final markerColor = currentWeight != null ? _weightColor(currentWeight) : null;
        // 시작 마커: 숫자만 볼드, :: 는 볼드 해제. 글씨 흰색, 배경 색상 음영.
        final numStr = m.group(1)!; // 숫자 부분
        final fullMarker = m.group(0)!; // 숫자 + (공백) + ::
        final afterNum = fullMarker.substring(numStr.length); // "::" 또는 " ::"
        // 숫자 (청록 글씨 + 볼드로 프롬프트 본문과 확실히 구분)
        spans.add(
          TextSpan(
            text: numStr,
            style: style?.copyWith(
              color: _weightNumColor,
              fontWeight: FontWeight.bold,
              backgroundColor: markerColor?.withValues(alpha: 0.4),
            ),
          ),
        );
        // :: 구분자 (노란 글씨 + 볼드로 가중치와 프롬프트 사이를 뚜렷이 구분)
        spans.add(
          TextSpan(
            text: afterNum,
            style: style?.copyWith(
              color: _separatorColor,
              fontWeight: FontWeight.bold,
              backgroundColor: markerColor?.withValues(alpha: 0.4),
            ),
          ),
        );
        pos += m.end;
      } else {
        // 가중치 구간 안 → 종료 :: 찾기
        final m = endRegex.firstMatch(text.substring(pos));
        final color = _weightColor(currentWeight);
        if (m == null) {
          // 종료 없이 끝까지 → 전부 음영 (글씨 흰색, 배경만 색상)
          spans.add(
            TextSpan(
              text: text.substring(pos),
              style: style?.copyWith(
                color: Colors.white,
                backgroundColor: color?.withValues(alpha: 0.32),
              ),
            ),
          );
          break;
        }
        // 구간 내용 (글씨 흰색, 배경만 음영)
        if (m.start > 0) {
          spans.add(
            TextSpan(
              text: text.substring(pos, pos + m.start),
              style: style?.copyWith(
                color: Colors.white,
                backgroundColor: color?.withValues(alpha: 0.32),
              ),
            ),
          );
        }
        // 종료 마커 :: (노란 글씨 + 볼드, 배경 음영 유지로 구간 끝까지 연결)
        spans.add(
          TextSpan(
            text: m.group(0),
            style: style?.copyWith(
              color: _separatorColor,
              fontWeight: FontWeight.bold,
              backgroundColor: color?.withValues(alpha: 0.32),
            ),
          ),
        );
        pos += m.end;
        currentWeight = null;
      }
    }

    return TextSpan(style: style, children: spans);
  }
}
