import 'dart:async';
import 'dart:math';
import '../utils/prompt_utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

// ============================================================================
// 🚀 좁은 공간(검색창) 전용 세로형 자동완성 텍스트 필드 위젯
// ============================================================================
class _InlineAutocompleteTextField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final AppState state;

  const _InlineAutocompleteTextField({
    required this.controller,
    required this.hintText,
    required this.state,
  });

  @override
  State<_InlineAutocompleteTextField> createState() => _InlineAutocompleteTextFieldState();
}

class _InlineAutocompleteTextFieldState extends State<_InlineAutocompleteTextField> {
  List<String> suggestions = [];
  late FocusNode focusNode;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    focusNode = FocusNode();
    focusNode.addListener(() {
      if (!focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted) {
            setState(() {
              suggestions.clear();
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    focusNode.dispose();
    super.dispose();
  }

  void onTextChanged() {
    String text = widget.controller.text;
    int cursor = widget.controller.selection.baseOffset;
    if (cursor < 0) {
      cursor = text.length;
    }

    String beforeCursor = text.substring(0, cursor);

    int lastComma = beforeCursor.lastIndexOf(',');
    int lastColon = beforeCursor.lastIndexOf(':');
    int lastNewline = beforeCursor.lastIndexOf('\n');
    int lastParen = beforeCursor.lastIndexOf(')');
    int lastDelimiter = max(lastComma, max(lastColon, max(lastNewline, lastParen)));

    String currentWord = lastDelimiter == -1
        ? beforeCursor
        : beforeCursor.substring(lastDelimiter + 1);
    currentWord = currentWord.trimLeft();

    if (currentWord.isEmpty) {
      setState(() {
        suggestions = [];
      });
      return;
    }

    if (currentWord.startsWith('__')) {
      String searchWord = currentWord.replaceAll('__', '').toLowerCase();
      List<String> matches = widget.state.wildcards
          .where((w) => w.name.toLowerCase().startsWith(searchWord))
          .map((w) => "__${w.name}__")
          .take(15)
          .toList();

      setState(() {
        suggestions = matches;
      });
      return;
    }

    List<String> matches = smartMatchTags(widget.state.danbooruTags, currentWord);

    setState(() {
      suggestions = matches;
    });
  }

  void insertTag(String tag) {
    String text = widget.controller.text;
    int cursor = widget.controller.selection.baseOffset;
    if (cursor < 0) cursor = text.length;

    String beforeCursor = text.substring(0, cursor);
    String afterCursor = text.substring(cursor);
    String newBefore = PromptUtils.buildCompletedText(beforeCursor, tag);

    widget.controller.value = TextEditingValue(
      text: newBefore + afterCursor,
      selection: TextSelection.collapsed(offset: newBefore.length),
    );

    setState(() {
      suggestions.clear();
    });
    widget.state.saveAllSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 44,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.deepPurpleAccent),
            borderRadius: BorderRadius.circular(4),
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: focusNode,
            onChanged: (_) {
              onTextChanged();
              _saveDebounce?.cancel();
              _saveDebounce = Timer(const Duration(milliseconds: 500), () {
                widget.state.saveAllSettings();
              });
            },
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              hintText: widget.hintText,
              hintStyle: const TextStyle(color: Colors.white30),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: suggestions.isNotEmpty
              ? Container(
                  margin: const EdgeInsets.only(top: 4),
                  constraints: const BoxConstraints(maxHeight: 150),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.5)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: suggestions.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, color: Colors.white12),
                      itemBuilder: (context, index) {
                        return InkWell(
                          onTap: () => insertTag(suggestions[index]),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            child: Text(
                              suggestions[index],
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class PromptTab extends StatefulWidget {
  final VoidCallback? onScrollToHistoryEnd;
  const PromptTab({super.key, this.onScrollToHistoryEnd});

  @override
  State<PromptTab> createState() => _PromptTabState();
}

class _PromptTabState extends State<PromptTab> {
  void _showPresetBottomSheet(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) {
        return Container(
          height: MediaQuery.of(modalContext).size.height * 0.7,
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(modalContext).viewInsets.bottom,
            top: 16,
            left: 16,
            right: 16,
          ),
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Row(
                children: [
                  Icon(Icons.bookmarks, color: Colors.deepPurpleAccent, size: 24),
                  SizedBox(width: 8),
                  Text(
                    "프롬프트 프리셋 관리",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              ElevatedButton.icon(
                onPressed: () {
                  TextEditingController nameCtrl = TextEditingController();
                  showDialog(
                    context: modalContext,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF1E1E1E),
                      title: const Text("프리셋 저장", style: TextStyle(color: Colors.white)),
                      content: TextField(
                        controller: nameCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: "프리셋 이름을 입력하세요",
                          hintStyle: TextStyle(color: Colors.white30),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text("취소", style: TextStyle(color: Colors.grey)),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            if (nameCtrl.text.trim().isNotEmpty) {
                              state.presets.add(
                                NaiPreset(
                                  name: nameCtrl.text.trim(),
                                  positive: state.positiveController.text,
                                  negative: state.negativeController.text,
                                  prefix: state.prefixController.text,
                                  suffix: state.suffixController.text,
                                ),
                              );
                              state.saveAllSettings();
                              state.refreshUI();
                              Navigator.pop(ctx);
                            }
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
                          child: const Text("저장", style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.add, color: Colors.white),
                label: const Text(
                  "현재 프롬프트 묶음을 새 프리셋으로 저장",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),

              Expanded(
                child: Consumer<AppState>(
                  builder: (context, consumerState, child) {
                    if (consumerState.presets.isEmpty) {
                      return const Center(
                        child: Text("저장된 프리셋이 없습니다.", style: TextStyle(color: Colors.white30)),
                      );
                    }
                    return ListView.separated(
                      itemCount: consumerState.presets.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, color: Colors.white12),
                      itemBuilder: (context, index) {
                        final preset = consumerState.presets[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          title: Text(
                            preset.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            "긍정: ${preset.positive.isEmpty ? '없음' : preset.positive}",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                          onTap: () {
                            showDialog(
                              context: modalContext,
                              builder: (ctx) {
                                Widget buildSection(String label, String text, Color color) {
                                  if (text.trim().isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          label,
                                          style: TextStyle(
                                            color: color,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: Colors.black26,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: color.withValues(alpha: 0.3)),
                                          ),
                                          child: Text(
                                            text,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }

                                return AlertDialog(
                                  backgroundColor: const Color(0xFF1E1E1E),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  title: Row(
                                    children: [
                                      const Icon(
                                        Icons.info_outline,
                                        color: Colors.deepPurpleAccent,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          preset.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        buildSection(
                                          "선행 프롬프트",
                                          preset.prefix,
                                          const Color(0xFF29B6F6),
                                        ),
                                        buildSection(
                                          "긍정적 프롬프트",
                                          preset.positive,
                                          const Color(0xFF00BFA5),
                                        ),
                                        buildSection(
                                          "후행 프롬프트",
                                          preset.suffix,
                                          const Color(0xFFFFA000),
                                        ),
                                        buildSection(
                                          "부정적 프롬프트",
                                          preset.negative,
                                          const Color(0xFFFF5252),
                                        ),
                                        if (preset.prefix.isEmpty &&
                                            preset.positive.isEmpty &&
                                            preset.suffix.isEmpty &&
                                            preset.negative.isEmpty)
                                          const Text(
                                            "저장된 내용이 없습니다.",
                                            style: TextStyle(color: Colors.white54),
                                          ),
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.deepPurpleAccent,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                      ),
                                      child: const Text(
                                        "닫기",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OutlinedButton(
                                onPressed: () {
                                  consumerState.positiveController.text = preset.positive;
                                  consumerState.negativeController.text = preset.negative;
                                  consumerState.prefixController.text = preset.prefix;
                                  consumerState.suffixController.text = preset.suffix;
                                  consumerState.saveAllSettings();
                                  consumerState.refreshUI();
                                  Navigator.pop(modalContext);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      duration: const Duration(milliseconds: 2400),
                                      content: Text("'${preset.name}' 프리셋을 불러왔습니다."),
                                    ),
                                  );
                                },
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.deepPurpleAccent),
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                ),
                                child: const Text(
                                  "적용",
                                  style: TextStyle(
                                    color: Colors.deepPurpleAccent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.redAccent),
                                onPressed: () {
                                  consumerState.presets.removeAt(index);
                                  consumerState.saveAllSettings();
                                  consumerState.refreshUI();
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPromptEditDialog(
    BuildContext context,
    AppState state,
    String title,
    IconData icon,
    Color color,
    TextEditingController controller,
  ) {
    FocusNode focusNode = FocusNode();
    final String initialText = controller.text;

    showDialog(
      context: context,
      builder: (ctx) {
        List<String> suggestions = [];

        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            focusNode.addListener(() {
              if (!focusNode.hasFocus) {
                Future.delayed(const Duration(milliseconds: 150), () {
                  if (ctx.mounted) {
                    setModalState(() {
                      suggestions.clear();
                    });
                  }
                });
              }
            });

            void onTextChanged() {
              String text = controller.text;
              int cursor = controller.selection.baseOffset;
              if (cursor < 0) {
                cursor = text.length;
              }

              String beforeCursor = text.substring(0, cursor);

              int lastComma = beforeCursor.lastIndexOf(',');
              int lastColon = beforeCursor.lastIndexOf(':');
              int lastNewline = beforeCursor.lastIndexOf('\n');
              int lastParen = beforeCursor.lastIndexOf(')');
              int lastDelimiter = max(lastComma, max(lastColon, max(lastNewline, lastParen)));

              String currentWord = lastDelimiter == -1
                  ? beforeCursor
                  : beforeCursor.substring(lastDelimiter + 1);

              currentWord = currentWord.trimLeft();

              if (currentWord.isEmpty) {
                setModalState(() {
                  suggestions = [];
                });
                return;
              }

              if (currentWord.startsWith('__')) {
                String searchWord = currentWord.replaceAll('__', '').toLowerCase();
                List<String> matches = state.wildcards
                    .where((w) => w.name.toLowerCase().startsWith(searchWord))
                    .map((w) => "__${w.name}__")
                    .take(15)
                    .toList();

                setModalState(() {
                  suggestions = matches;
                });
                return;
              }

              List<String> matches = smartMatchTags(state.danbooruTags, currentWord);

              setModalState(() {
                suggestions = matches;
              });
            }

            void insertTag(String tag) {
              String text = controller.text;
              int cursor = controller.selection.baseOffset;
              if (cursor < 0) cursor = text.length;

              String beforeCursor = text.substring(0, cursor);
              String afterCursor = text.substring(cursor);
              String newBefore = PromptUtils.buildCompletedText(beforeCursor, tag);

              controller.value = TextEditingValue(
                text: newBefore + afterCursor,
                selection: TextSelection.collapsed(offset: newBefore.length),
              );

              setModalState(() {
                suggestions.clear();
              });
              state.saveAllSettings();
              state.refreshUI();
            }

            return Dialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(icon, color: color, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    Container(
                      height: 250,
                      decoration: BoxDecoration(
                        border: Border.all(color: color.withValues(alpha: 0.5)),
                        borderRadius: BorderRadius.circular(12),
                        color: const Color(0xFF121212),
                      ),
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        onChanged: (_) {
                          onTextChanged();
                          state.saveAllSettings();
                          state.refreshUI();
                        },
                        maxLines: null,
                        expands: true,
                        style: const TextStyle(color: Colors.white, height: 1.5),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: suggestions.isNotEmpty ? 40 : 0,
                      child: suggestions.isNotEmpty
                          ? ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: suggestions.length,
                              itemBuilder: (context, index) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8.0),
                                  child: ActionChip(
                                    label: Text(
                                      suggestions[index],
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    backgroundColor: color.withValues(alpha: 0.2),
                                    side: BorderSide(color: color, width: 1.5),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    onPressed: () => insertTag(suggestions[index]),
                                  ),
                                );
                              },
                            )
                          : const SizedBox.shrink(),
                    ),

                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          onPressed: () {
                            controller.clear();
                            setModalState(() {
                              suggestions.clear();
                            });
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: color),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Icon(Icons.delete_sweep, color: color, size: 20),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () {
                            controller.text = initialText;
                            setModalState(() {
                              suggestions.clear();
                            });
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: color),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Icon(Icons.restore, color: color, size: 20),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: color,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text(
                            "닫기",
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) => focusNode.dispose());
  }

  Widget _buildPromptCard(
    BuildContext context,
    AppState state, {
    required String title,
    required IconData icon,
    required Color color,
    required TextEditingController controller,
    String hint = "",
  }) {
    return GestureDetector(
      onTap: () => _showPromptEditDialog(context, state, title, icon, color, controller),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: color, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        title,
                        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  Icon(Icons.edit, color: color, size: 16),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                controller.text.isEmpty ? hint : controller.text,
                style: TextStyle(
                  color: controller.text.isEmpty ? Colors.white30 : Colors.white,
                  height: 1.5,
                  fontSize: 14,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================================
  // 섹션 메타정보 (ID → 제목, 아이콘, 색상)
  // ============================================================================
  static const Map<String, Map<String, dynamic>> _sectionMeta = {
    'positive': {'title': '긍정적 프롬프트', 'icon': Icons.add_circle_outline, 'color': 0xFF00BFA5},
    'prefix': {'title': '선행 프롬프트', 'icon': Icons.arrow_right_alt, 'color': 0xFF29B6F6},
    'suffix': {'title': '후행 프롬프트', 'icon': Icons.keyboard_double_arrow_right, 'color': 0xFFFFA000},
    'negative': {'title': '부정적 프롬프트', 'icon': Icons.remove_circle_outline, 'color': 0xFFFF5252},
    'removeChips': {'title': '태그 제거', 'icon': Icons.auto_fix_high, 'color': 0xFF8B5CF6},
    'customRemove': {'title': '개별 제거 프롬프트', 'icon': Icons.delete_outline, 'color': 0xFF9E9E9E},
    'conditional': {'title': '조건부 트리거', 'icon': Icons.bolt, 'color': 0xFF29B6F6},
  };

  // ============================================================================
  // 섹션 헤더 (접기/펴기 토글 + 드래그 핸들)
  // ============================================================================
  Widget _buildSectionHeader({
    required AppState state,
    required String sectionId,
    required bool isCollapsed,
    required int index,
  }) {
    final meta = _sectionMeta[sectionId]!;
    final color = Color(meta['color'] as int);
    final icon = meta['icon'] as IconData;
    final title = meta['title'] as String;

    return GestureDetector(
      onTap: () {
        if (state.collapsedSections.contains(sectionId)) {
          state.collapsedSections.remove(sectionId);
        } else {
          state.collapsedSections.add(sectionId);
        }
        state.saveAllSettings();
        state.refreshUI();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isCollapsed ? color.withValues(alpha: 0.08) : color.withValues(alpha: 0.15),
          borderRadius: isCollapsed
              ? BorderRadius.circular(12)
              : const BorderRadius.vertical(top: Radius.circular(12)),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            // 접기/펴기 화살표
            Icon(isCollapsed ? Icons.chevron_right : Icons.expand_more, color: color, size: 22),
            const SizedBox(width: 4),
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            // 드래그 핸들 (접혔을 때만 표시, 잡고 드래그로 순서 변경)
            if (isCollapsed)
              ReorderableDragStartListener(
                index: index,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(Icons.drag_handle, color: color.withValues(alpha: 0.8), size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ============================================================================
  // 섹션 컨텐츠 (접히지 않았을 때 보이는 실제 내용)
  // ============================================================================
  Widget _buildSectionContent(BuildContext context, AppState state, String sectionId) {
    switch (sectionId) {
      case 'positive':
        return _buildPromptCardBody(
          context,
          state,
          color: const Color(0xFF00BFA5),
          controller: state.positiveController,
          hint: "태그를 입력하세요...",
          icon: Icons.add_circle_outline,
          title: "긍정적 프롬프트",
        );
      case 'prefix':
        return _buildPromptCardBody(
          context,
          state,
          color: const Color(0xFF29B6F6),
          controller: state.prefixController,
          hint: "1girl, solo, artist:kuroboshi kouhaku...",
          icon: Icons.arrow_right_alt,
          title: "선행 프롬프트",
        );
      case 'suffix':
        return _buildPromptCardBody(
          context,
          state,
          color: const Color(0xFFFFA000),
          controller: state.suffixController,
          hint: "고정으로 맨 뒤에 들어갈 태그...",
          icon: Icons.keyboard_double_arrow_right,
          title: "후행 프롬프트",
        );
      case 'negative':
        return _buildPromptCardBody(
          context,
          state,
          color: const Color(0xFFFF5252),
          controller: state.negativeController,
          hint: "text, logo, worst quality...",
          icon: Icons.remove_circle_outline,
          title: "부정적 프롬프트",
        );
      case 'removeChips':
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            border: Border.all(color: const Color(0xFF8B5CF6).withValues(alpha: 0.3)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildRemoveChip("특징 제거", Icons.auto_fix_high, state.removeCharacteristics, (v) {
                state.removeCharacteristics = v;
                state.saveAllSettings();
                state.refreshUI();
              }),
              _buildRemoveChip("의상 제거", Icons.checkroom, state.removeClothes, (v) {
                state.removeClothes = v;
                state.saveAllSettings();
                state.refreshUI();
              }),
              _buildRemoveChip("색상 제거", Icons.palette, state.removeColors, (v) {
                state.removeColors = v;
                state.saveAllSettings();
                state.refreshUI();
              }),
            ],
          ),
        );
      case 'customRemove':
        return _buildPromptCardBody(
          context,
          state,
          color: Colors.grey,
          controller: state.customRemoveController,
          hint: "*censor*, *skirt*, 단어...",
          icon: Icons.delete_outline,
          title: "개별 제거 프롬프트",
        );
      case 'conditional':
        return Column(
          children: [
            _buildPromptCardBody(
              context,
              state,
              color: const Color(0xFF29B6F6),
              controller: state.conditionalRuleController,
              hint: "# 주석을 적을 수 있습니다\n(e|q):*skirt=*skirt, pants\n(cat*):cat*^dog*",
              icon: Icons.bolt,
              title: "조건부 트리거 작성 (줄바꿈 구분)",
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF29B6F6).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF29B6F6).withValues(alpha: 0.3)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "💡 문법 가이드",
                    style: TextStyle(
                      color: Color(0xFF29B6F6),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "(조건):A=B → 조건 만족시 A를 B로 덮어쓰기 교체",
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Text(
                    "(조건):A^B → 조건 만족시 A를 B로 교체 (*A인 경우 포함되는 프롬프트중 A 부분만 교체)",
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Text(
                    "(조건):prefix=B → 긍정 프롬프트 맨 앞에 B 추가",
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Text(
                    "(조건):suffix=B → 긍정 프롬프트 맨 뒤에 B 추가",
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "*조건식에 g, s, q, e 를 쓰면 해당 연령 등급을 인식합니다.",
                    style: TextStyle(color: Colors.yellowAccent, fontSize: 11),
                  ),
                  Text(
                    "*조건식에는 *, &, |, ! 기호를 섞어 쓸 수 있습니다.",
                    style: TextStyle(color: Colors.yellowAccent, fontSize: 11),
                  ),
                  Text(
                    "*맨 앞에 #을 붙이면 주석으로 처리되어 실행되지 않습니다.",
                    style: TextStyle(color: Colors.yellowAccent, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  // 프롬프트 카드 본문 (헤더 분리 후 터치하면 편집 다이얼로그 열림)
  Widget _buildPromptCardBody(
    BuildContext context,
    AppState state, {
    required Color color,
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required String title,
  }) {
    return GestureDetector(
      onTap: () => _showPromptEditDialog(context, state, title, icon, color, controller),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  controller.text.isEmpty ? hint : controller.text,
                  style: TextStyle(
                    color: controller.text.isEmpty ? Colors.white30 : Colors.white,
                    height: 1.5,
                    fontSize: 14,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.edit, color: color, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRemoveChip(String label, IconData icon, bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: value ? Colors.deepPurpleAccent.withValues(alpha: 0.25) : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: value ? Colors.deepPurpleAccent : Colors.white24,
            width: value ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: value ? Colors.deepPurpleAccent : Colors.white54),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: value ? Colors.white : Colors.white54,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimpleCheck(
    BuildContext context,
    AppState state,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Theme(
          data: Theme.of(context).copyWith(unselectedWidgetColor: Colors.deepPurpleAccent),
          child: Checkbox(
            value: value,
            onChanged: (v) {
              onChanged(v ?? false);
              state.saveAllSettings();
              state.refreshUI();
            },
            activeColor: Colors.deepPurpleAccent,
            checkColor: Colors.white,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(width: 6),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    bool canChangePrompt = !state.isRandomLocked && state.gelbooruPrompts.isNotEmpty;
    Color promptActionColor = canChangePrompt ? const Color(0xFF8B5CF6) : Colors.grey;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        children: [
                          const TextSpan(
                            text: "Anlas  ",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          TextSpan(
                            text: state.isApiConnected ? "${state.currentAnlas}" : "0",
                            style: const TextStyle(
                              color: Colors.amber,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.sync, color: promptActionColor, size: 28),
                    tooltip: "현재 프롬프트 다시 불러오기",
                    onPressed: canChangePrompt ? () => state.reloadCurrentPrompt() : null,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton(
                    onPressed: canChangePrompt ? () => state.handleNextPrompt() : null,
                    style: OutlinedButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      fixedSize: const Size(160, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      side: BorderSide(color: promptActionColor, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                    child: Text(
                      "다음 프롬프트",
                      style: TextStyle(
                        color: promptActionColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 0),
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          "검색 : ${state.gelbooruTotal}",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          "남음 : ${state.gelbooruRemaining}",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.settings,
                      color: state.isGelbooruExpanded ? const Color(0xFF8B5CF6) : Colors.grey,
                      size: 28,
                    ),
                    onPressed: () {
                      state.isGelbooruExpanded = !state.isGelbooruExpanded;
                      state.refreshUI();
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: (state.isLoading || state.isInpaintLoading || state.isUpscaleLoading)
                        ? null
                        : () async {
                            if (state.checkIfAnlasConsumed()) {
                              bool? confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: const Color(0xFF1E1E1E),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  title: const Row(
                                    children: [
                                      Icon(Icons.warning_amber_rounded, color: Colors.amber),
                                      SizedBox(width: 8),
                                      Text(
                                        "포인트 소모 안내",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  content: const Text(
                                    "Anlas가 소모됩니다. 괜찮습니까?",
                                    style: TextStyle(color: Colors.white70, fontSize: 15),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: const Text(
                                        "취소",
                                        style: TextStyle(color: Colors.grey, fontSize: 15),
                                      ),
                                    ),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF8B5CF6),
                                      ),
                                      child: const Text(
                                        "생성하기",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm != true) {
                                return;
                              }
                            }
                            if (!context.mounted) {
                              return;
                            }
                            state.handleGenerate(context, widget.onScrollToHistoryEnd ?? () {});
                          },
                    style: ElevatedButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      fixedSize: const Size(160, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      backgroundColor: (state.isInpaintLoading || state.isUpscaleLoading)
                          ? Colors.grey[700]
                          : const Color(0xFF8B5CF6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                    icon: (state.isLoading || state.isInpaintLoading || state.isUpscaleLoading)
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
                    label: Text(
                      state.isLoading
                          ? "생성 중..."
                          : (state.isInpaintLoading
                                ? "인페인트 중..."
                                : (state.isUpscaleLoading ? "업스케일 중..." : "이미지 생성 시작")),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // 토큰 카운터
              Builder(
                builder: (context) {
                  final combined = [
                    state.prefixController.text,
                    state.positiveController.text,
                    state.suffixController.text,
                  ].where((s) => s.trim().isNotEmpty).join(', ');
                  final tokens = estimateTokenCount(combined);
                  final ratio = (tokens / 512).clamp(0.0, 1.0);
                  final color = tokens > 450
                      ? Colors.redAccent
                      : tokens > 350
                      ? Colors.orangeAccent
                      : Colors.white38;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Icon(Icons.token, size: 14, color: color),
                        const SizedBox(width: 4),
                        Text("~$tokens / 512 tokens", style: TextStyle(color: color, fontSize: 11)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: ratio,
                              minHeight: 3,
                              backgroundColor: Colors.white12,
                              valueColor: AlwaysStoppedAnimation(color),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _showPresetBottomSheet(context, state),
                    icon: const Icon(Icons.bookmarks, color: Colors.deepPurpleAccent, size: 16),
                    label: const Text(
                      "프리셋 관리",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: Colors.deepPurpleAccent.withValues(alpha: 0.15),
                      side: BorderSide(color: Colors.deepPurpleAccent.withValues(alpha: 0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 0),
                      minimumSize: const Size(140, 36),
                    ),
                  ),

                  Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Transform.scale(
                          scale: 1.2,
                          child: Checkbox(
                            value: state.isRandomLocked,
                            onChanged: (v) {
                              state.isRandomLocked = v ?? false;
                              state.saveAllSettings();
                              state.refreshUI();
                            },
                            activeColor: const Color(0xFF8B5CF6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text("랜덤 잠금", style: TextStyle(color: Colors.white, fontSize: 13)),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Transform.scale(
                          scale: 1.2,
                          child: Checkbox(
                            value: state.isAutoSave,
                            onChanged: (v) {
                              state.isAutoSave = v ?? false;
                              state.saveAllSettings();
                              state.refreshUI();
                            },
                            activeColor: const Color(0xFF8B5CF6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text("자동 저장", style: TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (state.isGelbooruExpanded) ...[
            _InlineAutocompleteTextField(
              controller: state.gelbooruIncludeController,
              hintText: "포함할 태그",
              state: state,
            ),
            const SizedBox(height: 8),
            _InlineAutocompleteTextField(
              controller: state.gelbooruExcludeController,
              hintText: "제외할 태그",
              state: state,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _buildSimpleCheck(context, state, "E", state.ratingE, (v) => state.ratingE = v),
                _buildSimpleCheck(context, state, "Q", state.ratingQ, (v) => state.ratingQ = v),
                _buildSimpleCheck(context, state, "S", state.ratingS, (v) => state.ratingS = v),
                _buildSimpleCheck(context, state, "G", state.ratingG, (v) => state.ratingG = v),
                const Spacer(),
                ElevatedButton(
                  onPressed: state.isGelbooruLoading
                      ? null
                      : () => state.handleGelbooruSearch(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2A2A35),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                    state.isGelbooruLoading ? "검색 중" : "검색",
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // ============================================================================
          // 🚀 접기/펴기 + 드래그 재배치 가능한 프롬프트 섹션
          // ============================================================================
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) {
              return Material(
                elevation: 4,
                color: Colors.transparent,
                shadowColor: Colors.deepPurpleAccent.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
                child: child,
              );
            },
            onReorder: (oldIndex, newIndex) {
              if (newIndex > oldIndex) newIndex--;
              final item = state.promptSectionOrder.removeAt(oldIndex);
              state.promptSectionOrder.insert(newIndex, item);
              state.saveAllSettings();
              state.refreshUI();
            },
            children: [
              for (int idx = 0; idx < state.promptSectionOrder.length; idx++)
                Padding(
                  key: ValueKey(state.promptSectionOrder[idx]),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    children: [
                      _buildSectionHeader(
                        state: state,
                        sectionId: state.promptSectionOrder[idx],
                        isCollapsed: state.collapsedSections.contains(
                          state.promptSectionOrder[idx],
                        ),
                        index: idx,
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                        child: state.collapsedSections.contains(state.promptSectionOrder[idx])
                            ? const SizedBox.shrink()
                            : _buildSectionContent(context, state, state.promptSectionOrder[idx]),
                      ),
                    ],
                  ),
                ),
            ],
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
