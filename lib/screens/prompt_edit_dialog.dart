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
  // ⚠️ 타이머는 다이얼로그가 열려 있는 동안 유지돼야 하므로 builder 바깥에 둔다.
  //    (StatefulBuilder 안에 두면 리빌드마다 새로 만들어져 디바운스가 동작하지 않는다)
  Timer? tagDebounce;
  Timer? saveDebounce;
  // 자동완성 후보를 만든 시점의 커서 위치.
  // 사용자가 다른 곳으로 커서를 옮기면 그 후보는 더 이상 유효하지 않다.
  //  (옮긴 뒤 후보를 누르면 엉뚱한 위치에 태그가 끼어드는 문제가 있었다)
  int suggestionAnchor = -1;

  // 커서가 후보를 만든 위치에서 벗어나면 후보를 지운다.
  //  탭·핸들 드래그·키보드 이동을 모두 잡으려면 컨트롤러 리스너가 확실하다.
  //  (텍스트가 바뀐 경우는 onChanged가 처리하므로 여기선 위치만 본다)
  String lastKnownText = controller.text;
  void Function()? cursorWatcher;

  showDialog(
    context: context,
    builder: (ctx) {
      List<String> suggestions = [];

      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setModalState) {
          // 커서 감시자 등록 (한 번만)
          if (cursorWatcher == null) {
            cursorWatcher = () {
              if (suggestionAnchor < 0) {
                return;
              }
              // 텍스트가 바뀐 경우는 타이핑이므로 onChanged가 처리한다
              if (controller.text != lastKnownText) {
                lastKnownText = controller.text;
                return;
              }
              // 텍스트는 그대로인데 커서만 움직였다 → 후보 무효
              if (controller.selection.baseOffset != suggestionAnchor) {
                setModalState(() {
                  suggestions = [];
                  suggestionAnchor = -1;
                });
              }
            };
            controller.addListener(cursorWatcher!);
          }

          focusNode.addListener(() {
            if (!focusNode.hasFocus) {
              Future.delayed(const Duration(milliseconds: 150), () {
                if (ctx.mounted) {
                  setModalState(() {
                    suggestions.clear();
                    suggestionAnchor = -1;
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
                suggestionAnchor = -1;
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
                suggestionAnchor = controller.selection.baseOffset;
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
                setModalState(() {
                  suggestions = [];
                  suggestionAnchor = -1;
                });
                return;
              }
              List<String> matches = smartMatchTags(state.searchTags, currentWord);
              setModalState(() {
                suggestions = matches;
                suggestionAnchor = controller.selection.baseOffset;
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
                        // 타이핑마다 하던 무거운 작업을 정리했다.
                        //  · saveAllSettings()는 설정 100여 개를 디스크에 쓰므로
                        //    입력이 멈춘 뒤(500ms) 한 번만 실행한다.
                        //  · 뒤쪽 탭 갱신(refreshUI)은 입력창이 화면을 덮고 있어
                        //    보이지 않으므로 창을 닫을 때만 한다.
                        //    (컨트롤러가 AppState 소유라 값 자체는 이미 반영돼 있다)
                        // onTextChanged 안에서 필요한 만큼만 setModalState를 부른다
                        // (여기서 또 부르면 매 글자마다 불필요한 리빌드가 한 번 더 생긴다)
                        lastKnownText = controller.text;
                        onTextChanged();
                        saveDebounce?.cancel();
                        saveDebounce = Timer(
                          const Duration(milliseconds: 500),
                          () => state.saveAllSettings(),
                        );
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
    if (cursorWatcher != null) {
      controller.removeListener(cursorWatcher!);
    }
    focusNode.dispose();
    // 대기 중인 저장이 있으면 취소하고 즉시 저장 (놓치지 않게)
    saveDebounce?.cancel();
    tagDebounce?.cancel();
    state.saveAllSettings();
    state.refreshUI(); // 창이 닫혔으니 이제 뒤쪽 화면을 갱신
    onClosed?.call();
  });
}
