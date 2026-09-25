import 'dart:async'; // Timer (자동완성 디바운스)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // SystemChannels (키보드 내리기)
import '../models/app_state.dart';
import '../utils/prompt_utils.dart';
import '../app_theme.dart';
import '../utils/ui_safety.dart';
import '../models/prompt_dict.dart';
import '../widgets/app_toast.dart';
import '../widgets/dict_image_viewer.dart'; // 사전 이미지 크게 보기

// ══════════════════════════════════════════════════════════════════════
// 프롬프트 입력 다이얼로그 (공용)
//  프롬프트 탭 / i2i 탭 / 캐릭터 탭이 모두 이 함수를 쓴다.
//  예전에는 파일마다 복붙된 사본이 있어서 한쪽만 고쳐지는 문제가 있었다
//  (예: 태그명 속 괄호에서 자동완성이 끊기던 버그).
// ══════════════════════════════════════════════════════════════════════
/// 확대 입력창을 연다. 창이 닫히면 완료되는 Future 를 돌려준다.
///  (다른 창 안에서 열었을 때, 닫힌 뒤 그 창의 미리보기를 새로 그리려면 await 하면 된다.
///   예전처럼 결과를 무시하고 불러도 된다)
Future<void> showPromptEditDialog(
  BuildContext context,
  AppState state,
  String title,
  IconData icon,
  Color color,
  TextEditingController controller, {
  // 호출측이 임시로 만든 컨트롤러를 정리할 때 쓴다 (다이얼로그가 닫힌 뒤 호출).
  // 이 함수는 외부에서 받은 controller를 직접 dispose 하지 않는다.
  VoidCallback? onClosed,
  // 되돌리기 기록을 저장할 열쇠.
  //  ⚠️ title 을 그대로 쓰면 안 된다. 프롬프트탭과 i2i탭이 똑같이
  //     "긍정적 프롬프트" 라는 이름을 쓰기 때문에 기록이 섞인다.
  //     캐릭터도 번호가 달라야 서로 안 섞인다.
  //     넘기지 않으면 title 을 쓰므로 기존 호출부도 그대로 동작한다.
  String? undoKey,
}) {
  final String historyKey = undoKey ?? title;
  FocusNode focusNode = FocusNode();
  final String initialText = controller.text;
  // 창을 연 시점의 내용을 되돌리기 기록에 남긴다.
  //  여기서 한 번만 남기면 "쓰던 걸 전부 지우고 다른 걸 시험" 하는 흐름이 그대로 복구된다.
  //  (타이핑마다 남기면 한 글자씩 되돌아가 쓸모가 없다)
  state.pushPromptUndo(historyKey, initialText);
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
  void Function()? focusWatcher;
  // 창이 닫힌 뒤에도 리스너가 한 박자 늦게 불릴 수 있다.
  // 그때 setModalState 를 부르면 이미 사라진 화면을 다시 그리라고 하는 셈이다.
  bool closed = false;

  return showDialog(
    context: context,
    builder: (ctx) {
      List<String> suggestions = [];

      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setModalState) {
          // 커서 감시자 등록 (한 번만)
          if (cursorWatcher == null) {
            cursorWatcher = () {
              if (closed || suggestionAnchor < 0) {
                return;
              }
              // 텍스트가 바뀐 경우는 타이핑이므로 onChanged가 처리한다
              if (controller.text != lastKnownText) {
                lastKnownText = controller.text;
                return;
              }
              // ⚠️ 드래그로 범위를 잡는 중에는 건드리지 않는다.
              //    선택이 진행되는 동안 이 리스너는 손가락을 움직일 때마다
              //    불리는데, 그때마다 화면을 다시 그리면 입력 연결이 끊겼다
              //    이어지기를 반복해 키보드 요청이 폭주한다(ANR).
              final sel = controller.selection;
              if (!sel.isCollapsed) {
                return;
              }
              // 텍스트는 그대로인데 커서만 움직였다 → 후보 무효
              if (sel.baseOffset != suggestionAnchor && suggestions.isNotEmpty) {
                // 제스처 처리 도중에 바로 그리지 않고 프레임이 끝난 뒤에 맡긴다
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (closed || !ctx.mounted) {
                    return;
                  }
                  setModalState(() {
                    suggestions = [];
                    suggestionAnchor = -1;
                  });
                });
              }
            };
            controller.addListener(cursorWatcher!);
          }

          // ⚠️ 리스너 등록은 한 번만.
          //    StatefulBuilder 의 builder 는 리빌드마다 실행되므로, 여기서 그냥
          //    addListener 하면 타이핑할 때마다 같은 리스너가 겹겹이 쌓인다.
          if (focusWatcher == null) {
            focusWatcher = () {
              if (!focusNode.hasFocus) {
                Future.delayed(const Duration(milliseconds: 150), () {
                  if (!closed && ctx.mounted) {
                    setModalState(() {
                      suggestions.clear();
                      suggestionAnchor = -1;
                    });
                  }
                });
              }
            };
            focusNode.addListener(focusWatcher!);
          }

          void onTextChanged() {
            // 단어 잘라내기·후보 만들기는 PromptUtils가 담당한다 (프롬프트탭과 공용)
            final currentWord = PromptUtils.currentWordBefore(
              controller.text,
              controller.selection.baseOffset,
            );
            final wildcardNames = state.wildcards.map((w) => w.name).toList();

            // 와일드카드(__name__)는 목록이 작아 즉시 보여준다
            if (currentWord.isEmpty || currentWord.startsWith('__')) {
              tagDebounce?.cancel();
              setModalState(() {
                suggestions = PromptUtils.suggestionsFor(
                  currentWord: currentWord,
                  tags: state.searchTags,
                  wildcardNames: wildcardNames,
                );
                suggestionAnchor = suggestions.isEmpty ? -1 : controller.selection.baseOffset;
              });
              return;
            }

            // 태그 매칭은 후보가 많아 100ms 디바운스 (빠른 응답 + 부하 방지)
            tagDebounce?.cancel();
            final capturedWord = currentWord; // 현재 시점 캡처
            tagDebounce = Timer(const Duration(milliseconds: 100), () {
              // 디바운스 도중 입력이 바뀌었으면 버린다
              final nowWord = PromptUtils.currentWordBefore(
                controller.text,
                controller.selection.baseOffset,
              );
              if (nowWord != capturedWord || nowWord.isEmpty) {
                setModalState(() {
                  suggestions = [];
                  suggestionAnchor = -1;
                });
                return;
              }
              final matches = PromptUtils.suggestionsFor(
                currentWord: nowWord,
                tags: state.searchTags,
                wildcardNames: wildcardNames,
              );
              setModalState(() {
                suggestions = matches;
                suggestionAnchor = matches.isEmpty ? -1 : controller.selection.baseOffset;
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
            backgroundColor: AppColors.surface,
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
                      color: AppColors.background,
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
                      // 프롬프트 사전에서 불러오기
                      OutlinedButton(
                        onPressed: () async {
                          final picked = await _pickDictEntry(ctx, state, color);
                          if (picked == null) {
                            return;
                          }
                          // 붙이기 전 내용을 기록해 둔다 (↺ 로 되돌릴 수 있게)
                          state.pushPromptUndo(historyKey, controller.text);
                          controller.text = appendPromptPiece(controller.text, picked.prompt);
                          // 커서를 맨 끝으로 — 이어서 바로 입력할 수 있게
                          controller.selection = TextSelection.collapsed(
                            offset: controller.text.length,
                          );
                          lastKnownText = controller.text;
                          setModalState(() {
                            suggestions.clear();
                          });
                          state.saveAllSettings();
                        },
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: color),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          // 버튼이 네 개라 좁은 화면(360dp)에서도 한 줄에 들어가게 최소 폭을 줄인다
                          minimumSize: const Size(48, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Icon(Icons.menu_book, color: color, size: 20),
                      ),
                      // 사전은 '불러오기', 오른쪽 둘은 '지우기·되돌리기'라 성격이 달라 더 띄운다
                      const SizedBox(width: 24),
                      OutlinedButton(
                        onPressed: () {
                          // 지우기 직전 내용을 기록해 둔다 (되돌리기로 살릴 수 있게)
                          state.pushPromptUndo(historyKey, controller.text);
                          controller.clear();
                          setModalState(() {
                            suggestions.clear();
                          });
                          state.saveAllSettings();
                          state.refreshUI();
                        },
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: color),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          // 버튼이 네 개라 좁은 화면(360dp)에서도 한 줄에 들어가게 최소 폭을 줄인다
                          minimumSize: const Size(48, 44),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Icon(Icons.delete_sweep, color: color, size: 20),
                      ),
                      const SizedBox(width: 12), // 아이콘 버튼끼리는 조금 더 띄운다
                      // 되돌리기 — 탭: 가장 최근 내용 / 꾹: 기록에서 골라 되돌리기
                      GestureDetector(
                        onLongPress: () async {
                          final picked = await _pickUndoEntry(
                            ctx,
                            state,
                            historyKey,
                            title,
                            color,
                            controller.text,
                          );
                          if (picked == null) {
                            return;
                          }
                          // 지금 내용도 기록해 둬야 되돌린 뒤 다시 돌아올 수 있다
                          state.pushPromptUndo(historyKey, controller.text);
                          controller.text = picked;
                          setModalState(() {
                            suggestions.clear();
                          });
                          state.saveAllSettings();
                          state.refreshUI();
                        },
                        child: OutlinedButton(
                          onPressed: () {
                            // '지금 입력창과 다른' 가장 최근 기록으로 간다.
                            //  ⚠️ 창을 열 때 지금 내용을 먼저 기록해 두기 때문에
                            //     맨 앞 기록은 대개 지금 내용과 똑같다. 그걸 고르면
                            //     버튼을 눌러도 아무 일도 안 일어난다(예전 버그).
                            final choices = _undoChoices(state, historyKey, controller.text);
                            if (choices.isEmpty) {
                              return;
                            }
                            final target = choices.first;
                            state.pushPromptUndo(historyKey, controller.text);
                            controller.text = target;
                            setModalState(() {
                              suggestions.clear();
                            });
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: color),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            // 버튼이 네 개라 좁은 화면(360dp)에서도 한 줄에 들어가게 최소 폭을 줄인다
                            minimumSize: const Size(48, 44),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.restore, color: color, size: 20),
                              // 기록이 2개 이상일 때만 개수를 보여 준다 (꾹 누르면 고를 수 있다는 힌트)
                              if (_undoChoices(state, historyKey, controller.text).length > 1) ...[
                                const SizedBox(width: 3),
                                Text(
                                  "${_undoChoices(state, historyKey, controller.text).length}",
                                  style: TextStyle(
                                    color: color,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          // 닫기 전에 키보드부터 내린다.
                          //  포커스 노드는 건드리지 않는다 (아래 .then 에서 정리).
                          // ⚠️ 이미 내려가 있으면 부르지 않는다. 그냥 부르면
                          //    안드로이드가 ALREADY_HIDDEN 으로 취소하며 로그만 쌓인다.
                          if (focusNode.hasFocus) {
                            SystemChannels.textInput.invokeMethod('TextInput.hide');
                          }
                          Navigator.pop(ctx);
                        },
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
    closed = true; // 남아 있는 리스너·지연 호출이 더 이상 화면을 건드리지 않게
    if (cursorWatcher != null) {
      controller.removeListener(cursorWatcher!);
    }
    if (focusWatcher != null) {
      focusNode.removeListener(focusWatcher!);
    }
    // 키보드를 내린다.
    //  ⚠️ 포커스 트리를 직접 만지지 않고 입력 채널에만 요청한다.
    //     unfocus() 로 포커스를 옮기면 그 순간 프레임워크가 포커스 전환과
    //     라우트 정리를 동시에 하게 되는데, 텍스트를 드래그 선택한 상태
    //     (선택 핸들·돋보기가 떠 있는 상태)에서 이러면 메인 스레드가 멈춘다.
    //  ⚠️ 이미 내려가 있으면 부르지 않는다 (ALREADY_HIDDEN 로그 방지)
    if (focusNode.hasFocus) {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    }

    // ⚠️ dispose 는 이번 프레임이 끝난 뒤에.
    //    닫히는 중인 화면이 아직 이 노드를 참조하고 있을 수 있어,
    //    같은 프레임에서 버리면 포커스 트리가 어긋난다.
    //    (이게 어긋나면 키보드가 남고 다음 탭이 먹지 않는다)
    WidgetsBinding.instance.addPostFrameCallback((_) => focusNode.dispose());

    // 대기 중인 저장이 있으면 취소한다
    saveDebounce?.cancel();
    tagDebounce?.cancel();
    // ⚠️ 저장은 여기서 한 번만.
    //    onClosed 안에서도 saveAllSettings 를 부르는 호출부가 있어,
    //    둘 다 돌면 설정 116개를 두 번 쓰게 된다. 한쪽으로 모은다.
    state.saveAllSettings();
    state.refreshUI(); // 창이 닫혔으니 이제 뒤쪽 화면을 갱신

    // 호출측 정리(보통 컨트롤러 dispose)는 창이 완전히 사라진 뒤에 맡긴다.
    //  이유는 disposeAfterDialog 의 설명 참고.
    if (onClosed != null) {
      disposeAfterDialog(onClosed);
    }
  });
}

/// 되돌아갈 수 있는 기록들 (최신이 앞).
///
/// 지금 입력창과 똑같은 기록은 뺀다 — 골라도 아무것도 안 바뀌기 때문이다.
/// (창을 열 때 지금 내용을 먼저 기록해 두므로, 빼지 않으면 목록 맨 위가
///  늘 '지금 내용'이 되어 어느 쪽이 현재인지 헷갈렸다)
List<String> _undoChoices(AppState state, String historyKey, String current) {
  return state.promptUndoList(historyKey).where((t) => t != current).toList();
}

/// 되돌리기 기록에서 하나를 고른다. 취소하면 null.
///
/// 맨 위에 '지금' 내용을 흐리게 보여 기준점을 잡아 주고,
/// 그 아래로 '바로 전 → 2번 전 → …' 순서로 늘어놓는다.
/// 되돌아갈 곳이 하나뿐이면 묻지 않고 그것을 돌려준다.
Future<String?> _pickUndoEntry(
  BuildContext context,
  AppState state,
  String historyKey, // 기록을 찾을 열쇠 (탭·캐릭터별로 다르다)
  String title, // 화면에 보여 줄 이름
  Color color,
  String current, // 지금 입력창 내용 (목록에서 빼고, 맨 위에 기준으로 보여 준다)
) async {
  final list = _undoChoices(state, historyKey, current);
  if (list.isEmpty) {
    return null;
  }
  if (list.length == 1) {
    return list.first;
  }

  Widget entry({
    required String label,
    required String text,
    required bool isNow,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isNow ? Colors.white.withValues(alpha: 0.04) : null,
          border: Border.all(
            color: isNow ? Colors.white12 : Colors.white24,
            // '지금' 칸은 누르는 곳이 아니라 기준점이라 점선 느낌으로 흐리게
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isNow ? Icons.edit_note : Icons.history,
                  size: 14,
                  color: isNow ? Colors.white38 : color,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: isNow ? Colors.white38 : color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  "${text.length}자",
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              text.isEmpty ? "(비어 있음)" : text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isNow ? Colors.white38 : Colors.white70,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.restore, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "$title 되돌리기",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 기준점: 지금 입력창 (누를 수 없음)
            entry(label: "지금", text: current, isNow: true),
            const Padding(
              padding: EdgeInsets.only(bottom: 6, left: 4),
              child: Text(
                "▼ 아래를 누르면 그때 내용으로 돌아갑니다",
                style: TextStyle(color: Colors.white30, fontSize: 11),
              ),
            ),
            for (int i = 0; i < list.length; i++)
              entry(
                label: i == 0 ? "바로 전" : "${i + 1}번 전",
                text: list[i],
                isNow: false,
                onTap: () => Navigator.pop(ctx, list[i]),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            state.clearPromptUndo(historyKey);
            Navigator.pop(ctx);
          },
          child: const Text("기록 지우기", style: TextStyle(color: Colors.redAccent)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text("취소", style: TextStyle(color: Colors.grey)),
        ),
      ],
    ),
  );
}

/// 프롬프트 사전에서 하나를 고른다.
///  '추가'를 누르면 그 항목을 돌려주고, '복사'는 클립보드에 넣고 창을 닫는다(null).
///
/// ⚠️ 목록이 길 수 있어 높이를 화면의 60%로 제한하고 그 안에서 스크롤한다.
///    (AlertDialog 의 content 는 높이가 정해지지 않아 ListView 를 그냥 넣으면 안 된다)
Future<PromptDictEntry?> _pickDictEntry(BuildContext context, AppState state, Color color) {
  // 마지막으로 고른 분류에서 시작한다 (지워진 분류였으면 전체로)
  String filter = state.validDictFilter(state.dictPickerFilter);
  String filterName(String f) {
    if (f == kDictFilterAll) {
      return "전체";
    }
    if (f == kDictFilterNone) {
      return "미분류";
    }
    for (final c in state.promptDictCategories) {
      if (c.id == f) {
        return c.name;
      }
    }
    return "전체";
  }

  Widget smallButton(String label, IconData icon, Color c, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  // 제목을 눌러 펼쳐 본 항목들 (내용 미리보기)
  final Set<String> expanded = {};

  return showDialog<PromptDictEntry>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setPicker) {
        final list = state.promptDict.where((e) => dictEntryMatches(e, filter)).toList();
        return AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          title: Row(
            children: [
              Icon(Icons.menu_book, color: color, size: 20),
              const SizedBox(width: 8),
              const Text(
                "프롬프트 사전",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(width: 10),
              // 분류 고르기 — 누르면 목록이 펼쳐진다
              Flexible(
                child: PopupMenuButton<String>(
                  initialValue: filter,
                  color: AppColors.surface,
                  tooltip: "분류",
                  onSelected: (v) => setPicker(() {
                    filter = v;
                    state.dictPickerFilter = v; // 다음에 열 때도 이 분류로
                    expanded.clear();
                  }),
                  itemBuilder: (_) => [
                    // 순서: 전체 → 만든 분류들 → 미분류 (사전 탭의 칩 줄과 같다)
                    const PopupMenuItem(
                      value: kDictFilterAll,
                      child: Text("전체", style: TextStyle(color: Colors.white)),
                    ),
                    for (final c in state.promptDictCategories)
                      PopupMenuItem(
                        value: c.id,
                        child: Text(c.name, style: const TextStyle(color: Colors.white)),
                      ),
                    // 미분류는 항상 맨 아래 (사전 편집 창과 같은 모양)
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: kDictFilterNone,
                      child: Text("미분류", style: TextStyle(color: Colors.white70)),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            filterName(filter),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(Icons.arrow_drop_down, color: Colors.white54, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Text("${list.length}개", style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: list.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 8),
                    child: Text(
                      state.promptDict.isEmpty
                          ? "사전이 비어 있습니다.\n라이브러리 탭 > 프롬프트 사전에서 저장해 두세요."
                          : "이 분류에는 항목이 없습니다.",
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white38, fontSize: 13, height: 1.5),
                    ),
                  )
                : ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, i) {
                        final e = list[i];
                        final t = state.dictThumb(e); // 한 번 푼 건 다시 안 푼다 (사전 탭과 공용)
                        final isOpen = expanded.contains(e.id);
                        return Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isOpen ? color.withValues(alpha: 0.5) : Colors.white12,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  // 썸네일을 누르면 크게 보기 — 작가를 고를 때 "이런 그림이었지" 확인용
                                  GestureDetector(
                                    onTap: t == null
                                        ? null
                                        : () => showDictImageViewer(
                                            ctx,
                                            title: e.displayTitle,
                                            loadLarge: () => state.loadDictImage(e.id),
                                            thumb: t,
                                          ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: SizedBox(
                                        width: 44,
                                        height: 44,
                                        child: t != null
                                            ? Image.memory(
                                                t,
                                                fit: BoxFit.cover,
                                                cacheWidth: 88, // 작게 보이므로 작게 푼다
                                                gaplessPlayback: true,
                                              )
                                            : Container(
                                                color: AppColors.surface,
                                                child: const Icon(
                                                  Icons.image_outlined,
                                                  color: Colors.white24,
                                                  size: 20,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  // 미리보기와 버튼 사이(제목)를 누르면 내용을 펼쳐 본다
                                  Expanded(
                                    child: InkWell(
                                      onTap: () => setPicker(() {
                                        if (!expanded.remove(e.id)) {
                                          expanded.add(e.id);
                                        }
                                      }),
                                      borderRadius: BorderRadius.circular(6),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                e.displayTitle,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            Icon(
                                              isOpen ? Icons.expand_less : Icons.expand_more,
                                              size: 18,
                                              color: Colors.white38,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  smallButton("추가", Icons.playlist_add, AppColors.teal, () {
                                    Navigator.pop(ctx, e);
                                  }),
                                  const SizedBox(width: 6),
                                  smallButton("복사", Icons.copy, AppColors.blue, () {
                                    Clipboard.setData(ClipboardData(text: e.prompt));
                                    Navigator.pop(ctx);
                                    showToast(context, "'${e.displayTitle}' 프롬프트를 복사했습니다.");
                                  }),
                                ],
                              ),
                              // 펼쳤을 때: 저장된 프롬프트 전체 (보기만, 길면 그 안에서 스크롤)
                              if (isOpen)
                                Container(
                                  margin: const EdgeInsets.only(top: 6),
                                  padding: const EdgeInsets.all(8),
                                  constraints: const BoxConstraints(maxHeight: 140),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      e.prompt,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("닫기", style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    ),
  );
}
