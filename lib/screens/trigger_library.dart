// lib/screens/trigger_library.dart
//
// 조건부 트리거 목록 — 라이브러리 탭의 세 번째 쪽('조건부 트리거').
//  규칙 하나가 한 칸:  [≡ 끌어서 순서]  [조건 · 결과 요약]  [켜기]
//  위에서부터 차례로 적용되므로 순서가 결과를 바꾼다.
//  '규칙 추가'를 누르면 목록 바로 위에 입력칸이 열리고(목록은 아래로 밀린다), 칸을 누르면 그 자리에서 입력칸으로 바뀐다.
//  두 경우 모두 같은 입력칸(_RuleEditor)을 쓴다 — 창(다이얼로그)은 쓰지 않는다.
//
//  저장은 예전 그대로 규칙 글 하나(state.conditionalRuleController)다. 목록은 그 글을 읽어 만든 '보기'이고,
//  칸을 바꿀 때마다 목록 전체를 글로 다시 써서 넣는다 (models/trigger_rules.dart).
//  그래서 '텍스트로 편집'으로 글을 직접 고쳐도 목록이 그대로 따라온다.
//
//  ⚠️ 이 화면은 main.dart 의 SingleChildScrollView 안에 있다 — ListView · 세로 Expanded 금지.
//     순서 바꾸기는 shrinkWrap + NeverScrollable 인 ReorderableListView (프롬프트탭 섹션과 같은 방식).
//  화면 순서: 개수 · 규칙 추가 → 작동 시점 → (새 규칙 입력칸) → 목록 → 텍스트로 편집 → 테스트(접힘) → 문법 가이드(접힘)
//  조건부 트리거는 이 목록에서만 고친다 — 프롬프트탭의 '조건부 트리거' 칸은 간단한 설명뿐이고, 누르면 여기로 온다
//  (TriggerSummaryCard → openTriggerLibrary).
import 'dart:async'; // 자동완성 디바운스

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 조건 칸에 쉼표를 받지 않는다 (FilteringTextInputFormatter)
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/app_state.dart';
import '../models/app_tabs.dart'; // 라이브러리 탭 · 안쪽 쪽 번호 (프롬프트탭 칸에서 여기로 올 때)
import '../models/prompt_pipeline.dart' show ratingLetterOf;
import '../models/text_controllers.dart';
import '../models/trigger_rules.dart';
import '../widgets/app_toast.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/prompt_preview_card.dart';
import '../utils/ui_safety.dart'; // 입력칸을 닫을 때 키보드만 내린다 (DEVNOTES 4)
import '../utils/prompt_utils.dart'; // 태그 후보 찾기 (smartMatchTags) · 보이는 이름 (displayTag)
import 'prompt_edit_dialog.dart'; // 글을 고치는 칸은 모두 같은 확대 입력창 (DEVNOTES 6)

/// 조건부 트리거 목록 열기 — 라이브러리 탭이 켜져 있으면 그 탭의 '조건부 트리거' 쪽으로,
///  꺼져 있으면 같은 목록을 새 화면으로 띄운다 (뒤로 가기로 돌아온다 — 라이브러리 탭을 꺼 둬도 고칠 수 있게).
void openTriggerLibrary(BuildContext context, AppState state) {
  if (state.isTabShown(AppTab.library)) {
    state.navigateToLibrary(kLibraryTriggerPage);
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: const Text(
            "조건부 트리거",
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
        ),
        body: const SafeArea(child: SingleChildScrollView(child: TriggerLibraryPage())),
      ),
    ),
  );
}

// ============================================================================
// 프롬프트탭의 '조건부 트리거' 칸 — 간단한 설명뿐, 누르면 목록으로
// ============================================================================

/// 프롬프트탭의 '조건부 트리거' 칸. 무엇인지 한 줄 + 켜진 규칙 수 — 누르면 [openTriggerLibrary].
///  ⚠️ 프롬프트탭은 AppState 를 생성자로 받는다 (widget.state) — 여기도 그대로 받는다.
///  (작동 시점 버튼 · 규칙 요약은 목록 쪽에만 둔다)
class TriggerSummaryCard extends StatelessWidget {
  final AppState state;

  const TriggerSummaryCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final on = parseTriggerLibrary(
      state.conditionalRuleController.text,
    ).whereType<TriggerRule>().where((r) => r.enabled).length;
    final border = BorderSide(color: AppColors.pink.withValues(alpha: 0.3));
    return GestureDetector(
      onTap: () => openTriggerLibrary(context, state),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
          border: Border(left: border, right: border, bottom: border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "조건이 맞으면 프롬프트를 바꿔 주는 규칙이에요.",
                    style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    "눌러서 라이브러리 › 조건부 트리거에서 편집 · 켜진 규칙 $on개",
                    style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: AppColors.pink),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 작동 시점
// ============================================================================

/// 작동 시점 고르기 — [랜덤 프롬프트 생성 시] [이미지 생성 시]. (예전엔 프롬프트탭 칸에 있었다)
class TriggerModeToggle extends StatelessWidget {
  final AppState state;

  const TriggerModeToggle({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _button("random", Icons.casino_outlined, "랜덤 프롬프트 생성 시")),
        const SizedBox(width: 8),
        Expanded(child: _button("generate", Icons.image_outlined, "이미지 생성 시")),
      ],
    );
  }

  Widget _button(String mode, IconData icon, String label) {
    final selected = state.conditionalTriggerMode == mode;
    final color = selected ? AppColors.pink : Colors.white54;
    return GestureDetector(
      onTap: () {
        if (selected) {
          return;
        }
        state.conditionalTriggerMode = mode;
        state.saveAndRefresh();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.pink.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.pink : Colors.white24,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 목록 (라이브러리 탭의 '조건부 트리거' 쪽)
// ============================================================================

/// 테스트 칸의 등급 — '자동' 은 예시 글에서 읽는다 ('이미지 생성 시' 의 실제 동작과 같다)
const String _kAutoRating = 'auto';

class TriggerLibraryPage extends StatefulWidget {
  const TriggerLibraryPage({super.key});

  @override
  State<TriggerLibraryPage> createState() => _TriggerLibraryPageState();
}

class _TriggerLibraryPageState extends State<TriggerLibraryPage> {
  // 지금 보여 주는 목록과, 그 목록을 읽어 온 글.
  //  글이 바깥에서 바뀌면(텍스트로 편집 · 백업 불러오기) 다시 읽는다 — 그때 칸 객체도 새로 생긴다.
  List<TriggerItem> _items = [];
  String? _parsedFrom;

  // 입력칸 — 한 번에 하나만 연다.
  //  _adding: 목록 위의 '새 규칙' 입력칸,  _editingRule: 그 자리에서 입력칸으로 바뀐 칸 (객체로 잡는다 — DEVNOTES 5)
  bool _adding = false;
  TriggerRule? _editingRule;

  // 테스트 칸 — 화면에만 있는 값 (저장하지 않는다)
  final TextEditingController _sampleCtrl = TextEditingController();
  String _testRating = _kAutoRating;
  // 테스트 칸은 접힌 채로 시작한다 (화면에만 — 저장하지 않는다)
  bool _testOpen = false;

  @override
  void dispose() {
    _sampleCtrl.dispose();
    super.dispose();
  }

  /// 목록을 규칙 글과 맞춘다 (글이 그대로면 지금 목록 — 칸 객체가 유지된다)
  List<TriggerItem> _sync(AppState state) {
    final text = state.conditionalRuleController.text;
    if (text != _parsedFrom) {
      _items = parseTriggerLibrary(text);
      _parsedFrom = text;
      _editingRule = null; // 고치던 칸은 이제 목록에 없다
    }
    return _items;
  }

  /// 목록을 글로 다시 써서 저장한다.
  ///  [undo] — 바꾸기 전 글을 '텍스트로 편집'의 되돌리기(↺)에 남긴다 (지우기 · 고치기처럼 되돌리기 어려운 것만).
  void _commit(AppState state, {bool undo = false}) {
    final ctrl = state.conditionalRuleController;
    if (undo) {
      state.pushPromptUndo(kConditionalUndoKey, ctrl.text);
    }
    final text = serializeTriggerLibrary(_items);
    _parsedFrom = text;
    ctrl.text = text;
    state.saveAndRefresh(); // 저장 + 다시 그리기 (이 화면도 다시 그려진다)
  }

  void _openAdd() => setState(() {
    _adding = true;
    _editingRule = null;
  });

  void _openEdit(TriggerRule r) => setState(() {
    _adding = false;
    _editingRule = r;
  });

  void _closeEditor() => setState(() {
    _adding = false;
    _editingRule = null;
  });

  /// 새 규칙은 맨 아래에 (위에서부터 차례로 적용되므로 지금까지의 규칙 뒤에 돈다)
  void _saveNew(AppState state, String cond, String action) {
    _sync(state);
    _items.add(TriggerRule(cond: cond, action: action));
    _closeEditor();
    _commit(state);
  }

  void _saveEdit(AppState state, TriggerRule r, String cond, String action) {
    _sync(state);
    _closeEditor();
    if (!_items.contains(r)) {
      showToast(context, "그 사이 규칙이 바뀌어 반영하지 못했어요. 다시 눌러 고쳐 주세요.");
      return;
    }
    if (r.cond == cond && r.action == action) {
      return; // 바뀐 게 없으면 글도 그대로 (되돌리기 기록도 남기지 않는다)
    }
    r.cond = cond;
    r.action = action;
    _commit(state, undo: true);
  }

  Future<void> _deleteRule(AppState state, TriggerRule r) async {
    final ok = await showConfirmDialog(
      context,
      title: "규칙 삭제",
      message: "이 규칙을 삭제할까요?\n${triggerRuleSummary(r)}",
      confirmLabel: "삭제",
      icon: Icons.delete_outline,
    );
    if (!ok || !mounted) {
      return;
    }
    _sync(state);
    if (!_items.remove(r)) {
      return;
    }
    _closeEditor();
    _commit(state, undo: true);
    showToast(context, "삭제했어요. '텍스트로 편집'의 되돌리기(↺)로 되살릴 수 있어요.");
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final items = _sync(state);
    final rules = items.whereType<TriggerRule>().toList();
    final on = rules.where((r) => r.enabled).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt, color: AppColors.pink, size: 18),
              const SizedBox(width: 6),
              Text(
                "규칙 ${rules.length}개 · 켜짐 $on",
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const Spacer(),
              ElevatedButton.icon(
                // 입력칸이 열려 있는 동안은 눌리지 않는다 (같은 칸이 두 번 열리지 않게)
                onPressed: _adding ? null : _openAdd,
                icon: const Icon(Icons.add, size: 18, color: Colors.white),
                label: const Text(
                  "규칙 추가",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.pink,
                  disabledBackgroundColor: AppColors.pink.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TriggerModeToggle(state: state),
          const SizedBox(height: 10),
          // 새 규칙 입력칸 — 열리면 아래 목록이 부드럽게 밀려 내려간다
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _adding
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _RuleEditor(
                      state: state,
                      onSubmit: (cond, action) => _saveNew(state, cond, action),
                      onCancel: _closeEditor,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          if (items.isNotEmpty)
            _buildList(state, items)
          else if (!_adding)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                "아직 규칙이 없어요.\n"
                "'규칙 추가'로 '이 태그가 있으면 → 저렇게 바꾸기'를 만들어 보세요.\n"
                "예) 1girl 이 있고 solo 가 없으면 → 긍정 앞에 solo 추가",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.5),
              ),
            ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => showPromptEditDialog(
              context,
              state,
              "조건부 트리거 (텍스트)",
              Icons.bolt,
              AppColors.pink,
              state.conditionalRuleController,
              undoKey: kConditionalUndoKey,
            ), // 닫힐 때 저장 · 다시 그리기는 창이 한다 → 글이 바뀌었으면 _sync 가 목록을 새로 읽는다
            icon: const Icon(Icons.notes, size: 18, color: AppColors.pink),
            label: const Text(
              "텍스트로 편집",
              style: TextStyle(color: AppColors.pink, fontWeight: FontWeight.bold),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppColors.pink.withValues(alpha: 0.6)),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 12),
          _buildTestBox(state, items),
          const SizedBox(height: 12),
          const _TriggerGuide(),
        ],
      ),
    );
  }

  Widget _buildList(AppState state, List<TriggerItem> items) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) => Material(
        elevation: 4,
        color: Colors.transparent,
        shadowColor: AppColors.pink.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        child: child,
      ),
      // newIndex 는 빼낸 뒤의 자리 (onReorderItem — 프롬프트탭 섹션과 같다)
      onReorderItem: (oldIndex, newIndex) {
        // 그린 뒤에 글이 바뀌어 목록을 새로 읽었으면 번호가 맞지 않는다 — 옮기지 않는다 (DEVNOTES 5)
        if (!identical(_sync(state), items) || oldIndex < 0 || oldIndex >= items.length) {
          return;
        }
        final item = items.removeAt(oldIndex);
        items.insert(newIndex.clamp(0, items.length), item);
        _commit(state);
      },
      children: [
        for (int i = 0; i < items.length; i++)
          Padding(
            // 칸 객체가 열쇠 — 순서가 바뀌어도 같은 칸을 같은 칸으로 본다 (DEVNOTES 5)
            key: ObjectKey(items[i]),
            padding: const EdgeInsets.only(bottom: 8),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: switch (items[i]) {
                // 고치는 중인 칸은 그 자리에서 입력칸으로 (끌 손잡이도 없어진다)
                final TriggerRule r when identical(r, _editingRule) => _RuleEditor(
                  state: state,
                  editing: r,
                  onSubmit: (cond, action) => _saveEdit(state, r, cond, action),
                  onCancel: _closeEditor,
                  onDelete: () => _deleteRule(state, r),
                ),
                final TriggerRule r => _ruleTile(state, r, i),
                final TriggerNote n => _noteTile(state, n, i),
              },
            ),
          ),
      ],
    );
  }

  Widget _dragHandle(int index) => ReorderableDragStartListener(
    index: index,
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      child: Icon(Icons.drag_indicator, color: Colors.white38, size: 20),
    ),
  );

  Widget _ruleTile(AppState state, TriggerRule r, int index) {
    final act = describeAction(r.action);
    final problem = conditionProblem(r.cond) ?? actionProblem(r.action);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openEdit(r),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: r.enabled ? AppColors.pink.withValues(alpha: 0.35) : Colors.white12,
            ),
          ),
          child: Row(
            children: [
              _dragHandle(index),
              Expanded(
                child: Opacity(
                  // 꺼 둔 규칙은 흐리게 — 남아 있지만 실행되지 않는다
                  opacity: r.enabled ? 1 : 0.45,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _summaryLine(
                        "조건",
                        AppColors.blue,
                        describeCondition(r.cond),
                        parens: true, // 묶음 괄호를 조금 굵게
                      ),
                      const SizedBox(height: 3),
                      _summaryLine("결과", AppColors.pink, "${act.verb} · ${act.detail}"),
                      if (problem != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            "⚠ $problem",
                            maxLines: 1, // 경고는 한 줄 (문장도 한 줄에 들도록 짧게 — trigger_rules.dart)
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppColors.orange, fontSize: 11),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Switch(
                value: r.enabled,
                activeThumbColor: AppColors.pink,
                onChanged: (v) {
                  _sync(state);
                  if (!_items.contains(r)) {
                    return; // 그 사이 목록을 새로 읽었다 — 옛 칸은 건드리지 않는다
                  }
                  r.enabled = v;
                  _commit(state);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [조건] 1girl 있음 · solo 없음  — 앞의 작은 색 딱지로 어느 쪽인지 보인다
  ///  [parens] — 조건 요약이면 묶음 괄호를 조금 굵고 밝게 (어디까지 묶였는지 보이게)
  Widget _summaryLine(String label, Color color, String text, {bool parens = false}) {
    const style = TextStyle(color: Colors.white70, fontSize: 12, height: 1.35);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 1, right: 6), child: _labelChip(label, color)),
        Expanded(
          child: Text.rich(
            parens ? _parenSpan(text) : TextSpan(text: text),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }

  Widget _noteTile(AppState state, TriggerNote n, int index) {
    final color = n.broken ? AppColors.orange : Colors.white38;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _editNote(state, n),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(2, 2, 10, 2),
          decoration: BoxDecoration(
            color: n.broken ? AppColors.orange.withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: n.broken ? AppColors.orange.withValues(alpha: 0.5) : Colors.white12,
            ),
          ),
          child: Row(
            children: [
              _dragHandle(index),
              Icon(n.broken ? Icons.warning_amber_rounded : Icons.notes, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (n.broken)
                        const Text(
                          "실행되지 않는 줄 — 눌러서 고치기",
                          style: TextStyle(
                            color: AppColors.orange,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      Text(
                        n.displayText,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: n.broken ? Colors.white70 : Colors.white54,
                          fontSize: 12,
                          fontStyle: n.broken ? FontStyle.normal : FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 메모 · 실행되지 않는 줄 고치기 — 글 그대로 고치고, 고친 글을 다시 읽어 그 자리에 넣는다
  ///  (규칙 모양으로 고치면 규칙 칸이 되고, 다 지우면 칸이 사라진다).
  Future<void> _editNote(AppState state, TriggerNote note) async {
    _closeEditor(); // 열려 있던 규칙 입력칸은 닫는다 (한 번에 하나)
    final original = note.toText();
    final ctrl = SyntaxHighlightController(text: original);
    await showPromptEditDialog(
      context,
      state,
      note.broken ? "실행되지 않는 줄" : "메모",
      note.broken ? Icons.warning_amber_rounded : Icons.notes,
      note.broken ? AppColors.orange : Colors.grey,
      ctrl,
      undoKey: 'trigger/note',
      // 창이 완전히 사라진 뒤에 버린다 (DEVNOTES 1) — 아래에서 글을 읽는 것은 그 전이다
      onClosed: ctrl.dispose,
    );
    if (!mounted) {
      return;
    }
    final text = ctrl.text;
    if (text == original) {
      return;
    }
    _sync(state);
    final i = _items.indexOf(note);
    if (i == -1) {
      showToast(context, "그 사이 규칙이 바뀌어 반영하지 못했어요. 다시 열어 주세요.");
      return;
    }
    final replaced = parseTriggerLibrary(text);
    if (replaced.isNotEmpty) {
      replaced.first.gapBefore = note.gapBefore;
    }
    _items.replaceRange(i, i + 1, replaced);
    _commit(state, undo: true);
  }

  // ── 테스트 칸 ──

  Widget _buildTestBox(AppState state, List<TriggerItem> items) {
    final sectioned = state.conditionalTriggerMode == "generate";
    final sample = _sampleCtrl.text;
    final auto = ratingLetterOf(sample);
    final rating = _testRating == _kAutoRating ? auto : _testRating;
    // 접혀 있으면 돌리지 않는다
    final run = !_testOpen || sample.trim().isEmpty
        ? null
        : runTriggerTest(items, sample, rating, sectioned: sectioned);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.pink.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.pink.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 머리줄을 누르면 접고 편다 (문법 가이드와 같은 모양)
          //  줄 높이를 고정한다 — 펼칠 때 '긍정 프롬프트 가져오기' 버튼이 생겨도 '테스트' 글자가 제자리에 있게.
          //  ⚠️ 예전엔 TextButton(누르는 자리 48px)이 줄을 키워, 펼치면 '테스트' 글자가 아래로 밀려 보였다.
          GestureDetector(
            onTap: () => setState(() => _testOpen = !_testOpen),
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              height: _kFoldHeaderHeight,
              child: Row(
                children: [
                  const Icon(Icons.science_outlined, color: AppColors.pink, size: 16),
                  const SizedBox(width: 6),
                  const Text(
                    "테스트",
                    style: TextStyle(
                      color: AppColors.pink,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  // 버튼은 남은 자리 오른쪽에 — 좁은 화면이면 글자가 '…' 로 줄어든다 (줄이 넘치지 않게)
                  if (_testOpen) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _SmallPillButton(
                          icon: Icons.download_rounded,
                          label: "긍정 프롬프트 가져오기",
                          onTap: () => setState(() {
                            _sampleCtrl.text = state.positiveController.text;
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ] else
                    const Spacer(),
                  Icon(
                    _testOpen ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.pink,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_testOpen) ...[
            const SizedBox(height: 6),
            PromptPreviewCard(
              title: "예시 프롬프트",
              icon: Icons.edit_note,
              color: AppColors.pink,
              text: sample,
              hint: "눌러서 예시 입력… (예: 1girl, skirt, smile)",
              maxLines: 3,
              background: AppColors.background,
              onTap: () async {
                await showPromptEditDialog(
                  context,
                  state,
                  "예시 프롬프트",
                  Icons.edit_note,
                  AppColors.pink,
                  _sampleCtrl,
                  undoKey: 'trigger/test',
                );
                if (mounted) {
                  setState(() {}); // 고친 예시로 결과를 다시 계산
                }
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text("등급", style: TextStyle(color: Colors.white54, fontSize: 12)),
                for (final r in const [_kAutoRating, 'g', 's', 'q', 'e'])
                  ChoiceChip(
                    label: Text(r == _kAutoRating ? "자동 ($auto)" : r),
                    selected: _testRating == r,
                    onSelected: (_) => setState(() => _testRating = r),
                    showCheckmark: false,
                    labelStyle: TextStyle(
                      color: _testRating == r ? Colors.white : Colors.white60,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    backgroundColor: AppColors.surface,
                    selectedColor: AppColors.pink.withValues(alpha: 0.35),
                    side: BorderSide(color: _testRating == r ? AppColors.pink : Colors.white24),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              sectioned
                  ? "지금 모드(이미지 생성 시)는 프롬프트 속 explicit · questionable · sensitive 글자로 등급을 정해요 — '자동'과 같아요.\n"
                        "예시만으로 시험해요 — 실제로는 선행 · 후행 프롬프트의 태그도 조건에 같이 보여요."
                  : "지금 모드(랜덤 프롬프트 생성 시)는 가져온 그림의 등급을 써요 — 시험할 등급을 골라 보세요.\n"
                        "예시만으로 시험해요 — 실제로는 선행 · 후행 프롬프트의 태그도 조건에 같이 보여요.",
              style: const TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 10),
            if (run == null)
              const Text(
                "예시를 넣으면 켜진 규칙을 차례로 적용한 결과가 바로 보여요.",
                style: TextStyle(color: Colors.white38, fontSize: 12),
              )
            else ...[
              Text(
                run.changed ? "결과" : "결과 — 바뀐 것 없음",
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  run.result.isEmpty ? "(비었어요)" : run.result,
                  style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                run.hits.isEmpty
                    ? "조건이 맞은 규칙 없음"
                    : "조건이 맞은 규칙 ${run.hits.length}개\n"
                          "${run.hits.map((r) => '· ${triggerRuleSummary(r)}').join('\n')}",
                style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// 문법 가이드 — 늘 접힌 채로 시작한다 (펼친 상태는 저장하지 않는다)
// ============================================================================

/// 접고 펴는 칸(테스트 · 문법 가이드)의 머리줄 높이 — 펼쳐도 접어도 같게
const double _kFoldHeaderHeight = 24;

/// 머리줄 안의 작은 버튼 — 테두리 · 옅은 배경 · 아이콘으로 '누르는 것'으로 보이게.
///  머리줄 높이(_kFoldHeaderHeight) 안에 들도록 작게 만든다 (TextButton 은 누르는 자리 48px 를 차지해 줄을 키운다).
///  머리줄의 접기(GestureDetector) 안에 있어도 이 버튼을 누르면 이 버튼만 눌린다 (안쪽이 먼저).
class _SmallPillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SmallPillButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: AppColors.pink.withValues(alpha: 0.55)),
    );
    return Material(
      color: AppColors.pink.withValues(alpha: 0.12),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: AppColors.pink),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.pink,
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TriggerGuide extends StatefulWidget {
  const _TriggerGuide();

  @override
  State<_TriggerGuide> createState() => _TriggerGuideState();
}

class _TriggerGuideState extends State<_TriggerGuide> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.pink.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.pink.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _open = !_open),
            behavior: HitTestBehavior.opaque,
            // 테스트 칸과 같은 머리줄 높이 — 접힌 두 칸이 같은 크기로 보이게
            child: SizedBox(
              height: _kFoldHeaderHeight,
              child: Row(
                children: [
                  const Text(
                    "💡 문법 가이드",
                    style: TextStyle(
                      color: AppColors.pink,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.pink,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...const [
            SizedBox(height: 8),
            _GuideText(kTriggerGuideRules, Colors.white70, 12),
            SizedBox(height: 8),
            _GuideText(kTriggerGuideConditions, Colors.yellowAccent, 11),
            SizedBox(height: 8),
            _GuideText(kTriggerGuideQuotes, Colors.orangeAccent, 11),
            SizedBox(height: 8),
            _GuideText(kTriggerGuideWildcards, Colors.cyanAccent, 11),
            SizedBox(height: 8),
            _GuideText(kTriggerGuideText, Colors.white54, 11),
          ],
        ],
      ),
    );
  }
}

class _GuideText extends StatelessWidget {
  final String text;
  final Color color;
  final double size;

  const _GuideText(this.text, this.color, this.size);

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(color: color, fontSize: size, height: 1.45));
}

// 가이드 글
const String kTriggerGuideRules =
    "(조건):A=B → 조건이 맞으면 A 를 B 로 바꾸기 (B 를 비우면 지우기)\n"
    "(조건):A^B → A 에 맞는 태그 속 글자만 바꾸기 (long*^short* : long hair → short hair)\n"
    "(조건):A+B → A 에 맞는 태그 바로 뒤에 B 넣기 (1girl+solo : 1girl, solo)\n"
    "   └ 여러 개는 쉼표로 (1girl+solo, smile) — 이미 있는 태그는 건너뛰어요. 1girl+solo+smile 은 'solo+smile' 한 태그예요\n"
    "(조건):prefix=B → 긍정 프롬프트 맨 앞에 B 추가\n"
    "(조건):suffix=B → 긍정 프롬프트 맨 뒤에 B 추가";
const String kTriggerGuideConditions =
    "* 조건에는 ! (아님) · & (그리고) · | (또는) · ( ) 를 섞어 쓸 수 있어요.  예) 1girl&!solo\n"
    "* 쉼표(,)는 쓸 수 없어요 — 태그 여러 개는 & 로 이어요.\n"
    "* g · s · q · e 를 쓰면 태그 대신 등급을 봐요.  늘 적용하려면 g|s|q|e";
const String kTriggerGuideQuotes =
    "* 기호(& | ! ( ) = ^ +)가 든 태그는 \"…\" 나 '…' 로 묶어요 — 자동완성으로 고르면 알아서 묶어 줘요.\n"
    "  예) (\"nahida (genshin impact)\"&!solo):\"la+ darknesss\"+dress\n"
    "  ' 가 든 태그(girls' frontline)는 \" 로 묶어요. * 는 묶음 바깥에 — *\"la+\" = la+ 로 끝나는 태그";
const String kTriggerGuideWildcards =
    "* * 는 위치에 따라 뜻이 달라요\n"
    "  skirt* → skirt 로 시작하는 태그\n"
    "  *skirt → skirt 로 끝나는 태그\n"
    "  *skirt* → skirt 가 들어간 태그";
const String kTriggerGuideText =
    "* 텍스트로 편집할 때: 앞에 #off 를 붙인 규칙은 꺼 둔 규칙이에요. 그 밖의 # 줄은 메모 칸으로 남아요.\n"
    "* 메모는 한 줄 통째로(# 로 시작) — 규칙 줄 끝에 붙인 # 메모는 글자로 들어가요.\n"
    "* 규칙 모양이 아닌 줄은 '실행되지 않는 줄'로 남고, 괄호 짝이 틀린 규칙(⚠)은 고치기 전까지 돌지 않아요.";

/// 입력칸의 결과 칸 아래 두 줄 도움말 (오른쪽엔 추가 버튼)
const String _kActionCheatSheet =
    "A=B 바꾸기 · A= 지우기 · A^B 일부 바꾸기\n"
    "A+B 뒤에 넣기 · prefix=B 긍정 앞 · suffix=B 긍정 뒤";

/// 조건 요약의 묶음 괄호 ( ) 를 조금 굵고 밝게 — 어디까지 묶였는지 한눈에 (목록 칸 · 입력칸 미리보기)
///  따옴표로 묶은 태그("nahida (genshin impact)") 속 괄호는 태그의 글자라 그대로 둔다.
///  괄호 · 따옴표는 한 글자라 그 자리에서 잘라도 이모지를 쪼개지 않는다.
TextSpan _parenSpan(String text) {
  final children = <TextSpan>[];
  int last = 0;
  bool inQuote = false;
  for (final m in _parenChars.allMatches(text)) {
    if (m[0] == '"') {
      inQuote = !inQuote;
      continue;
    }
    if (inQuote) {
      continue;
    }
    if (m.start > last) {
      children.add(TextSpan(text: text.substring(last, m.start)));
    }
    children.add(TextSpan(text: m[0], style: _parenStyle));
    last = m.end;
  }
  if (last < text.length) {
    children.add(TextSpan(text: text.substring(last)));
  }
  return TextSpan(children: children);
}

final RegExp _parenChars = RegExp(r'[()"]');
const TextStyle _parenStyle = TextStyle(color: Colors.white, fontWeight: FontWeight.w900);

/// [조건] · [결과] 작은 색 딱지 — 목록 칸과 입력칸이 같이 쓴다
Widget _labelChip(String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
  decoration: BoxDecoration(
    color: color.withValues(alpha: 0.15),
    borderRadius: BorderRadius.circular(4),
  ),
  child: Text(
    label,
    style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
  ),
);

// ============================================================================
// 규칙 입력칸 — 새 규칙(목록 위) · 고치기(그 칸 자리)가 같은 것을 쓴다
// ============================================================================

/// 조건 · 결과를 적는 칸. 적는 동안 아래에 사람 말 요약이 바로 보이고, 문제가 있으면 저장하지 않는다.
///  조건 · 결과는 프롬프트가 아니라 규칙 문법이라 보통 입력칸을 쓴다
///  (확대 입력창의 자동완성은 태그 뒤에 ', ' 를 붙여 조건 문법을 깨뜨린다).
///  대신 이 칸 전용 자동완성 — 적고 있는 칸 바로 아래에 태그 후보 목록이 뜨고, 고르면 그 태그만 바꿔 끼운다
///  (trigger_rules.dart 의 triggerWordAt · applyTriggerSuggestion — 쉼표를 붙이지 않고 앞뒤 * 는 살린다).
///  값만 돌려주고, 목록 반영은 부른 쪽이 한다.
///  컨트롤러 · 포커스는 이 칸이 화면에서 빠질 때 dispose() 에서 정리된다 (안의 TextField 가 먼저 정리된 뒤,
///  포커스는 한 프레임 뒤에).
///  닫을 때는 키보드만 내리고 칸을 없앤다 — 포커스를 직접 옮기지 않는다 (DEVNOTES 4).
///  ⚠️ AppState 는 생성자로 받는다 (태그 목록 · e621 색) — 사전 편집 창과 같은 방식.
class _RuleEditor extends StatefulWidget {
  final AppState state;

  /// 고칠 규칙 (null = 새 규칙)
  final TriggerRule? editing;
  final void Function(String cond, String action) onSubmit;
  final VoidCallback onCancel;

  /// 고칠 때만 — 삭제 (확인 창은 부른 쪽이 띄운다)
  final VoidCallback? onDelete;

  const _RuleEditor({
    required this.state,
    this.editing,
    required this.onSubmit,
    required this.onCancel,
    this.onDelete,
  });

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

/// 자동완성 목록 한 줄 높이 · 한 번에 보이는 줄 수 (넘치면 목록 안에서 스크롤)
const double _kSuggestRowHeight = 38;
const int _kSuggestVisibleRows = 5;

class _RuleEditorState extends State<_RuleEditor> {
  late final TextEditingController _condCtrl = TextEditingController(
    text: widget.editing?.cond ?? '',
  );
  late final TextEditingController _actionCtrl = TextEditingController(
    text: widget.editing?.action ?? '',
  );
  final FocusNode _condFocus = FocusNode();
  final FocusNode _actionFocus = FocusNode();
  // 저장을 눌렀을 때 막은 이유 (고치기 시작하면 지운다)
  String? _error;

  // 자동완성 — 지금 후보를 보여 주는 칸 (true 조건 / false 결과 / null 없음)
  bool? _suggestFor;
  List<String> _suggestions = const [];
  // 후보를 만든 때의 글 · 커서. 글은 그대로인데 커서만 옮기면 그 후보는 엉뚱한 자리에 들어가므로 지운다.
  String _anchorText = '';
  int _anchorCursor = -1;
  // 후보 찾기는 태그가 많아 잠깐 기다렸다가 (확대 입력창과 같은 100ms)
  Timer? _suggestDebounce;

  @override
  void initState() {
    super.initState();
    _condCtrl.addListener(_watchCursor);
    _actionCtrl.addListener(_watchCursor);
    _condFocus.addListener(_watchFocus);
    _actionFocus.addListener(_watchFocus);
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _condCtrl.removeListener(_watchCursor);
    _actionCtrl.removeListener(_watchCursor);
    _condFocus.removeListener(_watchFocus);
    _actionFocus.removeListener(_watchFocus);
    _condCtrl.dispose();
    _actionCtrl.dispose();
    // FocusNode 는 한 프레임 뒤에 버린다 (DEVNOTES 4 — 히스토리 · 갤러리 검색칸과 같은 방식)
    final FocusNode cond = _condFocus;
    final FocusNode action = _actionFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      cond.dispose();
      action.dispose();
    });
    super.dispose();
  }

  TextEditingController _ctrlOf(bool isCondition) => isCondition ? _condCtrl : _actionCtrl;

  void _hideKeyboard() {
    hideKeyboardIfShown(_condFocus);
    hideKeyboardIfShown(_actionFocus);
  }

  void _clearSuggestions() {
    _suggestDebounce?.cancel();
    if (_suggestFor == null && _suggestions.isEmpty) {
      return;
    }
    setState(() {
      _suggestFor = null;
      _suggestions = const [];
      _anchorCursor = -1;
    });
  }

  /// 글은 그대로인데 커서만 옮겼으면 후보를 지운다.
  ///  ⚠️ 글자를 드래그로 고르는 중에는 건드리지 않고, 그리기는 프레임 뒤로 미룬다
  ///     (확대 입력창과 같은 이유 — 고르는 동안 매번 다시 그리면 입력 연결이 흔들린다).
  void _watchCursor() {
    final which = _suggestFor;
    if (which == null) {
      return;
    }
    final ctrl = _ctrlOf(which);
    if (ctrl.text != _anchorText) {
      return; // 타이핑 — onChanged 가 새 후보를 만든다
    }
    final sel = ctrl.selection;
    if (!sel.isCollapsed || sel.baseOffset == _anchorCursor) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _clearSuggestions();
      }
    });
  }

  /// 후보를 보여 주던 칸에서 포커스가 나가면 (다른 칸을 누르면) 후보를 지운다
  void _watchFocus() {
    final which = _suggestFor;
    if (which == null || (which ? _condFocus : _actionFocus).hasFocus) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _clearSuggestions();
      }
    });
  }

  void _changed(bool isCondition) {
    setState(() => _error = null); // 요약 다시 그리기 + 안내 지우기
    _scheduleSuggestions(isCondition);
  }

  /// 커서 자리에서 적고 있는 태그로 후보를 찾는다 (두 글자부터 — 조건의 등급 글자 g · s · q · e 에 목록이 뜨지 않게)
  void _scheduleSuggestions(bool isCondition) {
    _suggestDebounce?.cancel();
    final ctrl = _ctrlOf(isCondition);
    final text = ctrl.text;
    final sel = ctrl.selection;
    final cursor = sel.isValid ? sel.baseOffset : text.length;
    final word = triggerWordAt(text, cursor, isCondition: isCondition);
    if (word == null || word.query.length < 2) {
      _clearSuggestions();
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 100), () {
      // 기다리는 사이 창이 닫혔거나 글이 또 바뀌었으면 버린다 (그때는 새 예약이 있다)
      if (!mounted || ctrl.text != text) {
        return;
      }
      // 따옴표로 묶어 적던 낱말엔 prefix= · suffix= 를 권하지 않는다 (태그 자리다)
      final keywords = isCondition || word.quote.isNotEmpty
          ? const <String>[]
          : triggerActionKeywords(text.substring(0, word.start), word.query);
      // 기호(& | ! ( ) = ^ +)가 든 태그도 후보에 둔다 — 고르면 applyTriggerSuggestion 이 따옴표로 묶어 넣는다.
      //  쉼표가 든 태그만 뺀다 (태그는 쉼표로 나뉘므로 묶어도 안 된다).
      //  ⚠️ 예전엔 기호 든 태그를 아예 뺐다 — la+ darknesss · nahida (genshin impact) 를 고를 수 없었다.
      final tags = [
        for (final raw in smartMatchTags(widget.state.searchTags, word.query))
          if (!kTriggerCondForbidden.hasMatch(PromptUtils.displayTag(raw))) raw,
      ];
      final list = [...keywords, ...tags];
      setState(() {
        _suggestFor = list.isEmpty ? null : isCondition;
        _suggestions = list;
        _anchorText = text;
        _anchorCursor = cursor;
      });
    });
  }

  /// 후보를 골랐다 — 커서 자리의 태그만 바꿔 끼운다 (그릴 때 잡아 둔 [raw] 를 받는다 — DEVNOTES 5)
  void _pick(bool isCondition, String raw) {
    final ctrl = _ctrlOf(isCondition);
    final tag = isTriggerKeyword(raw) ? raw : PromptUtils.displayTag(raw);
    final sel = ctrl.selection;
    final cursor = sel.isValid ? sel.baseOffset : ctrl.text.length;
    final r = applyTriggerSuggestion(ctrl.text, cursor, tag, isCondition: isCondition);
    ctrl.value = TextEditingValue(
      text: r.text,
      selection: TextSelection.collapsed(offset: r.cursor),
    );
    _suggestDebounce?.cancel();
    setState(() {
      _error = null;
      _suggestFor = null;
      _suggestions = const [];
      _anchorCursor = -1;
    });
  }

  void _submit() {
    final cond = triggerOneLine(_condCtrl.text);
    final action = triggerOneLine(_actionCtrl.text);
    final problem = ruleInputProblem(cond, action);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    _hideKeyboard();
    widget.onSubmit(cond, action);
  }

  void _cancel() {
    _hideKeyboard();
    widget.onCancel();
  }

  void _delete() {
    _hideKeyboard();
    widget.onDelete?.call();
  }

  Widget _field({
    required bool isCondition,
    required String label,
    required Color color,
    required String hint,
    bool autofocus = false,
    TextInputAction? inputAction,
    VoidCallback? onEditingComplete,
  }) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Colors.white24),
    );
    return TextField(
      controller: _ctrlOf(isCondition),
      focusNode: isCondition ? _condFocus : _actionFocus,
      autofocus: autofocus,
      textInputAction: inputAction,
      onEditingComplete: onEditingComplete,
      // 조건 칸은 쉼표를 아예 받지 않는다 (쉼표가 든 태그는 없다 — 붙여 넣어도 빠진다)
      inputFormatters: isCondition
          ? [FilteringTextInputFormatter.deny(kTriggerCondForbidden)]
          : null,
      onChanged: (_) => _changed(isCondition),
      // 칸 아래에 뜨는 후보 목록까지 키보드 위로 보이게 — 칸에 들어가거나 적을 때 그만큼 더 올려 준다
      scrollPadding: const EdgeInsets.fromLTRB(
        20,
        20,
        20,
        40 + _kSuggestRowHeight * _kSuggestVisibleRows,
      ),
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.background,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 10, right: 8),
          child: _labelChip(label, color),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: color, width: 1.5)),
      ),
    );
  }

  /// 적고 있는 칸 바로 아래의 태그 후보 목록 (검색창처럼 — 5줄까지 보이고 넘치면 그 안에서 스크롤)
  ///  ⚠️ 바깥이 스크롤 화면이라 높이를 정해 둔다 (Expanded 금지).
  ///  TextFieldTapRegion — 후보를 누르는 것을 '입력칸 바깥 누르기'로 보지 않게 (누르는 순간 키보드가 내려가지 않게).
  Widget _suggestionList(bool isCondition, Color color) {
    final shown = _suggestions;
    final rows = shown.length < _kSuggestVisibleRows ? shown.length : _kSuggestVisibleRows;
    return TextFieldTapRegion(
      child: Container(
        margin: const EdgeInsets.only(top: 4),
        height: _kSuggestRowHeight * rows,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemExtent: _kSuggestRowHeight,
            itemCount: shown.length,
            itemBuilder: (context, i) {
              // 그릴 때의 후보를 잡아 둔다 — 누르기 직전 목록이 바뀌어도 본 것이 들어간다 (DEVNOTES 5)
              final String raw = shown[i];
              // ⚠️ '= 로 끝나면 낱말'로 보면 '=_=' 같은 태그를 낱말로 그렸다
              final bool keyword = isTriggerKeyword(raw);
              final bool weak = raw.startsWith(kContainsMarker); // 가운데가 맞은 후보 (연하게)
              final String label = keyword ? raw : PromptUtils.displayTag(raw);
              final Color textColor = keyword
                  ? color
                  : widget.state.isE621Tag(raw)
                  ? const Color(0xFF3B9EFF)
                  : (weak ? Colors.white54 : Colors.white);
              return InkWell(
                onTap: () => _pick(isCondition, raw),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(
                        keyword ? Icons.keyboard_return : Icons.sell_outlined,
                        size: 14,
                        color: color.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: textColor, fontSize: 13),
                        ),
                      ),
                      if (keyword)
                        Text(
                          raw == 'prefix=' ? "긍정 앞에 추가" : "긍정 뒤에 추가",
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 요약 한 줄 — 문제가 있으면 주황색으로 그 이유
  ///  경고는 한 줄로 자른다. [parens] — 조건 요약이면 묶음 괄호를 조금 굵게 (목록 칸과 같다)
  Widget _previewText(String text, String? problem, {bool parens = false}) {
    if (problem != null) {
      return Text(
        "⚠ $problem",
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.orange, fontSize: 12, height: 1.35),
      );
    }
    return Text.rich(
      TextSpan(children: [const TextSpan(text: "→ "), parens ? _parenSpan(text) : TextSpan(text: text)]),
      style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.35),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.editing == null;
    final cond = triggerOneLine(_condCtrl.text);
    final action = triggerOneLine(_actionCtrl.text);
    final act = describeAction(action);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.pink.withValues(alpha: 0.7), width: 1.5),
        boxShadow: [BoxShadow(color: AppColors.pink.withValues(alpha: 0.12), blurRadius: 12)],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _field(
                  isCondition: true,
                  label: "조건",
                  color: AppColors.blue,
                  hint: "1girl&!solo · e|q · *skirt",
                  autofocus: isNew, // 새 규칙은 바로 적을 수 있게
                  inputAction: TextInputAction.next,
                ),
                if (_suggestFor == true) _suggestionList(true, AppColors.blue),
                if (cond.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 0, 0),
                    child: _previewText(
                      describeCondition(cond),
                      conditionProblem(cond),
                      parens: true,
                    ),
                  ),
                const SizedBox(height: 10),
                _field(
                  isCondition: false,
                  label: "결과",
                  color: AppColors.pink,
                  hint: "skirt=pants · prefix=solo",
                  inputAction: TextInputAction.done,
                  // 자판의 완료 = 저장 (기본 동작인 포커스 풀기 대신)
                  onEditingComplete: _submit,
                ),
                if (_suggestFor == false) _suggestionList(false, AppColors.pink),
                const SizedBox(height: 6),
                // [도움말 두 줄 / 결과 요약]  [삭제] [추가]
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: action.isNotEmpty
                            ? _previewText("${act.verb} · ${act.detail}", actionProblem(action))
                            : const Text(
                                _kActionCheatSheet,
                                style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
                              ),
                      ),
                    ),
                    if (!isNew && widget.onDelete != null)
                      TextButton(
                        onPressed: _delete,
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        child: const Text("삭제", style: TextStyle(color: Colors.redAccent)),
                      ),
                    const SizedBox(width: 4),
                    ElevatedButton.icon(
                      onPressed: _submit,
                      icon: Icon(isNew ? Icons.add : Icons.check, size: 16, color: Colors.white),
                      label: Text(
                        isNew ? "추가" : "저장",
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.pink,
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12, height: 1.35),
                    ),
                  ),
              ],
            ),
          ),
          // 자판의 '다음'이 조건 칸 옆의 이 버튼이 아니라 결과 칸으로 가게 — 포커스 순서에서 뺀다
          ExcludeFocus(
            child: IconButton(
              onPressed: _cancel,
              tooltip: isNew ? "닫기" : "고치기 취소",
              icon: const Icon(Icons.close, color: Colors.white60),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}
