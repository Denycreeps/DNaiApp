// lib/widgets/update_dialog.dart
//
// 새 버전 알림 다이얼로그.
//  · 앱을 켰을 때 자동으로 (main.dart)
//  · 설정 > 정보에서 직접 (settings_tab.dart)
//  두 경로가 같은 화면을 쓰므로 여기 한 곳에만 둔다.
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/app_state.dart';

/// 다이얼로그가 지금 떠 있는지. 라이브러리 전역이라 어느 화면에서 열든 공유된다.
///
/// ⚠️ 예전에는 main 과 설정 화면이 각자 다른 가드를 써서,
///    자동 알림이 뜬 상태에서 설정의 '업데이트 보기'를 누르면 두 개가 겹쳐 떴다.
bool _updateDialogOpen = false;

/// 업데이트 안내를 띄운다. 이미 떠 있으면 아무것도 하지 않는다.
Future<void> showUpdateDialog(BuildContext context, AppState state) async {
  if (_updateDialogOpen) {
    return;
  }
  _updateDialogOpen = true;
  // 수동으로 열 때도 가드를 켜서, 앱 시작 시 자동 알림이 뒤늦게 겹쳐 뜨지 않게 한다.
  state.updateDialogShown = true;

  final notes = state.releaseNotePreview;
  final canInstall = state.apkDownloadUrl != null;

  try {
    await showDialog(
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
              Text(
                "v${AppState.currentVersion} → v${state.latestVersion}",
                style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  "변경 사항",
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: notes
                        .map(
                          (line) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              line,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                height: 1.4,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                const Text(
                  "새로운 업데이트가 있습니다.",
                  style: TextStyle(color: Colors.white70),
                ),
              ],
              // 설치 파일을 못 찾은 경우: 눌러도 아무 일 없는 버튼을 보여주는 대신
              // 왜 못 받는지 알려 준다.
              if (!canInstall) ...[
                const SizedBox(height: 12),
                const Text(
                  "이 릴리스에서 APK 파일을 찾지 못했습니다.\nGitHub 저장소에서 직접 받아 주세요.",
                  style: TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("닫기", style: TextStyle(color: Colors.grey)),
          ),
          if (canInstall)
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                state.downloadAndInstallUpdate(context);
              },
              icon: const Icon(Icons.download, color: Colors.white, size: 16),
              label: const Text(
                "업데이트",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
        ],
      ),
    );
  } finally {
    _updateDialogOpen = false;
  }
}
