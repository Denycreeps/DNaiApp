// lib/widgets/update_dialog.dart
//
// 업데이트 안내 창 — 앱을 켰을 때 자동으로(main.dart)도, 설정에서 직접(설정탭)도 이 창 하나를 쓴다.
//  ⚠️ 예전엔 두 곳에 따로 있어 모양이 달랐다 (설정 쪽엔 버전 줄이 없고, 받을 파일이 없어도
//     업데이트 버튼이 보여 누르면 오류 안내가 떴다). 겹쳐 뜨기를 막는 표시도 각자였다.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../models/app_state.dart';
import 'app_toast.dart';

// 지금 떠 있는지 (자동·직접 어느 쪽이 먼저 열었든 또 열지 않는다)
bool _visible = false;

/// 업데이트 안내 창을 띄운다. 이미 떠 있으면 아무것도 하지 않는다.
///  띄우면 이번 실행에서는 자동 알림이 다시 뜨지 않는다 (AppState.updateDialogShown).
Future<void> showUpdateDialog(BuildContext context, AppState state) async {
  if (_visible) {
    return;
  }
  _visible = true;
  state.updateDialogShown = true;
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
              const SizedBox(height: 12),
              if (state.releaseNotePreview.isNotEmpty) ...[
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
                    children: [
                      for (final line in state.releaseNotePreview)
                        Padding(
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
                    ],
                  ),
                ),
              ] else
                const Text("새로운 업데이트가 있습니다.", style: TextStyle(color: Colors.white70)),
              // 이번 버전의 GitHub 릴리즈 화면 — 위 미리보기는 10줄 · 줄당 40자까지라
              //  전체 내용·스크린샷·첨부 파일은 거기서 본다.
              //  ⚠️ 내용 칸 자체를 누르게 하지 않았다: 누를 수 있다는 표시가 없고,
              //     긴 내역을 스크롤하다 손가락이 닿으면 뜻하지 않게 브라우저로 넘어간다.
              //  ⚠️ 아래 버튼 줄에도 넣지 않았다: [닫기][GitHub][업데이트] 셋이면
              //     좁은 폰에서 버튼이 세로로 쌓인다. 게다가 주인공은 '업데이트' 버튼이다.
              //  창은 닫지 않는다 — 읽고 돌아와서 바로 업데이트를 누를 수 있게.
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _openReleasePage(ctx, state),
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: const Text("GitHub에서 전체 내역 보기", style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("닫기", style: TextStyle(color: Colors.grey)),
          ),
          // 받을 파일이 있을 때만 (없으면 눌러도 '찾을 수 없습니다' 안내만 뜬다)
          if (state.apkDownloadUrl != null)
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
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
        ],
      ),
    );
  } finally {
    _visible = false;
  }
}

/// 이번 업데이트의 GitHub 릴리즈 화면을 브라우저로 연다.
///  주소는 업데이트 확인 때 받아 둔 것(AppState.updateUrl). 없으면 릴리즈 목록으로 간다.
Future<void> _openReleasePage(BuildContext context, AppState state) async {
  final String url = state.updateUrl ?? 'https://github.com/${AppState.githubRepo}/releases';
  bool ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false; // 주소가 이상하거나 열 앱이 없음
  }
  if (!ok && context.mounted) {
    showToast(context, "브라우저를 열 수 없어요: $url", length: ToastLength.long);
  }
}
