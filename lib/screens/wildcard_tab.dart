import 'dart:math'; // 🚀 max() 함수를 쓰기 위해 추가
import '../utils/prompt_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

class WildcardTab extends StatefulWidget {
  const WildcardTab({super.key});

  @override
  State<WildcardTab> createState() => _WildcardTabState();
}

class _WildcardTabState extends State<WildcardTab> {
  late TextEditingController _contentController;
  late FocusNode _focusNode;
  List<String> _suggestions = [];
  NaiWildcard? _lastSelectedCard;

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController();
    _focusNode = FocusNode();

    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted) setState(() => _suggestions.clear());
        });
      }
    });
  }

  @override
  void dispose() {
    _contentController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged(AppState state) {
    String text = _contentController.text;
    int cursor = _contentController.selection.baseOffset;
    if (cursor < 0) cursor = text.length;

    String beforeCursor = text.substring(0, cursor);

    // 🚀 쉼표, 콜론, 줄바꿈, 괄호 인식!
    int lastNewline = beforeCursor.lastIndexOf('\n');
    int lastComma = beforeCursor.lastIndexOf(',');
    int lastColon = beforeCursor.lastIndexOf(':');
    int lastParen = beforeCursor.lastIndexOf(')');
    int lastDelimiter = max(lastNewline, max(lastComma, max(lastColon, lastParen)));

    String currentWord = lastDelimiter == -1
        ? beforeCursor
        : beforeCursor.substring(lastDelimiter + 1);

    currentWord = currentWord.trimLeft();

    if (currentWord.isEmpty) {
      setState(() {
        _suggestions = [];
      });
      return;
    }

    // 🚀 [추가] 와일드카드 자동완성 로직
    if (currentWord.startsWith('__')) {
      String searchWord = currentWord.replaceAll('__', '').toLowerCase();
      List<String> matches = state.wildcards
          .where((w) => w.name.toLowerCase().startsWith(searchWord))
          .map((w) => "__${w.name}__")
          .take(15)
          .toList();

      setState(() {
        _suggestions = matches;
      });
      return;
    }

    List<String> matches = state.danbooruTags
        .where((t) => t.toLowerCase().startsWith(currentWord.toLowerCase()))
        .take(15)
        .toList();

    setState(() {
      _suggestions = matches;
    });
  }

  void _insertTag(String tag, AppState state) {
    String text = _contentController.text;
    int cursor = _contentController.selection.baseOffset;
    if (cursor < 0) cursor = text.length;

    String beforeCursor = text.substring(0, cursor);
    String afterCursor = text.substring(cursor);
    String newBefore = PromptUtils.buildCompletedText(beforeCursor, tag);

    _contentController.value = TextEditingValue(
      text: newBefore + afterCursor,
      selection: TextSelection.collapsed(offset: newBefore.length),
    );

    setState(() {
      _suggestions.clear();
    });
    state.wildcards[state.selectedWildcardIndex].content = _contentController.text;
    state.saveAllSettings();
  }

  void _showCreateDialog(BuildContext context, AppState state) {
    TextEditingController nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          "새 와일드카드 생성",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: nameController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "이름 입력 (예: 의상, 배경)",
            hintStyle: TextStyle(color: Colors.white30),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.deepPurpleAccent),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.deepPurpleAccent, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
            onPressed: () {
              String newName = nameController.text.trim();
              if (newName.isNotEmpty) {
                state.wildcards.insert(0, NaiWildcard(name: newName, content: ""));
                state.selectedWildcardIndex = 0;
                state.saveAllSettings();
                state.refreshUI();
              }
              Navigator.pop(ctx);
            },
            child: const Text("생성", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showEditNameDialog(BuildContext context, AppState state) {
    TextEditingController nameController = TextEditingController(
      text: state.wildcards[state.selectedWildcardIndex].name,
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          "이름 수정",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: nameController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "새 이름 입력",
            hintStyle: TextStyle(color: Colors.white30),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.deepPurpleAccent),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.deepPurpleAccent, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
            onPressed: () {
              state.wildcards[state.selectedWildcardIndex].name = nameController.text.trim();
              state.saveAllSettings();
              state.refreshUI();
              Navigator.pop(ctx);
            },
            child: const Text("저장", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.wildcards.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        state.wildcards.add(NaiWildcard(name: "기본", content: ""));
        state.selectedWildcardIndex = 0;
        state.refreshUI();
      });
      return const SizedBox();
    }

    if (state.selectedWildcardIndex >= state.wildcards.length) {
      state.selectedWildcardIndex = state.wildcards.length - 1;
    }

    final currentCard = state.wildcards[state.selectedWildcardIndex];

    if (_lastSelectedCard != currentCard) {
      _lastSelectedCard = currentCard;
      _contentController.text = currentCard.content;
      _suggestions.clear();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              InkWell(
                onTap: () => _showCreateDialog(context, state),
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.deepPurpleAccent, width: 2),
                    color: Colors.deepPurpleAccent.withValues(alpha: 0.1),
                  ),
                  child: const Icon(Icons.add, size: 28, color: Colors.deepPurpleAccent),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    border: Border.all(
                      color: Colors.deepPurpleAccent.withValues(alpha: 0.5),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: state.selectedWildcardIndex,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1E1E1E),
                      icon: const Icon(Icons.keyboard_arrow_down, color: Colors.deepPurpleAccent),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                      items: List.generate(
                        state.wildcards.length,
                        (index) => DropdownMenuItem(
                          value: index,
                          child: Text(
                            state.wildcards[index].name.isEmpty
                                ? "이름 없음"
                                : state.wildcards[index].name,
                          ),
                        ),
                      ),
                      onChanged: (val) {
                        if (val != null) state.selectWildcard(val);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () {
                  String formattedName = "__${currentCard.name}__";
                  Clipboard.setData(ClipboardData(text: formattedName));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(milliseconds: 2400),
                      content: Text("'$formattedName' 복사 완료!"),
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.deepPurpleAccent),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(0, 44),
                ),
                child: const Text(
                  "복사",
                  style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF1E1E1E),
                      title: const Text(
                        "삭제 확인",
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      content: const Text("삭제하시겠습니까?", style: TextStyle(color: Colors.white70)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text("취소", style: TextStyle(color: Colors.grey)),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                          onPressed: () {
                            state.deleteWildcard(state.selectedWildcardIndex);
                            Navigator.pop(ctx);
                          },
                          child: const Text("삭제", style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Icon(Icons.delete, color: Colors.redAccent, size: 22),
                ),
              ),
              InkWell(
                onTap: () => _showEditNameDialog(context, state),
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Icon(Icons.edit, color: Color(0xFF29B6F6), size: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            height: 420,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF00BFA5).withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BFA5).withValues(alpha: 0.15),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.view_list, color: Color(0xFF00BFA5), size: 20),
                      SizedBox(width: 8),
                      Text(
                        "랜덤 프롬프트 목록 (줄바꿈으로 구분)",
                        style: TextStyle(
                          color: Color(0xFF00BFA5),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),

                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: _suggestions.isNotEmpty ? 40 : 0,
                  margin: EdgeInsets.only(
                    top: _suggestions.isNotEmpty ? 8 : 0,
                    left: 16,
                    right: 16,
                  ),
                  child: _suggestions.isNotEmpty
                      ? ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: _suggestions.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: ActionChip(
                                label: Text(
                                  _suggestions[index],
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                backgroundColor: const Color(0xFF00BFA5).withValues(alpha: 0.2),
                                side: const BorderSide(color: Color(0xFF00BFA5), width: 1.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                onPressed: () => _insertTag(_suggestions[index], state),
                              ),
                            );
                          },
                        )
                      : const SizedBox.shrink(),
                ),

                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 16.0),
                    child: TextField(
                      controller: _contentController,
                      focusNode: _focusNode,
                      maxLines: null,
                      expands: true,
                      style: const TextStyle(color: Colors.white, height: 1.6, fontSize: 14),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: "100) school uniform\n200) maid outfit\nbikini\n...",
                        hintStyle: TextStyle(color: Colors.white30),
                      ),
                      onChanged: (val) {
                        _onTextChanged(state);
                        state.wildcards[state.selectedWildcardIndex].content = val;
                        state.saveAllSettings();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF00BFA5).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF00BFA5).withValues(alpha: 0.3)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "💡 가중치(확률) 가이드",
                  style: TextStyle(
                    color: Color(0xFF00BFA5),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  "숫자)태그명 → 숫자가 높을수록 나올 확률이 증가합니다.",
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  "예시:\n200) dog ears (나올 확률 2배)\n50) fox ears (나올 확률 절반)\ncat ears (숫자가 없으면 기본값 100)",
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
