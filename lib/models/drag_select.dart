// lib/models/drag_select.dart
//
// 갤러리 그리드의 '꾹 누른 채 끌어서 여러 장 고르기' 계산 — 화면과 무관한 순수 함수 (test/drag_select_test.dart).
//  · gridIndexAt         — 손가락 위치(그리드 안 좌표 + 스크롤)가 몇 번째 칸인지
//  · dragRangeSelect     — 꾹 누른 칸부터 지금 칸까지를 고르거나 푼 결과
//  · dragAutoScrollSpeed — 손가락이 위 · 아래 끝에 있을 때 저절로 굴릴 거리
//  쓰는 곳: widgets/gallery_view.dart (GalleryViewState 의 _onGridLongPress…)
import 'dart:math';

/// 고정 열 · 정사각 칸 그리드의 모양 — GalleryView 의 GridView 와 같은 값이어야 한다.
///  [width] 는 그리드(보이는 영역)의 폭, [padding] 은 네 변 여백, [spacing] 은 칸 사이 (가로 · 세로 같다).
typedef DragGrid = ({double width, int columns, double padding, double spacing});

/// 그리드 안 좌표 ([x], [y] — 보이는 영역의 왼쪽 위 기준) 가 몇 번째 칸인지. 칸이 없으면 null.
///  · 끌기 중(기본): 칸 사이 틈 · 여백 · 마지막 칸 아래도 가장 가까운 칸으로 본다 (손가락이 틈에 걸려도 끊기지 않게).
///  · [exact] — 꾹 누르기를 시작할 때: 칸 위가 아니면(틈 · 여백 · 빈 자리) null.
int? gridIndexAt(
  DragGrid g,
  double x,
  double y,
  double scrollOffset,
  int itemCount, {
  bool exact = false,
}) {
  if (itemCount <= 0 || g.columns <= 0) {
    return null;
  }
  final double tile = (g.width - g.padding * 2 - g.spacing * (g.columns - 1)) / g.columns;
  if (tile <= 0) {
    return null;
  }
  final double stride = tile + g.spacing;
  final double cx = x - g.padding;
  final double cy = y + scrollOffset - g.padding;
  if (exact) {
    if (cx < 0 || cy < 0 || cx % stride >= tile || cy % stride >= tile) {
      return null; // 여백 · 칸 사이 틈
    }
    final int col = (cx / stride).floor();
    final int index = (cy / stride).floor() * g.columns + col;
    return (col < g.columns && index < itemCount) ? index : null;
  }
  final int col = (cx / stride).floor().clamp(0, g.columns - 1);
  final int row = max(0, (cy / stride).floor());
  return min(row * g.columns + col, itemCount - 1);
}

/// 꾹 누른 칸 [anchor] 부터 지금 칸 [current] 까지 (양 끝 포함) 를 [adds] 면 고르고, 아니면 푼 결과.
///  [base] 는 끌기 전에 골라 둔 것 — 범위를 되돌려 줄이면 그 칸들은 원래대로 돌아간다 (일반 갤러리 앱처럼).
///  [idAt] 은 칸 번호 → 그림 id (폴더 칸 · 목록 밖은 null — 건너뛴다).
Set<String> dragRangeSelect({
  required Set<String> base,
  required int anchor,
  required int current,
  required bool adds,
  required String? Function(int index) idAt,
}) {
  final Set<String> out = {...base};
  final int lo = min(anchor, current);
  final int hi = max(anchor, current);
  for (int i = lo; i <= hi; i++) {
    final String? id = idAt(i);
    if (id == null) {
      continue;
    }
    if (adds) {
      out.add(id);
    } else {
      out.remove(id);
    }
  }
  return out;
}

/// 손가락이 그리드의 위 · 아래 끝 [edge] 안에 있으면 한 번(약 16ms)에 굴릴 거리 — 위로는 -, 아래로는 +, 아니면 0.
///  끝에 가까울수록(그리드 밖으로 나가면 최대) 빠르다. [y] 는 그리드 안 좌표, [height] 는 그리드 높이.
///  그리드가 낮으면 가장자리를 높이의 1/4 로 줄인다 (가운데가 늘 남게).
double dragAutoScrollSpeed(double y, double height, {double edge = 64, double maxStep = 20}) {
  if (height <= 0) {
    return 0;
  }
  final double e = min(edge, height / 4);
  if (y < e) {
    return -maxStep * ((e - y) / e).clamp(0.0, 1.0);
  }
  if (y > height - e) {
    return maxStep * ((y - (height - e)) / e).clamp(0.0, 1.0);
  }
  return 0;
}
