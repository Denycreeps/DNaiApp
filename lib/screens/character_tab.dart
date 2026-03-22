import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/nai_character.dart';

class CharacterTab extends StatelessWidget {
  const CharacterTab({super.key});

  void _showPromptEditDialog(
    BuildContext context,
    AppState state,
    String title,
    IconData icon,
    Color color,
    String currentText,
    ValueChanged<String> onSaved,
  ) async {
    TextEditingController tc = TextEditingController(text: currentText);
    FocusNode focusNode = FocusNode();
    final String initialText = currentText;

    await showDialog(
      context: context,
      builder: (ctx) {
        // 🚀 Linter 규칙 준수: 변수명 앞 언더스코어 제거
        List<String> suggestions = [];

        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            focusNode.addListener(() {
              if (!focusNode.hasFocus) {
                Future.delayed(const Duration(milliseconds: 150), () {
                  if (ctx.mounted) setModalState(() => suggestions.clear());
                });
              }
            });

            // 🚀 Linter 규칙 준수: 함수명 앞 언더스코어 제거
            void onTextChanged() {
              String text = tc.text;
              int cursor = tc.selection.baseOffset;
              if (cursor < 0) cursor = text.length;

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

              List<String> matches = state.danbooruTags
                  .where((t) => t.toLowerCase().startsWith(currentWord.toLowerCase()))
                  .take(15)
                  .toList();

              setModalState(() {
                suggestions = matches;
              });
            }

            // 🚀 Linter 규칙 준수: 함수명 앞 언더스코어 제거
            void insertTag(String tag) {
              String text = tc.text;
              int cursor = tc.selection.baseOffset;
              if (cursor < 0) cursor = text.length;

              String beforeCursor = text.substring(0, cursor);
              String afterCursor = text.substring(cursor);

              int lastComma = beforeCursor.lastIndexOf(',');
              int lastColon = beforeCursor.lastIndexOf(':');
              int lastNewline = beforeCursor.lastIndexOf('\n');
              int lastParen = beforeCursor.lastIndexOf(')');
              int lastDelimiter = max(lastComma, max(lastColon, max(lastNewline, lastParen)));

              String newBefore;

              if (lastDelimiter == -1) {
                newBefore = "$tag, ";
              } else {
                String delimiterStr = beforeCursor.substring(lastDelimiter, lastDelimiter + 1);
                if (delimiterStr == ':') {
                  newBefore = "${beforeCursor.substring(0, lastDelimiter)}:$tag, ";
                } else if (delimiterStr == '\n') {
                  newBefore = "${beforeCursor.substring(0, lastDelimiter)}\n$tag, ";
                } else if (delimiterStr == ')') {
                  newBefore = "${beforeCursor.substring(0, lastDelimiter)}) $tag, ";
                } else {
                  newBefore = "${beforeCursor.substring(0, lastDelimiter)}, $tag, ";
                }
              }

              tc.value = TextEditingValue(
                text: newBefore + afterCursor,
                selection: TextSelection.collapsed(offset: newBefore.length),
              );

              setModalState(() {
                suggestions.clear();
              });
              onSaved(tc.text);
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
                        controller: tc,
                        focusNode: focusNode,
                        onChanged: (val) {
                          onTextChanged(); // 🚀 수정된 함수 호출
                          onSaved(val);
                          state.refreshUI();
                        },
                        maxLines: null,
                        expands: true,
                        style: const TextStyle(color: Colors.white, height: 1.5),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(16),
                          hintText: "프롬프트를 입력하세요...",
                          hintStyle: TextStyle(color: Colors.white30),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: suggestions.isNotEmpty ? 40 : 0, // 🚀 수정된 변수 사용
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
                                    onPressed: () => insertTag(suggestions[index]), // 🚀 수정된 함수 호출
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
                            tc.clear();
                            setModalState(() {
                              suggestions.clear();
                            });
                            onSaved(tc.text);
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
                            tc.text = initialText;
                            setModalState(() {
                              suggestions.clear();
                            });
                            onSaved(tc.text);
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
    state.saveAllSettings();
  }

  void _showLocationDialog(BuildContext context, AppState state) {
    int tempX = state.characters[state.selectedCharIndex].gridX;
    int tempY = state.characters[state.selectedCharIndex].gridY;
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text(
              "위치 설정",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 250,
              height: 250,
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemCount: 25,
                itemBuilder: (context, index) {
                  int x = index % 5;
                  int y = index ~/ 5;
                  bool isSelected = (x == tempX && y == tempY);
                  return GestureDetector(
                    onTap: () => setDialogState(() {
                      tempX = x;
                      tempY = y;
                    }),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.deepPurpleAccent : Colors.transparent,
                        border: Border.all(color: Colors.white30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text("취소", style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () {
                  state.characters[state.selectedCharIndex].gridX = tempX;
                  state.characters[state.selectedCharIndex].gridY = tempY;
                  state.saveAllSettings();
                  state.refreshUI();
                  Navigator.pop(dialogContext);
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
                child: const Text("확인", style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPromptCard({
    required String title,
    required IconData icon,
    required Color color,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
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
                        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ],
                  ),
                  Icon(Icons.edit, color: color, size: 18),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                text.isEmpty ? "$title을(를) 입력하세요..." : text,
                style: TextStyle(
                  color: text.isEmpty ? Colors.white30 : Colors.white,
                  fontSize: 14,
                  height: 1.5,
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 70,
            constraints: const BoxConstraints(maxHeight: 600),
            decoration: const BoxDecoration(
              color: Color(0xFF121212),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.only(top: 0, bottom: 16),
              children: [
                ...List.generate(state.characters.length, (index) {
                  bool isSelected = state.selectedCharIndex == index;
                  bool isActive = state.characters[index].isActive;

                  return GestureDetector(
                    onTap: () {
                      state.selectedCharIndex = index;
                      state.refreshUI();
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF1E1E1E) : Colors.transparent,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(12),
                          bottomLeft: Radius.circular(12),
                        ),
                      ),
                      child: Center(
                        child: CircleAvatar(
                          backgroundColor: isActive ? Colors.deepPurpleAccent : Colors.grey[700],
                          foregroundColor: Colors.white,
                          child: Text(
                            "${index + 1}",
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Colors.deepPurpleAccent, size: 36),
                  onPressed: () {
                    state.characters.add(NaiCharacter());
                    state.selectedCharIndex = state.characters.length - 1;
                    state.refreshUI();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: state.characters.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text("캐릭터를 추가해주세요.", style: TextStyle(color: Colors.grey)),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    TextEditingController nameCtrl = TextEditingController(
                                      text: state.characters[state.selectedCharIndex].name.isEmpty
                                          ? "캐릭터 #${state.selectedCharIndex + 1}"
                                          : state.characters[state.selectedCharIndex].name,
                                    );
                                    showDialog(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        backgroundColor: const Color(0xFF1E1E1E),
                                        title: const Text(
                                          "캐릭터 이름 수정",
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        content: TextField(
                                          controller: nameCtrl,
                                          maxLength: 10,
                                          style: const TextStyle(color: Colors.white),
                                          decoration: const InputDecoration(
                                            counterText: "",
                                            hintText: "새 이름 입력",
                                            hintStyle: TextStyle(color: Colors.white30),
                                            enabledBorder: UnderlineInputBorder(
                                              borderSide: BorderSide(
                                                color: Colors.deepPurpleAccent,
                                              ),
                                            ),
                                            focusedBorder: UnderlineInputBorder(
                                              borderSide: BorderSide(
                                                color: Colors.deepPurpleAccent,
                                                width: 2,
                                              ),
                                            ),
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(ctx),
                                            child: const Text(
                                              "취소",
                                              style: TextStyle(color: Colors.grey),
                                            ),
                                          ),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.deepPurpleAccent,
                                            ),
                                            onPressed: () {
                                              state.characters[state.selectedCharIndex].name =
                                                  nameCtrl.text.trim();
                                              state.saveAllSettings();
                                              state.refreshUI();
                                              Navigator.pop(ctx);
                                            },
                                            child: const Text(
                                              "저장",
                                              style: TextStyle(color: Colors.white),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.deepPurple.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.person,
                                          color: Colors.deepPurpleAccent,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          state.characters[state.selectedCharIndex].name.isEmpty
                                              ? "캐릭터 #${state.selectedCharIndex + 1}"
                                              : state.characters[state.selectedCharIndex].name,
                                          style: const TextStyle(
                                            color: Colors.deepPurpleAccent,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Builder(
                                  builder: (context) {
                                    bool isCurrentActive =
                                        state.characters[state.selectedCharIndex].isActive;
                                    return IconButton(
                                      icon: Icon(
                                        isCurrentActive ? Icons.visibility : Icons.visibility_off,
                                        color: isCurrentActive
                                            ? Colors.deepPurpleAccent
                                            : Colors.grey,
                                      ),
                                      tooltip: isCurrentActive ? "캐릭터 끄기" : "캐릭터 켜기",
                                      onPressed: () {
                                        state.characters[state.selectedCharIndex].isActive =
                                            !isCurrentActive;
                                        state.saveAllSettings();
                                        state.refreshUI();
                                      },
                                    );
                                  },
                                ),
                              ],
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.redAccent),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    backgroundColor: const Color(0xFF1E1E1E),
                                    title: const Text(
                                      "캐릭터 삭제",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    content: const Text(
                                      "이 캐릭터를 정말 삭제하시겠습니까?",
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text(
                                          "취소",
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                      ),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.redAccent,
                                        ),
                                        onPressed: () {
                                          state.characters.removeAt(state.selectedCharIndex);
                                          // 🚀 Linter 규칙 준수: 중괄호 추가
                                          if (state.selectedCharIndex > 0) {
                                            state.selectedCharIndex--;
                                          }
                                          if (state.characters.isEmpty) {
                                            state.characters.add(NaiCharacter());
                                          }
                                          state.saveAllSettings();
                                          state.refreshUI();
                                          Navigator.pop(ctx);
                                        },
                                        child: const Text(
                                          "삭제",
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _buildPromptCard(
                          title: "캐릭터 긍정 프롬프트",
                          icon: Icons.add_circle_outline,
                          color: const Color(0xFF00BFA5),
                          text: state.characters[state.selectedCharIndex].positive,
                          onTap: () => _showPromptEditDialog(
                            context,
                            state,
                            "긍정적 프롬프트",
                            Icons.add_circle_outline,
                            const Color(0xFF00BFA5),
                            state.characters[state.selectedCharIndex].positive,
                            (val) {
                              state.characters[state.selectedCharIndex].positive = val;
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildPromptCard(
                          title: "캐릭터 부정 프롬프트",
                          icon: Icons.remove_circle_outline,
                          color: const Color(0xFFE57373),
                          text: state.characters[state.selectedCharIndex].negative,
                          onTap: () => _showPromptEditDialog(
                            context,
                            state,
                            "부정적 프롬프트",
                            Icons.remove_circle_outline,
                            const Color(0xFFE57373),
                            state.characters[state.selectedCharIndex].negative,
                            (val) {
                              state.characters[state.selectedCharIndex].negative = val;
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A35),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.location_on_outlined, color: Colors.white54),
                                  SizedBox(width: 8),
                                  Text(
                                    "캐릭터 위치 설정",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Container(
                                    width: 65,
                                    height: 65,
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E1E28),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: Colors.deepPurple.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: GridView.builder(
                                      physics: const NeverScrollableScrollPhysics(),
                                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 5,
                                        crossAxisSpacing: 2,
                                        mainAxisSpacing: 2,
                                      ),
                                      itemCount: 25,
                                      itemBuilder: (context, index) {
                                        int x = index % 5;
                                        int y = index ~/ 5;
                                        bool isSelected =
                                            (x == state.characters[state.selectedCharIndex].gridX &&
                                            y == state.characters[state.selectedCharIndex].gridY);
                                        return Container(
                                          decoration: BoxDecoration(
                                            color: isSelected
                                                ? Colors.deepPurpleAccent
                                                : Colors.transparent,
                                            border: Border.all(
                                              color: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                                            ),
                                            borderRadius: BorderRadius.circular(2),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Column(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black26,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          "X: ${state.characters[state.selectedCharIndex].gridX + 1}  Y: ${state.characters[state.selectedCharIndex].gridY + 1}",
                                          style: const TextStyle(color: Colors.white),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ElevatedButton.icon(
                                        onPressed: () => _showLocationDialog(context, state),
                                        icon: const Icon(Icons.edit, size: 16),
                                        label: const Text("위치 수정"),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.deepPurpleAccent,
                                          foregroundColor: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
