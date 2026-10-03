// lib/utils/image_codec.dart
//
// 이미지를 줄이고 WebP 로 굽는 일을 한곳에 모은다.
//
// 왜 한곳인가:
//  예전엔 히스토리·백업·갤러리·사전이 각자 image 패키지로 JPEG 썸네일을 만들었다.
//  크기·품질이 제각각이고, 순수 Dart 로 PNG 를 통째로 푸느라 느렸다.
//  이제 모두 여기의 함수를 거친다 — 규칙을 바꾸려면 이 파일만 고치면 된다.
//
// 실측 (NovelAI 기본 832×1216 그림 기준)
//  · 원본 PNG                  약 1.2~1.4MB
//  · 원본 크기 WebP q80        약 40~65KB   ← 사전 큰 이미지
//  · 긴 변 768 WebP q75        약 20~30KB   ← 히스토리 오래된 이미지·백업
//  · 긴 변 320 WebP q75        약 4~8KB     ← 사전 목록 썸네일
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

/// 이 크기 미만이면 '이미 줄인 썸네일'로 본다 (히스토리가 원본/썸네일을 가르는 기준).
///
/// ⚠️ 썸네일을 만들 때 반드시 이보다 작게 만들어야 한다.
///    넘으면 히스토리가 '아직 원본'으로 오해해 매번 다시 줄이고,
///    그때마다 화질이 한 번씩 더 깎인다.
const int kThumbBytesLimit = 50000;

/// 그림의 가로·세로를 헤더만 읽어 알아낸다 (그림 전체를 풀지 않아 가볍다).
Future<(int, int)?> readImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? desc;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    desc = await ui.ImageDescriptor.encoded(buffer);
    return (desc.width, desc.height);
  } catch (_) {
    return null;
  } finally {
    desc?.dispose();
    buffer?.dispose();
  }
}

/// 그림의 가로·세로를 파일 머리만 보고 '바로' 읽는다 — 기다릴 필요가 없어 화면을 그리는 도중에도 쓴다.
///  PNG · JPEG · WebP · GIF 를 알아본다. 모르는 형식이거나 깨졌으면 null.
///  (확실하지만 기다려야 하는 방법은 [readImageSize])
(int, int)? imageSizeFromHeader(Uint8List b) {
  final int n = b.length;
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int be32(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  int le24(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  (int, int)? ok(int w, int h) => (w > 0 && h > 0) ? (w, h) : null;

  // PNG — 서명 8바이트 뒤 첫 청크(IHDR)에 가로·세로
  if (isPng(b) && n >= 24) {
    return ok(be32(16), be32(20));
  }
  // GIF — 'GIF' 뒤 논리 화면 크기
  if (n >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return ok(le16(6), le16(8));
  }
  // WebP — 'RIFF' .... 'WEBP' 뒤 첫 청크 종류에 따라 자리가 다르다
  if (n >= 30 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    final String chunk = String.fromCharCodes(b.sublist(12, 16));
    if (chunk == 'VP8 ') {
      return ok(le16(26) & 0x3FFF, le16(28) & 0x3FFF); // 손실 압축
    }
    if (chunk == 'VP8L') {
      final int bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24); // 무손실
      return ok((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    }
    if (chunk == 'VP8X') {
      return ok(le24(24) + 1, le24(27) + 1); // 확장 (투명·애니메이션)
    }
    return null;
  }
  // JPEG — 표지(FF xx)를 따라가다 프레임 머리(SOFn)에서 읽는다
  if (isJpeg(b)) {
    int i = 2;
    while (i + 9 < n) {
      if (b[i] != 0xFF) {
        return null; // 표지 자리가 아니다 — 깨진 파일
      }
      final int m = b[i + 1];
      if (m == 0xFF) {
        i++; // 채움 바이트
        continue;
      }
      if (m == 0x01 || (m >= 0xD0 && m <= 0xD8)) {
        i += 2; // 길이가 없는 표지
        continue;
      }
      if (m == 0xD9 || m == 0xDA) {
        return null; // 프레임 머리 전에 끝났다
      }
      if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
        return ok(be16(i + 7), be16(i + 5)); // SOFn: 정밀도(1) 세로(2) 가로(2)
      }
      i += 2 + be16(i + 2);
    }
    return null;
  }
  return null;
}

/// WebP 로 굽는다 (안드로이드 네이티브 인코더). 실패하면 null — 부르는 쪽이 옛 방식으로 대신한다.
///
/// [maxSide] 긴 변을 이 길이 이하로 줄인다. 키우지는 않는다. null 이면 원래 크기 그대로.
///
/// ⚠️ flutter_image_compress 는 크기를 넘기지 않으면 기본값(1920×1080)을 쓴다.
///    그러면 그보다 큰 그림(업스케일 결과 등)이 조용히 줄어든다.
///    그래서 항상 '원하는 결과 크기'를 계산해 정확히 넘긴다.
/// ⚠️ 플랫폼 채널을 쓰므로 compute(isolate) 안에서는 부를 수 없다.
///    메인에서 불러도 실제 작업은 네이티브 스레드에서 돌아 화면이 멈추지 않는다.
Future<Uint8List?> encodeWebp(Uint8List src, {int? maxSide, required int quality}) async {
  try {
    final size = await readImageSize(src);
    if (size == null) {
      return null;
    }
    final (w, h) = size;
    final long = w > h ? w : h;
    final scale = (maxSide == null || long <= maxSide) ? 1.0 : long / maxSide;
    final out = await FlutterImageCompress.compressWithList(
      src,
      // 플러그인은 '가로/min, 세로/min 중 작은 비율'로 줄인다.
      //  결과 크기를 그대로 넘기면 두 비율이 같아져 정확히 그 크기가 된다.
      minWidth: (w / scale).round(),
      minHeight: (h / scale).round(),
      quality: quality,
      format: CompressFormat.webp,
    );
    if (out.isEmpty) {
      return null;
    }
    return Uint8List.fromList(out);
  } catch (e) {
    debugPrint('WebP 인코딩 실패(옛 방식으로 대신): $e');
    return null;
  }
}

/// 히스토리 오래된 이미지·백업용 썸네일 — 긴 변 768, 품질 75.
///  예전(200px JPEG)보다 크게 열어도 알아볼 수 있다.
///  [kThumbBytesLimit] 를 넘지 않도록 품질·크기를 차례로 낮춰 맞춘다.
Future<Uint8List?> makeHistoryThumb(Uint8List src) async {
  for (final (side, q) in const [(768, 75), (768, 60), (512, 60)]) {
    final t = await encodeWebp(src, maxSide: side, quality: q);
    if (t == null) {
      return null; // 인코더 자체가 안 되면 더 해 봐야 소용없다
    }
    if (t.length < kThumbBytesLimit - 2000) {
      return t; // 기준보다 조금 여유 있게
    }
  }
  return null;
}

/// 사전 큰 이미지 — 긴 변 1536, 품질 80.
///  NovelAI 기본 해상도(832×1216)는 줄이지 않고 그대로 담는다.
Future<Uint8List?> makeDictLargeImage(Uint8List src) => encodeWebp(src, maxSide: 1536, quality: 80);

/// 사전 목록·편집 창의 작은 썸네일 — 긴 변 320, 품질 75.
///  화면에 64~100dp 로만 보이므로 이 정도면 고해상도 폰에서도 선명하다.
Future<Uint8List?> makeDictThumb(Uint8List src) => encodeWebp(src, maxSide: 320, quality: 75);

/// 갤러리 썸네일(대비책 경로) — 긴 변 480, 품질 80.
///  보통은 안드로이드 기본 썸네일 API 가 만들고, 그게 안 될 때만 여기를 쓴다.
Future<Uint8List?> makeGalleryThumb(Uint8List src) => encodeWebp(src, maxSide: 480, quality: 80);

/// PNG 인지 (파일 첫 8바이트 서명으로 판단).
bool isPng(Uint8List b) =>
    b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

/// PNG 로 바꾼다 (무손실, 크기 그대로). 이미 PNG 면 그대로 돌려준다. 실패하면 null.
///  업스케일 서버는 PNG 를 기대하는데, WebP 로 저장해 둔 그림을 불러오면 WebP 가 넘어간다.
Future<Uint8List?> ensurePng(Uint8List src) async {
  if (isPng(src)) {
    return src;
  }
  try {
    final size = await readImageSize(src);
    if (size == null) {
      return null;
    }
    final (w, h) = size;
    final out = await FlutterImageCompress.compressWithList(
      src,
      // 크기를 정확히 넘긴다 (기본값 1920×1080 이면 큰 그림이 줄어든다 — encodeWebp 참고)
      minWidth: w,
      minHeight: h,
      quality: 100,
      format: CompressFormat.png,
    );
    return out.isEmpty ? null : Uint8List.fromList(out);
  } catch (e) {
    debugPrint('PNG 변환 실패: $e');
    return null;
  }
}

// ══════════════════════════════════════════════════════════════
// 저장 형식 · 확장자 · MIME
// ══════════════════════════════════════════════════════════════
//  나중에 화질을 바꾸거나 새 형식(예: AVIF)을 쓰고 싶을 때 이 아래만 고치면 된다.
//
//  · 화질 바꾸기     → SaveFormat 의 quality 숫자
//  · 새 형식 더하기  → SaveFormat 에 한 줄 + encodeForSave 에 한 갈래
//                     + mimeForExt / kImageExts 에 확장자
//                     + (메타데이터를 담는 방법 — app_state 의 _convertWithMetadata 참고)

/// 그림을 저장할 때 쓰는 형식.
enum SaveFormat {
  /// 원본 PNG 그대로 (다시 굽지 않는다 — 메타데이터가 PNG 안에 그대로 남는다)
  png('png', 'image/png', null),

  /// WebP 무손실 — PNG 보다 약 26% 작고 화질 손실이 없다
  webpLossless('webp', 'image/webp', 100),

  /// WebP 손실(품질 95) — 눈으로는 차이를 거의 못 느끼고 용량이 크게 준다
  webpLossy('webp', 'image/webp', 95);

  const SaveFormat(this.ext, this.mime, this.quality);

  /// 파일 확장자 (점 없이)
  final String ext;

  /// 저장소에 넘길 MIME
  final String mime;

  /// 다시 구울 때의 품질. null 이면 원본을 그대로 쓴다.
  final int? quality;
}

/// 저장용으로 굽는다. 원본을 그대로 쓰는 형식이거나 실패하면 null.
Future<Uint8List?> encodeForSave(Uint8List png, SaveFormat format) async {
  switch (format) {
    case SaveFormat.png:
      return null; // 원본 그대로
    case SaveFormat.webpLossless:
    case SaveFormat.webpLossy:
      return encodeWebp(png, quality: format.quality!);
  }
}

/// 그림 파일로 보는 확장자 (점 없이, 소문자).
///  갤러리·저장 폴더 목록·폴더 옮기기가 모두 이 목록을 쓴다.
///  ⚠️ 예전엔 갤러리(GIF 포함)와 저장 폴더 목록(GIF 제외)이 따로 적혀 있어서,
///     저장 방식에 따라 같은 폴더인데 보이는 그림이 달랐다.
const Set<String> kImageExts = {'png', 'jpg', 'jpeg', 'webp', 'gif'};

/// 파일 이름의 확장자 (점 없이, 소문자). 없으면 빈 문자열.
String extOf(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

/// 그림 파일 이름인지
bool isImageFileName(String name) => kImageExts.contains(extOf(name));

/// 확장자 → MIME.
///  ⚠️ 확장자와 MIME 이 어긋나면 안드로이드가 확장자를 덧붙인다 (예: 그림.webp.png).
///     저장 폴더에 파일을 쓸 때는 반드시 이 함수로 MIME 을 정한다.
String mimeForExt(String ext) {
  switch (ext.toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return 'image/png';
  }
}

/// JPEG 인지 (파일 첫 2바이트 서명으로 판단)
bool isJpeg(Uint8List b) => b.length >= 2 && b[0] == 0xFF && b[1] == 0xD8;
