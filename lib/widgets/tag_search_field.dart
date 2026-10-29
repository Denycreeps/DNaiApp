// lib/widgets/tag_search_field.dart
//
// 태그 검색칸 — 히스토리 검색 · 갤러리 검색이 같이 쓴다 (찾는 규칙은 models/history_search.dart).
//  ⚠️ 모양만 갖고 있다. 검색어 · 키보드 · 포커스는 부르는 쪽이 다룬다 (DEVNOTES 4 — 포커스를 빼지 않는다).
import 'package:flutter/material.dart';

import '../app_theme.dart';

class TagSearchField extends StatelessWidget {
  const TagSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    required this.onSearchKey,
    this.active = false,
    this.hintText = "태그로 찾기 — maid, smile, -glasses",
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  /// 지우기(✕) — 글이 있을 때만 보인다. 글을 비우는 건 부르는 쪽이 한다.
  final VoidCallback onClear;

  /// 키보드의 검색 키 — 보통 키보드만 내린다 (기본 동작은 포커스를 빼서 DEVNOTES 4 에 걸린다)
  final VoidCallback onSearchKey;

  /// 검색 중이면 돋보기 · 테두리를 강조색으로
  final bool active;

  final String hintText;

  @override
  Widget build(BuildContext context) {
    final Color accent = AppColors.accent;
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: BorderSide(color: c),
    );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      onEditingComplete: onSearchKey,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: hintText,
        hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
        prefixIcon: Icon(Icons.search, color: active ? accent : Colors.white38, size: 20),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                tooltip: "검색 지우기",
                onPressed: onClear,
              ),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: border(Colors.white24),
        enabledBorder: border(active ? accent.withValues(alpha: 0.6) : Colors.white24),
        focusedBorder: border(accent),
      ),
    );
  }
}
