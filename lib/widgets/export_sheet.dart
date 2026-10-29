// lib/widgets/export_sheet.dart
//
// 내보내기 — '폴더에 저장' / '공유하기' 고르기와 그 뒤의 쓰기. 설정 · 바이브 · 정밀 참조가 같이 쓴다.
//  · 폴더에 저장: 저장 폴더(SAF)의 settings/ 안 (AppState.saveSettingsViaSaf — 임시 이름으로 다 쓴 뒤 이름만 바꾼다).
//    파일 앱 · 불러오기(문서 선택기)에서 바로 보인다. 저장 폴더가 없거나 못 쓰면 공유로 대신한다 (파일을 잃지 않게).
//  · 공유하기: 캐시에 잠깐 만들어 다른 앱으로 보낸다 (utils/temp_files.dart 의 exportTempFile).
//  ⚠️ 고르는 창이 떠 있는 동안(await) 목록이 바뀔 수 있다 — 바이브처럼 목록에서 고른 것은
//     창을 띄우기 '전에' 내용을 만들어 둔다 (DEVNOTES 5).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_theme.dart';
import '../models/app_state.dart';
import '../utils/temp_files.dart';

enum ExportTarget { folder, share }

/// '폴더에 저장' / '공유하기' 를 고르는 아래 창 ([title] 이 맨 위에). 닫으면 null.
Future<ExportTarget?> pickExportTarget(BuildContext context, AppState state, {required String title}) {
  const sub = TextStyle(color: Colors.white38, fontSize: 11);
  return showModalBottomSheet<ExportTarget>(
    context: context,
    useRootNavigator: true, // 다이얼로그 안에서 불러도 그 위에 뜨게 (다이얼로그도 맨 위 Navigator 에 뜬다)
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          const Divider(height: 1, color: Colors.white12),
          ListTile(
            leading: const Icon(Icons.folder, color: AppColors.amber),
            title: const Text("폴더에 저장", style: TextStyle(color: Colors.white)),
            subtitle: Text(
              state.safRootUri != null
                  ? "저장 폴더의 settings 안에 저장 (파일 앱 · 불러오기에서 바로 보임)"
                  : "⚠️ 저장 폴더 미설정 — 대신 공유로 내보냅니다",
              style: sub,
            ),
            onTap: () => Navigator.pop(ctx, ExportTarget.folder),
          ),
          ListTile(
            leading: const Icon(Icons.share, color: AppColors.purple),
            title: const Text("공유하기", style: TextStyle(color: Colors.white)),
            subtitle: const Text("다른 앱으로 전송 (드라이브, 메신저 등)", style: sub),
            onTap: () => Navigator.pop(ctx, ExportTarget.share),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// [bytes] 를 [fileName] 으로 [target] 에 내보낸다. 반환: 알릴 글 (공유는 null — 공유 창이 곧 결과다).
///  실패는 던진다 — 부른 쪽이 '내보내기 실패' 를 알린다.
///  [mimeType] 은 파일 확장자와 맞춘다 — 안 맞으면 안드로이드가 그 MIME 의 확장자를 덧붙인다
///  (.json → application/json, .zip → application/zip, 안드로이드가 모르는 .naiv4vibe → application/octet-stream).
Future<String?> exportToTarget(
  AppState state,
  ExportTarget target,
  String fileName,
  Uint8List bytes, {
  String mimeType = 'application/json',
}) async {
  if (target == ExportTarget.folder) {
    final String? shown = await state.saveSettingsViaSaf(fileName, bytes, mimeType: mimeType);
    if (shown != null) {
      return "저장 완료: $shown";
    }
  }
  // 공유 — 폴더에 못 썼을 때도 (조용히 실패하지 말고 파일을 잃지 않게)
  final file = await exportTempFile(fileName);
  await file.writeAsBytes(bytes);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  if (target == ExportTarget.share) {
    return null;
  }
  return state.safRootUri == null
      ? "저장 폴더가 없어 공유로 내보냈습니다. 설정에서 저장 폴더를 지정해 주세요."
      : "폴더에 저장하지 못해 공유로 내보냈습니다.";
}
