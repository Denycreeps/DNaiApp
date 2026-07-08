import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;
import 'tag_filters.dart';
import 'models/model_caps.dart';

class NaiResponse {
  final Uint8List? image;
  final String? error;
  NaiResponse({this.image, this.error});
}

// ============================================================================
// [최종 핵심 해결책] 원본 이미지와 마스크 모두 무조건 '순수 3채널(RGB)' 강제 변환
// ============================================================================
String _processImage3Channel(Uint8List bytes) {
  img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) {
    String b64 = base64Encode(bytes);
    if (b64.contains(',')) {
      return b64.split(',').last.trim();
    }
    return b64.trim();
  }

  // 🚨 알파 채널을 제거하고 무조건 3채널(RGB) 이미지로 덮어씌웁니다.
  // V4.5 서버는 1채널이나 4채널 데이터가 들어오면 텐서 차원 오류로 크래시를 냅니다.
  final rgbImage = img.Image(width: decoded.width, height: decoded.height, numChannels: 3);
  for (var y = 0; y < decoded.height; y++) {
    for (var x = 0; x < decoded.width; x++) {
      final p = decoded.getPixel(x, y);
      rgbImage.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }

  int tW = (rgbImage.width ~/ 64) * 64;
  int tH = (rgbImage.height ~/ 64) * 64;
  img.Image finalImg = rgbImage;
  if (rgbImage.width != tW || rgbImage.height != tH) {
    finalImg = img.copyResize(rgbImage, width: tW, height: tH);
  }

  final pngBytes = Uint8List.fromList(img.encodePng(finalImg));
  String base64String = base64Encode(pngBytes);
  if (base64String.contains(',')) {
    return base64String.split(',').last.trim();
  }
  return base64String.trim();
}

// ============================================================================
// Infill 마스크 처리: 1/8 격자 → 8배 확대 → 풀 해상도 RGB 3채널 PNG
// ============================================================================
String _processMaskForInfill(Uint8List bytes) {
  if (bytes.length < 9) {
    return base64Encode(bytes);
  }

  final header = ByteData.view(bytes.buffer);
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

class NovelAiService {
  static const String apiUrl = "https://image.novelai.net/ai/generate-image";
  static const String encodeVibeUrl = "https://image.novelai.net/ai/encode-vibe";
  static const String upscaleUrl = "https://api.novelai.net/ai/upscale"; // 업스케일만 api 도메인 유지

  // ── Cloudflare Workers 프록시 ──────────────────────────────────────────
  static const String _danbooruProxy = "https://danbooru-proxy.dnaiapp.workers.dev";
  static const String _gelbooruProxy = "https://gelbooru-proxy.dnaiapp.workers.dev";
  // ───────────────────────────────────────────────────────────────────────

  String sanitizePrompt(String input) {
    return input.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).join(', ');
  }

  // Gelbooru rating 정규화: "explicit" → "e", "questionable" → "q" 등
  static String _normalizeRating(String? raw) {
    if (raw == null || raw.isEmpty) {
      return "g";
    }
    return raw.substring(0, 1).toLowerCase();
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

  List<String> _reorderTagsByPriority(List<String> tags) {
    List<String> countGroup = [];
    List<String> soloGroup = [];
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
    // 인원수 → solo → 시점 → 시선 → 일반(셔플) → 배경(맨 뒤)
    return [...countGroup, ...soloGroup, ...viewGroup, ...gazeGroup, ...rest, ...bgGroup];
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
  Future<Map<String, int>> _getDanbooruTagCategories(
    List<String> uniqueTags,
    String gelbooruUserId,
    String gelbooruApiKey,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    // v2: 구버전 캐시는 겔부루 전용 작가가 0(일반)으로 오염됐을 수 있어 폐기
    await prefs.remove('danbooru_tag_cache');
    String? cachedData = prefs.getString('tag_category_cache_v2');
    Map<String, dynamic> persistentCache = cachedData != null ? jsonDecode(cachedData) : {};

    Map<String, int> finalCategoryMap = {};
    List<String> tagsToFetch = [];

    for (String tag in uniqueTags) {
      if (tag.isEmpty) {
        continue;
      }
      if (persistentCache.containsKey(tag)) {
        finalCategoryMap[tag] = int.tryParse(persistentCache[tag].toString()) ?? 0;
      } else {
        tagsToFetch.add(tag);
      }
    }

    if (tagsToFetch.isEmpty) {
      return finalCategoryMap;
    }

    int chunkSize = 100;
    bool isCacheUpdated = false;

    try {
      // 청크 분할
      List<List<String>> chunks = [];
      for (int i = 0; i < tagsToFetch.length; i += chunkSize) {
        int end = (i + chunkSize < tagsToFetch.length) ? i + chunkSize : tagsToFetch.length;
        chunks.add(tagsToFetch.sublist(i, end));
      }

      // 배치 요청: Danbooru는 전역 10req/s 제한이라 한꺼번에 쏘면 429가 난다.
      // 6개씩 보내고 짧게 쉬어 첫 검색(미지 태그 대량)에도 안정적으로 동작.
      final List<http.Response?> results = [];
      const int batchSize = 6;
      for (int start = 0; start < chunks.length; start += batchSize) {
        final end = (start + batchSize).clamp(0, chunks.length);
        final batch = await Future.wait(
          chunks.sublist(start, end).map((chunk) async {
            String names = Uri.encodeComponent(chunk.join(','));
            try {
              return await http
                  .get(
                    Uri.parse(
                      "$_danbooruProxy/tags.json?search[name_comma]=$names&limit=100&only=name,category",
                    ),
                    headers: {'User-Agent': 'PrombotApp/1.0'},
                  )
                  .timeout(const Duration(seconds: 15));
            } catch (_) {
              return null;
            }
          }),
        );
        results.addAll(batch);
        if (end < chunks.length) {
          await Future.delayed(const Duration(milliseconds: 250));
        }
      }

      final List<String> danbooruNotFound = [];
      for (int i = 0; i < results.length; i++) {
        final response = results[i];
        if (response != null && response.statusCode == 200) {
          List<dynamic> data = jsonDecode(response.body);
          final Set<String> found = {};
          for (var tagInfo in data) {
            String name = tagInfo['name'];
            int category = tagInfo['category'];
            found.add(name);
            finalCategoryMap[name] = category;
            persistentCache[name] = category;
            isCacheUpdated = true;
          }
          // 응답에 없는 태그 = Danbooru에 없는 태그 → 겔부루 2차 분류로 넘김
          for (final tag in chunks[i]) {
            if (!found.contains(tag)) {
              danbooruNotFound.add(tag);
            }
          }
        }
      }

      // 2차: Danbooru에 없는 태그는 Gelbooru 태그 DB로 분류.
      // 포스트 출처가 겔부루이므로, 겔부루 전용 작가/태그도 여기서 정확히 잡힌다.
      // (type: 0=일반, 1=작가, 3=작품, 4=캐릭터, 5=메타, 6=폐기)
      if (danbooruNotFound.isNotEmpty) {
        const int gChunkSize = 100;
        for (int start = 0; start < danbooruNotFound.length; start += gChunkSize) {
          final end = (start + gChunkSize).clamp(0, danbooruNotFound.length);
          final chunk = danbooruNotFound.sublist(start, end);
          try {
            final names = Uri.encodeComponent(chunk.join(' '));
            final resp = await http
                .get(
                  Uri.parse(
                    "$_gelbooruProxy/index.php?page=dapi&s=tag&q=index&json=1&limit=100&names=$names&user_id=$gelbooruUserId&api_key=$gelbooruApiKey",
                  ),
                  headers: {
                    'User-Agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36',
                  },
                )
                .timeout(const Duration(seconds: 10));
            if (resp.statusCode == 200) {
              final decoded = jsonDecode(resp.body);
              final List<dynamic> gTags = (decoded is Map ? decoded['tag'] : null) ?? [];
              final Set<String> gFound = {};
              for (final tagInfo in gTags) {
                final String name = tagInfo['name'].toString();
                final int type = int.tryParse(tagInfo['type'].toString()) ?? 0;
                gFound.add(name);
                finalCategoryMap[name] = type;
                persistentCache[name] = type;
                isCacheUpdated = true;
              }
              // 양쪽 DB 모두에 없는 태그만 일반(0)으로 캐시 → 무한 재조회 차단
              for (final tag in chunk) {
                if (!gFound.contains(tag)) {
                  finalCategoryMap[tag] = 0;
                  persistentCache[tag] = 0;
                  isCacheUpdated = true;
                }
              }
            }
          } catch (e) {
            debugPrint("겔부루 태그 분류 폴백 실패: $e");
          }
          if (end < danbooruNotFound.length) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
        debugPrint("🏷️ 태그 분류 2차(겔부루): ${danbooruNotFound.length}개 처리");
      }

      if (isCacheUpdated) {
        // 캐시 크기 제한: 최대 50000개 (~1MB, SharedPreferences 안전 범위)
        const int maxCacheSize = 50000;
        if (persistentCache.length > maxCacheSize) {
          final keys = persistentCache.keys.toList();
          final removeCount = persistentCache.length - maxCacheSize;
          for (int i = 0; i < removeCount; i++) {
            persistentCache.remove(keys[i]);
          }
        }
        await prefs.setString('tag_category_cache_v2', jsonEncode(persistentCache));
      }
    } catch (e) {
      debugPrint("단보루 카테고리 페칭 실패: $e");
    }
    return finalCategoryMap;
  }

  Future<List<String>> fetchDanbooruTags({
    required String includeTags,
    required String excludeTags,
    required bool rG,
    required bool rS,
    required bool rQ,
    required bool rE,
    required bool removeCharacteristics,
    required bool removeClothes,
    required String gelbooruUserId,
    required String gelbooruApiKey,
    List<String> localExcludeTags = const [],
    int maxPagesToFetch = 20,
  }) async {
    List<String> incTags = includeTags
        .split(',')
        .map((e) => e.trim().replaceAll(' ', '_'))
        .where((e) => e.isNotEmpty)
        .toList();
    List<String> excTags = excludeTags
        .split(',')
        .map((e) => e.trim().replaceAll(' ', '_'))
        .where((e) => e.isNotEmpty)
        .toList();

    // 로컬 제외 태그 Set (빠른 검색용)
    final Set<String> localExcludeSet = localExcludeTags.map((t) => t.toLowerCase()).toSet();

    // OR 태그(~접두사)와 일반 태그 분리
    List<String> fixedTags = [];
    List<String> orTags = [];
    for (var t in incTags) {
      if (t.startsWith('~')) {
        orTags.add(t.substring(1)); // ~ 제거
      } else {
        fixedTags.add(t);
      }
    }

    // 공통 태그: 고정 태그 + 제외 태그 + 레이팅 필터
    List<String> baseTags = [...fixedTags];
    for (var t in excTags) {
      baseTags.add('-$t');
    }

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

    // 검색 범위(가져올 페이지 수)를 API 키 유무에 따라 조정:
    // - 본인 API 키 있음 → 적극적 (레이트 리밋 넉넉)
    // - 키 없음(공용 fallback 키) → 소극적 (공용 키 부담 줄이고 429 회피)
    // maxPagesToFetch가 명시적으로 전달되면(기본 20과 다르면) 그 값 우선.
    final int effectiveMaxPages = (maxPagesToFetch != 20)
        ? maxPagesToFetch
        : (hasCredentials ? 40 : 15);

    // OR 태그가 있으면 각 옵션별로 검색 → 합치기
    // 없으면 단일 검색
    List<List<String>> queryVariants = [];
    if (orTags.isEmpty) {
      queryVariants.add([...baseTags, "sort:random"]);
    } else {
      // 각 OR 옵션 + 고정 태그로 별도 쿼리 생성
      for (var orTag in orTags) {
        queryVariants.add([...baseTags, orTag, "sort:random"]);
      }
    }

    // 각 변형별 페이지 수 분배
    int pagesPerVariant = (effectiveMaxPages / queryVariants.length).ceil();

    List<dynamic> allValidPosts = [];
    Set<String> allUniqueTags = {};
    Set<int> seenIds = {};

    // 각 쿼리 변형별로 병렬 페이지 요청
    int totalRequests = 0;
    int failedRequests = 0;
    int timeoutRequests = 0;
    int serverErrors = 0;
    int rateLimitErrors = 0; // 429 별도 카운트
    int clientErrors = 0; // 4xx (429 제외)

    for (var apiTags in queryVariants) {
      String tagQuery = Uri.encodeQueryComponent(apiTags.join(' '));

      // 페이지 요청을 배치로 나눠 실행 (한 번에 너무 많이 쏘면 429 위험).
      // 배치 크기: 키 있으면 10, 없으면 5 (공용 키 보호).
      final int batchSize = hasCredentials ? 10 : 5;
      final List<http.Response?> pageResponses = [];

      Future<http.Response?> fetchPage(int page) async {
        totalRequests++;
        String gelbooruUrl =
            "$_gelbooruProxy/index.php?page=dapi&s=post&q=index&json=1&limit=100&pid=$page&tags=$tagQuery";
        gelbooruUrl += "&user_id=$effectiveUserId&api_key=$effectiveApiKey";
        try {
          return await http
              .get(
                Uri.parse(gelbooruUrl),
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36',
                },
              )
              .timeout(const Duration(seconds: 10));
        } on TimeoutException {
          timeoutRequests++;
          return null;
        } catch (e) {
          failedRequests++;
          debugPrint("겔보루 요청 에러: $e");
          return null;
        }
      }

      for (int start = 0; start < pagesPerVariant; start += batchSize) {
        final end = (start + batchSize).clamp(0, pagesPerVariant);
        final batch = await Future.wait(List.generate(end - start, (i) => fetchPage(start + i)));
        pageResponses.addAll(batch);
        // 다음 배치 전 짧은 간격 (서버 부담 완화)
        if (end < pagesPerVariant) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      for (var response in pageResponses) {
        if (response == null) {
          continue;
        }
        if (response.statusCode != 200) {
          final code = response.statusCode;
          if (code == 429) {
            rateLimitErrors++;
          } else if (code >= 500) {
            serverErrors++;
          } else if (code >= 400) {
            clientErrors++;
          } else {
            serverErrors++;
          }
          continue;
        }
        try {
          final decoded = jsonDecode(response.body);
          if (decoded['post'] == null) {
            continue;
          }

          List<dynamic> posts = decoded['post'];
          for (var post in posts) {
            if (post['id'] == null) {
              continue;
            }
            int postId = post['id'];

            if (seenIds.contains(postId)) {
              continue;
            }
            seenIds.add(postId);

            int width = int.tryParse(post['width'].toString()) ?? 0;
            int height = int.tryParse(post['height'].toString()) ?? 0;
            if (width < 512 || height < 512) {
              continue;
            }

            String tagString = post['tags'] ?? "";
            if (tagString.isEmpty) {
              continue;
            }

            allValidPosts.add(post);
            allUniqueTags.addAll(tagString.split(' ').where((e) => e.isNotEmpty));
          }
        } catch (e) {
          debugPrint("겔보루 파싱 에러: $e");
        }
      }
    } // queryVariants 루프 끝

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
    if (localExcludeSet.isNotEmpty) {
      allValidPosts.removeWhere((post) {
        String tagString = (post['tags'] ?? "").toString().toLowerCase();
        List<String> postTags = tagString.split(' ');
        return postTags.any((t) => localExcludeSet.contains(t));
      });
      debugPrint("🔍 로컬 제외 후: ${allValidPosts.length}개 포스트");
    }

    if (allValidPosts.isEmpty) {
      return [];
    }

    // 로컬 사전 필터링: metadata/copyright 태그를 Danbooru API에 보내기 전에 제거
    // → API 청크 수 감소 → 네트워크 호출 절감
    // (이름 사전 3종: 로컬에서 이미 분류 확정이므로 API에 물어볼 필요 없음)
    final filteredUniqueTags = allUniqueTags.where((t) {
      final spaced = t.replaceAll('_', ' ');
      return !TagFilters.metadataTags.contains(spaced) &&
          !TagFilters.copyrightTags.contains(spaced) &&
          !TagFilters.artistNames.contains(t) &&
          !TagFilters.characterNames.contains(t) &&
          !TagFilters.copyrightNames.contains(t) &&
          !TagFilters.commonGarbage.contains(t) &&
          !TagFilters.commonGarbage.contains(spaced);
    }).toList();

    Map<String, int> tagCategories = await _getDanbooruTagCategories(
      filteredUniqueTags,
      effectiveUserId,
      effectiveApiKey,
    );
    List<String> newPrompts = [];

    for (var post in allValidPosts) {
      String tagString = post['tags'] ?? "";
      List<String> rawTags = tagString.split(' ');
      List<String> finalTags = [];

      for (String t in rawTags.toSet()) {
        if (t.isEmpty) {
          continue;
        }

        String rawCleanTag = t.replaceAll('_', ' ');

        // 로컬 필터: metadata, copyright, commonGarbage
        if (TagFilters.metadataTags.contains(rawCleanTag)) {
          continue;
        }
        if (TagFilters.copyrightTags.contains(rawCleanTag)) {
          continue;
        }
        if (TagFilters.commonGarbage.contains(t) ||
            TagFilters.commonGarbage.contains(rawCleanTag)) {
          continue;
        }

        // 로컬 이름 사전: 작가/캐릭터/작품 이름은 API 결과와 무관하게 즉시 제거
        // (429·오프라인으로 카테고리 조회가 실패해도 이름 누출 방지)
        if (TagFilters.artistNames.contains(t) ||
            TagFilters.characterNames.contains(t) ||
            TagFilters.copyrightNames.contains(t)) {
          continue;
        }

        // Danbooru API 카테고리 필터: artist(1), copyright(3), character(4), metadata(5)
        int? category = tagCategories[t];
        if (category != null && category != 0) {
          continue;
        }

        String cleanTag = t.replaceAll('_', ' ').replaceAll('(', r'\(').replaceAll(')', r'\)');
        if (removeCharacteristics &&
            (TagFilters.characterTraits.contains(t) ||
                TagFilters.characterTraits.contains(rawCleanTag))) {
          continue;
        }
        if (removeClothes &&
            (TagFilters.clothesTags.contains(t) || TagFilters.clothesTags.contains(rawCleanTag))) {
          continue;
        }

        finalTags.add(cleanTag);
        if (finalTags.length >= 40) {
          break;
        }
      }

      if (finalTags.isNotEmpty) {
        // 프롬프트 순서 최적화: 인원수 → solo → 시점 → 시선 → 나머지(셔플) → 배경(맨 뒤)
        final prioritized = _reorderTagsByPriority(finalTags);
        String jsonCapsule = jsonEncode({
          "tags": prioritized.join(', '),
          "width": int.tryParse(post['width'].toString()) ?? 0,
          "height": int.tryParse(post['height'].toString()) ?? 0,
          "rating": _normalizeRating(post['rating']?.toString()),
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
  Future<String?> _encodeVibe(
    String base64Image,
    double infoExtracted,
    String model,
    String token,
  ) async {
    try {
      final response = await http.post(
        Uri.parse(encodeVibeUrl),
        headers: {"Authorization": "Bearer $token", "Content-Type": "application/json"},
        body: jsonEncode({
          "image": base64Image,
          "information_extracted": infoExtracted,
          "model": model,
        }),
      );
      if (response.statusCode == 200) {
        // 응답은 바이너리, base64로 인코딩
        return base64Encode(response.bodyBytes);
      }
      debugPrint("encode-vibe 실패: ${response.statusCode} ${response.body}");
      return null;
    } catch (e) {
      debugPrint("encode-vibe 오류: $e");
      return null;
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
    required bool isFurry,
    required int width,
    required int height,
    required double cfgScale,
    required double cfgRescale,
    required int seed,
    required List<Map<String, dynamic>> characters,
    Uint8List? image,
    Uint8List? mask,
    String action = "generate",
    double infillStrength = 0.7,
    bool variancePlus = false,
    bool useCharacterPosition = true,
    List<Map<String, dynamic>>? vibeTransfers,
    List<Map<String, dynamic>>? preciseRefs,
    int maxAttempts = 4,
    void Function(String)? onStatus,
  }) async {
    try {
      String finalPrompt = positive;
      if (isFurry) {
        finalPrompt = "fur dataset, $positive";
      }

      // 모델 능력(capability) 조회 — 기능 지원 여부/서버 전송용 문자열의 단일 출처
      final caps = modelCapsFor(model);

      // 서버로 실제 전송할 모델 문자열 (테스트 모델은 여기서 실제 v4.5 등으로 매핑됨)
      // infill 액션 시 모델명에 -inpainting 접미사 추가 (nai-diffusion-2 예외)
      // 예: nai-diffusion-4-5-full → nai-diffusion-4-5-full-inpainting
      String apiModel = caps.serverModelId;
      if (action == "infill" && caps.serverModelId != "nai-diffusion-2") {
        apiModel = "${caps.serverModelId}-inpainting";
      }

      Map<String, dynamic> parameters = {
        "width": width,
        "height": height,
        "scale": cfgScale,
        "sampler": sampler,
        "steps": steps,
        "seed": seed,
        "n_samples": 1,
      };

      // generate/infill 공통 파라미터
      parameters.addAll({
        "dynamic_thresholding": false,
        "controlnet_strength": 1,
        "legacy": false,
        "cfg_rescale": cfgRescale,
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
        // generate 전용 파라미터
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
      }

      if (variancePlus) {
        parameters["variety_plus"] = true;
      }

      if (scheduler != "native") {
        parameters["noise_schedule"] = scheduler;
      }

      // 이미지/마스크 인코딩
      if (image != null) {
        if (action == "infill") {
          // [핵심 수정] infill: 원본 이미지를 재인코딩 없이 그대로 전송!
          // 재인코딩하면 NovelAI PNG 메타데이터/픽셀 구조가 변형되어 서버 오류 가능
          parameters["image"] = base64Encode(image);
        } else {
          // generate: 3채널 RGB 변환 + 64배수 리사이즈 적용
          parameters["image"] = await compute(_processImage3Channel, image);
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
      bool hasCustomPosition = false;
      if (action != "infill") {
        for (var char in characters) {
          double cx = (char['gridX'] * 0.2) + 0.1;
          double cy = (char['gridY'] * 0.2) + 0.1;
          var center = {"x": cx, "y": cy};

          // 기본 위치(C3 = gridX:2, gridY:2)가 아닌 캐릭터가 있는지 체크
          if (char['gridX'] != 2 || char['gridY'] != 2) {
            hasCustomPosition = true;
          }

          if ((char['positive'] as String).isNotEmpty) {
            posCharCaptions.add({
              "char_caption": char['positive'],
              "centers": [center],
            });
          }
          if ((char['negative'] as String).isNotEmpty) {
            negCharCaptions.add({
              "char_caption": char['negative'],
              "centers": [center],
            });
          }
        }
      }

      parameters["v4_prompt"] = {
        "caption": {"base_caption": finalPrompt, "char_captions": posCharCaptions},
        // 하나라도 기본 위치(C3)가 아닌 캐릭터가 있고, 배치 적용이 켜져있을 때만 좌표 사용
        "use_coords": action == "infill" ? false : (hasCustomPosition && useCharacterPosition),
        "use_order": true,
      };
      parameters["v4_negative_prompt"] = {
        "caption": {"base_caption": negative, "char_captions": negCharCaptions},
        "legacy_uc": false,
      };
      // PC 프로그램과 동일: uc에도 네거티브 프롬프트를 넣어야 메타데이터에 표시됨
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

            String? encoded;
            if (cachedEnc != null && cachedInfoExt == infoExt && cachedModel == apiModel) {
              encoded = cachedEnc; // 캐시 재사용 (무료)
            } else {
              encoded = await _encodeVibe(v['image'] as String, infoExt, apiModel, token);
              if (encoded != null) {
                // 캐시 저장
                v['_encoded'] = encoded;
                v['_encodedInfoExt'] = infoExt;
                v['_encodedModel'] = apiModel;
              }
            }
            if (encoded != null) {
              encodedVibes.add(encoded);
              vibeStrengths.add((v['strength'] as double?) ?? 0.6);
            }
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
          final response = await http
              .post(
                Uri.parse(apiUrl),
                headers: {
                  "Authorization": "Bearer $token",
                  "Content-Type": "application/json",
                  "Accept": "application/zip",
                },
                body: jsonEncode(requestBody),
              )
              .timeout(const Duration(seconds: 60));

          if (response.statusCode == 201 || response.statusCode == 200) {
            onStatus?.call("이미지 수신 완료!");
            final archive = ZipDecoder().decodeBytes(response.bodyBytes);
            if (archive.isNotEmpty) {
              return NaiResponse(image: archive.first.content as Uint8List);
            }
            throw Exception('서버가 빈 아카이브를 반환했습니다.');
          } else if (response.statusCode == 429) {
            String errorMessage = '';
            try {
              final errorBody = jsonDecode(response.body);
              errorMessage = errorBody['message']?.toString().toLowerCase() ?? '';
            } catch (_) {
              errorMessage = response.body.toLowerCase();
            }

            if (errorMessage.contains('concurrent')) {
              lastWasConcurrent = true;
              onStatus?.call("서버 처리 중... 잠금 해제 대기 (${currentAttempt + 1}/$effectiveMaxAttempts)");
              debugPrint(
                '[동시성 제어] 서버 측 연산 잠금 상태. 재시도 폴링 진입. (시도: ${currentAttempt + 1}/$effectiveMaxAttempts)',
              );
            } else {
              return NaiResponse(error: "API 한도 초과: $errorMessage");
            }
          } else if (response.statusCode >= 500) {
            // 500 응답 body를 안전하게 파싱해서 디버그 출력
            String serverMsg = '';
            try {
              serverMsg = jsonDecode(response.body)['message']?.toString() ?? response.body;
            } catch (_) {
              serverMsg = response.body;
            }
            debugPrint('[서버 에러] ${response.statusCode}: $serverMsg — 재시도 수행.');
            onStatus?.call("서버 오류 (${response.statusCode}) — 재시도 중...");
          } else {
            String errorMsg = response.body;
            try {
              errorMsg = jsonDecode(response.body)['message']?.toString() ?? response.body;
            } catch (_) {}
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
            return NaiResponse(error: friendly);
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
      return NaiResponse(error: "파이프라인 내부 오류 발생\n$e");
    }
  }

  // ============================================================================
  // 업스케일 및 사용자 정보
  // ============================================================================
  Future<NaiResponse> upscaleImage({
    required Uint8List image,
    required int width,
    required int height,
    required String token,
  }) async {
    try {
      // 업스케일 API는 generate와 달리 채널 변환 없이 원본 그대로 base64 전송
      final String base64Image = base64Encode(image);

      final response = await http
          .post(
            Uri.parse(upscaleUrl),
            headers: {
              "Authorization": "Bearer $token",
              "Content-Type": "application/json",
              "Accept": "application/json",
            },
            body: jsonEncode({"image": base64Image, "width": width, "height": height, "scale": 4}),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode == 201 || response.statusCode == 200) {
        // 응답이 ZIP인 경우와 raw bytes인 경우 모두 처리
        try {
          final archive = ZipDecoder().decodeBytes(response.bodyBytes);
          if (archive.isNotEmpty) {
            return NaiResponse(image: archive.first.content as Uint8List);
          }
        } catch (_) {}
        return NaiResponse(image: response.bodyBytes);
      } else {
        String errorMsg = "서버 오류";
        try {
          errorMsg = jsonDecode(response.body)['message'] ?? response.body;
        } catch (_) {
          errorMsg = response.body.isNotEmpty ? response.body : "알 수 없는 오류 발생";
        }
        return NaiResponse(error: "업스케일 에러 [${response.statusCode}]\n$errorMsg");
      }
    } catch (e) {
      return NaiResponse(error: "네트워크 오류 발생\n$e");
    }
  }

  Future<Map<String, int>?> fetchUserInfo(String token) async {
    try {
      final cleanToken = token.trim().replaceFirst('Bearer ', '').trim();
      // NAI 서버 마이그레이션(2026): /user/* 는 image.novelai.net에서 호출해야 함.
      // 기존 api.novelai.net/user/subscription 은 현재 작동하지 않음.
      final url = Uri.parse('https://image.novelai.net/user/subscription');

      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $cleanToken', 'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        int tier = data['tier'] ?? 0;
        int anlas = 0;

        if (data['trainingStepsLeft'] != null) {
          int fixed = data['trainingStepsLeft']['fixedTrainingStepsLeft'] ?? 0;
          int purchased = data['trainingStepsLeft']['purchasedTrainingSteps'] ?? 0;
          anlas = fixed + purchased;
        }
        return {'tier': tier, 'anlas': anlas};
      }
    } catch (e) {
      debugPrint("🚨 Anlas 정보 조회 실패: $e");
    }
    return null;
  }
}
