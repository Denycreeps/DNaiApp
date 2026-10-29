// lib/models/focus_inpaint.dart
//
// 부분 인페인트 — 공식 웹의 'Focused Inpainting' (docs.novelai.net › Inpaint).
//  그림의 한 상자만 잘라 약 1메가픽셀로 키워 인페인트하고, 결과를 원래 크기로 줄여 '다시 그린 곳' 만 원본에 붙인다.
//  작은 얼굴 · 손 · 장신구도 크게 그려져 디테일이 산다. 보내는 크기가 1MP 이하라 Opus 는 큰 그림에서도 무료다.
//  화면과 무관한 순수 계산 (test/focus_inpaint_test.dart). 쓰는 곳: i2i_tab.dart ('부분' 도구) · AppState.handleFocusInpaintGenerate.
//
//  · 상자(OutpaintRect, 그림 픽셀)는 i2i 탭이 들고 있다. 손잡이 찾기는 확장의 자르기와 같은 hitOutpaintCrop.
//  · focusPlan          — 상자 → 잘라 낼 곳(보낼 비율로 넓힘) · 보낼 크기(64 의 배수, 약 1MP) · 다시 그릴 곳(맥락 띠를 뺀 곳)
//  · composeFocusCrop   — (compute) 잘라 키운 PNG — 보낼 그림
//  · composeFocusResult — (compute) 받은 결과를 줄여 마스크 자리만 원본에 붙인 PNG (그림 정보 청크를 옮겨 담는다)
//
//  ⚠️ 결과를 상자째로 붙이지 않는다 — 키웠다 줄인 맥락 부분이 흐려져 네모 자국이 남는다.
//     서버가 실제로 다시 그린 칸(8픽셀 칸)만, 가장자리는 원본과 부드럽게 섞어 붙인다. 그 밖의 픽셀은 원본 그대로다.
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../utils/image_codec.dart' show withPngTextChunks;
import 'outpaint.dart' show OutpaintRect, OutpaintCropHandle, dragOutpaintCrop, kOutpaintMaskCell;

/// 보낼 넓이 상한 — 1024×1024 (공식 '약 1메가픽셀' · Opus 무료 기준 = AppState.kMegapixelCap)
const int kFocusTargetPixels = 1048576;

/// 상자의 가장 작은 변 (그림 픽셀) — 그림이 이보다 작으면 그림 크기까지
const int kFocusMinBox = 64;

/// 상자의 가장 큰 넓이 (그림 픽셀) — 이보다 크면 키우지 못하고 줄여 보내게 돼 부분 인페인트의 이득이 없다 (공식도 상자 크기에 상한이 있다)
const int kFocusMaxBoxPixels = kFocusTargetPixels;

/// 키우는 배율 상한 — 아주 작은 상자를 수십 배로 키우면 맥락이 뭉개져 오히려 흐린 그림이 나온다
const double kFocusMaxUpscale = 8;

/// 맥락 폭 (보낼 판 픽셀) — 상자 안쪽 테두리의 빨간 띠. 다시 그리지 않고 둘레를 보는 데만 쓴다 (공식 'Minimum Context Area').
///  보낼 판 픽셀이라 상자가 작든 크든 판에서 같은 폭이다 (그림 픽셀로는 상자가 작을수록 좁다).
const int kFocusContextDefault = 64;
const int kFocusContextMax = 192;
const int kFocusContextStep = 8;

/// 붙일 때 가장자리를 섞는 폭 (보낼 판 픽셀) — 다시 그린 칸의 테두리에서 안쪽으로 이만큼 원본과 섞는다
const int kFocusFeather = 16;

/// 부분 인페인트 한 번의 계획 — 보내기 · 붙이기 · 화면의 빨간 띠가 같은 값을 쓴다.
class FocusPlan {
  /// 그림 전체 크기 (AppState.i2iImageSize — 실제 그림이 다르면(썸네일) 이 크기로 맞춰 쓴다)
  final int imageW;
  final int imageH;

  /// 사용자가 고른 상자 (그림 안 · 크기 범위로 맞춘 것, [clampFocusBox])
  final OutpaintRect box;

  /// 잘라 보낼 곳 (그림 픽셀) — 상자를 보낼 비율로 넓힌 것 (늘 상자를 품는다)
  final OutpaintRect crop;

  /// 보낼 크기 (64 의 배수, 넓이 [kFocusTargetPixels] 이하)
  final int sendW;
  final int sendH;

  /// 다시 그릴 수 있는 곳 (보낼 판 픽셀, 8 의 배수) — 상자에서 맥락 띠를 뺀 곳. 그림 끝에 닿은 변은 띠가 없다.
  final OutpaintRect interior;

  const FocusPlan({
    required this.imageW,
    required this.imageH,
    required this.box,
    required this.crop,
    required this.sendW,
    required this.sendH,
    required this.interior,
  });

  /// 보낼 판 픽셀 ÷ 그림 픽셀
  double get scaleX => sendW / crop.width;
  double get scaleY => sendH / crop.height;

  /// [interior] 를 그림 픽셀로 (화면의 빨간 띠 안쪽)
  ({double x0, double y0, double x1, double y1}) get interiorInImage => (
    x0: crop.x0 + interior.x0 / scaleX,
    y0: crop.y0 + interior.y0 / scaleY,
    x1: crop.x0 + interior.x1 / scaleX,
    y1: crop.y0 + interior.y1 / scaleY,
  );

  @override
  String toString() =>
      'FocusPlan(box: ${box.x0},${box.y0}-${box.x1},${box.y1}, crop: ${crop.x0},${crop.y0}-${crop.x1},${crop.y1}, '
      'send: ${sendW}x$sendH, interior: ${interior.x0},${interior.y0}-${interior.x1},${interior.y1})';
}

// ══════════════════════════════════════════════════════════════
// 상자
// ══════════════════════════════════════════════════════════════

/// 상자를 그림 안 · 크기 범위([kFocusMinBox] ~ 넓이 [kFocusMaxBoxPixels]) 로 맞춘다 — 가운데를 지키며.
///  그림 크기를 모르면 빈 상자.
OutpaintRect clampFocusBox(OutpaintRect box, int imageW, int imageH) {
  if (imageW <= 0 || imageH <= 0) {
    return const OutpaintRect(0, 0, 0, 0);
  }
  final int ax = box.x0.clamp(0, imageW);
  final int bx = box.x1.clamp(0, imageW);
  final int ay = box.y0.clamp(0, imageH);
  final int by = box.y1.clamp(0, imageH);
  final int x0 = min(ax, bx);
  final int x1 = max(ax, bx);
  final int y0 = min(ay, by);
  final int y1 = max(ay, by);
  final int minW = min(kFocusMinBox, imageW);
  final int minH = min(kFocusMinBox, imageH);
  int w = max(x1 - x0, minW);
  int h = max(y1 - y0, minH);
  // 넓이 상한 — 비율을 지켜 줄인다 (한쪽이 가장 작은 변에 막히면 다른 쪽을 마저 줄인다)
  if (w * h > kFocusMaxBoxPixels) {
    final double f = sqrt(kFocusMaxBoxPixels / (w * h));
    w = max(minW, (w * f).floor());
    h = max(minH, (h * f).floor());
    if (w * h > kFocusMaxBoxPixels) {
      if (w >= h) {
        w = max(minW, kFocusMaxBoxPixels ~/ h);
      } else {
        h = max(minH, kFocusMaxBoxPixels ~/ w);
      }
    }
  }
  w = min(w, imageW);
  h = min(h, imageH);
  final int nx0 = ((x0 + x1) / 2 - w / 2).round().clamp(0, imageW - w);
  final int ny0 = ((y0 + y1) / 2 - h / 2).round().clamp(0, imageH - h);
  return OutpaintRect(nx0, ny0, nx0 + w, ny0 + h);
}

/// 넓이가 [kFocusMaxBoxPixels] 를 넘으면 끈 변만 줄인다 — 변이면 그 변, 모서리면 맞은편 모서리를 붙든 채 비율대로.
OutpaintRect _limitArea(OutpaintRect r, OutpaintCropHandle handle) {
  const int maxA = kFocusMaxBoxPixels;
  if (r.width * r.height <= maxA || handle == OutpaintCropHandle.move || r.isEmpty) {
    return r;
  }
  switch (handle) {
    case OutpaintCropHandle.left:
      return OutpaintRect(r.x1 - max(1, maxA ~/ r.height), r.y0, r.x1, r.y1);
    case OutpaintCropHandle.right:
      return OutpaintRect(r.x0, r.y0, r.x0 + max(1, maxA ~/ r.height), r.y1);
    case OutpaintCropHandle.top:
      return OutpaintRect(r.x0, r.y1 - max(1, maxA ~/ r.width), r.x1, r.y1);
    case OutpaintCropHandle.bottom:
      return OutpaintRect(r.x0, r.y0, r.x1, r.y0 + max(1, maxA ~/ r.width));
    default:
      final double f = sqrt(maxA / (r.width * r.height));
      final int w = max(1, (r.width * f).floor());
      final int h = max(1, (r.height * f).floor());
      // 오른쪽 모서리를 끌었으면 왼쪽을, 아래 모서리를 끌었으면 위를 붙든다
      final bool keepLeft =
          handle == OutpaintCropHandle.topRight || handle == OutpaintCropHandle.bottomRight;
      final bool keepTop =
          handle == OutpaintCropHandle.bottomLeft || handle == OutpaintCropHandle.bottomRight;
      final int x0 = keepLeft ? r.x0 : r.x1 - w;
      final int y0 = keepTop ? r.y0 : r.y1 - h;
      return OutpaintRect(x0, y0, x0 + w, y0 + h);
  }
}

/// 손잡이 [handle] 를 (du, dv) (그림 픽셀) 만큼 끈 상자 — 손가락을 댄 순간의 상자 [start] 에서.
///  확장의 자르기와 같은 규칙(그림 밖으로 못 나감 · 통째로 옮기기는 크기 그대로 — dragOutpaintCrop)에,
///  가장 작은 변 [kFocusMinBox] · 가장 큰 넓이 [kFocusMaxBoxPixels] (넘치면 끈 변만 줄인다).
OutpaintRect dragFocusBox(
  OutpaintRect start,
  OutpaintCropHandle handle,
  double du,
  double dv,
  int imageW,
  int imageH,
) {
  final OutpaintRect r = dragOutpaintCrop(start, handle, du, dv, imageW, imageH, minSize: kFocusMinBox);
  return _limitArea(r, handle);
}

/// 상자 새로 그리기 — 손가락을 댄 곳 (ax, ay) 부터 지금 (bx, by) 까지 (그림 픽셀).
///  좁으면 끈 쪽으로 [kFocusMinBox] 까지 늘리고, 넓이가 넘치면 댄 곳을 붙든 채 비율대로 줄인다.
OutpaintRect focusBoxFromPoints(double ax, double ay, double bx, double by, int imageW, int imageH) {
  if (imageW <= 0 || imageH <= 0 || !ax.isFinite || !ay.isFinite || !bx.isFinite || !by.isFinite) {
    return const OutpaintRect(0, 0, 0, 0);
  }
  (int, int) span(double a, double b, int limit) {
    final int m = min(kFocusMinBox, limit);
    if (b >= a) {
      final int lo = a.floor().clamp(0, limit - m);
      final int hi = max(lo + m, b.ceil()).clamp(lo + m, limit);
      return (lo, hi);
    }
    final int hi = a.ceil().clamp(m, limit);
    final int lo = min(hi - m, b.floor()).clamp(0, hi - m);
    return (lo, hi);
  }

  final (int x0, int x1) = span(ax, bx, imageW);
  final (int y0, int y1) = span(ay, by, imageH);
  final OutpaintCropHandle corner = bx >= ax
      ? (by >= ay ? OutpaintCropHandle.bottomRight : OutpaintCropHandle.topRight)
      : (by >= ay ? OutpaintCropHandle.bottomLeft : OutpaintCropHandle.topLeft);
  return _limitArea(OutpaintRect(x0, y0, x1, y1), corner);
}

/// '부분' 을 처음 켤 때의 상자 — 칠한 곳 [painted] (그림 픽셀, 없으면 null) 이 맥락 띠 밖(다시 그릴 곳)에 들게 넉넉히.
///  칠한 곳이 없으면 그림 가운데에 짧은 변의 반 크기 정사각형.
OutpaintRect focusBoxAround(
  OutpaintRect? painted,
  int imageW,
  int imageH, {
  int context = kFocusContextDefault,
  int targetPixels = kFocusTargetPixels,
}) {
  if (imageW <= 0 || imageH <= 0) {
    return const OutpaintRect(0, 0, 0, 0);
  }
  if (painted == null || painted.isEmpty) {
    final int side = min(imageW, imageH) ~/ 2;
    final int x0 = (imageW - side) ~/ 2;
    final int y0 = (imageH - side) ~/ 2;
    return clampFocusBox(OutpaintRect(x0, y0, x0 + side, y0 + side), imageW, imageH);
  }
  // 맥락 띠는 보낼 판 픽셀이라, 그림 픽셀로는 배율에 따라 폭이 바뀐다 — 상자를 넓히면 배율이 줄어 띠가 넓어진다.
  //  계획해 배율을 보고 넓히기를 상자가 더 바뀌지 않을 때까지 (보통 두세 번).
  //  띠 + 칸 둘(서버가 마스크를 8픽셀 칸으로 묶고, 다시 그릴 곳도 칸에 맞춰 안쪽으로 줄인다) 만큼 바깥으로.
  OutpaintRect box = clampFocusBox(painted, imageW, imageH);
  for (int i = 0; i < 6; i++) {
    final FocusPlan? p = focusPlan(box, imageW, imageH, context: context, targetPixels: targetPixels);
    if (p == null) {
      break;
    }
    final int c = context.clamp(0, kFocusContextMax) + 2 * kOutpaintMaskCell;
    final int mx = (c / p.scaleX).ceil();
    final int my = (c / p.scaleY).ceil();
    final OutpaintRect next = clampFocusBox(
      OutpaintRect(painted.x0 - mx, painted.y0 - my, painted.x1 + mx, painted.y1 + my),
      imageW,
      imageH,
    );
    if (next == box) {
      break;
    }
    box = next;
  }
  return box;
}

// ══════════════════════════════════════════════════════════════
// 계획
// ══════════════════════════════════════════════════════════════

/// 상자 [box] 의 부분 인페인트 계획. [context] 는 맥락 폭(보낼 판 픽셀), [targetPixels] 는 보낼 넓이 상한
///  (보통 [kFocusTargetPixels] — 모델 상한이 더 작으면 그것). 그림 크기를 모르면 null.
///  ① 보낼 크기: 상자 비율에 가까운 64 의 배수 · 넓이는 상한 이하 (키우는 배율은 [kFocusMaxUpscale] 까지)
///  ② 잘라 낼 곳: 상자를 그 비율로 넓힌다 (상자 가운데 기준, 그림 안으로) — 그래서 보낸 그림이 늘어나거나 눌리지 않는다
///  ③ 다시 그릴 곳: 상자에서 맥락 띠를 뺀 곳 (그림 끝에 닿은 변은 띠 없이) — 넓힌 곳은 맥락으로만 쓴다
FocusPlan? focusPlan(
  OutpaintRect box,
  int imageW,
  int imageH, {
  int context = kFocusContextDefault,
  int targetPixels = kFocusTargetPixels,
}) {
  if (imageW <= 0 || imageH <= 0) {
    return null;
  }
  final OutpaintRect b = clampFocusBox(box, imageW, imageH);
  if (b.isEmpty) {
    return null;
  }
  int targetFor(OutpaintRect r) => max(
    64 * 64,
    min(targetPixels, (r.width * r.height * kFocusMaxUpscale * kFocusMaxUpscale).floor()),
  );
  ({int w, int h}) size = _sendSizeFor(b.width / b.height, targetFor(b));
  final OutpaintRect crop = _expandToAspect(b, size.w / size.h, imageW, imageH);
  // 그림 끝에 막혀 비율을 다 못 맞췄으면 (상자가 그림 폭 · 높이에 가까울 때) 잘라 낸 곳의 비율로 다시 고른다.
  //  이때는 그림이 조금(3% 안) 늘어나거나 눌린다 — 더 좁게 맞추면 64 의 배수가 모자라 한참 작은 크기가 골라졌다
  //  (1024×917 을 640×576 으로 줄여 보내는 식 — 무작위 검사로 확인).
  if (_ratioError(crop.width / crop.height, size.w / size.h) > 0.01) {
    size = _sendSizeFor(crop.width / crop.height, targetFor(crop), tolerance: 0.03);
  }
  return FocusPlan(
    imageW: imageW,
    imageH: imageH,
    box: b,
    crop: crop,
    sendW: size.w,
    sendH: size.h,
    interior: _interiorFor(b, crop, size.w, size.h, imageW, imageH, context),
  );
}

/// 두 비율이 얼마나 다른지 (로그 비 — 1% ≈ 0.01)
double _ratioError(double a, double b) => (log(a / b)).abs();

/// [aspect](가로 ÷ 세로)에 가까운 보낼 크기 — 64 의 배수, 넓이 [target] 이하.
///  비율이 [tolerance] 안으로 맞는 것 중 가장 넓은 것. 없으면 비율이 가장 가까운 것.
///  (잘라 낼 곳을 고른 비율로 넓히므로 조금 어긋나도 그림이 늘어나지 않는다 — 맥락이 조금 더 붙을 뿐)
({int w, int h}) _sendSizeFor(double aspect, int target, {double tolerance = 0.05}) {
  const int u = 64;
  ({int w, int h})? best;
  int bestArea = -1;
  ({int w, int h}) closest = (w: u, h: u);
  double closestErr = double.infinity;
  int closestArea = -1;
  for (int h = u; h * u <= target; h += u) {
    final double exact = h * aspect;
    for (final int w in {max(u, (exact / u).floor() * u), max(u, (exact / u).ceil() * u)}) {
      final int area = w * h;
      if (area > target) {
        continue;
      }
      final double err = _ratioError(w / h, aspect);
      if (err <= tolerance && area > bestArea) {
        best = (w: w, h: h);
        bestArea = area;
      }
      if (err < closestErr - 1e-12 || ((err - closestErr).abs() <= 1e-12 && area > closestArea)) {
        closest = (w: w, h: h);
        closestErr = err;
        closestArea = area;
      }
    }
  }
  return best ?? closest;
}

/// 상자 [b] 를 비율 [aspect] 로 넓힌 곳 (상자 가운데 기준 · 그림 안으로 밀어 넣는다). 그림 끝에 막히면 그만큼만.
OutpaintRect _expandToAspect(OutpaintRect b, double aspect, int imageW, int imageH) {
  double w = b.width.toDouble();
  double h = b.height.toDouble();
  if (w / h < aspect) {
    w = h * aspect;
  } else {
    h = w / aspect;
  }
  final int cw = w.round().clamp(b.width, imageW);
  final int ch = h.round().clamp(b.height, imageH);
  final int x0 = ((b.x0 + b.x1 - cw) / 2).round().clamp(0, imageW - cw);
  final int y0 = ((b.y0 + b.y1 - ch) / 2).round().clamp(0, imageH - ch);
  return OutpaintRect(x0, y0, x0 + cw, y0 + ch);
}

/// 다시 그릴 곳 (보낼 판 픽셀, 8 의 배수 — 서버가 마스크를 8픽셀 칸으로 묶으므로 칸이 띠에 걸치지 않게)
OutpaintRect _interiorFor(
  OutpaintRect b,
  OutpaintRect crop,
  int sendW,
  int sendH,
  int imageW,
  int imageH,
  int context,
) {
  const int cell = kOutpaintMaskCell;
  final double sx = sendW / crop.width;
  final double sy = sendH / crop.height;
  final int c = context.clamp(0, kFocusContextMax);
  // 맥락 띠 (그림 픽셀) — 상자의 1/4 을 넘지 않게 (다시 그릴 곳이 늘 상자의 반 이상 남게)
  final double cx = min(c / sx, b.width / 4);
  final double cy = min(c / sy, b.height / 4);
  // 그림 끝에 닿은 변은 띠가 없다 — 그 너머엔 볼 것이 없고, 띠가 있으면 그림 끝을 다시 그릴 수 없다
  int x0 = b.x0 <= 0 ? 0 : _ceilTo((b.x0 + cx - crop.x0) * sx, cell);
  int x1 = b.x1 >= imageW ? sendW : _floorTo((b.x1 - cx - crop.x0) * sx, cell);
  int y0 = b.y0 <= 0 ? 0 : _ceilTo((b.y0 + cy - crop.y0) * sy, cell);
  int y1 = b.y1 >= imageH ? sendH : _floorTo((b.y1 - cy - crop.y0) * sy, cell);
  x0 = x0.clamp(0, sendW);
  x1 = x1.clamp(0, sendW);
  y0 = y0.clamp(0, sendH);
  y1 = y1.clamp(0, sendH);
  // 너무 작아 비었으면 상자 가운데 칸 하나라도 (상자는 가장 작아도 64 라 보통은 일어나지 않는다)
  if (x1 - x0 < cell) {
    x0 = _floorTo(((b.x0 + b.x1) / 2 - crop.x0) * sx, cell).clamp(0, max(0, sendW - cell));
    x1 = min(sendW, x0 + cell);
  }
  if (y1 - y0 < cell) {
    y0 = _floorTo(((b.y0 + b.y1) / 2 - crop.y0) * sy, cell).clamp(0, max(0, sendH - cell));
    y1 = min(sendH, y0 + cell);
  }
  return OutpaintRect(x0, y0, x1, y1);
}

int _ceilTo(double v, int k) => ((v - 1e-6) / k).ceil() * k;
int _floorTo(double v, int k) => ((v + 1e-6) / k).floor() * k;

// ══════════════════════════════════════════════════════════════
// 판 짜기 · 붙이기 (무겁다 — compute 로)
// ══════════════════════════════════════════════════════════════

/// 그림을 풀어 [w]×[h] (그림 정보의 크기 — 계획의 기준) 로 맞춘다. 회전 정보 반영 · 8비트 · 3채널(투명 채널이 있으면 4).
///  실제 크기가 다르면(히스토리 썸네일 등) 그 크기로 늘이거나 줄인다 — 화면 · 계획이 그 크기를 기준으로 했다.
img.Image? _decodeAt(Uint8List bytes, int w, int h) {
  img.Image? src;
  try {
    src = img.decodeImage(bytes);
  } catch (_) {
    src = null; // 깨진 파일은 디코더가 던지기도 한다
  }
  if (src == null || w <= 0 || h <= 0) {
    return null;
  }
  if (src.exif.imageIfd.hasOrientation && src.exif.imageIfd.orientation != 1) {
    src = img.bakeOrientation(src);
  }
  final int nc = src.numChannels >= 4 ? 4 : 3;
  if (src.format != img.Format.uint8 || src.numChannels != nc || src.hasPalette) {
    src = src.convert(format: img.Format.uint8, numChannels: nc);
  }
  if (src.width != w || src.height != h) {
    src = img.copyResize(
      src,
      width: w,
      height: h,
      interpolation: (w < src.width || h < src.height)
          ? img.Interpolation.average
          : img.Interpolation.linear,
    );
  }
  return src;
}

/// 보낼 그림 만들기 — 원본([image])과 계획
typedef FocusCropJob = ({Uint8List image, FocusPlan plan});

/// 잘라 키운 그림 (PNG, 보낼 크기 · 3채널). 못 읽으면 null.
Uint8List? composeFocusCrop(FocusCropJob job) {
  final FocusPlan p = job.plan;
  final img.Image? src = _decodeAt(job.image, p.imageW, p.imageH);
  if (src == null) {
    return null;
  }
  final OutpaintRect c = p.crop;
  img.Image part = img.copyCrop(src, x: c.x0, y: c.y0, width: c.width, height: c.height);
  if (part.numChannels != 3) {
    part = part.convert(numChannels: 3); // 투명 채널은 떼고 색만 (보내는 쪽도 3채널로 맞춘다)
  }
  part = img.copyResize(
    part,
    width: p.sendW,
    height: p.sendH,
    // 키울 땐 부드럽게(3차), 줄일 땐(아주 큰 상자) 모아서
    interpolation: (p.sendW < c.width || p.sendH < c.height)
        ? img.Interpolation.average
        : img.Interpolation.cubic,
  );
  return img.encodePng(part);
}

/// 결과 붙이기 — 원본 · 받은 결과(보낼 크기) · 보낸 마스크 raw(헤더 8바이트 + 1바이트/픽셀) · 계획
typedef FocusPasteJob = ({Uint8List original, Uint8List result, Uint8List mask, FocusPlan plan});

/// 받은 결과를 잘라 낸 곳 크기로 줄여, 서버가 다시 그린 칸만 원본에 섞어 붙인 PNG (그림 전체 크기).
///  결과에 든 그림 정보(프롬프트 · 시드)를 옮겨 담는다 — 크기는 IHDR 에서 읽혀 그림 전체 크기가 된다.
///  못 읽으면 null.
Uint8List? composeFocusResult(FocusPasteJob job) {
  final FocusPlan p = job.plan;
  final img.Image? base = _decodeAt(job.original, p.imageW, p.imageH);
  if (base == null) {
    return null;
  }
  img.Image? res;
  try {
    res = img.decodeImage(job.result);
  } catch (_) {
    res = null;
  }
  if (res == null) {
    return null;
  }
  if (res.format != img.Format.uint8 || res.numChannels != 3 || res.hasPalette) {
    res = res.convert(format: img.Format.uint8, numChannels: 3);
  }
  final OutpaintRect c = p.crop;
  final int cw = c.width;
  final int ch = c.height;
  // 원래 크기로 — 키운 만큼 모아서 줄인다 (넓이 평균. 서버가 다른 크기로 돌려줘도 잘라 낸 곳 크기로)
  if (res.width != cw || res.height != ch) {
    res = img.copyResize(
      res,
      width: cw,
      height: ch,
      interpolation: (cw < res.width || ch < res.height)
          ? img.Interpolation.average
          : img.Interpolation.linear,
    );
  }
  final Float32List a = focusBlendAlpha(job.mask, p);
  for (int y = 0; y < ch; y++) {
    for (int x = 0; x < cw; x++) {
      final double t = a[y * cw + x];
      if (t <= 0) {
        continue; // 다시 그리지 않은 곳 — 원본 그대로
      }
      final img.Pixel o = base.getPixel(c.x0 + x, c.y0 + y);
      final img.Pixel r = res.getPixel(x, y);
      // 투명 채널(있으면)은 원본 그대로 두고 색만 섞는다
      o
        ..r = (o.r + (r.r - o.r) * t).round()
        ..g = (o.g + (r.g - o.g) * t).round()
        ..b = (o.b + (r.b - o.b) * t).round();
    }
  }
  return withPngTextChunks(img.encodePng(base), job.result);
}

/// 붙일 때 섞는 정도 (잘라 낸 곳 픽셀마다 0~1, 가로 [FocusPlan.crop] 폭).
///  · 서버가 실제로 다시 그린 칸 — 보낸 마스크를 8픽셀 칸으로 묶은 것 (NovelAiService._processMaskForInfill 과 같은 규칙:
///    칸 안에 한 점이라도 칠했으면 칸 전체) — 만 섞는다. 그 밖은 0 (원본 그대로).
///  · 칸의 테두리에서 안쪽으로 [kFocusFeather](보낼 판 픽셀)만큼은 0 → 1 로 부드럽게 (네모난 이음매가 보이지 않게).
///  · 그림 끝에 닿은 변은 바깥도 칠한 것으로 이어 본다 — 안 그러면 그림 끝에 원본이 띠처럼 남는다.
Float32List focusBlendAlpha(Uint8List mask, FocusPlan p) {
  final int cw = p.crop.width;
  final int ch = p.crop.height;
  final Float32List out = Float32List(max(0, cw * ch));
  if (mask.length < 8 || cw <= 0 || ch <= 0) {
    return out;
  }
  final ByteData head = ByteData.sublistView(mask);
  final int mw = head.getUint32(0);
  final int mh = head.getUint32(4);
  if (mw <= 0 || mh <= 0 || mask.length < 8 + mw * mh) {
    return out;
  }
  const int cell = kOutpaintMaskCell;
  final int gw = mw ~/ cell;
  final int gh = mh ~/ cell;
  if (gw <= 0 || gh <= 0) {
    return out;
  }
  final Uint8List grid = Uint8List(gw * gh);
  for (int y = 0; y < gh * cell; y++) {
    final int row = 8 + y * mw;
    final int g = (y ~/ cell) * gw;
    for (int x = 0; x < gw * cell; x++) {
      if (mask[row + x] > 0) {
        grid[g + x ~/ cell] = 1;
      }
    }
  }
  // 잘라 낸 곳 픽셀 → 보낼 판의 칸 (픽셀 가운데로)
  final double sx = mw / cw;
  final double sy = mh / ch;
  final Float32List m = Float32List(cw * ch);
  bool any = false;
  for (int y = 0; y < ch; y++) {
    final int gy = (((y + 0.5) * sy) / cell).floor().clamp(0, gh - 1);
    for (int x = 0; x < cw; x++) {
      final int gx = (((x + 0.5) * sx) / cell).floor().clamp(0, gw - 1);
      if (grid[gy * gw + gx] == 1) {
        m[y * cw + x] = 1;
        any = true;
      }
    }
  }
  if (!any) {
    return out;
  }
  final int r = max(1, (kFocusFeather / sx).round());
  final Float32List b = _boxBlur(
    m,
    cw,
    ch,
    r,
    extendLeft: p.crop.x0 <= 0,
    extendRight: p.crop.x1 >= p.imageW,
    extendTop: p.crop.y0 <= 0,
    extendBottom: p.crop.y1 >= p.imageH,
  );
  for (int i = 0; i < out.length; i++) {
    // 칸 안에서만 — 테두리(흐린 값 0.5 언저리)는 0, 안쪽으로 r 만큼 들어가면 1
    out[i] = m[i] > 0 ? (2 * b[i] - 1).clamp(0.0, 1.0) : 0.0;
  }
  return out;
}

/// 가로 · 세로 상자 흐림 (반지름 [r]). 바깥은 0 — [extendLeft] 등이 참인 변은 가장자리 값을 늘여 본다.
Float32List _boxBlur(
  Float32List src,
  int w,
  int h,
  int r, {
  required bool extendLeft,
  required bool extendRight,
  required bool extendTop,
  required bool extendBottom,
}) {
  final double inv = 1 / (2 * r + 1);
  final Float32List tmp = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    final int row = y * w;
    double at(int x) => x < 0
        ? (extendLeft ? src[row] : 0.0)
        : (x >= w ? (extendRight ? src[row + w - 1] : 0.0) : src[row + x]);
    double s = 0;
    for (int k = -r; k <= r; k++) {
      s += at(k);
    }
    for (int x = 0; x < w; x++) {
      tmp[row + x] = s * inv;
      s += at(x + r + 1) - at(x - r);
    }
  }
  final Float32List out = Float32List(w * h);
  for (int x = 0; x < w; x++) {
    double at(int y) => y < 0
        ? (extendTop ? tmp[x] : 0.0)
        : (y >= h ? (extendBottom ? tmp[(h - 1) * w + x] : 0.0) : tmp[y * w + x]);
    double s = 0;
    for (int k = -r; k <= r; k++) {
      s += at(k);
    }
    for (int y = 0; y < h; y++) {
      out[y * w + x] = s * inv;
      s += at(y + r + 1) - at(y - r);
    }
  }
  return out;
}
