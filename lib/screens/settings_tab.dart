import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../models/app_state.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                        "세션 동안 저장된 이미지",
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Text(
                    "${state.sessionSaveCount} 장",
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
            const SizedBox(height: 24),

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
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(const SnackBar(content: Text("폴더 경로가 선택되었습니다!")));
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
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text("경로 및 파일 이름이 저장되었습니다.")));
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
            const SizedBox(height: 24),

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

                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("계정 정보(Anlas/구독 등급) 동기화 완료!")),
                            );
                          } else {
                            state.isApiConnected = false;
                            await state.saveAllSettings();
                            state.refreshUI();

                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(const SnackBar(content: Text("API 토큰을 입력해주세요.")));
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
            ],
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
            ],

            const SizedBox(height: 24),

            // 🚀 [새 기능] Gelbooru API 키 입력 영역 추가!
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
                    "Gelbooru API 설정 (선택)",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    "익명 검색 제한을 해제하려면 '&api_key=...&user_id=...' 형식의 텍스트를 입력하세요.",
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: state.gelbooruApiController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _settingsInputDecoration("여기에 복사한 텍스트를 붙여넣으세요", Icons.api_rounded),
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
                        color: (state.gelbooruUserId.isNotEmpty && state.gelbooruApiKey.isNotEmpty)
                            ? Colors.tealAccent.withValues(alpha: 0.1)
                            : Colors.redAccent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color:
                              (state.gelbooruUserId.isNotEmpty && state.gelbooruApiKey.isNotEmpty)
                              ? Colors.tealAccent.withValues(alpha: 0.3)
                              : Colors.redAccent.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            (state.gelbooruUserId.isNotEmpty && state.gelbooruApiKey.isNotEmpty)
                                ? Icons.check_circle
                                : Icons.error,
                            color:
                                (state.gelbooruUserId.isNotEmpty && state.gelbooruApiKey.isNotEmpty)
                                ? Colors.tealAccent
                                : Colors.redAccent,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              (state.gelbooruUserId.isNotEmpty && state.gelbooruApiKey.isNotEmpty)
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
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
