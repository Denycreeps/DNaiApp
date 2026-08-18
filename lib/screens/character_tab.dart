import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/nai_character.dart';
import 'prompt_edit_dialog.dart';

class CharacterTab extends StatefulWidget {
  const CharacterTab({super.key});

  @override
  State<CharacterTab> createState() => _CharacterTabState();
}

class _CharacterTabState extends State<CharacterTab> {
  bool _isGridActive = false; // 그리드에서 캐릭터 선택됨 (이동 대기)

  // 프롬프트 입력 다이얼로그 — 공용 구현(prompt_edit_dialog.dart)을 사용한다.
  //  캐릭터 탭은 값+콜백 방식으로 호출하므로, 임시 컨트롤러를 만들어 연결한다.
  void _showPromptEditDialog(
    BuildContext context,
    AppState state,
    String title,
    IconData icon,
    Color color,
    String currentText,
    ValueChanged<String> onSaved,
  ) {
    final tc = TextEditingController(text: currentText);
    // 입력 내용을 실시간으로 콜백에 전달 (공용 다이얼로그는 컨트롤러 기반)
    tc.addListener(() => onSaved(tc.text));
    showPromptEditDialog(context, state, title, icon, color, tc);
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

  // 선택된 캐릭터를 위(-1)/아래(+1)로 한 칸 이동.
  // 캐릭터 순서 = 생성 시 배치 순서라, 프롬프트를 안 바꾸고도 좌우 배치를 조정할 수 있다.
  void _moveCharacter(AppState state, int direction) {
    final from = state.selectedCharIndex;
    final to = from + direction;
    if (to < 0 || to >= state.characters.length) {
      return;
    }
    setState(() {
      final moved = state.characters.removeAt(from);
      state.characters.insert(to, moved);
      state.selectedCharIndex = to; // 선택이 옮긴 캐릭터를 계속 따라가게
      state.saveAllSettings();
      state.refreshUI();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Column(
      children: [
        // 캐릭터 에디터 (먼저)
        Container(
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
                constraints: const BoxConstraints(maxHeight: 420),
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
                          setState(() {
                            if (isSelected && state.charRetapToggle) {
                              // 이미 선택된 상태에서 한 번 더 누르면 ON/OFF
                              // (설정에서 끌 수 있다 — 오조작 방지)
                              state.characters[index].isActive = !state.characters[index].isActive;
                            } else {
                              state.selectedCharIndex = index;
                            }
                            _isGridActive = false; // 상단 목록에서 선택 시 그리드 선택 해제
                            state.refreshUI();
                          });
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
                              backgroundColor: isActive
                                  ? Colors.deepPurpleAccent
                                  : Colors.grey[700],
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
                                Expanded(
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: GestureDetector(
                                          onTap: () {
                                            TextEditingController nameCtrl = TextEditingController(
                                              text:
                                                  state
                                                      .characters[state.selectedCharIndex]
                                                      .name
                                                      .isEmpty
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
                                                      state
                                                          .characters[state.selectedCharIndex]
                                                          .name = nameCtrl.text
                                                          .trim();
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
                                            ).then((_) => nameCtrl.dispose());
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
                                                Flexible(
                                                  child: Text(
                                                    state
                                                            .characters[state.selectedCharIndex]
                                                            .name
                                                            .isEmpty
                                                        ? "캐릭터 #${state.selectedCharIndex + 1}"
                                                        : state
                                                              .characters[state.selectedCharIndex]
                                                              .name,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      color: Colors.deepPurpleAccent,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Builder(
                                        builder: (context) {
                                          bool isCurrentActive =
                                              state.characters[state.selectedCharIndex].isActive;
                                          return IconButton(
                                            icon: Icon(
                                              isCurrentActive
                                                  ? Icons.visibility
                                                  : Icons.visibility_off,
                                              color: isCurrentActive
                                                  ? Colors.deepPurpleAccent
                                                  : Colors.grey,
                                              size: 20,
                                            ),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 34,
                                              minHeight: 34,
                                            ),
                                            visualDensity: VisualDensity.compact,
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
                                      // 순서 위로 (왼쪽으로 배치) — 첫 번째면 비활성
                                      IconButton(
                                        icon: const Icon(Icons.keyboard_arrow_up, size: 22),
                                        color: state.selectedCharIndex > 0
                                            ? Colors.white70
                                            : Colors.white24,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 30,
                                          minHeight: 34,
                                        ),
                                        visualDensity: VisualDensity.compact,
                                        tooltip: "순서 위로",
                                        onPressed: state.selectedCharIndex > 0
                                            ? () => _moveCharacter(state, -1)
                                            : null,
                                      ),
                                      // 순서 아래로 (오른쪽으로 배치) — 마지막이면 비활성
                                      IconButton(
                                        icon: const Icon(Icons.keyboard_arrow_down, size: 22),
                                        color: state.selectedCharIndex < state.characters.length - 1
                                            ? Colors.white70
                                            : Colors.white24,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 30,
                                          minHeight: 34,
                                        ),
                                        visualDensity: VisualDensity.compact,
                                        tooltip: "순서 아래로",
                                        onPressed:
                                            state.selectedCharIndex < state.characters.length - 1
                                            ? () => _moveCharacter(state, 1)
                                            : null,
                                      ),
                                    ],
                                  ),
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
                                              // Linter 규칙 준수: 중괄호 추가
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
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),

        // 캐릭터 위치 미리보기 그리드 (맨 아래)
        if (state.characters.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.grid_on, color: Colors.deepPurpleAccent, size: 16),
                    const SizedBox(width: 6),
                    const Text(
                      "캐릭터 배치",
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    // 랜덤 배치 ON/OFF (배치 적용과 상호 배타 — 켜면 상대가 꺼짐)
                    GestureDetector(
                      onTap: () {
                        state.setRandomCharacterOrder(!state.randomCharacterOrder);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: state.randomCharacterOrder
                              ? const Color(0xFF3B82F6).withValues(alpha: 0.15)
                              : Colors.transparent,
                          border: Border.all(
                            color: state.randomCharacterOrder
                                ? const Color(0xFF3B82F6)
                                : Colors.white24,
                          ),
                        ),
                        child: Text(
                          "랜덤 배치",
                          style: TextStyle(
                            color: state.randomCharacterOrder
                                ? const Color(0xFF3B82F6)
                                : Colors.white54,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // 배치 적용 ON/OFF
                    GestureDetector(
                      onTap: () {
                        state.setUseCharacterPosition(!state.useCharacterPosition);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: state.useCharacterPosition
                              ? const Color(0xFF8B5CF6).withValues(alpha: 0.15)
                              : Colors.transparent,
                          border: Border.all(
                            color: state.useCharacterPosition
                                ? const Color(0xFF8B5CF6)
                                : Colors.white24,
                          ),
                        ),
                        child: Text(
                          "배치 적용",
                          style: TextStyle(
                            color: state.useCharacterPosition
                                ? const Color(0xFF8B5CF6)
                                : Colors.white54,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // 위치 초기화
                    GestureDetector(
                      onTap: () {
                        for (final char in state.characters) {
                          char.gridX = 2;
                          char.gridY = 2;
                        }
                        state.saveAllSettings();
                        state.refreshUI();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Text(
                          "위치 초기화",
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                AspectRatio(
                  aspectRatio: 5 / 5,
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      crossAxisSpacing: 3,
                      mainAxisSpacing: 3,
                    ),
                    itemCount: 25,
                    itemBuilder: (context, index) {
                      int gx = index % 5;
                      int gy = index ~/ 5;

                      // 활성 캐릭터만 그리드에 표시
                      List<int> charsHere = [];
                      for (int ci = 0; ci < state.characters.length; ci++) {
                        if (state.characters[ci].isActive &&
                            state.characters[ci].gridX == gx &&
                            state.characters[ci].gridY == gy) {
                          charsHere.add(ci);
                        }
                      }

                      bool isSelected =
                          _isGridActive && charsHere.contains(state.selectedCharIndex);

                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (charsHere.isNotEmpty) {
                              if (isSelected && charsHere.length > 1) {
                                // 같은 칸에 여러 캐릭터 → 순환 선택
                                int curIdx = charsHere.indexOf(state.selectedCharIndex);
                                state.selectedCharIndex =
                                    charsHere[(curIdx + 1) % charsHere.length];
                              } else if (isSelected) {
                                // 이미 선택된 캐릭터 다시 탭 → 선택 해제
                                _isGridActive = false;
                              } else if (_isGridActive) {
                                // 다른 캐릭터 탭 → 자리 교환 + 선택 해제
                                final myChar = state.characters[state.selectedCharIndex];
                                final otherChar = state.characters[charsHere.first];
                                final tempX = myChar.gridX;
                                final tempY = myChar.gridY;
                                myChar.gridX = otherChar.gridX;
                                myChar.gridY = otherChar.gridY;
                                otherChar.gridX = tempX;
                                otherChar.gridY = tempY;
                                _isGridActive = false;
                                state.saveAllSettings();
                              } else {
                                // 선택 안 된 상태 → 선택
                                state.selectedCharIndex = charsHere.first;
                                _isGridActive = true;
                              }
                            } else {
                              // 빈 칸 탭: 선택된 캐릭터가 있으면 이동
                              if (_isGridActive &&
                                  state.selectedCharIndex < state.characters.length) {
                                state.characters[state.selectedCharIndex].gridX = gx;
                                state.characters[state.selectedCharIndex].gridY = gy;
                                _isGridActive = false;
                                state.saveAllSettings();
                              }
                            }
                            state.refreshUI();
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: charsHere.isNotEmpty
                                ? (isSelected
                                      ? Colors.deepPurpleAccent.withValues(alpha: 0.4)
                                      : Colors.deepPurpleAccent.withValues(alpha: 0.15))
                                : Colors.white.withValues(alpha: 0.03),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.deepPurpleAccent
                                  : Colors.white.withValues(alpha: 0.1),
                              width: isSelected ? 1.5 : 0.5,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Center(
                            child: charsHere.isNotEmpty
                                ? Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: charsHere
                                        .map(
                                          (i) => Text(
                                            "C${i + 1}",
                                            style: TextStyle(
                                              color: (_isGridActive && state.selectedCharIndex == i)
                                                  ? Colors.white
                                                  : Colors.white38,
                                              fontSize: charsHere.length > 2
                                                  ? 8
                                                  : (charsHere.length > 1 ? 9 : 11),
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        )
                                        .toList(),
                                  )
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    ); // Column closing
  }
}
