// lib/widgets/dict_image_viewer.dart
//
// 프롬프트 사전 이미지를 크게 본다 (핀치로 확대).
//  사전 목록 · 사전 편집 창 · 확대 입력창의 📖 선택 창이 같은 화면을 쓴다.
//
//  큰 이미지는 파일로 따로 있어서 열 때만 읽는다(loadLarge).
//  없으면(분류 기능 이전에 만든 항목 등) 작은 썸네일을 대신 보여 주고 안내한다.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_theme.dart';

Future<void> showDictImageViewer(
  BuildContext context, {
  required String title,
  required Future<Uint8List?> Function() loadLarge,
  Uint8List? thumb,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    builder: (_) => _DictImageViewer(title: title, loadLarge: loadLarge, thumb: thumb),
  );
}

class _DictImageViewer extends StatefulWidget {
  final String title;
  final Future<Uint8List?> Function() loadLarge;
  final Uint8List? thumb;

  const _DictImageViewer({required this.title, required this.loadLarge, this.thumb});

  @override
  State<_DictImageViewer> createState() => _DictImageViewerState();
}

class _DictImageViewerState extends State<_DictImageViewer> {
  // build 마다 다시 읽지 않도록 한 번만 만든다
  late final Future<Uint8List?> _large = widget.loadLarge();

  @override
  Widget build(BuildContext context) {
    // ⚠️ 창이 화면을 꽉 채워서, 보통 다이얼로그처럼 '바깥'을 눌러 닫을 곳이 없다.
    //    그래서 그림이 아닌 곳(빈 배경·제목줄)을 누르면 닫히게 한다.
    //    그림 위를 누른 건 닫지 않는다 — 확대해서 들여다보는 중일 수 있다.
    //    (닫기 버튼·뒤로가기로도 닫힌다)
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(context),
        child: SafeArea(
          child: Column(
            children: [
              // 제목 + 닫기
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<Uint8List?>(
                  future: _large,
                  builder: (ctx, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return Center(child: CircularProgressIndicator(color: AppColors.accent));
                    }
                    final large = snap.data;
                    final bytes = large ?? widget.thumb;
                    if (bytes == null) {
                      return const Center(
                        child: Text(
                          "등록된 이미지가 없습니다.",
                          style: TextStyle(color: Colors.white54, fontSize: 14),
                        ),
                      );
                    }
                    return Column(
                      children: [
                        Expanded(
                          child: InteractiveViewer(
                            minScale: 1,
                            maxScale: 5,
                            child: Center(
                              // 그림 위의 탭은 여기서 받아 버린다 → 바깥쪽 '닫기'까지 가지 않는다
                              child: GestureDetector(
                                onTap: () {},
                                child: Image.memory(
                                  bytes,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  // 작은 썸네일을 크게 늘릴 땐 부드럽게 (계단 현상 줄이기)
                                  filterQuality: FilterQuality.medium,
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 큰 이미지가 없어 작은 썸네일로 대신 보여 주는 중이면 알려 준다
                        if (large == null)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                            child: Text(
                              "작은 미리보기만 있어 흐리게 보입니다.\n"
                              "편집에서 이미지를 다시 넣으면 크게 볼 수 있어요.",
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
