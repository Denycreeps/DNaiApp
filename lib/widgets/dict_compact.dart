// lib/widgets/dict_compact.dart
//
// 프롬프트 사전 '간단히 보기' — 사전이 길어졌을 때 한 줄에 '이름 - 분류' 만 보이게 한다.
//  라이브러리 탭의 사전 목록과 확대 입력창의 📖 선택 창이 같은 줄 · 같은 전환 버튼을 쓴다.
//  켜고 끄기도 함께 간다 (AppState.promptDictCompact — 한쪽에서 바꾸면 다른 쪽도 간단히 보인다).
//
//  썸네일 · 프롬프트 미리보기를 빼고 줄 높이를 반 아래로 줄였다. '추가' · '복사' 는 작은 아이콘으로 남긴다 —
//  빼면 간단히 보기에서는 사전을 쓸 수가 없다 (선택 창은 고르려고 여는 곳이다).
import 'package:flutter/material.dart';

import '../app_theme.dart';

/// 간단히 보기 켜기/끄기 버튼 (작은 아이콘). 켜져 있으면 강조색으로 보인다.
class DictCompactToggle extends StatelessWidget {
  const DictCompactToggle({super.key, required this.compact, required this.onPressed, this.color});

  final bool compact;
  final VoidCallback onPressed;

  /// 켜졌을 때의 색 (없으면 강조색)
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: compact ? "간단히 보기 끄기" : "간단히 보기 (이름 - 분류)",
      onPressed: onPressed,
      icon: const Icon(Icons.view_headline, size: 20),
      color: compact ? (color ?? AppColors.accent) : Colors.white54,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    );
  }
}

/// 간단히 보기의 한 줄 — '이름 - 분류' + 작은 추가 · 복사 버튼.
///  줄을 누르면 [onTap] (사전 탭: 편집 · 선택 창: 내용 펼치기). [below] 는 줄 아래에 붙일 것 (펼친 내용).
class DictCompactRow extends StatelessWidget {
  const DictCompactRow({
    super.key,
    required this.title,
    required this.category,
    required this.onTap,
    required this.onAdd,
    required this.onCopy,
    this.onAddLongPress,
    this.background,
    this.borderColor,
    this.below,
  });

  final String title;

  /// 분류 이름 (분류가 없으면 '미분류')
  final String category;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final VoidCallback onCopy;

  /// '추가' 꾹 누르기 (선택 창: 맨 끝에 추가)
  final VoidCallback? onAddLongPress;

  /// 줄 바탕색 (없으면 AppColors.surface)
  final Color? background;

  /// 테두리 색 (없으면 옅은 흰색 — 펼쳤을 때 강조용)
  final Color? borderColor;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? AppColors.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor ?? Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // 이름이 길면 이름을 줄인다 — 분류는 늘 보이게 (분류는 짧으니 폭을 조금만 준다)
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 120),
                          child: Text(
                            "  -  $category",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  _miniButton(Icons.playlist_add, AppColors.teal, onAdd, onLongPress: onAddLongPress),
                  const SizedBox(width: 4),
                  _miniButton(Icons.copy, AppColors.blue, onCopy),
                ],
              ),
              ?below,
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniButton(IconData icon, Color c, VoidCallback onTap, {VoidCallback? onLongPress}) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 34,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withValues(alpha: 0.5)),
        ),
        child: Icon(icon, size: 15, color: c),
      ),
    );
  }
}
