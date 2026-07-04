import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_state.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // 설정 진입 시 항상 [일반] 탭으로 리셋되도록 핸들러 등록 (main onPageChanged가 호출)
    _appState = context.read<AppState>();
    _appState.settingsTabReset = () {
      if (mounted && _tabController.index != 0) {
        _tabController.animateTo(0);
      }
    };
  }

  @override
  void dispose() {
    _appState.settingsTabReset = null;
    _tabController.dispose();
    super.dispose();
  }

  bool _isGelbooruExpanded = false;
  bool _gelbooruExpandChecked = false;

  // 설정 내보내기: 폴더에 저장 / 공유하기 선택
  Future<void> _exportSettings(BuildContext context, AppState state) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
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
              subtitle: const Text(
                "DNaiApp/settings 폴더에 저장 (앱 재시작해도 유지)",
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () => Navigator.pop(ctx, 'folder'),
            ),
            ListTile(
              leading: const Icon(Icons.share, color: Color(0xFF8B5CF6)),
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
        final base = await state.getGalleryBasePath();
        final settingsDir = Directory('$base/settings');
        if (!await settingsDir.exists()) {
          await settingsDir.create(recursive: true);
        }
        final file = File('${settingsDir.path}/$fileName');
        await file.writeAsString(jsonStr);
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(seconds: 5), content: Text("저장 완료: ${file.path}")),
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

  InputDecoration _settingsInputDecoration(String hint, IconData icon, {Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white30),
      prefixIcon: Icon(icon, color: Colors.deepPurpleAccent),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: const Color(0xFF121212),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.deepPurpleAccent),
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
      backgroundColor: Colors.deepPurpleAccent.withValues(alpha: 0.2),
      side: const BorderSide(color: Colors.deepPurpleAccent, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onPressed: () => _insertTextAtCursor(controller, tag),
    );
  }

  Widget _tabChip(String label, bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: value
              ? Colors.deepPurpleAccent.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: value ? Colors.deepPurpleAccent : Colors.white24,
            width: value ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: value ? Colors.deepPurpleAccent : Colors.white38,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  // 1줄짜리 ON/OFF 토글 타일 (통일된 형태)
  Widget _toggleTile({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    Color color = Colors.deepPurpleAccent,
    BorderRadius? radius,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
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
    Color color = const Color(0xFF8B5CF6),
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
        backgroundColor: const Color(0xFF1E1E1E),
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
            child: const Text("복사만", style: TextStyle(color: Color(0xFF00BFA5))),
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
        backgroundColor: const Color(0xFF1E1E1E),
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
          color: const Color(0xFF121212),
          child: TabBar(
            controller: _tabController,
            indicatorColor: Colors.deepPurpleAccent,
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
              _tabScroll(_generalSection(context, state)),
              _tabScroll(_storageSection(context, state)),
              _tabScroll(_apiSection(context, state)),
              _tabScroll(_miscSection(context, state)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tabScroll(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [...children, const SizedBox(height: 80)],
        ),
      ),
    );
  }

  List<Widget> _generalSection(BuildContext context, AppState state) {
    return [
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
      // 3. 연속 생성 딜레이 (슬라이더)
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            const Icon(Icons.timer_outlined, color: Colors.deepPurpleAccent, size: 20),
            const SizedBox(width: 8),
            const Text(
              "연속 생성 딜레이",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(width: 8),
            Text(
              "${state.batchDelay.toStringAsFixed(1)}초",
              style: const TextStyle(
                color: Colors.deepPurpleAccent,
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
                  activeTrackColor: Colors.deepPurpleAccent,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: Colors.deepPurpleAccent,
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
      // 6. i2i용 히스토리 비활성화
      _toggleTile(
        icon: Icons.history_toggle_off,
        title: "i2i용 히스토리 비활성화",
        color: const Color(0xFF8B5CF6),
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
          title: "인페인트 결과 자동 전환",
          value: state.inpaintAutoSwitchResult,
          onChanged: (val) {
            state.inpaintAutoSwitchResult = val;
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
        radius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      const SizedBox(height: 16),

      // ── ON/OFF 옵션과 폴더/파일 설정 구분선 ──
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Divider(color: Colors.white24, thickness: 1, height: 1),
      ),
      // 탭 표시 설정
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "탭 표시 설정",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _tabChip("히스토리", state.historyTabEnabled, (v) {
                  state.historyTabEnabled = v;
                  state.saveAllSettings();
                  state.refreshUI();
                }),
                _tabChip("i2i", state.i2iTabEnabled, (v) {
                  state.i2iTabEnabled = v;
                  state.saveAllSettings();
                  state.refreshUI();
                }),
                _tabChip("캐릭터", state.characterTabEnabled, (v) {
                  state.characterTabEnabled = v;
                  state.saveAllSettings();
                  state.refreshUI();
                }),
                _tabChip("와일드카드", state.wildcardTabEnabled, (v) {
                  state.wildcardTabEnabled = v;
                  state.saveAllSettings();
                  state.refreshUI();
                }),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  List<Widget> _storageSection(BuildContext context, AppState state) {
    return [
      // 저장 폴더 (SAF) — 임의 폴더/SD카드 지정
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
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
                  const Icon(Icons.folder_special, color: Color(0xFF00BFA5), size: 20),
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
                  color: const Color(0xFF121212),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      state.safRootUri != null ? Icons.check_circle : Icons.remove_circle_outline,
                      size: 16,
                      color: state.safRootUri != null ? const Color(0xFF00BFA5) : Colors.white30,
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
                        foregroundColor: const Color(0xFF00BFA5),
                        side: const BorderSide(color: Color(0xFF00BFA5)),
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
          color: const Color(0xFF1E1E1E),
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
                  const Icon(Icons.edit_document, color: Colors.deepPurpleAccent, size: 20),
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
                    backgroundColor: Colors.deepPurpleAccent,
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
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.photo_library_outlined, color: Colors.deepPurpleAccent, size: 18),
                SizedBox(width: 8),
                Text(
                  "현재 생성된 이미지",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
            Text(
              "${state.sessionGenerateCount} 장",
              style: const TextStyle(
                color: Colors.deepPurpleAccent,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),

      // ✅ 1번: 설정 백업 (margin 제거 → 다른 항목과 동일한 가로 크기)
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.sync_alt, color: Colors.deepPurpleAccent, size: 18),
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
      // NovelAi API 토큰 설정 (미연결 시)
      if (!state.isApiConnected) ...[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "NovelAi API 토큰 설정",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                "API 토큰 입력이 필요합니다.",
                style: TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: state.apiTokenController,
                style: const TextStyle(color: Colors.white),
                decoration: _settingsInputDecoration("NovelAI 토큰을 붙여넣으세요", Icons.vpn_key_outlined),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    state.apiToken = state.apiTokenController.text.trim();
                    if (state.apiToken.isNotEmpty) {
                      await state.fetchAnlas();
                      state.isApiConnected = true;
                      await state.saveAllSettings();
                      state.refreshUI();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          duration: const Duration(milliseconds: 2400),
                          content: Text("계정 정보(Anlas/구독 등급) 동기화 완료!"),
                        ),
                      );
                    } else {
                      state.isApiConnected = false;
                      await state.saveAllSettings();
                      state.refreshUI();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          duration: const Duration(milliseconds: 2400),
                          content: Text("API 토큰을 입력해주세요."),
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurpleAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text(
                    "토큰 저장 및 연결",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],

      // API 연결 상태 (연결됨일 때만)
      if (state.isApiConnected) ...[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.tealAccent.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
          ),
          child: const Column(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.tealAccent, size: 40),
              SizedBox(height: 8),
              Text(
                "NovelAI 서버에 연결되어 있습니다.",
                style: TextStyle(
                  color: Colors.tealAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // 연결 해제 버튼
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              state.apiToken = "";
              state.apiTokenController.clear();
              state.isApiConnected = false;
              state.currentAnlas = 0;
              state.subscriptionTier = 0;
              state.saveAllSettings();
              state.refreshUI();
            },
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            label: const Text("연결 해제", style: TextStyle(color: Colors.redAccent)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              side: const BorderSide(color: Colors.redAccent),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],

      // ✅ 2번: Gelbooru API 설정 (접기/펴기)
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
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

  List<Widget> _miscSection(BuildContext context, AppState state) {
    return [
      // 앱 버전 정보
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
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
          ],
        ),
      ),
      // 업데이트 설정
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          children: [
            // 기동시 업데이트 확인 토글
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.sync, color: Colors.deepPurpleAccent, size: 20),
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
                  activeThumbColor: Colors.deepPurpleAccent,
                  activeTrackColor: Colors.deepPurpleAccent.withValues(alpha: 0.5),
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
                            valueColor: const AlwaysStoppedAnimation(Colors.deepPurpleAccent),
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
                      onPressed: () => state.downloadAndInstallUpdate(context),
                      icon: const Icon(Icons.download, color: Colors.white, size: 18),
                      label: Text(
                        "v${state.latestVersion} 다운로드 및 설치",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurpleAccent,
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
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Colors.deepPurpleAccent, size: 24),
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
          ),
        ],
      ),
    );
  }
}
