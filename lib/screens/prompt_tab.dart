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
import 'package:archive/archive.dart';
import '../models/app_state.dart';
import '../models/nai_character.dart';
import '../models/model_caps.dart';
import 'prompt_edit_dialog.dart';

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

  // 자동완성 후보를 만든 시점의 커서 위치.
  //  커서를 다른 곳으로 옮기면 그 후보는 무효다(엉뚱한 위치에 삽입되는 것 방지).
  int _suggestionAnchor = -1;
  String _lastKnownText = '';
  VoidCallback? _cursorWatcher;

  @override
  void initState() {
    super.initState();
    focusNode = FocusNode();
    _lastKnownText = widget.controller.text;
    // 텍스트는 그대로인데 커서만 움직이면 후보를 지운다
    _cursorWatcher = () {
      if (!mounted || _suggestionAnchor < 0) {
        return;
      }
      if (widget.controller.text != _lastKnownText) {
        _lastKnownText = widget.controller.text; // 타이핑은 onChanged가 처리
        return;
      }
      if (widget.controller.selection.baseOffset != _suggestionAnchor) {
        setState(() {
          suggestions = [];
          _suggestionAnchor = -1;
        });
      }
    };
    widget.controller.addListener(_cursorWatcher!);
    focusNode.addListener(() {
      if (!focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted) {
            setState(() {
              suggestions.clear();
              _suggestionAnchor = -1;
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    // 컨트롤러는 AppState 소유라 dispose하지 않지만, 우리가 붙인 리스너는 떼야 한다
    if (_cursorWatcher != null) {
      widget.controller.removeListener(_cursorWatcher!);
    }
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
    // '(' ')'는 구분자에서 제외 — 태그 이름 자체에 괄호가 들어가기 때문
    // (예: "zero (test)"). NovelAI 강조 문법은 {}/[]라 영향 없음.
    int lastParen = max(beforeCursor.lastIndexOf('{'), beforeCursor.lastIndexOf('|'));
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

    List<String> matches = smartMatchTags(widget.state.searchTags, currentWord);

    setState(() {
      suggestions = matches;
      _suggestionAnchor = widget.controller.selection.baseOffset;
    });
  }

  void insertTag(String tag) {
    PromptUtils.applyTagToController(widget.controller, tag);
    _lastKnownText = widget.controller.text;

    setState(() {
      suggestions.clear();
      _suggestionAnchor = -1;
    });
    widget.state.saveAllSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 44, maxHeight: 132),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.deepPurpleAccent),
            borderRadius: BorderRadius.circular(4),
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: focusNode,
            minLines: 1,
            maxLines: 4, // 태그가 길어지면 최대 4줄까지 자동 줄바꿈 (그 이상은 내부 스크롤)
            onChanged: (_) {
              _lastKnownText = widget.controller.text;
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
                              PromptUtils.displayTag(suggestions[index]),
                              style: TextStyle(
                                color: widget.state.isE621Tag(suggestions[index])
                                    ? const Color(0xFF3B9EFF)
                                    : Colors.white,
                                fontSize: 14,
                              ),
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

class _PromptTabState extends State<PromptTab> with AutomaticKeepAliveClientMixin {
  // 탭을 오갈 때 화면을 버리지 않고 살려둔다.
  //  다시 만들면 수백 개 위젯을 새로 그려야 해 전환이 굼떠진다.
  @override
  bool get wantKeepAlive => true;

  // [다음 프롬프트] 누름 팝 효과용 (누를 때마다 증가 → 애니메이션 재생)
  int _nextPromptFx = 0;

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
                // 키보드(viewInsets) + 시스템 네비게이션 바(viewPadding) 둘 다 피해야
                // 목록 아래쪽이 홈/뒤로 버튼에 묻히지 않는다
                bottom:
                    MediaQuery.of(modalContext).viewInsets.bottom +
                    MediaQuery.of(modalContext).viewPadding.bottom,
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
                        return ReorderableListView.builder(
                          itemCount: filtered.length,
                          onReorderItem: (oldIndex, newIndex) {
                            _reorderPreset(consumerState, selectedCategory, oldIndex, newIndex);
                          },
                          itemBuilder: (context, index) {
                            final originalIndex = filtered[index].key;
                            final preset = filtered[index].value;
                            return Container(
                              key: ValueKey(preset),
                              decoration: const BoxDecoration(
                                border: Border(bottom: BorderSide(color: Colors.white12, width: 1)),
                              ),
                              child: ListTile(
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
                                                // 36×36으로만 보이므로 작게 디코드
                                                child: Image.memory(
                                                  base64Decode(preset.previewImage!),
                                                  fit: BoxFit.cover,
                                                  cacheWidth: 108,
                                                  gaplessPlayback: true,
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
                                                                  color: color.withValues(
                                                                    alpha: 0.5,
                                                                  ),
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
                                                  child: GestureDetector(
                                                    onTap: () => _showRenamePresetDialog(
                                                      ctx,
                                                      consumerState,
                                                      preset,
                                                      setDialogState,
                                                    ),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        Flexible(
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
                                                        const SizedBox(width: 6),
                                                        const Icon(
                                                          Icons.edit,
                                                          size: 15,
                                                          color: Colors.white38,
                                                        ),
                                                      ],
                                                    ),
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
                                                            final bytes = await picked
                                                                .readAsBytes();
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
                                                                // 100×100으로만 보이므로 작게 디코드
                                                                child: Image.memory(
                                                                  base64Decode(
                                                                    preset.previewImage!,
                                                                  ),
                                                                  width: 100,
                                                                  height: 100,
                                                                  fit: BoxFit.cover,
                                                                  cacheWidth: 300,
                                                                  gaplessPlayback: true,
                                                                ),
                                                              )
                                                            : Container(
                                                                width: 100,
                                                                height: 100,
                                                                decoration: BoxDecoration(
                                                                  color: Colors.white.withValues(
                                                                    alpha: 0.05,
                                                                  ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(10),
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
                                      child: const Icon(
                                        Icons.copy,
                                        color: Colors.white54,
                                        size: 16,
                                      ),
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

  // 프리셋 저장 다이얼로그 (공용 showPresetSaveDialog 위임)
  void _showPresetSaveDialog(BuildContext parentContext, AppState state) {
    showPresetSaveDialog(
      parentContext,
      state,
      positive: state.positiveController.text,
      negative: state.negativeController.text,
      prefix: state.prefixController.text,
      suffix: state.suffixController.text,
      characters: state.characters,
      settingsProvider: () => state.getSettingsSnapshot(),
      allowPrefixSuffix: true,
      allowSettings: true,
    );
  }

  // 프리셋 순서 변경 (카테고리 필터 내 드래그 → 전체 presets 리스트에 반영)
  void _reorderPreset(AppState state, String category, int oldIndex, int newIndex) {
    // onReorderItem 콜백은 newIndex를 이미 보정해서 넘겨줌 (수동 보정 불필요)
    // 현재 카테고리에 속한 프리셋들의 전체 인덱스(표시 순서)
    final filteredFullIdx = state.presets
        .asMap()
        .entries
        .where((e) => _getPresetCategory(e.value) == category)
        .map((e) => e.key)
        .toList();
    if (oldIndex < 0 || oldIndex >= filteredFullIdx.length) {
      return;
    }
    final fromFull = filteredFullIdx[oldIndex];
    final moved = state.presets.removeAt(fromFull);

    // 제거 후 같은 카테고리의 전체 인덱스 재계산
    final afterFullIdx = state.presets
        .asMap()
        .entries
        .where((e) => _getPresetCategory(e.value) == category)
        .map((e) => e.key)
        .toList();

    int insertFull;
    if (newIndex >= afterFullIdx.length) {
      insertFull = afterFullIdx.isEmpty ? state.presets.length : afterFullIdx.last + 1;
    } else {
      insertFull = afterFullIdx[newIndex];
    }
    state.presets.insert(insertFull, moved);
    state.saveAllSettings();
    state.refreshUI();
  }

  // 프리셋 이름 변경 다이얼로그 (상세창에서 이름 탭 시)
  void _showRenamePresetDialog(
    BuildContext context,
    AppState state,
    NaiPreset preset,
    StateSetter setDialogState,
  ) {
    final TextEditingController renameCtrl = TextEditingController(text: preset.name);
    void commit(BuildContext rctx) {
      final n = renameCtrl.text.trim();
      if (n.isNotEmpty) {
        preset.name = n;
        state.saveAllSettings();
        state.refreshUI();
        setDialogState(() {});
      }
      Navigator.pop(rctx);
    }

    showDialog(
      context: context,
      builder: (rctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "이름 변경",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: renameCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: "새 프리셋 이름",
            hintStyle: const TextStyle(color: Colors.white30),
            filled: true,
            fillColor: const Color(0xFF121212),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (_) => commit(rctx),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(rctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => commit(rctx),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
            child: const Text(
              "저장",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
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
  // Precise Reference 내보내기 (ZIP: metadata.json + 이미지들)
  void _exportPrecise(BuildContext parentContext, AppState state) async {
    try {
      final archive = Archive();
      final List<Map<String, dynamic>> metadata = [];

      for (int i = 0; i < state.preciseRefs.length; i++) {
        final ref = state.preciseRefs[i];
        final imgBytes = base64Decode(ref['image']);
        final filename = "precise_${i + 1}.png";
        archive.addFile(ArchiveFile(filename, imgBytes.length, imgBytes));
        metadata.add({
          "filename": filename,
          "description": (ref['type'] as String?) ?? "character",
          "fidelity": (ref['fidelity'] as double?) ?? 0.5,
          "strength": (ref['strength'] as double?) ?? 1.0,
          "information_extracted": 1,
          "enabled": (ref['enabled'] as bool?) ?? true,
        });
      }

      final metaBytes = utf8.encode(jsonEncode(metadata));
      archive.addFile(ArchiveFile("metadata.json", metaBytes.length, metaBytes));

      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) {
        if (parentContext.mounted) {
          ScaffoldMessenger.of(parentContext).showSnackBar(
            SnackBar(duration: const Duration(milliseconds: 2400), content: Text("내보내기 실패")),
          );
        }
        return;
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/DNaiApp_Precise_${_fileTimestamp()}.zip');
      await file.writeAsBytes(zipData);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      if (parentContext.mounted) {
        ScaffoldMessenger.of(parentContext).showSnackBar(
          SnackBar(duration: const Duration(milliseconds: 2400), content: Text("내보내기 실패")),
        );
      }
    }
  }

  // Precise Reference 불러오기 (ZIP 해제 → metadata.json + 이미지)
  void _importPrecise(
    BuildContext parentContext,
    AppState state,
    StateSetter setDialogState,
  ) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.isEmpty) {
      return;
    }
    try {
      final file = File(result.files.single.path!);
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // metadata.json 찾기
      ArchiveFile? metaFile;
      final Map<String, Uint8List> images = {};
      for (final f in archive) {
        if (f.name.endsWith('metadata.json')) {
          metaFile = f;
        } else if (f.name.toLowerCase().endsWith('.png') ||
            f.name.toLowerCase().endsWith('.jpg') ||
            f.name.toLowerCase().endsWith('.jpeg')) {
          // 경로 제거하고 파일명만
          final baseName = f.name.split('/').last;
          images[baseName] = f.content as Uint8List;
        }
      }

      if (metaFile == null) {
        if (parentContext.mounted) {
          ScaffoldMessenger.of(parentContext).showSnackBar(
            SnackBar(
              duration: const Duration(milliseconds: 2400),
              content: Text("metadata.json이 없는 파일입니다."),
            ),
          );
        }
        return;
      }

      final metaList = jsonDecode(utf8.decode(metaFile.content as Uint8List)) as List;
      final List<Map<String, dynamic>> items = [];
      for (final m in metaList) {
        final filename = (m['filename'] as String?)?.split('/').last;
        if (filename == null || !images.containsKey(filename)) {
          continue;
        }
        // 이미지를 Precise 규격으로 리사이즈
        final resized = _resizePrecise(images[filename]!);
        items.add({
          'image': resized,
          'type': (m['description'] as String?) ?? 'character',
          'strength': (m['strength'] as num?)?.toDouble() ?? 1.0,
          'fidelity': (m['fidelity'] as num?)?.toDouble() ?? 0.5,
          'enabled': (m['enabled'] as bool?) ?? true,
        });
      }

      final added = state.addPreciseFromImport(items);
      setDialogState(() {});
      if (parentContext.mounted) {
        ScaffoldMessenger.of(parentContext).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text(added > 0 ? "$added개의 Reference를 불러왔습니다." : "불러올 이미지가 없습니다."),
          ),
        );
      }
    } catch (e) {
      if (parentContext.mounted) {
        ScaffoldMessenger.of(parentContext).showSnackBar(
          SnackBar(duration: const Duration(milliseconds: 2400), content: Text("불러오기 실패")),
        );
      }
    }
  }

  // Vibe 내보내기 선택 다이얼로그
  void _showVibeExportDialog(BuildContext parentContext, AppState state) {
    final selected = <int>{};

    Future<void> doExport(List<int> indices) async {
      try {
        final dir = await getTemporaryDirectory();
        final ts = _fileTimestamp();
        if (indices.length == 1) {
          final jsonStr = state.exportVibeToNaiv4(state.vibeTransfers[indices[0]]);
          final file = File('${dir.path}/DNaiApp_Vibe_$ts.naiv4vibe');
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
          final file = File('${dir.path}/DNaiApp_Vibe_$ts.naiv4vibebundle');
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

  // initialTab: 0=Vibe, 1=Character Ref (버튼에 따라 먼저 보일 탭을 지정)
  void _showVibeTransferDialog(BuildContext parentContext, AppState state, {int initialTab = 0}) {
    showDialog(
      context: parentContext,
      builder: (ctx) => DefaultTabController(
        length: 2,
        initialIndex: initialTab,
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
                    _buildVibeTab("Character Ref", const Color(0xFF00BFA5)),
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
                                                    child: SizedBox(
                                                      width: double.infinity,
                                                      height: double.infinity,
                                                      child: Image.memory(
                                                        base64Decode(vibe['image']),
                                                        fit: BoxFit.cover,
                                                        cacheWidth: 200,
                                                      ),
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
                                                    child: SizedBox(
                                                      width: double.infinity,
                                                      height: double.infinity,
                                                      child: Image.memory(
                                                        base64Decode(ref['image']),
                                                        fit: BoxFit.cover,
                                                        cacheWidth: 200,
                                                      ),
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
                          const SizedBox(height: 12),
                          // 내보내기/불러오기 버튼
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: state.preciseRefs.isEmpty
                                      ? null
                                      : () {
                                          _exportPrecise(parentContext, state);
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
                                  onPressed: () {
                                    _importPrecise(parentContext, state, setDialogState);
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
                              // Character 탭
                              if (controller.index == 1) {
                                // Vibe 있으면 동시 사용 불가 경고 우선
                                if (state.vibeTransfers.isNotEmpty &&
                                    state.preciseRefs
                                        .where((r) => (r['enabled'] as bool?) ?? true)
                                        .isNotEmpty) {
                                  return Text(
                                    "⚠ Vibe와 동시 사용 불가\n(Precise 우선 적용)",
                                    style: TextStyle(
                                      color: Colors.orangeAccent.withValues(alpha: 0.8),
                                      fontSize: 10,
                                    ),
                                  );
                                }
                                // Precise Anlas 소모 표시
                                if (state.preciseRefs.isNotEmpty) {
                                  final cost = state.calculatePreciseAnlas();
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            // 가중치 규칙만: 이름 옆 ON/OFF (접혔을 때도 보임)
            if (sectionId == 'weightRules')
              SizedBox(
                height: 24,
                child: FittedBox(
                  fit: BoxFit.fitHeight,
                  child: Switch(
                    value: state.weightRulesEnabled,
                    activeThumbColor: color,
                    onChanged: (v) {
                      state.weightRulesEnabled = v;
                      state.saveAllSettings();
                      state.refreshUI();
                    },
                  ),
                ),
              ),
            if (sectionId == 'weightRules') const SizedBox(width: 4),
            // 드래그 핸들 (접혔을 때만 표시, 잡고 드래그로 순서 변경)
            if (isCollapsed)
              ReorderableDragStartListener(
                index: index,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(Icons.drag_handle, color: color.withValues(alpha: 0.8), size: 18),
                ),
              )
            else
              // 펼쳤을 때도 핸들 자리(아이콘18 + 패딩10 = 28)를 가로·세로 모두 비워둬서
              // ① 옆 ON/OFF 위치가 흔들리지 않고 ② 접힘/펼침 헤더 높이가 똑같아진다
              const SizedBox(width: 28, height: 28),
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
            spacing: 6,
            runSpacing: 6,
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
              // 옷을 벗김/찢어짐/잡아당김 등 '의상에 일어난 일'
              _buildRemoveChip("의상 상태", Icons.dry_cleaning, state.removeClothingEvents, (v) {
                state.removeClothingEvents = v;
                state.saveAllSettings();
                state.refreshUI();
              }),
              // 구체적인 태그가 있으면 그것이 함의하는 상위 태그를 제거 (토큰 절약)
              _buildRemoveChip("중복 정리", Icons.filter_alt_off, state.removeImpliedTags, (v) {
                state.removeImpliedTags = v;
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
              color: const Color(0xFFEC4899),
              controller: state.conditionalRuleController,
              hint: "# 주석을 적을 수 있습니다\n(e|q):*skirt=*skirt, pants\n(cat*):cat*^dog*",
              icon: Icons.bolt,
              title: "조건부 트리거 작성 (줄바꿈 구분)",
            ),
            const SizedBox(height: 12),
            // 작동 시점 선택 버튼
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      state.conditionalTriggerMode = "random";
                      state.saveAllSettings();
                      state.refreshUI();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: state.conditionalTriggerMode == "random"
                            ? const Color(0xFFEC4899).withValues(alpha: 0.2)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: state.conditionalTriggerMode == "random"
                              ? const Color(0xFFEC4899)
                              : Colors.white24,
                          width: state.conditionalTriggerMode == "random" ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.casino_outlined,
                            size: 16,
                            color: state.conditionalTriggerMode == "random"
                                ? const Color(0xFFEC4899)
                                : Colors.white54,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "랜덤 프롬프트 생성 시",
                            style: TextStyle(
                              color: state.conditionalTriggerMode == "random"
                                  ? const Color(0xFFEC4899)
                                  : Colors.white54,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      state.conditionalTriggerMode = "generate";
                      state.saveAllSettings();
                      state.refreshUI();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: state.conditionalTriggerMode == "generate"
                            ? const Color(0xFFEC4899).withValues(alpha: 0.2)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: state.conditionalTriggerMode == "generate"
                              ? const Color(0xFFEC4899)
                              : Colors.white24,
                          width: state.conditionalTriggerMode == "generate" ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.image_outlined,
                            size: 16,
                            color: state.conditionalTriggerMode == "generate"
                                ? const Color(0xFFEC4899)
                                : Colors.white54,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            "이미지 생성 시",
                            style: TextStyle(
                              color: state.conditionalTriggerMode == "generate"
                                  ? const Color(0xFFEC4899)
                                  : Colors.white54,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEC4899).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFEC4899).withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 탭하면 가이드를 접었다 펼 수 있다 (상태는 저장됨)
                  GestureDetector(
                    onTap: () {
                      state.conditionalGuideCollapsed = !state.conditionalGuideCollapsed;
                      state.saveAllSettings();
                      state.refreshUI();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        const Text(
                          "💡 문법 가이드",
                          style: TextStyle(
                            color: Color(0xFFEC4899),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          state.conditionalGuideCollapsed ? Icons.expand_more : Icons.expand_less,
                          color: const Color(0xFFEC4899),
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                  if (!state.conditionalGuideCollapsed) ...const [
                    SizedBox(height: 8),
                    Text(
                      "(조건):A=B → 조건 만족시 A를 B로 덮어쓰기 교체",
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      "(!조건):A=B → 조건을 만족하지 않을시 A를 B로 교체",
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
                    SizedBox(height: 8),
                    Text(
                      "*는 위치에 따라 의미가 다릅니다.\n  skirt* → skirt로 시작하는 프롬프트\n  *skirt → skirt로 끝나는 프롬프트\n  *skirt* → skirt를 포함하는 프롬프트",
                      style: TextStyle(color: Colors.cyanAccent, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      case 'weightRules':
        // 다른 프롬프트 창과 완전히 동일한 카드/입력 경험
        return _buildPromptCardBody(
          context,
          state,
          color: const Color(0xFF84CC16),
          controller: state.weightRulesController,
          hint: "sleeping=0.5, smile=1.3, #무시할내용",
          icon: Icons.tune,
          title: "가중치 규칙 (콤마/줄바꿈 구분)",
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
      onTap: () => showPromptEditDialog(context, state, title, icon, color, controller),
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
                child: controller.text.isEmpty
                    ? Text(
                        hint,
                        style: const TextStyle(color: Colors.white30, height: 1.5, fontSize: 14),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      )
                    : (controller is SyntaxHighlightController
                          ? RichText(
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              text: SyntaxHighlightController.buildSyntaxSpan(
                                controller.text,
                                const TextStyle(color: Colors.white, height: 1.5, fontSize: 14),
                              ),
                            )
                          : (controller is WeightRulesController
                                ? RichText(
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    text: WeightRulesController.buildRulesSpan(
                                      controller.text,
                                      const TextStyle(
                                        color: Colors.white,
                                        height: 1.5,
                                        fontSize: 14,
                                      ),
                                      state.weightRulesEnabled,
                                    ),
                                  )
                                : (WeightHighlightController.highlightEnabled
                                      ? RichText(
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                          text: WeightHighlightController.buildWeightSpan(
                                            controller.text,
                                            const TextStyle(
                                              color: Colors.white,
                                              height: 1.5,
                                              fontSize: 14,
                                            ),
                                          ),
                                        )
                                      : Text(
                                          controller.text,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            height: 1.5,
                                            fontSize: 14,
                                          ),
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                        )))),
              ),
              const SizedBox(width: 8),
              Icon(Icons.edit, color: color, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  // V5 사용 한도 게이지.
  //  V5는 시간당 회복되는 사용 한도가 있어 남은 양을 보여준다.
  //  토큰 게이지 바로 아래에 같은 모양으로 두되, 색을 달리해 구분한다.
  //  ⚠️ 조회 API가 아직 공개되지 않아 지금은 "확인중"만 표시한다.
  //     AppState.v5LimitPercent 에 값이 들어오면 자동으로 %와 바가 채워진다.
  Widget _buildV5LimitGauge(AppState state) {
    // V5가 아닌 모델에서는 표시하지 않는다
    if (state.selectedModel != NaiModels.v5Full) {
      return const SizedBox.shrink();
    }
    final pct = state.v5LimitPercent;
    final known = pct != null;
    final ratio = known ? (pct / 100).clamp(0.0, 1.0) : 0.0;
    // 남을수록 파랑, 부족할수록 붉게 (토큰 게이지와 색 계열을 다르게 해 구분)
    final color = !known
        ? Colors.white24
        : pct <= 10
        ? const Color(0xFFFF1744)
        : pct <= 30
        ? Colors.orangeAccent
        : const Color(0xFF29B6F6);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(Icons.hourglass_bottom, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            known ? "V5 limit ${pct.toStringAsFixed(0)}%" : "V5 limit 확인중",
            style: TextStyle(color: color, fontSize: 11),
          ),
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
  }

  // 제거 옵션 칩. 4개가 한 줄에 들어가도록 여백·글자를 줄였다.
  Widget _buildRemoveChip(String label, IconData icon, bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
        decoration: BoxDecoration(
          color: value ? Colors.deepPurpleAccent.withValues(alpha: 0.25) : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: value ? Colors.deepPurpleAccent : Colors.white24,
            width: value ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: value ? Colors.deepPurpleAccent : Colors.white54),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                color: value ? Colors.white : Colors.white54,
                fontSize: 11,
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

  // 생성 시작 (기존 UI와 동일한 절차: API 확인 → Anlas 경고 → 배치 실행)
  Future<void> _startGenerate(BuildContext context, AppState state) async {
    // API 연결 확인 먼저
    if (!state.isApiConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(milliseconds: 2400),
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
      final bool? confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amber),
              SizedBox(width: 8),
              Text(
                "포인트 소모 안내",
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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
              child: const Text("취소", style: TextStyle(color: Colors.grey, fontSize: 15)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6)),
              child: const Text(
                "생성하기",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
    // 배치/반복 실행 (1회여도 이 경로를 타야 반복 설정이 반영된다)
    state.handleBatchGenerate(context, widget.onScrollToHistoryEnd ?? () {});
  }

  // 배치/반복 설정 다이얼로그 (기존 UI·2번째 UI 공용)
  void _showBatchSettingsDialog(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(
          text: state.batchCount <= 0 ? '' : state.batchCount.toString(),
        );
        // 현재 배치가 무한(0)인지 다이얼로그 내부에서 추적
        bool isInfinite = state.batchCount == 0;
        // 같은 프롬프트 반복 횟수 입력용
        final repeatCtrl = TextEditingController(text: state.repeatSamePromptCount.toString());
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text(
                "배치 생성 횟수",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 무한일 땐 입력 비활성 + 안내문 표시, 터치하면 해제되어 입력 가능
                  GestureDetector(
                    onTap: isInfinite
                        ? () {
                            setDialogState(() {
                              isInfinite = false;
                              ctrl.clear();
                            });
                          }
                        : null,
                    child: AbsorbPointer(
                      absorbing: isInfinite, // 무한이면 TextField 대신 위 onTap이 먹도록
                      child: TextField(
                        controller: ctrl,
                        enabled: !isInfinite,
                        keyboardType: TextInputType.number,
                        style: TextStyle(color: isInfinite ? Colors.white54 : Colors.white),
                        decoration: InputDecoration(
                          hintText: isInfinite ? "무한 생성 중 (터치 시 해제)" : "1~999",
                          hintStyle: const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: const Color(0xFF121212),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 자동 생성 중 이미지마다 다음 프롬프트 자동 전환
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          "프롬프트 자동 전환",
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                      Transform.scale(
                        scale: 0.85,
                        child: Switch(
                          value: state.autoNextPromptInBatch,
                          activeThumbColor: const Color(0xFF8B5CF6),
                          onChanged: (v) {
                            setDialogState(() {
                              state.autoNextPromptInBatch = v;
                            });
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                        ),
                      ),
                    ],
                  ),
                  // 같은 프롬프트로 N번 반복 후 다음으로 (자동 전환 ON일 때만 유효)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          "같은 프롬프트 반복",
                          style: TextStyle(
                            color: state.autoNextPromptInBatch ? Colors.white : Colors.white38,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      // 작은 숫자 입력창
                      SizedBox(
                        width: 44,
                        height: 32,
                        child: TextField(
                          controller: repeatCtrl,
                          enabled: state.autoNextPromptInBatch && state.repeatSamePromptEnabled,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                            filled: true,
                            fillColor: const Color(0xFF121212),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onChanged: (v) {
                            final n = int.tryParse(v);
                            if (n != null) {
                              state.repeatSamePromptCount = n.clamp(1, 99);
                              // 타이핑마다 저장하면 버벅이므로 멈춘 뒤 한 번만
                              state.saveAllSettingsDebounced();
                            }
                          },
                        ),
                      ),
                      Transform.scale(
                        scale: 0.85,
                        child: Switch(
                          value: state.repeatSamePromptEnabled,
                          activeThumbColor: const Color(0xFF8B5CF6),
                          onChanged: state.autoNextPromptInBatch
                              ? (v) {
                                  setDialogState(() {
                                    state.repeatSamePromptEnabled = v;
                                  });
                                  state.saveAllSettings();
                                  state.refreshUI();
                                }
                              : null, // 자동 전환 OFF면 비활성
                        ),
                      ),
                    ],
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
                    if (isInfinite) {
                      // 무한 생성
                      setState(() => state.batchCount = 0);
                    } else {
                      final val = int.tryParse(ctrl.text) ?? 1;
                      setState(() => state.batchCount = val.clamp(1, 999));
                    }
                    Navigator.pop(ctx);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6)),
                  child: const Text("확인", style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════
  // 2번째 UI (설정: "프롬프트탭 다른 UI로 변경")
  //  - 상단: 실제로 전송될 최종 프롬프트 합본 + 토큰
  //  - 중단: 기능을 성격별로 묶은 버튼 (탭하면 바텀시트)
  //  - 하단: 생성 바
  // 기존 UI 코드는 그대로 두고 이 경로만 따로 그린다.
  // ══════════════════════════════════════════════════════════════
  Widget _buildAltLayout(
    BuildContext context,
    AppState state,
    bool canChangePrompt,
    Color promptActionColor,
  ) {
    final preview = state.buildPreviewPrompt();
    // 활성 캐릭터 프롬프트까지 합산 (NAI는 base+character 합쳐 512 제한)
    final tokens = estimateTotalTokens(state);
    final capTokens = modelCapsFor(state.selectedModel).maxPromptTokens;
    final maxTokens = capTokens > 0 ? capTokens : 512;
    final ratio = (tokens / maxTokens).clamp(0.0, 1.0);
    // 한도를 넘으면 바로 알 수 있게 진한 빨강
    final tokenColor = tokens > maxTokens
        // 빨강은 '초과'에만 쓴다 (보이면 바로 넘친 걸 알 수 있게)
        ? const Color(0xFFFF1744)
        : ratio > 0.88
        ? const Color(0xFFFFA000) // 주황
        : (ratio > 0.68 ? const Color(0xFFFFD54F) : const Color(0xFF00BFA5)); // 노랑

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 윗줄: Anlas · 랜덤 잠금/자동 저장 · 새로고침 · 다음 ──
          // 아랫줄과 열을 맞추기 위해 [정사각 버튼][간격][넓은 버튼] 구조를 공유한다
          Row(
            children: [
              const Icon(Icons.toll, color: Color(0xFFFFA000), size: 14),
              const SizedBox(width: 4),
              Text(
                "${state.currentAnlas}",
                style: const TextStyle(
                  color: Color(0xFFFFA000),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 10),
              // 랜덤 잠금 / 자동 저장 (새로고침과 같은 크기)
              _altToggleIcon(
                icon: state.isRandomLocked ? Icons.lock : Icons.lock_open,
                tooltip: "랜덤 잠금",
                active: state.isRandomLocked,
                color: const Color(0xFFFFA000),
                onTap: () {
                  state.isRandomLocked = !state.isRandomLocked;
                  state.saveAllSettings();
                  state.refreshUI();
                },
              ),
              const SizedBox(width: 6),
              _altToggleIcon(
                icon: state.isAutoSave ? Icons.save : Icons.save_outlined,
                tooltip: "자동 저장",
                active: state.isAutoSave,
                color: const Color(0xFF00BFA5),
                onTap: () {
                  state.isAutoSave = !state.isAutoSave;
                  state.saveAllSettings();
                  state.refreshUI();
                },
              ),
              const Spacer(flex: 1),
              // 현재 프롬프트 다시 불러오기 (아랫줄 배수 버튼과 같은 자리·크기)
              _altIconButton(
                icon: Icons.sync,
                color: promptActionColor,
                tooltip: "현재 프롬프트 다시 불러오기",
                onTap: canChangePrompt ? () => state.reloadCurrentPrompt() : null,
              ),
              const SizedBox(width: 10),
              // 다음 프롬프트 (아랫줄 생성 버튼과 같은 너비)
              Expanded(
                flex: 5,
                child: _altWideButton(
                  label: "다음 (P : ${state.gelbooruPrompts.length - state.currentPromptIndex})",
                  color: promptActionColor,
                  filled: false,
                  onTap: canChangePrompt ? () => state.handleNextPrompt() : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ── 아랫줄: 배수 · 생성 (윗줄과 열 맞춤) ──
          Row(
            children: [
              // 윗줄의 [Anlas+토글] 영역과 같은 비율을 차지해 열을 맞춘다
              const Spacer(flex: 4),
              // 배수 (탭=순환, 꾹=직접 입력)
              _altIconButton(
                text: state.batchCount == 0 ? "∞" : "${state.batchCount}x",
                color: const Color(0xFF8B5CF6),
                tooltip: "생성 횟수 (길게 눌러 직접 입력)",
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
                onLongPress: () => _showBatchSettingsDialog(context, state),
              ),
              const SizedBox(width: 10),
              // 생성 시작
              Expanded(
                flex: 5,
                child: _altWideButton(
                  label: state.isBatchMode
                      ? "중지 (${state.batchRemaining})"
                      : (state.isLoading ? "생성 중" : "생성"),
                  icon: state.isBatchMode ? Icons.stop_circle : Icons.auto_awesome,
                  color: const Color(0xFF8B5CF6),
                  filled: true,
                  onTap: (state.isLoading && !state.isBatchMode)
                      ? null
                      : (state.isBatchMode
                            ? () => state.cancelBatch()
                            : () => _startGenerate(context, state)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ── 최종 프롬프트 합본 (실제 전송 내용) ──
          // ⚠️ 프롬프트 탭은 SingleChildScrollView 안이라 높이가 무한이다.
          //    여기서 Expanded를 쓰면 남은 공간을 못 구해 레이아웃이 멈춘다(ANR).
          //    반드시 고정 높이를 준다.
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.28,
            child: GestureDetector(
              // 탭하면 긍정 프롬프트를 바로 편집 (가장 자주 고치는 곳)
              onTap: () => showPromptEditDialog(
                context,
                state,
                "긍정적 프롬프트",
                Icons.add_circle_outline,
                const Color(0xFF00BFA5),
                state.positiveController,
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF00BFA5).withValues(alpha: 0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.add_circle_outline, color: Color(0xFF00BFA5), size: 16),
                        const SizedBox(width: 6),
                        const Text(
                          "긍정적 프롬프트",
                          style: TextStyle(
                            color: Color(0xFF00BFA5),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const Spacer(),
                        const Icon(Icons.edit, color: Colors.white38, size: 15),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: preview.trim().isEmpty
                            ? const Text(
                                "프롬프트를 입력하세요 (탭하여 편집)",
                                style: TextStyle(color: Colors.white30, fontSize: 13),
                              )
                            // 설정에서 '가중치 색상 표시'가 꺼져 있으면 평문으로
                            : (WeightHighlightController.highlightEnabled
                                  ? RichText(
                                      text: WeightHighlightController.buildWeightSpan(
                                        preview,
                                        const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          height: 1.5,
                                        ),
                                      ),
                                    )
                                  : Text(
                                      preview,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        height: 1.5,
                                      ),
                                    )),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // ── 토큰 게이지 ──
          Row(
            children: [
              Icon(Icons.token, size: 14, color: tokenColor),
              const SizedBox(width: 6),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 5,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation(tokenColor),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                "~${buildTokenLabel(state, maxTokens)}",
                style: TextStyle(color: tokenColor, fontSize: 11),
              ),
            ],
          ),
          _buildV5LimitGauge(state),
          const SizedBox(height: 6),

          // ── 기능 묶음 버튼 ──
          // 윗줄: 프롬프트 관리 / 검색 도구
          Row(
            children: [
              Expanded(
                child: _altGroupButton(
                  icon: Icons.article_outlined,
                  label: "프롬프트 관리",
                  color: const Color(0xFF8B5CF6),
                  badge: _sectionBadge(state, _altManageSectionIds),
                  onTap: () => _openPromptManageSheet(context, state),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _altGroupButton(
                  icon: Icons.search,
                  label: "검색 도구",
                  color: const Color(0xFFFFA000),
                  // 검색 중이면 진행 상황을, 아니면 남은 프롬프트 수를 표시
                  busy: state.isGelbooruLoading,
                  badge: state.isGelbooruLoading
                      ? (state.gelbooruSearchStage.isNotEmpty ? state.gelbooruSearchStage : "검색 중")
                      : (state.gelbooruPrompts.isEmpty
                            ? "검색 필요"
                            : "남음 ${state.gelbooruPrompts.length - state.currentPromptIndex}"),
                  onTap: () => _openSearchToolsSheet(context, state),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 아랫줄: 프롬프트 도구(규칙) / NAI 도구
          Row(
            children: [
              Expanded(
                child: _altGroupButton(
                  icon: Icons.tune,
                  label: "프롬프트 도구",
                  color: const Color(0xFFEC4899),
                  badge: _sectionBadge(state, _altRuleSectionIds),
                  onTap: () => _openPromptRuleSheet(context, state),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _altGroupButton(
                  icon: Icons.auto_awesome,
                  label: "NAI 도구",
                  color: const Color(0xFF29B6F6),
                  badge: _naiToolsBadge(state),
                  onTap: () => _openNaiToolsSheet(context, state),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── 메인에 고정한 창들 (시트의 📌로 지정) ──
          // 고정된 게 없으면 아무것도 그리지 않아 화면이 깔끔하게 유지된다
          for (final id in _altToolSectionIds)
            if (state.pinnedPromptSections.contains(id))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_altPinRow(state, id), _buildSectionContent(context, state, id)],
                ),
              ),
        ],
      ),
    );
  }

  // 레이팅 칩 (내용만큼만 차지)
  Widget _altRatingChip(
    String letter,
    String label,
    bool value,
    Color color,
    ValueChanged<bool> onChanged,
  ) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: value ? color.withValues(alpha: 0.18) : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: value ? color : Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.check_circle : Icons.circle_outlined,
              color: value ? color : Colors.white24,
              size: 15,
            ),
            const SizedBox(width: 6),
            Text(
              "$letter · $label",
              style: TextStyle(
                color: value ? color : Colors.white38,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 검색 현황 숫자 (검색됨 / 남음)
  Widget _altSearchStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  // 정사각 버튼 (새로고침 / 배수) — 두 줄의 열을 맞추기 위해 같은 크기 사용
  // 아이콘 또는 텍스트 중 하나를 표시한다.
  Widget _altIconButton({
    IconData? icon,
    String? text,
    required Color color,
    required String tooltip,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final enabled = onTap != null;
    final line = enabled ? color : Colors.white24;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xFF2A2A35),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          // 눌리는 느낌(리플 + 진동)을 주기 위해 Material+InkWell 사용
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  onTap();
                },
          onLongPress: onLongPress == null
              ? null
              : () {
                  HapticFeedback.mediumImpact();
                  onLongPress();
                },
          borderRadius: BorderRadius.circular(10),
          splashColor: color.withValues(alpha: 0.3),
          highlightColor: color.withValues(alpha: 0.15),
          child: Container(
            // D열: 새로고침 / 배수 공통 크기
            width: 44,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: enabled ? color.withValues(alpha: 0.5) : Colors.white12),
            ),
            child: text != null
                ? Text(
                    text,
                    style: TextStyle(color: line, fontWeight: FontWeight.bold, fontSize: 14),
                  )
                : Icon(icon, color: line, size: 20),
          ),
        ),
      ),
    );
  }

  // 넓은 버튼 (다음 / 생성) — 두 줄 모두 같은 너비
  Widget _altWideButton({
    required String label,
    required Color color,
    required bool filled,
    required VoidCallback? onTap,
    IconData? icon,
  }) {
    final enabled = onTap != null;
    final fg = filled ? Colors.white : (enabled ? color : Colors.white24);
    return SizedBox(
      height: 42,
      child: Material(
        color: filled ? (enabled ? color : const Color(0xFF2A2A35)) : const Color(0xFF2A2A35),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  onTap();
                },
          borderRadius: BorderRadius.circular(10),
          splashColor: Colors.white.withValues(alpha: 0.25),
          highlightColor: Colors.white.withValues(alpha: 0.12),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: enabled ? color.withValues(alpha: filled ? 0.0 : 0.5) : Colors.white12,
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, color: fg, size: 17), const SizedBox(width: 5)],
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ON/OFF 토글 아이콘 (랜덤 잠금 / 자동 저장) — 정사각 버튼과 같은 크기
  Widget _altToggleIcon({
    required IconData icon,
    required String tooltip,
    required bool active,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: "$tooltip ${active ? 'ON' : 'OFF'}",
      child: Material(
        color: active ? color.withValues(alpha: 0.18) : const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          splashColor: color.withValues(alpha: 0.3),
          highlightColor: color.withValues(alpha: 0.15),
          child: Container(
            // B/C열: 두 줄의 아이콘 버튼 공통 크기
            width: 44,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: active ? color : Colors.white12),
            ),
            child: Icon(icon, color: active ? color : Colors.white24, size: 18),
          ),
        ),
      ),
    );
  }

  // 묶음 버튼 (2번째 UI)
  // badge: 시트를 열지 않아도 현황을 알 수 있게 아래에 작게 표시
  Widget _altGroupButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    String? badge,
    bool busy = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // 배지 유무와 관계없이 4개 버튼 높이가 항상 같도록 고정
        height: 74,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: busy ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: busy ? 0.9 : 0.4)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  )
                : Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
            // 배지 자리는 항상 확보 (없으면 빈 칸으로 둬서 높이 유지)
            const SizedBox(height: 2),
            SizedBox(
              height: 12,
              child: badge == null
                  ? null
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        badge,
                        maxLines: 1,
                        style: TextStyle(color: color.withValues(alpha: 0.75), fontSize: 9),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // 섹션 배지: 내용이 채워진 창 개수 (메인에 고정한 건 이미 보이므로 제외)
  String? _sectionBadge(AppState state, List<String> ids) {
    int filled = 0;
    int pinned = 0;
    for (final id in ids) {
      if (state.pinnedPromptSections.contains(id)) {
        pinned++;
        continue;
      }
      if (_sectionHasContent(state, id)) {
        filled++;
      }
    }
    if (filled == 0) {
      return pinned > 0 ? "고정 $pinned" : null;
    }
    return pinned > 0 ? "$filled개 · 고정$pinned" : "$filled개 설정됨";
  }

  // 해당 섹션에 실제 내용이 있는지
  bool _sectionHasContent(AppState state, String id) {
    switch (id) {
      case 'prefix':
        return state.prefixController.text.trim().isNotEmpty;
      case 'suffix':
        return state.suffixController.text.trim().isNotEmpty;
      case 'negative':
        return state.negativeController.text.trim().isNotEmpty;
      case 'customRemove':
        return state.customRemoveController.text.trim().isNotEmpty;
      case 'removeChips':
        // 제거 옵션 중 하나라도 켜져 있으면 설정된 것으로 본다
        return state.removeCharacteristics ||
            state.removeClothes ||
            state.removeClothingEvents ||
            state.removeImpliedTags ||
            state.removeColors;
      case 'conditional':
        return state.conditionalRuleController.text.trim().isNotEmpty;
      case 'weightRules':
        return state.weightRulesEnabled && state.weightRulesController.text.trim().isNotEmpty;
      default:
        return false;
    }
  }

  // NAI 도구 배지: 활성 캐릭터 / 참조 개수
  String? _naiToolsBadge(AppState state) {
    final chars = state.characters.where((c) => c.isActive).length;
    final refs = state.vibeTransfers.length + state.preciseRefs.length;
    final parts = <String>[];
    if (chars > 0) {
      parts.add("캐릭터 $chars");
    }
    if (refs > 0) {
      parts.add("참조 $refs");
    }
    return parts.isEmpty ? null : parts.join(" · ");
  }

  // 공용 시트 껍데기 (2번째 UI 묶음들)
  void _openAltSheet(BuildContext context, String title, IconData icon, Color color, Widget body) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF171717),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 14,
          right: 14,
          top: 10,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).viewPadding.bottom + 14,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Flexible(child: SingleChildScrollView(child: body)),
            ],
          ),
        ),
      ),
    );
  }

  // 2번째 UI 섹션 분류 (긍정은 상단 카드에서 직접 편집)
  //  - 관리: 프롬프트 본문을 이루는 창들
  //  - 도구: 프롬프트를 가공하는 규칙들
  static const List<String> _altManageSectionIds = [
    'prefix',
    'suffix',
    'negative',
    'removeChips',
    'customRemove',
  ];
  static const List<String> _altRuleSectionIds = ['conditional', 'weightRules'];

  // 메인 고정 표시용 전체 목록 (관리 + 도구)
  static const List<String> _altToolSectionIds = [..._altManageSectionIds, ..._altRuleSectionIds];

  // ① 프롬프트 관리 (선행/후행/부정/태그 제거)
  void _openPromptManageSheet(BuildContext context, AppState state) {
    _openSectionSheet(
      context,
      state,
      "프롬프트 관리",
      Icons.article_outlined,
      const Color(0xFF8B5CF6),
      _altManageSectionIds,
    );
  }

  // ② 프롬프트 도구 (조건부 트리거 / 가중치 규칙)
  void _openPromptRuleSheet(BuildContext context, AppState state) {
    _openSectionSheet(
      context,
      state,
      "프롬프트 도구",
      Icons.tune,
      const Color(0xFFEC4899),
      _altRuleSectionIds,
    );
  }

  // 섹션 목록을 보여주는 공용 시트
  void _openSectionSheet(
    BuildContext context,
    AppState state,
    String title,
    IconData icon,
    Color color,
    List<String> ids,
  ) {
    _openAltSheet(
      context,
      title,
      icon,
      color,
      AnimatedBuilder(
        animation: state,
        builder: (ctx, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                "📌 을 누르면 메인 화면에 고정돼요",
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
            for (final id in ids)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _altPinRow(state, id),
                    // 접기 상태는 기존 UI와 공유 (collapsedSections)
                    if (!state.collapsedSections.contains(id))
                      // 기존 섹션 위젯을 그대로 재사용 (동작·색상 100% 동일)
                      _buildSectionContent(ctx, state, id),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // 섹션 헤더 + 고정 토글
  // _buildPromptCardBody는 "위에 헤더가 붙는다"는 전제로 위쪽 테두리/모서리가 없다.
  // 그래서 여기서 헤더 배경·테두리를 그려 카드가 잘려 보이지 않게 맞춘다.
  Widget _altPinRow(AppState state, String id) {
    final meta = _sectionMeta[id]!;
    final color = Color(meta['color'] as int);
    final pinned = state.pinnedPromptSections.contains(id);
    final collapsed = state.collapsedSections.contains(id);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        // 접히면 아래쪽 카드가 없으므로 사방을 둥글게 마감
        borderRadius: collapsed
            ? BorderRadius.circular(12)
            : const BorderRadius.vertical(top: Radius.circular(12)),
        border: collapsed
            ? Border.all(color: color.withValues(alpha: 0.3))
            : Border(
                top: BorderSide(color: color.withValues(alpha: 0.3)),
                left: BorderSide(color: color.withValues(alpha: 0.3)),
                right: BorderSide(color: color.withValues(alpha: 0.3)),
              ),
      ),
      child: Row(
        children: [
          // 제목 영역을 탭하면 접기/펼치기
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (state.collapsedSections.contains(id)) {
                  state.collapsedSections.remove(id);
                } else {
                  state.collapsedSections.add(id);
                }
                state.saveAllSettings();
                state.refreshUI();
              },
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Icon(collapsed ? Icons.chevron_right : Icons.expand_more, color: color, size: 18),
                  const SizedBox(width: 2),
                  Icon(meta['icon'] as IconData, color: color, size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      meta['title'] as String,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: () => state.togglePinnedSection(id),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(
                pinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: pinned ? color : Colors.white24,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ② NAI 도구: 현재 설정 요약 + 캐릭터 / Vibe·Precise / 상세 환경 / 프리셋
  void _openNaiToolsSheet(BuildContext context, AppState state) {
    _openAltSheet(
      context,
      "NAI 도구",
      Icons.auto_awesome,
      const Color(0xFF29B6F6),
      AnimatedBuilder(
        animation: state,
        // 모델 정보는 시트가 열려 있는 동안 바뀔 수 있으므로 builder 안에서 계산
        builder: (ctx, _) {
          final caps = modelCapsFor(state.selectedModel);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── 현재 생성 설정 요약 (상세 환경을 열지 않아도 확인 가능) ──
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.memory, color: Colors.white54, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            caps.isPlaceholder ? caps.displayName : state.selectedModel,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _altInfoChip(Icons.aspect_ratio, state.selectedResolution),
                        _altInfoChip(Icons.stairs, "스텝 ${state.stepsController.text}"),
                        _altInfoChip(Icons.tune, "CFG ${state.cfgScaleController.text}"),
                        _altInfoChip(Icons.grain, state.selectedSampler.replaceAll('k_', '')),
                        if (state.isSeedLocked)
                          _altInfoChip(Icons.lock, "시드 고정", color: const Color(0xFFFFA000)),
                        if (state.isVariancePlus && caps.supportsVarietyPlus)
                          _altInfoChip(Icons.shuffle, "VAR+", color: Colors.deepPurpleAccent),
                      ],
                    ),
                  ],
                ),
              ),
              _altToolTile(
                icon: Icons.people_alt,
                label: "캐릭터",
                // 활성 캐릭터 이름을 미리 보여줘 시트를 열지 않아도 확인 가능
                sub: state.characters.where((c) => c.isActive).isEmpty
                    ? "활성 캐릭터 없음"
                    : state.characters
                          .where((c) => c.isActive)
                          .map((c) => c.name.isEmpty ? "이름없음" : c.name)
                          .join(", "),
                color: Colors.deepPurpleAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _openAltCharSheet(context, state);
                },
              ),
              _altToolTile(
                icon: Icons.palette,
                label: "Vibe",
                sub: caps.supportsVibe
                    ? "${state.vibeTransfers.length}개 등록"
                    : "${caps.displayName}에선 사용 불가",
                color: const Color(0xFF8B5CF6),
                enabled: caps.supportsVibe,
                onTap: () {
                  Navigator.pop(ctx);
                  _showVibeTransferDialog(context, state, initialTab: 0);
                },
              ),
              _altToolTile(
                icon: Icons.face_retouching_natural,
                label: "Character Ref",
                sub: caps.supportsPrecise
                    ? "${state.preciseRefs.length}개 등록"
                    : "${caps.displayName}에선 사용 불가",
                color: const Color(0xFF00BFA5),
                enabled: caps.supportsPrecise,
                onTap: () {
                  Navigator.pop(ctx);
                  _showVibeTransferDialog(context, state, initialTab: 1);
                },
              ),
              _altToolTile(
                icon: Icons.bookmarks,
                label: "프리셋 관리",
                sub: "저장된 설정 불러오기",
                color: Colors.deepPurpleAccent,
                onTap: () {
                  Navigator.pop(ctx);
                  _showPresetBottomSheet(context, state);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  // 설정 요약용 작은 칩
  Widget _altInfoChip(IconData icon, String text, {Color? color}) {
    final c = color ?? Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: c, size: 12),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(color: c, fontSize: 11)),
        ],
      ),
    );
  }

  // ③ 검색 도구: 레이팅 / 검색 / 생성 옵션
  void _openSearchToolsSheet(BuildContext context, AppState state) {
    _openAltSheet(
      context,
      "검색 도구",
      Icons.search,
      const Color(0xFFFFA000),
      StatefulBuilder(
        builder: (ctx, setSheet) => AnimatedBuilder(
          animation: state,
          builder: (ctx2, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 검색 태그 입력 (기존 UI와 동일한 자동완성 입력창)
              const Text(
                "검색 태그",
                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
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
              const SizedBox(height: 14),
              const Text(
                "레이팅",
                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              // 레이팅은 필요한 만큼만 차지하도록 칩으로 (Expanded로 화면을 나눠 먹지 않게)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _altRatingChip("E", "노출", state.ratingE, const Color(0xFFFF5252), (v) {
                    state.ratingE = v;
                    state.saveAllSettings();
                    state.refreshUI();
                  }),
                  _altRatingChip("Q", "선정", state.ratingQ, const Color(0xFFFFA000), (v) {
                    state.ratingQ = v;
                    state.saveAllSettings();
                    state.refreshUI();
                  }),
                  _altRatingChip("S", "민감", state.ratingS, const Color(0xFF29B6F6), (v) {
                    state.ratingS = v;
                    state.saveAllSettings();
                    state.refreshUI();
                  }),
                  _altRatingChip("G", "전체", state.ratingG, const Color(0xFF00BFA5), (v) {
                    state.ratingG = v;
                    state.saveAllSettings();
                    state.refreshUI();
                  }),
                ],
              ),
              const SizedBox(height: 14),
              // 검색 현황을 카드로 키워서 한눈에 (숫자가 주인공)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _altSearchStat(
                        "검색됨",
                        "${state.gelbooruPrompts.length}",
                        const Color(0xFFFFA000),
                      ),
                    ),
                    Container(width: 1, height: 28, color: Colors.white12),
                    Expanded(
                      child: _altSearchStat(
                        "남음",
                        "${state.gelbooruPrompts.length - state.currentPromptIndex}",
                        Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // 검색 버튼은 가로 전체 (제일 자주 누르는 것)
              SizedBox(
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: state.isGelbooruLoading
                      ? null
                      : () => state.handleGelbooruSearch(context),
                  icon: state.isGelbooruLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white70),
                          ),
                        )
                      : const Icon(Icons.search, size: 18),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      state.isGelbooruLoading
                          ? (state.gelbooruSearchStage.isNotEmpty
                                ? state.gelbooruSearchStage
                                : "검색 중")
                          : "검색",
                      maxLines: 1,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFA000),
                    foregroundColor: Colors.black87,
                    disabledBackgroundColor: const Color(0xFF2A2A35),
                    disabledForegroundColor: Colors.white54,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 2번째 UI 전용 캐릭터 목록/편집 시트
  // (서랍은 손잡이 위젯 소유라 여기선 별도로 제공. 편집창은 공용 함수 재사용)
  void _openAltCharSheet(BuildContext context, AppState state) {
    _openAltSheet(
      context,
      "캐릭터",
      Icons.people_alt,
      Colors.deepPurpleAccent,
      AnimatedBuilder(
        animation: state,
        builder: (ctx, _) {
          if (state.characters.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                "캐릭터가 없어요.\n캐릭터 탭에서 추가하세요.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < state.characters.length; i++) _altCharCard(ctx, state, i),
            ],
          );
        },
      ),
    );
  }

  // 캐릭터 1명 카드 (ON/OFF + 긍정/부정 편집)
  Widget _altCharCard(BuildContext ctx, AppState state, int index) {
    final char = state.characters[index];
    final isOn = char.isActive;
    final title = char.name.isEmpty ? "캐릭터 #${index + 1}" : char.name;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isOn ? Colors.deepPurpleAccent : Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // 설정 '캐릭터 재선택으로 ON/OFF'를 끄면 여기서도 토글되지 않는다
              IconButton(
                icon: Icon(
                  isOn ? Icons.visibility : Icons.visibility_off,
                  // 색은 항상 상태를 나타낸다 (설정과 무관)
                  color: isOn ? Colors.deepPurpleAccent : Colors.grey,
                  size: 20,
                ),
                onPressed: state.charRetapToggle
                    ? () {
                        state.characters[index].isActive = !isOn;
                        state.saveAllSettings();
                        state.refreshUI();
                      }
                    : null,
              ),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isOn ? Colors.white : Colors.white54,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: _altCharPromptButton(
                    ctx,
                    state,
                    index,
                    positive: true,
                    text: char.positive,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _altCharPromptButton(
                    ctx,
                    state,
                    index,
                    positive: false,
                    text: char.negative,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 캐릭터 긍정/부정 편집 버튼 (탭 → 공용 프롬프트 입력창)
  Widget _altCharPromptButton(
    BuildContext ctx,
    AppState state,
    int index, {
    required bool positive,
    required String text,
  }) {
    final color = positive ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    final label = positive ? "긍정" : "부정";
    return GestureDetector(
      onTap: () {
        // 컨트롤러를 즉석 생성해 원본에 실시간 반영 (서랍과 동일한 방식)
        final ctrl = TextEditingController(
          text: positive ? state.characters[index].positive : state.characters[index].negative,
        );
        ctrl.addListener(() {
          if (index < state.characters.length) {
            if (positive) {
              state.characters[index].positive = ctrl.text;
            } else {
              state.characters[index].negative = ctrl.text;
            }
          }
        });
        showPromptEditDialog(
          ctx,
          state,
          "$label 프롬프트",
          positive ? Icons.add_circle_outline : Icons.remove_circle_outline,
          color,
          ctrl,
          onClosed: () {
            // 리스너가 메모리는 갱신하지만 저장은 하지 않으므로 닫을 때 한 번 저장
            state.saveAllSettings();
            state.refreshUI();
            // 여기서 만든 임시 컨트롤러이므로 직접 정리
            ctrl.dispose();
          },
        );
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              text.isEmpty ? "탭하여 입력..." : text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: text.isEmpty ? Colors.white30 : Colors.white, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  // 묶음 시트 안의 항목 타일
  Widget _altToolTile({
    required IconData icon,
    required String label,
    required String sub,
    required Color color,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis, // 캐릭터가 많아도 넘치지 않게
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // 예전 UI (기본) — UI 개편 전의 원래 레이아웃
  //  기본으로 표시되는 레이아웃. 설정에서 '새로운 UI'를 켜면 개편본으로 바뀐다.
  // ══════════════════════════════════════════════════════════
  // 이전 버전 데이터에 새로 추가된 섹션이 없으면 자동 보정.
  //  이게 없으면 섹션을 추가해도 화면에 나타나지 않는다.
  //  build와 _buildClassicLayout 양쪽에서 같은 코드를 돌리고 있어 하나로 합쳤다.
  // 생성 버튼을 눌렀을 때의 처리.
  //  build 안에 78줄이 들어 있어 화면을 그릴 때마다 다시 만들어졌다.
  Future<void> _onGeneratePressed(BuildContext context, AppState state) async {
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amber),
              SizedBox(width: 8),
              Text(
                "포인트 소모 안내",
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
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
              child: const Text("취소", style: TextStyle(color: Colors.grey, fontSize: 15)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8B5CF6)),
              child: const Text(
                "생성하기",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
    state.handleBatchGenerate(context, widget.onScrollToHistoryEnd ?? () {});
  }

  // 윗줄 도구 버튼
  //  build 안에 118줄이 들어 있어 화면을 그릴 때마다 다시 만들어졌다.
  Widget _buildToolRowTop(
    BuildContext context,
    AppState state,
    bool canChangePrompt,
    Color promptActionColor,
  ) {
    return Row(
      children: [
        // 왼쪽 그룹: 화면이 좁으면 줄어들고, 오른쪽 두 열은 항상 붙어있게
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 아랫줄 그룹과 같은 폭으로 묶어 오른쪽 두 열을 정렬
            // A열: 아랫줄 프리셋 버튼과 같은 폭 (열 정렬)
            SizedBox(
              width: 78,
              child: Row(
                children: [
                  // Anlas를 살짝 오른쪽으로 (뒤 간격을 줄여 총폭은 동일)
                  const SizedBox(width: 8),
                  const Icon(Icons.toll, color: Color(0xFFFFA000), size: 16),
                  const SizedBox(width: 4),
                  // Anlas 자릿수가 커져도 그룹 폭을 넘지 않게
                  Flexible(
                    child: Text(
                      state.isApiConnected ? "${state.currentAnlas}" : "0",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFFFA000),
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            _altToggleIcon(
              icon: state.isRandomLocked ? Icons.lock : Icons.lock_open,
              tooltip: "랜덤 잠금",
              active: state.isRandomLocked,
              color: const Color(0xFFFFA000),
              onTap: () {
                state.isRandomLocked = !state.isRandomLocked;
                state.saveAllSettings();
                state.refreshUI();
              },
            ),
            const SizedBox(width: 8),
            _altToggleIcon(
              icon: state.isAutoSave ? Icons.save : Icons.save_outlined,
              tooltip: "자동 저장",
              active: state.isAutoSave,
              color: const Color(0xFF00BFA5),
              onTap: () {
                state.isAutoSave = !state.isAutoSave;
                state.saveAllSettings();
                state.refreshUI();
              },
            ),
          ],
        ),
        const SizedBox(width: 8),
        // 현재 프롬프트 다시 불러오기 (아랫줄 배수 버튼과 같은 열)
        _altIconButton(
          icon: Icons.sync,
          color: promptActionColor,
          tooltip: "현재 프롬프트 다시 불러오기",
          onTap: canChangePrompt ? () => state.reloadCurrentPrompt() : null,
        ),
        const SizedBox(width: 8),
        // 다음 프롬프트 (남는 공간을 차지 → 화면이 좁아도 안 넘침)
        // E열: 남는 공간을 전부 차지 (왼쪽이 모두 고정이라 겹칠 일 없음)
        //  ※ 왼쪽 고정 합계는 238dp. 화면이 270dp 미만이면 오버플로우가 나므로
        //    버튼을 더 키울 때는 이 합계를 넘기지 않도록 주의.
        Flexible(
          fit: FlexFit.tight,
          child: TweenAnimationBuilder<double>(
            // 누를 때마다 key가 바뀌어 '눌렸다 튕겨나오는' 팝 애니메이션 재생
            key: ValueKey(_nextPromptFx),
            tween: Tween(begin: _nextPromptFx == 0 ? 1.0 : 0.82, end: 1.0),
            duration: const Duration(milliseconds: 260),
            curve: Curves.elasticOut,
            builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
            child: SizedBox(
              height: 42,
              child: OutlinedButton(
                onPressed: canChangePrompt
                    ? () {
                        HapticFeedback.lightImpact();
                        setState(() => _nextPromptFx++);
                        state.handleNextPrompt();
                      }
                    : null,
                style: OutlinedButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  side: BorderSide(color: promptActionColor, width: 1.5),
                  // '이미지 생성'과 같은 알약 모양
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    "다음 (P : ${state.gelbooruRemaining})",
                    maxLines: 1,
                    style: TextStyle(
                      color: promptActionColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 아랫줄 도구 버튼 (프리셋 · 생성 등)
  //  build 안에 215줄이 들어 있어 화면을 그릴 때마다 다시 만들어졌다.
  Widget _buildToolRowBottom(BuildContext context, AppState state) {
    return Row(
      children: [
        // 왼쪽 그룹: 화면이 좁으면 줄어들고, 오른쪽 두 열은 항상 붙어있게
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 윗줄 그룹과 같은 폭으로 묶어 오른쪽 두 열을 정렬
            OutlinedButton(
              onPressed: () => _showPresetBottomSheet(context, state),
              style: OutlinedButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: Colors.deepPurpleAccent.withValues(alpha: 0.15),
                side: BorderSide(color: Colors.deepPurpleAccent.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                minimumSize: const Size(78, 42), // A열: 윗줄 Anlas 영역과 같은 폭
                fixedSize: const Size(78, 42),
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  "프리셋",
                  maxLines: 1,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Vibe Transfer / Precise Reference
            // 모델이 둘 다 미지원이면(예: V5) 잠그고 이유를 알려준다
            Builder(
              builder: (context) {
                final caps = modelCapsFor(state.selectedModel);
                final bool locked = !caps.supportsVibe && !caps.supportsPrecise;
                return GestureDetector(
                  onTap: () {
                    if (locked) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("${caps.displayName}에선 Vibe / Precise를 사용할 수 없어요"),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                      return;
                    }
                    _showVibeTransferDialog(context, state);
                  },
                  child: Opacity(
                    opacity: locked ? 0.35 : 1.0,
                    // 다른 버튼들과 같은 높이(42)로 터치 영역 확보
                    child: SizedBox(
                      width: 44,
                      height: 42,
                      child: Icon(
                        locked ? Icons.palette : Icons.palette_outlined,
                        color: locked
                            ? Colors.grey
                            : ((state.vibeTransfers.isNotEmpty || state.preciseRefs.isNotEmpty)
                                  ? const Color(0xFF8B5CF6)
                                  : Colors.grey),
                        size: 24,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 8),
            // 톱니바퀴 (상세 환경) — 컴팩트
            GestureDetector(
              onTap: () {
                state.isGelbooruExpanded = !state.isGelbooruExpanded;
                state.refreshUI();
              },
              child: SizedBox(
                width: 44,
                height: 42,
                child: Icon(
                  Icons.settings,
                  color: state.isGelbooruExpanded ? const Color(0xFF8B5CF6) : Colors.grey,
                  size: 24,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(width: 8),
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
            _showBatchSettingsDialog(context, state);
          },
          child: Container(
            // 윗줄 새로고침 버튼과 같은 크기 (열 맞춤)
            width: 44,
            height: 42,
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
        const SizedBox(width: 8),
        // E열: 남는 공간을 전부 차지 (왼쪽이 모두 고정이라 겹칠 일 없음)
        Flexible(
          fit: FlexFit.tight,
          child: ElevatedButton.icon(
            onPressed:
                (state.isLoading ||
                    state.isBatchMode ||
                    state.isInpaintLoading ||
                    state.isUpscaleLoading)
                ? () {
                    if (state.isBatchMode) {
                      state.cancelBatch();
                    }
                  }
                : () => _onGeneratePressed(context, state),
            style: ElevatedButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(0, 42), // 윗줄 '다음' 버튼과 같은 높이
              padding: const EdgeInsets.symmetric(horizontal: 8),
              backgroundColor:
                  (state.isLoading ||
                      state.isBatchMode ||
                      state.isInpaintLoading ||
                      state.isUpscaleLoading)
                  ? Colors.grey[700]
                  : const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            ),
            icon:
                (state.isLoading ||
                    state.isBatchMode ||
                    state.isInpaintLoading ||
                    state.isUpscaleLoading)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
            // 폭이 좁아도 줄바꿈되지 않도록 FittedBox로 축소 처리
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                (state.isLoading || state.isBatchMode)
                    ? (state.isBatchMode
                          ? (state.currentRepeatTotal > 1
                                // 반복 생성 중: 남은 회차 + 이번 회차의 반복 진행도
                                ? "생성중(${state.batchRemaining}) ${state.currentRepeatIndex}/${state.currentRepeatTotal}..."
                                : "생성중(${state.batchRemaining})...")
                          : "생성 중...")
                    : (state.isInpaintLoading
                          ? "인페인트 중..."
                          : (state.isUpscaleLoading ? "업스케일 중..." : "이미지 생성")),
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 클래식 UI 윗줄 도구 버튼
  //  _buildClassicLayout 안에 132줄이 들어 있어 매번 다시 만들어졌다.
  Widget _buildClassicToolRowTop(BuildContext context, AppState state) {
    return Row(
      children: [
        Text(
          "검색 : ${state.gelbooruTotal}",
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(width: 12),
        Text(
          "남음 : ${state.gelbooruRemaining}",
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
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
          onLongPress: () => _showBatchSettingsDialog(context, state),
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
          onPressed:
              (state.isLoading ||
                  state.isBatchMode ||
                  state.isInpaintLoading ||
                  state.isUpscaleLoading)
              ? () {
                  if (state.isBatchMode) {
                    state.cancelBatch();
                  }
                }
              : () => _onGeneratePressed(context, state),
          style: ElevatedButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            fixedSize: const Size(160, 40),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            backgroundColor:
                (state.isLoading ||
                    state.isBatchMode ||
                    state.isInpaintLoading ||
                    state.isUpscaleLoading)
                ? Colors.grey[700]
                : const Color(0xFF8B5CF6),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          ),
          icon:
              (state.isLoading ||
                  state.isBatchMode ||
                  state.isInpaintLoading ||
                  state.isUpscaleLoading)
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
          label: Text(
            (state.isLoading || state.isBatchMode)
                ? (state.isBatchMode
                      ? (state.currentRepeatTotal > 1
                            // 반복 생성 중: 남은 회차 + 이번 회차의 반복 진행도
                            ? "생성중(${state.batchRemaining}) ${state.currentRepeatIndex}/${state.currentRepeatTotal}..."
                            : "생성중(${state.batchRemaining})...")
                      : "생성 중...")
                : (state.isInpaintLoading
                      ? "인페인트 중..."
                      : (state.isUpscaleLoading ? "업스케일 중..." : "이미지 생성 시작")),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
      ],
    );
  }

  // 클래식 UI 아랫줄 도구 버튼
  //  _buildClassicLayout 안에 99줄이 들어 있어 매번 다시 만들어졌다.
  Widget _buildClassicToolRowBottom(BuildContext context, AppState state) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: () => _showPresetBottomSheet(context, state),
          icon: const Icon(Icons.bookmarks, color: Colors.deepPurpleAccent, size: 16),
          label: const Text(
            "프리셋 관리",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
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
    );
  }

  void _ensureSectionsPresent(AppState state) {
    final missing = _sectionMeta.keys.where((k) => !state.promptSectionOrder.contains(k)).toList();
    if (missing.isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      state.promptSectionOrder.addAll(missing);
      state.saveAllSettings();
      state.refreshUI();
    });
  }

  Widget _buildClassicLayout(BuildContext context) {
    final state = context.watch<AppState>();
    // 이전 버전 데이터(또는 재시작 전 메모리)에 새로 추가된 섹션이 없으면 자동 보정.
    // 이게 없으면 섹션을 추가해도 화면에 나타나지 않는다.
    _ensureSectionsPresent(state);
    bool canChangePrompt = !state.isRandomLocked && state.gelbooruPrompts.isNotEmpty;
    Color promptActionColor = canChangePrompt ? const Color(0xFF8B5CF6) : Colors.grey;

    return Stack(
      children: [
        Padding(
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
                      TweenAnimationBuilder<double>(
                        // 누를 때마다 key가 바뀌어 '눌렸다 튕겨나오는' 팝 애니메이션 재생
                        key: ValueKey(_nextPromptFx),
                        tween: Tween(begin: _nextPromptFx == 0 ? 1.0 : 0.82, end: 1.0),
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.elasticOut,
                        builder: (context, scale, child) =>
                            Transform.scale(scale: scale, child: child),
                        child: OutlinedButton(
                          onPressed: canChangePrompt
                              ? () {
                                  HapticFeedback.lightImpact(); // 살짝 진동 — 누른 맛!
                                  setState(() => _nextPromptFx++);
                                  state.handleNextPrompt();
                                }
                              : null,
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
                      ),
                    ],
                  ),
                  const SizedBox(height: 0),
                  _buildClassicToolRowTop(context, state),
                  const SizedBox(height: 8),
                  // 토큰 카운터
                  Builder(
                    builder: (context) {
                      // 활성 캐릭터 프롬프트까지 합산 (NAI는 base+character 합쳐 512 제한)
                      final tokens = estimateTotalTokens(state);
                      final capTokens = modelCapsFor(state.selectedModel).maxPromptTokens;
                      final maxTokens = capTokens > 0 ? capTokens : 512;
                      final ratio = (tokens / maxTokens).clamp(0.0, 1.0);
                      // 한도를 넘으면 바로 알 수 있게 진한 빨강
                      final color = tokens > maxTokens
                          // 빨강은 '초과'에만 쓴다 (보이면 바로 넘친 걸 알 수 있게)
                          ? const Color(0xFFFF1744)
                          : tokens > maxTokens * 0.88
                          ? Colors.orangeAccent
                          : tokens > maxTokens * 0.68
                          ? const Color(0xFFFFD54F)
                          : Colors.white38;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.token, size: 14, color: color),
                                const SizedBox(width: 4),
                                Text(
                                  "~${buildTokenLabel(state, maxTokens)} tokens",
                                  style: TextStyle(color: color, fontSize: 11),
                                ),
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
                            _buildV5LimitGauge(state),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  _buildClassicToolRowBottom(context, state),
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
                        // 기본 좌우 패딩(24)과 최소폭(88)이 커서 글씨 공간을 잡아먹는다.
                        // 좌우 여백을 줄여 "태그 확인 1200/3200" 같은 긴 문구도 들어가게.
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown, // 길면 글씨만 줄어듦 (버튼 크기는 그대로)
                        child: Text(
                          state.isGelbooruLoading
                              ? (state.gelbooruSearchStage.isNotEmpty
                                    // 페이지 수신 완료 후: 분류/필터/캐시 등 현재 단계 표시
                                    ? state.gelbooruSearchStage
                                    : (state.gelbooruSearchTotal > 0
                                          // 페이지 수신 중: 완료/전체 페이지
                                          ? "검색 중 ${state.gelbooruSearchDone}/${state.gelbooruSearchTotal}"
                                          : "검색 중"))
                              : "검  색", // 유휴 시엔 글자 사이를 띄워 버튼이 너무 작지 않게
                          maxLines: 1,
                          style: const TextStyle(color: Colors.white),
                        ),
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
                onReorderItem: (oldIndex, newIndex) {
                  final item = state.promptSectionOrder.removeAt(oldIndex);
                  state.promptSectionOrder.insert(newIndex, item);
                  state.saveAllSettings();
                  state.refreshUI();
                },
                children: [
                  for (int idx = 0; idx < state.promptSectionOrder.length; idx++)
                    // 설정에서 숨긴 섹션은 자리만 차지하지 않게 비워둔다.
                    // (키와 인덱스는 유지해야 드래그 순서 변경이 깨지지 않음)
                    if (state.hiddenPromptSections.contains(state.promptSectionOrder[idx]))
                      SizedBox.shrink(key: ValueKey(state.promptSectionOrder[idx]))
                    else
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
                                  : _buildSectionContent(
                                      context,
                                      state,
                                      state.promptSectionOrder[idx],
                                    ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),

              const SizedBox(height: 16),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive 필수 호출
    final state = context.watch<AppState>();
    // 이전 버전 데이터(또는 재시작 전 메모리)에 새로 추가된 섹션이 없으면 자동 보정.
    // 이게 없으면 섹션을 추가해도 화면에 나타나지 않는다.
    _ensureSectionsPresent(state);
    bool canChangePrompt = !state.isRandomLocked && state.gelbooruPrompts.isNotEmpty;
    Color promptActionColor = canChangePrompt ? const Color(0xFF8B5CF6) : Colors.grey;

    // [보류] 실험용 UI (설정에서 숨겨져 있음)
    if (state.promptAltLayout) {
      return _buildAltLayout(context, state, canChangePrompt, promptActionColor);
    }

    // 기본은 예전 UI. 설정에서 '새로운 UI'를 켰을 때만 개편된 레이아웃을 쓴다.
    if (!state.promptNewLayout) {
      return _buildClassicLayout(context);
    }

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                children: [
                  // 윗줄: Anlas · 랜덤잠금/자동저장 · 새로고침 · 다음
                  _buildToolRowTop(context, state, canChangePrompt, promptActionColor),
                  const SizedBox(height: 6),
                  _buildToolRowBottom(context, state),
                  const SizedBox(height: 8),
                  // 토큰 카운터

                  Builder(
                    builder: (context) {
                      // 활성 캐릭터 프롬프트까지 합산 (NAI는 base+character 합쳐 512 제한)
                      final tokens = estimateTotalTokens(state);
                      // 토큰 상한은 모델 캡에서 (0이면 미확인 → 512 기본값)
                      final capTokens = modelCapsFor(state.selectedModel).maxPromptTokens;
                      final maxTokens = capTokens > 0 ? capTokens : 512;
                      final ratio = (tokens / maxTokens).clamp(0.0, 1.0);
                      // 한도를 넘으면 바로 알 수 있게 진한 빨강
                      final color = tokens > maxTokens
                          // 빨강은 '초과'에만 쓴다 (보이면 바로 넘친 걸 알 수 있게)
                          ? const Color(0xFFFF1744)
                          : tokens > maxTokens * 0.88
                          ? Colors.orangeAccent
                          : tokens > maxTokens * 0.68
                          ? const Color(0xFFFFD54F)
                          : Colors.white38;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.token, size: 14, color: color),
                                const SizedBox(width: 4),
                                Text(
                                  "~${buildTokenLabel(state, maxTokens)} tokens",
                                  style: TextStyle(color: color, fontSize: 11),
                                ),
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
                            _buildV5LimitGauge(state),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 2),
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
                        // 기본 좌우 패딩(24)과 최소폭(88)이 커서 글씨 공간을 잡아먹는다.
                        // 좌우 여백을 줄여 "태그 확인 1200/3200" 같은 긴 문구도 들어가게.
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown, // 길면 글씨만 줄어듦 (버튼 크기는 그대로)
                        child: Text(
                          state.isGelbooruLoading
                              ? (state.gelbooruSearchStage.isNotEmpty
                                    // 페이지 수신 완료 후: 분류/필터/캐시 등 현재 단계 표시
                                    ? state.gelbooruSearchStage
                                    : (state.gelbooruSearchTotal > 0
                                          // 페이지 수신 중: 완료/전체 페이지
                                          ? "검색 중 ${state.gelbooruSearchDone}/${state.gelbooruSearchTotal}"
                                          : "검색 중"))
                              : "검  색", // 유휴 시엔 글자 사이를 띄워 버튼이 너무 작지 않게
                          maxLines: 1,
                          style: const TextStyle(color: Colors.white),
                        ),
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
                onReorderItem: (oldIndex, newIndex) {
                  final item = state.promptSectionOrder.removeAt(oldIndex);
                  state.promptSectionOrder.insert(newIndex, item);
                  state.saveAllSettings();
                  state.refreshUI();
                },
                children: [
                  for (int idx = 0; idx < state.promptSectionOrder.length; idx++)
                    // 설정에서 숨긴 섹션은 자리만 차지하지 않게 비워둔다.
                    // (키와 인덱스는 유지해야 드래그 순서 변경이 깨지지 않음)
                    if (state.hiddenPromptSections.contains(state.promptSectionOrder[idx]))
                      SizedBox.shrink(key: ValueKey(state.promptSectionOrder[idx]))
                    else
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
                                  : _buildSectionContent(
                                      context,
                                      state,
                                      state.promptSectionOrder[idx],
                                    ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),

              const SizedBox(height: 16),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }
}

// 파일명용 날짜_시간 문자열 (YYYYMMDD_HHMMSS)
String _fileTimestamp() {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return "${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}";
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

// ============================================================================
// 섹션 메타정보 (ID → 제목, 아이콘, 색상)
// ============================================================================
const Map<String, Map<String, dynamic>> _sectionMeta = {
  'positive': {'title': '긍정적 프롬프트', 'icon': Icons.add_circle_outline, 'color': 0xFF00BFA5},
  'prefix': {'title': '선행 프롬프트', 'icon': Icons.arrow_right_alt, 'color': 0xFF29B6F6},
  'suffix': {'title': '후행 프롬프트', 'icon': Icons.keyboard_double_arrow_right, 'color': 0xFFFFA000},
  'negative': {'title': '부정적 프롬프트', 'icon': Icons.remove_circle_outline, 'color': 0xFFFF5252},
  'removeChips': {'title': '태그 제거', 'icon': Icons.auto_fix_high, 'color': 0xFF8B5CF6},
  'customRemove': {'title': '개별 제거 프롬프트', 'icon': Icons.delete_outline, 'color': 0xFF9E9E9E},
  'conditional': {'title': '조건부 트리거', 'icon': Icons.bolt, 'color': 0xFFEC4899},
  'weightRules': {'title': '가중치 규칙', 'icon': Icons.tune, 'color': 0xFF84CC16},
};

// ============================================================================
// 섹션 헤더 (접기/펴기 토글 + 드래그 핸들)
// ============================================================================

// ── 캐릭터 편집 손잡이 + 서랍 ──
// main.dart의 '화면 기준' Stack에서 Positioned.fill로 사용한다.
// 스크롤 영역 밖이라 드래그 좌표가 화면과 정확히 일치하고,
// 창도 화면 기준으로 배치되어 아래가 묻히지 않는다.
class CharDrawerHandle extends StatefulWidget {
  const CharDrawerHandle({super.key});

  @override
  State<CharDrawerHandle> createState() => _CharDrawerHandleState();
}

class _CharDrawerHandleState extends State<CharDrawerHandle> {
  bool _charDrawerOpen = false;
  int? _charEditIndex; // 편집 중인 캐릭터 (null이면 목록 화면)
  // 캐릭터별 긍정/부정 컨트롤러 캐시 (편집 다이얼로그와 미리보기가 공유)
  // 캐릭터 프롬프트 입력창이 열려 있는 동안은 컨트롤러를 건드리지 않는다.
  // (편집 중에 값을 다시 넣으면 커서 이동·드래그 선택이 초기화된다)
  bool _charEditingOpen = false;

  final Map<int, TextEditingController> _charPosCtrls = {};
  final Map<int, TextEditingController> _charNegCtrls = {};
  double? _charHandleTop; // 손잡이 세로 위치 (드래그로 이동)
  double _screenHeight = 800;

  @override
  void dispose() {
    for (final c in _charPosCtrls.values) {
      c.dispose();
    }
    for (final c in _charNegCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _screenHeight = MediaQuery.of(context).size.height;
    if (!state.promptCharDrawerEnabled || _charDrawerOpen) {
      return const SizedBox.shrink();
    }
    // 자체 Stack(화면 전체) 안에서 손잡이를 배치 → 빈 영역은 터치가 통과된다
    return Stack(
      children: [
        Positioned(
          right: 0,
          top: _handleTopValue(state),
          child: GestureDetector(
            onTap: () => _openCharDrawer(state),
            onVerticalDragUpdate: (d) {
              final maxTop = _screenHeight - 80;
              // 현재 위치 + 이동량 (clamp는 한 번만 — 이중 적용하면 좌표가 어긋남)
              final current = _charHandleTop ?? _handleTopValue(state);
              setState(() {
                _charHandleTop = (current + d.delta.dy).clamp(0.0, maxTop);
              });
            },
            onVerticalDragEnd: (_) {
              if (_charHandleTop != null) {
                state.savePromptCharHandleTop(_charHandleTop!);
              }
            },
            child: Container(
              width: 30,
              height: 80,
              decoration: const BoxDecoration(
                color: Color(0xFF8B5CF6),
                borderRadius: BorderRadius.horizontal(left: Radius.circular(12)),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.drag_indicator, color: Colors.white54, size: 16),
                  SizedBox(height: 3),
                  Icon(Icons.people_alt, color: Colors.white, size: 17),
                  SizedBox(height: 3),
                  Icon(Icons.chevron_left, color: Colors.white, size: 18),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  double _handleTopValue(AppState state) {
    final maxTop = _screenHeight - 80;
    final saved = state.promptCharHandleTop;
    final base = _charHandleTop ?? (saved >= 0 ? saved : _screenHeight * 0.15);
    return base.clamp(0.0, maxTop);
  }

  // ── 캐릭터 목록 바텀시트 (손잡이 탭 → 화면 아래에서 올라옴) ──
  // 캐릭터별 긍정/부정 컨트롤러 (없으면 생성, 텍스트 변경 시 원본에 실시간 반영)
  TextEditingController _charCtrl(AppState state, int index, bool positive) {
    final cache = positive ? _charPosCtrls : _charNegCtrls;
    if (!cache.containsKey(index)) {
      final char = state.characters[index];
      final ctrl = TextEditingController(text: positive ? char.positive : char.negative);
      ctrl.addListener(() {
        if (index < state.characters.length) {
          if (positive) {
            state.characters[index].positive = ctrl.text;
          } else {
            state.characters[index].negative = ctrl.text;
          }
        }
      });
      cache[index] = ctrl;
    } else if (!_charEditingOpen) {
      // 입력창이 '닫혀 있을 때만' 외부 변경(캐릭터 탭 등)을 반영한다.
      //  ⚠️ 편집 중에 값을 다시 넣으면 TextField 내부 편집 상태가 재설정되어
      //     커서 이동·드래그 선택이 취소된다. 그래서 열려 있는 동안은 손대지 않는다.
      //  · 편집 중에는 리스너가 원본을 실시간 갱신하므로 값이 어차피 같다.
      //  · 아래에서 선택 범위를 보존하는 것은 이중 안전장치.
      final ctrl = cache[index]!;
      final src = positive ? state.characters[index].positive : state.characters[index].negative;
      if (ctrl.text != src) {
        final sel = ctrl.selection;
        ctrl.value = ctrl.value.copyWith(
          text: src,
          // 선택 범위가 새 텍스트 길이를 넘지 않도록 보정
          selection: sel.start <= src.length && sel.end <= src.length
              ? sel
              : TextSelection.collapsed(offset: src.length),
          composing: TextRange.empty,
        );
      }
    }
    return cache[index]!;
  }

  // ── 캐릭터 편집 서랍 (오른쪽에서 슬라이드) ──
  // 목록 화면(_charEditIndex == null) ↔ 편집 화면 전환.
  // 세로 길이는 캐릭터 4~5개가 보이도록 화면의 약 55%.
  // ── 캐릭터 편집 서랍 (화면 최상위 레이어로 오른쪽에서 슬라이드) ──
  // showGeneralDialog를 쓰면 스크롤 영역이 아닌 '화면' 기준으로 배치되어,
  // 프롬프트 탭을 아무리 스크롤해도 창이 화면 밖으로 묻히지 않는다.
  void _openCharDrawer(AppState state) {
    const double drawerWidth = 240;
    final screenH = MediaQuery.of(context).size.height;
    final drawerHeight = screenH * 0.37; // 크기는 기존 그대로
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    // 손잡이 위쪽을 창의 위쪽으로 맞춘다. 단, 그렇게 하면 창이 화면 아래로
    // 넘칠 경우(손잡이가 너무 아래) 기존처럼 화면 맨 아래에 붙인다.
    final handleTop = _handleTopValue(state);
    final bool anchorToHandle = handleTop + drawerHeight <= screenH - bottomInset;
    setState(() {
      _charDrawerOpen = true; // 열려 있는 동안 손잡이 숨김
      _charEditIndex = null;
    });

    showGeneralDialog(
      context: context,
      barrierDismissible: true, // 밖을 탭하면 닫힘
      barrierLabel: "캐릭터 편집 닫기",
      barrierColor: Colors.black.withValues(alpha: 0.3),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, anim, secondAnim) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            // AppState 변경(프롬프트 저장 등)에도 미리보기가 갱신되도록 연결
            return AnimatedBuilder(
              animation: state,
              builder: (ctx, _) {
                void close() => Navigator.of(ctx).pop();
                return Stack(
                  children: [
                    Positioned(
                      // 공간이 넉넉하면 손잡이 위쪽에 맞춰서,
                      // 부족하면 화면 맨 아래에 붙여서 표시
                      top: anchorToHandle ? handleTop : null,
                      bottom: anchorToHandle ? null : bottomInset,
                      right: 0,
                      width: drawerWidth,
                      height: drawerHeight,
                      child: Material(
                        color: Colors.transparent,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF171717),
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                            border: Border.all(
                              color: Colors.deepPurpleAccent.withValues(alpha: 0.4),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 12,
                                offset: const Offset(-4, 0),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                            child: _charEditIndex == null
                                ? _buildCharDrawerList(state, setLocal, close)
                                : _buildCharDrawerEditor(state, _charEditIndex!, setLocal, close),
                          ),
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
      transitionBuilder: (ctx, anim, secondAnim, child) {
        // 오른쪽에서 슬라이드
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
    ).whenComplete(() {
      if (mounted) {
        setState(() => _charDrawerOpen = false); // 닫히면 손잡이 다시 표시
      }
    });
  }

  // 서랍 - 캐릭터 목록
  // setLocal: 서랍(다이얼로그) 내부 갱신 / close: 서랍 닫기
  Widget _buildCharDrawerList(AppState state, StateSetter setLocal, VoidCallback close) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: const Color(0xFF1E1E1E),
          child: Row(
            children: [
              const Icon(Icons.people_alt, color: Colors.deepPurpleAccent, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  "캐릭터 목록",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              GestureDetector(
                onTap: close,
                child: const Icon(Icons.chevron_right, color: Colors.white54, size: 22),
              ),
            ],
          ),
        ),
        Expanded(
          child: state.characters.isEmpty
              ? const Center(
                  child: Text(
                    "캐릭터가 없어요.\n캐릭터 탭에서 추가하세요.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: state.characters.length,
                  itemBuilder: (context, i) {
                    final char = state.characters[i];
                    final isOn = char.isActive;
                    final title = char.name.isEmpty ? "캐릭터 #${i + 1}" : char.name;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: isOn ? Colors.deepPurpleAccent : Colors.white12),
                      ),
                      child: Row(
                        children: [
                          // 설정 '캐릭터 재선택으로 ON/OFF'를 끄면 여기서도 토글되지 않는다
                          IconButton(
                            icon: Icon(
                              isOn ? Icons.visibility : Icons.visibility_off,
                              // 색은 항상 상태를 나타낸다 (설정과 무관)
                              color: isOn ? Colors.deepPurpleAccent : Colors.grey,
                              size: 20,
                            ),
                            tooltip: state.charRetapToggle
                                ? (isOn ? "끄기" : "켜기")
                                : "설정에서 'ON/OFF'를 켜면 사용할 수 있어요",
                            onPressed: state.charRetapToggle
                                ? () {
                                    state.characters[i].isActive = !isOn;
                                    state.saveAllSettings();
                                    state.refreshUI();
                                    setLocal(() {});
                                  }
                                : null,
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                _charEditIndex = i;
                                setLocal(() {});
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                child: Text(
                                  title,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isOn ? Colors.white : Colors.white54,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const Icon(Icons.edit, color: Colors.white38, size: 16),
                          const SizedBox(width: 10),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // 서랍 - 편집 화면 (긍정/부정 3줄 미리보기 → 탭하면 프롬프트 입력 다이얼로그)
  Widget _buildCharDrawerEditor(
    AppState state,
    int index,
    StateSetter setLocal,
    VoidCallback close,
  ) {
    if (index >= state.characters.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _charEditIndex = null;
        setLocal(() {});
      });
      return const SizedBox.shrink();
    }
    final char = state.characters[index];
    final title = char.name.isEmpty ? "캐릭터 #${index + 1}" : char.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          color: const Color(0xFF1E1E1E),
          child: Row(
            children: [
              GestureDetector(
                onTap: () {
                  _charEditIndex = null;
                  setLocal(() {});
                },
                child: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
              GestureDetector(
                onTap: close,
                child: const Icon(Icons.chevron_right, color: Colors.white54, size: 22),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _charPreviewCard(
                  label: "긍정 프롬프트",
                  color: const Color(0xFF10B981),
                  icon: Icons.add_circle_outline,
                  text: char.positive,
                  onTap: () {
                    // 프롬프트 탭의 입력 다이얼로그 그대로 재사용 (세세한 경험 동일)
                    _charEditingOpen = true;
                    showPromptEditDialog(
                      context,
                      state,
                      "긍정 프롬프트",
                      Icons.add_circle_outline,
                      const Color(0xFF10B981),
                      _charCtrl(state, index, true),
                      onClosed: () {
                        _charEditingOpen = false;
                        // 리스너가 메모리는 실시간 갱신하지만 저장은 하지 않으므로
                        // 창을 닫을 때 한 번만 저장한다 (매 타자마다 저장하면 무겁다)
                        state.saveAllSettings();
                        setLocal(() {});
                      },
                    );
                  },
                ),
                const SizedBox(height: 12),
                _charPreviewCard(
                  label: "부정 프롬프트",
                  color: const Color(0xFFEF4444),
                  icon: Icons.remove_circle_outline,
                  text: char.negative,
                  onTap: () {
                    _charEditingOpen = true;
                    showPromptEditDialog(
                      context,
                      state,
                      "부정 프롬프트",
                      Icons.remove_circle_outline,
                      const Color(0xFFEF4444),
                      _charCtrl(state, index, false),
                      onClosed: () {
                        _charEditingOpen = false;
                        state.saveAllSettings();
                        setLocal(() {});
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 긍정/부정 미리보기 카드 (3줄) — 탭하면 입력 다이얼로그
  Widget _charPreviewCard({
    required String label,
    required Color color,
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: color, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                  Icon(Icons.edit, color: color, size: 15),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                text.isEmpty ? "탭하여 입력..." : text,
                maxLines: 3, // 미리보기 3줄
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: text.isEmpty ? Colors.white30 : Colors.white,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
