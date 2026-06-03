import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../utils/prompt_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import '../models/app_state.dart';
import '../models/nai_character.dart';

// ============================================================================
// 좁은 공간(검색창) 전용 세로형 자동완성 텍스트 필드 위젯
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
    int lastParen = max(
      beforeCursor.lastIndexOf(')'),
      max(
        beforeCursor.lastIndexOf('('),
        max(beforeCursor.lastIndexOf('{'), beforeCursor.lastIndexOf('|')),
      ),
    );
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
    if (cursor < 0) {
      cursor = text.length;
    }

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
  // 프리셋 카테고리 분류
  String _getPresetCategory(NaiPreset preset) {
    final f = preset.savedFields;
    if (f.length == 1 && f.contains('positive')) {
      return 'positive';
    }
    if (f.length == 1 && f.contains('prefix')) {
      return 'prefix';
    }
    if (f.length == 1 && f.contains('characters')) {
      return 'characters';
    }
    return 'etc';
  }

  void _showPresetBottomSheet(BuildContext context, AppState state) {
    String selectedCategory = 'positive'; // 기본 탭

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (modalContext, setModalState) {
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
                  // 타이틀 + 저장 버튼
                  Row(
                    children: [
                      const Icon(Icons.bookmarks, color: Colors.deepPurpleAccent, size: 24),
                      const SizedBox(width: 8),
                      const Text(
                        "프롬프트 프리셋 관리",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () {
                          _showPresetSaveDialog(modalContext, state);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.deepPurpleAccent),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add, color: Colors.deepPurpleAccent, size: 16),
                              SizedBox(width: 4),
                              Text(
                                "저장",
                                style: TextStyle(
                                  color: Colors.deepPurpleAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 카테고리 탭
                  Row(
                    children: [
                      _buildCategoryChip(
                        'positive',
                        '긍정',
                        const Color(0xFF00BFA5),
                        selectedCategory,
                        (cat) {
                          setModalState(() => selectedCategory = cat);
                        },
                      ),
                      const SizedBox(width: 6),
                      _buildCategoryChip(
                        'prefix',
                        '선행',
                        const Color(0xFF29B6F6),
                        selectedCategory,
                        (cat) {
                          setModalState(() => selectedCategory = cat);
                        },
                      ),
                      const SizedBox(width: 6),
                      _buildCategoryChip(
                        'characters',
                        '캐릭터',
                        Colors.deepPurpleAccent,
                        selectedCategory,
                        (cat) {
                          setModalState(() => selectedCategory = cat);
                        },
                      ),
                      const SizedBox(width: 6),
                      _buildCategoryChip('etc', '기타', Colors.grey, selectedCategory, (cat) {
                        setModalState(() => selectedCategory = cat);
                      }),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Expanded(
                    child: Consumer<AppState>(
                      builder: (context, consumerState, child) {
                        // 선택된 카테고리로 필터링
                        final filtered = consumerState.presets
                            .asMap()
                            .entries
                            .where((e) => _getPresetCategory(e.value) == selectedCategory)
                            .toList();

                        if (filtered.isEmpty) {
                          return const Center(
                            child: Text(
                              "이 카테고리에 저장된 프리셋이 없습니다.",
                              style: TextStyle(color: Colors.white30),
                            ),
                          );
                        }
                        return ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1, color: Colors.white12),
                          itemBuilder: (context, index) {
                            final originalIndex = filtered[index].key;
                            final preset = filtered[index].value;
                            return ListTile(
                              dense: true,
                              visualDensity: const VisualDensity(vertical: -3),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 0,
                              ),
                              // 기타 제외 카테고리에서만 미리보기 이미지 표시
                              leading: selectedCategory != 'etc'
                                  ? SizedBox(
                                      width: 36,
                                      height: 36,
                                      child: preset.previewImage != null
                                          ? ClipRRect(
                                              borderRadius: BorderRadius.circular(6),
                                              child: Image.memory(
                                                base64Decode(preset.previewImage!),
                                                fit: BoxFit.cover,
                                              ),
                                            )
                                          : Container(
                                              decoration: BoxDecoration(
                                                color: Colors.white.withValues(alpha: 0.05),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: Colors.white12),
                                              ),
                                              child: const Icon(
                                                Icons.image_outlined,
                                                color: Colors.white24,
                                                size: 18,
                                              ),
                                            ),
                                    )
                                  : null,
                              title: Text(
                                preset.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                preset.savedFields
                                    .map((f) {
                                      const labels = {
                                        'positive': '긍정',
                                        'negative': '부정',
                                        'prefix': '선행',
                                        'suffix': '후행',
                                        'settings': '설정',
                                        'characters': '캐릭터',
                                      };
                                      return labels[f] ?? f;
                                    })
                                    .join(' · '),
                                style: const TextStyle(color: Colors.white54, fontSize: 11),
                              ),
                              onTap: () {
                                final category = _getPresetCategory(preset);
                                final bool isEtc = category == 'etc';

                                showDialog(
                                  context: modalContext,
                                  builder: (ctx) {
                                    Set<String> expandedSections = {};

                                    return StatefulBuilder(
                                      builder: (ctx, setDialogState) {
                                        Widget buildSection(
                                          String label,
                                          String text,
                                          Color color,
                                        ) {
                                          if (text.trim().isEmpty) {
                                            return const SizedBox.shrink();
                                          }

                                          if (!isEtc) {
                                            // 긍정/선행/캐릭터: 항상 펼쳐진 상태
                                            return Padding(
                                              padding: const EdgeInsets.only(bottom: 8),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Container(
                                                    width: double.infinity,
                                                    padding: const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 8,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: color.withValues(alpha: 0.1),
                                                      borderRadius: const BorderRadius.vertical(
                                                        top: Radius.circular(8),
                                                      ),
                                                      border: Border.all(
                                                        color: color.withValues(alpha: 0.3),
                                                      ),
                                                    ),
                                                    child: Text(
                                                      label,
                                                      style: TextStyle(
                                                        color: color,
                                                        fontSize: 14,
                                                        fontWeight: FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                  Container(
                                                    width: double.infinity,
                                                    padding: const EdgeInsets.all(10),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black26,
                                                      borderRadius: const BorderRadius.vertical(
                                                        bottom: Radius.circular(8),
                                                      ),
                                                      border: Border.all(
                                                        color: color.withValues(alpha: 0.2),
                                                      ),
                                                    ),
                                                    child: Text(
                                                      text,
                                                      style: const TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 15,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }

                                          // 기타: 접기/펴기
                                          final isExpanded = expandedSections.contains(label);
                                          return Padding(
                                            padding: const EdgeInsets.only(bottom: 8),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                GestureDetector(
                                                  onTap: () {
                                                    setDialogState(() {
                                                      if (isExpanded) {
                                                        expandedSections.remove(label);
                                                      } else {
                                                        expandedSections.add(label);
                                                      }
                                                    });
                                                  },
                                                  child: Container(
                                                    width: double.infinity,
                                                    padding: const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 8,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: color.withValues(alpha: 0.1),
                                                      borderRadius: BorderRadius.circular(8),
                                                      border: Border.all(
                                                        color: color.withValues(alpha: 0.3),
                                                      ),
                                                    ),
                                                    child: Row(
                                                      children: [
                                                        Icon(
                                                          isExpanded
                                                              ? Icons.expand_more
                                                              : Icons.chevron_right,
                                                          color: color,
                                                          size: 18,
                                                        ),
                                                        const SizedBox(width: 4),
                                                        Flexible(
                                                          flex: 2,
                                                          child: Text(
                                                            label,
                                                            style: TextStyle(
                                                              color: color,
                                                              fontSize: 14,
                                                              fontWeight: FontWeight.bold,
                                                            ),
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                        ),
                                                        if (!isExpanded) ...[
                                                          const SizedBox(width: 8),
                                                          Flexible(
                                                            flex: 3,
                                                            child: Text(
                                                              text,
                                                              style: TextStyle(
                                                                color: color.withValues(alpha: 0.5),
                                                                fontSize: 12,
                                                              ),
                                                              overflow: TextOverflow.ellipsis,
                                                              maxLines: 1,
                                                              textAlign: TextAlign.right,
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                                if (isExpanded)
                                                  Container(
                                                    width: double.infinity,
                                                    padding: const EdgeInsets.all(10),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black26,
                                                      borderRadius: const BorderRadius.vertical(
                                                        bottom: Radius.circular(8),
                                                      ),
                                                      border: Border.all(
                                                        color: color.withValues(alpha: 0.2),
                                                      ),
                                                    ),
                                                    child: Text(
                                                      text,
                                                      style: const TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 15,
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
                                                // 미리보기 이미지 (기타 제외)
                                                if (!isEtc) ...[
                                                  Center(
                                                    child: GestureDetector(
                                                      onTap: () async {
                                                        final picker = ImagePicker();
                                                        final picked = await picker.pickImage(
                                                          source: ImageSource.gallery,
                                                          maxWidth: 200,
                                                        );
                                                        if (picked != null) {
                                                          final bytes = await picked.readAsBytes();
                                                          // 100px 썸네일로 변환
                                                          final decoded = img.decodeImage(bytes);
                                                          if (decoded != null) {
                                                            final thumb = img.copyResize(
                                                              decoded,
                                                              width: 200,
                                                            );
                                                            final jpgBytes = Uint8List.fromList(
                                                              img.encodeJpg(thumb, quality: 85),
                                                            );
                                                            preset.previewImage = base64Encode(
                                                              jpgBytes,
                                                            );
                                                            state.saveAllSettings();
                                                            state.refreshUI();
                                                            setDialogState(() {});
                                                          }
                                                        }
                                                      },
                                                      child: preset.previewImage != null
                                                          ? ClipRRect(
                                                              borderRadius: BorderRadius.circular(
                                                                10,
                                                              ),
                                                              child: Image.memory(
                                                                base64Decode(preset.previewImage!),
                                                                width: 100,
                                                                height: 100,
                                                                fit: BoxFit.cover,
                                                              ),
                                                            )
                                                          : Container(
                                                              width: 100,
                                                              height: 100,
                                                              decoration: BoxDecoration(
                                                                color: Colors.white.withValues(
                                                                  alpha: 0.05,
                                                                ),
                                                                borderRadius: BorderRadius.circular(
                                                                  10,
                                                                ),
                                                                border: Border.all(
                                                                  color: Colors.white24,
                                                                  style: BorderStyle.solid,
                                                                ),
                                                              ),
                                                              child: const Column(
                                                                mainAxisAlignment:
                                                                    MainAxisAlignment.center,
                                                                children: [
                                                                  Icon(
                                                                    Icons
                                                                        .add_photo_alternate_outlined,
                                                                    color: Colors.white30,
                                                                    size: 28,
                                                                  ),
                                                                  SizedBox(height: 4),
                                                                  Text(
                                                                    "미리보기 추가",
                                                                    style: TextStyle(
                                                                      color: Colors.white30,
                                                                      fontSize: 10,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 12),
                                                ],
                                                buildSection(
                                                  "선행",
                                                  preset.prefix,
                                                  const Color(0xFF29B6F6),
                                                ),
                                                buildSection(
                                                  "긍정적",
                                                  preset.positive,
                                                  const Color(0xFF00BFA5),
                                                ),
                                                buildSection(
                                                  "후행",
                                                  preset.suffix,
                                                  const Color(0xFFFFA000),
                                                ),
                                                buildSection(
                                                  "부정적",
                                                  preset.negative,
                                                  const Color(0xFFFF5252),
                                                ),
                                                if (preset.settings != null)
                                                  buildSection(
                                                    "설정",
                                                    "모델: ${preset.settings!['model'] ?? '-'}\n"
                                                        "샘플러: ${preset.settings!['sampler'] ?? '-'}\n"
                                                        "스텝: ${preset.settings!['steps'] ?? '-'} / CFG: ${preset.settings!['cfg'] ?? '-'}",
                                                    Colors.amber,
                                                  ),
                                                if (preset.characters != null &&
                                                    preset.characters!.isNotEmpty)
                                                  ...preset.characters!.asMap().entries.map((
                                                    entry,
                                                  ) {
                                                    final i = entry.key;
                                                    final c = entry.value;
                                                    final pos = c['positive'] ?? '';
                                                    final neg = c['uc'] ?? c['negative'] ?? '';
                                                    final display = [
                                                      if (pos.toString().isNotEmpty) "긍정: $pos",
                                                      if (neg.toString().isNotEmpty) "부정: $neg",
                                                    ].join('\n');
                                                    return buildSection(
                                                      c['name']?.toString().isNotEmpty == true
                                                          ? c['name']
                                                          : "캐릭터 ${i + 1}",
                                                      display.isEmpty ? '(비어있음)' : display,
                                                      Colors.deepPurpleAccent,
                                                    );
                                                  }),
                                                if (preset.prefix.isEmpty &&
                                                    preset.positive.isEmpty &&
                                                    preset.suffix.isEmpty &&
                                                    preset.negative.isEmpty &&
                                                    preset.settings == null &&
                                                    preset.characters == null)
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
                                );
                              },
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // 복사 버튼
                                  OutlinedButton(
                                    onPressed: () {
                                      final category = _getPresetCategory(preset);
                                      if (category == 'etc') {
                                        // 기타: 어떤 항목을 복사할지 선택
                                        _showPresetCopyDialog(modalContext, preset);
                                      } else {
                                        // 단일 카테고리: 해당 내용 바로 복사
                                        String text = '';
                                        if (category == 'positive') {
                                          text = preset.positive;
                                        } else if (category == 'prefix') {
                                          text = preset.prefix;
                                        } else if (category == 'characters' &&
                                            preset.characters != null) {
                                          text = preset.characters!
                                              .map((c) => c['positive'] ?? '')
                                              .where((s) => s.toString().isNotEmpty)
                                              .join(', ');
                                        }
                                        if (text.isNotEmpty) {
                                          Clipboard.setData(ClipboardData(text: text));
                                          ScaffoldMessenger.of(modalContext).showSnackBar(
                                            SnackBar(
                                              duration: const Duration(milliseconds: 2400),
                                              content: Text("클립보드에 복사했습니다."),
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.white24),
                                      padding: const EdgeInsets.symmetric(horizontal: 10),
                                    ),
                                    child: const Icon(Icons.copy, color: Colors.white54, size: 16),
                                  ),
                                  const SizedBox(width: 4),
                                  // 적용 버튼
                                  OutlinedButton(
                                    onPressed: () {
                                      final category = _getPresetCategory(preset);
                                      if (category == 'etc') {
                                        // 기타: 어떤 항목을 불러올지 선택
                                        _showPresetApplyDialog(
                                          context,
                                          modalContext,
                                          consumerState,
                                          preset,
                                        );
                                      } else {
                                        // 단일 카테고리: 바로 적용
                                        _applyPreset(consumerState, preset, preset.savedFields);
                                        Navigator.pop(modalContext);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            duration: const Duration(milliseconds: 2400),
                                            content: Text("'${preset.name}' 프리셋을 불러왔습니다."),
                                          ),
                                        );
                                      }
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
                                  const SizedBox(width: 4),
                                  SizedBox(
                                    width: 32,
                                    height: 32,
                                    child: IconButton(
                                      padding: EdgeInsets.zero,
                                      iconSize: 20,
                                      icon: const Icon(Icons.delete, color: Colors.redAccent),
                                      onPressed: () {
                                        consumerState.presets.removeAt(originalIndex);
                                        consumerState.saveAllSettings();
                                        consumerState.refreshUI();
                                      },
                                    ),
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
      },
    );
  }

  // 카테고리 칩 빌더
  Widget _buildCategoryChip(
    String category,
    String label,
    Color color,
    String selected,
    ValueChanged<String> onTap,
  ) {
    final isActive = selected == category;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(category),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isActive ? color.withValues(alpha: 0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isActive ? color : Colors.white24, width: isActive ? 1.5 : 1),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: isActive ? color : Colors.white38,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 프리셋 저장 다이얼로그 (분리)
  void _showPresetSaveDialog(BuildContext parentContext, AppState state) {
    TextEditingController nameCtrl = TextEditingController();
    Map<String, bool> fields = {
      'positive': true,
      'negative': true,
      'prefix': true,
      'suffix': true,
      'characters': false,
      'settings': false,
    };
    // 캐릭터 개별 선택
    Set<int> selectedCharIndices = {};
    for (int i = 0; i < state.characters.length; i++) {
      if (state.characters[i].isActive) {
        selectedCharIndices.add(i);
      }
    }

    showDialog(
      context: parentContext,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Widget fieldChip(String key, String label, Color color) {
            final selected = fields[key]!;
            return GestureDetector(
              onTap: () => setDialogState(() => fields[key] = !selected),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? color.withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected ? color : Colors.white24,
                    width: selected ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      selected ? Icons.check_circle : Icons.circle_outlined,
                      size: 16,
                      color: selected ? color : Colors.white38,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: selected ? color : Colors.white38,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              "프리셋 저장",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: "프리셋 이름을 입력하세요",
                      hintStyle: const TextStyle(color: Colors.white30),
                      filled: true,
                      fillColor: const Color(0xFF121212),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text("저장할 항목 선택", style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: fieldChip('positive', '긍정적', const Color(0xFF00BFA5))),
                      const SizedBox(width: 8),
                      Expanded(child: fieldChip('negative', '부정적', const Color(0xFFFF5252))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: fieldChip('prefix', '선행', const Color(0xFF29B6F6))),
                      const SizedBox(width: 8),
                      Expanded(child: fieldChip('suffix', '후행', const Color(0xFFFFA000))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: fieldChip('characters', '캐릭터', Colors.deepPurpleAccent)),
                      const SizedBox(width: 8),
                      Expanded(child: fieldChip('settings', '설정', Colors.amber)),
                    ],
                  ),
                  // 캐릭터 체크 시 캐릭터 목록 표시
                  ...(fields['characters']! && state.characters.isNotEmpty
                      ? [
                          const SizedBox(height: 8),
                          ...state.characters.asMap().entries.map((entry) {
                            final i = entry.key;
                            final c = entry.value;
                            final isSelected = selectedCharIndices.contains(i);
                            final charName = c.name.isNotEmpty ? c.name : "캐릭터 ${i + 1}";
                            final preview = c.positive.isNotEmpty ? c.positive : '(비어있음)';
                            return GestureDetector(
                              onTap: () => setDialogState(() {
                                if (isSelected) {
                                  selectedCharIndices.remove(i);
                                } else {
                                  selectedCharIndices.add(i);
                                }
                              }),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Colors.deepPurpleAccent.withValues(alpha: 0.1)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isSelected
                                        ? Colors.deepPurpleAccent.withValues(alpha: 0.4)
                                        : Colors.white10,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                                      size: 16,
                                      color: isSelected ? Colors.deepPurpleAccent : Colors.white38,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      charName,
                                      style: TextStyle(
                                        color: isSelected ? Colors.white : Colors.white54,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        preview,
                                        style: const TextStyle(color: Colors.white30, fontSize: 11),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ]
                      : []),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("취소", style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () {
                  if (nameCtrl.text.trim().isEmpty) {
                    final now = DateTime.now();
                    nameCtrl.text =
                        "${now.year.toString().substring(2)}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}";
                  }
                  final savedFields = fields.entries
                      .where((e) => e.value)
                      .map((e) => e.key)
                      .toSet();

                  // 비어있는 필드는 저장에서 제외
                  if (savedFields.contains('positive') &&
                      state.positiveController.text.trim().isEmpty) {
                    savedFields.remove('positive');
                  }
                  if (savedFields.contains('negative') &&
                      state.negativeController.text.trim().isEmpty) {
                    savedFields.remove('negative');
                  }
                  if (savedFields.contains('prefix') &&
                      state.prefixController.text.trim().isEmpty) {
                    savedFields.remove('prefix');
                  }
                  if (savedFields.contains('suffix') &&
                      state.suffixController.text.trim().isEmpty) {
                    savedFields.remove('suffix');
                  }

                  // 선택된 캐릭터만 저장
                  List<Map<String, dynamic>>? charsToSave;
                  if (savedFields.contains('characters') && selectedCharIndices.isNotEmpty) {
                    charsToSave = selectedCharIndices
                        .toList()
                        .where((i) => i < state.characters.length)
                        .map((i) => state.characters[i].toJson())
                        .toList();
                  } else {
                    savedFields.remove('characters');
                  }

                  if (savedFields.isEmpty) {
                    Navigator.pop(ctx);
                    return;
                  }
                  state.presets.add(
                    NaiPreset(
                      name: nameCtrl.text.trim(),
                      positive: savedFields.contains('positive')
                          ? state.positiveController.text
                          : '',
                      negative: savedFields.contains('negative')
                          ? state.negativeController.text
                          : '',
                      prefix: savedFields.contains('prefix') ? state.prefixController.text : '',
                      suffix: savedFields.contains('suffix') ? state.suffixController.text : '',
                      settings: savedFields.contains('settings')
                          ? state.getSettingsSnapshot()
                          : null,
                      characters: charsToSave,
                      savedFields: savedFields,
                    ),
                  );
                  state.saveAllSettings();
                  state.refreshUI();
                  Navigator.pop(ctx);
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
                child: const Text(
                  "저장",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // 프리셋 적용 (선택된 항목만)
  void _applyPreset(AppState state, NaiPreset preset, Set<String> fieldsToApply) {
    if (fieldsToApply.contains('positive')) {
      state.positiveController.text = preset.positive;
    }
    if (fieldsToApply.contains('negative')) {
      state.negativeController.text = preset.negative;
    }
    if (fieldsToApply.contains('prefix')) {
      state.prefixController.text = preset.prefix;
    }
    if (fieldsToApply.contains('suffix')) {
      state.suffixController.text = preset.suffix;
    }
    if (fieldsToApply.contains('settings') && preset.settings != null) {
      state.applySettingsSnapshot(preset.settings!);
    }
    if (fieldsToApply.contains('characters') && preset.characters != null) {
      // 기존 캐릭터에 추가 (덮어쓰지 않음)
      for (var charJson in preset.characters!) {
        final newChar = NaiCharacter.fromJson(charJson);
        newChar.isActive = true;
        state.characters.add(newChar);
      }
    }
    state.saveAllSettings();
    state.refreshUI();
  }

  // 기타 프리셋 적용 시 항목 선택 다이얼로그
  void _showPresetApplyDialog(
    BuildContext outerContext,
    BuildContext modalContext,
    AppState state,
    NaiPreset preset,
  ) {
    // 저장된 항목만 선택 가능하게
    Map<String, bool> applyFields = {};
    for (var f in preset.savedFields) {
      applyFields[f] = true;
    }

    const labels = {
      'positive': '긍정적',
      'negative': '부정적',
      'prefix': '선행',
      'suffix': '후행',
      'settings': '설정',
      'characters': '캐릭터',
    };

    showDialog(
      context: modalContext,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final entries = applyFields.entries.toList();
          // 항목 수에 따라 2열 또는 1열
          List<Widget> rows = [];
          for (int i = 0; i < entries.length; i += 2) {
            final first = entries[i];
            final second = i + 1 < entries.length ? entries[i + 1] : null;

            Widget chip(MapEntry<String, bool> entry) {
              final color =
                  {
                    'positive': const Color(0xFF00BFA5),
                    'negative': const Color(0xFFFF5252),
                    'prefix': const Color(0xFF29B6F6),
                    'suffix': const Color(0xFFFFA000),
                    'settings': Colors.amber,
                    'characters': Colors.deepPurpleAccent,
                  }[entry.key] ??
                  Colors.grey;

              return Expanded(
                child: GestureDetector(
                  onTap: () => setDialogState(() => applyFields[entry.key] = !entry.value),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: entry.value
                          ? color.withValues(alpha: 0.15)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: entry.value ? color : Colors.white24,
                        width: entry.value ? 1.5 : 1,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        labels[entry.key] ?? entry.key,
                        style: TextStyle(
                          color: entry.value ? color : Colors.white38,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            rows.add(
              Row(
                children: [
                  chip(first),
                  if (second != null) ...[
                    const SizedBox(width: 8),
                    chip(second),
                  ] else
                    const Spacer(),
                ],
              ),
            );
            if (i + 2 < entries.length) {
              rows.add(const SizedBox(height: 8));
            }
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(
              "'${preset.name}' 불러오기",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("불러올 항목을 선택하세요", style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 12),
                ...rows,
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("취소", style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () {
                  final selected = applyFields.entries
                      .where((e) => e.value)
                      .map((e) => e.key)
                      .toSet();
                  if (selected.isNotEmpty) {
                    _applyPreset(state, preset, selected);
                    Navigator.pop(ctx);
                    Navigator.pop(modalContext);
                    ScaffoldMessenger.of(outerContext).showSnackBar(
                      SnackBar(
                        duration: const Duration(milliseconds: 2400),
                        content: Text("'${preset.name}' 프리셋을 불러왔습니다."),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
                child: const Text(
                  "불러오기",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // 기타 프리셋 복사 항목 선택 다이얼로그
  void _showPresetCopyDialog(BuildContext parentContext, NaiPreset preset) {
    const labels = {'positive': '긍정적', 'negative': '부정적', 'prefix': '선행', 'suffix': '후행'};

    // 텍스트가 있는 항목만 표시
    Map<String, String> available = {};
    if (preset.savedFields.contains('positive') && preset.positive.isNotEmpty) {
      available['positive'] = preset.positive;
    }
    if (preset.savedFields.contains('negative') && preset.negative.isNotEmpty) {
      available['negative'] = preset.negative;
    }
    if (preset.savedFields.contains('prefix') && preset.prefix.isNotEmpty) {
      available['prefix'] = preset.prefix;
    }
    if (preset.savedFields.contains('suffix') && preset.suffix.isNotEmpty) {
      available['suffix'] = preset.suffix;
    }
    if (preset.savedFields.contains('characters') && preset.characters != null) {
      for (int i = 0; i < preset.characters!.length; i++) {
        final c = preset.characters![i];
        final pos = c['positive']?.toString() ?? '';
        if (pos.isNotEmpty) {
          available['char_${i}_pos'] = pos;
        }
        final neg = (c['uc'] ?? c['negative'])?.toString() ?? '';
        if (neg.isNotEmpty) {
          available['char_${i}_neg'] = neg;
        }
        // 참고: char_${i}_pos는 _가 뒤따르므로 ${i} 중괄호 필수 ($i_pos는 i_pos 변수로 오인)
      }
    }

    if (available.isEmpty) {
      return;
    }

    showDialog(
      context: parentContext,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          "'${preset.name}' 복사",
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: available.entries.map((entry) {
              String label;
              if (entry.key.startsWith('char_')) {
                final parts = entry.key.split('_');
                final idx = int.parse(parts[1]);
                final type = parts[2] == 'pos' ? '긍정' : '부정';
                final charName = preset.characters![idx]['name']?.toString();
                label = "${charName?.isNotEmpty == true ? charName! : '캐릭터 ${idx + 1}'} ($type)";
              } else {
                label = labels[entry.key] ?? entry.key;
              }
              return ListTile(
                dense: true,
                title: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  entry.value,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.copy, color: Colors.white54, size: 16),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: entry.value));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(parentContext).showSnackBar(
                    SnackBar(
                      duration: const Duration(milliseconds: 2400),
                      content: Text("'$label' 클립보드에 복사했습니다."),
                    ),
                  );
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  // ============================================================================
  // Vibe Transfer 다이얼로그
  // ============================================================================
  // Vibe 내보내기 선택 다이얼로그
  void _showVibeExportDialog(BuildContext parentContext, AppState state) {
    final selected = <int>{};

    Future<void> doExport(List<int> indices) async {
      try {
        final dir = await getTemporaryDirectory();
        final now = DateTime.now();
        final dateStr =
            "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}";
        if (indices.length == 1) {
          final jsonStr = state.exportVibeToNaiv4(state.vibeTransfers[indices[0]]);
          final file = File('${dir.path}/vibe_$dateStr.naiv4vibe');
          await file.writeAsString(jsonStr);
          await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
        } else {
          final vibes = indices
              .map((i) => jsonDecode(state.exportVibeToNaiv4(state.vibeTransfers[i])))
              .toList();
          final jsonStr = jsonEncode({
            "identifier": "novelai-vibe-transfer-bundle",
            "version": 1,
            "vibes": vibes,
          });
          final file = File('${dir.path}/vibes_$dateStr.naiv4vibebundle');
          await file.writeAsString(jsonStr);
          await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
        }
      } catch (e) {
        if (parentContext.mounted) {
          ScaffoldMessenger.of(parentContext).showSnackBar(
            SnackBar(duration: const Duration(milliseconds: 2400), content: Text("내보내기 실패")),
          );
        }
      }
    }

    // vibe가 1개면 바로 내보내기
    if (state.vibeTransfers.length == 1) {
      doExport([0]);
      return;
    }

    showDialog(
      context: parentContext,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            "내보낼 Vibe 선택",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "1개 선택 시 .naiv4vibe,\n2개 이상 선택 시 .naiv4vibebundle로 저장됩니다.",
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 12),
                ...state.vibeTransfers.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final vibe = entry.value;
                  final isSel = selected.contains(idx);
                  return GestureDetector(
                    onTap: () {
                      setDialogState(() {
                        if (isSel) {
                          selected.remove(idx);
                        } else {
                          selected.add(idx);
                        }
                      });
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isSel
                            ? const Color(0xFF8B5CF6).withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: isSel ? const Color(0xFF8B5CF6) : Colors.white24),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSel ? Icons.check_box : Icons.check_box_outline_blank,
                            color: isSel ? const Color(0xFF8B5CF6) : Colors.white38,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.memory(
                              base64Decode(vibe['image']),
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              cacheWidth: 80,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "Vibe ${idx + 1}",
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("취소", style: TextStyle(color: Colors.grey)),
                ),
                const Spacer(),
                ElevatedButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          final sorted = selected.toList()..sort();
                          doExport(sorted);
                        },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6)),
                  child: Text(
                    selected.length <= 1 ? "내보내기" : "${selected.length}개 묶음 내보내기",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Vibe 다이얼로그용 색 테두리 탭
  Widget _buildVibeTab(String title, Color color) {
    return Builder(
      builder: (ctx) {
        final controller = DefaultTabController.of(ctx);
        return AnimatedBuilder(
          animation: controller,
          builder: (_, _) {
            // 현재 탭 인덱스로 active 판정
            final myIndex = title == "Vibe" ? 0 : 1;
            final isActive = controller.index == myIndex;
            return Container(
              height: 34,
              decoration: BoxDecoration(
                color: isActive ? color.withValues(alpha: 0.15) : Colors.transparent,
                border: Border.all(
                  color: isActive ? color : color.withValues(alpha: 0.4),
                  width: isActive ? 1.5 : 1,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  title,
                  style: TextStyle(
                    color: isActive ? color : Colors.white54,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showVibeTransferDialog(BuildContext parentContext, AppState state) {
    showDialog(
      context: parentContext,
      builder: (ctx) => DefaultTabController(
        length: 2,
        child: StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              titlePadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              title: SizedBox(
                height: 38,
                child: TabBar(
                  indicator: const BoxDecoration(),
                  dividerColor: Colors.transparent,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  tabs: [
                    _buildVibeTab("Vibe", const Color(0xFF8B5CF6)),
                    _buildVibeTab("Character", const Color(0xFF00BFA5)),
                  ],
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 360,
                child: TabBarView(
                  children: [
                    // === Vibe Transfer 탭 ===
                    SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 3x3 그리드 (최대 9개)
                          GridView.count(
                            crossAxisCount: 3,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 0.85,
                            children: List.generate(
                              (state.vibeTransfers.length < 9) ? state.vibeTransfers.length + 1 : 9,
                              (idx) {
                                if (idx < state.vibeTransfers.length) {
                                  final vibe = state.vibeTransfers[idx];
                                  final isEnabled = (vibe['enabled'] as bool?) ?? true;
                                  return GestureDetector(
                                    onTap: () => _showVibeSettingsDialog(
                                      parentContext,
                                      state,
                                      idx,
                                      setDialogState,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: isEnabled
                                              ? const Color(0xFF8B5CF6).withValues(alpha: 0.5)
                                              : Colors.white12,
                                        ),
                                      ),
                                      child: Column(
                                        children: [
                                          Expanded(
                                            child: Stack(
                                              children: [
                                                ClipRRect(
                                                  borderRadius: const BorderRadius.vertical(
                                                    top: Radius.circular(7),
                                                  ),
                                                  child: ColorFiltered(
                                                    colorFilter: isEnabled
                                                        ? const ColorFilter.mode(
                                                            Colors.transparent,
                                                            BlendMode.multiply,
                                                          )
                                                        : const ColorFilter.mode(
                                                            Colors.black54,
                                                            BlendMode.darken,
                                                          ),
                                                    child: Image.memory(
                                                      base64Decode(vibe['image']),
                                                      width: double.infinity,
                                                      fit: BoxFit.cover,
                                                      cacheWidth: 200,
                                                    ),
                                                  ),
                                                ),
                                                // 눈 아이콘 (좌상단) - enable/disable
                                                Positioned(
                                                  top: 4,
                                                  left: 4,
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      setDialogState(
                                                        () => state.vibeTransfers[idx]['enabled'] =
                                                            !isEnabled,
                                                      );
                                                      state.refreshUI();
                                                      state.saveReferencesToLocal();
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(4),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black54,
                                                        borderRadius: BorderRadius.circular(12),
                                                      ),
                                                      child: Icon(
                                                        isEnabled
                                                            ? Icons.visibility
                                                            : Icons.visibility_off,
                                                        color: isEnabled
                                                            ? const Color(0xFF8B5CF6)
                                                            : Colors.white38,
                                                        size: 18,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Positioned(
                                                  top: 4,
                                                  right: 4,
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      setDialogState(
                                                        () => state.vibeTransfers.removeAt(idx),
                                                      );
                                                      state.refreshUI();
                                                      state.saveReferencesToLocal();
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(4),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black54,
                                                        borderRadius: BorderRadius.circular(12),
                                                      ),
                                                      child: const Icon(
                                                        Icons.close,
                                                        color: Colors.white,
                                                        size: 18,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(vertical: 5),
                                            decoration: const BoxDecoration(
                                              borderRadius: BorderRadius.vertical(
                                                bottom: Radius.circular(7),
                                              ),
                                              color: Color(0xFF121212),
                                            ),
                                            child: Center(
                                              child: Text(
                                                "${((vibe['strength'] ?? 0.6) * 100).round()}% · ${((vibe['infoExtracted'] ?? 1.0) * 100).round()}%",
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                } else {
                                  // 추가 버튼
                                  return GestureDetector(
                                    onTap: () async {
                                      final picker = ImagePicker();
                                      final picked = await picker.pickImage(
                                        source: ImageSource.gallery,
                                      );
                                      if (picked != null) {
                                        final bytes = await picked.readAsBytes();
                                        final base64Img = _resizeVibeImage(bytes);
                                        setDialogState(() {
                                          state.vibeTransfers.add({
                                            'image': base64Img,
                                            'strength': 0.6,
                                            'infoExtracted': 1.0,
                                            'enabled': true,
                                          });
                                        });
                                        state.refreshUI();
                                        state.saveReferencesToLocal();
                                      }
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.white24),
                                        color: Colors.white.withValues(alpha: 0.03),
                                      ),
                                      child: const Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.add_photo_alternate_outlined,
                                            color: Colors.white30,
                                            size: 24,
                                          ),
                                          SizedBox(height: 2),
                                          Text(
                                            "추가",
                                            style: TextStyle(color: Colors.white30, fontSize: 9),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
                          // 내보내기/불러오기 버튼
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: state.vibeTransfers.isEmpty
                                      ? null
                                      : () {
                                          _showVibeExportDialog(parentContext, state);
                                        },
                                  icon: const Icon(Icons.upload_file, size: 16),
                                  label: const Text("내보내기", style: TextStyle(fontSize: 12)),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    side: const BorderSide(color: Colors.white24),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    final result = await FilePicker.platform.pickFiles(
                                      type: FileType.any,
                                    );
                                    if (result == null || result.files.isEmpty) {
                                      return;
                                    }
                                    try {
                                      final file = File(result.files.single.path!);
                                      final jsonStr = await file.readAsString();
                                      final added = state.importVibeFromNaiv4(jsonStr);
                                      setDialogState(() {});
                                      if (parentContext.mounted) {
                                        ScaffoldMessenger.of(parentContext).showSnackBar(
                                          SnackBar(
                                            duration: const Duration(milliseconds: 2400),
                                            content: Text(
                                              added > 0
                                                  ? "$added개의 vibe를 불러왔습니다."
                                                  : added == 0
                                                  ? "유효한 vibe 파일이 아닙니다."
                                                  : "파일을 읽는 데 실패했습니다.",
                                            ),
                                          ),
                                        );
                                      }
                                    } catch (e) {
                                      if (parentContext.mounted) {
                                        ScaffoldMessenger.of(parentContext).showSnackBar(
                                          SnackBar(
                                            duration: const Duration(milliseconds: 2400),
                                            content: Text("불러오기 실패"),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  icon: const Icon(Icons.download, size: 16),
                                  label: const Text("불러오기", style: TextStyle(fontSize: 12)),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    side: const BorderSide(color: Colors.white24),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // === Character (Precise Reference) 탭 ===
                    SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GridView.count(
                            crossAxisCount: 3,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 0.78,
                            children: List.generate(
                              (state.preciseRefs.length < 9) ? state.preciseRefs.length + 1 : 9,
                              (idx) {
                                if (idx < state.preciseRefs.length) {
                                  final ref = state.preciseRefs[idx];
                                  final typeLabel =
                                      {
                                        'character': '캐릭터',
                                        'style': '스타일',
                                        'character&style': '둘다',
                                      }[ref['type']] ??
                                      '캐릭터';
                                  final isEnabled = (ref['enabled'] as bool?) ?? true;
                                  return GestureDetector(
                                    onTap: () => _showPreciseSettingsDialog(
                                      parentContext,
                                      state,
                                      idx,
                                      setDialogState,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: isEnabled
                                              ? const Color(0xFF8B5CF6).withValues(alpha: 0.5)
                                              : Colors.white12,
                                        ),
                                      ),
                                      child: Column(
                                        children: [
                                          Expanded(
                                            child: Stack(
                                              children: [
                                                ClipRRect(
                                                  borderRadius: const BorderRadius.vertical(
                                                    top: Radius.circular(7),
                                                  ),
                                                  child: ColorFiltered(
                                                    colorFilter: isEnabled
                                                        ? const ColorFilter.mode(
                                                            Colors.transparent,
                                                            BlendMode.multiply,
                                                          )
                                                        : const ColorFilter.mode(
                                                            Colors.black54,
                                                            BlendMode.darken,
                                                          ),
                                                    child: Image.memory(
                                                      base64Decode(ref['image']),
                                                      width: double.infinity,
                                                      fit: BoxFit.cover,
                                                      cacheWidth: 200,
                                                    ),
                                                  ),
                                                ),
                                                // 눈 아이콘 (좌상단) - enable/disable
                                                Positioned(
                                                  top: 4,
                                                  left: 4,
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      setDialogState(
                                                        () => state.preciseRefs[idx]['enabled'] =
                                                            !isEnabled,
                                                      );
                                                      state.refreshUI();
                                                      state.saveReferencesToLocal();
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(4),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black54,
                                                        borderRadius: BorderRadius.circular(12),
                                                      ),
                                                      child: Icon(
                                                        isEnabled
                                                            ? Icons.visibility
                                                            : Icons.visibility_off,
                                                        color: isEnabled
                                                            ? const Color(0xFF8B5CF6)
                                                            : Colors.white38,
                                                        size: 18,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Positioned(
                                                  top: 4,
                                                  right: 4,
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      setDialogState(
                                                        () => state.preciseRefs.removeAt(idx),
                                                      );
                                                      state.refreshUI();
                                                      state.saveReferencesToLocal();
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(4),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black54,
                                                        borderRadius: BorderRadius.circular(12),
                                                      ),
                                                      child: const Icon(
                                                        Icons.close,
                                                        color: Colors.white,
                                                        size: 18,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 5,
                                              horizontal: 2,
                                            ),
                                            decoration: const BoxDecoration(
                                              borderRadius: BorderRadius.vertical(
                                                bottom: Radius.circular(7),
                                              ),
                                              color: Color(0xFF121212),
                                            ),
                                            child: Center(
                                              child: Text(
                                                "$typeLabel\n${((ref['strength'] ?? 1.0) * 100).round()}% · ${((ref['fidelity'] ?? 0.5) * 100).round()}%",
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  height: 1.3,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                } else {
                                  return GestureDetector(
                                    onTap: () async {
                                      final picker = ImagePicker();
                                      final picked = await picker.pickImage(
                                        source: ImageSource.gallery,
                                      );
                                      if (picked != null) {
                                        final bytes = await picked.readAsBytes();
                                        final base64Img = _resizePrecise(bytes);
                                        setDialogState(() {
                                          state.preciseRefs.add({
                                            'image': base64Img,
                                            'type': 'character',
                                            'strength': 1.0,
                                            'fidelity': 0.5,
                                            'enabled': true,
                                          });
                                        });
                                        state.refreshUI();
                                        state.saveReferencesToLocal();
                                      }
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.white24),
                                        color: Colors.white.withValues(alpha: 0.03),
                                      ),
                                      child: const Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.add_photo_alternate_outlined,
                                            color: Colors.white30,
                                            size: 24,
                                          ),
                                          SizedBox(height: 2),
                                          Text(
                                            "추가",
                                            style: TextStyle(color: Colors.white30, fontSize: 9),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              actions: [
                Row(
                  children: [
                    Expanded(
                      child: Builder(
                        builder: (innerCtx) {
                          final controller = DefaultTabController.of(innerCtx);
                          return AnimatedBuilder(
                            animation: controller,
                            builder: (_, _) {
                              // Character 탭 + Vibe 있을 때: 동시 사용 불가 경고 (2줄)
                              if (controller.index == 1 && state.vibeTransfers.isNotEmpty) {
                                return Text(
                                  "⚠ Vibe와 동시 사용 불가\n(Precise 우선 적용)",
                                  style: TextStyle(
                                    color: Colors.orangeAccent.withValues(alpha: 0.8),
                                    fontSize: 10,
                                  ),
                                );
                              }
                              // Vibe 탭: Anlas 소모 상태 표시
                              if (controller.index == 0 && state.vibeTransfers.isNotEmpty) {
                                final cost = state.calculateVibeAnlas();
                                if (cost > 0) {
                                  return Text(
                                    "Anlas가 $cost 소모됩니다.",
                                    style: TextStyle(
                                      color: Colors.amber.withValues(alpha: 0.8),
                                      fontSize: 10,
                                    ),
                                  );
                                } else {
                                  return Text(
                                    "Anlas가 소모되지 않습니다.",
                                    style: TextStyle(
                                      color: Colors.tealAccent.withValues(alpha: 0.7),
                                      fontSize: 10,
                                    ),
                                  );
                                }
                              }
                              return const Text(
                                "이미지를 탭하여 설정을 변경하세요.",
                                style: TextStyle(color: Colors.white38, fontSize: 10),
                              );
                            },
                          );
                        },
                      ),
                    ),
                    Builder(
                      builder: (innerCtx) {
                        final controller = DefaultTabController.of(innerCtx);
                        return AnimatedBuilder(
                          animation: controller,
                          builder: (_, _) {
                            final tabIdx = controller.index;
                            final hasItems = tabIdx == 0
                                ? state.vibeTransfers.isNotEmpty
                                : state.preciseRefs.isNotEmpty;
                            if (!hasItems) {
                              return const SizedBox.shrink();
                            }
                            return GestureDetector(
                              onTap: () {
                                showDialog(
                                  context: parentContext,
                                  builder: (confirmCtx) => AlertDialog(
                                    backgroundColor: const Color(0xFF1E1E1E),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    title: Text(
                                      tabIdx == 0 ? "Vibe 전체 삭제" : "Character 전체 삭제",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    content: Text(
                                      tabIdx == 0
                                          ? "등록된 모든 Vibe를 삭제하시겠습니까?"
                                          : "등록된 모든 Character Reference를 삭제하시겠습니까?",
                                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(confirmCtx),
                                        child: const Text(
                                          "취소",
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                      ),
                                      ElevatedButton(
                                        onPressed: () {
                                          setDialogState(() {
                                            if (tabIdx == 0) {
                                              state.vibeTransfers.clear();
                                            } else {
                                              state.preciseRefs.clear();
                                            }
                                          });
                                          state.refreshUI();
                                          state.saveReferencesToLocal();
                                          Navigator.pop(confirmCtx);
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.redAccent,
                                        ),
                                        child: const Text(
                                          "삭제",
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12),
                                child: Text(
                                  "전체 삭제",
                                  style: TextStyle(color: Colors.redAccent, fontSize: 12),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text("닫기", style: TextStyle(color: Colors.grey)),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showPreciseSettingsDialog(
    BuildContext context,
    AppState state,
    int idx,
    StateSetter setParentState,
  ) {
    String type = (state.preciseRefs[idx]['type'] as String?) ?? 'character';
    double strength = (state.preciseRefs[idx]['strength'] ?? 1.0).toDouble();
    double fidelity = (state.preciseRefs[idx]['fidelity'] ?? 0.5).toDouble();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            "Reference ${idx + 1} 설정",
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 이미지 변경
                Center(
                  child: GestureDetector(
                    onTap: () async {
                      final picker = ImagePicker();
                      final picked = await picker.pickImage(source: ImageSource.gallery);
                      if (picked != null) {
                        final bytes = await picked.readAsBytes();
                        state.preciseRefs[idx]['image'] = _resizePrecise(bytes);
                        setDialogState(() {});
                        setParentState(() {});
                        state.refreshUI();
                        state.saveReferencesToLocal();
                      }
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        base64Decode(state.preciseRefs[idx]['image']),
                        height: 80,
                        width: 80,
                        fit: BoxFit.cover,
                        cacheWidth: 160,
                      ),
                    ),
                  ),
                ),
                const Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      "탭하여 이미지 변경",
                      style: TextStyle(color: Colors.white30, fontSize: 10),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 참조 타입 선택
                const Text(
                  "참조 타입",
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children:
                      [
                        {'key': 'character', 'label': '캐릭터'},
                        {'key': 'style', 'label': '스타일'},
                        {'key': 'character&style', 'label': '둘다'},
                      ].map((t) {
                        final isActive = type == t['key'];
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: GestureDetector(
                              onTap: () => setDialogState(() => type = t['key']!),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? const Color(0xFF8B5CF6).withValues(alpha: 0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isActive ? const Color(0xFF8B5CF6) : Colors.white24,
                                    width: isActive ? 1.5 : 1,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    t['label']!,
                                    style: TextStyle(
                                      color: isActive ? const Color(0xFF8B5CF6) : Colors.white54,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text(
                      "강도 (Strength)",
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const Spacer(),
                    Text(
                      "${(strength * 100).round()}%",
                      style: const TextStyle(
                        color: Color(0xFF8B5CF6),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: strength,
                  min: 0.0,
                  max: 1.0,
                  divisions: 100,
                  activeColor: const Color(0xFF8B5CF6),
                  onChanged: (v) {
                    setDialogState(() => strength = v);
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text(
                      "충실도 (Fidelity)",
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const Spacer(),
                    Text(
                      "${(fidelity * 100).round()}%",
                      style: const TextStyle(
                        color: Color(0xFF8B5CF6),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: fidelity,
                  min: 0.0,
                  max: 1.0,
                  divisions: 100,
                  activeColor: const Color(0xFF8B5CF6),
                  onChanged: (v) {
                    setDialogState(() => fidelity = v);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("취소", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                state.preciseRefs[idx]['type'] = type;
                state.preciseRefs[idx]['strength'] = strength;
                state.preciseRefs[idx]['fidelity'] = fidelity;
                setParentState(() {});
                state.refreshUI();
                state.saveReferencesToLocal();
                Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6)),
              child: const Text(
                "확인",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showVibeSettingsDialog(
    BuildContext context,
    AppState state,
    int idx,
    StateSetter setParentState,
  ) {
    double strength = (state.vibeTransfers[idx]['strength'] ?? 0.6).toDouble();
    double infoExtracted = (state.vibeTransfers[idx]['infoExtracted'] ?? 1.0).toDouble();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            "Vibe ${idx + 1} 설정",
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 이미지 변경
              GestureDetector(
                onTap: () async {
                  final picker = ImagePicker();
                  final picked = await picker.pickImage(source: ImageSource.gallery);
                  if (picked != null) {
                    final bytes = await picked.readAsBytes();
                    state.vibeTransfers[idx]['image'] = _resizeVibeImage(bytes);
                    // 이미지 변경 시 인코딩 캐시 무효화
                    state.vibeTransfers[idx].remove('_encoded');
                    state.vibeTransfers[idx].remove('_encodedInfoExt');
                    state.vibeTransfers[idx].remove('_encodedModel');
                    setDialogState(() {});
                    setParentState(() {});
                    state.refreshUI();
                    state.saveReferencesToLocal();
                  }
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    base64Decode(state.vibeTransfers[idx]['image']),
                    height: 80,
                    width: 80,
                    fit: BoxFit.cover,
                    cacheWidth: 160,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text("탭하여 이미지 변경", style: TextStyle(color: Colors.white30, fontSize: 10)),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text(
                    "강도 (Strength)",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const Spacer(),
                  Text(
                    "${(strength * 100).round()}%",
                    style: const TextStyle(
                      color: Color(0xFF8B5CF6),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              Slider(
                value: strength,
                min: 0.01,
                max: 1.0,
                divisions: 99,
                activeColor: const Color(0xFF8B5CF6),
                onChanged: (v) {
                  setDialogState(() => strength = v);
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    "정보 추출 (Info Extracted)",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const Spacer(),
                  Text(
                    "${(infoExtracted * 100).round()}%",
                    style: const TextStyle(
                      color: Color(0xFF8B5CF6),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              Slider(
                value: infoExtracted,
                min: 0.01,
                max: 1.0,
                divisions: 99,
                activeColor: const Color(0xFF8B5CF6),
                onChanged: (v) {
                  setDialogState(() => infoExtracted = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("취소", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                // 정보추출 값이 바뀌면 인코딩 캐시 무효화 (재인코딩 필요)
                final oldInfoExt = (state.vibeTransfers[idx]['infoExtracted'] as double?) ?? 1.0;
                if (oldInfoExt != infoExtracted) {
                  state.vibeTransfers[idx].remove('_encoded');
                  state.vibeTransfers[idx].remove('_encodedInfoExt');
                  state.vibeTransfers[idx].remove('_encodedModel');
                }
                state.vibeTransfers[idx]['strength'] = strength;
                state.vibeTransfers[idx]['infoExtracted'] = infoExtracted;
                setParentState(() {});
                state.refreshUI();
                state.saveReferencesToLocal();
                Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6)),
              child: const Text(
                "확인",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
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

            Timer? tagDebounce;

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
              int lastParen = max(
                beforeCursor.lastIndexOf(')'),
                max(
                  beforeCursor.lastIndexOf('('),
                  max(beforeCursor.lastIndexOf('{'), beforeCursor.lastIndexOf('|')),
                ),
              );
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

              // 150ms 디바운스 (빠른 응답 + 부하 방지)
              tagDebounce?.cancel();
              final capturedWord = currentWord; // 현재 시점 캡처
              tagDebounce = Timer(const Duration(milliseconds: 100), () {
                // 디바운스 후 입력이 바뀌었으면 무시
                final nowText = controller.text;
                final nowCursor = controller.selection.baseOffset;
                if (nowCursor < 0 || nowText != controller.text) {
                  return;
                }
                final nowBefore = nowText.substring(0, nowCursor.clamp(0, nowText.length));
                final nowLastDel = max(
                  nowBefore.lastIndexOf(','),
                  max(
                    nowBefore.lastIndexOf(':'),
                    max(
                      nowBefore.lastIndexOf('\n'),
                      max(
                        nowBefore.lastIndexOf(')'),
                        max(
                          nowBefore.lastIndexOf('('),
                          max(nowBefore.lastIndexOf('{'), nowBefore.lastIndexOf('|')),
                        ),
                      ),
                    ),
                  ),
                );
                final nowWord = (nowLastDel == -1 ? nowBefore : nowBefore.substring(nowLastDel + 1))
                    .trimLeft();
                if (nowWord != capturedWord || nowWord.isEmpty) {
                  setModalState(() => suggestions = []);
                  return;
                }
                List<String> matches = smartMatchTags(state.danbooruTags, currentWord);
                setModalState(() {
                  suggestions = matches;
                });
              });
            }

            void insertTag(String tag) {
              String text = controller.text;
              int cursor = controller.selection.baseOffset;
              if (cursor < 0) {
                cursor = text.length;
              }

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
          hint: "프롬프트를 입력하세요...",
          icon: Icons.add_circle_outline,
          title: "긍정적 프롬프트",
        );
      case 'prefix':
        return _buildPromptCardBody(
          context,
          state,
          color: const Color(0xFF29B6F6),
          controller: state.prefixController,
          hint: "프롬프트를 입력하세요...",
          icon: Icons.arrow_right_alt,
          title: "선행 프롬프트",
        );
      case 'suffix':
        return _buildPromptCardBody(
          context,
          state,
          color: const Color(0xFFFFA000),
          controller: state.suffixController,
          hint: "프롬프트를 입력하세요...",
          icon: Icons.keyboard_double_arrow_right,
          title: "후행 프롬프트",
        );
      case 'negative':
        return _buildPromptCardBody(
          context,
          state,
          color: const Color(0xFFFF5252),
          controller: state.negativeController,
          hint: "프롬프트를 입력하세요...",
          icon: Icons.remove_circle_outline,
          title: "부정적 프롬프트",
        );
      case 'removeChips':
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            border: Border(
              left: BorderSide(color: const Color(0xFF8B5CF6).withValues(alpha: 0.3)),
              right: BorderSide(color: const Color(0xFF8B5CF6).withValues(alpha: 0.3)),
              bottom: BorderSide(color: const Color(0xFF8B5CF6).withValues(alpha: 0.3)),
            ),
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
          border: Border(
            left: BorderSide(color: color.withValues(alpha: 0.3)),
            right: BorderSide(color: color.withValues(alpha: 0.3)),
            bottom: BorderSide(color: color.withValues(alpha: 0.3)),
          ),
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
                  const Spacer(),
                  // 배치 카운터
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        if (state.batchCount == 1) {
                          state.batchCount = 2;
                        } else if (state.batchCount == 2) {
                          state.batchCount = 3;
                        } else if (state.batchCount == 3) {
                          state.batchCount = 4;
                        } else if (state.batchCount == 4) {
                          state.batchCount = 0;
                        } else {
                          state.batchCount = 1;
                        }
                      });
                    },
                    onLongPress: () {
                      showDialog(
                        context: context,
                        builder: (ctx) {
                          final ctrl = TextEditingController(
                            text: state.batchCount <= 0 ? '' : state.batchCount.toString(),
                          );
                          return AlertDialog(
                            backgroundColor: const Color(0xFF1E1E1E),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            title: const Text(
                              "배치 생성 횟수",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            content: TextField(
                              controller: ctrl,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: "1~999",
                                hintStyle: const TextStyle(color: Colors.white30),
                                filled: true,
                                fillColor: const Color(0xFF121212),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text("취소", style: TextStyle(color: Colors.grey)),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  final val = int.tryParse(ctrl.text) ?? 1;
                                  setState(() => state.batchCount = val.clamp(1, 999));
                                  Navigator.pop(ctx);
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF8B5CF6),
                                ),
                                child: const Text("확인", style: TextStyle(color: Colors.white)),
                              ),
                            ],
                          );
                        },
                      );
                    },
                    child: Container(
                      width: 44,
                      height: 40,
                      decoration: BoxDecoration(
                        color: state.batchCount > 1 || state.batchCount == 0
                            ? const Color(0xFF8B5CF6).withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: state.batchCount > 1 || state.batchCount == 0
                              ? const Color(0xFF8B5CF6)
                              : Colors.white24,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          state.batchCount == 0 ? "∞" : "${state.batchCount}x",
                          style: TextStyle(
                            color: state.batchCount > 1 || state.batchCount == 0
                                ? const Color(0xFF8B5CF6)
                                : Colors.white54,
                            fontWeight: FontWeight.bold,
                            fontSize: state.batchCount == 0
                                ? 18
                                : state.batchCount >= 100
                                ? 10
                                : state.batchCount >= 10
                                ? 12
                                : 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: (state.isLoading || state.isInpaintLoading || state.isUpscaleLoading)
                        ? () {
                            if (state.isBatchMode) {
                              state.cancelBatch();
                            }
                          }
                        : () async {
                            // API 연결 확인 먼저
                            if (!state.isApiConnected) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(milliseconds: 2400),
                                  content: Text("설정 탭에서 API 키를 먼저 연결해주세요."),
                                ),
                              );
                              return;
                            }
                            if (state.checkIfAnlasConsumed()) {
                              final batchInfo = state.batchCount > 1
                                  ? "\n${state.batchCount}회 연속 생성합니다."
                                  : state.batchCount == 0
                                  ? "\n무한 생성합니다. 수동으로 중지하세요."
                                  : "";
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
                                  content: Text(
                                    "Anlas가 소모됩니다. 괜찮습니까?$batchInfo",
                                    style: const TextStyle(color: Colors.white70, fontSize: 15),
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
                            state.handleBatchGenerate(
                              context,
                              widget.onScrollToHistoryEnd ?? () {},
                            );
                          },
                    style: ElevatedButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      fixedSize: const Size(160, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      backgroundColor:
                          (state.isLoading || state.isInpaintLoading || state.isUpscaleLoading)
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
                          ? (state.isBatchMode ? "생성중(${state.batchRemaining})..." : "생성 중...")
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
              const SizedBox(height: 4),
              Row(
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
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
                      minimumSize: const Size(120, 36),
                    ),
                  ),
                  const Spacer(),
                  // Vibe Transfer
                  GestureDetector(
                    onTap: () => _showVibeTransferDialog(context, state),
                    child: Icon(
                      Icons.palette_outlined,
                      color: (state.vibeTransfers.isNotEmpty || state.preciseRefs.isNotEmpty)
                          ? const Color(0xFF8B5CF6)
                          : Colors.grey,
                      size: 22,
                    ),
                  ),
                  const Spacer(),
                  // 톱니바퀴 (상세 환경) — 컴팩트
                  GestureDetector(
                    onTap: () {
                      state.isGelbooruExpanded = !state.isGelbooruExpanded;
                      state.refreshUI();
                    },
                    child: Icon(
                      Icons.settings,
                      color: state.isGelbooruExpanded ? const Color(0xFF8B5CF6) : Colors.grey,
                      size: 22,
                    ),
                  ),
                  const Spacer(flex: 2),
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
                      const SizedBox(width: 4),
                      const Text("랜덤 잠금", style: TextStyle(color: Colors.white, fontSize: 13)),
                      const SizedBox(width: 12),
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
                      const SizedBox(width: 4),
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
          // 접기/펴기 + 드래그 재배치 가능한 프롬프트 섹션
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
              if (newIndex > oldIndex) {
                newIndex--;
              }
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
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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

// Vibe Transfer용 이미지 리사이즈 + base64 인코딩 (백그라운드 isolate)
String _resizeVibeImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return base64Encode(bytes);
  }
  // 긴 변 기준 최대 1024px로 축소 (Vibe Transfer는 큰 해상도 불필요)
  img.Image resized = decoded;
  if (decoded.width > 1024 || decoded.height > 1024) {
    if (decoded.width >= decoded.height) {
      resized = img.copyResize(decoded, width: 1024);
    } else {
      resized = img.copyResize(decoded, height: 1024);
    }
  }
  final jpg = img.encodeJpg(resized, quality: 90);
  return base64Encode(jpg);
}

// Precise Reference용 이미지 리사이즈 + 패딩
// NovelAI는 반드시 1024x1536 / 1472x1472 / 1536x1024 중 하나여야 함
String _resizePrecise(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return base64Encode(bytes);
  }

  // 3가지 타겟 크기
  const targets = [
    [1024, 1536], // 세로
    [1472, 1472], // 정사각
    [1536, 1024], // 가로
  ];

  // 원본 비율과 가장 가까운 타겟 선택
  final ratio = decoded.width / decoded.height;
  int bestW = 1024, bestH = 1536;
  double minDiff = double.infinity;
  for (final t in targets) {
    final tRatio = t[0] / t[1];
    final diff = (ratio - tRatio).abs();
    if (diff < minDiff) {
      minDiff = diff;
      bestW = t[0];
      bestH = t[1];
    }
  }

  // 비율 유지하며 축소
  final scaleX = bestW / decoded.width;
  final scaleY = bestH / decoded.height;
  final scale = scaleX < scaleY ? scaleX : scaleY;
  final newW = (decoded.width * scale).round();
  final newH = (decoded.height * scale).round();
  final resized = img.copyResize(decoded, width: newW, height: newH);

  // 검은 배경에 중앙 배치 (패딩) - 픽셀 직접 복사로 버전 호환성 확보
  final padded = img.Image(width: bestW, height: bestH, numChannels: 3);
  for (final p in padded) {
    p.setRgb(0, 0, 0);
  }
  final xOff = (bestW - newW) ~/ 2;
  final yOff = (bestH - newH) ~/ 2;
  for (int y = 0; y < newH; y++) {
    for (int x = 0; x < newW; x++) {
      final pixel = resized.getPixel(x, y);
      padded.setPixelRgb(x + xOff, y + yOff, pixel.r, pixel.g, pixel.b);
    }
  }

  final jpg = img.encodeJpg(padded, quality: 90);
  return base64Encode(jpg);
}
