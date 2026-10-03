// lib/widgets/prompt_preview_card.dart
//
// 프롬프트 미리보기 카드 — 누르면 확대 입력창이 열리는 칸.
//  캐릭터탭(긍정·부정), 프롬프트탭 캐릭터 서랍(긍정·임시), 라이브러리 사전 편집이 같이 쓴다.
//  (예전엔 세 곳이 각자 비슷한 카드를 따로 갖고 있었다 — 합쳐서 약 230줄)
//
//  [ 아이콘 제목              (스위치) ✎ ]   ← 모드 색 띠
//  [ 프롬프트 미리보기 …                  ]
import 'package:flutter/material.dart';

import '../app_theme.dart';

class PromptPreviewCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback onTap;

  /// 비었을 때 보여 줄 문구
  final String hint;

  /// 미리보기 줄 수 (넘치면 … 으로 줄인다. 전문은 눌러서 확대 입력창에서)
  final int maxLines;

  /// 본문 높이를 고정할지 (null = 내용만큼).
  ///  캐릭터탭처럼 아래 위치 패널이 밀리면 안 되는 곳에서 쓴다. 비었으면 문구를 가운데에.
  final double? bodyHeight;

  /// 촘촘하게 (세로 공간이 빠듯한 캐릭터탭용 — 머리줄·모서리가 조금 작다)
  final bool dense;

  /// 카드 바탕색 (다이얼로그 안처럼 바탕이 surface 인 곳에서는 더 어두운 색으로)
  final Color? background;

  /// 주면 머리줄 오른쪽에 ON/OFF 스위치가 붙는다 (서랍의 임시 프롬프트).
  ///  꺼져 있으면 본문을 흐리게 — 내용은 남아 있지만 쓰이지 않는다는 표시.
  final bool? enabled;
  final ValueChanged<bool>? onEnabledChanged;

  const PromptPreviewCard({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.text,
    required this.onTap,
    this.hint = "눌러서 입력…",
    this.maxLines = 3,
    this.bodyHeight,
    this.dense = false,
    this.background,
    this.enabled,
    this.onEnabledChanged,
  });

  @override
  Widget build(BuildContext context) {
    final bool empty = text.isEmpty;
    final bool dimmed = enabled == false;
    // 촘촘한 모양과 보통 모양 (예전 캐릭터탭 카드와 서랍 카드의 크기를 그대로 옮겼다)
    final double radius = dense ? 12 : 10;
    final double iconSize = dense ? 14 : 16;
    final double titleSize = dense ? 12 : 13;
    final double headerPadV = dense ? 5 : 8;
    final double bodySize = dense ? 13 : 12;

    final bodyText = Text(
      empty ? hint : text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: (empty && bodyHeight != null) ? TextAlign.center : TextAlign.start,
      style: TextStyle(
        color: empty ? Colors.white30 : (dimmed ? Colors.white38 : Colors.white),
        fontSize: bodySize,
        height: 1.4,
      ),
    );

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: background ?? AppColors.surface,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: color.withValues(alpha: dense ? 0.3 : 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 머리줄 — 색 띠
            Container(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: headerPadV),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.vertical(top: Radius.circular(radius - 1)),
              ),
              child: Row(
                children: [
                  Icon(icon, color: color, size: iconSize),
                  SizedBox(width: dense ? 5 : 6),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: titleSize,
                      ),
                    ),
                  ),
                  if (enabled != null && onEnabledChanged != null) ...[
                    SizedBox(
                      height: 22,
                      child: FittedBox(
                        fit: BoxFit.fitHeight,
                        child: Switch(
                          value: enabled!,
                          activeThumbColor: color,
                          onChanged: onEnabledChanged,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(Icons.edit, color: color, size: iconSize - 1),
                ],
              ),
            ),
            // 본문
            if (bodyHeight != null)
              SizedBox(
                height: bodyHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Align(
                    alignment: empty ? Alignment.center : Alignment.topLeft,
                    child: bodyText,
                  ),
                ),
              )
            else
              Padding(padding: const EdgeInsets.all(10), child: bodyText),
          ],
        ),
      ),
    );
  }
}
