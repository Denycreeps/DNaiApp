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

class _SettingsTabState extends State<SettingsTab> {
  bool _isGelbooruExpanded = false;

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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ✅ 4번: '현재 생성된 이미지'
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.photo_library_outlined, color: Colors.deepPurpleAccent),
                      SizedBox(width: 8),
                      Text(
                        "현재 생성된 이미지",
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Text(
                    "${state.sessionGenerateCount} 장",
                    style: const TextStyle(
                      color: Colors.deepPurpleAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 저장 경로 및 파일 이름
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
                    "저장 경로 및 파일 이름",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 24),
                  const Text(
                    "폴더 경로 (기본: Download)",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: state.customSavePathController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _settingsInputDecoration(
                      "/storage/emulated/0/Download",
                      Icons.folder_open,
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.manage_search, color: Colors.deepPurpleAccent),
                        tooltip: "폴더 찾아보기",
                        onPressed: () async {
                          String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                          if (selectedDirectory != null) {
                            state.customSavePathController.text = selectedDirectory;
                            state.saveAllSettings();
                            state.refreshUI();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(milliseconds: 2400),
                                  content: Text("폴더 경로가 선택되었습니다!"),
                                ),
                              );
                            }
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text("파일 이름 규칙", style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
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
                            content: Text("경로 및 파일 이름이 저장되었습니다."),
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
              ),
            ),
            const SizedBox(height: 16),

            // ✅ 3번: '다른 탭에서 이미지 보이기' → 저장 경로 아래로 이동
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.image_outlined, color: Colors.deepPurpleAccent),
                      SizedBox(width: 8),
                      Text(
                        "다른 탭에서 이미지 보이기",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                  Switch(
                    value: state.showImageInOtherTabs,
                    activeThumbColor: Colors.deepPurpleAccent,
                    activeTrackColor: Colors.deepPurpleAccent.withValues(alpha: 0.5),
                    onChanged: (val) {
                      state.showImageInOtherTabs = val;
                      state.saveAllSettings();
                      state.refreshUI();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

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
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
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
            const SizedBox(height: 24),

            // API 토큰 설정 (미연결 시)
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
                      "API 토큰 설정",
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: state.apiTokenController,
                      style: const TextStyle(color: Colors.white),
                      decoration: _settingsInputDecoration(
                        "NovelAI 토큰을 붙여넣으세요",
                        Icons.vpn_key_outlined,
                      ),
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
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
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
                          onPressed: () async {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                duration: const Duration(milliseconds: 2400),
                                content: Text("내보내기 준비 중..."),
                              ),
                            );
                            try {
                              final data = state.exportSettings();
                              final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
                              final dir = await getTemporaryDirectory();
                              final file = File('${dir.path}/dnaiapp_settings.json');
                              await file.writeAsString(jsonStr);
                              await SharePlus.instance.share(
                                ShareParams(files: [XFile(file.path)]),
                              );
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    duration: const Duration(milliseconds: 2400),
                                    content: Text("내보내기에 실패했습니다."),
                                  ),
                                );
                              }
                            }
                          },
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

            // API 연결 상태
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: state.isApiConnected
                    ? Colors.tealAccent.withValues(alpha: 0.05)
                    : Colors.redAccent.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: state.isApiConnected
                      ? Colors.tealAccent.withValues(alpha: 0.3)
                      : Colors.redAccent.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    state.isApiConnected ? Icons.check_circle_outline : Icons.error_outline,
                    color: state.isApiConnected ? Colors.tealAccent : Colors.redAccent,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    state.isApiConnected ? "NovelAI 서버에 연결되어 있습니다." : "API 토큰 입력이 필요합니다.",
                    style: TextStyle(
                      color: state.isApiConnected ? Colors.tealAccent : Colors.redAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ✅ 5번: 연결 해제 버튼 → 버전 바로 위로 이동
            if (state.isApiConnected) ...[
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
                            color:
                                (state.gelbooruUserId.isNotEmpty && state.gelbooruApiKey.isNotEmpty)
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
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          )
                        : OutlinedButton.icon(
                            onPressed: () async {
                              await state.checkForUpdate();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  duration: const Duration(milliseconds: 2400),
                                  content: Text(
                                    state.hasUpdate
                                        ? "v${state.latestVersion} 업데이트가 있습니다!"
                                        : "최신 버전입니다.",
                                  ),
                                ),
                              );
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
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

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
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
