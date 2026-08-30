import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_state.dart';
import '../models/text_controllers.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_theme.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  // 탭 전환 시 상태를 유지해 재방문이 즉시 이뤄지게 한다
  @override
  bool get wantKeepAlive => true;

  late final TabController _tabController;
  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _appState = context.read<AppState>();
    // 탭을 옮길 때마다 '방문했음'을 기록해 그때부터 내용을 만든다 (지연 생성)
    _tabController.addListener(_markTabVisited);
    // 스와이프 도중에도 반응하도록 애니메이션에도 붙인다
    _tabController.animation?.addListener(_markTabVisited);
  }

  // 실제로 열어본 탭만 내용을 만든다.
  //  설정 탭 4개를 전부 만들면 위젯이 200개 가까이 되어 진입할 때 한 번 멈칫한다.
  //  처음에는 [일반]만 만들고, 다른 탭은 눌렀을 때 만든 뒤 계속 유지한다.
  final Set<int> _visitedTabs = {0};

  // API 탭에 들어오면 계정 상태를 한 번 확인한다.
  //  ⚠️ _markTabVisited는 스와이프 애니메이션에도 물려 있어 한 프레임에도 여러 번
  //     불린다. 가드가 없으면 addPostFrameCallback이 수십 개 쌓인다.
  //     실제 API 호출은 refreshAllAccountQuotas가 '5분 이내 확인분은 건너뛰기'로
  //     한 번 더 걸러 준다.
  bool _apiQuotaChecked = false;

  void _refreshAccountsOnApiTab() {
    if (_apiQuotaChecked || !mounted) {
      return;
    }
    if (_appState.naiAccounts.isEmpty) {
      return;
    }
    _apiQuotaChecked = true;
    // 빌드 도중 notifyListeners가 불리지 않도록 프레임 뒤로 미룬다
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _appState.refreshAllAccountQuotas();
      }
    });
  }

  void _markTabVisited() {
    // 스와이프 중에는 index가 아직 안 바뀌므로 애니메이션 값으로 목적지를 본다.
    // (안 그러면 넘기는 도중 빈 화면이 스쳐 지나간다)
    final v = _tabController.animation?.value ?? _tabController.index.toDouble();
    bool changed = false;
    changed |= _visitedTabs.add(v.floor().clamp(0, 3));
    changed |= _visitedTabs.add(v.ceil().clamp(0, 3));
    changed |= _visitedTabs.add(_tabController.index);
    if (changed && mounted) {
      setState(() {});
    }
    if (_tabController.index == 2) {
      _refreshAccountsOnApiTab();
    }
  }

  @override
  void dispose() {
    _tabController.animation?.removeListener(_markTabVisited);
    _tabController.removeListener(_markTabVisited);
    _tabController.dispose();
    for (final c in _tabScrolls) {
      c.dispose();
    }
    super.dispose();
  }

  bool _isGelbooruExpanded = false;
  bool _gelbooruExpandChecked = false;

  // 설정 내보내기: 폴더에 저장 / 공유하기 선택
  Future<void> _exportSettings(BuildContext context, AppState state) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text("설정 내보내기", style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            const Divider(height: 1, color: Colors.white12),
            ListTile(
              leading: const Icon(Icons.folder, color: Color(0xFFFFC107)),
              title: const Text("폴더에 저장", style: TextStyle(color: Colors.white)),
              subtitle: Text(
                state.safRootUri != null
                    ? "저장 폴더의 settings 안에 저장 (파일 앱에서 열람 가능)"
                    : "⚠️ 저장 폴더 미설정 — 가져오기로 다시 못 읽습니다",
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () => Navigator.pop(ctx, 'folder'),
            ),
            ListTile(
              leading: const Icon(Icons.share, color: AppColors.purple),
              title: const Text("공유하기", style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                "다른 앱으로 전송 (드라이브, 메신저 등)",
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (choice == null || !context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(duration: Duration(milliseconds: 2400), content: Text("내보내기 준비 중...")),
    );

    try {
      final data = await state.exportSettings();
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final dateStr =
          "${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}";
      final fileName = "DNaiApp_Settings_$dateStr.json";

      if (choice == 'folder') {
        // SAF 폴더에 저장한다.
        //  ⚠️ 예전처럼 /Android/data/<패키지>/files 아래에 쓰면 저장은 되지만,
        //     안드로이드 11부터 문서 선택기가 그 경로를 볼 수 없어서
        //     '가져오기'를 눌러도 파일이 나타나지 않는다.
        final shown = await state.saveSettingsViaSaf(fileName, jsonStr);
        if (!context.mounted) {
          return;
        }
        if (shown == null) {
          // 저장 폴더가 없으면 조용히 실패하지 말고 공유로 대체 (파일을 잃지 않게)
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/$fileName');
          await file.writeAsString(jsonStr);
          await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
          if (!context.mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              duration: Duration(seconds: 5),
              content: Text("저장 폴더가 없어 공유로 내보냈습니다. 설정에서 저장 폴더를 지정해 주세요."),
            ),
          );
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(seconds: 5), content: Text("저장 완료: $shown")),
        );
      } else {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(jsonStr);
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(duration: Duration(milliseconds: 2400), content: Text("내보내기에 실패했습니다.")),
        );
      }
    }
  }

  // 남은 할당량에 따른 색. 넉넉/보통/부족을 한눈에 구분한다.
  static Color _quotaColor(double percent) {
    if (percent >= 50) {
      return AppColors.teal;
    }
    if (percent >= 20) {
      return Colors.amber;
    }
    return Colors.redAccent;
  }

  // ── NovelAI 계정 목록 ──
  //  라디오처럼 하나만 활성화된다. 탭하면 그 계정의 토큰으로 갈아끼운다.
  Widget _buildAccountList(BuildContext context, AppState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.people_alt_outlined, color: AppColors.accent, size: 18),
              const SizedBox(width: 8),
              const Text(
                "NovelAI 계정",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text(
                "${state.naiAccounts.length}개",
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              if (state.naiAccounts.isNotEmpty) ...[
                const SizedBox(width: 4),
                // 전체 계정 잔액·할당량 다시 확인
                state.isRefreshingAccounts
                    ? const Padding(
                        padding: EdgeInsets.all(6),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.refresh, size: 18, color: Colors.white38),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                        tooltip: '모든 계정 다시 확인',
                        onPressed: () => state.refreshAllAccountQuotas(force: true),
                      ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (state.naiAccounts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                "등록된 계정이 없어요. 아래에서 추가해 주세요.",
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          for (int i = 0; i < state.naiAccounts.length; i++) _accountRow(context, state, i),
          const SizedBox(height: 4),
          // 현재 연결 상태 — 예전에는 아래 별도 카드에 있었지만 여기로 합쳤다
          if (state.naiAccounts.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: state.isApiConnected
                    ? AppColors.teal.withValues(alpha: 0.12)
                    : Colors.redAccent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    state.isApiConnected ? Icons.check_circle_outline : Icons.error_outline,
                    size: 15,
                    color: state.isApiConnected ? AppColors.teal : Colors.redAccent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    state.isApiConnected ? "서버에 연결됨" : "연결되지 않음 (토큰 확인)",
                    style: TextStyle(
                      color: state.isApiConnected ? AppColors.teal : Colors.redAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showAccountDialog(context, state, null),
                  icon: Icon(Icons.add, size: 16, color: AppColors.accent),
                  label: Text("계정 추가", style: TextStyle(color: AppColors.accent, fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.accent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  // 계정이 하나뿐이면 지울 수 없다 (토큰이 아예 사라지는 것 방지)
                  onPressed: state.naiAccounts.length > 1
                      ? () => _showRemoveAccountDialog(context, state)
                      : null,
                  icon: Icon(
                    Icons.remove,
                    size: 16,
                    color: state.naiAccounts.length > 1 ? Colors.redAccent : Colors.white24,
                  ),
                  label: Text(
                    "계정 삭제",
                    style: TextStyle(
                      color: state.naiAccounts.length > 1 ? Colors.redAccent : Colors.white24,
                      fontSize: 13,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: state.naiAccounts.length > 1 ? Colors.redAccent : Colors.white12,
                    ),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 계정 삭제 — 어느 계정을 지울지 목록에서 고른다.
  //  쓰던 계정을 바꾸지 않고도 다른 계정을 지울 수 있어야 해서 목록 방식으로 둔다.
  void _showRemoveAccountDialog(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("삭제할 계정 선택", style: TextStyle(color: Colors.white, fontSize: 16)),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: state.naiAccounts.length,
            itemBuilder: (c, i) {
              final acc = state.naiAccounts[i];
              final isActive = state.activeAccountIndex == i;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Icon(
                  isActive ? Icons.radio_button_checked : Icons.person_outline,
                  size: 18,
                  color: isActive ? AppColors.accent : Colors.white38,
                ),
                title: Text(
                  acc.label.isEmpty ? "계정 ${i + 1}" : acc.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                subtitle: Text(
                  acc.token.isEmpty ? "토큰 없음" : acc.maskedToken,
                  style: TextStyle(
                    color: acc.token.isEmpty ? Colors.redAccent : Colors.white38,
                    fontSize: 11,
                  ),
                ),
                trailing: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmRemoveAccount(context, state, i);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  // 실제 삭제 전 한 번 더 확인
  void _confirmRemoveAccount(BuildContext context, AppState state, int index) {
    if (index < 0 || index >= state.naiAccounts.length) {
      return;
    }
    final acc = state.naiAccounts[index];
    final isActive = state.activeAccountIndex == index;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("계정 삭제", style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          isActive
              ? "'${acc.label}' 계정을 지울까요?\n지금 쓰는 계정이라 다른 계정으로 전환돼요."
              : "'${acc.label}' 계정을 지울까요?",
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // 삭제 후 계정 전환·잔액 조회가 이어지므로 끝까지 진행시킨다
              state.removeAccount(index);
            },
            child: const Text("삭제", style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Widget _accountRow(BuildContext context, AppState state, int index) {
    final acc = state.naiAccounts[index];
    final isActive = state.activeAccountIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: isActive ? null : () => state.switchAccount(index),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? AppColors.accent.withValues(alpha: 0.15) : const Color(0xFF161616),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isActive ? AppColors.accent : Colors.white12),
          ),
          child: Row(
            children: [
              Icon(
                isActive ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: isActive ? AppColors.accent : Colors.white24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      acc.label.isEmpty ? "계정 ${index + 1}" : acc.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isActive ? Colors.white : Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      acc.token.isEmpty ? "토큰 없음" : acc.maskedToken,
                      style: TextStyle(
                        color: acc.token.isEmpty ? Colors.redAccent : Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              // [Anlas · 할당량 · 갱신시각] 을 한 줄로 나열한다.
              //  ⚠️ 이름/토큰 칸이 Expanded라 여기 폭이 넓어지면 이름이 밀려 잘린다.
              //     그래서 각 항목은 확인된 것만 내보낸다.
              if (acc.anlas >= 0 || acc.limitPercent != null || acc.checkedAgo != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (acc.anlas >= 0) ...[
                        const Icon(Icons.toll, size: 15, color: Colors.orangeAccent),
                        const SizedBox(width: 3),
                        Text(
                          "${acc.anlas}",
                          style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
                        ),
                      ],
                      if (acc.limitPercent != null) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.bolt, size: 15, color: _quotaColor(acc.limitPercent!)),
                        const SizedBox(width: 2),
                        Text(
                          "${acc.limitPercent!.round()}%",
                          style: TextStyle(
                            color: _quotaColor(acc.limitPercent!),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                      if (acc.checkedAgo != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          acc.checkedAgo!,
                          style: const TextStyle(color: Colors.white30, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18, color: Colors.white38),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => _showAccountDialog(context, state, index),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 계정 추가/수정 다이얼로그. index가 null이면 추가.
  void _showAccountDialog(BuildContext context, AppState state, int? index) {
    final isEdit = index != null;
    final acc = isEdit ? state.naiAccounts[index] : null;
    final labelCtrl = TextEditingController(text: acc?.label ?? '');
    final tokenCtrl = TextEditingController(text: acc?.token ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          isEdit ? "계정 수정" : "계정 추가",
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelCtrl,
              maxLength: 12,
              style: const TextStyle(color: Colors.white),
              decoration: _settingsInputDecoration("이름 (예: 본계정)", Icons.label_outline),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tokenCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: _settingsInputDecoration("NovelAI 토큰", Icons.vpn_key_outlined),
            ),
          ],
        ),
        actions: [
          // 마지막 하나는 지울 수 없다
          if (isEdit && state.naiAccounts.length > 1)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                state.removeAccount(index);
              },
              child: const Text("삭제", style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () {
              if (isEdit) {
                state.updateAccount(index, label: labelCtrl.text, token: tokenCtrl.text);
              } else {
                state.addAccount(labelCtrl.text, tokenCtrl.text);
              }
              Navigator.pop(ctx);
            },
            child: const Text("저장", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ).then((_) {
      // 다이얼로그가 완전히 닫힌 뒤에 정리 (닫히는 중에 버리면 예외가 난다)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        labelCtrl.dispose();
        tokenCtrl.dispose();
      });
    });
  }

  InputDecoration _settingsInputDecoration(String hint, IconData icon, {Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white30),
      prefixIcon: Icon(icon, color: AppColors.accent),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppColors.background,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: AppColors.accent),
      ),
    );
  }

  void _insertTextAtCursor(TextEditingController controller, String textToInsert) {
    final int cursorPosition = controller.selection.baseOffset;
    if (cursorPosition >= 0) {
      final String text = controller.text;
      final String newText =
          text.substring(0, cursorPosition) + textToInsert + text.substring(cursorPosition);
      controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: cursorPosition + textToInsert.length),
      );
    } else {
      controller.text += textToInsert;
    }
  }

  Widget _buildQuickTagButton(TextEditingController controller, String tag, String label) {
    return ActionChip(
      label: Text(
        label,
        style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
      ),
      backgroundColor: AppColors.accent.withValues(alpha: 0.2),
      side: BorderSide(color: AppColors.accent, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onPressed: () => _insertTextAtCursor(controller, tag),
    );
  }

  // 칩들을 2열 균등 그리드로 배치 (Wrap이 3+1로 깨지는 문제 해결)
  Widget _chipGrid(List<Widget> chips) {
    final rows = <Widget>[];
    for (int i = 0; i < chips.length; i += 2) {
      final left = chips[i];
      final right = (i + 1 < chips.length) ? chips[i + 1] : null;
      rows.add(
        Padding(
          padding: EdgeInsets.only(bottom: i + 2 < chips.length ? 6 : 0),
          child: Row(
            children: [
              Expanded(child: left),
              const SizedBox(width: 6),
              // 홀수 개면 마지막 칸은 빈 자리로 (좌측 정렬 유지)
              Expanded(child: right ?? const SizedBox()),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  // 켜고 끄는 칩 (탭 표시 / i2i 모드 표시 등에 공용으로 사용)
  // 컴팩트하게 유지하면서 아이콘 + 체크 표시로 상태를 명확히 보여준다.
  Widget _tabChip(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    IconData? icon,
    Color? activeColor,
  }) {
    final Color accent = activeColor ?? AppColors.accent;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: value ? accent.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: value ? accent.withValues(alpha: 0.8) : Colors.white24,
            width: value ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            Icon(
              value ? Icons.check_circle : Icons.circle_outlined,
              size: 14,
              color: value ? accent : Colors.white30,
            ),
            const SizedBox(width: 5),
            if (icon != null) ...[
              Icon(icon, size: 13, color: value ? accent : Colors.white38),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: value ? accent : Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 1줄짜리 ON/OFF 토글 타일 (통일된 형태)
  // 액센트 색 선택 타일.
  //  자유 컬러 피커가 아니라 고정 팔레트를 쓴다.
  //  (긍정=청록 / 선행=파랑 / 후행=주황 / 부정=빨강 / 캐릭터=보라 처럼
  //   의미가 정해진 색과 겹치면 UI에서 구분이 안 되기 때문)
  Widget _accentPickerTile(AppState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(color: AppColors.surface),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.color_lens, color: AppColors.accent, size: 20),
              const SizedBox(width: 8),
              const Text(
                "액센트 색",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            "버튼·아이콘·강조 표시에 쓰이는 색이에요.",
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: AppColors.accentPalette.map((opt) {
              final bool selected = state.themeAccent == opt.color.toARGB32();
              return GestureDetector(
                onTap: () => state.setThemeAccent(opt.color.toARGB32()),
                child: Tooltip(
                  message: opt.name,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: opt.color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.white24,
                        width: selected ? 3 : 1,
                      ),
                      boxShadow: selected
                          ? [BoxShadow(color: opt.color.withValues(alpha: 0.5), blurRadius: 8)]
                          : null,
                    ),
                    child: selected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _toggleTile({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    // ⚠️ AppColors.accent는 런타임에 바뀌는 값이라 기본 파라미터 값으로 못 쓴다
    //    (기본값은 컴파일 타임 상수여야 함). null로 받고 본문에서 채운다.
    Color? color,
    BorderRadius? radius,
  }) {
    color ??= AppColors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: radius,
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.85,
            child: Switch(
              value: value,
              activeThumbColor: color,
              activeTrackColor: color.withValues(alpha: 0.5),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  // 하위(종속) 토글 — 마스터 토글 아래에 들여써서 종속 관계를 시각적으로 표현
  Widget _subToggleTile({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    Color color = AppColors.purple,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF181818),
          border: Border(
            left: BorderSide(color: color.withValues(alpha: 0.45), width: 2),
            top: const BorderSide(color: Colors.white10),
            right: const BorderSide(color: Colors.white10),
            bottom: const BorderSide(color: Colors.white10),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  Icon(
                    Icons.subdirectory_arrow_right,
                    color: color.withValues(alpha: 0.6),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                ],
              ),
            ),
            Transform.scale(
              scale: 0.72,
              child: Switch(
                value: value,
                activeThumbColor: color,
                activeTrackColor: color.withValues(alpha: 0.5),
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 앱 전용 폴더의 기존 이미지를 SAF 폴더로 이전 (복사만 / 이동 선택)
  Future<void> _migrateAppToSaf(BuildContext context, AppState state) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.drive_file_move_outline, color: Color(0xFFFFC107)),
            SizedBox(width: 8),
            Text("앱 폴더 → SAF 이전", style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Text(
          "앱 전용 폴더에 저장돼 있던 기존 이미지를 지금 지정한 SAF 폴더로 옮깁니다. 세션 폴더 구조는 그대로 유지돼요.\n\n"
          "· 복사만: 원본을 그대로 두고 SAF에도 복사\n"
          "· 이동: SAF로 복사한 뒤 앱 폴더의 원본 삭제 (중복 없이 통합)",
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, "cancel"),
            child: const Text("취소", style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, "copy"),
            child: const Text("복사만", style: TextStyle(color: AppColors.teal)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, "move"),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107)),
            child: const Text(
              "이동",
              style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (choice == null || choice == "cancel" || !context.mounted) {
      return;
    }
    final bool move = choice == "move";

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        content: Row(
          children: [
            const CircularProgressIndicator(color: Color(0xFFFFC107)),
            const SizedBox(width: 20),
            Text(move ? "이동 중..." : "복사 중...", style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );

    final result = await state.migrateAppFolderToSaf(deleteOriginals: move);
    if (!context.mounted) {
      return;
    }
    Navigator.pop(context); // 진행 다이얼로그 닫기

    final String msg;
    if (result.copied == 0 && result.failed == 0) {
      msg = "옮길 이미지가 없어요.";
    } else {
      final delPart = move ? " · 원본 ${result.deleted}장 삭제" : "";
      final failPart = result.failed > 0 ? " · 실패 ${result.failed}건" : "";
      msg = "${result.copied}장을 SAF로 ${move ? "이동" : "복사"}했어요$delPart$failPart.";
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive 필수 호출
    final state = context.watch<AppState>();

    // Gelbooru API 미인증 시 기본 열림 (최초 1회)
    if (!_gelbooruExpandChecked) {
      _gelbooruExpandChecked = true;
      if (state.gelbooruApiController.text.trim().isEmpty) {
        _isGelbooruExpanded = true;
      }
    }

    return Column(
      children: [
        Material(
          color: AppColors.background,
          child: TabBar(
            controller: _tabController,
            indicatorColor: AppColors.accent,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            tabs: const [
              Tab(text: "일반"),
              Tab(text: "저장"),
              Tab(text: "API"),
              Tab(text: "기타"),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _lazyTab(0, () => _generalSection(context, state), _tabScrolls[0]),
              _lazyTab(1, () => _storageSection(context, state), _tabScrolls[1]),
              _lazyTab(2, () => _apiSection(context, state), _tabScrolls[2]),
              _lazyTab(3, () => _miscSection(context, state), _tabScrolls[3]),
            ],
          ),
        ),
      ],
    );
  }

  // 하위탭별 스크롤 컨트롤러 — 설정을 토글해도 스크롤 위치가 맨 위로 튀지 않게 유지.
  // 탭 표시를 바꾸면 PageView가 재생성되어 이 컨트롤러도 새로 만들어지므로,
  // 실제 위치는 AppState에 보관하고 여기서 복원한다.
  late final List<ScrollController> _tabScrolls = List.generate(4, (i) {
    final c = ScrollController(initialScrollOffset: _appState.settingsScrollOffsets[i] ?? 0);
    // 스크롤할 때마다 위치를 AppState에 기록
    c.addListener(() {
      if (c.hasClients) {
        _appState.settingsScrollOffsets[i] = c.offset;
      }
    });
    return c;
  });

  // 검색 페이지 수 슬라이더 타일 (본인 API 키가 있어야 조절 가능)
  Widget _searchPagesTile(AppState state) {
    final bool hasKey = state.gelbooruApiKey.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.search, color: hasKey ? AppColors.accent : Colors.white24, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "검색 페이지 수",
                  style: TextStyle(color: hasKey ? Colors.white : Colors.white38, fontSize: 15),
                ),
              ),
              Text(
                hasKey ? "${state.gelbooruSearchPages}" : "40",
                style: TextStyle(
                  color: hasKey ? AppColors.accent : Colors.white38,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          Text(
            hasKey ? "많을수록 더 많은 결과를 찾지만 검색이 느려져요 (40~120)" : "본인 API 키를 등록하면 조절할 수 있어요",
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          Slider(
            value: state.gelbooruSearchPages.toDouble().clamp(40, 120),
            min: 40,
            max: 120,
            divisions: 16, // 40,45,...,120
            activeColor: AppColors.accent,
            label: "${state.gelbooruSearchPages}",
            onChanged: hasKey
                ? (v) {
                    state.gelbooruSearchPages = v.round();
                    state.refreshUI();
                  }
                : null,
            onChangeEnd: hasKey
                ? (v) {
                    state.gelbooruSearchPages = v.round();
                    state.saveAllSettings();
                    state.refreshUI();
                  }
                : null,
          ),
          const SizedBox(height: 4),
          // [실험] 정렬 축 다양화 토글
          Row(
            children: [
              Icon(
                Icons.shuffle,
                color: hasKey ? const Color(0xFF3B82F6) : Colors.white24,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "정렬 다양화 (실험)",
                      style: TextStyle(color: hasKey ? Colors.white : Colors.white38, fontSize: 14),
                    ),
                    Text(
                      "여러 정렬을 섞어 더 다양한 결과를 찾아요",
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Switch(
                value: state.diversifySearchSort,
                activeThumbColor: const Color(0xFF3B82F6),
                onChanged: hasKey
                    ? (v) {
                        state.diversifySearchSort = v;
                        state.saveAllSettings();
                        state.refreshUI();
                      }
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 방문한 탭만 내용을 만든다. 아직 안 본 탭은 빈 화면으로 자리만 잡는다.
  Widget _lazyTab(int index, List<Widget> Function() build, ScrollController controller) {
    if (!_visitedTabs.contains(index)) {
      return const SizedBox.shrink();
    }
    return _tabScroll(build(), controller);
  }

  Widget _tabScroll(List<Widget> children, ScrollController controller) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        controller: controller,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [...children, const SizedBox(height: 80)],
        ),
      ),
    );
  }

  // 설정 그룹 (접기/펴기) — 항목이 많아져 성격별로 묶는다.
  // 접힘 상태는 AppState에 저장되어 앱을 껐다 켜도 유지된다.
  Widget _settingGroup(
    AppState state, {
    required String id,
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final collapsed = state.collapsedSettingGroups.contains(id);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 헤더 (탭하면 접기/펴기)
          InkWell(
            onTap: () => state.toggleSettingGroup(id),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(icon, color: AppColors.accent, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Icon(
                    collapsed ? Icons.expand_more : Icons.expand_less,
                    color: Colors.white38,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
        ],
      ),
    );
  }

  List<Widget> _generalSection(BuildContext context, AppState state) {
    return [
      // ── 프롬프트 ──
      _settingGroup(
        state,
        id: 'prompt',
        title: "프롬프트",
        icon: Icons.edit_note,
        children: [
          // 1. 랜덤 프롬프트 알파벳 순서
          _toggleTile(
            icon: Icons.sort_by_alpha,
            title: "랜덤 프롬프트 알파벳 순서",
            value: state.randomPromptAlphabetical,
            onChanged: (val) {
              state.randomPromptAlphabetical = val;
              state.saveAllSettings();
              state.refreshUI();
            },
            radius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          // 2. NovelAi 권장 순서 무시
          _toggleTile(
            icon: Icons.rule_folder_outlined,
            title: "NovelAi 권장 순서 무시",
            value: state.ignoreRecommendedOrder,
            onChanged: (val) {
              state.ignoreRecommendedOrder = val;
              state.saveAllSettings();
              state.refreshUI();
            },
          ),
          // 7. 가중치 색상 표시
          _toggleTile(
            icon: Icons.format_color_text,
            title: "가중치 색상 표시",
            value: state.weightHighlight,
            onChanged: (val) {
              state.weightHighlight = val;
              WeightHighlightController.highlightEnabled = val;
              state.saveAllSettings();
              state.refreshUI();
            },
          ),
          // 8. e621 프롬프트 확장
          _toggleTile(
            icon: Icons.extension,
            title: "e621 프롬프트 확장",
            color: const Color(0xFF3B9EFF),
            value: state.e621Enabled,
            onChanged: (val) {
              state.e621Enabled = val;
              state.saveAllSettings();
              state.refreshUI();
            },
          ),
          _toggleTile(
            icon: Icons.dashboard_outlined,
            title: "프롬프트탭 새로운 UI로 변경",
            value: state.promptNewLayout,
            onChanged: (val) {
              state.promptNewLayout = val;
              state.saveAllSettings();
              state.refreshUI();
            },
          ),
          // ⚠️ [보류] 프롬프트탭 2번째 UI 토글 (promptAltLayout)
          //  구현은 prompt_tab.dart의 _buildAltLayout 이하에 그대로 남아 있고,
          //  AppState.promptAltLayout 을 true 로 만들면 다시 동작한다.
          //  일반 사용자에게 노출하지 않기 위해 설정 항목만 제거한 상태.
          //  다시 쓰려면 아래 블록의 주석을 해제하면 된다.
          // _toggleTile(
          //   icon: Icons.dashboard_customize,
          //   title: "프롬프트탭 다른 UI로 변경",
          //   value: state.promptAltLayout,
          //   onChanged: (val) {
          //     state.promptAltLayout = val;
          //     state.saveAllSettings();
          //     state.refreshUI();
          //   },
          // ),
          // 11. 프롬프트 탭 캐릭터 편집 서랍
          _toggleTile(
            icon: Icons.people_alt,
            title: "프롬프트 탭 캐릭터 편집",
            value: state.promptCharDrawerEnabled,
            onChanged: (val) {
              state.promptCharDrawerEnabled = val;
              state.saveAllSettings();
              state.refreshUI();
            },
            radius: const BorderRadius.vertical(bottom: Radius.circular(16)),
          ),
          // 캐릭터 탭 재탭 토글
          _toggleTile(
            icon: Icons.touch_app,
            title: "캐릭터 재선택으로 ON/OFF",
            value: state.charRetapToggle,
            onChanged: (val) {
              state.charRetapToggle = val;
              state.saveAllSettings();
              state.refreshUI();
            },
          ),
        ],
      ),

      // ── 히스토리 · 갤러리 ──
      _settingGroup(
        state,
        id: 'history',
        title: "히스토리 · 갤러리",
        icon: Icons.photo_library_outlined,
        children: [
          // 4. 갤러리 모드 비활성화 (기본은 켜져 있음)
          _toggleTile(
            icon: Icons.photo_library_outlined,
            title: "갤러리 모드 비활성화",
            color: const Color(0xFFFFC107),
            value: !state.galleryModeEnabled,
            onChanged: (val) {
              state.setGalleryModeEnabled(!val);
            },
          ),
          // 5. 히스토리 이미지 슬라이드
          _toggleTile(
            icon: Icons.view_carousel_outlined,
            title: "히스토리 이미지 슬라이드",
            value: state.historySlideEnabled,
            onChanged: (val) {
              state.historySlideEnabled = val;
              state.saveAllSettings();
              state.refreshUI();
            },
          ),
        ],
      ),

      // ── i2i · 인페인트 ──
      _settingGroup(
        state,
        id: 'i2i',
        title: "i2i · 인페인트",
        icon: Icons.brush_outlined,
        children: [
          // 6. i2i용 히스토리 비활성화
          _toggleTile(
            icon: Icons.history_toggle_off,
            title: "i2i용 히스토리 비활성화",
            color: AppColors.purple,
            value: state.i2iHistoryDisabled,
            onChanged: (val) {
              state.i2iHistoryDisabled = val;
              state.saveAllSettings();
              state.refreshUI();
            },
          ),
          // 6-1. i2i 히스토리 핸들이 켜져 있을 때만(=비활성화 OFF) 인페인트 세부 옵션 표시
          if (!state.i2iHistoryDisabled) ...[
            _subToggleTile(
              title: "인페인트 후 전환 방지",
              value: state.inpaintNoAutoSwitch,
              onChanged: (val) {
                state.inpaintNoAutoSwitch = val;
                state.saveAllSettings();
                state.refreshUI();
              },
            ),
            _subToggleTile(
              title: "인페인트 시 마스킹 자동 해제",
              value: state.inpaintAutoClearMask,
              onChanged: (val) {
                state.inpaintAutoClearMask = val;
                state.saveAllSettings();
                state.refreshUI();
              },
            ),
          ],
          // ⚠️ [1차 UI 비활성] i2i탭은 2차 배치로 고정되어 토글을 숨겼다.
          //  1차 UI를 되살리려면 아래 주석을 해제하고
          //  AppState의 i2iAltLayout 강제 true(로드/복원부)를 풀면 된다.
          // _toggleTile(
          //   icon: Icons.view_quilt,
          //   title: "i2i탭 다른 UI로 변경",
          //   value: state.i2iAltLayout,
          //   onChanged: (val) {
          //     state.i2iAltLayout = val;
          //     state.saveAllSettings();
          //     state.refreshUI();
          //   },
          // ),
        ],
      ),

      // ── 동작 · 기타 ──
      _settingGroup(
        state,
        id: 'behavior',
        title: "동작 · 기타",
        icon: Icons.tune,
        children: [
          // 3. 연속 생성 딜레이 (슬라이더)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                Icon(Icons.timer_outlined, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                const Text(
                  "연속 생성 딜레이",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(width: 8),
                Text(
                  "${state.batchDelay.toStringAsFixed(1)}초",
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: AppColors.accent,
                      inactiveTrackColor: Colors.white12,
                      thumbColor: AppColors.accent,
                    ),
                    child: Slider(
                      value: state.batchDelay,
                      min: 0.0,
                      max: 5.0,
                      divisions: 10,
                      onChanged: (v) {
                        state.batchDelay = v;
                        state.refreshUI();
                      },
                      onChangeEnd: (_) => state.saveAllSettings(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 프롬프트 입력 폰트 크기 (확대 입력창 전용)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                Icon(Icons.format_size, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                const Text(
                  "프롬프트 입력 폰트 크기",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(width: 8),
                Text(
                  state.promptEditorFontSize.toStringAsFixed(0),
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: AppColors.accent,
                      inactiveTrackColor: Colors.white12,
                      thumbColor: AppColors.accent,
                    ),
                    child: Slider(
                      value: state.promptEditorFontSize,
                      min: 10.0,
                      max: 28.0,
                      divisions: 36,
                      onChanged: (v) {
                        state.promptEditorFontSize = v;
                        state.refreshUI();
                      },
                      onChangeEnd: (_) => state.saveAllSettings(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 9. 탭 좌우 스와이프
          _toggleTile(
            icon: Icons.swipe,
            title: "탭 좌우 스와이프",
            value: state.horizontalSwipeEnabled,
            onChanged: (val) {
              state.horizontalSwipeEnabled = val;
              state.saveAllSettings();
              state.refreshUI();
            },
          ),
        ],
      ),

      // ── 테마 ──
      _settingGroup(
        state,
        id: 'theme',
        title: "테마",
        icon: Icons.palette_outlined,
        children: [_accentPickerTile(state)],
      ),

      const SizedBox(height: 16),
      // 검색 페이지 수 (API 키 있을 때만 조절 가능) — 독립 카드
      _searchPagesTile(state),
      const SizedBox(height: 16),
      // ── ON/OFF 옵션과 폴더/파일 설정 구분선 ──
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Divider(color: Colors.white24, thickness: 1, height: 1),
      ),
      // 표시 설정 (탭 / i2i 모드) — 한 카드로 통합
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tab, color: AppColors.accent, size: 15),
                const SizedBox(width: 6),
                const Text(
                  "탭 표시 설정",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 2×2 균등 그리드 (Wrap이 3+1로 깨지는 것을 방지)
            _chipGrid([
              _tabChip("히스토리", state.historyTabEnabled, (v) {
                state.historyTabEnabled = v;
                state.saveAllSettings();
                state.refreshUI();
              }, icon: Icons.history),
              _tabChip("i2i", state.i2iTabEnabled, (v) {
                state.setI2iTabEnabled(v);
              }, icon: Icons.image),
              _tabChip("캐릭터", state.characterTabEnabled, (v) {
                state.characterTabEnabled = v;
                state.saveAllSettings();
                state.refreshUI();
              }, icon: Icons.people),
              _tabChip("와일드카드", state.wildcardTabEnabled, (v) {
                state.wildcardTabEnabled = v;
                state.saveAllSettings();
                state.refreshUI();
              }, icon: Icons.casino),
            ]),

            const SizedBox(height: 16),
            Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
            const SizedBox(height: 14),

            Row(
              children: [
                const Icon(Icons.dashboard_customize, color: AppColors.teal, size: 15),
                const SizedBox(width: 6),
                const Text(
                  "i2i 모드 표시 설정",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _chipGrid([
              _tabChip(
                "인페인트",
                state.i2iModeInpaintEnabled,
                (v) => state.setI2iModeEnabled('inpaint', v),
                icon: Icons.format_paint,
                activeColor: AppColors.teal,
              ),
              _tabChip(
                "모자이크",
                state.i2iModeMosaicEnabled,
                (v) => state.setI2iModeEnabled('mosaic', v),
                icon: Icons.grid_on,
                activeColor: AppColors.accent,
              ),
              _tabChip(
                "img2img",
                state.i2iModeImg2imgEnabled,
                (v) => state.setI2iModeEnabled('img2img', v),
                icon: Icons.auto_fix_high,
                activeColor: const Color(0xFF3B82F6),
              ),
              _tabChip(
                "업스케일",
                state.i2iModeUpscaleEnabled,
                (v) => state.setI2iModeEnabled('upscale', v),
                icon: Icons.high_quality,
                activeColor: AppColors.orange,
              ),
            ]),

            const SizedBox(height: 16),
            Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
            const SizedBox(height: 14),

            Row(
              children: [
                const Icon(Icons.view_agenda, color: AppColors.purple, size: 15),
                const SizedBox(width: 6),
                const Text(
                  "프롬프트 창 표시 설정",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              "전부 꺼도 프롬프트 탭은 그대로 유지돼요",
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 10),
            _chipGrid([
              _promptSectionChip(
                state,
                'positive',
                "긍정적",
                Icons.add_circle_outline,
                AppColors.teal,
              ),
              _promptSectionChip(state, 'prefix', "선행", Icons.arrow_right_alt, AppColors.blue),
              _promptSectionChip(
                state,
                'suffix',
                "후행",
                Icons.keyboard_double_arrow_right,
                AppColors.orange,
              ),
              _promptSectionChip(
                state,
                'negative',
                "부정적",
                Icons.remove_circle_outline,
                AppColors.red,
              ),
              _promptSectionChip(
                state,
                'removeChips',
                "태그 제거",
                Icons.auto_fix_high,
                AppColors.purple,
              ),
              _promptSectionChip(
                state,
                'customRemove',
                "개별 제거",
                Icons.delete_outline,
                const Color(0xFF9E9E9E),
              ),
              _promptSectionChip(state, 'conditional', "조건부", Icons.bolt, const Color(0xFFEC4899)),
              _promptSectionChip(state, 'weightRules', "가중치", Icons.tune, const Color(0xFF84CC16)),
            ]),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  // 프롬프트 섹션 표시 칩 (숨김 목록에 없으면 ON)
  Widget _promptSectionChip(
    AppState state,
    String sectionId,
    String label,
    IconData icon,
    Color color,
  ) {
    return _tabChip(
      label,
      !state.hiddenPromptSections.contains(sectionId),
      (v) => state.setPromptSectionVisible(sectionId, v),
      icon: icon,
      activeColor: color,
    );
  }

  List<Widget> _storageSection(BuildContext context, AppState state) {
    return [
      // 저장 폴더 방식
      _toggleTile(
        icon: Icons.folder_outlined,
        title: "날짜별 폴더에 저장",
        value: state.saveFolderByDateOnly,
        onChanged: (val) {
          state.saveFolderByDateOnly = val;
          state.saveAllSettings();
          state.refreshUI();
        },
      ),
      const SizedBox(height: 16),
      // 이미지 저장 형식 (일반 탭에서 이동 — 저장 관련이므로 여기가 맞다)
      _toggleTile(
        icon: Icons.image_outlined,
        title: "이미지를 Webp로 저장",
        value: state.saveAsWebp,
        onChanged: (val) {
          state.saveAsWebp = val;
          state.saveAllSettings();
          state.refreshUI();
        },
      ),
      // WebP 저장이 켜져 있을 때만 압축 방식 선택
      if (state.saveAsWebp)
        _subToggleTile(
          title: "손실 압축 사용 (품질 95%)",
          value: state.webpLossy,
          onChanged: (val) {
            state.webpLossy = val;
            state.saveAllSettings();
            state.refreshUI();
          },
        ),
      const SizedBox(height: 16),
      // 저장 폴더 (SAF) — 임의 폴더/SD카드 지정
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => state.safCardOpen = !state.safCardOpen);
                state.saveAllSettings();
              },
              child: Row(
                children: [
                  const Icon(Icons.folder_special, color: AppColors.teal, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    "저장 폴더 (SAF)",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    state.safCardOpen ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white38,
                    size: 22,
                  ),
                ],
              ),
            ),
            if (state.safCardOpen) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      state.safRootUri != null ? Icons.check_circle : Icons.remove_circle_outline,
                      size: 16,
                      color: state.safRootUri != null ? AppColors.teal : Colors.white30,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.safRootUri != null ? "선택됨: ${state.safRootName ?? '폴더'}" : "선택 안 됨",
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await state.pickSafRoot();
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            duration: const Duration(milliseconds: 2000),
                            content: Text(ok ? "저장 폴더를 지정했어요!" : "폴더 선택이 취소됐어요."),
                          ),
                        );
                      },
                      icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                      label: const Text("폴더 선택"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.teal,
                        side: const BorderSide(color: AppColors.teal),
                      ),
                    ),
                  ),
                  if (state.safRootUri != null) ...[
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        await state.clearSafRoot();
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            duration: Duration(milliseconds: 2000),
                            content: Text("저장 폴더 지정을 해제했어요."),
                          ),
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white54,
                        side: const BorderSide(color: Colors.white24),
                      ),
                      child: const Text("해제"),
                    ),
                  ],
                ],
              ),
              if (state.safRootUri != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _migrateAppToSaf(context, state),
                    icon: const Icon(Icons.drive_file_move_outline, size: 18),
                    label: const Text("앱 폴더의 기존 이미지를 SAF로 옮기기"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFFC107),
                      side: const BorderSide(color: Color(0x55FFC107)),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),

      // 파일 이름 규칙
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => state.fileCardOpen = !state.fileCardOpen);
                state.saveAllSettings();
              },
              child: Row(
                children: [
                  Icon(Icons.edit_document, color: AppColors.accent, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    "파일 이름",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    state.fileCardOpen ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white38,
                    size: 22,
                  ),
                ],
              ),
            ),
            if (state.fileCardOpen) ...[
              const SizedBox(height: 12),
              TextField(
                controller: state.customFileNameController,
                style: const TextStyle(color: Colors.white),
                decoration: _settingsInputDecoration(
                  "예: Nai-{yy}{mm}{dd}-{time}",
                  Icons.edit_document,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: -4,
                children: [
                  _buildQuickTagButton(state.customFileNameController, "{yy}", "연도"),
                  _buildQuickTagButton(state.customFileNameController, "{mm}", "월"),
                  _buildQuickTagButton(state.customFileNameController, "{dd}", "일"),
                  _buildQuickTagButton(state.customFileNameController, "{time}", "시간"),
                  _buildQuickTagButton(state.customFileNameController, "{count}", "번호"),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    state.saveAllSettings();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(milliseconds: 2400),
                        content: Text("파일 이름이 저장되었습니다."),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text(
                    "설정 저장 적용",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),

      // 현재 생성된 이미지 (이번 세션 생성 수)
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.photo_library_outlined, color: AppColors.accent, size: 18),
                SizedBox(width: 8),
                Text(
                  "현재 생성된 이미지",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
            Text(
              "${state.sessionGenerateCount} 장",
              style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),

      // ✅ 1번: 설정 백업 (margin 제거 → 다른 항목과 동일한 가로 크기)
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sync_alt, color: AppColors.accent, size: 18),
                SizedBox(width: 8),
                Text(
                  "설정 백업",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              "프롬프트, 캐릭터, 와일드카드, 상세 설정, 토큰, 히스토리를 파일로 저장하거나 불러옵니다.",
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _exportSettings(context, state),
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text("내보내기"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final result = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                      );
                      if (result == null || result.files.isEmpty) return;
                      try {
                        final file = File(result.files.single.path!);
                        final jsonStr = await file.readAsString();
                        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
                        state.importSettings(data);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              duration: const Duration(milliseconds: 2400),
                              content: Text("설정을 성공적으로 불러왔습니다!"),
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              duration: const Duration(milliseconds: 2400),
                              content: Text("파일을 읽는 데 실패했습니다. JSON 형식을 확인해주세요."),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text("가져오기"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  List<Widget> _apiSection(BuildContext context, AppState state) {
    return [
      // ── NovelAI 계정 목록 ──
      //  V5의 시간당 한도 때문에 계정을 번갈아 쓰는 경우가 생겼다.
      //  여러 토큰을 보관해 두고 탭 한 번으로 갈아끼운다.
      _buildAccountList(context, state),
      const SizedBox(height: 16),

      // ✅ 2번: Gelbooru API 설정 (접기/펴기)
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () {
                setState(() {
                  _isGelbooruExpanded = !_isGelbooruExpanded;
                });
              },
              child: Row(
                children: [
                  Icon(
                    _isGelbooruExpanded ? Icons.expand_more : Icons.chevron_right,
                    color: Colors.white54,
                    size: 22,
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      "Gelbooru API 설정 (선택)",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (!_isGelbooruExpanded && state.gelbooruApiController.text.isNotEmpty)
                    Icon(
                      (state.gelbooruUserId.isNotEmpty && state.gelbooruApiKey.isNotEmpty)
                          ? Icons.check_circle
                          : Icons.error,
                      color: (state.gelbooruUserId.isNotEmpty && state.gelbooruApiKey.isNotEmpty)
                          ? Colors.tealAccent
                          : Colors.redAccent,
                      size: 18,
                    ),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: _isGelbooruExpanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 6),
                        const Text(
                          "익명 검색 제한을 해제하려면 '&api_key=...&user_id=...' 형식의 텍스트를 입력하세요.",
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: state.gelbooruApiController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _settingsInputDecoration(
                            "여기에 복사한 텍스트를 붙여넣으세요",
                            Icons.api_rounded,
                          ),
                          onChanged: (val) {
                            state.parseGelbooruApi();
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                        ),
                        if (state.gelbooruApiController.text.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            decoration: BoxDecoration(
                              color:
                                  (state.gelbooruUserId.isNotEmpty &&
                                      state.gelbooruApiKey.isNotEmpty)
                                  ? Colors.tealAccent.withValues(alpha: 0.1)
                                  : Colors.redAccent.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color:
                                    (state.gelbooruUserId.isNotEmpty &&
                                        state.gelbooruApiKey.isNotEmpty)
                                    ? Colors.tealAccent.withValues(alpha: 0.3)
                                    : Colors.redAccent.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  (state.gelbooruUserId.isNotEmpty &&
                                          state.gelbooruApiKey.isNotEmpty)
                                      ? Icons.check_circle
                                      : Icons.error,
                                  color:
                                      (state.gelbooruUserId.isNotEmpty &&
                                          state.gelbooruApiKey.isNotEmpty)
                                      ? Colors.tealAccent
                                      : Colors.redAccent,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    (state.gelbooruUserId.isNotEmpty &&
                                            state.gelbooruApiKey.isNotEmpty)
                                        ? "인식 완료! (User ID: ${state.gelbooruUserId})"
                                        : "형식이 올바르지 않습니다. (api_key와 user_id가 필요합니다)",
                                    style: TextStyle(
                                      color:
                                          (state.gelbooruUserId.isNotEmpty &&
                                              state.gelbooruApiKey.isNotEmpty)
                                          ? Colors.tealAccent
                                          : Colors.redAccent,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  // GitHub 저장소 열기 (주소는 AppState.githubRepo 하나에서만 관리)
  Future<void> _openGithubRepo(BuildContext context) async {
    final uri = Uri.parse('https://github.com/${AppState.githubRepo}');
    bool ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("브라우저를 열 수 없어요: $uri")));
    }
  }

  List<Widget> _miscSection(BuildContext context, AppState state) {
    return [
      // 앱 버전 정보 (탭하면 GitHub 저장소 열기)
      InkWell(
        onTap: () => _openGithubRepo(context),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.info_outline, color: Colors.white38, size: 16),
              const SizedBox(width: 6),
              Text(
                "DNaiApp v${AppState.currentVersion}",
                style: const TextStyle(color: Colors.white38, fontSize: 13),
              ),
              const SizedBox(width: 8),
              // 탭 가능하다는 힌트
              const Icon(Icons.open_in_new, color: Colors.white24, size: 14),
            ],
          ),
        ),
      ),
      // 업데이트 설정
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          children: [
            // 기동시 업데이트 확인 토글
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.sync, color: AppColors.accent, size: 20),
                    SizedBox(width: 8),
                    Text(
                      "기동 시 업데이트 확인",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: state.autoCheckUpdate,
                  activeThumbColor: AppColors.accent,
                  activeTrackColor: AppColors.accent.withValues(alpha: 0.5),
                  onChanged: (val) {
                    state.autoCheckUpdate = val;
                    state.saveAllSettings();
                    state.refreshUI();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 업데이트 확인 버튼
            SizedBox(
              width: double.infinity,
              child: state.isDownloadingUpdate
                  ? Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: state.downloadProgress,
                            minHeight: 8,
                            backgroundColor: Colors.white12,
                            valueColor: AlwaysStoppedAnimation(AppColors.accent),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "다운로드 중... ${(state.downloadProgress * 100).toStringAsFixed(0)}%",
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    )
                  : state.hasUpdate
                  ? ElevatedButton.icon(
                      onPressed: () => _showUpdateDialog(context, state),
                      icon: const Icon(Icons.system_update, color: Colors.white, size: 18),
                      label: Text(
                        "v${state.latestVersion} 업데이트 보기",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: () async {
                        await state.checkForUpdate();
                        if (!context.mounted) {
                          return;
                        }
                        if (state.hasUpdate) {
                          _showUpdateDialog(context, state);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              duration: const Duration(milliseconds: 2400),
                              content: Text("최신 버전입니다."),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text(
                        "업데이트 확인",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  void _showUpdateDialog(BuildContext context, AppState state) {
    // 수동으로 열 때도 가드를 켜서, main의 자동 알림이 겹쳐 뜨지 않게 한다.
    state.updateDialogShown = true;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.system_update, color: AppColors.accent, size: 24),
            const SizedBox(width: 8),
            Text(
              "v${state.latestVersion} 업데이트",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (state.releaseNotePreview.isNotEmpty) ...[
                const Text(
                  "변경 사항",
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...state.releaseNotePreview.map(
                  (line) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      line,
                      style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ] else
                const Text("새로운 업데이트가 있습니다.", style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("닫기", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              state.downloadAndInstallUpdate(context);
            },
            icon: const Icon(Icons.download, color: Colors.white, size: 16),
            label: const Text(
              "업데이트",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
          ),
        ],
      ),
    );
  }
}
