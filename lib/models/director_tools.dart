// lib/models/director_tools.dart
//
// NovelAI Director Tools.
//  이미지 한 장을 받아 다른 형태로 바꿔 주는 도구 모음이다.
//  프롬프트·시드·모델과 무관하게 '이미지 + 크기'만으로 동작한다.
//
// 모든 도구가 같은 엔드포인트(/ai/augment-image)를 쓰고 req_type 만 다르다.
// 그래서 새 도구가 나오면 아래 목록에 한 줄만 추가하면 된다.
//
// 공식 문서: https://docs.novelai.net/en/image/directortools/
import 'package:flutter/material.dart';

class DirectorTool {
  /// API 로 보내는 req_type 값
  final String reqType;

  /// 화면에 보이는 이름
  final String label;

  final IconData icon;

  /// 이 도구가 결과를 여러 장 돌려주는가.
  ///  배경 제거는 Masked / Generated / Blend 3장을 준다.
  final bool multiResult;

  /// 결과 릴 배지에 쓸 짧은 이름
  final String badge;

  /// 사용자에게 보여 줄 한 줄 설명
  final String description;

  const DirectorTool({
    required this.reqType,
    required this.label,
    required this.icon,
    required this.badge,
    required this.description,
    this.multiResult = false,
  });
}

/// 앱이 지원하는 도구 목록.
///
/// ⚠️ 프롬프트나 강도가 필요한 도구(Colorize, Emotion)는 아직 넣지 않았다.
///    입력 UI가 따로 필요해서 지금 구조로는 담기지 않는다.
const List<DirectorTool> kDirectorTools = [
  DirectorTool(
    reqType: 'bg-removal',
    label: '배경 제거',
    icon: Icons.layers_clear,
    badge: 'BG',
    description: '배경을 지우고 인물만 남깁니다. 결과가 3장 나옵니다.',
    multiResult: true,
  ),
  DirectorTool(
    reqType: 'lineart',
    label: '라인아트',
    icon: Icons.gesture,
    badge: 'LINE',
    description: '깔끔한 선화로 바꿉니다.',
  ),
  DirectorTool(
    reqType: 'sketch',
    label: '스케치',
    icon: Icons.draw,
    badge: 'SKET',
    description: '연필 스케치풍으로 바꿉니다.',
  ),
  DirectorTool(
    reqType: 'declutter',
    label: '디클러터',
    icon: Icons.cleaning_services,
    badge: 'DECL',
    description: '말풍선·효과음 같은 군더더기를 지웁니다.',
  ),
];

/// Director Tool 실행에 드는 Anlas 를 계산한다.
///
/// NovelAI 웹이 버튼에 표시하는 값과 같은 식이다.
/// (832x1216 기준: 배경 제거 65 / 나머지는 Opus 라면 0)
///
/// ⚠️ 배경 제거만 규칙이 다르다.
///    · 결과가 3장이라 기본 비용의 3배에 고정 5가 더 붙는다
///    · Opus 무료 한 장 감면을 받지 못한다 (tier 1 로 계산된다)
///
/// [tier] 는 구독 등급(Opus = 3). [steps] 는 28 고정이다.
int directorToolCost({
  required String reqType,
  required int width,
  required int height,
  required int tier,
}) {
  const int steps = 28;
  const int basePixels = 1048576; // 1024 x 1024
  final bool isBgRemoval = reqType == 'bg-removal';

  // 면적 기반 기본 비용 (V4 계열과 같은 식)
  final int pixels = width * height;
  final double raw = 2951823174884865e-21 * pixels + 5.753298233447344e-7 * pixels * steps;
  int cost = raw.ceil();
  if (cost < 2) {
    cost = 2;
  }
  if (cost > 140) {
    return -1; // 상한 초과 — 공식도 계산을 포기한다
  }

  // Opus 는 28스텝 이하·1MP 이하 이미지 한 장을 무료로 만들어 준다.
  //  배경 제거는 이 감면 대상이 아니다.
  int samples = 1;
  final int effectiveTier = isBgRemoval ? 1 : tier;
  if (steps <= 28 && pixels.clamp(65536, 1 << 30) <= basePixels && effectiveTier >= 3) {
    samples -= 1;
  }

  final int total = cost * samples;
  return isBgRemoval ? total * 3 + 5 : total;
}

/// reqType 으로 도구를 찾는다. 없으면 첫 번째(배경 제거).
DirectorTool directorToolFor(String reqType) {
  for (final t in kDirectorTools) {
    if (t.reqType == reqType) {
      return t;
    }
  }
  return kDirectorTools.first;
}

/// 배경 제거가 돌려주는 3장의 이름. zip 안에 들어 있는 순서와 같다.
///  · Masked    — 원본을 마스크로 오려낸 것 (전경 요소가 남을 수 있음)
///  · Generated — AI 가 새로 그린 것 (가려졌던 부분을 채워 줌)
///  · Blend     — 둘을 섞은 것
const List<String> kBgRemovalVariants = ['Masked', 'Generated', 'Blend'];
