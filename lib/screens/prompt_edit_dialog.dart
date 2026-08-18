import 'dart:async'; // Timer (자동완성 디바운스)
import 'dart:math'; // max (커서 위치 계산)
import 'package:flutter/material.dart';
import '../models/app_state.dart';
import '../utils/prompt_utils.dart';

// ══════════════════════════════════════════════════════════════════════
// 프롬프트 입력 다이얼로그 (공용)
//  프롬프트 탭 / i2i 탭 / 캐릭터 탭이 모두 이 함수를 쓴다.
//  예전에는 파일마다 복붙된 사본이 있어서 한쪽만 고쳐지는 문제가 있었다
//  (예: 태그명 속 괄호에서 자동완성이 끊기던 버그).
// ══════════════════════════════════════════════════════════════════════
void showPromptEditDialog(
  BuildContext context,
  AppState state,
  String title,
  IconData icon,
  Color color,
  TextEditingController controller, {
  // 호출측이 임시로 만든 컨트롤러를 정리할 때 쓴다 (다이얼로그가 닫힌 뒤 호출).
  // 이 함수는 외부에서 받은 controller를 직접 dispose 하지 않는다.
  VoidCallback? onClosed,
}) {
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
            // '(' ')'는 구분자에서 제외 — 태그 이름 자체에 괄호가 들어가기 때문
            // (예: "zero (test)"). NovelAI 강조 문법은 {}/[]라 영향 없음.
            int lastParen = max(beforeCursor.lastIndexOf('{'), beforeCursor.lastIndexOf('|'));
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
                    max(nowBefore.lastIndexOf('{'), nowBefore.lastIndexOf('|')),
                  ),
                ),
              );
              final nowWord = (nowLastDel == -1 ? nowBefore : nowBefore.substring(nowLastDel + 1))
                  .trimLeft();
              if (nowWord != capturedWord || nowWord.isEmpty) {
                setModalState(() => suggestions = []);
                return;
              }
              List<String> matches = smartMatchTags(state.searchTags, currentWord);
              setModalState(() {
                suggestions = matches;
              });
            });
          }

          void insertTag(String tag) {
            PromptUtils.applyTagToController(controller, tag);

            setModalState(() {
              suggestions.clear();
            });
            state.saveAllSettings();
            state.refreshUI();
          }

          return Dialog(
            insetPadding: PromptUtils.promptEditorDialogInsets,
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
                      style: PromptUtils.promptEditorTextStyle(state.promptEditorFontSize),
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
                                    PromptUtils.displayTag(suggestions[index]),
                                    style: TextStyle(
                                      color: state.isE621Tag(suggestions[index])
                                          ? const Color(0xFF3B9EFF)
                                          : Colors.white,
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
  ).then((_) {
    focusNode.dispose();
    onClosed?.call();
  });
}
