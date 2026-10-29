// lib/models/outpaint.dart
//
// 확장 (i2i 탭 · 인페인트) — 지금 그림을 '판'(상세 환경의 해상도) 위로 옮기고 키우고 줄이고 돌려 두면,
// 비어 있는 곳을 NovelAI 인페인트가 그림에 맞춰 채운다 (사실상 아웃페인트).
//  공식 웹도 같은 방식이다: 캔버스를 키우면 새로 생긴 빈칸이 저절로 마스크가 되고, 인페인트로 채운다.
//
// 이 파일에는 화면과 떨어진 순수 계산만 둔다 — 테스트로 확인한다 (test/outpaint_test.dart).
//  · 자리: 처음 자리 · 맞춤 · 원래 크기 · 손가락으로 옮기고 키우고 돌리기 · 90° 돌리기 · 가장자리에 붙이기 · 범위 제한
//  · 자르기: 그림의 남길 곳(OutpaintRect, 그림 픽셀) — 손잡이 찾기 · 끌기 · 자른 뒤에도 그림을 제자리에
//    자리(OutpaintPlacement)는 언제나 '자른 그림' 기준이다 — 자리 계산은 자른 그림의 크기만 알면 된다.
//  · 판 짜기: 원본을 남길 곳(= 마스크 밖) · 마스크 raw · 판 그림(PNG)
//  화면(lib/screens/i2i_tab.dart)과 보내기(AppState.handleOutpaintGenerate)가 모두 여기 값을 쓴다
//  — 화면에 보이는 '새로 그릴 곳'과 실제로 보내는 마스크가 어긋나지 않게.
//
// 좌표: 판 픽셀, 오른쪽 · 아래가 + (화면과 같다). 각도는 라디안, + 가 시계 방향 (Flutter 의 Transform.rotate ·
//  두 손가락 회전(ScaleUpdateDetails.rotation)과 같은 방향).
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 빈칸은 원본이 없어 처음부터 그려야 한다 — 인페인트 강도는 늘 이 값으로 보낸다.
///  (낮추면 빈칸에 깔아 둔 흐린 바탕색이 남아 뿌옇게 나온다. 평소 인페인트 강도는 그대로 둔다)
const double kOutpaintStrength = 1.0;

/// 경계 — 그림 가장자리 안쪽으로 함께 다시 그릴 폭 (판 픽셀). 이음매가 덜 보이게 한다.
///  버튼을 누를 때마다 이 순서로 돈다 (마스크는 8픽셀 칸 단위라 8의 배수).
const List<int> kOutpaintOverlapSteps = [0, 8, 16, 32, 64];
const int kOutpaintOverlapDefault = 16;

/// [current] 다음 경계 폭 (목록에 없는 값이면 기본값부터)
int nextOutpaintOverlap(int current) {
  final int i = kOutpaintOverlapSteps.indexOf(current);
  if (i < 0) {
    return kOutpaintOverlapDefault;
  }
  return kOutpaintOverlapSteps[(i + 1) % kOutpaintOverlapSteps.length];
}

/// 그림과 판이 겹쳐야 하는 크기 (지름, 판 픽셀) — 판 밖으로 다 밀어내면 채울 기준이 없다.
///  그림이나 판이 이보다 작으면 그 크기까지만.
const double kOutpaintMinVisible = 64;

/// 배율 범위 — 돌리지 않은 '맞춤' 배율의 몇 배까지 줄이고 키울 수 있는지
const double kOutpaintMinScaleOfFit = 0.1;
const double kOutpaintMaxScaleOfFit = 8;

/// 두 손가락으로 돌릴 때 0° · 90° · 180° · 270° 에서 이 각도(라디안, 약 4°) 안이면 딱 맞춘다
const double kOutpaintAngleSnap = 4 * pi / 180;

/// 마스크 칸 — 서버로 보낼 때 8픽셀 칸으로 묶인다 (NovelAiService._processMaskForInfill:
///  칸 안에 한 픽셀이라도 칠해져 있으면 칸 전체를 다시 그린다)
const int kOutpaintMaskCell = 8;

/// 빈칸과 맞닿은 가장자리는 판을 이만큼 들인 곳으로 자른다 — 픽셀 가운데는 판 끝에서 반 픽셀 안쪽이라,
///  그보다 바깥의 가장자리 너머엔 그림으로 덮이지 않은 픽셀이 없다 (판 끝에 반 픽셀 못 미친 가장자리 때문에
///  판 끝을 따라 경계 띠를 괜히 다시 그리지 않게).
const double _clipMargin = 0.5;

/// 판 위 그림의 자리. 단위는 판의 픽셀.
class OutpaintPlacement {
  /// 그림 가운데 (판 밖으로 나가면 음수 · 판보다 큰 값도 된다)
  final double cx;
  final double cy;

  /// 그림 1픽셀이 판에서 몇 픽셀인지 (1 = 원래 크기)
  final double scale;

  /// 돌린 각도 (라디안, + 가 시계 방향, -π ~ π)
  final double angle;

  const OutpaintPlacement({
    required this.cx,
    required this.cy,
    required this.scale,
    this.angle = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is OutpaintPlacement &&
      other.cx == cx &&
      other.cy == cy &&
      other.scale == scale &&
      other.angle == angle;

  @override
  int get hashCode => Object.hash(cx, cy, scale, angle);

  @override
  String toString() => 'OutpaintPlacement(cx: $cx, cy: $cy, scale: $scale, angle: $angle)';
}

/// 정수 사각형 [x0, x1) × [y0, y1) (판 픽셀)
class OutpaintRect {
  final int x0;
  final int y0;
  final int x1;
  final int y1;

  const OutpaintRect(this.x0, this.y0, this.x1, this.y1);

  int get width => x1 - x0;
  int get height => y1 - y0;
  bool get isEmpty => x1 <= x0 || y1 <= y0;

  @override
  bool operator ==(Object other) =>
      other is OutpaintRect && other.x0 == x0 && other.y0 == y0 && other.x1 == x1 && other.y1 == y1;

  @override
  int get hashCode => Object.hash(x0, y0, x1, y1);

  @override
  String toString() => 'OutpaintRect($x0, $y0, $x1, $y1)';
}

/// 각도를 -π ~ π 로
double _normAngle(double a) {
  double r = a % (2 * pi); // Dart 의 % 는 0 ~ 2π
  if (r > pi) {
    r -= 2 * pi;
  }
  return r;
}

/// 화면에 보일 각도 (도, -179 ~ 180)
int outpaintAngleDegrees(double angle) {
  final int d = (_normAngle(angle) * 180 / pi).round();
  return d == -180 ? 180 : d;
}

// ══════════════════════════════════════════════════════════════
// 자리
// ══════════════════════════════════════════════════════════════

/// 그림 전체가 판 안에 들어가는 가장 큰 배율 ('맞춤'의 배율). [angle] 만큼 돌린 그림의 바깥 상자로 잰다.
double outpaintFitScale(int imageW, int imageH, int canvasW, int canvasH, {double angle = 0}) {
  final double c = cos(angle).abs();
  final double s = sin(angle).abs();
  final double bw = max(imageW * c + imageH * s, 1e-9);
  final double bh = max(imageW * s + imageH * c, 1e-9);
  return min(canvasW / bw, canvasH / bh);
}

/// 가운데에 맞춤 배율로 (범위 제한 전 — 돌리지 않았으면 늘 범위 안이다)
OutpaintPlacement _fitCentered(int imageW, int imageH, int canvasW, int canvasH, double angle) =>
    OutpaintPlacement(
      cx: canvasW / 2,
      cy: canvasH / 2,
      scale: outpaintFitScale(imageW, imageH, canvasW, canvasH, angle: angle),
      angle: angle,
    );

/// 맞춤 — 그림 전체가 보이게 가장 크게, 가운데 ([angle] 은 그대로)
OutpaintPlacement outpaintFit(int imageW, int imageH, int canvasW, int canvasH, {double angle = 0}) =>
    clampOutpaintPlacement(
      _fitCentered(imageW, imageH, canvasW, canvasH, angle),
      imageW,
      imageH,
      canvasW,
      canvasH,
    );

/// 원래 크기(1:1) — 그림 픽셀 그대로, 가운데 ([angle] 은 그대로). 배율 범위를 넘으면 범위 안으로.
OutpaintPlacement outpaintOriginal(int imageW, int imageH, int canvasW, int canvasH, {double angle = 0}) =>
    clampOutpaintPlacement(
      OutpaintPlacement(cx: canvasW / 2, cy: canvasH / 2, scale: 1, angle: angle),
      imageW,
      imageH,
      canvasW,
      canvasH,
    );

/// 처음 자리 (돌리지 않은 채) — 원래 크기로 판 안에 다 들어가면 원래 크기(그림을 다시 굽지 않아 가장 깨끗하다),
///  아니면 맞춤. 예) 832×1216 → 판 1024×1536: 원래 크기로 가운데, 둘레가 빈칸
///                 832×1216 → 판 1216×832: 맞춤 (세로를 판에 맞춰 줄이고 양옆이 빈칸)
OutpaintPlacement outpaintInitial(int imageW, int imageH, int canvasW, int canvasH) {
  if (imageW <= canvasW && imageH <= canvasH) {
    return outpaintOriginal(imageW, imageH, canvasW, canvasH);
  }
  return outpaintFit(imageW, imageH, canvasW, canvasH);
}

double _clampScale(double scale, int imageW, int imageH, int canvasW, int canvasH) {
  final double fit = outpaintFitScale(imageW, imageH, canvasW, canvasH);
  return scale.clamp(fit * kOutpaintMinScaleOfFit, fit * kOutpaintMaxScaleOfFit).toDouble();
}

/// 범위 안으로 — 배율은 [맞춤 × 0.1, 맞춤 × 8], 각도는 -π ~ π,
///  자리는 그림과 판의 겹친 곳에 지름 [kOutpaintMinVisible] 의 원이 들어가게 (돌려도 같은 규칙).
///  가운데가 있어도 되는 곳은 '판을 반지름만큼 줄인 것'과 '그림을 반지름만큼 줄인 것'을 더한(민코프스키 합)
///  볼록 다각형이다 — 밖이면 그 다각형에서 가장 가까운 점으로 옮긴다.
///  숫자가 아닌 값(NaN · 무한)이 들어오면 맞춤(반듯하게)으로 되돌린다.
OutpaintPlacement clampOutpaintPlacement(
  OutpaintPlacement p,
  int imageW,
  int imageH,
  int canvasW,
  int canvasH,
) {
  if (!p.cx.isFinite || !p.cy.isFinite || !p.scale.isFinite || !p.angle.isFinite || p.scale <= 0) {
    // ⚠️ outpaintFit 을 부르지 않는다 — 그건 다시 여기를 부른다 (판 크기가 0 이면 끝없이 돈다)
    return _fitCentered(imageW, imageH, canvasW, canvasH, 0);
  }
  final double s = _clampScale(p.scale, imageW, imageH, canvasW, canvasH);
  final double a = _normAngle(p.angle);
  final double w = imageW * s;
  final double h = imageH * s;
  // 겹칠 원의 반지름 — 그림 · 판이 작으면 그 크기까지만 (아래 두 사각형이 늘 뒤집히지 않게)
  final double m = min(kOutpaintMinVisible / 2, min(min(w, h), min(canvasW, canvasH).toDouble()) / 2);
  final double hw = w / 2 - m;
  final double hh = h / 2 - m;
  final double c = cos(a);
  final double sn = sin(a);
  final pts = <_Pt>[
    for (final double fx in [m, canvasW - m])
      for (final double fy in [m, canvasH - m])
        for (final double ex in [-hw, hw])
          for (final double ey in [-hh, hh]) _Pt(fx + ex * c - ey * sn, fy + ex * sn + ey * c),
  ];
  final _Pt q = _clampToHull(_convexHull(pts), _Pt(p.cx, p.cy));
  return OutpaintPlacement(cx: q.x, cy: q.y, scale: s, angle: a);
}

/// 손가락으로 옮기고 키우고 돌리기.
///  [start] 는 손가락을 댄 순간의 자리, ([fx0], [fy0]) · ([fx1], [fy1]) 는 그때와 지금의 손가락 가운데(판 픽셀),
///  [factor] 는 그때보다 손가락을 몇 배로 벌렸는지, [rotation] 은 그때보다 몇 도 돌렸는지 (라디안, 시계 방향)
///  — 한 손가락이면 1 · 0 (그냥 옮기기).
///  손가락 아래 있던 그림의 점이 계속 손가락 아래 있게 옮긴다. 각도는 0° · 90° · 180° · 270° 가까이면
///  [angleSnap] 안에서 딱 맞춘다 (맞춘 각도로 자리를 계산해 손가락 아래 점이 튀지 않는다). 결과는 범위 안이다.
OutpaintPlacement zoomOutpaintPlacement(
  OutpaintPlacement start, {
  required double fx0,
  required double fy0,
  required double fx1,
  required double fy1,
  required double factor,
  double rotation = 0,
  double angleSnap = kOutpaintAngleSnap,
  required int imageW,
  required int imageH,
  required int canvasW,
  required int canvasH,
}) {
  final double f = (factor.isFinite && factor > 0) ? factor : 1.0;
  final double r = rotation.isFinite ? rotation : 0.0;
  final double s = _clampScale(start.scale * f, imageW, imageH, canvasW, canvasH);
  double a = _normAngle(start.angle + r);
  final double quarter = (a / (pi / 2)).roundToDouble() * (pi / 2);
  if ((a - quarter).abs() <= angleSnap) {
    a = _normAngle(quarter);
  }
  // 손가락 아래에 있던 그림의 점 (그림 가운데에서, 돌리기 전 · 그림 픽셀)
  final double dx = fx0 - start.cx;
  final double dy = fy0 - start.cy;
  final double c0 = cos(start.angle);
  final double s0 = sin(start.angle);
  final double ux = (dx * c0 + dy * s0) / start.scale;
  final double uy = (-dx * s0 + dy * c0) / start.scale;
  // 그 점이 지금 손가락 아래 오도록 가운데를 정한다
  final double c1 = cos(a);
  final double s1 = sin(a);
  return clampOutpaintPlacement(
    OutpaintPlacement(
      cx: fx1 - (ux * c1 - uy * s1) * s,
      cy: fy1 - (ux * s1 + uy * c1) * s,
      scale: s,
      angle: a,
    ),
    imageW,
    imageH,
    canvasW,
    canvasH,
  );
}

/// 90° 돌리기 (시계 방향) — 지금 각도에서 다음 0° · 90° · 180° · 270° 로. 가운데 · 배율은 그대로.
OutpaintPlacement rotateOutpaintPlacement90(
  OutpaintPlacement p,
  int imageW,
  int imageH,
  int canvasW,
  int canvasH,
) {
  // 이미 딱 맞는 각도면 그다음으로 (반올림 오차로 제자리에 머물지 않게 조금 더해서 내린다)
  final double next = ((p.angle + 1e-6) / (pi / 2)).floorToDouble() * (pi / 2) + pi / 2;
  return clampOutpaintPlacement(
    OutpaintPlacement(cx: p.cx, cy: p.cy, scale: p.scale, angle: next),
    imageW,
    imageH,
    canvasW,
    canvasH,
  );
}

/// 판 가장자리 · 가운데에 가까우면 붙인다 — 한쪽으로만 늘리고 싶을 때 맞추기 쉽게.
///  그림(돌렸으면 돌린 그림의 바깥 상자)의 왼쪽 · 오른쪽 · 가운데 중 [threshold](판 픽셀) 안에서 가장 가까운 하나에만
///  붙는다. 가로 · 세로 따로, 배율 · 각도는 그대로.
OutpaintPlacement snapOutpaintPlacement(
  OutpaintPlacement p,
  int imageW,
  int imageH,
  int canvasW,
  int canvasH,
  double threshold,
) {
  final double c = cos(p.angle).abs();
  final double sn = sin(p.angle).abs();
  final double hx = (imageW * c + imageH * sn) * p.scale / 2;
  final double hy = (imageW * sn + imageH * c) * p.scale / 2;
  double snap(double pos, double half, int frame) {
    double best = pos;
    double bestD = double.infinity;
    // 왼쪽(위) 끝 · 오른쪽(아래) 끝 · 가운데
    for (final double t in [half, frame - half, frame / 2]) {
      final double d = (t - pos).abs();
      if (d <= threshold && d < bestD) {
        best = t;
        bestD = d;
      }
    }
    return best;
  }

  return OutpaintPlacement(
    cx: snap(p.cx, hx, canvasW),
    cy: snap(p.cy, hy, canvasH),
    scale: p.scale,
    angle: p.angle,
  );
}

// ══════════════════════════════════════════════════════════════
// 자르기 — 그림에서 남길 곳만 판에 놓는다 (다른 앱처럼 모서리 'ㄱ' 손잡이로)
// ══════════════════════════════════════════════════════════════
//  자른 곳은 그림 픽셀의 정수 사각형(OutpaintRect, 자르기 전 그림 기준)이다.
//  자리(OutpaintPlacement)의 가운데 · 배율 · 각도는 '자른 그림' 의 것 — 자른 곳의 가운데가 (cx, cy) 에 온다.
//  자르는 동안엔 그림이 화면에서 움직이지 않게, 자른 곳이 바뀐 만큼 가운데를 옮긴다 (outpaintRecenterForCrop).

/// 자른 곳의 가장 작은 크기 (그림 픽셀) — 그림이 이보다 작으면 그림 크기까지
const int kOutpaintMinCrop = 32;

/// 자르기 손잡이 — 모서리 넷 · 변 넷 · 자른 곳 안(통째로 옮기기)
enum OutpaintCropHandle { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move }

/// 자르지 않은 그림 전체
OutpaintRect outpaintFullCrop(int imageW, int imageH) => OutpaintRect(0, 0, imageW, imageH);

/// 판 좌표 (x, y) 가 그림(자르기 전 전체)의 어느 자리인지 (그림 픽셀, 소수) — 자리 [p] 는 자른 곳 [crop] 기준
({double u, double v}) outpaintImagePoint(OutpaintPlacement p, OutpaintRect crop, double x, double y) {
  final double c = cos(p.angle);
  final double s = sin(p.angle);
  final double dx = x - p.cx;
  final double dy = y - p.cy;
  return (
    u: (crop.x0 + crop.x1) / 2 + (dx * c + dy * s) / p.scale,
    v: (crop.y0 + crop.y1) / 2 + (-dx * s + dy * c) / p.scale,
  );
}

/// 자르기 전 그림 전체의 가운데 (판 좌표) — 화면은 그림 전체를 여기 놓고 돌린 뒤 자른 곳만 보여 준다
({double x, double y}) outpaintFullCenter(OutpaintPlacement p, OutpaintRect crop, int imageW, int imageH) {
  final double du = imageW / 2 - (crop.x0 + crop.x1) / 2;
  final double dv = imageH / 2 - (crop.y0 + crop.y1) / 2;
  final double c = cos(p.angle);
  final double s = sin(p.angle);
  return (x: p.cx + (du * c - dv * s) * p.scale, y: p.cy + (du * s + dv * c) * p.scale);
}

/// 자른 곳을 [from] 에서 [to] 로 바꿀 때의 자리 — 그림이 판에서 그대로 있게 가운데만 옮긴다 (배율 · 각도 그대로).
///  범위 제한은 하지 않는다 (끄는 동안 그림이 튀지 않게 — 다 끈 뒤 부르는 쪽이 clampOutpaintPlacement).
OutpaintPlacement outpaintRecenterForCrop(OutpaintPlacement p, OutpaintRect from, OutpaintRect to) {
  final double du = (to.x0 + to.x1) / 2 - (from.x0 + from.x1) / 2;
  final double dv = (to.y0 + to.y1) / 2 - (from.y0 + from.y1) / 2;
  final double c = cos(p.angle);
  final double s = sin(p.angle);
  return OutpaintPlacement(
    cx: p.cx + (du * c - dv * s) * p.scale,
    cy: p.cy + (du * s + dv * c) * p.scale,
    scale: p.scale,
    angle: p.angle,
  );
}

/// 손가락 (u, v) (그림 픽셀) 아래의 자르기 손잡이. [radius] 는 손가락이 닿는 범위 (그림 픽셀).
///  모서리가 먼저(가장 가까운 것), 다음 변(가장 가까운 것), 자른 곳 안이면 [OutpaintCropHandle.move], 아니면 null.
OutpaintCropHandle? hitOutpaintCrop(OutpaintRect crop, double u, double v, double radius) {
  final double r = radius.isFinite ? max(0.0, radius) : 0.0;
  final double r2 = r * r;
  OutpaintCropHandle? best;
  double bestD = double.infinity;
  for (final (OutpaintCropHandle h, int x, int y) in [
    (OutpaintCropHandle.topLeft, crop.x0, crop.y0),
    (OutpaintCropHandle.topRight, crop.x1, crop.y0),
    (OutpaintCropHandle.bottomRight, crop.x1, crop.y1),
    (OutpaintCropHandle.bottomLeft, crop.x0, crop.y1),
  ]) {
    final double d = (u - x) * (u - x) + (v - y) * (v - y);
    if (d <= r2 && d < bestD) {
      best = h;
      bestD = d;
    }
  }
  if (best != null) {
    return best;
  }
  final bool inX = u >= crop.x0 - r && u <= crop.x1 + r;
  final bool inY = v >= crop.y0 - r && v <= crop.y1 + r;
  for (final (OutpaintCropHandle h, double d, bool along) in [
    (OutpaintCropHandle.top, (v - crop.y0).abs(), inX),
    (OutpaintCropHandle.bottom, (v - crop.y1).abs(), inX),
    (OutpaintCropHandle.left, (u - crop.x0).abs(), inY),
    (OutpaintCropHandle.right, (u - crop.x1).abs(), inY),
  ]) {
    if (along && d <= r && d < bestD) {
      best = h;
      bestD = d;
    }
  }
  if (best != null) {
    return best;
  }
  if (u > crop.x0 && u < crop.x1 && v > crop.y0 && v < crop.y1) {
    return OutpaintCropHandle.move;
  }
  return null;
}

/// 손잡이 [handle] 를 (du, dv) (그림 픽셀) 만큼 끈 자른 곳 — 손가락을 댄 순간의 자른 곳 [start] 에서.
///  그림 밖으로는 못 나가고, [minSize](기본 [kOutpaintMinCrop]) 보다 좁아지지 않는다. 통째로 옮기기는 크기를 지킨 채 그림 안에서만.
///  부분 인페인트의 상자도 같은 손잡이로 끈다 (focus_inpaint.dart 의 dragFocusBox — 가장 작은 변만 다르다).
OutpaintRect dragOutpaintCrop(
  OutpaintRect start,
  OutpaintCropHandle handle,
  double du,
  double dv,
  int imageW,
  int imageH, {
  int minSize = kOutpaintMinCrop,
}) {
  if (!du.isFinite || !dv.isFinite) {
    return start;
  }
  final int dx = du.round();
  final int dy = dv.round();
  if (handle == OutpaintCropHandle.move) {
    final int sx = dx.clamp(min(0, -start.x0), max(0, imageW - start.x1));
    final int sy = dy.clamp(min(0, -start.y0), max(0, imageH - start.y1));
    return OutpaintRect(start.x0 + sx, start.y0 + sy, start.x1 + sx, start.y1 + sy);
  }
  final int minW = min(minSize, imageW);
  final int minH = min(minSize, imageH);
  int x0 = start.x0;
  int y0 = start.y0;
  int x1 = start.x1;
  int y1 = start.y1;
  // clamp 의 아래가 위보다 크면 오류라, 범위를 먼저 바로잡는다 (이상한 시작값이 와도 멈추지 않게)
  int clampTo(int v, int lo, int hi) => v.clamp(lo, max(lo, hi));
  const lefts = {OutpaintCropHandle.topLeft, OutpaintCropHandle.left, OutpaintCropHandle.bottomLeft};
  const rights = {OutpaintCropHandle.topRight, OutpaintCropHandle.right, OutpaintCropHandle.bottomRight};
  const tops = {OutpaintCropHandle.topLeft, OutpaintCropHandle.top, OutpaintCropHandle.topRight};
  const bottoms = {OutpaintCropHandle.bottomLeft, OutpaintCropHandle.bottom, OutpaintCropHandle.bottomRight};
  if (lefts.contains(handle)) {
    x0 = clampTo(start.x0 + dx, 0, start.x1 - minW);
  }
  if (rights.contains(handle)) {
    x1 = clampTo(start.x1 + dx, min(start.x0 + minW, imageW), imageW);
  }
  if (tops.contains(handle)) {
    y0 = clampTo(start.y0 + dy, 0, start.y1 - minH);
  }
  if (bottoms.contains(handle)) {
    y1 = clampTo(start.y1 + dy, min(start.y0 + minH, imageH), imageH);
  }
  return OutpaintRect(x0, y0, x1, y1);
}

// ══════════════════════════════════════════════════════════════
// 판 짜기
// ══════════════════════════════════════════════════════════════

/// 판 위에 놓인 그림 — '이 점이 그림 안인가' · '그림 좌표로' 를 한 곳에서 (마스크 · 판 짜기가 같이 쓴다)
class _Placed {
  final double cx;
  final double cy;
  final double c; // cos(각도)
  final double s; // sin(각도)
  final double hw; // 그림 반 폭 (판 픽셀)
  final double hh;

  /// 칸 꼭짓점 · 판 모서리를 볼 때의 여유 — 꼭짓점 넷이 그림을 이만큼 넓힌 곳 안이면 칸 안 픽셀 가운데는 모두 그림 안이다.
  ///  (픽셀 가운데는 칸 테두리에서 가로 · 세로 반 픽셀 안쪽 — 그림 변의 방향으로 재면 0.5 × (|cos| + |sin|))
  ///  판 짜기는 픽셀 가운데가 그림 안인 픽셀만 그림으로 칠하므로, 남긴 칸에 흐린 바탕이 남지 않는다.
  final double cornerTolerance;

  _Placed(OutpaintPlacement p, int imageW, int imageH)
    : cx = p.cx,
      cy = p.cy,
      c = cos(p.angle),
      s = sin(p.angle),
      hw = imageW * p.scale / 2,
      hh = imageH * p.scale / 2,
      cornerTolerance = 0.5 * (cos(p.angle).abs() + sin(p.angle).abs());

  /// 그림 가운데 기준 · 돌리기 전 좌표 (판 픽셀 단위)
  double localX(double x, double y) => (x - cx) * c + (y - cy) * s;
  double localY(double x, double y) => -(x - cx) * s + (y - cy) * c;

  /// (x, y) 가 그림 안인지 (가장자리 포함) — [tolerance] 를 주면 그만큼 넉넉히
  bool contains(double x, double y, [double tolerance = 0]) =>
      localX(x, y).abs() <= hw + tolerance && localY(x, y).abs() <= hh + tolerance;

  /// 네 모서리 (판 좌표, 둘레 순서)
  List<_Pt> corners() => [
    for (final (double ex, double ey) in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)])
      _Pt(cx + ex * c - ey * s, cy + ex * s + ey * c),
  ];

  /// 빈칸과 맞닿은 그림 가장자리 — 네 변을 판 안쪽([_clipMargin] 만큼 들인 곳)으로 자른 것.
  ///  판 끝에 닿았거나 판 밖에 있는 변은 빠진다 (그쪽엔 채울 빈칸이 없다).
  List<(_Pt, _Pt)> emptyEdges(int canvasW, int canvasH) {
    final cs = corners();
    final out = <(_Pt, _Pt)>[];
    for (int i = 0; i < 4; i++) {
      final seg = _clipSegment(
        cs[i],
        cs[(i + 1) % 4],
        _clipMargin,
        _clipMargin,
        canvasW - _clipMargin,
        canvasH - _clipMargin,
      );
      if (seg != null) {
        out.add(seg);
      }
    }
    return out;
  }
}

/// 채울 빈칸이 없는지 — 그림이 판을 다 덮었다 (판의 네 모서리가 다 그림 안)
bool outpaintNothingToFill(OutpaintPlacement p, int imageW, int imageH, int canvasW, int canvasH) {
  final g = _Placed(p, imageW, imageH);
  final double w = canvasW.toDouble();
  final double h = canvasH.toDouble();
  final double t = g.cornerTolerance;
  return g.contains(0, 0, t) && g.contains(w, 0, t) && g.contains(0, h, t) && g.contains(w, h, t);
}

/// 원본을 그대로 남길 곳 (= 마스크 밖) — 8픽셀 칸을 줄마다 이은 사각형들 (위아래로 같은 줄은 합친다).
///  나머지는 전부 새로 그린다.
///  칸을 남기는 조건: 칸의 네 모서리가 모두 그림 안이고, 빈칸과 맞닿은 그림 가장자리에서 [overlap] 이상 떨어져 있다
///  (경계 — 이음매를 같이 다시 그리게). 판 끝에 닿거나 판 밖으로 넘친 가장자리는 따지지 않는다.
///  서버가 마스크를 8픽셀 칸으로 묶으므로(칸에 한 픽셀이라도 칠하면 칸 전체) 처음부터 칸으로 계산한다
///  — 화면 표시와 보내는 마스크가 같다. 남길 곳이 없으면 빈 목록 (그림이 너무 작아 경계가 다 먹은 경우).
List<OutpaintRect> outpaintKeepRects(
  OutpaintPlacement p,
  int imageW,
  int imageH,
  int canvasW,
  int canvasH,
  int overlap,
) {
  const int cell = kOutpaintMaskCell;
  final int gw = canvasW ~/ cell;
  final int gh = canvasH ~/ cell;
  if (gw <= 0 || gh <= 0 || !(p.scale > 0) || !p.scale.isFinite) {
    return const [];
  }
  final g = _Placed(p, imageW, imageH);
  final edges = g.emptyEdges(canvasW, canvasH);
  final double ov2 = pow(max(0, overlap), 2).toDouble();
  // 칸 꼭짓점마다 '남겨도 되는지'
  final int vw = gw + 1;
  final good = Uint8List(vw * (gh + 1));
  for (int vy = 0; vy <= gh; vy++) {
    final double y = (vy * cell).toDouble();
    for (int vx = 0; vx <= gw; vx++) {
      final double x = (vx * cell).toDouble();
      if (!g.contains(x, y, g.cornerTolerance)) {
        continue;
      }
      if (ov2 > 0 && edges.any((e) => _distSqToSegment(x, y, e.$1, e.$2) < ov2)) {
        continue;
      }
      good[vy * vw + vx] = 1;
    }
  }
  bool cellGood(int gx, int gy) =>
      good[gy * vw + gx] == 1 &&
      good[gy * vw + gx + 1] == 1 &&
      good[(gy + 1) * vw + gx] == 1 &&
      good[(gy + 1) * vw + gx + 1] == 1;

  final rects = <OutpaintRect>[];
  // 바로 윗줄에서 끝난 사각형 (가로 범위 → rects 번호) — 같은 범위면 아래로 늘린다
  var open = <(int, int), int>{};
  for (int gy = 0; gy < gh; gy++) {
    final next = <(int, int), int>{};
    int gx = 0;
    while (gx < gw) {
      if (!cellGood(gx, gy)) {
        gx++;
        continue;
      }
      int end = gx;
      while (end < gw && cellGood(end, gy)) {
        end++;
      }
      final (int, int) span = (gx * cell, end * cell);
      final int? at = open[span];
      if (at != null) {
        final r = rects[at];
        rects[at] = OutpaintRect(r.x0, r.y0, r.x1, r.y1 + cell);
        next[span] = at;
      } else {
        rects.add(OutpaintRect(span.$1, gy * cell, span.$2, gy * cell + cell));
        next[span] = rects.length - 1;
      }
      gx = end;
    }
    open = next;
  }
  return rects;
}

/// 마스크 raw — 머리(가로 · 세로 4바이트씩) + 픽셀마다 1바이트 (255 = 새로 그릴 곳).
///  인페인트 붓 마스크(i2i_tab 의 _buildMaskRaw)와 같은 모양이라 같은 길로 보낸다
///  (NovelAiService._processMaskForInfill). [keep] 이 비었으면 판 전체를 새로 그린다.
Uint8List outpaintMaskRaw(int canvasW, int canvasH, List<OutpaintRect> keep) {
  final raw = Uint8List(8 + canvasW * canvasH);
  final header = ByteData.sublistView(raw);
  header.setUint32(0, canvasW);
  header.setUint32(4, canvasH);
  raw.fillRange(8, raw.length, 255);
  for (final k in keep) {
    final int x0 = k.x0.clamp(0, canvasW);
    final int x1 = k.x1.clamp(x0, canvasW);
    final int y0 = k.y0.clamp(0, canvasH);
    final int y1 = k.y1.clamp(y0, canvasH);
    for (int y = y0; y < y1; y++) {
      final int row = 8 + y * canvasW;
      raw.fillRange(row + x0, row + x1, 0);
    }
  }
  return raw;
}

/// 판 짜기 일감 — compute 로 다른 isolate 에 넘긴다 (그림 풀기 · 판 픽셀마다 집어 오기 · PNG 굽기가 무겁다)
class OutpaintJob {
  final Uint8List image;

  /// 그림 크기 (자르기 전 전체) — 화면이 자리를 잡은 기준 (AppState.i2iImageSize). 실제 그림 크기가 다르면 이 크기로 맞춘다.
  final int imageW;
  final int imageH;
  final int canvasW;
  final int canvasH;

  /// 자리 — 자른 그림 기준 ([crop] 이 없으면 그림 전체)
  final OutpaintPlacement placement;
  final int overlap;

  /// 남길 곳 (그림 픽셀, [imageW] × [imageH] 기준). null 이면 자르지 않는다.
  final OutpaintRect? crop;

  const OutpaintJob({
    required this.image,
    required this.imageW,
    required this.imageH,
    required this.canvasW,
    required this.canvasH,
    required this.placement,
    required this.overlap,
    this.crop,
  });
}

/// 짠 판 — 보낼 그림(PNG, 판 크기 · 3채널)과 마스크 raw
class OutpaintCanvas {
  final Uint8List png;
  final Uint8List mask;

  const OutpaintCanvas(this.png, this.mask);
}

/// 판을 짠다 — 판의 픽셀마다 그림 좌표로 되돌려 색을 집어 오고(돌린 그림도 같은 길),
///  그림 밖(빈칸)은 가장 가까운 그림 가장자리 색을 늘인 뒤 크게 흐려 깐다 (회색 판보다 이어지는 색이 자연스럽다).
///  마스크도 같이 만든다. 그림을 못 읽거나 판과 안 겹치면 null.
///  ⚠️ 무겁다 — compute 로 부른다.
OutpaintCanvas? composeOutpaint(OutpaintJob job) {
  img.Image? src;
  try {
    src = img.decodeImage(job.image);
  } catch (_) {
    src = null; // 깨진 파일은 디코더가 던지기도 한다
  }
  if (src == null) {
    return null;
  }
  // 회전 정보가 있는 사진은 화면에 보이는 방향으로 (Flutter 도 돌려서 보여 준다)
  //  — 그대로 두면 아래 copyResize 가 따로 돌려 버린다
  if (src.exif.imageIfd.hasOrientation && src.exif.imageIfd.orientation != 1) {
    src = img.bakeOrientation(src);
  }
  // 8비트 3채널로 (16비트 · 팔레트 · 투명 채널은 아래에서 바이트를 그대로 읽을 수 없다)
  //  투명한 곳은 보낼 때도 색만 남는다 (NovelAiService._processImage3Channel 과 같다)
  if (src.format != img.Format.uint8 || src.numChannels != 3 || src.hasPalette) {
    src = src.convert(format: img.Format.uint8, numChannels: 3);
  }
  int iw = job.imageW;
  int ih = job.imageH;
  // 자르기 — 남길 곳만 잘라 낸 그림을 놓는다 (자리는 자른 그림 기준이다)
  //  실제 그림이 그림 정보의 크기와 다르면(썸네일 등) 자른 곳도 그 비율로 옮겨 자른다.
  final OutpaintRect? crop = job.crop;
  if (crop != null &&
      iw > 0 &&
      ih > 0 &&
      !crop.isEmpty &&
      !(crop.x0 <= 0 && crop.y0 <= 0 && crop.x1 >= iw && crop.y1 >= ih)) {
    final double rx = src.width / iw;
    final double ry = src.height / ih;
    final int x0 = (crop.x0 * rx).round().clamp(0, src.width - 1);
    final int y0 = (crop.y0 * ry).round().clamp(0, src.height - 1);
    final int x1 = (crop.x1 * rx).round().clamp(x0 + 1, src.width);
    final int y1 = (crop.y1 * ry).round().clamp(y0 + 1, src.height);
    src = img.copyCrop(src, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
    iw = crop.width;
    ih = crop.height;
  }
  final OutpaintPlacement p = job.placement;
  if (iw <= 0 || ih <= 0 || !(p.scale > 0) || !p.scale.isFinite) {
    return null;
  }
  // 줄여 놓을 때는 미리 그 배율 가까이로 줄여 둔다 (한 점씩 집어 오면 자글자글해진다).
  //  키울 때는 원래 그림에서 바로 집어 온다 — 그림 전체를 키워 두지 않는다 (메모리).
  //  그림 정보의 크기와 실제 크기가 다르면(썸네일 등) 여기서 같이 맞춘다.
  final int tw = p.scale < 1 ? max(1, (iw * p.scale).round()) : iw;
  final int th = p.scale < 1 ? max(1, (ih * p.scale).round()) : ih;
  if (src.width != tw || src.height != th) {
    src = img.copyResize(
      src,
      width: tw,
      height: th,
      interpolation: (tw < src.width || th < src.height)
          ? img.Interpolation.average
          : img.Interpolation.linear,
    );
  }
  final int sw = src.width;
  final int sh = src.height;
  final Uint8List sb = src.getBytes(order: img.ChannelOrder.rgb);
  final double fx = sw / iw; // 집어 올 그림의 픽셀 ÷ 그림 픽셀
  final double fy = sh / ih;

  final int cw = job.canvasW;
  final int ch = job.canvasH;
  final g = _Placed(p, iw, ih);
  final out = Uint8List(cw * ch * 3);
  final covered = Uint8List(cw * ch);
  int coveredCount = 0;
  for (int y = 0; y < ch; y++) {
    final double py = y + 0.5; // 픽셀 가운데
    for (int x = 0; x < cw; x++) {
      final double px = x + 0.5;
      final int i = y * cw + x;
      if (g.contains(px, py)) {
        covered[i] = 1;
        coveredCount++;
      }
      // 그림 좌표 (밖이면 가장 가까운 가장자리로 — 빈칸 바탕용)
      final double u = (g.localX(px, py) / p.scale + iw / 2).clamp(0.0, iw.toDouble());
      final double v = (g.localY(px, py) / p.scale + ih / 2).clamp(0.0, ih.toDouble());
      // 이중 선형으로 집어 온다 (원래 크기 · 정수 자리면 픽셀이 그대로 옮겨진다)
      final double sx = (u * fx - 0.5).clamp(0.0, sw - 1.0);
      final double sy = (v * fy - 0.5).clamp(0.0, sh - 1.0);
      final int x0 = sx.floor();
      final int y0 = sy.floor();
      final int x1 = min(x0 + 1, sw - 1);
      final int y1 = min(y0 + 1, sh - 1);
      final double ax = sx - x0;
      final double ay = sy - y0;
      final int o00 = (y0 * sw + x0) * 3;
      final int o01 = (y0 * sw + x1) * 3;
      final int o10 = (y1 * sw + x0) * 3;
      final int o11 = (y1 * sw + x1) * 3;
      final int d = i * 3;
      for (int k = 0; k < 3; k++) {
        final double top = sb[o00 + k] + (sb[o01 + k] - sb[o00 + k]) * ax;
        final double bottom = sb[o10 + k] + (sb[o11 + k] - sb[o10 + k]) * ax;
        out[d + k] = (top + (bottom - top) * ay).round().clamp(0, 255);
      }
    }
  }
  if (coveredCount == 0) {
    return null; // 판과 안 겹친다
  }

  // 빈칸 바탕 — 가장자리 색을 늘인 판(위에서 이미 out 에 들어 있다)을 크게 흐려서, 그림이 없는 곳에만 깐다
  if (coveredCount < cw * ch) {
    final small = img.copyResize(
      img.Image.fromBytes(width: cw, height: ch, bytes: Uint8List.fromList(out).buffer, numChannels: 3),
      width: max(1, cw ~/ 32),
      height: max(1, ch ~/ 32),
      interpolation: img.Interpolation.average,
    );
    final Uint8List soft = img
        .copyResize(small, width: cw, height: ch, interpolation: img.Interpolation.linear)
        .getBytes(order: img.ChannelOrder.rgb);
    for (int i = 0; i < cw * ch; i++) {
      if (covered[i] == 0) {
        final int d = i * 3;
        out[d] = soft[d];
        out[d + 1] = soft[d + 1];
        out[d + 2] = soft[d + 2];
      }
    }
  }

  // 압축은 가볍게 — 보내기 전에 한 번 더 3채널 PNG 로 다시 굽는다 (NovelAiService._processImage3Channel)
  final png = img.encodePng(
    img.Image.fromBytes(width: cw, height: ch, bytes: out.buffer, numChannels: 3),
    level: 1,
  );
  final mask = outpaintMaskRaw(cw, ch, outpaintKeepRects(p, iw, ih, cw, ch, job.overlap));
  return OutpaintCanvas(png, mask);
}

// ══════════════════════════════════════════════════════════════
// 작은 기하 도구
// ══════════════════════════════════════════════════════════════

class _Pt {
  final double x;
  final double y;

  const _Pt(this.x, this.y);
}

double _cross(_Pt o, _Pt a, _Pt b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

/// 볼록 껍질 (모노톤 체인). 점이 한 점 · 한 줄로 모이면 1 · 2개만 돌려준다.
List<_Pt> _convexHull(List<_Pt> pts) {
  final sorted = [...pts]..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  if (sorted.length <= 1) {
    return sorted;
  }
  final lower = <_Pt>[];
  for (final p in sorted) {
    while (lower.length >= 2 && _cross(lower[lower.length - 2], lower.last, p) <= 1e-9) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <_Pt>[];
  for (final p in sorted.reversed) {
    while (upper.length >= 2 && _cross(upper[upper.length - 2], upper.last, p) <= 1e-9) {
      upper.removeLast();
    }
    upper.add(p);
  }
  final hull = [...lower.sublist(0, lower.length - 1), ...upper.sublist(0, upper.length - 1)];
  if (hull.isEmpty) {
    return [sorted.first]; // 전부 같은 점
  }
  return hull;
}

/// 선분 a-b 위에서 p 에 가장 가까운 점
_Pt _nearestOnSegment(_Pt a, _Pt b, _Pt p) {
  final double dx = b.x - a.x;
  final double dy = b.y - a.y;
  final double len2 = dx * dx + dy * dy;
  if (len2 <= 0) {
    return a;
  }
  final double t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / len2).clamp(0.0, 1.0);
  return _Pt(a.x + dx * t, a.y + dy * t);
}

double _distSq(_Pt a, _Pt b) => (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y);

double _distSqToSegment(double x, double y, _Pt a, _Pt b) {
  final p = _Pt(x, y);
  return _distSq(p, _nearestOnSegment(a, b, p));
}

/// p 를 볼록 다각형 [hull](_convexHull 순서) 안으로 — 안이면 그대로, 밖이면 가장 가까운 테두리 점
_Pt _clampToHull(List<_Pt> hull, _Pt p) {
  if (hull.length == 1) {
    return hull.first;
  }
  if (hull.length == 2) {
    return _nearestOnSegment(hull[0], hull[1], p);
  }
  bool inside = true;
  for (int i = 0; i < hull.length; i++) {
    if (_cross(hull[i], hull[(i + 1) % hull.length], p) < -1e-9) {
      inside = false;
      break;
    }
  }
  if (inside) {
    return p;
  }
  _Pt best = hull.first;
  double bestD = double.infinity;
  for (int i = 0; i < hull.length; i++) {
    final q = _nearestOnSegment(hull[i], hull[(i + 1) % hull.length], p);
    final double d = _distSq(q, p);
    if (d < bestD) {
      bestD = d;
      best = q;
    }
  }
  return best;
}

/// 선분 a-b 를 사각형 [x0, x1] × [y0, y1] 안으로 자른다 (리앙-바스키). 안 겹치면 null.
(_Pt, _Pt)? _clipSegment(_Pt a, _Pt b, double x0, double y0, double x1, double y1) {
  if (x1 < x0 || y1 < y0) {
    return null;
  }
  final double dx = b.x - a.x;
  final double dy = b.y - a.y;
  double t0 = 0;
  double t1 = 1;
  // (p, q): p·t ≤ q 꼴의 네 조건
  for (final (double pp, double qq) in [
    (-dx, a.x - x0),
    (dx, x1 - a.x),
    (-dy, a.y - y0),
    (dy, y1 - a.y),
  ]) {
    if (pp == 0) {
      if (qq < 0) {
        return null; // 평행한데 밖
      }
      continue;
    }
    final double t = qq / pp;
    if (pp < 0) {
      if (t > t1) {
        return null;
      }
      if (t > t0) {
        t0 = t;
      }
    } else {
      if (t < t0) {
        return null;
      }
      if (t < t1) {
        t1 = t;
      }
    }
  }
  return (_Pt(a.x + dx * t0, a.y + dy * t0), _Pt(a.x + dx * t1, a.y + dy * t1));
}
