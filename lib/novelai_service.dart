import 'dart:async';
import 'dart:convert';
import 'dart:io' show File; // 태그 분류 캐시 파일
import 'dart:math';
import 'dart:typed_data'; // BytesBuilder (multipart 본문)
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;
import 'package:image/image.dart' as img;
import 'tag_filters.dart';
import 'models/model_caps.dart';
import 'models/prompt_pipeline.dart' show weightTouchesBoundary; // 구획 경계의 가중치 표시
import 'models/prompt_search.dart'
    show SearchPlan, searchSyntaxJunkTarget, unescapeGelbooruHtml; // 프롬프트 검색 — {A|B} 조합 · 찌꺼기 태그 · HTML 문자
import 'utils/image_codec.dart'; // ensurePng · withPngTextChunks (i2i 결과 자르기)
import 'utils/nai_stream.dart'; // 스트리밍 생성 응답 읽기 (생성 과정 미리보기)

// ZIP 응답에서 첫 파일을 꺼낸다 (compute isolate용 — 수 MB 해제를 메인에서 안 하도록)
/// zip 안의 이미지를 '전부' 꺼낸다. zip 이 아니면 빈 목록.
///  배경 제거처럼 결과가 여러 장인 도구를 위한 것.
///  (기존 _unzipFirstEntry 는 첫 장만 꺼내므로 그대로 둔다)
List<Uint8List> _unzipAllEntries(Uint8List zipBytes) {
  try {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    return [
      for (final f in archive)
        if (f.isFile) f.content as Uint8List,
    ];
  } catch (_) {
    // zip 이 아니면 빈 목록. 호출부가 원본 바이트를 한 장으로 취급한다.
  }
  return const [];
}

Uint8List? _unzipFirstEntry(Uint8List zipBytes) {
  try {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    if (archive.isNotEmpty) {
      return archive.first.content as Uint8List;
    }
  } catch (_) {
    // zip 이 아니면 그냥 null. 서버가 이미지를 zip 없이 그대로 주는 경우가 있어,
    // 호출부가 null 을 받으면 원본 바이트를 그대로 쓴다.
  }
  return null;
}

/// 결과가 여러 장일 수 있는 응답 (Director Tools 용).
///  배경 제거는 Masked/Generated/Blend 3장이 온다.
class NaiMultiResponse {
  final List<Uint8List> images;
  final String? error;
  const NaiMultiResponse({this.images = const [], this.error});
}

class NaiResponse {
  final Uint8List? image;

  /// 한 번에 여러 장(n_samples)을 받았을 때 둘째 장부터. 보통은 비어 있다.
  final List<Uint8List> more;
  final String? error;

  /// 다시 보내도 같은 결과일 오류인지 — 키 · Anlas · 권한 · 요청 내용 · 한도(429) · Vibe 인코딩 실패 · 앱 쪽 오류.
  ///  연속 생성은 이 오류면 바로 멈춘다 (예전엔 0.5초마다 같은 실패 요청을 끝없이 보냈다).
  ///  false 인 오류(서버 바쁨 · 5xx · 시간 초과 · 연결)는 다음 장은 될 수도 있다.
  final bool fatal;

  NaiResponse({this.image, this.more = const [], this.error, this.fatal = false});
}

// ============================================================================
// [최종 핵심 해결책] 원본 이미지와 마스크 모두 무조건 '순수 3채널(RGB)' 강제 변환
// ============================================================================
//  [job] = (그림, 그림을 둘 가로·세로, 보낼 가로·세로).
//  서버는 그림 크기와 width·height 가 다르면 거부하거나 어긋나게 그린다. 그래서
//   1) 그림을 '둘 크기'로 맞추고 (비율은 부르는 쪽이 지켜 준다 — AppState.i2iSendPlan)
//   2) 보낼 크기(64 의 배수)까지 모자란 오른쪽·아래는 가장자리 픽셀을 늘여 채운다.
//  채운 부분은 결과에서 다시 잘라낸다 (_cropResultToContent) — 그림을 늘이거나 누르지 않는다.
//  (보낼 크기가 0 이하면 예전처럼 64 의 배수로만 내린다)
String _processImage3Channel((Uint8List, int, int, int, int) job) {
  final (bytes, fitW, fitH, sendW, sendH) = job;
  img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) {
    String b64 = base64Encode(bytes);
    if (b64.contains(',')) {
      return b64.split(',').last.trim();
    }
    return b64.trim();
  }

  final int tW = sendW > 0 ? sendW : (decoded.width ~/ 64) * 64;
  final int tH = sendH > 0 ? sendH : (decoded.height ~/ 64) * 64;
  // 그림을 둘 크기 — 없거나 보낼 크기보다 크면 보낼 크기 그대로 (채울 곳 없음)
  final int cW = (fitW > 0 && fitW <= tW) ? fitW : tW;
  final int cH = (fitH > 0 && fitH <= tH) ? fitH : tH;
  // 16비트 PNG 등은 8비트로 — 아래에서 색을 8비트 판에 옮기므로 (안 하면 하얗게 날아간다)
  if (decoded.format != img.Format.uint8) {
    decoded = decoded.convert(format: img.Format.uint8);
  }
  // 먼저 줄인다 — 큰 사진을 원래 크기로 한 픽셀씩 도는 것보다 훨씬 빠르다
  if (decoded.width != cW || decoded.height != cH) {
    decoded = img.copyResize(decoded, width: cW, height: cH);
  }

  // 🚨 알파 채널을 제거하고 무조건 3채널(RGB) 이미지로 덮어씌웁니다.
  // V4.5 서버는 1채널이나 4채널 데이터가 들어오면 텐서 차원 오류로 크래시를 냅니다.
  //  동시에 보낼 크기로 채운다 — 그림 밖(오른쪽·아래)은 마지막 열·행을 늘여 이어 붙인다
  //  (검정으로 채우면 경계가 생겨 가장자리에 테두리가 비칠 수 있다).
  final finalImg = img.Image(width: tW, height: tH, numChannels: 3);
  for (var y = 0; y < tH; y++) {
    final int sy = y < cH ? y : cH - 1;
    for (var x = 0; x < tW; x++) {
      final p = decoded.getPixel(x < cW ? x : cW - 1, sy);
      finalImg.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }

  final pngBytes = Uint8List.fromList(img.encodePng(finalImg));
  String base64String = base64Encode(pngBytes);
  if (base64String.contains(',')) {
    return base64String.split(',').last.trim();
  }
  return base64String.trim();
}

// ============================================================================
// i2i 결과 자르기 — 채워 보낸 오른쪽·아래를 걷어내 원래 그림 크기로 되돌린다
// ============================================================================
//  [job] = (결과 PNG, 남길 가로, 남길 세로). 왼쪽 위 기준으로 자른다 (_processImage3Channel 이
//  그림을 왼쪽 위에 두고 오른쪽·아래만 채우므로).
//  NovelAI 가 넣어 둔 글자 청크(프롬프트·설정)는 그대로 옮겨 담는다 — 그래야 히스토리·i2i 가
//  그림 정보를 계속 읽는다. 크기 정보는 IHDR 에서 읽으므로 자른 크기로 바르게 나온다.
//  자를 게 없거나 PNG 가 아니거나 실패하면 받은 그대로 돌려준다.
Uint8List _cropResultToContent((Uint8List, int, int) job) {
  final (bytes, w, h) = job;
  try {
    if (!isPng(bytes)) {
      return bytes;
    }
    final decoded = img.decodePng(bytes);
    if (decoded == null ||
        decoded.width < w ||
        decoded.height < h ||
        (decoded.width == w && decoded.height == h)) {
      return bytes;
    }
    final cropped = img.copyCrop(decoded, x: 0, y: 0, width: w, height: h);
    return withPngTextChunks(img.encodePng(cropped), bytes);
  } catch (e) {
    debugPrint('i2i 결과 자르기 실패(받은 그대로 사용): $e');
    return bytes;
  }
}

// ============================================================================
// Infill 마스크 처리: 1/8 격자 → 8배 확대 → 풀 해상도 RGB 3채널 PNG
// ============================================================================
String _processMaskForInfill(Uint8List bytes) {
  if (bytes.length < 9) {
    return base64Encode(bytes);
  }

  final header = ByteData.sublistView(bytes);
  final int w = header.getUint32(0);
  final int h = header.getUint32(4);
  final int expectedSize = 8 + w * h;
  if (bytes.length < expectedSize) {
    return base64Encode(bytes);
  }

  // 1단계: 풀 해상도 raw → 1/8 격자로 축소
  final int smallW = w ~/ 8;
  final int smallH = h ~/ 8;
  final grid = List.generate(smallH, (_) => List.filled(smallW, false));
  int idx = 8;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (bytes[idx++] > 0) {
        final int gx = x ~/ 8;
        final int gy = y ~/ 8;
        if (gx < smallW && gy < smallH) {
          grid[gy][gx] = true;
        }
      }
    }
  }

  // 2단계: 1/8 격자 → 8배 확대 풀 해상도 RGB 3채널 마스크
  final mask = img.Image(
    width: smallW * 8,
    height: smallH * 8,
    format: img.Format.uint8,
    numChannels: 3,
  );
  for (int gy = 0; gy < smallH; gy++) {
    for (int gx = 0; gx < smallW; gx++) {
      if (grid[gy][gx]) {
        for (int dy = 0; dy < 8; dy++) {
          for (int dx = 0; dx < 8; dx++) {
            mask.setPixelRgb(gx * 8 + dx, gy * 8 + dy, 255, 255, 255);
          }
        }
      }
    }
  }

  return base64Encode(Uint8List.fromList(img.encodePng(mask)));
}

// ============================================================================
// 프롬프트 검색 — 화면 밖(compute isolate)에서 도는 부분
// ============================================================================

/// 검색 페이지에서 쓰는 값만 뽑은 포스트 한 개
typedef _SlimPost = ({int id, int width, int height, String? rating, List<String> tags});

/// 검색 페이지 하나를 푼 결과.
///  [raw]   거르기 전 받은 포스트 수 (0 이면 결과가 끝났다는 뜻)
///  [total] 서버가 알려 준 전체 검색 결과 수 (@attributes.count, 없으면 null)
///  [posts] 쓸 만한 포스트 (512 미만·태그 없는 것은 이미 뺐다)
typedef _PostsPage = ({int raw, int? total, List<_SlimPost> posts});

/// 겔부루 검색 페이지 응답(바이트) → 쓸 값만 뽑는다.
///  예전엔 화면 쪽에서 같은 응답을 두 번(개수 세기 + 내용) 풀었다. 페이지 하나가 100~200KB 라
///  수십 페이지를 받는 동안 화면이 자꾸 끊겼다 → 여기서 한 번만, 화면 밖에서 푼다.
///  돌려보내는 것도 필요한 값뿐이라 가볍다.
_PostsPage _slimPostsPage(Uint8List body) {
  String text;
  try {
    text = utf8.decode(body);
  } catch (_) {
    text = latin1.decode(body); // UTF-8 이 아니면 (예전 response.body 와 같은 방식)
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map) {
    return (raw: 0, total: null, posts: const <_SlimPost>[]);
  }
  final attrs = decoded['@attributes'];
  final int? total = attrs is Map ? int.tryParse('${attrs['count']}') : null;
  final rawPosts = decoded['post'];
  final List list = rawPosts is List ? rawPosts : (rawPosts is Map ? [rawPosts] : const []);
  final posts = <_SlimPost>[];
  for (final p in list) {
    if (p is! Map) {
      continue;
    }
    final idv = p['id'];
    final int? id = idv is int ? idv : int.tryParse('$idv');
    if (id == null) {
      continue;
    }
    final int width = int.tryParse('${p['width']}') ?? 0;
    final int height = int.tryParse('${p['height']}') ?? 0;
    if (width < 512 || height < 512) {
      continue; // 너무 작은 그림은 프롬프트 재료로 쓰지 않는다
    }
    final tagString = p['tags'];
    if (tagString is! String || tagString.isEmpty) {
      continue;
    }
    posts.add((
      id: id,
      width: width,
      height: height,
      rating: p['rating']?.toString(),
      tags: tagString.split(' ').where((e) => e.isNotEmpty).toList(),
    ));
  }
  return (raw: list.length, total: total, posts: posts);
}

/// 검색어 하나(묶음 + 섞기 순서)에서 받을 페이지 범위
class _PageRun {
  _PageRun(this.query, this.from, this.count);
  final String query; // 주소에 넣을 수 있게 바꾼 검색어
  final int from; // 첫 페이지 번호 (pid)
  final int count; // 받을 페이지 수
  bool ended = false; // 결과가 끝났거나(빈 페이지) 계속 실패한다 → 남은 차례는 건너뛴다
  int fails = 0; // 연달아 실패한 페이지 수
}

/// 요청 간격 지키기 — 요청 '시작' 사이에 [gapMs] 를 두고, 429 를 받으면 모두 잠깐 쉰다.
///  검색 페이지 받기 · 태그 확인(단보루 · 겔부루)이 같이 쓴다 (서버마다 하나씩).
///  · 자리는 기다리기 '전에' 잡는다 — 그래야 일꾼끼리 같은 시각에 몰려 나가지 않는다.
///  · 기다리는 사이 다른 요청이 429 를 받아 '쉬기' 가 걸렸으면 다시 줄을 선다.
///  · 시각은 스톱워치로 잰다 (기기 시계가 도중에 바뀌어도 줄이 멈추지 않게).
class _RequestPacer {
  _RequestPacer(this.gapMs);
  final int gapMs;
  final Stopwatch _clock = Stopwatch()..start();
  int _nextStartMs = 0; // 다음 요청을 보낼 수 있는 때
  int _pauseUntilMs = 0; // 429 를 받으면 모두 이때까지 쉰다

  /// 다음 요청을 보내도 되는 때까지 기다린다.
  Future<void> waitTurn() async {
    while (true) {
      final int now = _clock.elapsedMilliseconds;
      final int at = max(max(_nextStartMs, now), _pauseUntilMs);
      _nextStartMs = at + gapMs;
      if (at > now) {
        await Future<void>.delayed(Duration(milliseconds: at - now));
      }
      if (_pauseUntilMs <= at) {
        return; // 자리를 잡은 뒤로 새 '쉬기' 가 걸리지 않았다
      }
    }
  }

  /// 429 — 모두 잠깐 쉰다 (이미 더 길게 쉬기로 했으면 그대로)
  void pauseFor(Duration d) {
    _pauseUntilMs = max(_pauseUntilMs, _clock.elapsedMilliseconds + d.inMilliseconds);
  }
}

/// 할 일들을 일꾼 [workers] 명이 나눠 처리한다 — 끝난 일꾼이 바로 다음 일을 가져간다.
Future<void> _runPool(int workers, List<Future<void> Function()> jobs) async {
  int next = 0;
  Future<void> worker() async {
    while (next < jobs.length) {
      await jobs[next++]();
    }
  }

  await Future.wait([
    for (int w = 0; w < min(workers, jobs.length); w++) worker(),
  ]);
}

/// 태그 분류 캐시 파일 → 지도 (화면 밖에서 읽고 푼다). 형식이 틀리면 예외.
Future<Map<String, int>> _readTagCacheFile(String path) async =>
    _toTagCategoryMap(jsonDecode(await File(path).readAsString()));

/// 예전 버전이 설정에 둔 캐시(JSON 글자) → 지도
Map<String, int> _decodeTagCacheString(String raw) => _toTagCategoryMap(jsonDecode(raw));

Map<String, int> _toTagCategoryMap(Object? v) {
  if (v is! Map) {
    throw const FormatException('태그 분류 캐시 형식이 아님');
  }
  final out = <String, int>{}; // 파일에 적힌 순서(오래 안 쓴 것 → 최근 것)를 그대로 지킨다
  v.forEach((k, val) {
    final int? n = val is int ? val : int.tryParse('$val');
    if (k is String && n != null) {
      out[k] = n;
    }
  });
  return out;
}

/// 지도 → JSON 바이트 (화면 밖에서)
Uint8List _encodeTagCache(Map<String, int> m) => utf8.encode(jsonEncode(m));

class NovelAiService {
  static const String apiUrl = "https://image.novelai.net/ai/generate-image";
  // 스트리밍 생성 — 중간 단계 미리보기가 함께 온다 (설정 '생성 과정 미리보기'. NovelAI 웹도 V4 부터 이 길로 생성한다)
  static const String streamUrl = "https://image.novelai.net/ai/generate-image-stream";
  static const String encodeVibeUrl = "https://image.novelai.net/ai/encode-vibe";
  // 업스케일 — 2026-08 에 NovelAI 가 V5 업스케일러로 바꾸면서 주소·형식이 모두 달라졌다.
  //  · 주소: api.novelai.net → image.novelai.net (옛 주소는 404 'Cannot POST /ai/upscale')
  //  · 형식: JSON(base64) → multipart (그림 + request)
  //  · 모델·배율·비용이 고정이다 (입력 크기·구독 등급과 무관)
  static const String upscaleUrl = "https://image.novelai.net/ai/upscale";
  static const String upscaleModel = 'nai-diffusion-5-curated';
  static const int upscaleScale = 2;
  static const int upscaleAnlasCost = 1;

  /// Director Tools 전용. 배경 제거·라인아트·스케치·디클러터가 모두 이 주소를 쓴다.
  static const String directorUrl = "https://image.novelai.net/ai/augment-image";

  // ── Cloudflare Workers 프록시 ──────────────────────────────────────────
  static const String _danbooruProxy = "https://danbooru-proxy.dnaiapp.workers.dev";
  static const String _gelbooruProxy = "https://gelbooru-proxy.dnaiapp.workers.dev";
  // 겔부루는 브라우저가 아닌 요청을 막는 경우가 있어 브라우저처럼 보이게 한다
  static const String _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36';

  /// 프롬프트 검색에서 받을 페이지 수 기본값 (설정 화면도 이 값을 보여 준다).
  ///  본인 API 키가 없으면 모두가 같이 쓰는 공용 키로 검색하므로 적게 받는다 (429 를 피하려고).
  static const int searchPagesWithKey = 40;
  static const int searchPagesWithoutKey = 15;
  // ───────────────────────────────────────────────────────────────────────

  // 응답 본문을 UTF-8로 안전하게 읽는다.
  //  http 패키지의 response.body는 서버가 charset을 명시하지 않으면
  //  latin-1로 디코드해 한글·일본어가 깨진다. 바이트에서 직접 디코드한다.
  String _utf8Body(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      return response.body; // 혹시 UTF-8이 아니면 원래 방식으로
    }
  }

  /// 프롬프트 한 덩어리(구획)의 맨 앞 · 맨 끝 빈 자리(공백 · 쉼표 · 줄바꿈)만 걷어 낸다.
  ///  구획을 이을 때 경계에 ", , " 가 생기거나 프롬프트가 쉼표 · 빈 줄로 시작/끝나지 않게 — 그 밖은 건드리지 않는다.
  ///  (구획 끝의 줄바꿈은 joinPromptSections 가 원문을 보고 다시 살려 잇는다)
  ///
  /// ⚠️ 구획 '안'은 사용자가 쓴 그대로 보낸다 — 보낸 프롬프트는 그림 정보에 남아 '불러오기' 로 칸에 돌아온다.
  ///    · 예전엔 구획 전체에서 내용 없는 조각을 버려, 사용자가 쓴 'a, , b' 가 'a, b' 로 바뀌어 나갔다.
  ///    · 그보다 전엔 조각마다 trim() 을 걸고 ', ' 로 다시 이어, 줄바꿈 · 들여쓰기(줄 구성, '#' 주석)까지 사라졌다.
  String sanitizePrompt(String input) =>
      input.replaceFirst(_leadingBlank, '').replaceFirst(_trailingBlank, '');

  /// 선행/긍정/후행처럼 여러 구획을 하나의 프롬프트로 잇는다.
  ///  비어 있는 구획은 건너뛰어 앞뒤에 쉼표가 남지 않게 하고,
  ///  구획 사이에만 쉼표를 넣는다. 각 구획 '안'의 서식은 그대로 유지된다.
  ///  구획 끝(또는 다음 구획 앞)에 줄바꿈을 넣어 두었으면 그 줄바꿈도 살려 잇는다.
  ///   예) 긍정 '자연어 문장,⏎' + 후행 'masterpiece' → '자연어 문장,⏎masterpiece'
  ///  ⚠️ 예전엔 늘 ", " 로 이어서, 구획 끝 줄바꿈이 사라지고 한 줄로 붙었다
  ///     (sanitizePrompt 가 맨 끝의 빈 조각을 버리면서 줄바꿈도 같이 버려지기 때문).
  ///  경계가 가중치 표시에 닿으면 (앞이 '1.1::' 로 끝나거나 뒤가 '::' 로 시작) 쉼표 없이 잇는다
  ///   — 선행 끝에서 연 가중치가 긍정 첫 태그에 바로 붙게 (weightTouchesBoundary 참고).
  String joinPromptSections(List<String> sections) {
    final out = StringBuffer();
    String? prevRaw; // 앞 구획(정리 전) — 끝에 줄바꿈을 뒀는지 본다
    String prev = ''; // 앞 구획(정리 후) — 가중치 표시로 끝나는지 본다
    for (final raw in sections) {
      final s = sanitizePrompt(raw);
      if (s.isEmpty) {
        continue;
      }
      if (prevRaw != null) {
        final int breaks = max(
          _newlinesIn(_trailingBlank.firstMatch(prevRaw)),
          _newlinesIn(_leadingBlank.firstMatch(raw)),
        );
        final String lines = '\n' * breaks;
        out.write(weightTouchesBoundary(prev, s) ? lines : (breaks > 0 ? ',$lines' : ', '));
      }
      out.write(s);
      prevRaw = raw;
      prev = s;
    }
    return out.toString();
  }

  // 구획 끝·앞의 '빈 자리' (공백·줄바꿈·쉼표). 여기에 든 줄바꿈 수만큼 줄을 나눠 잇는다.
  static final RegExp _trailingBlank = RegExp(r'[\s,]*$');
  static final RegExp _leadingBlank = RegExp(r'^[\s,]*');
  static int _newlinesIn(RegExpMatch? m) => m == null ? 0 : '\n'.allMatches(m[0]!).length;

  // Gelbooru rating 정규화: "explicit" → "e", "questionable" → "q" 등
  static String _normalizeRating(String? raw) {
    if (raw == null || raw.isEmpty) {
      return "g";
    }
    return raw.substring(0, 1).toLowerCase();
  }

  /// 작가·작품으로 '확실한' 이름 — 캐릭터일 리 없으니 카테고리를 물을 필요가 없다.
  ///  (에셋 사전 filter_names 는 작가·작품·캐릭터가 섞여 있어 여기서 판단하지 않는다 → 물어본다)
  static bool _isKnownNonCharacterName(String t) =>
      TagFilters.artistNames.contains(t) ||
      t.endsWith('_(artist)') ||
      TagFilters.copyrightNames.contains(t);

  /// 카테고리 조회에 실패했을 때 쓰는 캐릭터 판정 — 캐릭터 사전에 있거나,
  ///  '이름_(작품명)' 모양이고 괄호 안이 알려진 작품이면 캐릭터로 본다.
  ///  (예: kisaki_(blue_archive), hu_tao_(genshin_impact))
  static bool _looksLikeCharacter(String t) {
    if (TagFilters.characterNames.contains(t)) {
      return true;
    }
    final m = RegExp(r'^.+_\(([^)]+)\)$').firstMatch(t);
    if (m == null) {
      return false;
    }
    final inner = m.group(1)!;
    return TagFilters.copyrightNames.contains(inner) ||
        TagFilters.copyrightTags.contains(inner.replaceAll('_', ' '));
  }

  // ============================================================================
  // 프롬프트 태그 우선순위 정렬
  // 순서: 인원수 → solo → 시점/앵글 → 시선 방향 → 나머지(셔플)
  // ============================================================================
  static const Set<String> _countTags = {
    '1girl',
    '2girls',
    '3girls',
    '4girls',
    '5girls',
    '6+girls',
    'multiple girls',
    '1boy',
    '2boys',
    '3boys',
    '4boys',
    '5boys',
    '6+boys',
    'multiple boys',
    '1other',
    '2others',
    '3others',
    'multiple others',
  };

  static const Set<String> _soloTags = {'solo'};

  static const Set<String> _viewpointTags = {
    // 수직 앵글
    'from above', 'from below', 'high angle', 'low angle',
    "bird's-eye view", "worm's-eye view", 'overhead shot',
    // 방향
    'from behind', 'from side', 'from outside',
    'side view', 'profile', 'rear view', 'back view',
    // 틸트/스타일
    'dutch angle', 'tilted view', 'straight-on',
    // POV
    'pov', 'first-person view',
    // 프레이밍
    'close-up', 'upper body', 'lower body', 'cowboy shot',
    'portrait', 'full body', 'wide shot', 'medium shot',
    'face', 'head focus',
  };

  static const Set<String> _gazeTags = {
    'looking at viewer',
    'looking away',
    'looking back',
    'looking down',
    'looking up',
    'looking to the side',
    'looking at another',
    'looking ahead',
    'looking afar',
    'looking at phone',
    'looking at mirror',
    'looking at hand',
    'eye contact',
    'staring',
    'glaring',
    'eyes closed',
    'one eye closed',
    'half-closed eyes',
    'closed eyes',
  };

  List<String> _reorderTagsByPriority(List<String> tags, {Set<String> chars = const {}}) {
    List<String> countGroup = [];
    List<String> soloGroup = [];
    List<String> charGroup = [];
    List<String> viewGroup = [];
    List<String> gazeGroup = [];
    List<String> bgGroup = [];
    List<String> rest = [];

    for (var tag in tags) {
      final lower = tag.toLowerCase();
      if (_countTags.contains(lower)) {
        countGroup.add(tag);
      } else if (_soloTags.contains(lower)) {
        soloGroup.add(tag);
      } else if (chars.contains(tag)) {
        charGroup.add(tag);
      } else if (_viewpointTags.contains(lower)) {
        viewGroup.add(tag);
      } else if (_gazeTags.contains(lower)) {
        gazeGroup.add(tag);
      } else if (_isBackgroundTag(lower)) {
        bgGroup.add(tag);
      } else {
        rest.add(tag);
      }
    }

    rest.shuffle();
    bgGroup.shuffle();
    // 인원수 → solo → 캐릭터 → 시점 → 시선 → 일반(셔플) → 배경(맨 뒤)
    //  (단보루 관례대로 '1girl, hatsune miku, …' 처럼 캐릭터를 앞쪽에 둔다)
    return [
      ...countGroup,
      ...soloGroup,
      ...charGroup,
      ...viewGroup,
      ...gazeGroup,
      ...rest,
      ...bgGroup,
    ];
  }

  bool _isBackgroundTag(String lower) {
    // 접미사 매칭: ~background, ~sky 패턴
    if (lower.endsWith('background') || lower.endsWith(' sky')) {
      return true;
    }
    // 고정 목록 매칭
    return TagFilters.backgroundTags.contains(lower);
  }

  // ============================================================================
  // 단보루 태그 파싱 로직 (기존 유지)
  // ============================================================================
  // 태그 카테고리 조회: 1차 Danbooru(정확) → 2차 Gelbooru(겔부루 전용 태그 커버).
  // Danbooru에 없는 겔부루 전용 작가가 '일반'으로 오인돼 프롬프트에 새는 것을 방지한다.

  // ── 태그 분류 캐시 (태그 이름 → 종류 번호: 0 일반·1 작가·3 작품·4 캐릭터·5 메타) ──
  //  예전엔 SharedPreferences 에 JSON 글자 하나(최대 5만 개, ~1MB)로 두고 검색마다 통째로 풀고 다시 썼다.
  //  설정 파일(XML)은 값 하나만 바뀌어도 전체를 다시 쓰고, 앱을 켤 때 통째로 읽힌다 → 파일로 뺐다.
  //   · 처음 쓸 때 한 번만 파일에서 읽어(화면 밖) 메모리에 들고 있는다.
  //   · 꽉 차면 '가장 오래 안 쓴' 태그부터 버린다 — 캐시에서 찾을 때마다 맨 뒤로 보낸다.
  //     (예전엔 '먼저 들어온' 순서로 버려서 자주 나오는 태그도 밀려났다)
  //   · 새 태그가 들어온 검색 끝에만 쓴다. 쓰기는 기다리지 않는다 (검색 결과와 상관없다).
  static const int _tagCacheMax = 50000;
  // 예전 버전이 설정에 쓰던 이름들 (v1·v2 는 오염 가능성 때문에 예전부터 버리던 것)
  static const List<String> _legacyTagCacheKeys = [
    'tag_category_cache_v3',
    'tag_category_cache_v2',
    'danbooru_tag_cache',
  ];
  static Map<String, int>? _tagCache; // null = 아직 안 읽음
  static Future<Map<String, int>>? _tagCacheLoading;
  static Future<bool> _tagCacheSaving = Future.value(true);

  static Future<File> _tagCacheFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/tag_category_cache.json');

  /// 캐시를 (처음 한 번만) 읽어 온다. 실패해도 빈 캐시 — 검색은 멈추지 않는다.
  ///  잠깐 못 읽은 경우(메모리 부족 등)엔 이번 검색만 '임시' 빈 캐시를 주고 기억하지 않는다 →
  ///  다음 검색에 다시 읽는다. 임시 캐시는 저장하지 않는다 (멀쩡한 5만 개 파일을 덮지 않게).
  static Future<Map<String, int>> _loadTagCache() {
    final ready = _tagCache;
    if (ready != null) {
      return Future.value(ready);
    }
    return _tagCacheLoading ??= _readTagCacheOnce().then((m) {
      _tagCacheLoading = null;
      if (m == null) {
        return <String, int>{};
      }
      return _tagCache = m;
    });
  }

  /// 예전 버전이 설정에 남긴 태그 분류 캐시가 있으면 지금 파일로 옮긴다 (앱을 켤 때, 기다리지 않는다).
  ///  검색을 안 하면 옮길 기회가 없어 ~1MB 가 설정 파일에 남아, 설정이 바뀔 때마다 같이 다시 쓰였다.
  static Future<void> migrateLegacyTagCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_legacyTagCacheKeys.any(prefs.containsKey)) {
        await _loadTagCache(); // 읽으면서 옮기고, 옮긴 뒤 설정 쪽을 지운다
      }
    } catch (e) {
      debugPrint('태그 분류 캐시 옮기기 실패 (다음에 다시): $e');
    }
  }

  /// 반환 null = 잠깐 못 읽음 (위 _loadTagCache 설명)
  static Future<Map<String, int>?> _readTagCacheOnce() async {
    try {
      final f = await _tagCacheFile();
      Map<String, int> m = {};
      bool fromFile = false;
      if (await f.exists()) {
        try {
          m = await compute(_readTagCacheFile, f.path);
          fromFile = true;
        } on FormatException catch (e) {
          // 내용이 깨졌다 — 캐시라 살릴 필요가 없다. 새로 쌓는다 (아래에서 덮어쓴다)
          debugPrint('태그 분류 캐시 파일이 깨짐 (새로 쌓습니다): $e');
        }
      }
      // 예전 버전이 설정에 둔 캐시 → 합친다.
      //  처음 올라왔을 때뿐 아니라, 옛 버전으로 내렸다가 다시 올린 경우에도 그동안 쌓인 걸 살린다.
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString('tag_category_cache_v3');
      if (legacy != null) {
        try {
          final old = await compute(_decodeTagCacheString, legacy);
          // 파일 쪽이 더 최근에 쓴 것 — 파일에 없는 태그만 앞(오래된 쪽)에 붙인다
          final merged = <String, int>{};
          old.forEach((k, v) {
            if (!m.containsKey(k)) {
              merged[k] = v;
            }
          });
          merged.addAll(m);
          m = merged;
          debugPrint('예전 태그 분류 캐시 ${old.length}개를 파일로 옮깁니다');
        } catch (e) {
          debugPrint('예전 태그 분류 캐시 읽기 실패 (버립니다): $e');
        }
      }
      // 파일이 없었거나(처음·깨짐) 설정에 예전 사본이 남아 있으면 지금 한 번 쓴다.
      //  쓰기에 성공하면 설정 쪽 사본은 _writeTagCacheFile 이 지운다 (실패하면 남겨 두고 다음에).
      if (!fromFile || _legacyTagCacheKeys.any(prefs.containsKey)) {
        await _writeTagCacheFile(m);
      }
      return m;
    } catch (e) {
      debugPrint('태그 분류 캐시 읽기 실패 (이번 검색은 저장하지 않습니다): $e');
      return null;
    }
  }

  /// 캐시를 파일로 쓴다 (JSON 만들기는 화면 밖, 쓰기는 임시 파일 → 이름 바꾸기). 차례로 돈다.
  ///  반환: 썼는지. 쓰고 나면 예전 버전이 설정에 남긴 캐시를 지운다.
  static Future<bool> _writeTagCacheFile(Map<String, int> cache) {
    final snapshot = Map<String, int>.of(cache); // 쓰는 사이 다음 검색이 바꿔도 이 모습으로
    final next = _tagCacheSaving.then((_) async {
      try {
        final bytes = await compute(_encodeTagCache, snapshot);
        final f = await _tagCacheFile();
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(f.path);
        final prefs = await SharedPreferences.getInstance();
        for (final k in _legacyTagCacheKeys) {
          if (prefs.containsKey(k)) {
            await prefs.remove(k);
          }
        }
        return true;
      } catch (e) {
        debugPrint('태그 분류 캐시 저장 실패: $e');
        return false;
      }
    });
    _tagCacheSaving = next;
    return next;
  }

  /// 첫 페이지 결과로 '더 받아야 할 페이지 수' 를 센다. 모르면 [unknown].
  static int _pagesStillNeeded(_PostsPage? first, int unknown) {
    if (first == null) {
      return unknown; // 첫 페이지를 못 받았다 — 결과 수를 모른다
    }
    final int? total = first.total;
    if (total != null) {
      return max(0, (total + 99) ~/ 100 - 1); // 100개씩 — 첫 페이지는 이미 받았다
    }
    return first.raw < 100 ? 0 : unknown; // 결과 수가 안 왔다 — 첫 페이지가 덜 찼으면 거기서 끝
  }

  /// [budget] 페이지를 [need] 대로 나눈다 — 적게 필요한 쪽은 필요한 만큼 다 주고, 남은 걸 나머지가 똑같이 나눈다.
  ///  예) 필요 [2, 50, 50], 예산 30 → [2, 14, 14]
  static List<int> _sharePages(List<int> need, int budget) {
    final List<int> give = List<int>.filled(need.length, 0);
    int left = budget;
    List<int> open = [
      for (int i = 0; i < need.length; i++)
        if (need[i] > 0) i,
    ];
    // 예산이 묶음 수보다 적으면 앞쪽 묶음만 받게 된다 — 시작점을 매번 섞어 특정 OR 옵션만 유리하지 않게
    if (open.length > 1) {
      final int r = Random().nextInt(open.length);
      open = [...open.sublist(r), ...open.sublist(0, r)];
    }
    while (left > 0 && open.isNotEmpty) {
      final int each = max(1, left ~/ open.length);
      final List<int> still = [];
      for (final i in open) {
        final int g = min(each, min(need[i] - give[i], left));
        give[i] += g;
        left -= g;
        if (give[i] < need[i]) {
          still.add(i);
        }
      }
      open = still;
    }
    return give;
  }

  /// 429 응답의 Retry-After(초). 없거나 이상하면 2초, 길면 5초로 자른다 (검색이 너무 오래 멈추지 않게).
  static Duration _retryAfter(http.Response r) {
    final int sec = int.tryParse(r.headers['retry-after'] ?? '') ?? 2;
    return Duration(seconds: sec.clamp(1, 5));
  }

  Future<Map<String, int>> _getDanbooruTagCategories(
    List<String> uniqueTags,
    String gelbooruUserId,
    String gelbooruApiKey, {
    required http.Client client, // 검색이 쓰는 연결을 같이 쓴다
    // 본인 겔부루 키인지 — 아니면 모두가 같이 쓰는 공용 키라 2차(겔부루)를 더 천천히 묻는다
    required bool hasOwnKey,
    void Function(String stage)? onStage,
  }) async {
    // 캐시 (첫 검색 때 한 번만 파일에서 읽는다 — 위 '태그 분류 캐시' 설명)
    final Map<String, int> cache = await _loadTagCache();

    Map<String, int> finalCategoryMap = {};
    List<String> tagsToFetch = [];

    for (String tag in uniqueTags) {
      if (tag.isEmpty) {
        continue;
      }
      final int? known = cache.remove(tag);
      if (known != null) {
        cache[tag] = known; // 맨 뒤로 보낸다 = '최근에 쓴' 태그 (꽉 차면 앞쪽부터 버린다)
        finalCategoryMap[tag] = known;
      } else {
        tagsToFetch.add(tag);
      }
    }

    if (tagsToFetch.isEmpty) {
      return finalCategoryMap;
    }

    bool isCacheUpdated = false;

    // 이 태그의 분류를 확정한다 (이번 검색의 지도 + 캐시)
    void learn(String name, int category) {
      finalCategoryMap[name] = category;
      cache[name] = category;
      isCacheUpdated = true;
    }

    // 진행 표시: '확인이 끝난 태그 / 확인할 태그'. 1차(단보루)에서 찾았거나 2차(겔부루)까지 물어본 태그를 센다.
    //  ⚠️ 예전엔 1차 묶음을 보낼 때만 숫자를 바꿨다. 1차가 끝나면 '태그 확인 9000/9444' 에서 멈춘 채,
    //     2차(단보루에 없는 태그 수천 개를 50개씩 하나하나 차례로)가 몇십 초씩 돌아 고장 난 것처럼 보였다.
    final int newTagCount = tagsToFetch.length;
    int doneTags = 0;
    void tagsDone(int n) {
      doneTags += n;
      onStage?.call("태그 확인 $doneTags/$newTagCount");
    }

    tagsDone(0);

    try {
      // ── 1차: 단보루 (100개씩) ──
      //  단보루 읽기 한도는 초당 10건이다 — 일꾼 6명 · 시작 간격 0.15초(초당 7건 이하). 429 면 모두 쉬고 한 번 더.
      //  ⚠️ 예전엔 6개씩 묶어 보내고 묶음에서 가장 느린 요청까지 기다린 뒤 0.25초를 쉬었다.
      const int chunkSize = 100;
      final List<List<String>> chunks = [
        for (int i = 0; i < tagsToFetch.length; i += chunkSize)
          tagsToFetch.sublist(i, min(i + chunkSize, tagsToFetch.length)),
      ];
      final danbooruPacer = _RequestPacer(150);

      // 2차(겔부루)로 넘길 태그 — 단보루에 없거나 단보루 요청이 실패한 태그.
      //  1차가 끝나기를 기다리지 않고 모이는 대로 바로 묻는다 (서버가 달라 서로의 한도와 상관없다).
      final List<String> pending = [];
      bool danbooruDone = false;

      Future<void> askDanbooru(List<String> chunk) async {
        Map<String, int>? got;
        // 겔부루는 태그 속 기호를 HTML 문자로 보낸다 (jeanne_d&#039;arc_(fate) · &gt;_&lt;).
        //  단보루에는 원래 글자로 묻고, 답은 받은 모양으로 되돌려 적는다.
        //  ⚠️ 예전엔 받은 모양 그대로 물어 단보루가 못 찾았다 → 이런 태그는 모두 2차(겔부루)로 넘어갔고,
        //     2차까지 실패하면 분류를 몰라 이름이 새거나 괄호 태그가 버려졌다.
        //  (2차 겔부루에는 받은 모양 그대로 묻는다 — 겔부루가 준 이름이라 그 모양으로 찾는다)
        final Map<String, String> askedAs = {for (final t in chunk) unescapeGelbooruHtml(t): t};
        try {
          final names = Uri.encodeComponent(askedAs.keys.join(','));
          final uri = Uri.parse(
            "$_danbooruProxy/tags.json?search[name_comma]=$names&limit=100&only=name,category",
          );
          http.Response? response;
          bool retried = false;
          while (true) {
            await danbooruPacer.waitTurn();
            try {
              final r = await client
                  .get(uri, headers: {'User-Agent': 'PrombotApp/1.0'})
                  .timeout(const Duration(seconds: 15));
              if (r.statusCode == 429 && !retried) {
                danbooruPacer.pauseFor(_retryAfter(r)); // 모두 잠깐 쉬고 이 묶음만 한 번 더
                retried = true;
                continue;
              }
              response = r;
            } on TimeoutException {
              response = null; // 시간 초과는 다시 하지 않는다 — 2차로 넘긴다
            } catch (_) {
              if (!retried) {
                retried = true; // 끊긴 연결 — 새 연결로 한 번 더
                continue;
              }
              response = null;
            }
            break;
          }
          // 응답 하나가 이상해도(형식 오류) 그 묶음만 2차로 넘긴다
          if (response != null && response.statusCode == 200) {
            final data = jsonDecode(_utf8Body(response));
            if (data is List) {
              final Map<String, int> m = {};
              for (final tagInfo in data) {
                final name = tagInfo is Map ? tagInfo['name'] : null;
                final category = tagInfo is Map ? tagInfo['category'] : null;
                if (name is String && category is int) {
                  m[askedAs[name] ?? name] = category;
                }
              }
              got = m;
            }
          }
        } catch (e) {
          debugPrint("단보루 태그 응답 해석 실패 (2차로 넘김): $e");
          got = null;
        }
        if (got == null) {
          // [핵심] 응답 실패(타임아웃/429 등) 묶음을 조용히 버리면 태그가 미분류로 남아
          // 작가/캐릭터 이름이 프롬프트에 그대로 새어 나간다 → 겔부루 2차로 넘겨 분류 시도.
          // (겔부루 2차도 실패하면 캐시에 안 남으므로 다음 검색 때 자동 재시도된다)
          pending.addAll(chunk);
          return;
        }
        got.forEach(learn);
        // 응답에 없는 태그 = 단보루에 없는 태그 → 겔부루 2차로
        int found = 0;
        for (final tag in chunk) {
          if (got.containsKey(tag)) {
            found++;
          } else {
            pending.add(tag);
          }
        }
        tagsDone(found);
      }

      // ── 2차: 겔부루 태그 DB (50개씩) ──
      //  포스트 출처가 겔부루이므로, 겔부루 전용 작가/태그도 여기서 정확히 잡힌다.
      //  (type: 0=일반, 1=작가, 3=작품, 4=캐릭터, 5=메타, 6=폐기)
      //  50개씩: 100개를 공백으로 이으면 URL 길이/응답 상한 경계에 걸려 실존 태그가 응답에서 누락
      //  → 0(일반)으로 영구 오염될 수 있다.
      //  ⚠️ 예전엔 1차가 다 끝난 뒤 한 번에 하나씩 0.2초 쉬어 가며 물었다 (수천 개면 몇십 초).
      //     이제 일꾼 여럿이 1차와 겹쳐 묻는다 — 본인 키가 없으면(공용 키) 더 천천히.
      const int gChunkSize = 50;
      final int gWorkers = hasOwnKey ? 5 : 3;
      final gelbooruPacer = _RequestPacer(hasOwnKey ? 120 : 250);
      int gelbooruAsked = 0;

      Future<void> askGelbooru(List<String> chunk) async {
        try {
          final names = Uri.encodeComponent(chunk.join(' '));
          final uri = Uri.parse(
            "$_gelbooruProxy/index.php?page=dapi&s=tag&q=index&json=1&limit=100&names=$names&user_id=$gelbooruUserId&api_key=$gelbooruApiKey",
          );
          http.Response? resp;
          bool retried = false;
          while (true) {
            await gelbooruPacer.waitTurn();
            try {
              final r = await client
                  .get(uri, headers: {'User-Agent': _browserUserAgent})
                  .timeout(const Duration(seconds: 10));
              if (r.statusCode == 429 && !retried) {
                gelbooruPacer.pauseFor(_retryAfter(r)); // 모두 잠깐 쉬고 이 묶음만 한 번 더
                retried = true;
                continue;
              }
              resp = r;
            } on TimeoutException {
              resp = null;
            } catch (_) {
              if (!retried) {
                retried = true; // 끊긴 연결 — 새 연결로 한 번 더
                continue;
              }
              resp = null;
            }
            break;
          }
          if (resp != null && resp.statusCode == 200) {
            // 바이트에서 UTF-8 로 — resp.body 는 charset 이 없으면 latin-1 로 풀어 일본어 태그 이름이 깨졌고,
            //  깨진 이름은 아래 '응답에 없는 태그' 로 잘못 분류돼 일반(0)으로 굳었다.
            final decoded = jsonDecode(_utf8Body(resp));
            final rawTags = decoded is Map ? decoded['tag'] : null;
            // 한 개만 오면 목록이 아니라 그 하나가 온다
            final List gTags = rawTags is List ? rawTags : (rawTags is Map ? [rawTags] : const []);
            final Set<String> gFound = {};
            for (final tagInfo in gTags) {
              if (tagInfo is! Map) {
                continue;
              }
              final String name = tagInfo['name'].toString();
              final int type = int.tryParse(tagInfo['type'].toString()) ?? 0;
              gFound.add(name);
              learn(name, type);
            }
            // 양쪽 DB 모두에 없는 태그만 일반(0)으로 캐시 → 무한 재조회 차단
            for (final tag in chunk) {
              if (!gFound.contains(tag)) {
                learn(tag, 0);
              }
            }
          }
        } catch (e) {
          debugPrint("겔부루 태그 분류 폴백 실패: $e");
        }
        // 성공이든 실패든 이 태그들은 물어봤다 (실패한 태그는 캐시에 안 남아 다음 검색 때 다시 묻는다)
        gelbooruAsked += chunk.length;
        tagsDone(chunk.length);
      }

      // 2차 일꾼 — 50개가 모이면 바로, 1차가 끝났으면 남은 것을 마저 묻는다
      Future<void> gelbooruWorker() async {
        while (true) {
          if (pending.length >= gChunkSize || (danbooruDone && pending.isNotEmpty)) {
            final int n = min(gChunkSize, pending.length);
            final List<String> chunk = pending.sublist(0, n);
            pending.removeRange(0, n);
            await askGelbooru(chunk);
          } else if (danbooruDone) {
            return; // 1차도 끝났고 남은 것도 없다
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 100)); // 1차가 더 넘겨 주기를 기다린다
          }
        }
      }

      Future<void> runDanbooru() async {
        try {
          await _runPool(6, [for (final c in chunks) () => askDanbooru(c)]);
        } finally {
          danbooruDone = true; // ⚠️ 무슨 일이 있어도 — 안 그러면 2차 일꾼이 끝없이 기다린다
        }
      }

      await Future.wait([runDanbooru(), for (int w = 0; w < gWorkers; w++) gelbooruWorker()]);
      if (gelbooruAsked > 0) {
        debugPrint("🏷️ 태그 분류 2차(겔부루): $gelbooruAsked개 처리");
      }

      // 임시 캐시(파일을 잠깐 못 읽음)는 저장하지 않는다 — 멀쩡한 파일을 덮지 않게
      if (isCacheUpdated && identical(cache, _tagCache)) {
        // 꽉 찼으면 앞쪽(가장 오래 안 쓴 것)부터 버린다
        final int over = cache.length - _tagCacheMax;
        if (over > 0) {
          for (final k in cache.keys.take(over).toList()) {
            cache.remove(k);
          }
        }
        unawaited(_writeTagCacheFile(cache)); // 기다리지 않는다 — 검색 결과와 상관없다
      }
    } catch (e) {
      debugPrint("단보루 카테고리 페칭 실패: $e");
    }
    return finalCategoryMap;
  }

  Future<List<String>> fetchDanbooruTags({
    // 포함 칸을 푼 검색 계획 ({A|B} 조합 · *keyword — models/prompt_search.dart)
    required SearchPlan plan,
    required bool rG,
    required bool rS,
    required bool rQ,
    required bool rE,
    required String gelbooruUserId,
    required String gelbooruApiKey,
    List<String> localExcludeTags = const [],
    // 받을 페이지 수 (첫 페이지들 포함 전체). null 이면 기본값 — searchPagesWithKey / WithoutKey
    int? maxPagesToFetch,
    void Function(int done, int total, int found)? onProgress,
    void Function(String stage)? onStage,
    // 조합이 너무 많아 그중 일부만 검색에 담았을 때만 불린다 (담은 조합 수, 전체 조합 수)
    void Function(int searched, int total)? onCombos,
  }) async {
    // 검색 하나 동안 같은 연결을 계속 쓴다 (페이지 수십 개 + 태그 분류 요청).
    //  ⚠️ 예전엔 http.get 을 그냥 불러 요청마다 새로 연결(TLS 악수)했다 — 모바일에선 한 번에 0.1~0.3초.
    //     http 패키지 안내대로 Client 하나를 쓰면 연결이 유지돼 그 시간이 빠진다. 다 쓰면 꼭 닫는다.
    final client = http.Client();
    try {
      return await _searchPrompts(
        client,
        plan: plan,
        rG: rG,
        rS: rS,
        rQ: rQ,
        rE: rE,
        gelbooruUserId: gelbooruUserId,
        gelbooruApiKey: gelbooruApiKey,
        localExcludeTags: localExcludeTags,
        maxPagesToFetch: maxPagesToFetch,
        onProgress: onProgress,
        onStage: onStage,
        onCombos: onCombos,
      );
    } finally {
      client.close();
    }
  }

  Future<List<String>> _searchPrompts(
    http.Client client, {
    required SearchPlan plan,
    required bool rG,
    required bool rS,
    required bool rQ,
    required bool rE,
    required String gelbooruUserId,
    required String gelbooruApiKey,
    List<String> localExcludeTags = const [],
    int? maxPagesToFetch,
    // 검색 진행 상황 콜백 (완료 페이지 수, 전체 페이지 수, 지금까지 모인 유효 포스트 수)
    void Function(int done, int total, int found)? onProgress,
    // 검색 후 단계 메시지 콜백 (분류/필터/캐시 등 "지금 뭐 하는 중")
    void Function(String stage)? onStage,
    void Function(int searched, int total)? onCombos,
    // (예전 '[실험] 정렬 다양화' — score/id 축 섞기 — 는 섞기 번호를 쓰면서 뺐다. 아래 ② 설명)
  }) async {
    // 로컬 제외 태그 Set (빠른 검색용)
    final Set<String> localExcludeSet = localExcludeTags.map((t) => t.toLowerCase()).toSet();

    // 모든 묶음에 붙는 레이팅 필터
    //  (제외 태그는 검색어로 보내지 않고 받은 뒤 localExcludeTags 로 거른다 — 검색어가
    //   길어지면 겔부루가 결과를 덜 주기 때문)
    final List<String> baseTags = [];

    if (!rG) {
      baseTags.add("-rating:general");
    }
    if (!rS) {
      baseTags.add("-rating:sensitive");
    }
    if (!rQ) {
      baseTags.add("-rating:questionable");
    }
    if (!rE) {
      baseTags.add("-rating:explicit");
    }

    const String fallbackUserId = "1939815";
    const String fallbackApiKey =
        "cffc455dd65a8733c0524ea230cb259a03b246c3f2fb00086199a71a8acc6b22e134ea32e229af0eb655bde67a43cacf7380073201af688ba50b5ff0f1df738e";

    bool hasCredentials = gelbooruUserId.isNotEmpty && gelbooruApiKey.isNotEmpty;
    String effectiveUserId = hasCredentials ? gelbooruUserId : fallbackUserId;
    String effectiveApiKey = hasCredentials ? gelbooruApiKey : fallbackApiKey;

    // 받을 페이지 수 (첫 페이지들 포함 전체 예산):
    //  - 본인 키(아이디 + 키)가 있으면 부른 쪽이 정한 값, 안 정했으면 40
    //  - 없으면 공용 fallback 키라 15 고정 — 공용 키 부담을 줄이고 429 를 피한다
    //    (키만 있고 아이디가 없으면 공용 키로 검색하므로 이쪽이다 — 설정 화면도 같은 기준으로 보여 준다)
    //  ⚠️ 예전엔 '20 이 오면 기본값' 이라는 약속 숫자를 썼다 — 이제 null 이 기본값이다.
    final int effectiveMaxPages = hasCredentials
        ? (maxPagesToFetch ?? searchPagesWithKey)
        : searchPagesWithoutKey;

    // ── 검색어 묶음 ──
    //  포함 칸의 {A|B} 조합 하나 = 묶음 하나 — 묶음마다 따로 검색해 합친다 (models/prompt_search.dart 의 SearchPlan).
    //  묶음마다 첫 페이지는 꼭 받으므로, 조합이 받을 페이지 수보다 많으면 보기가 많은 조각부터 겔부루의
    //  '또는 묶음' {a ~ b ~ c} 으로 합쳐 묶음 수를 줄인다 — 모든 조합이 검색에 들어간다
    //  (예: *hair(20개), {A|B|C|D}, {E|F|G} = 240 조합, 페이지 40 → 묶음 36개로 240 조합 전부).
    //  합칠 수 없는 조각뿐이면 그만큼만 고르게 골라 검색한다 (검색할 때마다 다르게).
    final searchSet = plan.queries(effectiveMaxPages);
    if (searchSet.covered < plan.combinations) {
      onCombos?.call(searchSet.covered, plan.combinations); // 일부만 담았다 — 부른 쪽이 알려 준다
    }
    final List<List<String>> groups = [
      for (final g in searchSet.groups) [...g, ...baseTags],
    ];
    String encodeQuery(List<String> tags) => Uri.encodeQueryComponent(tags.join(' '));

    // 이번 검색의 섞기 번호 — 'sort:random:번호' 는 번호가 같으면 페이지를 넘겨도 같은 순서를 지킨다.
    //  (겔부루 안내: 번호는 0~10000. 사이트에 그림이 추가·삭제·수정되면 다시 섞일 수 있다 — 큰 사이트라
    //   검색 도중에도 생길 수 있다. 그래도 겹친 그림은 아래에서 id 로 걸러지고, 최악이라도 예전과 같다)
    //  ⚠️ 예전엔 그냥 'sort:random' 이라 페이지마다 새로 섞였다 → 페이지끼리 겹쳐 같은 그림을 또 받았다
    //     (결과 1,500개짜리 검색이면 15페이지를 받아도 고유한 건 1,000개 남짓).
    //  번호는 검색마다 새로 뽑는다 — 같은 검색을 다시 해도 다른 표본이 나온다.
    final String randomSort = "sort:random:${Random().nextInt(10001)}";

    final List<_SlimPost> allValidPosts = [];
    final Set<int> seenIds = {};

    // 결과가 하나도 없을 때 원인을 알려 주려고 오류를 종류별로 센다
    int totalRequests = 0;
    int failedRequests = 0;
    int timeoutRequests = 0;
    int serverErrors = 0;
    int rateLimitErrors = 0; // 429 별도 카운트
    int clientErrors = 0; // 4xx (429 제외)

    // ── 요청 보내기 ──
    //  일꾼 여러 명이 할 일 줄에서 하나씩 가져간다 — 끝난 일꾼이 바로 다음 페이지를 가져간다.
    //  ⚠️ 예전엔 10개씩 묶어 보내고, 묶음에서 가장 느린 요청(최악 10초)까지 다 기다린 뒤 0.2초를 쉬었다.
    //  대신 요청 '시작' 사이에 간격을 둬서 서버에 한꺼번에 몰아치지 않는다 (키가 없으면 공용 키라 더 천천히).
    final int workers = hasCredentials ? 10 : 5;
    final pacer = _RequestPacer(hasCredentials ? 100 : 200);
    bool stopAll = false; // 키가 틀렸다 등 — 다른 페이지도 똑같이 실패하니 남은 건 보내지 않는다

    // 페이지 하나 받기. 실패면 null (종류별로 센다).
    //  429(너무 빠름)·연결 끊김은 한 번만 더 시도한다 — 예전엔 그 페이지를 그냥 버렸다.
    //  시간 초과(10초)는 다시 하지 않는다 — 기다림만 두 배가 된다.
    //  [skip] 이 참이면 (차례를 기다리는 사이 결과가 끝났다 등) 보내지 않고 null.
    Future<http.Response?> fetchPage(String query, int page, bool Function() skip) async {
      final uri = Uri.parse(
        "$_gelbooruProxy/index.php?page=dapi&s=post&q=index&json=1&limit=100&pid=$page&tags=$query"
        "&user_id=$effectiveUserId&api_key=$effectiveApiKey",
      );
      bool retried = false;
      while (true) {
        if (skip()) {
          return null; // 줄 서기 전에도 본다 — 그만둘 거면 자리를 잡지 않는다
        }
        await pacer.waitTurn();
        if (skip()) {
          return null;
        }
        if (!retried) {
          totalRequests++; // 다시 시도해도 한 페이지는 한 건으로 센다 (오류 안내의 '총 N건' 과 맞게)
        }
        try {
          final r = await client
              .get(uri, headers: {'User-Agent': _browserUserAgent})
              .timeout(const Duration(seconds: 10));
          if (r.statusCode == 429) {
            pacer.pauseFor(_retryAfter(r)); // 모두 잠깐 쉰다
            if (!retried) {
              retried = true;
              continue; // 이 페이지만 한 번 더
            }
          }
          return r;
        } on TimeoutException {
          timeoutRequests++;
          return null;
        } catch (e) {
          if (!retried) {
            retried = true; // 끊긴 연결(서버가 오래된 연결을 닫음 등) — 새 연결로 한 번 더
            continue;
          }
          failedRequests++;
          debugPrint("겔보루 요청 에러: $e");
          return null;
        }
      }
    }

    // 응답 1건 → (화면 밖에서) 풀기 → 처음 보는 포스트만 모은다. 못 받았거나 못 풀었으면 null.
    Future<_PostsPage?> processResponse(http.Response? response) async {
      if (response == null) {
        return null;
      }
      if (response.statusCode != 200) {
        final code = response.statusCode;
        if (code == 429) {
          rateLimitErrors++;
        } else if (code >= 500) {
          serverErrors++;
        } else if (code >= 400) {
          clientErrors++;
          if (code == 401 || code == 403) {
            stopAll = true; // 키가 틀렸다 — 다른 페이지도 똑같이 실패한다
          }
          // 그 밖의 4xx (한 OR 옵션의 검색어가 너무 긴 경우 등)는 그 검색어만 실패로 센다 (연달아 3번이면 멈춤)
        } else {
          serverErrors++;
        }
        return null;
      }
      try {
        final page = await compute(_slimPostsPage, response.bodyBytes);
        for (final post in page.posts) {
          if (seenIds.add(post.id)) {
            allValidPosts.add(post);
          }
        }
        return page;
      } catch (e) {
        // 200 인데 못 푼다 = 서버가 이상한 내용을 줬다 (점검 페이지 등) — 오류로 센다.
        //  (안 세면 전부 이렇게 실패했을 때 '오류' 대신 '검색 결과 없음' 으로 안내된다)
        serverErrors++;
        debugPrint("겔보루 파싱 에러: $e");
        return null;
      }
    }

    // 진행 표시: 받은 페이지 / 받을 페이지 (첫 페이지들을 받은 뒤 '받을 페이지' 가 정해진다)
    int donePages = 0;
    int plannedPages = groups.length;
    void report() => onProgress?.call(donePages, plannedPages, allValidPosts.length);

    Future<_PostsPage?> loadPage(String query, int page, bool Function() skip) async {
      final r = await fetchPage(query, page, skip);
      if (r == null && skip()) {
        plannedPages--; // 보내지 않았다 — 받을 페이지에서 뺀다
        report();
        return null;
      }
      final res = await processResponse(r);
      donePages++;
      report(); // 검색 버튼의 찾은 개수가 실시간으로 차오른다
      return res;
    }

    // ① 묶음마다 첫 페이지 (섞기 순서로). 응답에 '전체 결과 수' 가 같이 온다.
    report();
    final List<_PostsPage?> first = List<_PostsPage?>.filled(groups.length, null);
    await _runPool(workers, [
      for (int g = 0; g < groups.length; g++)
        () async {
          first[g] = await loadPage(encodeQuery([...groups[g], randomSort]), 0, () => stopAll);
        },
    ]);

    // 첫 페이지를 하나도 못 받았으면(네트워크 끊김·키 오류·서버 점검) 더 보내지 않는다 —
    //  아래에서 오류 종류별로 안내한다.
    if (!stopAll && first.any((p) => p != null)) {
      // ② 남은 페이지를 묶음마다 '필요한 만큼만' 나눈다.
      //  필요 = 전체 결과 수 ÷ 100 (올림) − 이미 받은 첫 페이지. 결과 300개짜리 묶음은 2페이지 더면 끝.
      //  ⚠️ 예전엔 묶음마다 페이지를 똑같이 나눠, 작은 묶음은 빈 페이지를 때리고 큰 묶음은 모자랐다.
      //  예산이 모자라면 적게 필요한 묶음부터 다 채우고, 남은 걸 큰 묶음들이 똑같이 나눈다 (_sharePages).
      //  첫 페이지를 못 받은 묶음은 결과 수를 모른다 → 첫 페이지부터 몫만큼 받다가 빈 페이지가 나오면 멈춘다.
      const int unknownNeed = 1 << 30;
      final List<int> need = [
        for (final p in first) _pagesStillNeeded(p, unknownNeed),
      ];
      final List<int> share = _sharePages(need, max(0, effectiveMaxPages - groups.length));

      // 묶음별로 받을 범위 — 섞기 순서 하나로 받는다.
      //  (예전엔 '정렬 다양화' 로 점수순·최신순도 섞었다. 섞기 번호를 쓰면 섞기 순서만으로도 페이지가
      //   안 겹치고, 점수순·최신순은 늘 같은 순서라 검색을 거듭할수록 같은 그림이 반복돼서 뺐다)
      final List<_PageRun> runs = [
        for (int g = 0; g < groups.length; g++)
          if (share[g] > 0)
            _PageRun(
              encodeQuery([...groups[g], randomSort]),
              first[g] == null ? 0 : 1, // 첫 페이지를 받았으면 그다음부터
              share[g],
            ),
      ];

      // ③ 페이지 번호 순으로 묶음들을 번갈아 줄 세워 받는다 — 모든 묶음이 고르게 진행되고,
      //  결과가 일찍 끝난 묶음(빈 페이지)은 남은 차례를 바로 건너뛴다.
      final List<Future<void> Function()> jobs = [];
      final int longest = runs.fold(0, (m, r) => max(m, r.count));
      for (int k = 0; k < longest; k++) {
        for (final run in runs) {
          if (k >= run.count) {
            continue;
          }
          final int page = run.from + k;
          jobs.add(() async {
            if (run.ended || stopAll) {
              plannedPages--; // 결과가 끝났다 — 이 페이지는 받지 않는다
              report();
              return;
            }
            final res = await loadPage(run.query, page, () => run.ended || stopAll);
            if (res == null) {
              // 연달아 3번 실패 — 이 검색어는 그만둔다 (네트워크·서버 문제면 남은 페이지도 똑같다)
              //  ⚠️ 이게 없으면 네트워크가 끊겼을 때 예산을 다 쓸 때까지 실패 요청을 계속 보냈다.
              if (++run.fails >= 3) {
                run.ended = true;
              }
            } else {
              run.fails = 0;
              if (res.raw == 0) {
                run.ended = true; // 빈 페이지 = 결과 끝
              }
            }
          });
        }
      }
      plannedPages += jobs.length;
      report();
      await _runPool(workers, jobs);
    }

    // 결과 종합 판정
    final int totalErrors =
        failedRequests + timeoutRequests + serverErrors + rateLimitErrors + clientErrors;

    if (allValidPosts.isEmpty) {
      // 에러가 전혀 없었으면 → 순수하게 검색 결과 0개 (범위 문제)
      if (totalErrors == 0) {
        throw Exception("__NO_RESULTS__"); // 호출 측에서 "범위를 넓혀 다시 검색" 안내
      }
      // 에러가 있었으면 → 종류별 구체적 메시지
      List<String> errorParts = [];
      if (rateLimitErrors > 0) {
        errorParts.add("⏱ 요청 과다 (429): $rateLimitErrors건 — 잠시 후 다시 시도해주세요");
      }
      if (timeoutRequests > 0) {
        errorParts.add("⏱ 시간 초과: $timeoutRequests건 — 서버 응답이 느립니다");
      }
      if (serverErrors > 0) {
        errorParts.add("🔧 서버 오류: $serverErrors건 — 서버가 불안정합니다");
      }
      if (clientErrors > 0) {
        errorParts.add("⚠️ 요청 오류: $clientErrors건 — 태그/API 키 확인 필요");
      }
      if (failedRequests > 0) {
        errorParts.add("📡 연결 실패: $failedRequests건 — 네트워크를 확인해주세요");
      }
      errorParts.add("(총 $totalRequests건 요청 중)");
      throw Exception(errorParts.join('\n'));
    }

    if (allValidPosts.isEmpty) {
      return [];
    }

    // 로컬 제외 필터링: 포스트의 태그에 제외 태그가 하나라도 포함되면 제거
    // (이 단계에서 유효 포스트 수가 줄어들 수 있음 — 실시간 카운트는 필터 전 값이므로)
    if (localExcludeSet.isNotEmpty) {
      onStage?.call("정보 받는 중");
      //  '-loli' 같은 찌꺼기 태그(searchSyntaxJunkTarget)는 가리키던 태그(loli)로 보고 같이 비교한다.
      //  제외하려던 태그를 두고 다툼이 있었던 그림이라 조심스럽게 같이 뺀다 (빠지는 건 몇 장뿐).
      //  겔부루가 기호를 HTML 문자로 보내 오는 태그(jack-o&#039;-lantern)는 원래 글자로 되돌려 비교한다
      //  — 예전엔 제외 칸에 jack-o'-lantern 이라고 적어도 걸러지지 않았다.
      allValidPosts.removeWhere(
        (post) => post.tags.any((t) {
          final lower = unescapeGelbooruHtml(t.toLowerCase());
          return localExcludeSet.contains(lower) ||
              localExcludeSet.contains(searchSyntaxJunkTarget(lower));
        }),
      );
      debugPrint("🔍 로컬 제외 후: ${allValidPosts.length}개 포스트");
    }

    if (allValidPosts.isEmpty) {
      return [];
    }

    // 분류를 물어볼 태그 — 제외로 빠진 포스트의 태그는 물어볼 필요가 없다
    //  (예전엔 받자마자 모아서, 제외된 포스트의 태그까지 서버에 물어봤다)
    final Set<String> allUniqueTags = {for (final post in allValidPosts) ...post.tags};

    // 포함 칸에 적은 태그 (밑줄 모양 · 소문자) — 받은 그림에 있으면 '검색한 태그' 로 표시한다.
    //  아래 메타 · 잡동사니 목록에 든 것(monochrome · multiple views …)이라도 분류를 물어, '일반' 이면 남긴다.
    final Set<String> searched = plan.searchedTags;
    bool isSearched(String t) => searched.contains(unescapeGelbooruHtml(t.toLowerCase()));

    // 이름 사전(에셋) 로드 — 최초 1회만 실제 로드되고 이후엔 즉시 반환
    await TagFilters.ensureNamesLoaded();

    // 로컬 사전 필터링: 카테고리를 물을 필요가 없는 태그는 API에 보내기 전에 뺀다
    // → API 청크 수 감소 → 네트워크 호출 절감
    //  ⚠️ 이름 사전(isNameTag)에 든 태그를 통째로 빼면 안 된다. 캐릭터 이름도 거의 다 사전에
    //     들어 있어서(hatsune_miku, kisaki_(blue_archive) …) 카테고리 4 를 받을 기회가 없고,
    //     아래 '캐릭터 통과증'이 한 번도 열리지 않았다 → 캐릭터 제거 스위치를 꺼도 이름이 사라졌다.
    //     그래서 작가·작품으로 '확실한' 이름만 빼고, 캐릭터일 수 있는 이름은 물어본다.
    //     (한 번 물어본 태그는 기기에 저장돼 다음부터는 묻지 않는다)
    final filteredUniqueTags = allUniqueTags.where((t) {
      final spaced = t.replaceAll('_', ' ');
      // 찌꺼기 태그(-loli 등)는 아래에서 어차피 버린다 — 물어볼 필요도 없다
      if (searchSyntaxJunkTarget(t) != null) {
        return false;
      }
      // 검색한 태그는 목록에 있어도 묻는다 — 일반(0)이면 남기고, 메타(highres 등)면 뺀다 (아래 '로컬 목록 필터')
      if (isSearched(t)) {
        return true;
      }
      return !TagFilters.metadataTags.contains(spaced) &&
          !TagFilters.copyrightTags.contains(spaced) &&
          !_isKnownNonCharacterName(unescapeGelbooruHtml(t)) &&
          !TagFilters.commonGarbage.contains(t) &&
          !TagFilters.commonGarbage.contains(spaced);
    }).toList();

    // 태그 분류 (작가/캐릭터/작품 판별) — 페이지 수신 후 가장 오래 걸리는 구간.
    // 새 태그가 많으면 Danbooru/Gelbooru에 나눠 물어보느라 여기서 한참 멈춘 것처럼 보인다.
    onStage?.call("태그 확인 중");
    Map<String, int> tagCategories = await _getDanbooruTagCategories(
      filteredUniqueTags,
      effectiveUserId,
      effectiveApiKey,
      client: client,
      hasOwnKey: hasCredentials,
      onStage: onStage,
    );
    onStage?.call("정리하는 중");
    List<String> newPrompts = [];

    int processed = 0;
    for (final post in allValidPosts) {
      // 수천 개를 한 번에 돌면 그동안 화면이 멈춘다 → 200개마다 한 번 쉬어 화면이 그려질 틈을 준다
      if (++processed % 200 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final List<String> rawTags = post.tags;
      List<String> finalTags = [];
      // 캐릭터로 확인된 태그 — 저장할 때 따로 표시해 두고, 지울지는 적용 단계에서 정한다
      List<String> charTags = [];
      // 검색한 태그 — 저장할 때 따로 표시해 두고, 적용 단계의 자동 정리 스위치가 지우지 않는다 (prompt_search.dart)
      final Set<String> keptTags = {};

      // ⚠️ 개수로 끊지 않는다 — 걸러지지 않은 태그는 전부 담는다.
      //    예전엔 받은 순서대로 40개째에서 멈췄는데, 겔부루는 태그를 abc 순으로 보내서 태그가 많은 그림이면
      //    뒤쪽 글자로 시작하는 태그(solo · smile · upper body · very long hair …)가 늘 빠졌다 (2026-10).
      //    길어진 프롬프트는 프롬프트탭의 토큰 게이지로 보인다.
      for (String t in rawTags.toSet()) {
        if (t.isEmpty) {
          continue;
        }
        // 검색 문법 찌꺼기 (-loli, ~smile 등) — 태그가 아니다. 분류를 몰라(또는 '일반'으로 와서)
        //  예전엔 그대로 통과해 프롬프트에 '-loli' 가 들어갔다. 캐릭터 통과증보다 먼저 버린다.
        if (searchSyntaxJunkTarget(t) != null) {
          continue;
        }

        String rawCleanTag = t.replaceAll('_', ' ');
        // 이름 사전들은 원래 글자로 적혀 있다 — 겔부루의 HTML 문자(&#039; 등)를 되돌려 찾는다
        final String named = unescapeGelbooruHtml(t);

        // ★ 캐릭터 통과증: 카테고리 4(캐릭터)로 확인된 태그는 아래 이름 검사들을 건너뛴다.
        //   · 항상 살려서 저장한다 — 지울지는 적용 단계(_processAndSetPrompt)에서
        //     '캐릭터 제거' 스위치로 정하므로, 스위치를 바꿔도 다시 검색할 필요가 없다.
        //   · 괄호는 그대로 둔다 — NovelAI 는 'hu tao (genshin impact)' 처럼 괄호를 그대로 쓴다.
        //     (아래 일반 태그의 \( 는 A1111 문법이라 캐릭터에는 쓰지 않는다)
        //   · 조회에 실패해 카테고리를 모르면(429·오프라인) 캐릭터 사전으로 알아본다
        //     (_looksLikeCharacter). 사전에도 없으면 예전처럼 아래 이름 검사에서 걸러진다.
        final int? category = tagCategories[t];
        final bool searchedTag = isSearched(t);
        if (category == 4 || (category == null && _looksLikeCharacter(named))) {
          finalTags.add(rawCleanTag);
          charTags.add(rawCleanTag);
          if (searchedTag) {
            keptTags.add(rawCleanTag);
          }
          continue;
        }

        // 로컬 목록 필터 (메타 · 작품 · 잡동사니 · 이름) — 분류 조회가 실패해도 이름 · 메타가 새지 않게.
        //  ⚠️ 검색한 태그는 분류가 '일반'으로 확인됐으면 건너뛴다 — 예전엔 monochrome · multiple views 처럼
        //     잡동사니 목록에 든 일반 태그를 찾으면, 찾은 태그가 결과에서 빠졌다. (highres 같은 메타는 분류가 5라 아래에서 빠진다)
        if (!(searchedTag && category == 0)) {
          if (TagFilters.metadataTags.contains(rawCleanTag)) {
            continue;
          }
          if (TagFilters.copyrightTags.contains(rawCleanTag)) {
            continue;
          }
          if (TagFilters.commonGarbage.contains(t) || TagFilters.commonGarbage.contains(rawCleanTag)) {
            continue;
          }
          // 이름 판정 통합: 정적 사전 + 에셋 사전 + 패턴 안전장치
          // (429·오프라인으로 카테고리 조회가 실패해도 이름 누출 방지)
          if (TagFilters.isNameTag(named)) {
            continue;
          }
        }

        // Danbooru API 카테고리 필터: artist(1), copyright(3), character(4), metadata(5), 겔부루 폐기(6)
        if (category != null && category != 0) {
          continue;
        }

        // 괄호 든 태그 (shrug (clothing) 등)
        //  · 카테고리로 '일반'이 확인됐으면 괄호째 살린다 — NovelAI 표기 그대로.
        //  · 조회 실패로 모르면 버린다 — 괄호 꼬리표는 이름(작품·캐릭터·작가)인 경우가 많아,
        //    예전의 '괄호면 버림' 안전장치를 확인이 안 된 태그에만 남겨 둔다.
        //  ⚠️ 예전엔 \( 로 바꿔 저장했는데(A1111 문법), 적용 단계가 괄호 든 태그를
        //     전부 버려서 일반 태그까지 사라졌다. 이제 \( 는 '예전 목록' 표시로만 쓰인다.
        if (category == null && (t.contains('(') || t.contains(')'))) {
          continue;
        }

        // 특징·의상 제거는 여기서 하지 않는다 — 적용 단계(_processAndSetPrompt)가
        //  스위치를 보고 거른다. 그래야 스위치를 바꿔도 다시 검색할 필요가 없다.
        finalTags.add(rawCleanTag);
        if (searchedTag) {
          keptTags.add(rawCleanTag);
        }
      }

      if (finalTags.isNotEmpty) {
        // 프롬프트 순서 최적화: 인원수 → solo → 시점 → 시선 → 나머지(셔플) → 배경(맨 뒤)
        final prioritized = _reorderTagsByPriority(finalTags, chars: charTags.toSet());
        String jsonCapsule = jsonEncode({
          "tags": prioritized.join(', '),
          "width": post.width,
          "height": post.height,
          "rating": _normalizeRating(post.rating),
          // 어느 태그가 캐릭터인지 — 없으면 빼서 옛 모양과 같게 둔다
          if (charTags.isNotEmpty) "chars": charTags,
          // 어느 태그가 검색한 태그인지 — 적용 단계의 자동 정리 스위치가 지우지 않는다. 없으면 뺀다.
          if (keptTags.isNotEmpty) "kept": [for (final k in keptTags) k.toLowerCase()],
        });
        newPrompts.add(jsonCapsule);
      }
    }

    newPrompts.shuffle();
    return newPrompts;
  }

  // ============================================================================
  // 이미지 생성/인페인트 API 호출 (지수 백오프 적용 완료)
  // ============================================================================
  // V4 모델용 Vibe 이미지 인코딩 (encode-vibe 엔드포인트)
  /// Vibe 한 장 인코딩 (V4 이상 · 2 Anlas). 실패하면 encoded 가 null 이고 error 에 이유.
  Future<({String? encoded, String? error})> _encodeVibe(
    String base64Image,
    double infoExtracted,
    String model,
    String token,
  ) async {
    try {
      // ⚠️ 시간 제한이 없으면 연결이 멈췄을 때 생성이 끝나지 않는다 (로딩이 영원히 돈다).
      //    실패하면 부른 쪽이 생성하지 않고 오류로 끝낸다 (generateImage 의 Vibe 부분).
      final response = await http
          .post(
            Uri.parse(encodeVibeUrl),
            headers: {
              "Authorization": "Bearer $token",
              "Content-Type": "application/json; charset=utf-8",
            },
            body: jsonEncode({
              "image": base64Image,
              "information_extracted": infoExtracted,
              "model": model,
            }),
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) {
        // 응답은 바이너리, base64로 인코딩
        return (encoded: base64Encode(response.bodyBytes), error: null);
      }
      debugPrint("encode-vibe 실패: ${response.statusCode} ${response.body}");
      String msg = response.body;
      try {
        msg = jsonDecode(_utf8Body(response))['message']?.toString() ?? response.body;
      } catch (_) {
        // JSON 이 아니면 본문 그대로
      }
      return (encoded: null, error: "[${response.statusCode}] $msg");
    } catch (e) {
      debugPrint("encode-vibe 오류: $e");
      return (encoded: null, error: e is TimeoutException ? "시간 초과" : "연결 실패");
    }
  }

  Future<NaiResponse> generateImage({
    required String positive,
    required String negative,
    required String token,
    required String model,
    required int steps,
    required String sampler,
    required String scheduler,
    required int width,
    required int height,
    required double cfgScale,
    required double cfgRescale,
    required int seed,
    required List<Map<String, dynamic>> characters,
    Uint8List? image,
    Uint8List? mask,
    String action = "generate",
    // [image] 가 NovelAI 가 만든 그림(그림 정보가 있는 PNG)인지 — 인페인트에서 그대로 보내도 되는지 가른다
    bool imageFromNovelAi = false,
    // i2i: [image] 를 둘 크기 (0 이면 width·height 그대로). width·height 보다 작으면
    //  모자란 오른쪽·아래를 채워 보내고, 결과에서 그만큼 잘라내 이 크기로 돌려준다.
    int contentWidth = 0,
    int contentHeight = 0,
    double infillStrength = 0.7,
    double img2imgStrength = 0.5, // img2img: 원본을 얼마나 바꿀지 (낮을수록 원본 충실)
    double img2imgNoise = 0.1, // img2img: 새 디테일 추가량
    bool variancePlus = false,
    bool transparentBackground = false,
    bool useCharacterPosition = true,
    bool randomCharacterOrder = false, // 캐릭터 순서 랜덤 (배치 적용과 상호 배타)
    List<Map<String, dynamic>>? vibeTransfers,
    List<Map<String, dynamic>>? preciseRefs,
    int maxAttempts = 4,
    void Function(String)? onStatus,
    // 생성 과정 미리보기 — 주면 스트리밍으로 요청해 중간 단계(JPEG)를 [step]/[steps] 와 함께 넘긴다.
    //  V4 이상의 그냥 생성(action "generate")만 — i2i · 인페인트 · V3 는 주어도 보통 요청으로 간다.
    void Function(Uint8List image, int step, int steps)? onPreview,
    // 미리보기를 걷으라는 신호 — 스트리밍 시도가 실패해 다시 하거나 보통 요청으로 바꿀 때.
    //  (안 걷으면 재시도를 기다리는 동안 지난 시도의 중간 그림이 남아 '아직 그리는 중' 처럼 보였다)
    VoidCallback? onPreviewReset,
    // V5 Full 의 Medium effort — 모델 이름을 바꿔 보내고, 공식이 잠그는 값(스텝 14 · Euler Ancestral ·
    //  CFG Rescale 0 · 캐릭터 부정 비움)으로 보낸다. 부정 프롬프트(고정 UC)는 부른 쪽이 만들어 넘긴다.
    //  V5 Full 이 아닌 모델이면 무시한다.
    bool mediumEffort = false,
    // 한 번에 만들 장수 (n_samples — 생성 버튼 꾹). 그냥 생성(action "generate")에서만 1 보다 크게 보낸다.
    //  2장 이상이면 스트리밍(미리보기)을 쓰지 않는다 — 장마다 중간 그림이 섞여 와 한 칸에 보여 줄 수 없다.
    //  받은 그림은 첫 장이 image, 나머지가 more.
    int samples = 1,
  }) async {
    try {
      String finalPrompt = positive;
      final int nSamples = action == "generate" ? samples.clamp(1, 4) : 1;

      // 모델 능력(capability) 조회 — 기능 지원 여부/서버 전송용 문자열의 단일 출처
      final caps = modelCapsFor(model);

      // 서버로 실제 전송할 모델 문자열 (테스트 모델은 여기서 실제 v4.5 등으로 매핑됨)
      // infill 액션 시 모델명에 -inpainting 접미사 추가 (nai-diffusion-2 예외)
      // 예: nai-diffusion-4-5-full → nai-diffusion-4-5-full-inpainting
      final bool medium = mediumEffort && caps.serverModelId == NaiModels.v5Full;
      String apiModel = medium ? NaiModels.v5FullMedium : caps.serverModelId;
      if (action == "infill" && caps.serverModelId != NaiModels.v2) {
        apiModel = "$apiModel-inpainting";
      }

      // 모델별 상한을 넘지 않게 정리한다 (V5는 CFG 10, 스텝 50이 상한)
      final safeCfg = cfgScale.clamp(0.0, caps.maxCfgScale);
      final safeSteps = medium ? kMediumEffortSteps : steps.clamp(1, caps.maxSteps);

      Map<String, dynamic> parameters = {
        "width": width,
        "height": height,
        "scale": safeCfg,
        "sampler": medium ? kMediumEffortSampler : sampler,
        "steps": safeSteps,
        "seed": seed,
        "n_samples": nSamples,
      };

      // generate/infill 공통 파라미터
      parameters.addAll({
        "dynamic_thresholding": false,
        "controlnet_strength": 1,
        "legacy": false,
        "cfg_rescale": medium ? 0.0 : cfgRescale, // Medium 은 Rescale 을 지원하지 않는다
        "negative_prompt": negative,
        "extra_noise_seed": seed,
      });

      if (action == "infill") {
        // [최종 수정] PC 프로그램 api_service.py 326~373번 줄과 1:1 일치
        // infill 전용 (326~339번 줄)
        parameters.addAll({
          "add_original_image": true,
          "inpaintImg2ImgStrength": infillStrength,
          "noise": 0,
          "deliberate_euler_ancestral_bug": false,
          "controlnet_strength": 1,
          "request_type": "NativeInfillingRequest",
        });
        // 강도가 1 보다 낮으면 공식처럼 img2img 묶음(강도 · 색 보정)을 같이 보낸다 — 공식 웹은 '인페인트 강도'를
        //  inpaintImg2ImgStrength 와 이 묶음 둘로 보낸다 (1 이면 묶음 없이 — 칠한 곳을 처음부터 새로 그린다).
        //  ⚠️ 예전엔 묶음 없이 inpaintImg2ImgStrength 만 보냈다. 기본값도 0.7 이라(공식 기본값은 1) 칠한 곳에 원래 모양이
        //     남아, 물건을 지우려 해도 비슷한 물건이 자꾸 다시 그려졌다.
        if (infillStrength < 1.0) {
          parameters["img2img"] = {"strength": infillStrength, "color_correct": true};
        }
        // V4 특화 설정 (345~373번 줄)
        parameters.addAll({
          "params_version": 3,
          "legacy": false,
          "legacy_uc": false,
          "autoSmea": true,
          "prefer_brownian": true,
          "ucPreset": 0,
          "use_coords": false,
        });
      } else {
        // generate / img2img 공통 파라미터
        parameters.addAll({
          "add_original_image": true,
          "qualityToggle": true,
          "ucPreset": 3,
          "sm": false,
          "sm_dyn": false,
          "uncond_scale": 1,
          "params_version": 3,
          // [수정] VAR+ ON: 58, OFF: null (기존 59.04... 하드코딩 제거)
          "skip_cfg_above_sigma": variancePlus ? 58 : null,
        });

        // img2img 전용: 원본 변형 강도(strength)와 노이즈(noise)
        // strength 낮음(0.2~0.4)=원본 충실 / 높음(0.6~0.8)=창의적 재해석
        if (action == "img2img") {
          parameters.addAll({"strength": img2imgStrength, "noise": img2imgNoise});
        }
      }

      if (variancePlus) {
        parameters["variety_plus"] = true;
      }

      // 투명 배경 (V5 전용). 알파 채널을 그대로 받는다.
      //  프롬프트에 "transparent background" 같은 태그도 함께 쓰면 더 잘 먹는다.
      if (transparentBackground && caps.supportsTransparency) {
        parameters["straight_alpha"] = true;
      }

      // 노이즈 스케줄 — 고른 값을 그대로 보낸다 ('native' 면 보내지 않아 서버 기본값을 쓴다)
      if (scheduler != "native") {
        parameters["noise_schedule"] = scheduler;
      }

      // i2i 에서 그림을 둘 크기 — 보낼 크기(width·height)보다 크거나 없으면 보낼 크기 그대로
      final int fitW = (contentWidth > 0 && contentWidth <= width) ? contentWidth : width;
      final int fitH = (contentHeight > 0 && contentHeight <= height) ? contentHeight : height;

      // 이미지/마스크 인코딩
      if (image != null) {
        // infill: NovelAI 가 만든 PNG 가 요청 크기와 딱 맞으면 재인코딩 없이 그대로 보낸다
        //  (재인코딩하면 NovelAI PNG 메타데이터/픽셀 구조가 변형되어 서버 오류 가능).
        //  그 밖의 그림 — 밖에서 가져온 그림·Director 결과(투명 4채널일 수 있다)·크기가 다른 그림·썸네일 —
        //  은 요청 크기의 3채널 PNG 로 맞춘다.
        //  ⚠️ 예전엔 infill 이면 무조건 그대로 보냈다 (그림 정보 없는 그림은 앱이 아예 막고 있었다).
        if (action == "infill" &&
            imageFromNovelAi &&
            fitW == width &&
            fitH == height &&
            isPng(image) &&
            imageSizeFromHeader(image) == (width, height)) {
          parameters["image"] = base64Encode(image);
        } else {
          // 3채널 RGB 변환 + 둘 크기로 맞추고 보낼 크기까지 채움
          parameters["image"] = await compute(
            _processImage3Channel,
            (image, fitW, fitH, width, height),
          );
        }

        if (action == "infill" && mask != null) {
          parameters["mask"] = await compute(_processMaskForInfill, mask);
        }
      }

      // v4_prompt / v4_negative_prompt: generate, infill 모두 필요
      // (infill 모델도 V4 아키텍처이므로 이 필드가 없으면 서버가 타임아웃)
      List<Map<String, dynamic>> posCharCaptions = [];
      List<Map<String, dynamic>> negCharCaptions = [];

      // 캐릭터 좌표는 generate 전용
      if (action != "infill") {
        // [랜덤 배치] ON이면 캐릭터 순서를 시드 기반으로 섞는다.
        // V4는 use_order:true로 캡션 순서를 구도에 반영하므로(먼저 적힌 캐릭터가 왼쪽 경향),
        // 순서를 섞으면 구도가 매번 달라진다. 시드 기반이라 같은 시드는 같은 구도로 재현.
        // [배치 적용]/[랜덤 배치] 둘 다 OFF면 캐릭터 적용 순서 그대로 (원래 동작).
        List<dynamic> orderedCharacters = List.of(characters);
        if (randomCharacterOrder && orderedCharacters.length > 1) {
          orderedCharacters.shuffle(Random(seed));
        }

        for (var char in orderedCharacters) {
          // 자유 좌표(posX/posY)가 있으면 그대로 쓰고, 없으면 5x5 그리드에서 환산한다.
          //  V5는 캔버스 어디든 찍을 수 있어 그리드로는 표현되지 않는다.
          double cx = (char['posX'] as num?)?.toDouble() ?? ((char['gridX'] * 0.2) + 0.1);
          double cy = (char['posY'] as num?)?.toDouble() ?? ((char['gridY'] * 0.2) + 0.1);
          var center = {"x": cx, "y": cy};

          // 긍정 · 부정 칸은 캐릭터마다 '짝으로' 넣는다 — 부정이 비어도 빈 글자로 한 칸 (공식 웹과 같다).
          //  ⚠️ 예전엔 부정이 빈 캐릭터를 부정 목록에서 뺐다. 그러면 그림 정보에서 부정 칸 수가 캐릭터 수와
          //     달라져, 번호대로 읽으면 남의 캐릭터에 붙었다 (image_metadata.dart _pairCharNegatives 참고).
          //  긍정이 빈 캐릭터는 둘 다 넣지 않는다 (예전엔 부정만 들어가 짝이 어긋났다).
          if ((char['positive'] as String).isEmpty) {
            continue;
          }
          posCharCaptions.add({
            "char_caption": char['positive'],
            "centers": [center],
          });
          negCharCaptions.add({
            // Medium 은 부정 프롬프트가 고정이라 캐릭터 부정은 비워 보낸다 (칸 수는 그대로 짝으로)
            "char_caption": medium ? '' : ((char['negative'] as String?) ?? ''),
            "centers": [center],
          });
        }
      }

      // V4 이전 아키텍처(V3 등)는 v4_prompt를 이해하지 못한다.
      //  캡션 구조 없이 input/uc만 보내야 하므로 이 블록을 건너뛴다.
      if (caps.usesV4Prompt) {
        parameters["v4_prompt"] = {
          "caption": {"base_caption": finalPrompt, "char_captions": posCharCaptions},
          // [배치 적용] ON이면 좌표 사용 — 전원 기본 위치(중앙)여도 그대로 중앙 배치(겹침 허용).
          // 공식 스펙 정합: 포지션 기능은 캐릭터 2명 이상일 때만 활성 (1명은 공식도 비활성),
          // 같은 셀 겹침은 공식도 그대로 전송(좌표는 강제가 아닌 '넛지', 랜덤 재배치 없음).
          "use_coords": action == "infill"
              ? false
              : (useCharacterPosition && posCharCaptions.length >= 2),
          "use_order": true,
        };
        parameters["v4_negative_prompt"] = {
          "caption": {"base_caption": negative, "char_captions": negCharCaptions},
          "legacy_uc": false,
        };
      }
      // PC 프로그램과 동일: uc에도 네거티브 프롬프트를 넣어야 메타데이터에 표시됨
      //  (v4_prompt를 쓰지 않는 모델에서도 부정 프롬프트는 uc로 전달된다)
      parameters["uc"] = negative;

      // Vibe Transfer
      if (vibeTransfers != null && vibeTransfers.isNotEmpty) {
        if (caps.usesEncodeVibe) {
          // V4 이상: encode-vibe로 인코딩 필요 (캐시 활용)
          List<String> encodedVibes = [];
          List<double> vibeStrengths = [];
          for (final v in vibeTransfers) {
            final infoExt = (v['infoExtracted'] as double?) ?? 1.0;
            // 캐시 확인: 같은 정보추출 값으로 이미 인코딩됐으면 재사용 (Anlas 절약)
            final cachedEnc = v['_encoded'] as String?;
            final cachedInfoExt = v['_encodedInfoExt'] as double?;
            final cachedModel = v['_encodedModel'] as String?;

            final String encoded;
            if (cachedEnc != null && cachedInfoExt == infoExt && cachedModel == apiModel) {
              encoded = cachedEnc; // 캐시 재사용 (무료)
            } else {
              final enc = await _encodeVibe(v['image'] as String, infoExt, apiModel, token);
              final String? fresh = enc.encoded;
              if (fresh == null) {
                // 하나라도 못 하면 생성하지 않는다 — 그 Vibe 만 빠진 그림이 나오고 Anlas 는 그대로 나갔다
                //  (Anlas 가 모자라 인코딩(2 Anlas)만 실패하면, 연속 생성 내내 Vibe 없는 그림이 나왔다).
                //  앞서 인코딩된 것은 캐시에 남아 다음엔 다시 내지 않는다.
                return NaiResponse(
                  error: "Vibe 인코딩에 실패해서 생성하지 않았어요.\n${enc.error ?? ''}",
                  fatal: true,
                );
              }
              encoded = fresh;
              // 캐시 저장
              v['_encoded'] = encoded;
              v['_encodedInfoExt'] = infoExt;
              v['_encodedModel'] = apiModel;
            }
            encodedVibes.add(encoded);
            vibeStrengths.add((v['strength'] as double?) ?? 0.6);
          }
          if (encodedVibes.isNotEmpty) {
            parameters["reference_image_multiple"] = encodedVibes;
            parameters["reference_strength_multiple"] = vibeStrengths;
            parameters["normalize_reference_strength_multiple"] = true;
          }
        } else {
          // V3: raw 이미지 직접 전송
          parameters["reference_image_multiple"] = vibeTransfers
              .map((v) => v['image'] as String)
              .toList();
          parameters["reference_information_extracted_multiple"] = vibeTransfers
              .map((v) => (v['infoExtracted'] as double?) ?? 1.0)
              .toList();
          parameters["reference_strength_multiple"] = vibeTransfers
              .map((v) => (v['strength'] as double?) ?? 0.6)
              .toList();
          parameters["normalize_reference_strength_multiple"] = true;
        }
      }

      // Precise Reference (V4.5 전용, Vibe Transfer와 동시 사용 불가)
      if (preciseRefs != null && preciseRefs.isNotEmpty && caps.supportsPrecise) {
        parameters["params_version"] = 3;
        parameters["director_reference_images"] = preciseRefs
            .map((r) => r['image'] as String)
            .toList();
        parameters["director_reference_descriptions"] = preciseRefs
            .map(
              (r) => {
                "caption": {
                  "base_caption": (r['type'] as String?) ?? "character",
                  "char_captions": [],
                },
                "legacy_uc": false,
              },
            )
            .toList();
        parameters["director_reference_strength_values"] = preciseRefs
            .map((r) => (r['strength'] as double?) ?? 1.0)
            .toList();
        // Fidelity는 1에서 빼서 secondary_strength로 전송
        parameters["director_reference_secondary_strength_values"] = preciseRefs
            .map((r) => 1.0 - ((r['fidelity'] as double?) ?? 0.5))
            .toList();
        parameters["director_reference_information_extracted"] = preciseRefs
            .map((r) => 1.0)
            .toList();
      }

      // 스트리밍으로 받을지 — 미리보기를 원하고, V4 이상의 그냥 생성일 때만 (서버가 그때만 중간 단계를 보낸다)
      bool streaming =
          onPreview != null &&
          !_streamUnavailable &&
          action == "generate" &&
          caps.usesV4Prompt &&
          nSamples == 1;
      if (streaming) {
        parameters["stream"] = "msgpack";
      }

      final Map<String, dynamic> requestBody = {
        // T5 토크나이저 파싱 크래시 방지를 위해 소문자화
        "input": finalPrompt,
        "model": apiModel,
        "action": action,
        "parameters": parameters,
      };

      int currentAttempt = 0;
      final Random random = Random();
      // infill은 서버 처리 시간이 길어 재시도 횟수를 더 많이 줌
      final int effectiveMaxAttempts = (action == "infill") ? 6 : maxAttempts;
      bool lastWasConcurrent = false;

      onStatus?.call("서버에 요청 전송 중...");

      while (currentAttempt < effectiveMaxAttempts) {
        try {
          final http.Response response;
          if (streaming) {
            final streamed = await _postStream(requestBody, token, safeSteps, onPreview!);
            final Uint8List? finalImage = streamed.image;
            if (finalImage != null) {
              onStatus?.call("이미지 수신 완료!");
              return NaiResponse(image: finalImage);
            }
            final http.Response? failure = streamed.failure;
            // 스트리밍만의 문제일 수 있으면 바로 보통 요청으로 다시 (시도 횟수는 쓰지 않는다 — 한 번만 일어난다)
            //  · 404: 스트리밍 주소가 없어졌다 (_postStream 이 이번 실행 동안 끈다)
            //  · 400: 그 모델이 스트리밍을 안 받을 수 있다 — 프롬프트 탓이면 보통 요청도 400 이라 그 오류가 그대로 뜬다 (400 은 Anlas 를 쓰지 않는다)
            //  · 응답은 왔는데 읽을 수 있는 마지막 그림이 없었다 (형식이 바뀌었다 — 이것도 이번 실행 동안 끈다)
            if (failure == null || failure.statusCode == 404 || failure.statusCode == 400) {
              streaming = false;
              parameters.remove("stream");
              onPreviewReset?.call(); // 보통 요청은 중간 그림이 없다 — 지난 그림이 끝까지 남지 않게
              continue;
            }
            // 실패 응답(상태 코드 + 본문) — 아래에서 보통 요청과 똑같이 다룬다 (429 대기 · 재시도 · 오류 문구)
            response = failure;
          } else {
            response = await http
                .post(
                  Uri.parse(apiUrl),
                  headers: {
                    "Authorization": "Bearer $token",
                    "Content-Type": "application/json; charset=utf-8",
                    "Accept": "application/zip",
                  },
                  body: jsonEncode(requestBody),
                )
                .timeout(const Duration(seconds: 60));
          }

          if (response.statusCode == 201 || response.statusCode == 200) {
            onStatus?.call("이미지 수신 완료!");
            // 한 번에 여러 장 — ZIP 안의 그림을 전부 꺼낸다 (i2i 가 아니라 잘라낼 것이 없다)
            if (nSamples > 1) {
              final all = await compute(_unzipAllEntries, response.bodyBytes);
              if (all.isEmpty) {
                throw Exception('서버가 빈 아카이브를 반환했습니다.');
              }
              return NaiResponse(image: all.first, more: all.sublist(1));
            }
            // ZIP 해제는 수 MB 작업이라 isolate에서 (메인 스레드 잰크 방지)
            final imageBytes = await compute(_unzipFirstEntry, response.bodyBytes);
            if (imageBytes != null) {
              // i2i 에서 채워 보냈으면 채운 만큼 잘라 원래 그림 크기로 되돌린다
              if (image != null && (fitW < width || fitH < height)) {
                onStatus?.call("원래 크기로 맞추는 중...");
                return NaiResponse(
                  image: await compute(_cropResultToContent, (imageBytes, fitW, fitH)),
                );
              }
              return NaiResponse(image: imageBytes);
            }
            throw Exception('서버가 빈 아카이브를 반환했습니다.');
          } else if (response.statusCode == 429) {
            String errorMessage = '';
            try {
              final errorBody = jsonDecode(_utf8Body(response));
              errorMessage = errorBody['message']?.toString().toLowerCase() ?? '';
            } catch (_) {
              errorMessage = _utf8Body(response).toLowerCase();
            }

            if (errorMessage.contains('concurrent')) {
              lastWasConcurrent = true;
              onStatus?.call("서버 처리 중... 잠금 해제 대기 (${currentAttempt + 1}/$effectiveMaxAttempts)");
              debugPrint(
                '[동시성 제어] 서버 측 연산 잠금 상태. 재시도 폴링 진입. (시도: ${currentAttempt + 1}/$effectiveMaxAttempts)',
              );
            } else {
              return NaiResponse(error: "API 한도 초과: $errorMessage", fatal: true);
            }
          } else if (response.statusCode >= 500) {
            // 500 응답 body를 안전하게 파싱해서 디버그 출력
            String serverMsg = '';
            try {
              serverMsg = jsonDecode(_utf8Body(response))['message']?.toString() ?? response.body;
            } catch (_) {
              serverMsg = response.body;
            }
            debugPrint('[서버 에러] ${response.statusCode}: $serverMsg — 재시도 수행.');
            onStatus?.call("서버 오류 (${response.statusCode}) — 재시도 중...");
          } else {
            String errorMsg = response.body;
            try {
              errorMsg = jsonDecode(_utf8Body(response))['message']?.toString() ?? response.body;
            } catch (_) {
              // 오류 응답이 JSON 이 아닌 경우(HTML 안내 페이지 등).
              // 위에서 넣어 둔 원문(response.body)을 그대로 쓴다.
            }
            final code = response.statusCode;
            String friendly;
            if (code == 400) {
              friendly = "잘못된 요청 (400)\n프롬프트나 설정에 문제가 있을 수 있어요.\n$errorMsg";
            } else if (code == 401) {
              friendly = "인증 실패 (401)\nAPI 키가 올바른지 설정 탭에서 확인해주세요.\n$errorMsg";
            } else if (code == 402) {
              friendly = "결제/구독 필요 (402)\nAnlas(크레딧)나 구독 상태를 확인해주세요.\n$errorMsg";
            } else if (code == 403) {
              friendly = "접근 거부 (403)\nAPI 키 권한을 확인해주세요.\n$errorMsg";
            } else {
              friendly = "요청 실패 [$code]\n$errorMsg";
            }
            return NaiResponse(error: friendly, fatal: true); // 4xx — 다시 보내도 같다
          }
        } catch (e) {
          lastWasConcurrent = false;
          if (currentAttempt >= effectiveMaxAttempts - 1) {
            if (e is TimeoutException) {
              return NaiResponse(error: "⏱ 생성 시간 초과 (60초)\n서버가 너무 느리거나 혼잡합니다. 잠시 후 다시 시도해주세요.");
            }
            return NaiResponse(error: "📡 연결 실패\n네트워크를 확인하거나 잠시 후 다시 시도해주세요.\n$e");
          }
        }

        // 이번 시도는 실패했다 — 다시 하기 전에 지난 시도의 미리보기를 걷는다 (오류로 끝나도 부른 쪽이 걷는다)
        onPreviewReset?.call();
        currentAttempt++;
        if (currentAttempt < effectiveMaxAttempts) {
          final int exponentialDelay = pow(2, currentAttempt).toInt();
          // concurrent lock이면 10~30초 대기 (서버가 ghost request 마칠 시간), 일반은 최대 30초
          final int baseDelay = lastWasConcurrent
              ? exponentialDelay.clamp(10, 30)
              : exponentialDelay.clamp(2, 30);
          final int jitterMs = random.nextInt(1000);
          debugPrint('[재시도] ${baseDelay}s 후 재시도 (시도 $currentAttempt/$effectiveMaxAttempts)');
          onStatus?.call("$baseDelay초 후 재시도 ($currentAttempt/$effectiveMaxAttempts)...");
          await Future.delayed(Duration(seconds: baseDelay, milliseconds: jitterMs));
        }
      }
      return NaiResponse(error: "최종 실패. 서버의 연산 잠금 상태가 해제되지 않았습니다.");
    } catch (e) {
      return NaiResponse(error: "파이프라인 내부 오류 발생\n$e", fatal: true);
    }
  }

  /// 스트리밍 주소가 없어졌을 때(404) 이번 실행 동안은 보통 요청으로만 — 매번 실패하고 돌아오지 않게
  static bool _streamUnavailable = false;

  /// 스트리밍 생성 한 번 — 중간 단계는 [onPreview] 로 넘기고, 마지막 그림을 돌려준다.
  ///  · 200 이 아니면 본문까지 읽어 [failure] 로 돌려준다 (부른 쪽이 보통 요청과 같은 오류 처리를 탄다).
  ///  · 200 인데 마지막 그림 없이 '깨끗이' 끝나면 둘 다 null — 형식을 못 알아본 것이라 이번 실행 동안 스트리밍을 끈다
  ///    (부른 쪽이 보통 요청으로 다시 보낸다. 재시도를 거듭해도 고쳐지지 않고 Anlas 만 쓴다).
  ///  · 도중에 끊기면 예외 — 부른 쪽의 재시도가 받는다 (보통 요청이 끊긴 것과 같다).
  ///  · 마지막 그림을 받으면 바로 끝낸다 — 그 뒤에 연결 오류가 나도 받은 그림을 버리지 않게 (한 번에 한 장이다).
  ///  · 시간 제한: 응답 머리 60초, 그 뒤엔 '조각 사이' 60초 (중간 단계가 오는 동안은 끊지 않는다).
  Future<({Uint8List? image, http.Response? failure})> _postStream(
    Map<String, dynamic> body,
    String token,
    int steps,
    void Function(Uint8List image, int step, int steps) onPreview,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('POST', Uri.parse(streamUrl))
        ..headers.addAll({
          "Authorization": "Bearer $token",
          "Content-Type": "application/json; charset=utf-8",
          "Accept": "*/*",
        })
        ..body = jsonEncode(body);
      final res = await client.send(request).timeout(const Duration(seconds: 60));
      if (res.statusCode != 200 && res.statusCode != 201) {
        final bytes = await res.stream.toBytes().timeout(const Duration(seconds: 30));
        if (res.statusCode == 404) {
          _streamUnavailable = true; // 이번 실행 동안은 보통 요청으로 (부른 쪽이 이번 요청도 보통 요청으로 다시 보낸다)
        }
        return (image: null, failure: http.Response.bytes(bytes, res.statusCode, headers: res.headers));
      }
      final reader = NaiStreamReader();
      Uint8List? finalImage;
      // 다 모인 칸들 — 중간 단계는 넘기고, 마지막 그림이 오면 true
      bool take(List<NaiStreamEvent> events) {
        for (final ev in events) {
          if (ev.isFinal) {
            finalImage = ev.image;
            return true;
          }
          onPreview(ev.image, ev.step, steps);
        }
        return false;
      }

      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        if (take(reader.add(chunk))) {
          break; // 마지막 그림을 받았다 — 나머지는 기다리지 않는다
        }
      }
      if (finalImage == null) {
        take(reader.close());
      }
      final Uint8List? image = finalImage;
      if (image == null) {
        debugPrint('[스트리밍] 마지막 그림 없이 끝남 — 이번 실행 동안 보통 요청으로 바꾼다');
        _streamUnavailable = true;
      }
      return (image: image, failure: null);
    } finally {
      client.close();
    }
  }

  // ============================================================================
  // 업스케일 및 사용자 정보
  // ============================================================================
  /// V5 업스케일 (2배 고정, 1 Anlas).
  ///
  /// NovelAI 웹과 같은 multipart 요청을 보낸다.
  ///  · image   : 그림 파일 (PNG)
  ///  · request : {"image":"image", "model":…, "declared_blur_sigma":0} (JSON)
  ///  응답은 ZIP 안에 PNG 한 장이다.
  Future<NaiResponse> upscaleImage({required Uint8List image, required String token}) async {
    try {
      final cleanToken = token.trim().replaceFirst('Bearer ', '').trim();
      // 서버는 PNG 를 기대한다. WebP·JPEG 로 저장해 둔 그림을 불러온 경우 바꿔서 보낸다.
      final png = await ensurePng(image);
      if (png == null) {
        return NaiResponse(error: "업스케일할 그림을 읽을 수 없습니다.");
      }

      // multipart 본문을 직접 만든다.
      //  (http 패키지의 MultipartFile 로 content-type 을 정하려면 http_parser 를
      //   따로 의존성에 넣어야 해서, 형식이 단순한 두 부분짜리는 직접 쓰는 편이 가볍다)
      final boundary = '----DNaiApp${DateTime.now().microsecondsSinceEpoch}';
      final request = jsonEncode({
        'image': 'image', // 아래 'image' 부분을 가리킨다
        'model': upscaleModel,
        'declared_blur_sigma': 0,
      });
      final body = BytesBuilder(copy: false)
        ..add(
          utf8.encode(
            '--$boundary\r\n'
            'Content-Disposition: form-data; name="image"; filename="blob"\r\n'
            'Content-Type: image/png\r\n\r\n',
          ),
        )
        ..add(png)
        ..add(
          utf8.encode(
            '\r\n--$boundary\r\n'
            'Content-Disposition: form-data; name="request"; filename="blob"\r\n'
            'Content-Type: application/json\r\n\r\n',
          ),
        )
        ..add(utf8.encode(request))
        ..add(utf8.encode('\r\n--$boundary--\r\n'));

      final response = await http
          .post(
            Uri.parse(upscaleUrl),
            headers: {
              "Authorization": "Bearer $cleanToken",
              "Content-Type": "multipart/form-data; boundary=$boundary",
              // NovelAI 웹이 함께 보내는 머리글 (요청 추적용)
              "x-correlation-id": _correlationId(),
              "x-initiated-at": DateTime.now().toUtc().toIso8601String(),
            },
            body: body.takeBytes(),
          )
          .timeout(const Duration(seconds: 180));

      if (response.statusCode == 201 || response.statusCode == 200) {
        // 응답은 ZIP (해제는 isolate 에서). 혹시 ZIP 이 아니면 그대로 그림으로 쓴다.
        final unzipped = await compute(_unzipFirstEntry, response.bodyBytes);
        return NaiResponse(image: unzipped ?? response.bodyBytes);
      } else {
        String errorMsg = "서버 오류";
        try {
          errorMsg = jsonDecode(_utf8Body(response))['message'] ?? response.body;
        } catch (_) {
          errorMsg = response.body.isNotEmpty ? response.body : "알 수 없는 오류 발생";
        }
        return NaiResponse(error: "업스케일 에러 [${response.statusCode}]\n$errorMsg");
      }
    } catch (e) {
      return NaiResponse(error: "네트워크 오류 발생\n$e");
    }
  }

  /// 요청 추적용 짧은 무작위 값 (영문 소문자·숫자 6자)
  static String _correlationId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Director Tool 실행 (/ai/augment-image).
  ///
  /// 모든 도구가 이 하나의 엔드포인트를 쓰고 [reqType] 만 다르다.
  ///  · bg-removal 은 결과가 3장(Masked/Generated/Blend)
  ///  · 나머지는 1장
  ///
  /// ⚠️ 배경 제거는 공식 문서에서도 "상당히 느리다"고 안내한다.
  ///    그래서 생성(60초)보다 넉넉한 180초를 준다.
  Future<NaiMultiResponse> runDirectorTool({
    required Uint8List image,
    required int width,
    required int height,
    required String token,
    required String reqType,
    String prompt = '',
    int defry = 0,
  }) async {
    try {
      final cleanToken = token.trim().replaceFirst('Bearer ', '').trim();
      final response = await http
          .post(
            Uri.parse(directorUrl),
            headers: {
              "Authorization": "Bearer $cleanToken",
              "Content-Type": "application/json; charset=utf-8",
              "Accept": "application/zip",
            },
            body: jsonEncode({
              "req_type": reqType,
              "width": width,
              "height": height,
              // 헤더(data:image/png;base64,) 없이 순수 base64 만 보낸다
              "image": base64Encode(image),
              "prompt": prompt,
              "defry": defry,
            }),
          )
          .timeout(const Duration(seconds: 180));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final images = await compute(_unzipAllEntries, response.bodyBytes);
        if (images.isNotEmpty) {
          return NaiMultiResponse(images: images);
        }
        // zip 이 아니면 응답 자체가 이미지 한 장이다
        return NaiMultiResponse(images: [response.bodyBytes]);
      }

      String errorMsg = "서버 오류";
      try {
        errorMsg = jsonDecode(_utf8Body(response))['message'] ?? response.body;
      } catch (_) {
        // JSON 이 아니면 본문을 그대로 보여 준다
        errorMsg = response.body.isNotEmpty ? response.body : "알 수 없는 오류 발생";
      }
      return NaiMultiResponse(error: "Director Tool 에러 [${response.statusCode}]\n$errorMsg");
    } on TimeoutException {
      return NaiMultiResponse(error: "⏱ 처리 시간 초과 (180초)\n배경 제거는 오래 걸릴 수 있습니다. 잠시 후 다시 시도해주세요.");
    } catch (e) {
      return NaiMultiResponse(error: "네트워크 오류 발생\n$e");
    }
  }

  /// 사용자 정보 조회 (Anlas + 구독 등급 + V5 사용 한도)
  ///  응답의 usage 필드가 V5 한도다:
  ///    { percent: 107, purchasedPercent: 100, isNegative: false, timeUntilNextPercent: 0 }
  ///  · percent  — 남은 비율. 100을 넘을 수도 있다(여유분).
  ///  · purchasedPercent — 부스트(Opus Usage Boost)로 산 추가 사용량(공식 화면의 'Extra Usage').
  ///     percent 와 따로 센다 — 기본 한도를 먼저 쓰고, 다 쓰면 이걸 쓴다. 부스트 하나에 +100%, 최대 400%.
  ///     ⚠️ 예전엔 읽지 않아, 기본 한도가 0% 면 부스트가 남아 있어도 0% 로만 보였다 (2026-10).
  ///  · isNegative — 이미 다 써서 Anlas를 소모하는 중인지
  ///  (timeUntilNextPercent 는 읽지 않는다 — 조회한 순간 값이라 화면에서 줄어들지 않아 오해만 샀다)
  Future<Map<String, dynamic>?> fetchUserInfo(String token) async {
    try {
      final cleanToken = token.trim().replaceFirst('Bearer ', '').trim();
      // NAI 서버 마이그레이션(2026): /user/* 는 image.novelai.net에서 호출해야 함.
      // 기존 api.novelai.net/user/subscription 은 현재 작동하지 않음.
      final url = Uri.parse('https://image.novelai.net/user/subscription');

      // ⚠️ 시간 제한이 꼭 필요하다 — 앱을 켤 때 로딩 화면이 이 조회를 기다린다.
      //    예전엔 제한이 없어서, 와이파이가 붙었는데 인터넷이 안 되는 곳(인증 전 공용 와이파이 등)에서
      //    연결이 멈추면 로딩 화면이 끝나지 않을 수 있었다. 실패하면 아래 catch 에서 null.
      final response = await http
          .get(
            url,
            headers: {
              'Authorization': 'Bearer $cleanToken',
              'Content-Type': 'application/json; charset=utf-8',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(_utf8Body(response));

        int tier = data['tier'] ?? 0;
        int anlas = 0;

        // V5 사용 한도 (Opus 전용 — 없으면 null)
        double? usagePercent;
        double usageExtra = 0;
        bool usageNegative = false;
        final usage = data['usage'];
        if (usage is Map) {
          final p = usage['percent'];
          if (p is num) {
            usagePercent = p.toDouble();
          }
          final extra = usage['purchasedPercent'];
          if (extra is num && extra > 0) {
            usageExtra = extra.toDouble();
          }
          usageNegative = usage['isNegative'] == true;
        }

        if (data['trainingStepsLeft'] != null) {
          int fixed = data['trainingStepsLeft']['fixedTrainingStepsLeft'] ?? 0;
          int purchased = data['trainingStepsLeft']['purchasedTrainingSteps'] ?? 0;
          anlas = fixed + purchased;
        }
        return {
          'tier': tier,
          'anlas': anlas,
          'usagePercent': usagePercent, // null이면 한도 정보 없음
          'usageExtra': usageExtra, // 부스트 추가 사용량 (없으면 0)
          'usageNegative': usageNegative,
        };
      }
    } catch (e) {
      debugPrint("🚨 Anlas 정보 조회 실패: $e");
    }
    return null;
  }
}
