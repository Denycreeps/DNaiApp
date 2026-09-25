import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/preset_models.dart';
import '../app_theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/app_toast.dart';
import 'dart:async'; // unawaited
import 'package:image_picker/image_picker.dart';
import 'dart:convert'; // 미리보기 base64
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import '../models/prompt_dict.dart';
import '../utils/ui_safety.dart';
import 'prompt_edit_dialog.dart'; // 모든 프롬프트 칸이 같은 확대 입력창을 쓴다
import '../widgets/dict_image_viewer.dart'; // 사전 이미지 크게 보기
import '../utils/image_codec.dart'; // WebP 굽기 (한곳)

class WildcardTab extends StatefulWidget {
  const WildcardTab({super.key});

  @override
  State<WildcardTab> createState() => _WildcardTabState();
}

class _WildcardTabState extends State<WildcardTab> with SingleTickerProviderStateMixin {
  late TextEditingController _contentController;
  // initState 에서 한 번 잡아 둔다.
  //  ⚠️ 리스너 안에서 context.read 를 쓰면 안 된다 — 카드를 바꿀 때 build 도중에
  //     _contentController.text 를 넣는데, 그 순간 리스너가 불려 'build 중 read' 가 된다.
  //     Provider 는 디버그 모드에서 이것을 오류로 막는다.
  late final AppState _appState;
  NaiWildcard? _lastSelectedCard;

  // 안쪽 탭: 0 와일드카드 / 1 프롬프트 사전
  late TabController _subTab;
  // 사전 탭을 한 번이라도 열었는지 (안 열었으면 만들지 않는다 — 미리보기 디코딩 절약)
  bool _dictVisited = false;
  // 지금 화면에 보여 주고 있는 안쪽 탭 (리스너 중복 호출 걸러내기용)
  int _shownSubTab = 0;
  // 사전 분류 칩: 전체 / 미분류 / 분류 id
  String _dictFilter = kDictFilterAll;

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppState>(); // initState 에서는 read 가 허용된다
    _contentController = TextEditingController();
    // 확대 입력창에서 고치는 즉시 지금 와일드카드에 반영한다.
    //  ⚠️ 창이 닫힐 때 옮기면 늦다 — 입력창은 닫히는 '순간' 저장하는데,
    //     그때 아직 옛 내용이면 옛 내용이 저장된다. (저장은 입력창이 모아서 한다)
    _contentController.addListener(_syncWildcardContent);
    // 마지막으로 본 쪽에서 시작한다 (탭을 떠났다 오면 이 화면이 새로 만들어진다)
    final start = _appState.wildcardSubTab;
    _subTab = TabController(length: 2, vsync: this, initialIndex: start);
    _shownSubTab = start;
    _dictVisited = start == 1;
    _subTab.addListener(() {
      // ⚠️ indexIsChanging 을 기다리지 않는다.
      //    예전엔 '밑줄 애니메이션이 끝난 뒤'에만 내용을 바꿔서, 누르고 나서
      //    0.3초 넘게 지나야 화면이 바뀌어 반응이 굼뜨게 느껴졌다.
      //    index 는 누르는 순간 이미 바뀌어 있으므로 그때 바로 바꾼다.
      //    (애니메이션 동안 리스너가 여러 번 불리므로 실제로 바뀔 때만 처리)
      if (_subTab.index == _shownSubTab) {
        return;
      }
      _shownSubTab = _subTab.index;
      _appState.setWildcardSubTab(_subTab.index);
      setState(() {
        if (_subTab.index == 1) {
          _dictVisited = true;
        }
      });
    });
  }

  @override
  void dispose() {
    _contentController.dispose();
    _subTab.dispose();
    super.dispose();
  }

  /// 입력창 내용을 지금 고른 와일드카드에 옮긴다 (저장은 확대 입력창이 모아서 한다).
  void _syncWildcardContent() {
    if (!mounted) {
      return;
    }
    final state = _appState;
    final i = state.selectedWildcardIndex;
    if (i < 0 || i >= state.wildcards.length) {
      return;
    }
    if (state.wildcards[i].content != _contentController.text) {
      state.wildcards[i].content = _contentController.text;
    }
  }

  void _showCreateDialog(BuildContext context, AppState state) {
    TextEditingController nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          "새 와일드카드 생성",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: nameController,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: "이름 입력 (예: 의상, 배경)",
            hintStyle: TextStyle(color: Colors.white30),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.accent, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
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
    ).then((_) {
      // 다이얼로그가 완전히 닫힌 뒤에 정리 (닫히는 중에 버리면 예외가 난다)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        nameController.dispose();
      });
    });
  }

  void _showEditNameDialog(BuildContext context, AppState state) {
    TextEditingController nameController = TextEditingController(
      text: state.wildcards[state.selectedWildcardIndex].name,
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          "이름 수정",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: nameController,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: "새 이름 입력",
            hintStyle: TextStyle(color: Colors.white30),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.accent, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () {
              final card = state.wildcards[state.selectedWildcardIndex];
              final newName = nameController.text.trim();
              // 되돌리기 기록은 이름으로 묶여 있어 함께 옮긴다
              state.renameUndoKey('wildcard/${card.name}', 'wildcard/$newName');
              card.name = newName;
              state.saveAllSettings();
              state.refreshUI();
              Navigator.pop(ctx);
            },
            child: const Text("저장", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ).then((_) {
      // 다이얼로그가 완전히 닫힌 뒤에 정리 (닫히는 중에 버리면 예외가 난다)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        nameController.dispose();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final page = _subTab.index;

    // ⚠️ 이 탭은 main.dart 에서 SingleChildScrollView 로 감싸여 있다.
    //    그래서 TabBarView 나 세로 Expanded 처럼 '높이가 정해져야' 하는 위젯을
    //    쓰면 안 된다 (높이가 무한이라 그리는 순간 멈춘다).
    //    탭 바는 모양만 쓰고, 내용은 Offstage 로 바꿔 끼운다.
    //    두 페이지 모두 트리에 남아 있으므로 와일드카드 입력 내용도 그대로 유지된다.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabBar(
          controller: _subTab,
          indicatorColor: AppColors.accent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: "와일드카드"),
            Tab(text: "프롬프트 사전"),
          ],
        ),
        const SizedBox(height: 8),
        Offstage(offstage: page != 0, child: _buildWildcardPage(context, state)),
        Offstage(
          offstage: page != 1,
          child: _dictVisited ? _buildPromptDictPage(context, state) : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildWildcardPage(BuildContext context, AppState state) {
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
                    border: Border.all(color: AppColors.accent, width: 2),
                    color: AppColors.accent.withValues(alpha: 0.1),
                  ),
                  child: Icon(Icons.add, size: 28, color: AppColors.accent),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    border: Border.all(color: AppColors.accent.withValues(alpha: 0.5), width: 2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: state.selectedWildcardIndex,
                      isExpanded: true,
                      dropdownColor: AppColors.surface,
                      icon: Icon(Icons.keyboard_arrow_down, color: AppColors.accent),
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
                  showToast(context, "'$formattedName' 복사 완료!");
                },
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppColors.accent),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(0, 44),
                ),
                child: Text(
                  "복사",
                  style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () async {
                  final ok = await showConfirmDialog(
                    context,
                    title: "와일드카드 삭제",
                    message: "'${state.wildcards[state.selectedWildcardIndex].name}' 을(를) 삭제할까요?",
                    confirmLabel: "삭제",
                    icon: Icons.delete_outline,
                  );
                  if (ok) {
                    state.deleteWildcard(state.selectedWildcardIndex);
                  }
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
                  child: Icon(Icons.edit, color: AppColors.blue, size: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            height: 420,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.teal.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.teal.withValues(alpha: 0.15),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.view_list, color: AppColors.teal, size: 20),
                      SizedBox(width: 8),
                      Text(
                        "랜덤 프롬프트 목록 (줄바꿈으로 구분)",
                        style: TextStyle(
                          color: AppColors.teal,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Spacer(),
                      // 아래 목록을 누르면 확대 입력창이 열린다는 표시
                      Icon(Icons.edit, color: AppColors.teal, size: 16),
                    ],
                  ),
                ),

                Expanded(
                  // ⚠️ 예전엔 여기에 와일드카드만의 입력칸(자동완성 줄 포함)이 따로 있었다.
                  //    이제 다른 프롬프트 칸과 같은 확대 입력창을 연다 — 입력창 구현이 하나라
                  //    고칠 곳도 하나고, 되돌리기·사전 불러오기·전부 지우기도 함께 쓸 수 있다.
                  //    (옛 입력칸은 글자 하나 칠 때마다 설정 116개를 통째로 저장했다.
                  //     확대 입력창은 0.5초씩 모아서 저장한다)
                  child: InkWell(
                    onTap: () => showPromptEditDialog(
                      context,
                      state,
                      "와일드카드: ${currentCard.name}",
                      Icons.view_list,
                      AppColors.teal,
                      _contentController,
                      // 이름으로 묶는다 (지우거나 이름을 바꾸면 pruneUndoKeys 로 정리)
                      undoKey: 'wildcard/${currentCard.name}',
                    ),
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                      child: SingleChildScrollView(
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(
                            _contentController.text.isEmpty
                                ? "눌러서 입력…\n\n100) school uniform\n200) maid outfit\nbikini\n..."
                                : _contentController.text,
                            style: TextStyle(
                              color: _contentController.text.isEmpty
                                  ? Colors.white30
                                  : Colors.white,
                              height: 1.6,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
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
              color: AppColors.teal.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.teal.withValues(alpha: 0.3)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "💡 가중치(확률) 가이드",
                  style: TextStyle(
                    color: AppColors.teal,
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

  // ══════════════════════════════════════════════════════════════
  // 프롬프트 사전
  // ══════════════════════════════════════════════════════════════
  //  ⚠️ 이 페이지도 스크롤 뷰 안에 있다. ListView/Expanded(세로) 금지 —
  //     항목은 그냥 Column 에 쌓고, 스크롤은 바깥이 맡는다.

  Widget _buildPromptDictPage(BuildContext context, AppState state) {
    // 지웠던 분류를 보고 있었다면 전체로 되돌린다
    _dictFilter = state.validDictFilter(_dictFilter);
    final list = state.promptDict.where((e) => dictEntryMatches(e, _dictFilter)).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book, color: AppColors.accent, size: 18),
              const SizedBox(width: 6),
              Text("${list.length}개", style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => _showDictEditor(state),
                icon: const Icon(Icons.add, size: 18, color: Colors.white),
                label: const Text(
                  "프롬프트 저장",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _dictCategoryBar(state),
          const SizedBox(height: 10),
          if (list.isEmpty && state.promptDict.isNotEmpty)
            // 사전은 있는데 이 분류에만 없는 경우
            Container(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                "이 분류에는 아직 항목이 없습니다.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            )
          else if (list.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                "아직 저장한 프롬프트가 없습니다.\n"
                "자주 쓰는 캐릭터나 작가 태그를 '프롬프트 저장'으로 모아 두세요.\n"
                "마지막으로 생성한 이미지가 미리보기로 함께 저장됩니다.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.5),
              ),
            )
          else
            for (final e in list) _dictTile(state, e),
        ],
      ),
    );
  }

  /// 분류 칩 줄: [전체] [분류들…] [미분류] [+]
  ///  ⚠️ 가로 스크롤 — 세로 스크롤 뷰 안이지만 가로 폭은 정해져 있어 안전하다.
  Widget _dictCategoryBar(AppState state) {
    int countOf(String filter) => state.promptDict.where((e) => dictEntryMatches(e, filter)).length;

    Widget chip(String label, String filter, {VoidCallback? onLongPress}) {
      final selected = _dictFilter == filter;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onLongPress: onLongPress,
          child: ChoiceChip(
            label: Text("$label ${countOf(filter)}"),
            selected: selected,
            onSelected: (_) => setState(() => _dictFilter = filter),
            showCheckmark: false,
            labelStyle: TextStyle(
              color: selected ? Colors.white : Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
            backgroundColor: AppColors.surface,
            selectedColor: AppColors.accent.withValues(alpha: 0.35),
            side: BorderSide(color: selected ? AppColors.accent : Colors.white24),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          // 전체는 항상 맨 왼쪽
          chip("전체", kDictFilterAll),
          for (final c in state.promptDictCategories)
            chip(c.name, c.id, onLongPress: () => _showCategoryMenu(state, c)),
          // 미분류는 항상 '+' 바로 왼쪽
          chip("미분류", kDictFilterNone),
          ActionChip(
            label: const Icon(Icons.add, size: 16, color: Colors.white70),
            tooltip: "분류 추가",
            onPressed: () => _addCategory(state),
            backgroundColor: AppColors.surface,
            side: const BorderSide(color: Colors.white24),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// 분류 이름을 입력받는 작은 창. 취소하면 null.
  Future<String?> _askCategoryName({String initial = '', required String title}) async {
    final ctrl = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "예: 작가, 캐릭터, 의상",
            hintStyle: TextStyle(color: Colors.white30),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text("확인", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    // ⚠️ 닫히는 애니메이션이 끝난 뒤에 버린다 (DEVNOTES 1번)
    disposeAfterDialog(ctrl.dispose);
    return ok == true ? name : null;
  }

  Future<void> _addCategory(AppState state) async {
    final name = await _askCategoryName(title: "새 분류");
    if (name == null || !mounted) {
      return;
    }
    final c = state.addPromptDictCategory(name);
    if (c == null) {
      showToast(
        context,
        name.isEmpty ? "이름을 입력해 주세요." : "'$name' 은(는) 쓸 수 없는 이름입니다. (이미 있거나 예약된 이름)",
      );
      return;
    }
    // 만든 분류를 바로 보여 준다 (이어서 저장하면 그 분류로 들어간다)
    setState(() => _dictFilter = c.id);
  }

  /// 분류 칩을 꾹 눌렀을 때: 이름 바꾸기 / 삭제
  void _showCategoryMenu(AppState state, PromptDictCategory c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                "분류: ${c.name}",
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white70),
              title: const Text("이름 바꾸기", style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                final name = await _askCategoryName(initial: c.name, title: "분류 이름 바꾸기");
                if (name == null || !mounted) {
                  return;
                }
                if (!state.renamePromptDictCategory(c.id, name)) {
                  showToast(context, "'$name' 은(는) 쓸 수 없는 이름입니다. (이미 있거나 예약된 이름)");
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text("분류 삭제", style: TextStyle(color: Colors.redAccent)),
              subtitle: const Text(
                "안의 항목은 지우지 않고 미분류로 옮깁니다",
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showConfirmDialog(
                  context,
                  title: "분류 삭제",
                  message: "'${c.name}' 분류를 삭제할까요?\n안의 항목은 미분류로 옮겨집니다.",
                  confirmLabel: "삭제",
                  icon: Icons.delete_outline,
                );
                if (!ok || !mounted) {
                  return;
                }
                state.removePromptDictCategory(c.id);
                setState(() {
                  if (_dictFilter == c.id) {
                    _dictFilter = kDictFilterAll;
                  }
                });
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _dictTile(AppState state, PromptDictEntry e) {
    final thumb = state.dictThumb(e);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        // 탭하면 바로 편집 (이름·프롬프트·미리보기를 한 화면에서)
        onTap: () => _showDictEditor(state, editing: e),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 썸네일을 누르면 크게 보기 (나머지 부분을 누르면 편집)
              GestureDetector(
                onTap: thumb == null
                    ? null
                    : () => showDictImageViewer(
                        context,
                        title: e.displayTitle,
                        loadLarge: () => state.loadDictImage(e.id),
                        thumb: thumb,
                      ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: thumb != null
                        ? Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                        : Container(
                            color: AppColors.background,
                            child: const Icon(Icons.image_outlined, color: Colors.white24),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      e.prompt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.35),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Column(
                children: [
                  _dictActionButton(
                    "추가",
                    Icons.playlist_add,
                    AppColors.teal,
                    () => _appendDictEntry(state, e),
                  ),
                  const SizedBox(height: 6),
                  // 사전은 '조각'을 꺼내 쓰는 용도라 통째로 바꾸는 '교체' 대신
                  // 다른 입력창(캐릭터·부정 등)에 붙여 넣을 수 있게 '복사'를 둔다
                  _dictActionButton("복사", Icons.copy, AppColors.blue, () => _copyDictEntry(e)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dictActionButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 58,
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  /// 사전 항목을 긍정 프롬프트 뒤에 이어 붙인다.
  void _appendDictEntry(AppState state, PromptDictEntry e) {
    final ctrl = state.positiveController;
    final before = ctrl.text;
    // 붙이기 전 내용을 되돌리기 기록에 남긴다.
    //  → 프롬프트탭 확대 입력창의 '되돌리기'로 원래대로 돌아갈 수 있다.
    //    (열쇠는 프롬프트탭 긍정 입력창과 같아야 한다)
    state.pushPromptUndo(kPositiveUndoKey, before);
    ctrl.text = appendPromptPiece(before, e.prompt);
    state.saveAllSettings();
    state.refreshUI();
    showToast(context, "긍정 프롬프트 뒤에 '${e.displayTitle}'을(를) 붙였습니다.");
  }

  void _copyDictEntry(PromptDictEntry e) {
    Clipboard.setData(ClipboardData(text: e.prompt));
    showToast(context, "'${e.displayTitle}' 프롬프트를 복사했습니다.");
  }

  /// 새로 저장하거나([editing] == null) 기존 항목을 고친다.
  ///  프리셋 편집 창과 같은 배치 — 가운데 미리보기(탭하면 갤러리), 아래에 이름·프롬프트.
  Future<void> _showDictEditor(AppState state, {PromptDictEntry? editing}) async {
    final titleCtrl = TextEditingController(text: editing?.title ?? '');
    final promptCtrl = TextEditingController(
      text: editing?.prompt ?? state.positiveController.text,
    );

    // 분류: 고치는 중이면 그 항목의 분류, 새로 만들면 '지금 보고 있는 분류'
    //  (캐릭터 분류를 보다가 저장하면 캐릭터로 들어가는 게 자연스럽다.
    //   전체·미분류를 보고 있었으면 미분류)
    String? categoryId = editing != null
        ? editing.categoryId
        : (_dictFilter == kDictFilterAll || _dictFilter == kDictFilterNone ? null : _dictFilter);

    // 미리보기 상태 (창 안에서 바꿔도 '저장'을 누르기 전까지는 반영하지 않는다)
    String? thumb = editing?.thumbnail;
    Uint8List? thumbBytes = editing != null ? state.dictThumb(editing) : null;
    bool busy = false;
    bool open = true;
    StateSetter? setD;

    // 크게 볼 이미지 — 새로 고른 것 (저장을 누르기 전까지는 파일에 쓰지 않는다)
    Uint8List? pendingLarge;
    // 이번 창에서 이미지를 바꾸거나 지웠는지 (그대로면 저장할 때 파일을 건드리지 않는다)
    bool imageChanged = false;

    // 고른 그림으로 '크게 볼 이미지'와 '목록용 썸네일'을 함께 만든다.
    //  네이티브 WebP 인코더라 화면이 멈추지 않는다.
    //  인코더가 안 되는 기기면 옛 방식(isolate 에서 200px JPEG 썸네일)만 만든다 — 크게 보기는 썸네일로.
    Future<void> useImage(Uint8List src) async {
      busy = true;
      if (open) {
        setD?.call(() {});
      }
      final large = await makeDictLargeImage(src);
      final small = await makeDictThumb(large ?? src);
      final String? t = small != null
          ? base64Encode(small)
          : await compute(_legacyDictThumbJpeg, src);
      busy = false;
      // ⚠️ 그림을 전혀 읽지 못했으면 아무것도 바꾸지 않는다.
      //    그대로 '바뀜'으로 표시하면 저장할 때 원래 있던 이미지까지 지워진다
      //    (사용자는 바꾸려다 실패했을 뿐인데 기존 이미지를 잃는다).
      if (t == null) {
        if (open) {
          setD?.call(() {});
        }
        if (mounted) {
          showToast(context, "이미지를 읽지 못했습니다. 다른 이미지를 골라 주세요.");
        }
        return;
      }
      thumb = t;
      thumbBytes = base64Decode(t); // 위에서 null 을 이미 걸렀다
      pendingLarge = large;
      imageChanged = true;
      // 창이 닫힌 뒤에 끝났으면 다시 그리지 않는다
      if (open) {
        setD?.call(() {});
      }
    }

    // 지금 창에서 보이는 이미지를 크게 본다 (새로 고른 것이 있으면 그것, 없으면 저장된 파일)
    Future<void> viewLarge() => showDictImageViewer(
      context,
      title: titleCtrl.text.trim().isNotEmpty ? titleCtrl.text.trim() : "미리보기",
      loadLarge: () async {
        if (imageChanged) {
          return pendingLarge;
        }
        return editing == null ? null : state.loadDictImage(editing.id);
      },
      thumb: thumbBytes,
    );

    Future<void> pickFromGallery() async {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // 크게 볼 이미지로 쓰므로 원본에 가깝게 받는다.
        //  (카메라 사진처럼 아주 큰 그림은 받아 올 때부터 줄여 메모리를 아낀다)
        maxWidth: 2048,
        maxHeight: 2048,
      );
      if (picked == null) {
        return;
      }
      await useImage(await picked.readAsBytes());
    }

    // 새로 저장할 때는 마지막 생성 이미지를 기본 미리보기로 (창을 먼저 띄우고 뒤에서 만든다)
    if (editing == null && state.currentImageBytes != null) {
      unawaited(useImage(state.currentImageBytes!));
    }

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          setD = setDialogState;
          final hasLast = state.currentImageBytes != null;
          return AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(
              editing == null ? "프롬프트 저장" : "프롬프트 편집",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 미리보기 + 오른쪽에 버튼 세로로
                  //  (예전엔 미리보기 아래에 버튼을 가로로 늘어놓아, 좁은 화면에서 넘치고
                  //   미리보기 옆의 넓은 공간은 비어 있었다)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 이미지가 있으면 누르면 크게 보고, 없으면 갤러리에서 고른다
                      GestureDetector(
                        onTap: busy ? null : (thumbBytes != null ? viewLarge : pickFromGallery),
                        child: _dictPreviewBox(thumbBytes, busy),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _dictImageAction(
                              icon: Icons.photo_library_outlined,
                              label: "갤러리",
                              onPressed: busy ? null : pickFromGallery,
                            ),
                            if (hasLast)
                              _dictImageAction(
                                icon: Icons.auto_awesome,
                                label: "마지막 이미지",
                                onPressed: busy ? null : () => useImage(state.currentImageBytes!),
                              ),
                            if (thumbBytes != null)
                              _dictImageAction(
                                icon: Icons.close,
                                label: "지우기",
                                dim: true,
                                onPressed: busy
                                    ? null
                                    : () => setDialogState(() {
                                        thumb = null;
                                        thumbBytes = null;
                                        pendingLarge = null;
                                        imageChanged = true; // 저장하면 큰 이미지 파일도 지운다
                                      }),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const SizedBox(height: 4),
                  // 분류 고르기 — 누르면 목록이 펼쳐진다 (미분류가 기본)
                  //  칩을 늘어놓는 방식은 분류가 많아지면 창을 가득 채워서 목록으로 했다.
                  Row(
                    children: [
                      const Text("분류", style: TextStyle(color: Colors.white54, fontSize: 13)),
                      const SizedBox(width: 10),
                      Expanded(
                        // ⚠️ PopupMenuButton 은 메뉴를 '글자 길이만큼'만 그리고 버튼 오른쪽 끝에
                        //    붙여 띄워서, 긴 입력칸 옆에 쪼그만 목록이 떠 어색했다.
                        //    DropdownButton(isExpanded) 은 목록을 '버튼 너비 그대로' 버튼 위에 펼친다.
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              // 미분류는 null 이라 메뉴 값으로 쓸 수 없어 kDictFilterNone 로 대신한다
                              value: categoryId ?? kDictFilterNone,
                              isExpanded: true,
                              dropdownColor: AppColors.surface,
                              borderRadius: BorderRadius.circular(10),
                              // 분류가 많아도 화면을 다 덮지 않게 (그 안에서 스크롤)
                              menuMaxHeight: 320,
                              icon: const Icon(Icons.arrow_drop_down, color: Colors.white54),
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              onChanged: (v) => setDialogState(
                                () => categoryId = (v == null || v == kDictFilterNone) ? null : v,
                              ),
                              items: [
                                for (final c in state.promptDictCategories)
                                  DropdownMenuItem(
                                    value: c.id,
                                    child: Text(c.name, overflow: TextOverflow.ellipsis),
                                  ),
                                // 미분류는 항상 맨 아래 — 흐린 글씨와 아이콘으로 다른 분류와 구분한다
                                const DropdownMenuItem(
                                  value: kDictFilterNone,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.folder_off_outlined,
                                        size: 16,
                                        color: Colors.white38,
                                      ),
                                      SizedBox(width: 6),
                                      Text("미분류", style: TextStyle(color: Colors.white70)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: titleCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: "이름 (비우면 첫 태그)",
                      labelStyle: TextStyle(color: Colors.white54),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 프롬프트 — 다른 프롬프트 칸과 똑같은 확대 입력창으로 편집한다.
                  //  (자동완성 후보·가중치 색·되돌리기·사전 불러오기를 그대로 쓸 수 있다)
                  //  여기는 미리보기만 보여 주고, 누르면 확대 입력창이 열린다.
                  _promptPreviewBox(
                    label: "프롬프트",
                    text: promptCtrl.text,
                    color: AppColors.accent,
                    height: 110,
                    onTap: () async {
                      await showPromptEditDialog(
                        ctx,
                        state,
                        "사전 프롬프트",
                        Icons.menu_book,
                        AppColors.accent,
                        promptCtrl,
                        // 항목마다 되돌리기 기록을 따로 (새 항목은 'new' 한 칸을 같이 쓴다)
                        undoKey: 'dict/${editing?.id ?? 'new'}',
                      );
                      // 확대 입력창에서 고친 내용을 미리보기에 반영
                      if (open) {
                        setDialogState(() {});
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              if (editing != null)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'delete'),
                  child: const Text("삭제", style: TextStyle(color: Colors.redAccent)),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("취소", style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                // 미리보기를 만드는 중에는 저장을 막는다 (반쯤 된 값이 들어가지 않게)
                onPressed: busy ? null : () => Navigator.pop(ctx, 'save'),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
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
    open = false;

    // 값은 컨트롤러를 버리기 전에 꺼내 둔다
    final title = titleCtrl.text.trim();
    final prompt = promptCtrl.text.trim();
    // ⚠️ 닫히는 애니메이션이 끝난 뒤에 버린다 (DEVNOTES 1번)
    disposeAfterDialog(() {
      titleCtrl.dispose();
      promptCtrl.dispose();
    });

    if (!mounted) {
      return;
    }

    if (result == 'delete' && editing != null) {
      final ok = await showConfirmDialog(
        context,
        title: "프롬프트 사전 삭제",
        message: "'${editing.displayTitle}' 을(를) 삭제할까요?",
        confirmLabel: "삭제",
        icon: Icons.delete_outline,
      );
      if (!ok || !mounted) {
        return;
      }
      state.removePromptDictEntry(editing.id);
      return;
    }

    if (result != 'save') {
      return;
    }
    if (prompt.isEmpty) {
      showToast(context, "프롬프트가 비어 있어 저장하지 않았습니다.");
      return;
    }
    // 이름을 비워 두면 첫 태그를 이름으로 쓴다 ('miku, blue hair' → 'miku')
    final name = title.isNotEmpty ? title : PromptDictEntry.autoTitle(prompt);

    // 큰 이미지 파일을 먼저 반영한 뒤 목록을 바꾼다.
    //  (순서가 반대면 방금 저장한 항목을 바로 크게 볼 때 파일이 아직 없어 흐리게 보인다)
    //  이미지를 건드리지 않았으면 파일도 그대로 둔다.
    Future<void> applyLargeImage(String id) async {
      if (!imageChanged) {
        return;
      }
      final large = pendingLarge;
      if (large != null) {
        await state.saveDictImage(id, large);
      } else {
        await state.deleteDictImage(id);
      }
    }

    if (editing == null) {
      final entry = PromptDictEntry(
        title: name,
        prompt: prompt,
        thumbnail: thumb,
        categoryId: categoryId,
      );
      await applyLargeImage(entry.id);
      if (!mounted) {
        return;
      }
      state.addPromptDictEntry(entry);
      showToast(context, "'$name' 을(를) 저장했습니다.");
    } else {
      await applyLargeImage(editing.id);
      if (!mounted) {
        return;
      }
      editing
        ..title = name
        ..prompt = prompt
        ..thumbnail = thumb
        ..categoryId = categoryId;
      state.updatePromptDictEntry(editing);
      showToast(context, "수정했습니다.");
    }
  }

  /// 프롬프트 미리보기 칸 — 누르면 확대 입력창이 열린다.
  ///  사전 편집 창과 와일드카드 편집이 같은 모양을 쓴다 (프롬프트탭 카드와 같은 역할).
  ///  ⚠️ [height] 가 정해져 있어야 한다 — 스크롤 뷰 안에서 쓰이므로 무한 높이가 되면 멈춘다.
  Widget _promptPreviewBox({
    required String label,
    required String text,
    required Color color,
    required double height,
    required VoidCallback onTap,
    String hint = "눌러서 입력…",
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Icon(Icons.edit, size: 14, color: color),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  text.isEmpty ? hint : text,
                  style: TextStyle(
                    color: text.isEmpty ? Colors.white30 : Colors.white,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 사전 편집 창의 이미지 버튼 한 줄 (미리보기 오른쪽에 세로로 쌓인다)
  Widget _dictImageAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool dim = false,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: TextButton.styleFrom(
        foregroundColor: dim ? Colors.white54 : Colors.white70,
        // 왼쪽 정렬 — 세 버튼의 아이콘이 한 줄로 가지런히
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  /// 편집 창의 미리보기 칸 (프리셋 편집 창과 같은 100×100)
  Widget _dictPreviewBox(Uint8List? bytes, bool busy) {
    if (busy) {
      return Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
          ),
        ),
      );
    }
    if (bytes != null) {
      return Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              bytes,
              width: 100,
              height: 100,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
          // 탭하면 바꿀 수 있다는 표시
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.edit, size: 13, color: Colors.white70),
            ),
          ),
        ],
      );
    }
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_photo_alternate_outlined, color: Colors.white30, size: 28),
          SizedBox(height: 4),
          Text("미리보기 추가", style: TextStyle(color: Colors.white30, fontSize: 11)),
        ],
      ),
    );
  }
}

/// [대비책] 사전 썸네일을 옛 방식으로 만든다 (긴 변 200px JPEG → base64).
///  보통은 image_codec.dart 의 WebP 인코더를 쓰고, 그게 안 되는 기기에서만 여기를 쓴다.
///  compute 로 별도 isolate 에서 돌리므로 반드시 최상위 함수여야 한다.
String? _legacyDictThumbJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return null;
  }
  final resized = decoded.width >= decoded.height
      ? img.copyResize(decoded, width: 200)
      : img.copyResize(decoded, height: 200);
  return base64Encode(img.encodeJpg(resized, quality: 80));
}
