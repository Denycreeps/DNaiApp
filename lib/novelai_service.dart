import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;
import 'tag_filters.dart';

class NaiResponse {
  final Uint8List? image;
  final String? error;
  NaiResponse({this.image, this.error});
}

// ============================================================================
// 🚀 [최종 핵심 해결책] 원본 이미지와 마스크 모두 무조건 '순수 3채널(RGB)' 강제 변환
// ============================================================================
String _processImage3Channel(Uint8List bytes) {
  img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) {
    String b64 = base64Encode(bytes);
    if (b64.contains(',')) return b64.split(',').last.trim();
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
  if (bytes.length < 9) return base64Encode(bytes);

  final header = ByteData.view(bytes.buffer);
  final int w = header.getUint32(0);
  final int h = header.getUint32(4);
  final int expectedSize = 8 + w * h;
  if (bytes.length < expectedSize) return base64Encode(bytes);

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
        if (gx < smallW && gy < smallH) grid[gy][gx] = true;
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
    if (raw == null || raw.isEmpty) return "g";
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
    if (lower.endsWith('background') || lower.endsWith(' sky')) return true;
    // 고정 목록 매칭
    return TagFilters.backgroundTags.contains(lower);
  }

  // ============================================================================
  // 단보루 태그 파싱 로직 (기존 유지)
  // ============================================================================
  Future<Map<String, int>> _getDanbooruTagCategories(List<String> uniqueTags) async {
    final prefs = await SharedPreferences.getInstance();
    String? cachedData = prefs.getString('danbooru_tag_cache');
    Map<String, dynamic> persistentCache = cachedData != null ? jsonDecode(cachedData) : {};

    Map<String, int> finalCategoryMap = {};
    List<String> tagsToFetch = [];

    for (String tag in uniqueTags) {
      if (tag.isEmpty) continue;
      if (persistentCache.containsKey(tag)) {
        finalCategoryMap[tag] = int.tryParse(persistentCache[tag].toString()) ?? 0;
      } else {
        tagsToFetch.add(tag);
      }
    }

    if (tagsToFetch.isEmpty) return finalCategoryMap;

    int chunkSize = 100;
    bool isCacheUpdated = false;

    try {
      // 병렬 요청: 모든 청크를 동시에 전송
      List<List<String>> chunks = [];
      for (int i = 0; i < tagsToFetch.length; i += chunkSize) {
        int end = (i + chunkSize < tagsToFetch.length) ? i + chunkSize : tagsToFetch.length;
        chunks.add(tagsToFetch.sublist(i, end));
      }

      final results = await Future.wait(
        chunks.map((chunk) async {
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

      for (var response in results) {
        if (response != null && response.statusCode == 200) {
          List<dynamic> data = jsonDecode(response.body);
          for (var tagInfo in data) {
            String name = tagInfo['name'];
            int category = tagInfo['category'];
            finalCategoryMap[name] = category;
            persistentCache[name] = category;
            isCacheUpdated = true;
          }
        }
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
        await prefs.setString('danbooru_tag_cache', jsonEncode(persistentCache));
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

    List<String> apiTags = [...incTags];
    for (var t in excTags) {
      apiTags.add('-$t');
    }

    if (!rG) apiTags.add("-rating:general");
    if (!rS) apiTags.add("-rating:sensitive");
    if (!rQ) apiTags.add("-rating:questionable");
    if (!rE) apiTags.add("-rating:explicit");

    const String fallbackUserId = "1939815";
    const String fallbackApiKey =
        "cffc455dd65a8733c0524ea230cb259a03b246c3f2fb00086199a71a8acc6b22e134ea32e229af0eb655bde67a43cacf7380073201af688ba50b5ff0f1df738e";

    bool hasCredentials = gelbooruUserId.isNotEmpty && gelbooruApiKey.isNotEmpty;
    String effectiveUserId = hasCredentials ? gelbooruUserId : fallbackUserId;
    String effectiveApiKey = hasCredentials ? gelbooruApiKey : fallbackApiKey;

    if (!apiTags.contains("sort:random")) {
      apiTags.add("sort:random");
    }

    String tagQuery = Uri.encodeQueryComponent(apiTags.join(' '));
    int maxPagesToFetch = 20;

    List<dynamic> allValidPosts = [];
    Set<String> allUniqueTags = {};
    Set<int> seenIds = {};

    // Gelbooru 페이지 병렬 요청: 모든 페이지를 동시에 가져옴
    final pageResponses = await Future.wait(
      List.generate(maxPagesToFetch, (page) async {
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
        } catch (e) {
          debugPrint("겔보루 요청 에러: $e");
          return null;
        }
      }),
    );

    for (var response in pageResponses) {
      if (response == null || response.statusCode != 200) continue;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded['post'] == null) continue;

        List<dynamic> posts = decoded['post'];
        for (var post in posts) {
          if (post['id'] == null) continue;
          int postId = post['id'];

          if (seenIds.contains(postId)) continue;
          seenIds.add(postId);

          int width = int.tryParse(post['width'].toString()) ?? 0;
          int height = int.tryParse(post['height'].toString()) ?? 0;
          if (width < 512 || height < 512) continue;

          String tagString = post['tags'] ?? "";
          if (tagString.isEmpty) continue;

          allValidPosts.add(post);
          allUniqueTags.addAll(tagString.split(' ').where((e) => e.isNotEmpty));
        }
      } catch (e) {
        debugPrint("겔보루 파싱 에러: $e");
      }
    }

    if (allValidPosts.isEmpty) return [];

    // 로컬 사전 필터링: metadata/copyright 태그를 Danbooru API에 보내기 전에 제거
    // → API 청크 수 감소 → 네트워크 호출 절감
    final filteredUniqueTags = allUniqueTags.where((t) {
      final spaced = t.replaceAll('_', ' ');
      return !TagFilters.metadataTags.contains(spaced) &&
          !TagFilters.copyrightTags.contains(spaced) &&
          !TagFilters.commonGarbage.contains(t) &&
          !TagFilters.commonGarbage.contains(spaced);
    }).toList();

    Map<String, int> tagCategories = await _getDanbooruTagCategories(filteredUniqueTags);
    List<String> newPrompts = [];

    for (var post in allValidPosts) {
      String tagString = post['tags'] ?? "";
      List<String> rawTags = tagString.split(' ');
      List<String> finalTags = [];

      for (String t in rawTags.toSet()) {
        if (t.isEmpty) continue;

        String rawCleanTag = t.replaceAll('_', ' ');

        // 로컬 필터: metadata, copyright, commonGarbage
        if (TagFilters.metadataTags.contains(rawCleanTag)) continue;
        if (TagFilters.copyrightTags.contains(rawCleanTag)) continue;
        if (TagFilters.commonGarbage.contains(t) ||
            TagFilters.commonGarbage.contains(rawCleanTag)) {
          continue;
        }

        // Danbooru API 카테고리 필터: artist(1), copyright(3), character(4), metadata(5)
        int? category = tagCategories[t];
        if (category != null && category != 0) continue;

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
        if (finalTags.length >= 40) break;
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
    int maxAttempts = 6,
    void Function(String)? onStatus,
  }) async {
    try {
      String finalPrompt = positive;
      if (isFurry) {
        finalPrompt = "fur dataset, $positive";
      }

      // infill 액션 시 모델명에 -inpainting 접미사 추가 (nai-diffusion-2 예외)
      // 예: nai-diffusion-4-5-full → nai-diffusion-4-5-full-inpainting
      String apiModel = model;
      if (action == "infill" && model != "nai-diffusion-2") {
        apiModel = "$model-inpainting";
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
        // 🚀 [최종 수정] PC 프로그램 api_service.py 326~373번 줄과 1:1 일치
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
          // 🚀 [수정] VAR+ ON: 58, OFF: null (기존 59.04... 하드코딩 제거)
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
          // 🚀 [핵심 수정] infill: 원본 이미지를 재인코딩 없이 그대로 전송!
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
      if (action != "infill") {
        for (var char in characters) {
          double cx = (char['gridX'] * 0.2) + 0.1;
          double cy = (char['gridY'] * 0.2) + 0.1;
          var center = {"x": cx, "y": cy};

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
        // PC 프로그램: infill은 항상 use_coords=false
        "use_coords": action == "infill" ? false : posCharCaptions.isNotEmpty,
        "use_order": true,
      };
      parameters["v4_negative_prompt"] = {
        "caption": {"base_caption": negative, "char_captions": negCharCaptions},
        "legacy_uc": false,
      };
      // PC 프로그램과 동일: uc에도 네거티브 프롬프트를 넣어야 메타데이터에 표시됨
      parameters["uc"] = negative;

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
      final int effectiveMaxAttempts = (action == "infill") ? 10 : maxAttempts;
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
              .timeout(const Duration(seconds: 120));

          if (response.statusCode == 201 || response.statusCode == 200) {
            onStatus?.call("이미지 수신 완료!");
            final archive = ZipDecoder().decodeBytes(response.bodyBytes);
            if (archive.isNotEmpty) return NaiResponse(image: archive.first.content as Uint8List);
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
            return NaiResponse(error: "치명적 에러 [${response.statusCode}]: $errorMsg");
          }
        } catch (e) {
          lastWasConcurrent = false;
          if (currentAttempt >= effectiveMaxAttempts - 1) {
            return NaiResponse(error: "네트워크 한도 초과 및 연결 실패: $e");
          }
        }

        currentAttempt++;
        if (currentAttempt < effectiveMaxAttempts) {
          final int exponentialDelay = pow(2, currentAttempt).toInt();
          // concurrent lock이면 최소 20초 대기 (서버가 ghost request를 마칠 시간 확보)
          final int baseDelay = lastWasConcurrent
              ? exponentialDelay.clamp(20, 60)
              : exponentialDelay;
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
      final url = Uri.parse('https://api.novelai.net/user/subscription');

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
