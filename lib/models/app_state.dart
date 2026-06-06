import 'package:flutter/services.dart' show rootBundle;
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

import '../novelai_service.dart';
import '../tag_filters.dart';
import 'nai_character.dart';

// ============================================================================
// 스마트 태그 매칭: 공백으로 단어 조각을 구분하여 검색
// "ca t" → cat_tail (ca→cat, t→tail) 매칭, cat_ears 제외
// 단일 단어면 기존 startsWith 동작과 동일
// ============================================================================
// † 접두어 = 보조 매칭 결과 (UI에서 연한 스타일로 구분)
// ============================================================================
const String kContainsMarker = '* ';

// ============================================================================
// 프롬프트 토큰 추정기 (NAI V4/V4.5 T5 토크나이저 기준 ~512 토큰 제한)
// T5 토크나이저는 서브워드 기반으로, 평균 ~3.2글자당 1토큰
// (콤마·괄호·가중치 구문 모두 토큰으로 소비됨)
// ============================================================================
int estimateTokenCount(String prompt) {
  if (prompt.trim().isEmpty) {
    return 0;
  }
  return (prompt.trim().length / 3.1).round();
}

List<String> smartMatchTags(List<String> tags, String query, {int limit = 15}) {
  // 트레일링 스페이스 감지 (trim 전에!)
  final hasTrailingSpace = query.endsWith(' ');
  final lower = query.toLowerCase().trim();
  if (lower.isEmpty) {
    return [];
  }

  final fragments = lower.split(RegExp(r'\s+'));

  // 다중 조각 ("ca t", "lo a v" 등): 스마트 단어 매칭
  if (fragments.length > 1) {
    return _multiWordMatch(tags, fragments, limit);
  }

  // ======================================================================
  // 단일 조각
  // ======================================================================

  // 🔒 트레일링 스페이스 = "확정 모드": startsWith만 → 없으면 contains fallback
  if (hasTrailingSpace) {
    final startsResults = tags.where((t) => t.toLowerCase().startsWith(lower)).take(limit).toList();
    if (startsResults.isNotEmpty) {
      return startsResults;
    }
    // startsWith 결과 없음 → contains fallback (연한 스타일)
    return tags
        .where((t) => t.toLowerCase().contains(lower))
        .take(limit)
        .map((t) => '$kContainsMarker$t')
        .toList();
  }

  // 1~2글자: startsWith만 (contains는 노이즈 너무 많음)
  if (lower.length <= 2) {
    return tags.where((t) => t.toLowerCase().startsWith(lower)).take(limit).toList();
  }

  // 3글자+, 스페이스 없음: 단어경계 우선 + 중간매칭 후순위
  final wordBoundaryResults = <String>[];
  final midWordResults = <String>[];

  for (final tag in tags) {
    final tagLower = tag.toLowerCase();
    if (tagLower.startsWith(lower)) {
      // 태그 자체가 쿼리로 시작 (최우선)
      wordBoundaryResults.add(tag);
    } else if (tagLower.split(' ').any((w) => w.startsWith(lower))) {
      // 태그 안의 단어가 쿼리로 시작 (단어 경계 매칭)
      wordBoundaryResults.add(tag);
    } else if (tagLower.contains(lower)) {
      // 단어 중간에 포함 (최후순위)
      midWordResults.add(tag);
    }
    if (wordBoundaryResults.length >= limit && midWordResults.length >= limit) {
      break;
    }
  }

  // 점진적 할당: 쿼리가 길수록 midWord 비중 증가
  final wordSlots = (wordBoundaryResults.length < limit - 3)
      ? wordBoundaryResults.length
      : max<int>(limit - lower.length, 5).clamp(0, limit);
  final midSlots = limit - min<int>(wordBoundaryResults.length, wordSlots);

  return [
    ...wordBoundaryResults.take(wordSlots),
    ...midWordResults.take(midSlots).map((t) => '$kContainsMarker$t'),
  ];
}

List<String> _multiWordMatch(List<String> tags, List<String> fragments, int limit) {
  final first = fragments.first;
  final rest = fragments.sublist(1);

  return tags
      .where((tag) {
        final tagLower = tag.toLowerCase();
        if (!tagLower.startsWith(first)) {
          return false;
        }

        final words = tagLower.split(RegExp(r'[_ ]'));
        int wordIdx = 1;
        for (final frag in rest) {
          bool found = false;
          while (wordIdx < words.length) {
            if (words[wordIdx].startsWith(frag)) {
              wordIdx++;
              found = true;
              break;
            }
            wordIdx++;
          }
          if (!found) {
            return false;
          }
        }
        return true;
      })
      .take(limit)
      .toList();
}

class NaiMetadata {
  final String positive;
  final String negative;
  final List<String> characterPrompts;
  final List<String> characterUndesiredContents;
  final int width;
  final int height;
  final int seed;
  final int steps;
  final String sampler;
  final double promptGuidance;
  final double promptGuidanceRescale;
  final double undesiredContentStrength;
  final String source;
  final Map<String, dynamic> extraParams;

  NaiMetadata({
    required this.positive,
    required this.negative,
    required this.characterPrompts,
    required this.characterUndesiredContents,
    required this.width,
    required this.height,
    required this.seed,
    required this.steps,
    required this.sampler,
    required this.promptGuidance,
    required this.promptGuidanceRescale,
    required this.undesiredContentStrength,
    required this.source,
    this.extraParams = const {},
  });

  Map<String, dynamic> toJson() => {
    'positive': positive,
    'negative': negative,
    'characterPrompts': characterPrompts,
    'characterUndesiredContents': characterUndesiredContents,
    'width': width,
    'height': height,
    'seed': seed,
    'steps': steps,
    'sampler': sampler,
    'promptGuidance': promptGuidance,
    'promptGuidanceRescale': promptGuidanceRescale,
    'undesiredContentStrength': undesiredContentStrength,
    'source': source,
    'extraParams': extraParams,
  };

  factory NaiMetadata.fromJson(Map<String, dynamic> json) => NaiMetadata(
    positive: json['positive'] ?? '',
    negative: json['negative'] ?? '',
    characterPrompts: List<String>.from(json['characterPrompts'] ?? []),
    characterUndesiredContents: List<String>.from(json['characterUndesiredContents'] ?? []),
    width: json['width'] ?? 0,
    height: json['height'] ?? 0,
    seed: json['seed'] ?? 0,
    steps: json['steps'] ?? 0,
    sampler: json['sampler'] ?? '',
    promptGuidance: (json['promptGuidance'] ?? 0).toDouble(),
    promptGuidanceRescale: (json['promptGuidanceRescale'] ?? 0).toDouble(),
    undesiredContentStrength: (json['undesiredContentStrength'] ?? 0).toDouble(),
    source: json['source'] ?? '',
    extraParams: Map<String, dynamic>.from(json['extraParams'] ?? {}),
  );

  // extraParams에 값을 추가한 새 인스턴스를 반환 (서버가 메타데이터에 기록하지 않는 값 보완용)
  NaiMetadata copyWithExtra(Map<String, dynamic> extra) {
    final merged = Map<String, dynamic>.from(extraParams)..addAll(extra);
    return NaiMetadata(
      positive: positive,
      negative: negative,
      characterPrompts: characterPrompts,
      characterUndesiredContents: characterUndesiredContents,
      width: width,
      height: height,
      seed: seed,
      steps: steps,
      sampler: sampler,
      promptGuidance: promptGuidance,
      promptGuidanceRescale: promptGuidanceRescale,
      undesiredContentStrength: undesiredContentStrength,
      source: source,
      extraParams: merged,
    );
  }
}

NaiMetadata? extractNovelAIMetadata(Uint8List imageBytes) {
  try {
    final pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
    for (int i = 0; i < pngSignature.length; i++) {
      if (imageBytes[i] != pngSignature[i]) {
        return null;
      }
    }

    int offset = 8;
    Map<String, String> textChunks = {};
    int imageWidth = 0;
    int imageHeight = 0;

    while (offset < imageBytes.length) {
      if (offset + 8 > imageBytes.length) {
        break;
      }

      int length = ByteData.view(imageBytes.buffer).getUint32(offset);
      String type = String.fromCharCodes(imageBytes.sublist(offset + 4, offset + 8));

      if (type == 'IHDR' && length >= 8) {
        imageWidth = ByteData.view(imageBytes.buffer).getUint32(offset + 8);
        imageHeight = ByteData.view(imageBytes.buffer).getUint32(offset + 12);
      } else if (type == 'tEXt') {
        List<int> chunkData = imageBytes.sublist(offset + 8, offset + 8 + length);
        int nullIdx = chunkData.indexOf(0);
        if (nullIdx != -1) {
          String key = String.fromCharCodes(chunkData.sublist(0, nullIdx));
          String value = utf8.decode(chunkData.sublist(nullIdx + 1), allowMalformed: true);
          textChunks[key] = value;
        }
      }
      offset += 12 + length;
    }

    String prompt = textChunks['Description'] ?? '';
    String source = textChunks['Source'] ?? '';
    String commentString = textChunks['Comment'] ?? '{}';

    if (commentString == '{}' || commentString.isEmpty) {
      try {
        String rawString = utf8.decode(imageBytes, allowMalformed: true);
        int startIndex = rawString.indexOf('{"prompt":');
        if (startIndex == -1) {
          startIndex = rawString.indexOf('{"v4_prompt":');
        }
        if (startIndex != -1) {
          int braceIndex = rawString.lastIndexOf('{', startIndex);
          if (braceIndex != -1) {
            int openBraces = 0;
            for (int i = braceIndex; i < rawString.length; i++) {
              if (rawString[i] == '{') {
                openBraces++;
              } else if (rawString[i] == '}') {
                openBraces--;
                if (openBraces == 0) {
                  commentString = rawString.substring(braceIndex, i + 1);
                  break;
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    Map<String, dynamic> commentJson = {};
    try {
      commentJson = jsonDecode(commentString);
    } catch (_) {}

    String pos = "";
    String neg = "";
    List<String> charPrompts = [];
    List<String> charUCs = [];

    if (commentJson.containsKey('v4_prompt')) {
      var v4 = commentJson['v4_prompt'];
      if (v4 is Map && v4.containsKey('caption')) {
        var cap = v4['caption'];
        if (cap is Map && cap.containsKey('char_captions')) {
          var chars = cap['char_captions'];
          if (chars is List) {
            for (var c in chars) {
              if (c is Map) {
                String? cText = c['char_caption']?.toString() ?? c['char_prompt']?.toString();
                if (cText != null && cText.isNotEmpty) {
                  charPrompts.add(cText);
                }
                String? cUc = c['uc']?.toString();
                if (cUc != null && cUc.isNotEmpty) {
                  charUCs.add(cUc);
                }
              }
            }
          }
        }
      }
    }

    if (commentJson.containsKey('v4_negative_prompt')) {
      var v4Neg = commentJson['v4_negative_prompt'];
      if (v4Neg is Map) {
        if (v4Neg['caption'] is Map && v4Neg['caption']['base_caption'] != null) {
          neg = v4Neg['caption']['base_caption'].toString();
        } else if (v4Neg['base_caption'] != null) {
          neg = v4Neg['base_caption'].toString();
        } else if (v4Neg['text'] != null) {
          neg = v4Neg['text'].toString();
        }
      } else if (v4Neg is String) {
        neg = v4Neg;
      }
    }

    if (commentJson.containsKey('characterPrompts')) {
      var cps = commentJson['characterPrompts'];
      if (cps is List) {
        for (var cp in cps) {
          if (cp is Map) {
            charPrompts.add(cp['prompt']?.toString() ?? '');
            charUCs.add(cp['uc']?.toString() ?? '');
          } else {
            charPrompts.add(cp.toString());
          }
        }
      }
    }

    if (pos.isEmpty) {
      pos = commentJson['prompt']?.toString() ?? prompt;
    }
    if (neg.isEmpty) {
      neg = commentJson['uc']?.toString() ?? '';
    }

    int parsedSeed = int.tryParse(commentJson['seed']?.toString() ?? '') ?? 0;
    int parsedSteps = int.tryParse(commentJson['steps']?.toString() ?? '') ?? 0;
    String parsedSampler = commentJson['sampler']?.toString() ?? '';
    double parsedScale = double.tryParse(commentJson['scale']?.toString() ?? '') ?? 0.0;
    double parsedRescale = double.tryParse(commentJson['cfg_rescale']?.toString() ?? '') ?? 0.0;
    double parsedUcStrength = double.tryParse(commentJson['uc_strength']?.toString() ?? '') ?? 0.0;

    Map<String, dynamic> extras = Map.from(commentJson);
    final knownKeys = [
      'uc',
      'seed',
      'steps',
      'sampler',
      'scale',
      'cfg_rescale',
      'uc_strength',
      'characterPrompts',
      'v4_prompt',
      'v4_negative_prompt',
      'prompt',
    ];
    for (var key in knownKeys) {
      extras.remove(key);
    }

    return NaiMetadata(
      positive: pos,
      negative: neg,
      characterPrompts: charPrompts,
      characterUndesiredContents: charUCs,
      width: imageWidth,
      height: imageHeight,
      seed: parsedSeed,
      steps: parsedSteps,
      sampler: parsedSampler,
      promptGuidance: parsedScale,
      promptGuidanceRescale: parsedRescale,
      undesiredContentStrength: parsedUcStrength,
      source: source,
      extraParams: extras,
    );
  } catch (e) {
    debugPrint("메타데이터 파싱 실패: $e");
    return null;
  }
}

class NaiWildcard {
  String name;
  String content;
  NaiWildcard({this.name = "새 와일드카드", this.content = ""});
  Map<String, dynamic> toJson() => {'name': name, 'content': content};
  factory NaiWildcard.fromJson(Map<String, dynamic> json) =>
      NaiWildcard(name: json['name'] ?? '', content: json['content'] ?? '');
}

class NaiPreset {
  String name;
  String positive;
  String negative;
  String prefix;
  String suffix;
  Map<String, dynamic>? settings; // 상세 설정 (스텝, 시드, cfg 등)
  List<Map<String, dynamic>>? characters; // 캐릭터 리스트
  Set<String> savedFields;
  String? previewImage; // base64 썸네일 (100px JPEG)

  NaiPreset({
    required this.name,
    this.positive = '',
    this.negative = '',
    this.prefix = '',
    this.suffix = '',
    this.settings,
    this.characters,
    this.previewImage,
    Set<String>? savedFields,
  }) : savedFields = savedFields ?? {'positive', 'negative', 'prefix', 'suffix'};

  Map<String, dynamic> toJson() => {
    'name': name,
    'positive': positive,
    'negative': negative,
    'prefix': prefix,
    'suffix': suffix,
    'settings': settings,
    'characters': characters,
    'savedFields': savedFields.toList(),
    if (previewImage != null) 'previewImage': previewImage,
  };

  factory NaiPreset.fromJson(Map<String, dynamic> json) => NaiPreset(
    name: json['name'] ?? '',
    positive: json['positive'] ?? '',
    negative: json['negative'] ?? '',
    prefix: json['prefix'] ?? '',
    suffix: json['suffix'] ?? '',
    settings: json['settings'] as Map<String, dynamic>?,
    characters: (json['characters'] as List?)?.map((e) => Map<String, dynamic>.from(e)).toList(),
    previewImage: json['previewImage'] as String?,
    savedFields: json['savedFields'] != null
        ? (json['savedFields'] as List).map((e) => e.toString()).toSet()
        : {'positive', 'negative', 'prefix', 'suffix'},
  );
}

class SyntaxHighlightController extends TextEditingController {
  SyntaxHighlightController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final lines = text.split('\n');
    final List<TextSpan> spans = [];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('#')) {
        spans.add(
          TextSpan(
            text: line,
            style: style?.copyWith(color: Colors.grey),
          ),
        );
      } else {
        spans.add(TextSpan(text: line, style: style));
      }

      if (i < lines.length - 1) {
        spans.add(TextSpan(text: '\n', style: style));
      }
    }
    return TextSpan(style: style, children: spans);
  }
}

class AppState extends ChangeNotifier {
  // ============================================================================
  // 앱 버전 & 업데이트 체크
  // ============================================================================
  static String currentVersion = "0.0.0"; // pubspec.yaml에서 자동 로드됨
  // GitHub 저장소 주소 (본인 리포로 변경!)
  static const String githubRepo = "Denycreeps/DNaiApp";

  String? latestVersion;
  String? updateUrl;
  String? updateNotes;
  String? apkDownloadUrl; // APK 직접 다운로드 URL
  bool autoCheckUpdate = true; // 기동 시 자동 업데이트 체크
  bool isDownloadingUpdate = false;
  double downloadProgress = 0.0;

  bool get hasUpdate =>
      latestVersion != null && _compareVersions(latestVersion!, currentVersion) > 0;

  /// 릴리즈 노트를 미리보기 형태로 변환
  List<String> get releaseNotePreview {
    if (updateNotes == null || updateNotes!.isEmpty) {
      return [];
    }
    return updateNotes!
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('![')) // 이미지 라인 제외
        .map((line) {
          // 마크다운 헤더 정리
          line = line.replaceAll(RegExp(r'^#+\s*'), '');
          // 30자 넘으면 자르기
          if (line.length > 40) {
            return '${line.substring(0, 40)}...';
          }
          return line;
        })
        .take(10) // 최대 10줄
        .toList();
  }

  static int _compareVersions(String a, String b) {
    final pa = a.replaceFirst('v', '').split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.replaceFirst('v', '').split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) {
        return va.compareTo(vb);
      }
    }
    return 0;
  }

  Future<void> checkForUpdate() async {
    try {
      // releases/latest는 'commit 날짜' 기준이라 태그를 옛 커밋에 달면 최신을 못 찾음.
      // releases 목록 전체를 받아서 버전 번호로 직접 최댓값을 찾는다.
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$githubRepo/releases?per_page=30'),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final releases = jsonDecode(resp.body) as List? ?? [];
        Map<String, dynamic>? best;
        String bestTag = "";
        for (final r in releases) {
          // draft / prerelease 제외
          if ((r['draft'] as bool?) ?? false) {
            continue;
          }
          if ((r['prerelease'] as bool?) ?? false) {
            continue;
          }
          final tag = r['tag_name']?.toString() ?? "";
          if (tag.isEmpty) {
            continue;
          }
          if (best == null || _compareVersions(tag, bestTag) > 0) {
            best = Map<String, dynamic>.from(r);
            bestTag = tag;
          }
        }

        if (best != null && _compareVersions(bestTag, currentVersion) > 0) {
          latestVersion = bestTag.replaceFirst('v', '');
          updateUrl = best['html_url']?.toString();
          updateNotes = best['body']?.toString();

          // APK 에셋 찾기
          final assets = best['assets'] as List? ?? [];
          for (final asset in assets) {
            final name = asset['name']?.toString() ?? '';
            if (name.endsWith('.apk')) {
              apkDownloadUrl = asset['browser_download_url']?.toString();
              break;
            }
          }
          notifyListeners();
        }
      }
    } catch (_) {
      // 네트워크 실패 시 무시 (업데이트 체크는 부가 기능)
    }
  }

  Future<void> downloadAndInstallUpdate(BuildContext context) async {
    if (apkDownloadUrl == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("다운로드 URL을 찾을 수 없습니다."),
          ),
        );
      }
      return;
    }

    isDownloadingUpdate = true;
    downloadProgress = 0.0;
    notifyListeners();

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/DNaiApp_v$latestVersion.apk');

      // 스트리밍 다운로드 (프로그레스 표시)
      final request = http.Request('GET', Uri.parse(apkDownloadUrl!));
      final response = await http.Client().send(request);
      final contentLength = response.contentLength ?? 0;

      List<int> bytes = [];
      int received = 0;

      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          downloadProgress = received / contentLength;
          notifyListeners();
        }
      }

      await file.writeAsBytes(bytes);

      isDownloadingUpdate = false;
      downloadProgress = 1.0;
      notifyListeners();

      // APK 설치 실행
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("설치 실행에 실패했습니다: ${result.message}"),
          ),
        );
      }
    } catch (e) {
      isDownloadingUpdate = false;
      downloadProgress = 0.0;
      notifyListeners();
      debugPrint("업데이트 다운로드 실패: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(milliseconds: 2400), content: Text("다운로드에 실패했습니다.")),
        );
      }
    }
  }

  // ============================================================================

  final TextEditingController positiveController = TextEditingController();
  final TextEditingController negativeController = TextEditingController();
  final TextEditingController prefixController = TextEditingController();
  final TextEditingController suffixController = TextEditingController();

  final TextEditingController inpaintPositiveController = TextEditingController();
  final TextEditingController inpaintNegativeController = TextEditingController();
  final TextEditingController inpaintPrefixController = TextEditingController();
  final TextEditingController inpaintSuffixController = TextEditingController();

  final TextEditingController stepsController = TextEditingController(text: "28");
  final TextEditingController cfgScaleController = TextEditingController(text: "6.0");
  final TextEditingController cfgRescaleController = TextEditingController(text: "0.00");
  final TextEditingController seedController = TextEditingController();
  final TextEditingController apiTokenController = TextEditingController();

  final TextEditingController gelbooruApiController = TextEditingController();
  String gelbooruUserId = "";
  String gelbooruApiKey = "";

  final TextEditingController gelbooruIncludeController = TextEditingController();
  final TextEditingController gelbooruExcludeController = TextEditingController();
  final TextEditingController customRemoveController = TextEditingController();
  final TextEditingController customSavePathController = TextEditingController(
    text: "/storage/emulated/0/Download",
  );
  final TextEditingController customFileNameController = TextEditingController(
    text: "Nai-{yy}{mm}{dd}-{time}-{count}",
  );
  final TextEditingController customWidthController = TextEditingController(text: "832");
  final TextEditingController customHeightController = TextEditingController(text: "1216");

  final SyntaxHighlightController conditionalRuleController = SyntaxHighlightController();
  // 조건부 트리거 작동 시점: "random"(랜덤 프롬프트 생성 시) / "generate"(이미지 생성 시)
  String conditionalTriggerMode = "random";

  bool ratingE = false;
  bool ratingQ = false;
  bool ratingS = false;
  bool ratingG = true;
  bool removeCharacteristics = false;
  bool removeClothes = false;
  bool removeColors = false;
  bool isAutoSave = true;
  bool isRandomLocked = false;
  bool isFurryMode = false;
  bool isSeedLocked = false;
  double infillStrength = 0.7;
  bool isVariancePlus = false; // VAR+ (Variety+) 모드
  bool horizontalSwipeEnabled = false; // 좌우 스와이프 탭 전환
  bool historySlideEnabled = false; // 히스토리 이미지 슬라이드 (화살표 + 애니메이션)
  bool randomPromptAlphabetical = false; // 랜덤 프롬프트 나머지 태그 알파벳 순서
  bool ignoreRecommendedOrder = false; // NovelAI 권장 순서(인원/solo/시점 등) 무시

  // 배치 생성
  int batchCount = 1; // 1, 2, 3, 4, 0(무한)
  int batchRemaining = 0; // 남은 생성 수
  bool isBatchMode = false;
  double batchDelay = 0.5; // 연속 생성 딜레이 (초)
  bool showGenerationMessage = false; // 이미지 생성 시 하단 메세지

  // 탭 활성화 상태 (프롬프트/설정은 항상 켜짐)
  bool historyTabEnabled = true;
  bool i2iTabEnabled = true;
  bool characterTabEnabled = true;
  bool wildcardTabEnabled = true;
  bool useGelbooruApiKey = true;

  // 프롬프트 섹션 순서 (드래그로 재배치 가능)
  List<String> promptSectionOrder = [
    'positive',
    'prefix',
    'suffix',
    'negative',
    'removeChips',
    'customRemove',
    'conditional',
  ];

  // 프롬프트 섹션 접기 상태
  Set<String> collapsedSections = {};

  String resolutionMode = "수동";
  int currentImageWidth = 0;
  int currentImageHeight = 0;
  String apiToken = "";
  bool isApiConnected = false;
  int sessionSaveCount = 0;
  int sessionGenerateCount = 0;
  String? sessionFolderName;
  String selectedModel = "nai-diffusion-4-5-full";
  String selectedSampler = "k_euler_ancestral";
  String selectedScheduler = "karras";
  String selectedResolution = "832 x 1216";
  double resolutionScale = 1.0; // 1.0, 1.5, 2.0
  List<String> customResolutions = []; // 사용자 추가 해상도

  List<NaiCharacter> characters = [NaiCharacter()];
  int selectedCharIndex = 0;
  bool useCharacterPosition = true; // 캐릭터 배치 적용 ON/OFF

  // Vibe Transfer
  List<Map<String, dynamic>> vibeTransfers =
      []; // [{image: base64, strength: 0.6, infoExtracted: 1.0}]

  // Precise Reference (V4.5 전용)
  List<Map<String, dynamic>> preciseRefs =
      []; // [{image: base64, type: 'character', strength: 1.0, fidelity: 0.5}]
  List<NaiWildcard> wildcards = [
    NaiWildcard(name: "의상", content: "school uniform\nmaid outfit\nbikini"),
  ];
  int selectedWildcardIndex = 0;

  List<NaiPreset> presets = [];

  List<String> gelbooruPrompts = [];
  int currentPromptIndex = 0;
  int gelbooruTotal = 0;
  int gelbooruRemaining = 0;
  bool isGelbooruExpanded = false;
  bool isGelbooruLoading = false;

  final NovelAiService _service = NovelAiService();
  Uint8List? currentImageBytes;
  String? lastErrorMessage;

  bool isLoading = false;
  bool isUpscaleLoading = false;
  bool isInpaintLoading = false;
  String inpaintStatusMessage = ""; // 인페인트 진행 상태 실시간 표시용

  int currentAnlas = 0;
  int subscriptionTier = 0;

  List<Uint8List> historyImages = [];
  List<NaiMetadata?> historyMetadata = [];
  List<bool> historyFavorites = [];
  List<String?> historyFilePaths = []; // 자동저장된 파일 경로 추적
  bool historyNeedsFullSave = false; // 인덱스 변경 시 전체 저장 필요 표시
  int selectedHistoryIndex = -1;

  List<Uint8List> i2iHistoryImages = [];
  List<NaiMetadata?> i2iHistoryMetadata = [];
  int selectedI2iHistoryIndex = -1;

  Uint8List? targetI2iImage;
  NaiMetadata? targetI2iMetadata;

  List<String> danbooruTags = [];

  double historyThumbnailScrollOffset = 0.0;
  bool scrollToThumbnailEnd = false;
  bool isHistoryGridView = false;

  int? requestedTabIndex;

  void navigateToTab(int index) {
    requestedTabIndex = index;
    notifyListeners();
  }

  void clearNavigation() {
    requestedTabIndex = null;
  }

  void parseGelbooruApi() {
    String input = gelbooruApiController.text;
    final userIdMatch = RegExp(r'user_id=([^&\s]+)').firstMatch(input);
    final apiKeyMatch = RegExp(r'api_key=([^&\s]+)').firstMatch(input);
    gelbooruUserId = userIdMatch?.group(1) ?? "";
    gelbooruApiKey = apiKeyMatch?.group(1) ?? "";
  }

  Future<void> loadInitialData() async {
    // pubspec.yaml의 version을 자동으로 읽어옴
    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
    } catch (_) {}

    // 권한: 파일 접근은 앱 전용 디렉토리 사용 (권한 불필요)
    // 커스텀 경로 저장 시 실패하면 앱 전용 폴더로 자동 대체
    await _loadTagsFromJson();
    final prefs = await SharedPreferences.getInstance();

    // SharedPreferences가 비어있으면 백업에서 복구 시도
    final hasSettings = prefs.getString('api_token') != null || prefs.getString('positive') != null;
    if (!hasSettings) {
      final recovered = await tryRecoverFromBackup();
      if (recovered) {
        debugPrint("백업에서 설정 복구 완료");
        notifyListeners();
        return;
      }
    }

    apiToken = prefs.getString('api_token') ?? "";
    apiTokenController.text = apiToken;
    // 토큰이 있으면 실제 서버에 검증 (Anlas 조회)
    if (apiToken.isNotEmpty) {
      try {
        await fetchAnlas();
        isApiConnected = currentAnlas >= 0;
      } catch (_) {
        isApiConnected = false;
      }
    } else {
      isApiConnected = false;
    }
    customSavePathController.text =
        prefs.getString('custom_save_path') ?? "/storage/emulated/0/Download";
    customFileNameController.text =
        prefs.getString('custom_file_name') ?? "Nai-{yy}{mm}{dd}-{time}-{count}";
    customWidthController.text = prefs.getString('custom_width') ?? "832";
    customHeightController.text = prefs.getString('custom_height') ?? "1216";
    conditionalRuleController.text = prefs.getString('conditional_rules') ?? "";
    conditionalTriggerMode = prefs.getString('conditionalTriggerMode') ?? "random";

    positiveController.text = prefs.getString('positive') ?? "";
    negativeController.text = prefs.getString('negative') ?? "";
    prefixController.text = prefs.getString('prefix') ?? "";
    suffixController.text = prefs.getString('suffix') ?? "";

    inpaintPositiveController.text = prefs.getString('inpaint_pos') ?? "";
    inpaintNegativeController.text = prefs.getString('inpaint_neg') ?? "";
    inpaintPrefixController.text = prefs.getString('inpaint_prefix') ?? "";
    inpaintSuffixController.text = prefs.getString('inpaint_suffix') ?? "";

    stepsController.text = prefs.getString('steps') ?? "28";
    cfgScaleController.text = prefs.getString('cfgScale') ?? "6.0";
    cfgRescaleController.text = prefs.getString('cfgRescale') ?? "0.00";
    seedController.text = prefs.getString('seed') ?? "";
    gelbooruIncludeController.text = prefs.getString('gelbooru_inc') ?? "";
    gelbooruExcludeController.text = prefs.getString('gelbooru_exc') ?? "";

    gelbooruApiController.text = prefs.getString('gelbooru_api_input') ?? "";
    parseGelbooruApi();

    ratingE = prefs.getBool('rating_e') ?? false;
    ratingQ = prefs.getBool('rating_q') ?? false;
    ratingS = prefs.getBool('rating_s') ?? false;
    ratingG = prefs.getBool('rating_g') ?? true;
    removeCharacteristics = prefs.getBool('remove_char_traits') ?? false;
    removeClothes = prefs.getBool('remove_clothes') ?? false;
    removeColors = prefs.getBool('remove_colors') ?? false;
    customRemoveController.text = prefs.getString('custom_remove') ?? "";
    isAutoSave = prefs.getBool('auto_save') ?? true;
    isRandomLocked = prefs.getBool('random_lock') ?? false;
    isFurryMode = prefs.getBool('furry') ?? false;
    isSeedLocked = prefs.getBool('seedLocked') ?? false;
    infillStrength = prefs.getDouble('infillStrength') ?? 0.7;
    isVariancePlus = prefs.getBool('variancePlus') ?? false;
    horizontalSwipeEnabled = prefs.getBool('horizontalSwipeEnabled') ?? false;
    historySlideEnabled = prefs.getBool('historySlideEnabled') ?? false;
    randomPromptAlphabetical = prefs.getBool('randomPromptAlphabetical') ?? false;
    ignoreRecommendedOrder = prefs.getBool('ignoreRecommendedOrder') ?? false;
    batchDelay = prefs.getDouble('batchDelay') ?? 0.5;
    showGenerationMessage = prefs.getBool('showGenerationMessage') ?? false;
    autoCheckUpdate = prefs.getBool('autoCheckUpdate') ?? true;
    historyTabEnabled = prefs.getBool('historyTabEnabled') ?? true;
    i2iTabEnabled = prefs.getBool('i2iTabEnabled') ?? true;
    characterTabEnabled = prefs.getBool('characterTabEnabled') ?? true;
    useCharacterPosition = prefs.getBool('useCharacterPosition') ?? true;
    wildcardTabEnabled = prefs.getBool('wildcardTabEnabled') ?? true;
    useGelbooruApiKey = prefs.getBool('useGelbooruApiKey') ?? true;
    resolutionMode = prefs.getString('resolutionMode') ?? "수동";
    final sectionOrderJson = prefs.getStringList('promptSectionOrder');
    if (sectionOrderJson != null && sectionOrderJson.length == 7) {
      promptSectionOrder = sectionOrderJson;
    }
    final collapsedJson = prefs.getStringList('collapsedSections');
    if (collapsedJson != null) {
      collapsedSections = collapsedJson.toSet();
    }
    selectedModel = prefs.getString('model') ?? "nai-diffusion-4-5-full";
    selectedSampler = prefs.getString('sampler') ?? "k_euler_ancestral";
    selectedScheduler = prefs.getString('scheduler') ?? "karras";
    selectedResolution = prefs.getString('resolution') ?? "832 x 1216";
    resolutionScale = prefs.getDouble('resolutionScale') ?? 1.0;
    if (resolutionScale != 1.5) {
      resolutionScale = 1.0;
    } // 1.0 또는 1.5만 허용
    customResolutions = prefs.getStringList('customResolutions') ?? [];

    String? charJson = prefs.getString('characters');
    if (charJson != null) {
      List<dynamic> decoded = jsonDecode(charJson);
      characters = decoded.map((e) => NaiCharacter.fromJson(e)).toList();
    }
    if (characters.isEmpty) {
      characters.add(NaiCharacter());
    }
    String? wildcardJson = prefs.getString('wildcards');
    if (wildcardJson != null) {
      List<dynamic> decoded = jsonDecode(wildcardJson);
      wildcards = decoded.map((e) => NaiWildcard.fromJson(e)).toList();
    }
    if (wildcards.isEmpty) {
      wildcards.add(NaiWildcard(name: "의상", content: "school uniform\nmaid outfit\nbikini"));
    }

    String? presetsJson = prefs.getString('presets');
    if (presetsJson != null) {
      List<dynamic> decoded = jsonDecode(presetsJson);
      presets = decoded.map((e) => NaiPreset.fromJson(e)).toList();
    }

    gelbooruPrompts = prefs.getStringList('gelbooruPrompts') ?? [];
    gelbooruTotal = gelbooruPrompts.length;
    currentPromptIndex = prefs.getInt('currentPromptIndex') ?? 0;
    if (gelbooruTotal > 0) {
      gelbooruRemaining = gelbooruTotal - currentPromptIndex;
    }

    await fetchAnlas();
    await _loadHistoryFromLocal();
    await loadReferencesFromLocal();
    notifyListeners();

    // 업데이트 체크 (조건부, 앱 시작을 블로킹하지 않음)
    if (autoCheckUpdate) {
      checkForUpdate();
    }
  }

  Future<void> _loadTagsFromJson() async {
    try {
      final String jsonString = await rootBundle.loadString('assets/tags.json');
      final List<dynamic> jsonData = jsonDecode(jsonString);

      jsonData.sort((a, b) => (b['post_count'] ?? 0).compareTo(a['post_count'] ?? 0));
      danbooruTags = jsonData.map((e) => e['tag_name'].toString()).toList();
      debugPrint("✅ 7만 개 태그 로딩 완료! 총 ${danbooruTags.length}개");
    } catch (e) {
      debugPrint("❌ 태그 파일 읽기 실패: $e");
    }
  }

  // ============================================================================
  // 설정 내보내기/가져오기
  // ============================================================================
  Future<Map<String, dynamic>> exportSettings({bool includeHistory = true}) async {
    // 히스토리 썸네일 생성 → 백그라운드 isolate로 처리
    List<Map<String, dynamic>> historyExport = [];
    if (includeHistory && historyImages.isNotEmpty) {
      historyExport = await compute(_exportHistoryIsolate, {
        'images': historyImages,
        'metadata': historyMetadata.map((m) => m?.toJson()).toList(),
        'favorites': historyFavorites,
        'filePaths': historyFilePaths,
      });
    }

    return {
      'version': currentVersion,
      'api_token': apiToken,
      'positive': positiveController.text,
      'negative': negativeController.text,
      'prefix': prefixController.text,
      'suffix': suffixController.text,
      'inpaint_pos': inpaintPositiveController.text,
      'inpaint_neg': inpaintNegativeController.text,
      'inpaint_prefix': inpaintPrefixController.text,
      'inpaint_suffix': inpaintSuffixController.text,
      'steps': stepsController.text,
      'cfgScale': cfgScaleController.text,
      'cfgRescale': cfgRescaleController.text,
      'seed': seedController.text,
      'conditional_rules': conditionalRuleController.text,
      'conditionalTriggerMode': conditionalTriggerMode,
      'gelbooru_inc': gelbooruIncludeController.text,
      'gelbooru_exc': gelbooruExcludeController.text,
      'custom_save_path': customSavePathController.text,
      'custom_file_name': customFileNameController.text,
      'custom_width': customWidthController.text,
      'custom_height': customHeightController.text,
      'custom_remove': customRemoveController.text,
      'model': selectedModel,
      'sampler': selectedSampler,
      'scheduler': selectedScheduler,
      'resolutionMode': resolutionMode,
      'promptSectionOrder': promptSectionOrder,
      'rating_e': ratingE,
      'rating_q': ratingQ,
      'rating_s': ratingS,
      'rating_g': ratingG,
      'remove_char_traits': removeCharacteristics,
      'remove_clothes': removeClothes,
      'remove_colors': removeColors,
      'auto_save': isAutoSave,
      'random_lock': isRandomLocked,
      'furry': isFurryMode,
      'seedLocked': isSeedLocked,
      'infillStrength': infillStrength,
      'variancePlus': isVariancePlus,
      'horizontalSwipeEnabled': horizontalSwipeEnabled,
      'historySlideEnabled': historySlideEnabled,
      'randomPromptAlphabetical': randomPromptAlphabetical,
      'ignoreRecommendedOrder': ignoreRecommendedOrder,
      'batchDelay': batchDelay,
      'showGenerationMessage': showGenerationMessage,
      'historyTabEnabled': historyTabEnabled,
      'i2iTabEnabled': i2iTabEnabled,
      'characterTabEnabled': characterTabEnabled,
      'useCharacterPosition': useCharacterPosition,
      'wildcardTabEnabled': wildcardTabEnabled,
      'useGelbooruApiKey': useGelbooruApiKey,
      'gelbooru_api_input': gelbooruApiController.text,
      'resolution': selectedResolution,
      'resolutionScale': resolutionScale,
      'customResolutions': customResolutions,
      'autoCheckUpdate': autoCheckUpdate,
      'collapsedSections': collapsedSections.toList(),
      'characters': characters.map((c) => c.toJson()).toList(),
      'wildcards': wildcards.map((w) => w.toJson()).toList(),
      'presets': presets.map((p) => p.toJson()).toList(),
      if (includeHistory) 'history': historyExport,
    };
  }

  static List<Map<String, dynamic>> _exportHistoryIsolate(Map<String, dynamic> params) {
    final images = params['images'] as List<Uint8List>;
    final metadata = params['metadata'] as List;
    final favorites = params['favorites'] as List<bool>;
    final filePaths = params['filePaths'] as List<String?>;

    List<Map<String, dynamic>> result = [];
    for (int i = 0; i < images.length; i++) {
      String base64Thumb;
      // 50KB 이하 = 이미 썸네일
      if (images[i].length < 50000) {
        base64Thumb = base64Encode(images[i]);
      } else {
        try {
          final decoded = img.decodeImage(images[i]);
          if (decoded != null) {
            final thumb = img.copyResize(decoded, width: 200);
            base64Thumb = base64Encode(Uint8List.fromList(img.encodeJpg(thumb, quality: 70)));
          } else {
            base64Thumb = base64Encode(images[i]);
          }
        } catch (_) {
          base64Thumb = base64Encode(images[i]);
        }
      }
      result.add({
        'image': base64Thumb,
        'metadata': i < metadata.length ? metadata[i] : null,
        'favorite': i < favorites.length ? favorites[i] : false,
        'filePath': i < filePaths.length ? filePaths[i] : null,
      });
    }
    return result;
  }

  void importSettings(Map<String, dynamic> data) {
    // API 토큰 복원
    if (data['api_token'] != null && data['api_token'].toString().isNotEmpty) {
      apiToken = data['api_token'];
      apiTokenController.text = apiToken;
      // 토큰만 복원, 연결 상태는 다음 기동 시 검증
      isApiConnected = false;
    }

    positiveController.text = data['positive'] ?? '';
    negativeController.text = data['negative'] ?? '';
    prefixController.text = data['prefix'] ?? '';
    suffixController.text = data['suffix'] ?? '';
    inpaintPositiveController.text = data['inpaint_pos'] ?? '';
    inpaintNegativeController.text = data['inpaint_neg'] ?? '';
    inpaintPrefixController.text = data['inpaint_prefix'] ?? '';
    inpaintSuffixController.text = data['inpaint_suffix'] ?? '';
    stepsController.text = data['steps'] ?? '28';
    cfgScaleController.text = data['cfgScale'] ?? '6.0';
    cfgRescaleController.text = data['cfgRescale'] ?? '0.00';
    seedController.text = data['seed'] ?? '';
    conditionalRuleController.text = data['conditional_rules'] ?? '';
    conditionalTriggerMode = data['conditionalTriggerMode'] ?? 'random';
    gelbooruIncludeController.text = data['gelbooru_inc'] ?? '';
    gelbooruExcludeController.text = data['gelbooru_exc'] ?? '';
    customSavePathController.text = data['custom_save_path'] ?? '/storage/emulated/0/Download';
    customFileNameController.text = data['custom_file_name'] ?? 'Nai-{yy}{mm}{dd}-{time}-{count}';
    customWidthController.text = data['custom_width'] ?? '832';
    customHeightController.text = data['custom_height'] ?? '1216';
    customRemoveController.text = data['custom_remove'] ?? '';
    selectedModel = data['model'] ?? 'nai-diffusion-4-5-full';
    selectedSampler = data['sampler'] ?? 'k_euler_ancestral';
    selectedScheduler = data['scheduler'] ?? 'karras';
    resolutionMode = data['resolutionMode'] ?? '수동';
    if (data['promptSectionOrder'] != null) {
      promptSectionOrder = List<String>.from(data['promptSectionOrder']);
    }
    ratingE = data['rating_e'] ?? false;
    ratingQ = data['rating_q'] ?? false;
    ratingS = data['rating_s'] ?? false;
    ratingG = data['rating_g'] ?? true;
    removeCharacteristics = data['remove_char_traits'] ?? false;
    removeClothes = data['remove_clothes'] ?? false;
    removeColors = data['remove_colors'] ?? false;
    isAutoSave = data['auto_save'] ?? true;
    isRandomLocked = data['random_lock'] ?? false;
    isFurryMode = data['furry'] ?? false;
    isSeedLocked = data['seedLocked'] ?? false;
    infillStrength = (data['infillStrength'] ?? 0.7).toDouble();
    isVariancePlus = data['variancePlus'] ?? false;
    horizontalSwipeEnabled = data['horizontalSwipeEnabled'] ?? false;
    historySlideEnabled = data['historySlideEnabled'] ?? false;
    randomPromptAlphabetical = data['randomPromptAlphabetical'] ?? false;
    ignoreRecommendedOrder = data['ignoreRecommendedOrder'] ?? false;
    batchDelay = (data['batchDelay'] ?? 0.5).toDouble();
    showGenerationMessage = data['showGenerationMessage'] ?? false;
    historyTabEnabled = data['historyTabEnabled'] ?? true;
    i2iTabEnabled = data['i2iTabEnabled'] ?? true;
    characterTabEnabled = data['characterTabEnabled'] ?? true;
    useCharacterPosition = data['useCharacterPosition'] ?? true;
    // 구버전 백업 호환: vibe/precise가 설정 파일에 있으면 불러옴 (현재는 references.json에 별도 저장)
    bool hadRefs = false;
    if (data['vibeTransfers'] != null) {
      vibeTransfers = (data['vibeTransfers'] as List).map((e) {
        final m = Map<String, dynamic>.from(e);
        if (m['strength'] != null) {
          m['strength'] = (m['strength'] as num).toDouble();
        }
        if (m['infoExtracted'] != null) {
          m['infoExtracted'] = (m['infoExtracted'] as num).toDouble();
        }
        if (m['_encodedInfoExt'] != null) {
          m['_encodedInfoExt'] = (m['_encodedInfoExt'] as num).toDouble();
        }
        return m;
      }).toList();
      hadRefs = true;
    }
    if (data['preciseRefs'] != null) {
      preciseRefs = (data['preciseRefs'] as List).map((e) {
        final m = Map<String, dynamic>.from(e);
        if (m['strength'] != null) {
          m['strength'] = (m['strength'] as num).toDouble();
        }
        if (m['fidelity'] != null) {
          m['fidelity'] = (m['fidelity'] as num).toDouble();
        }
        return m;
      }).toList();
      hadRefs = true;
    }
    if (hadRefs) {
      saveReferencesToLocal();
    }
    wildcardTabEnabled = data['wildcardTabEnabled'] ?? true;
    historyTabEnabled = data['historyTabEnabled'] ?? true;
    i2iTabEnabled = data['i2iTabEnabled'] ?? true;
    useGelbooruApiKey = data['useGelbooruApiKey'] ?? true;
    if (data['gelbooru_api_input'] != null) {
      gelbooruApiController.text = data['gelbooru_api_input'];
      parseGelbooruApi();
    }
    if (data['resolution'] != null) {
      selectedResolution = data['resolution'];
    }
    resolutionScale = (data['resolutionScale'] ?? 1.0).toDouble();
    if (resolutionScale != 1.5) {
      resolutionScale = 1.0;
    }
    if (data['customResolutions'] != null) {
      customResolutions = List<String>.from(data['customResolutions']);
    }
    if (data['autoCheckUpdate'] != null) {
      autoCheckUpdate = data['autoCheckUpdate'];
    }
    if (data['collapsedSections'] != null) {
      collapsedSections = Set<String>.from(data['collapsedSections']);
    }

    if (data['characters'] != null) {
      characters = (data['characters'] as List).map((e) => NaiCharacter.fromJson(e)).toList();
      if (characters.isEmpty) {
        characters.add(NaiCharacter());
      }
    }
    if (data['wildcards'] != null) {
      wildcards = (data['wildcards'] as List).map((e) => NaiWildcard.fromJson(e)).toList();
    }
    if (data['presets'] != null) {
      presets = (data['presets'] as List).map((e) => NaiPreset.fromJson(e)).toList();
    }

    // 히스토리 복원 (썸네일 base64 → Uint8List)
    if (data['history'] != null) {
      final historyData = data['history'] as List;
      historyImages.clear();
      historyMetadata.clear();
      historyFavorites.clear();
      historyFilePaths.clear();

      for (final item in historyData) {
        try {
          final imageBase64 = item['image'] as String?;
          if (imageBase64 != null) {
            historyImages.add(base64Decode(imageBase64));
            historyMetadata.add(
              item['metadata'] != null ? NaiMetadata.fromJson(item['metadata']) : null,
            );
            historyFavorites.add(item['favorite'] ?? false);
            historyFilePaths.add(item['filePath'] as String?);
          }
        } catch (_) {
          // 손상된 항목 건너뛰기
        }
      }

      if (historyImages.isNotEmpty) {
        selectedHistoryIndex = historyImages.length - 1;
      }
      _fullSaveHistoryToLocal();
    }

    saveAllSettings();
    notifyListeners();
  }

  Future<void> saveAllSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_token', apiTokenController.text);
      await prefs.setString('custom_save_path', customSavePathController.text);
      await prefs.setString('custom_file_name', customFileNameController.text);
      await prefs.setString('custom_width', customWidthController.text);
      await prefs.setString('custom_height', customHeightController.text);
      await prefs.setString('conditional_rules', conditionalRuleController.text);
      await prefs.setString('conditionalTriggerMode', conditionalTriggerMode);

      await prefs.setString('positive', positiveController.text);
      await prefs.setString('negative', negativeController.text);
      await prefs.setString('prefix', prefixController.text);
      await prefs.setString('suffix', suffixController.text);

      await prefs.setString('inpaint_pos', inpaintPositiveController.text);
      await prefs.setString('inpaint_neg', inpaintNegativeController.text);
      await prefs.setString('inpaint_prefix', inpaintPrefixController.text);
      await prefs.setString('inpaint_suffix', inpaintSuffixController.text);

      await prefs.setString('steps', stepsController.text);
      await prefs.setString('cfgScale', cfgScaleController.text);
      await prefs.setString('cfgRescale', cfgRescaleController.text);
      await prefs.setString('seed', seedController.text);
      await prefs.setString('gelbooru_inc', gelbooruIncludeController.text);
      await prefs.setString('gelbooru_exc', gelbooruExcludeController.text);
      await prefs.setString('gelbooru_api_input', gelbooruApiController.text);
      await prefs.setBool('rating_e', ratingE);
      await prefs.setBool('rating_q', ratingQ);
      await prefs.setBool('rating_s', ratingS);
      await prefs.setBool('rating_g', ratingG);
      await prefs.setBool('remove_char_traits', removeCharacteristics);
      await prefs.setBool('remove_clothes', removeClothes);
      await prefs.setBool('remove_colors', removeColors);
      await prefs.setString('custom_remove', customRemoveController.text);
      await prefs.setBool('auto_save', isAutoSave);
      await prefs.setBool('random_lock', isRandomLocked);
      await prefs.setBool('furry', isFurryMode);
      await prefs.setBool('seedLocked', isSeedLocked);
      await prefs.setDouble('infillStrength', infillStrength);
      await prefs.setBool('variancePlus', isVariancePlus);
      await prefs.setBool('horizontalSwipeEnabled', horizontalSwipeEnabled);
      await prefs.setBool('historySlideEnabled', historySlideEnabled);
      await prefs.setBool('randomPromptAlphabetical', randomPromptAlphabetical);
      await prefs.setBool('ignoreRecommendedOrder', ignoreRecommendedOrder);
      await prefs.setDouble('batchDelay', batchDelay);
      await prefs.setBool('showGenerationMessage', showGenerationMessage);
      await prefs.setBool('autoCheckUpdate', autoCheckUpdate);
      await prefs.setBool('historyTabEnabled', historyTabEnabled);
      await prefs.setBool('i2iTabEnabled', i2iTabEnabled);
      await prefs.setBool('characterTabEnabled', characterTabEnabled);
      await prefs.setBool('useCharacterPosition', useCharacterPosition);
      await prefs.setBool('wildcardTabEnabled', wildcardTabEnabled);
      await prefs.setStringList('promptSectionOrder', promptSectionOrder);
      await prefs.setStringList('collapsedSections', collapsedSections.toList());
      await prefs.setBool('useGelbooruApiKey', useGelbooruApiKey);
      await prefs.setString('resolutionMode', resolutionMode);
      await prefs.setString('model', selectedModel);
      await prefs.setString('sampler', selectedSampler);
      await prefs.setString('scheduler', selectedScheduler);
      await prefs.setString('resolution', selectedResolution);
      await prefs.setDouble('resolutionScale', resolutionScale);
      await prefs.setStringList('customResolutions', customResolutions);
      await prefs.setString('characters', jsonEncode(characters.map((e) => e.toJson()).toList()));
      await prefs.setString('wildcards', jsonEncode(wildcards.map((e) => e.toJson()).toList()));
      await prefs.setString('presets', jsonEncode(presets.map((e) => e.toJson()).toList()));
      await prefs.setStringList('gelbooruPrompts', gelbooruPrompts);
      await prefs.setInt('currentPromptIndex', currentPromptIndex);

      // 설정 백업 파일 저장 (SharedPreferences 손실 방지)
      await _saveSettingsBackup();
    } catch (e) {
      debugPrint("설정 저장 실패: $e");
    }
  }

  // ============================================================================
  // 설정 백업/복구 (SharedPreferences 손실 방지)
  // ============================================================================
  Future<void> _saveSettingsBackup() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/settings_backup.json');
      // exportSettings에서 히스토리 제외 (용량 절약 + 빠른 저장)
      final data = await exportSettings(includeHistory: false);
      data['backup_time'] = DateTime.now().toIso8601String();
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<bool> tryRecoverFromBackup() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/settings_backup.json');
      if (!file.existsSync()) {
        return false;
      }

      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // importSettings로 전부 복원 (히스토리는 별도 로컬 저장소에서 복구)
      importSettings(data);
      debugPrint("설정 백업에서 복구 성공 (백업 시간: ${data['backup_time'] ?? '알 수 없음'})");
      return true;
    } catch (e) {
      debugPrint("백업 복구 실패: $e");
      return false;
    }
  }

  void refreshUI() => notifyListeners();

  // ============================================================================
  // 프리셋용 설정 스냅샷
  // ============================================================================
  Map<String, dynamic> getSettingsSnapshot() {
    return {
      'steps': stepsController.text,
      'cfg': cfgScaleController.text,
      'cfgRescale': cfgRescaleController.text,
      'seed': seedController.text,
      'sampler': selectedSampler,
      'scheduler': selectedScheduler,
      'model': selectedModel,
      'resolution': selectedResolution,
      'seedLocked': isSeedLocked,
      'variancePlus': isVariancePlus,
    };
  }

  void applySettingsSnapshot(Map<String, dynamic> s) {
    if (s['steps'] != null) {
      stepsController.text = s['steps'];
    }
    if (s['cfg'] != null) {
      cfgScaleController.text = s['cfg'];
    }
    if (s['cfgRescale'] != null) {
      cfgRescaleController.text = s['cfgRescale'];
    }
    if (s['seed'] != null) {
      seedController.text = s['seed'];
    }
    if (s['sampler'] != null) {
      selectedSampler = s['sampler'];
    }
    if (s['scheduler'] != null) {
      selectedScheduler = s['scheduler'];
    }
    if (s['model'] != null) {
      selectedModel = s['model'];
    }
    if (s['resolution'] != null) {
      selectedResolution = s['resolution'];
    }
    if (s['seedLocked'] != null) {
      isSeedLocked = s['seedLocked'];
    }
    if (s['variancePlus'] != null) {
      isVariancePlus = s['variancePlus'];
    }
  }

  void sendToI2i(Uint8List imageBytes, NaiMetadata? metadata) {
    targetI2iImage = imageBytes;
    targetI2iMetadata = metadata;
    // i2i 탭이 꺼져 있으면 자동으로 켜기
    if (!i2iTabEnabled) {
      i2iTabEnabled = true;
      saveAllSettings();
    }
    notifyListeners();
  }

  // {A|B|C} 형식 → ~A, ~B, ~C (OR 검색)
  // *keyword 형식 → 해당 키워드가 포함된 태그들을 OR 검색 (상위 20개)
  String _expandWildcardForSearch(String input) {
    // 1단계: {A|B|C} → ~A, ~B, ~C
    String result = input.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
      final options = match.group(1)!.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty);
      return options.map((o) => '~$o').join(', ');
    });

    // 2단계: *keyword → ~tag1, ~tag2, ... (태그 DB에서 매칭)
    final tags = result.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    List<String> expanded = [];

    for (final tag in tags) {
      if (tag.startsWith('*') && tag.length > 1) {
        final keyword = tag.substring(1).toLowerCase().replaceAll(' ', '_');
        final matches = danbooruTags
            .where((t) => t.contains(keyword))
            .take(20)
            .map((t) => '~${t.replaceAll('_', ' ')}')
            .toList();
        if (matches.isNotEmpty) {
          expanded.addAll(matches);
        } else {
          expanded.add(keyword.replaceAll('_', ' '));
        }
      } else {
        expanded.add(tag);
      }
    }

    return expanded.join(', ');
  }

  // 제외 태그 확장 (~ 없이, 로컬 필터링용)
  List<String> _expandExcludeForSearch(String input) {
    List<String> result = [];

    // {A|B|C} → A, B, C (전부 제외 대상)
    String flattened = input.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
      return match.group(1)!.split('|').map((e) => e.trim()).join(', ');
    });

    final tags = flattened.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    for (final tag in tags) {
      if (tag.startsWith('*') && tag.length > 1) {
        final keyword = tag.substring(1).toLowerCase().replaceAll(' ', '_');
        final matches = danbooruTags
            .where((t) => t.contains(keyword))
            .take(50) // 제외는 넉넉하게 50개
            .toList();
        if (matches.isNotEmpty) {
          result.addAll(matches);
        } else {
          result.add(keyword);
        }
      } else {
        result.add(tag.replaceAll(' ', '_'));
      }
    }

    return result;
  }

  Future<void> handleGelbooruSearch(BuildContext context) async {
    isGelbooruLoading = true;
    gelbooruPrompts.clear();
    gelbooruTotal = 0;
    gelbooruRemaining = 0;
    currentPromptIndex = 0;
    notifyListeners();

    parseGelbooruApi();

    try {
      // 포함: {A|B} → ~A, ~B / *keyword → 매칭 태그 OR
      final expandedInclude = _expandWildcardForSearch(gelbooruIncludeController.text);
      // 제외: 로컬 후처리용 (API 태그 제한 회피 + 정확한 필터링)
      final localExcludeTags = _expandExcludeForSearch(gelbooruExcludeController.text);
      debugPrint("🔍 검색: $expandedInclude / 제외(${localExcludeTags.length}개): $localExcludeTags");

      List<String> results = await _service.fetchDanbooruTags(
        includeTags: expandedInclude,
        excludeTags: '', // API에 제외 태그 안 보냄
        localExcludeTags: localExcludeTags, // 로컬 후처리
        rG: ratingG,
        rS: ratingS,
        rQ: ratingQ,
        rE: ratingE,
        removeCharacteristics: removeCharacteristics,
        removeClothes: removeClothes,
        gelbooruUserId: gelbooruUserId,
        gelbooruApiKey: gelbooruApiKey,
      );
      isGelbooruLoading = false;

      if (!context.mounted) {
        return;
      }

      if (results.isNotEmpty) {
        results.shuffle();
        gelbooruPrompts = results;
        gelbooruTotal = results.length;
        gelbooruRemaining = gelbooruTotal;
        saveAllSettings();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("${results.length}개의 프롬프트를 찾았습니다."),
          ),
        );
      } else {
        _showSearchErrorDialog(
          context,
          "조건에 맞는 결과가 없습니다.",
          "포함 태그: ${gelbooruIncludeController.text}\n\n"
              "가능한 원인:\n"
              "• 태그 조합에 맞는 이미지가 없음\n"
              "• 레이팅 필터가 너무 제한적\n"
              "• 태그 이름 오타 확인",
        );
      }
    } catch (e) {
      isGelbooruLoading = false;
      if (!context.mounted) {
        return;
      }

      String errorMsg = e.toString().replaceFirst('Exception: ', '');
      String title;
      String detail;

      if (errorMsg.contains('시간 초과')) {
        title = "서버 응답 없음";
        detail =
            "Gelbooru 서버가 응답하지 않습니다.\n\n$errorMsg\n\n"
            "가능한 원인:\n"
            "• Gelbooru 서버 점검/장애\n"
            "• 인터넷 연결 불안정\n"
            "• 프록시 서버 문제";
      } else if (errorMsg.contains('서버 오류') || errorMsg.contains('서버 응답 코드')) {
        title = "서버 오류";
        detail =
            "Gelbooru 서버에서 오류가 발생했습니다.\n\n$errorMsg\n\n"
            "가능한 원인:\n"
            "• Gelbooru 서버 일시적 장애\n"
            "• API 키 오류\n"
            "• 요청 횟수 초과";
      } else if (errorMsg.contains('연결 실패') || errorMsg.contains('SocketException')) {
        title = "연결 실패";
        detail =
            "서버에 연결할 수 없습니다.\n\n$errorMsg\n\n"
            "가능한 원인:\n"
            "• 인터넷 연결 끊김\n"
            "• 방화벽/VPN 차단\n"
            "• 프록시 서버 다운";
      } else {
        title = "검색 실패";
        detail = "알 수 없는 오류가 발생했습니다.\n\n$errorMsg";
      }

      _showSearchErrorDialog(context, title, detail);
    }
    notifyListeners();
  }

  void _showSearchErrorDialog(BuildContext context, String title, String detail) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 24),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            detail,
            style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              "확인",
              style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  String _sortNovelAIPrompt(String prompt) {
    List<String> tags = prompt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    // NovelAI 권장 순서 무시: 그룹 분류 없이 전체 처리
    if (ignoreRecommendedOrder) {
      if (randomPromptAlphabetical) {
        // 알파벳 순서
        tags.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      } else {
        // 랜덤 섞기
        tags.shuffle();
      }
      return tags.join(', ');
    }

    List<String> gPerson = []; // 1. 인원수 (1girl, 2boys)
    List<String> gSolo = []; // 2. solo 계열
    List<String> gFrom = []; // 3. 시점 (from ~)
    List<String> gLooking = []; // 4. 시선 (looking ~)
    List<String> gComposition = []; // 5. 신체 구도/시점
    List<String> gRest = []; // 6. 나머지 (알파벳 정렬 대상)
    List<String> gBackground = []; // 7. 배경

    final personRegex = RegExp(r'^(\d+|\d+\+)\s?(girl|girls|boy|boys)$');

    // 신체 구도/시점 태그 (맨 앞쪽 고정)
    const compositionTags = {
      'full body',
      'upper body',
      'lower body',
      'cowboy shot',
      'portrait',
      'close-up',
      'feet out of frame',
      'wide shot',
      'dutch angle',
      'straight-on',
      'pov',
    };

    for (String tag in tags) {
      String lowerTag = tag.toLowerCase();

      if (personRegex.hasMatch(lowerTag) ||
          lowerTag == 'multiple girls' ||
          lowerTag == 'multiple boys') {
        gPerson.add(tag);
      } else if (lowerTag == 'solo' || lowerTag == 'solo focus') {
        gSolo.add(tag);
      } else if (lowerTag.startsWith('from ')) {
        gFrom.add(tag);
      } else if (lowerTag.startsWith('looking ')) {
        gLooking.add(tag);
      } else if (compositionTags.contains(lowerTag)) {
        gComposition.add(tag);
      } else if (lowerTag.contains('background')) {
        gBackground.add(tag);
      } else {
        gRest.add(tag);
      }
    }

    // 알파벳 순서 옵션이 켜져있으면 나머지 그룹만 정렬 (고정 그룹은 제외)
    if (randomPromptAlphabetical) {
      gRest.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    List<String> sortedTags = [
      ...gPerson,
      ...gSolo,
      ...gFrom,
      ...gLooking,
      ...gComposition,
      ...gRest,
      ...gBackground,
    ];
    return sortedTags.join(', ');
  }

  void _processAndSetPrompt(int targetIndex) {
    if (gelbooruPrompts.isEmpty) {
      return;
    }
    String nextRawData = gelbooruPrompts[targetIndex];
    String tagString = "";
    String rating = "g";

    try {
      Map<String, dynamic> parsed = jsonDecode(nextRawData);
      tagString = parsed['tags'] ?? "";
      currentImageWidth = parsed['width'] ?? 0;
      currentImageHeight = parsed['height'] ?? 0;
      rating = parsed['rating']?.toString() ?? "g";
      // Gelbooru는 "general", "sensitive", "questionable", "explicit" 풀 단어를 반환
      // 조건부 트리거에서 g/s/q/e 단일 문자로 비교하므로 정규화
      if (rating.length > 1) {
        rating = rating.substring(0, 1);
      }
    } catch (e) {
      tagString = nextRawData;
      currentImageWidth = 0;
      currentImageHeight = 0;
      rating = "g";
    }

    tagString = tagString
        .replaceAll('&#39;', "'")
        .replaceAll('&#039;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');

    List<String> rawTags = tagString.split(',').map((e) => e.trim()).toList();
    List<String> customRules = customRemoveController.text
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    List<String> cleanTags = [];

    for (String t in rawTags) {
      String cleanTag = t.replaceAll('_', ' ');
      if (t.contains('(') || t.contains(')')) {
        continue;
      }
      if (TagFilters.commonGarbage.contains(t) || TagFilters.commonGarbage.contains(cleanTag)) {
        continue;
      }
      if (removeCharacteristics &&
          (TagFilters.characterTraits.contains(t) ||
              TagFilters.characterTraits.contains(cleanTag))) {
        continue;
      }
      if (removeClothes &&
          (TagFilters.clothesTags.contains(t) || TagFilters.clothesTags.contains(cleanTag))) {
        continue;
      }
      if (removeColors) {
        bool hasColor = false;
        for (final keyword in TagFilters.colorKeywords) {
          if (cleanTag.contains(keyword) || t.contains(keyword)) {
            hasColor = true;
            break;
          }
        }
        if (hasColor) {
          continue;
        }
      }

      bool shouldRemove = false;
      for (String rule in customRules) {
        if (rule.startsWith('*') && rule.endsWith('*') && rule.length > 2) {
          if (t.contains(rule.substring(1, rule.length - 1))) {
            shouldRemove = true;
          }
        } else if (rule.startsWith('*') && rule.length > 1) {
          if (t.endsWith(rule.substring(1))) {
            shouldRemove = true;
          }
        } else if (rule.endsWith('*') && rule.length > 1) {
          if (t.startsWith(rule.substring(0, rule.length - 1))) {
            shouldRemove = true;
          }
        } else {
          if (t == rule || cleanTag == rule) {
            shouldRemove = true;
          }
        }
      }
      if (shouldRemove) {
        continue;
      }
      cleanTags.add(t);
    }

    String prefixText = prefixController.text;
    String suffixText = suffixController.text;
    List<String> fixedTags = "$prefixText,$suffixText"
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();

    List<String> filteredTags = cleanTags
        .where((tag) => !fixedTags.contains(tag.toLowerCase()))
        .toList();

    String combined = filteredTags.join(', ');

    // 조건부 트리거가 "random" 모드일 때만 여기서 적용
    String finalConditioned = conditionalTriggerMode == "random"
        ? _applyConditionalRules(combined, rating)
        : combined;
    String finalSorted = _sortNovelAIPrompt(finalConditioned);

    positiveController.text = finalSorted;
  }

  void handleNextPrompt() {
    if (gelbooruPrompts.isEmpty) {
      return;
    }
    _processAndSetPrompt(currentPromptIndex);
    currentPromptIndex = (currentPromptIndex + 1) % gelbooruPrompts.length;
    gelbooruRemaining = gelbooruPrompts.length - currentPromptIndex;
    if (gelbooruRemaining == 0) {
      gelbooruRemaining = gelbooruPrompts.length;
    }
    saveAllSettings();
    notifyListeners();
  }

  void reloadCurrentPrompt() {
    if (gelbooruPrompts.isEmpty) {
      return;
    }
    int targetIndex = currentPromptIndex - 1;
    if (targetIndex < 0) {
      targetIndex = gelbooruPrompts.length - 1;
    }
    _processAndSetPrompt(targetIndex);
    saveAllSettings();
    notifyListeners();
  }

  String _processPipeOptions(String prompt) {
    // "a|b|c," → 셋 중 하나를 랜덤 선택. 쉼표 또는 줄끝 앞의 word|word 패턴 처리
    final RegExp pipeRegex = RegExp(r'([\w \t][^\n,|]*(?:\|[^\n,|]+)+)(?=[,\n]|$)');
    return prompt.replaceAllMapped(pipeRegex, (match) {
      final List<String> options = match
          .group(0)!
          .split('|')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (options.length < 2) {
        return match.group(0)!;
      }
      return options[Random().nextInt(options.length)];
    });
  }

  String _processWildcards(String prompt) {
    String result = _processPipeOptions(prompt);
    final RegExp regex = RegExp(r'__(.+?)__');
    int depth = 0;
    while (regex.hasMatch(result) && depth < 5) {
      result = result.replaceAllMapped(regex, (match) {
        String wName = match.group(1)!;
        var wcList = wildcards.where((e) => e.name == wName);
        if (wcList.isEmpty) {
          return match.group(0)!;
        }

        List<String> options = wcList.first.content
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

        if (options.isEmpty) {
          return match.group(0)!;
        }

        List<Map<String, dynamic>> weightedOptions = [];
        int totalWeight = 0;
        final weightRegex = RegExp(r'^(\d+)\)(.*)$');

        for (String opt in options) {
          int weight = 100;
          String text = opt;
          final m = weightRegex.firstMatch(opt);
          if (m != null) {
            weight = int.tryParse(m.group(1)!) ?? 100;
            text = m.group(2)!.trim();
          }
          if (weight > 0 && text.isNotEmpty) {
            weightedOptions.add({'weight': weight, 'text': text});
            totalWeight += weight;
          }
        }

        if (weightedOptions.isEmpty) {
          return match.group(0)!;
        }

        int randomVal = Random().nextInt(totalWeight);
        int currentSum = 0;
        for (var item in weightedOptions) {
          currentSum += item['weight'] as int;
          if (randomVal < currentSum) {
            return item['text'] as String;
          }
        }
        return weightedOptions.last['text'] as String;
      });
      result = _processPipeOptions(result);
      depth++;
    }
    return result;
  }

  // ============================================================================
  // 조건부 트리거: 재귀 하강 파서 (중첩 괄호 지원)
  // 문법: expr = or_expr
  //        or_expr = and_expr ('|' and_expr)*
  //        and_expr = atom ('&' atom)*
  //        atom = '!' atom | '(' or_expr ')' | pattern
  // 예시: A&(B|C)&D = A 그리고 (B 또는 C) 그리고 D
  // ============================================================================
  bool _evaluateCondition(String condStr, List<String> tags, String rating) {
    final parser = _ConditionParser(condStr, tags, rating, this);
    return parser.parseOrExpr();
  }

  bool _matchAtom(String pattern, List<String> tags, String rating) {
    bool negate = pattern.startsWith('!');
    if (negate) {
      pattern = pattern.substring(1);
    }

    bool matched;
    if (pattern == 'g' || pattern == 's' || pattern == 'q' || pattern == 'e') {
      matched = (rating.toLowerCase() == pattern.toLowerCase());
    } else {
      matched = tags.any((tag) => _isMatch(tag, pattern));
    }

    return negate ? !matched : matched;
  }

  bool _isMatch(String tag, String pattern) {
    if (pattern.startsWith('*') && pattern.endsWith('*') && pattern.length > 2) {
      return tag.contains(pattern.substring(1, pattern.length - 1));
    } else if (pattern.startsWith('*') && pattern.length > 1) {
      return tag.endsWith(pattern.substring(1));
    } else if (pattern.endsWith('*') && pattern.length > 1) {
      return tag.startsWith(pattern.substring(0, pattern.length - 1));
    } else {
      return tag == pattern;
    }
  }

  String _applyConditionalRules(String prompt, String rating) {
    if (conditionalRuleController.text.trim().isEmpty) {
      return prompt;
    }
    List<String> tags = prompt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    List<String> rules = conditionalRuleController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('#'))
        .toList();

    for (String ruleStr in rules) {
      if (!ruleStr.startsWith('(')) {
        continue;
      }

      // 매칭되는 닫는 괄호 찾기 (중첩 괄호 지원)
      int depth = 0;
      int sepIdx = -1;
      for (int i = 0; i < ruleStr.length; i++) {
        if (ruleStr[i] == '(') {
          depth++;
        } else if (ruleStr[i] == ')') {
          depth--;
          if (depth == 0) {
            // '):' 패턴 확인
            if (i + 1 < ruleStr.length && ruleStr[i + 1] == ':') {
              sepIdx = i;
            }
            break;
          }
        }
      }
      if (sepIdx == -1) {
        continue;
      }

      String condStr = ruleStr.substring(1, sepIdx);
      String actionStr = ruleStr.substring(sepIdx + 2);

      // 재귀 하강 파서로 조건 평가
      bool conditionMet = _evaluateCondition(condStr, tags, rating);

      if (conditionMet) {
        if (actionStr.startsWith('prefix=')) {
          String b = actionStr.substring(7).trim();
          if (!tags.contains(b)) {
            tags.insert(0, b);
          }
        } else if (actionStr.startsWith('suffix=')) {
          String b = actionStr.substring(7).trim();
          if (!tags.contains(b)) {
            tags.add(b);
          }
        } else if (actionStr.contains('^')) {
          int idx = actionStr.indexOf('^');
          String a = actionStr.substring(0, idx).trim();
          String b = actionStr.substring(idx + 1).trim();
          String literalA = a.replaceAll('*', '');
          String literalB = b.replaceAll('*', '');

          for (int i = 0; i < tags.length; i++) {
            if (_isMatch(tags[i], a)) {
              if (literalA.isNotEmpty) {
                tags[i] = tags[i].replaceAll(literalA, literalB);
              } else {
                tags[i] = b;
              }
            }
          }
        } else if (actionStr.contains('=')) {
          int eqIdx = actionStr.indexOf('=');
          String a = actionStr.substring(0, eqIdx).trim();
          String b = actionStr.substring(eqIdx + 1).trim();

          for (int i = 0; i < tags.length; i++) {
            if (_isMatch(tags[i], a)) {
              tags[i] = b;
            }
          }
        }
      }
    }
    return tags.toSet().join(', ');
  }

  Future<void> handleGenerate(BuildContext context, VoidCallback onScrollToHistoryEnd) async {
    if (!isApiConnected) {
      return;
    }
    if (!isSeedLocked || seedController.text.isEmpty) {
      seedController.text = Random().nextInt(4294967296).toString();
    }
    isLoading = true;
    lastErrorMessage = null;
    notifyListeners();
    await saveAllSettings();
    int width = 832;
    int height = 1216;

    if (resolutionMode == "랜덤") {
      List<String> randomList = [
        "1344 x 768",
        "1216 x 832",
        "1152 x 896",
        "1088 x 960",
        "1024 x 1024",
        "960 x 1088",
        "896 x 1152",
        "832 x 1216",
        "768 x 1344",
      ];
      String rndRes = randomList[Random().nextInt(randomList.length)];
      List<String> resParts = rndRes.replaceAll(" ", "").split("x");
      width = int.parse(resParts[0]);
      height = int.parse(resParts[1]);
    } else if (resolutionMode == "자동" && currentImageWidth > 0 && currentImageHeight > 0) {
      double maxPixels = 1048576.0;
      double ratio = currentImageWidth / currentImageHeight;
      double h = sqrt(maxPixels / ratio);
      double w = h * ratio;
      width = (w / 64).round() * 64;
      height = (h / 64).round() * 64;
      while (width * height > 1048576) {
        if (width > height) {
          width -= 64;
        } else {
          height -= 64;
        }
      }
      if (width < 64) {
        width = 64;
      }
      if (height < 64) {
        height = 64;
      }
    } else if (selectedResolution == "직접 입력" ||
        (resolutionMode == "자동" && currentImageWidth == 0)) {
      width = int.tryParse(customWidthController.text) ?? 832;
      height = int.tryParse(customHeightController.text) ?? 1216;
    } else {
      List<String> resParts = selectedResolution.replaceAll(" ", "").split("x");
      width = int.parse(resParts[0]);
      height = int.parse(resParts[1]);
    }

    // 해상도 배율 적용
    if (resolutionScale != 1.0) {
      width = ((width * resolutionScale) / 64).round() * 64;
      height = ((height * resolutionScale) / 64).round() * 64;
    }

    // 64px 단위 정렬 (NovelAI 필수 요구사항)
    width = ((width / 64).round() * 64).clamp(64, 9999);
    height = ((height / 64).round() * 64).clamp(64, 9999);

    // NovelAI 최대 픽셀 수 제한 (3,145,728px ≈ 1536×2048)
    const int maxPixels = 3145728;
    while (width * height > maxPixels) {
      if (width > height) {
        width -= 64;
      } else {
        height -= 64;
      }
    }

    String combined =
        "${prefixController.text},${positiveController.text},${suffixController.text}";
    String step1 = _processWildcards(combined);

    // 조건부 트리거가 "generate" 모드면 합쳐진 프롬프트에 적용
    if (conditionalTriggerMode == "generate") {
      // 프롬프트에서 등급 추출 (g/s/q/e 태그가 있으면 사용, 없으면 g)
      String rating = "g";
      final lower = step1.toLowerCase();
      if (lower.contains("explicit")) {
        rating = "e";
      } else if (lower.contains("questionable")) {
        rating = "q";
      } else if (lower.contains("sensitive")) {
        rating = "s";
      }
      step1 = _applyConditionalRules(step1, rating);
    }

    String finalPrompt = _service.sanitizePrompt(step1);
    String finalNegative = _service.sanitizePrompt(_processWildcards(negativeController.text));

    List<Map<String, dynamic>> processedCharacters = characters.where((char) => char.isActive).map((
      char,
    ) {
      Map<String, dynamic> charJson = char.toJson();
      if (charJson.containsKey('positive')) {
        charJson['positive'] = _processWildcards(charJson['positive'].toString());
      }
      if (charJson.containsKey('negative')) {
        charJson['negative'] = _processWildcards(charJson['negative'].toString());
      }
      return charJson;
    }).toList();

    bool bgInitialized = false;
    if (Platform.isAndroid) {
      try {
        bgInitialized = await FlutterBackground.initialize(
          androidConfig: const FlutterBackgroundAndroidConfig(
            notificationTitle: "NovelAI 이미지 생성 중",
            notificationText: "백그라운드에서 안전하게 통신 중입니다...",
            notificationImportance: AndroidNotificationImportance.normal,
            notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
          ),
        );
        if (bgInitialized) {
          await FlutterBackground.enableBackgroundExecution();
        }
      } catch (e) {
        debugPrint("백그라운드 실행 권한이 없거나 오류 발생: $e");
      }
    }

    try {
      final result = await _service.generateImage(
        positive: finalPrompt,
        negative: finalNegative,
        token: apiToken,
        model: selectedModel,
        steps: int.tryParse(stepsController.text) ?? 28,
        sampler: selectedSampler,
        scheduler: selectedScheduler,
        isFurry: isFurryMode,
        width: width,
        height: height,
        cfgScale: double.tryParse(cfgScaleController.text) ?? 6.0,
        cfgRescale: double.tryParse(cfgRescaleController.text) ?? 0.0,
        seed: int.tryParse(seedController.text) ?? 0,
        characters: processedCharacters,
        variancePlus: isVariancePlus,
        useCharacterPosition: useCharacterPosition,
        vibeTransfers:
            (vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).isNotEmpty &&
                preciseRefs.where((r) => (r['enabled'] as bool?) ?? true).isEmpty)
            ? vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList()
            : null,
        preciseRefs: preciseRefs.where((r) => (r['enabled'] as bool?) ?? true).toList().isNotEmpty
            ? preciseRefs.where((r) => (r['enabled'] as bool?) ?? true).toList()
            : null,
      );

      isLoading = false;
      currentImageBytes = result.image ?? currentImageBytes;
      lastErrorMessage = result.error;

      if (result.image != null) {
        sessionGenerateCount++;
        // 인코딩 캐시가 갱신됐을 수 있으니 저장
        saveReferencesToLocal();

        NaiMetadata? parsedMeta = extractNovelAIMetadata(result.image!);
        if (parsedMeta != null) {
          parsedMeta = parsedMeta.copyWithExtra({'variety_plus': isVariancePlus});
        }

        await addImageToHistory(
          image: result.image!,
          metadata: parsedMeta,
          context: context.mounted ? context : null,
        );

        if (!isHistoryGridView) {
          onScrollToHistoryEnd();
        }
      }

      await fetchAnlas();
    } finally {
      if (bgInitialized && Platform.isAndroid) {
        try {
          await FlutterBackground.disableBackgroundExecution();
        } catch (_) {}
      }
      isLoading = false;
      notifyListeners();
    }
  }

  // ============================================================================
  // 배치 생성 (연속 생성)
  // ============================================================================
  void cancelBatch() {
    batchRemaining = 0;
    isBatchMode = false;
    notifyListeners();
  }

  Future<void> handleBatchGenerate(BuildContext context, VoidCallback onScrollToHistoryEnd) async {
    if (isLoading || isInpaintLoading || isUpscaleLoading) {
      return;
    }

    final count = batchCount; // 0 = 무한
    batchRemaining = count == 0 ? 999 : count;
    isBatchMode = count > 1 || count == 0;
    notifyListeners();

    while (batchRemaining > 0) {
      if (!context.mounted) {
        break;
      }
      if (!isApiConnected) {
        break;
      } // API 끊기면 중지

      await handleGenerate(context, onScrollToHistoryEnd);

      // 생성 중 취소 확인
      if (!isBatchMode && batchCount != 0) {
        break;
      }
      if (batchRemaining <= 0) {
        break;
      }

      if (count != 0) {
        batchRemaining--;
      }
      notifyListeners();

      // 다음 생성 전 잠깐 대기 (서버 부하 방지)
      await Future.delayed(Duration(milliseconds: (batchDelay * 1000).round()));
    }

    batchRemaining = 0;
    isBatchMode = false;
    notifyListeners();
  }

  // [추가] 엄격한 뮤텍스 잠금을 위한 변수 선언
  bool _isInpaintProcessing = false;

  Future<void> handleInpaintGenerate(BuildContext context, Uint8List maskBytes) async {
    // 1. 뮤텍스 검사: 앞선 작업 진행 중이라면 다중 클릭 무시
    if (_isInpaintProcessing) {
      debugPrint('이미 처리 중입니다. 중복 요청을 무시합니다.');
      return;
    }

    if (!isApiConnected) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("설정 탭에서 API 키를 먼저 연결해주세요."),
          ),
        );
      }
      return;
    }
    if (targetI2iImage == null || targetI2iMetadata == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("히스토리 탭에서 이미지를 먼저 선택해주세요."),
          ),
        );
      }
      return;
    }

    // 잠금 활성화
    _isInpaintProcessing = true;
    isInpaintLoading = true;
    inpaintStatusMessage = "연결 중...";
    lastErrorMessage = null;
    notifyListeners();

    try {
      if (!isSeedLocked || seedController.text.isEmpty) {
        seedController.text = Random().nextInt(4294967296).toString();
      }

      await saveAllSettings();

      int width = targetI2iMetadata!.width;
      int height = targetI2iMetadata!.height;

      String combined =
          "${inpaintPrefixController.text},${inpaintPositiveController.text},${inpaintSuffixController.text}";
      String step1 = _processWildcards(combined);

      String finalPrompt = _service.sanitizePrompt(step1);
      String finalNegative = _service.sanitizePrompt(
        _processWildcards(inpaintNegativeController.text),
      );

      bool bgInitialized = false;
      if (Platform.isAndroid) {
        try {
          bgInitialized = await FlutterBackground.initialize(
            androidConfig: const FlutterBackgroundAndroidConfig(
              notificationTitle: "NovelAI 인페인트 진행 중",
              notificationText: "백그라운드에서 안전하게 통신 중입니다...",
              notificationImportance: AndroidNotificationImportance.normal,
              notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
            ),
          );
          if (bgInitialized) {
            await FlutterBackground.enableBackgroundExecution();
          }
        } catch (e) {
          debugPrint("백그라운드 오류: $e");
        }
      }

      // API 호출 (내부적으로 Isolate + 백오프가 작동함)
      final result = await _service.generateImage(
        positive: finalPrompt,
        negative: finalNegative,
        token: apiToken,
        model: selectedModel,
        steps: int.tryParse(stepsController.text) ?? 28,
        sampler: selectedSampler,
        scheduler: selectedScheduler,
        isFurry: isFurryMode,
        width: width,
        height: height,
        cfgScale: double.tryParse(cfgScaleController.text) ?? 6.0,
        cfgRescale: double.tryParse(cfgRescaleController.text) ?? 0.0,
        seed: int.tryParse(seedController.text) ?? 0,
        characters: [],
        image: targetI2iImage,
        mask: maskBytes,
        action: "infill",
        infillStrength: infillStrength,
        variancePlus: isVariancePlus,
        onStatus: (msg) {
          inpaintStatusMessage = msg;
          notifyListeners();
        },
      );

      lastErrorMessage = result.error;

      if (result.error != null) {
        if (context.mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.redAccent),
                  SizedBox(width: 8),
                  Text(
                    "인페인트 생성 오류",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Text(result.error!, style: const TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("닫기", style: TextStyle(color: Colors.deepPurpleAccent)),
                ),
              ],
            ),
          );
        }
      } else if (result.image != null) {
        NaiMetadata? parsedMeta = extractNovelAIMetadata(result.image!);

        await addImageToHistory(
          image: result.image!,
          metadata: parsedMeta,
          context: context.mounted ? context : null,
        );

        isHistoryGridView = false;
        navigateToTab(1);
      }

      await fetchAnlas();
    } catch (e) {
      debugPrint('인페인트 파이프라인 에러: $e'); //
    } finally {
      // 성공/실패 여부와 관계없이 반드시 락 해제
      _isInpaintProcessing = false;
      isInpaintLoading = false;
      inpaintStatusMessage = "";
      notifyListeners();
    }
  }

  Future<void> handleUpscaleGenerate(BuildContext context) async {
    if (!isApiConnected) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 2400),
          content: Text("설정 탭에서 API 키를 먼저 연결해주세요."),
        ),
      );
      return;
    }
    if (targetI2iImage == null || targetI2iMetadata == null) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 2400),
          content: Text("히스토리 탭에서 이미지를 먼저 선택해주세요."),
        ),
      );
      return;
    }

    int width = targetI2iMetadata!.width;
    int height = targetI2iMetadata!.height;

    // [수정] PDF 가이드라인 적용: 1024x1024 픽셀 한계 검증 (면적 기준 계산)
    if ((width * height) > 1048576) {
      if (!context.mounted) {
        return;
      }
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amber),
              SizedBox(width: 8),
              Text(
                "해상도 제한 초과",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Text(
            "업스케일 API는 1024x1024 (1,048,576 픽셀) 면적 이하인 원본 이미지만 처리할 수 있습니다.\n\n현재 해상도: ${width}x$height", //
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                "확인",
                style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
      return;
    }

    bool proceed =
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.high_quality, color: Colors.amber),
                SizedBox(width: 8),
                Text(
                  "업스케일 진행",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            content: const Text(
              "업스케일(화질 향상)을 진행하면 유료 재화인 Anlas가 소모됩니다.\n(소모되는 비용은 이미지 크기에 따라 달라집니다.)\n\n계속 진행하시겠습니까?",
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("취소", style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.amber[700]),
                child: const Text(
                  "업스케일 시작",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (!proceed) {
      return;
    }

    if (!context.mounted) {
      return;
    }

    isUpscaleLoading = true;
    lastErrorMessage = null;
    notifyListeners();

    try {
      final result = await _service.upscaleImage(
        image: targetI2iImage!,
        width: width,
        height: height,
        token: apiToken,
      );

      isUpscaleLoading = false;

      if (result.error != null) {
        if (!context.mounted) {
          return;
        }
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.error_outline, color: Colors.redAccent),
                SizedBox(width: 8),
                Text(
                  "업스케일 오류",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            content: Text(result.error!, style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  "닫기",
                  style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
      } else if (result.image != null) {
        NaiMetadata? parsedMeta;
        if (targetI2iMetadata != null) {
          parsedMeta = NaiMetadata(
            positive: targetI2iMetadata!.positive,
            negative: targetI2iMetadata!.negative,
            characterPrompts: targetI2iMetadata!.characterPrompts,
            characterUndesiredContents: targetI2iMetadata!.characterUndesiredContents,
            width: width * 4,
            height: height * 4,
            seed: targetI2iMetadata!.seed,
            steps: targetI2iMetadata!.steps,
            sampler: targetI2iMetadata!.sampler,
            promptGuidance: targetI2iMetadata!.promptGuidance,
            promptGuidanceRescale: targetI2iMetadata!.promptGuidanceRescale,
            undesiredContentStrength: targetI2iMetadata!.undesiredContentStrength,
            source: targetI2iMetadata!.source,
            extraParams: targetI2iMetadata!.extraParams,
          );
        } else {
          parsedMeta = extractNovelAIMetadata(result.image!);
        }

        await addImageToHistory(
          image: result.image!,
          metadata: parsedMeta,
          context: context.mounted ? context : null,
          forceSave: true, // 업스케일은 항상 저장
        );

        isHistoryGridView = false;
        navigateToTab(1);
      }

      await fetchAnlas();
    } finally {
      isUpscaleLoading = false;
      notifyListeners();
    }
  }

  Future<void> importImageToHistory(BuildContext context) async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        final Uint8List bytes = await image.readAsBytes();

        historyImages.add(bytes);
        historyFavorites.add(false);
        historyFilePaths.add(null); // 불러온 이미지는 저장 경로 없음

        NaiMetadata? parsedMeta = extractNovelAIMetadata(bytes);
        historyMetadata.add(parsedMeta);

        if (historyImages.length > 100) {
          _removeOldestNonFavorite();
        }

        selectedHistoryIndex = historyImages.length - 1;
        scrollToThumbnailEnd = true;
        saveHistoryToLocal();
        notifyListeners();

        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("이미지를 성공적으로 불러왔습니다!"),
          ),
        );
      }
    } catch (e) {
      debugPrint("이미지 불러오기 오류: $e");
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 2400),
          content: Text("이미지를 불러오는 데 실패했습니다."),
        ),
      );
    }
  }

  // ============================================================================
  // 히스토리 일괄 삭제
  // ============================================================================
  bool isHistoryLoading = true; // 히스토리 로드 중 플래그

  // ============================================================================
  // 히스토리 메모리 관리
  // ============================================================================
  static const int _memoryKeepCount = 30; // 최근 N개만 원본 유지

  /// 오래된 이미지를 썸네일로 변환해서 메모리 절약 (백그라운드)
  Future<void> _trimHistoryMemory() async {
    if (historyImages.length <= _memoryKeepCount) {
      return;
    }

    final cutoff = historyImages.length - _memoryKeepCount;
    // 변환할 인덱스와 데이터 수집
    List<int> toConvert = [];
    List<Uint8List> toConvertData = [];
    for (int i = 0; i < cutoff; i++) {
      if (historyImages[i].length < 50000) {
        continue;
      }
      toConvert.add(i);
      toConvertData.add(historyImages[i]);
    }
    if (toConvertData.isEmpty) {
      return;
    }

    // 백그라운드 isolate에서 변환
    final thumbnails = await compute(_trimHistoryIsolate, toConvertData);
    for (int j = 0; j < toConvert.length; j++) {
      historyImages[toConvert[j]] = thumbnails[j];
    }
  }

  static List<Uint8List> _trimHistoryIsolate(List<Uint8List> images) {
    List<Uint8List> results = [];
    for (final bytes in images) {
      try {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          final thumb = img.copyResize(decoded, width: 200);
          results.add(Uint8List.fromList(img.encodeJpg(thumb, quality: 70)));
          continue;
        }
      } catch (_) {}
      results.add(bytes);
    }
    return results;
  }

  /// 특정 인덱스의 원본 이미지를 디스크에서 로드 (썸네일→원본 복구)
  Future<Uint8List?> loadFullHistoryImage(int index) async {
    if (index < 0 || index >= historyImages.length) {
      return null;
    }
    // 이미 원본 크기면 그대로
    if (historyImages[index].length >= 50000) {
      return historyImages[index];
    }
    try {
      final dir = await _getHistoryDir();
      final imgFile = File('${dir.path}/img_$index.png');
      if (await imgFile.exists()) {
        final bytes = await imgFile.readAsBytes();
        historyImages[index] = bytes; // 메모리에 복구
        return bytes;
      }
    } catch (_) {}
    return historyImages[index]; // 원본 없으면 썸네일 반환
  }

  // ============================================================================
  // 히스토리에 이미지 추가 (공통 헬퍼)
  // ============================================================================
  Future<String?> addImageToHistory({
    required Uint8List image,
    required NaiMetadata? metadata,
    BuildContext? context,
    bool forceSave = false, // true면 isAutoSave 무시하고 저장
  }) async {
    if (historyImages.length >= 100) {
      _removeOldestNonFavorite();
    }
    historyImages.add(image);
    historyFavorites.add(false);
    historyMetadata.add(metadata);

    String? savedPath;
    if (forceSave || isAutoSave) {
      savedPath = await autoSaveImage((context != null && context.mounted) ? context : null, image);
    }
    historyFilePaths.add(savedPath);

    selectedHistoryIndex = historyImages.length - 1;
    scrollToThumbnailEnd = true;
    saveHistoryToLocal();
    await _trimHistoryMemory();

    return savedPath;
  }

  void deleteAllHistory() {
    historyImages.clear();
    historyMetadata.clear();
    historyFavorites.clear();
    historyFilePaths.clear();
    selectedHistoryIndex = -1;
    _fullSaveHistoryToLocal();
    notifyListeners();
  }

  void deleteNonFavoriteHistory() {
    int i = 0;
    while (i < historyImages.length) {
      if (i >= historyFavorites.length || !historyFavorites[i]) {
        historyImages.removeAt(i);
        if (i < historyMetadata.length) {
          historyMetadata.removeAt(i);
        }
        if (i < historyFavorites.length) {
          historyFavorites.removeAt(i);
        }
        if (i < historyFilePaths.length) {
          historyFilePaths.removeAt(i);
        }
      } else {
        i++;
      }
    }
    if (historyImages.isEmpty) {
      selectedHistoryIndex = -1;
    } else {
      selectedHistoryIndex = selectedHistoryIndex.clamp(0, historyImages.length - 1);
    }
    _fullSaveHistoryToLocal();
    notifyListeners();
  }

  void deleteHistoryByIndices(Set<int> indices) {
    // 큰 인덱스부터 삭제해야 인덱스가 안 밀림
    final sorted = indices.toList()..sort((a, b) => b.compareTo(a));
    for (final idx in sorted) {
      if (idx < 0 || idx >= historyImages.length) {
        continue;
      }
      historyImages.removeAt(idx);
      if (idx < historyMetadata.length) {
        historyMetadata.removeAt(idx);
      }
      if (idx < historyFavorites.length) {
        historyFavorites.removeAt(idx);
      }
      if (idx < historyFilePaths.length) {
        historyFilePaths.removeAt(idx);
      }
    }
    if (historyImages.isEmpty) {
      selectedHistoryIndex = -1;
    } else {
      selectedHistoryIndex = selectedHistoryIndex.clamp(0, historyImages.length - 1);
    }
    _fullSaveHistoryToLocal();
    notifyListeners();
  }

  void toggleHistoryFavorite(int index) {
    if (index < 0 || index >= historyFavorites.length) {
      return;
    }
    historyFavorites[index] = !historyFavorites[index];
    saveHistoryToLocal();
    notifyListeners();
  }

  // ============================================================================
  // 즐겨찾기가 아닌 가장 오래된 이미지 제거 (즐겨찾기 보호)
  // ============================================================================
  void _removeOldestNonFavorite() {
    // 즐겨찾기가 아닌 가장 오래된 인덱스 찾기
    int targetIndex = -1;
    for (int i = 0; i < historyImages.length; i++) {
      if (i >= historyFavorites.length || !historyFavorites[i]) {
        targetIndex = i;
        break;
      }
    }

    // 전부 즐겨찾기면 삭제하지 않음 (100개 초과 허용)
    if (targetIndex == -1) {
      return;
    }

    historyImages.removeAt(targetIndex);
    if (targetIndex < historyMetadata.length) {
      historyMetadata.removeAt(targetIndex);
    }
    if (targetIndex < historyFavorites.length) {
      historyFavorites.removeAt(targetIndex);
    }
    if (targetIndex < historyFilePaths.length) {
      historyFilePaths.removeAt(targetIndex);
    }

    // selectedHistoryIndex 보정
    if (targetIndex <= selectedHistoryIndex) {
      selectedHistoryIndex--;
      if (selectedHistoryIndex < 0) {
        selectedHistoryIndex = 0;
      }
    }
    historyNeedsFullSave = true; // 인덱스가 밀렸으므로 전체 저장 필요
  }

  void deleteHistoryImage(int index) {
    if (index < 0 || index >= historyImages.length) {
      return;
    }

    historyImages.removeAt(index);
    if (index < historyMetadata.length) {
      historyMetadata.removeAt(index);
    }
    if (index < historyFavorites.length) {
      historyFavorites.removeAt(index);
    }
    if (index < historyFilePaths.length) {
      historyFilePaths.removeAt(index);
    }

    if (historyImages.isEmpty) {
      selectedHistoryIndex = -1;
    } else {
      if (index <= selectedHistoryIndex) {
        selectedHistoryIndex--;
      }
      if (selectedHistoryIndex < 0) {
        selectedHistoryIndex = 0;
      }
    }
    _fullSaveHistoryToLocal(); // 인덱스 변경되므로 전체 저장
    historyNeedsFullSave = false;
    notifyListeners();
  }

  // ============================================================================
  // 히스토리 로컬 저장/불러오기 (앱 종료 후에도 유지)
  // ============================================================================
  Future<Directory> _getHistoryDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final historyDir = Directory('${appDir.path}/history');
    if (!await historyDir.exists()) {
      await historyDir.create(recursive: true);
    }
    return historyDir;
  }

  // Vibe Transfer / Precise Reference 로컬 저장
  // ============================================================================
  // .naiv4vibe 파일 import/export
  // ============================================================================

  // 간단한 해시 (crypto 의존성 회피, 키 이름용)
  String _simpleHash(String input) {
    int hash = 0;
    for (int i = 0; i < input.length; i++) {
      hash = (hash * 31 + input.codeUnitAt(i)) & 0x7FFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  // 모델명 → naiv4vibe encodings 키
  String _modelToVibeKey(String model) {
    if (model.contains("4-5") && model.contains("full")) {
      return "v4-5full";
    }
    if (model.contains("4-5") && model.contains("curated")) {
      return "v4-5curated";
    }
    if (model.contains("4") && model.contains("full")) {
      return "v4full";
    }
    if (model.contains("4") && model.contains("curated")) {
      return "v4curated";
    }
    return "v4-5full";
  }

  // 단일 vibe를 .naiv4vibe JSON 문자열로 변환
  String exportVibeToNaiv4(Map<String, dynamic> vibe) {
    final vibeKey = _modelToVibeKey(selectedModel);
    final infoExt = (vibe['infoExtracted'] as double?) ?? 1.0;
    final image = vibe['image'] as String;

    // 인코딩이 있으면 포함
    Map<String, dynamic> encodings = {};
    final encoded = vibe['_encoded'] as String?;
    if (encoded != null) {
      // 임의의 해시 키 생성 (NovelAI는 내부 해시지만, 키 이름은 중요하지 않음)
      final keyHash = _simpleHash("$image$infoExt");
      encodings = {
        vibeKey: {
          keyHash: {
            "encoding": encoded,
            "params": {"information_extracted": infoExt},
          },
        },
      };
    }

    final naiv4 = {
      "identifier": "novelai-vibe-transfer",
      "version": 1,
      "type": "image",
      "image": image,
      "id": _simpleHash(image),
      "encodings": encodings,
      "name": vibe['name'] ?? "vibe",
      "thumbnail": "data:image/jpeg;base64,$image",
      "createdAt": DateTime.now().millisecondsSinceEpoch,
      "importInfo": {
        "model": selectedModel,
        "information_extracted": infoExt,
        "strength": (vibe['strength'] as double?) ?? 0.6,
      },
    };
    return jsonEncode(naiv4);
  }

  // .naiv4vibe / .naiv4vibeBundle JSON 파싱 → vibeTransfers에 추가
  // 반환: 추가된 개수
  int importVibeFromNaiv4(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr);
      List<dynamic> vibesToImport = [];

      if (data['identifier'] == 'novelai-vibe-transfer-bundle') {
        vibesToImport = data['vibes'] as List;
      } else if (data['identifier'] == 'novelai-vibe-transfer') {
        vibesToImport = [data];
      } else {
        return 0;
      }

      int added = 0;
      for (final v in vibesToImport) {
        if (vibeTransfers.length >= 9) {
          break;
        }

        final image = v['image'] as String?;
        if (image == null) {
          continue;
        }

        final importInfo = v['importInfo'] as Map<String, dynamic>?;
        final infoExt = (importInfo?['information_extracted'] as num?)?.toDouble() ?? 1.0;
        final strength = (importInfo?['strength'] as num?)?.toDouble() ?? 0.6;

        // 현재 모델에 맞는 인코딩 추출
        String? encoded;
        final encodings = v['encodings'] as Map<String, dynamic>?;
        if (encodings != null) {
          final vibeKey = _modelToVibeKey(selectedModel);
          final modelEncodings = encodings[vibeKey] as Map<String, dynamic>?;
          if (modelEncodings != null && modelEncodings.isNotEmpty) {
            // 정보추출 값이 일치하는 인코딩 찾기
            for (final entry in modelEncodings.values) {
              final params = entry['params'] as Map<String, dynamic>?;
              final encInfoExt = (params?['information_extracted'] as num?)?.toDouble();
              if (encInfoExt == infoExt) {
                encoded = entry['encoding'] as String?;
                break;
              }
            }
            // 못 찾으면 첫 번째 인코딩 사용
            encoded ??= (modelEncodings.values.first['encoding'] as String?);
          }
        }

        final newVibe = <String, dynamic>{
          'image': image,
          'strength': strength,
          'infoExtracted': infoExt,
        };
        // 인코딩 있으면 캐시에 저장 (Anlas 절약)
        if (encoded != null) {
          newVibe['_encoded'] = encoded;
          newVibe['_encodedInfoExt'] = infoExt;
          newVibe['_encodedModel'] = selectedModel;
        }
        vibeTransfers.add(newVibe);
        added++;
      }

      if (added > 0) {
        saveReferencesToLocal();
        notifyListeners();
      }
      return added;
    } catch (e) {
      debugPrint("naiv4vibe 파싱 실패: $e");
      return -1;
    }
  }

  // Precise Reference import: (이미지 base64, metadata 항목) 리스트를 받아 추가
  // 반환: 추가된 개수
  int addPreciseFromImport(List<Map<String, dynamic>> items) {
    int added = 0;
    for (final item in items) {
      if (preciseRefs.length >= 9) {
        break;
      }
      final image = item['image'] as String?;
      if (image == null) {
        continue;
      }
      preciseRefs.add({
        'image': image,
        'type': (item['type'] as String?) ?? 'character',
        'strength': (item['strength'] as num?)?.toDouble() ?? 1.0,
        'fidelity': (item['fidelity'] as num?)?.toDouble() ?? 0.5,
        'enabled': (item['enabled'] as bool?) ?? true,
      });
      added++;
    }
    if (added > 0) {
      saveReferencesToLocal();
      notifyListeners();
    }
    return added;
  }

  Future<void> saveReferencesToLocal() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/references.json');
      final data = {'vibeTransfers': vibeTransfers, 'preciseRefs': preciseRefs};
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint("레퍼런스 저장 실패: $e");
    }
  }

  Future<void> loadReferencesFromLocal() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/references.json');
      if (!await file.exists()) {
        return;
      }
      final data = jsonDecode(await file.readAsString());
      if (data['vibeTransfers'] != null) {
        vibeTransfers = (data['vibeTransfers'] as List).map((e) {
          final m = Map<String, dynamic>.from(e);
          if (m['strength'] != null) {
            m['strength'] = (m['strength'] as num).toDouble();
          }
          if (m['infoExtracted'] != null) {
            m['infoExtracted'] = (m['infoExtracted'] as num).toDouble();
          }
          if (m['_encodedInfoExt'] != null) {
            m['_encodedInfoExt'] = (m['_encodedInfoExt'] as num).toDouble();
          }
          return m;
        }).toList();
      }
      if (data['preciseRefs'] != null) {
        preciseRefs = (data['preciseRefs'] as List).map((e) {
          final m = Map<String, dynamic>.from(e);
          if (m['strength'] != null) {
            m['strength'] = (m['strength'] as num).toDouble();
          }
          if (m['fidelity'] != null) {
            m['fidelity'] = (m['fidelity'] as num).toDouble();
          }
          return m;
        }).toList();
      }
    } catch (e) {
      debugPrint("레퍼런스 불러오기 실패: $e");
    }
  }

  Timer? _historySaveDebounce;

  Future<void> saveHistoryToLocal() async {
    // 빠른 연속 호출 방지 (300ms 디바운스)
    _historySaveDebounce?.cancel();
    _historySaveDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final dir = await _getHistoryDir();
        final int total = historyImages.length;

        // JSON 파일만 매번 갱신 (가볍고 빠름)
        await File(
          '${dir.path}/metadata.json',
        ).writeAsString(jsonEncode(historyMetadata.map((m) => m?.toJson()).toList()));
        await File('${dir.path}/favorites.json').writeAsString(jsonEncode(historyFavorites));
        await File('${dir.path}/paths.json').writeAsString(jsonEncode(historyFilePaths));

        // 인덱스가 밀린 상태면 이미지 파일은 건너뛰기 (fullSave에서 처리)
        if (!historyNeedsFullSave && total > 0) {
          final lastIdx = total - 1;
          final pngFile = File('${dir.path}/img_$lastIdx.png');
          final thumbFile = File('${dir.path}/thumb_$lastIdx.jpg');
          if (!pngFile.existsSync() && !thumbFile.existsSync()) {
            await pngFile.writeAsBytes(historyImages[lastIdx]);
          }
        }

        debugPrint("✅ 히스토리 증분 저장 완료 ($total개)");
      } catch (e) {
        debugPrint("❌ 히스토리 저장 실패: $e");
      }
    });
  }

  // 앱 백그라운드/종료 시 호출 — 밀린 전체 저장 실행
  Future<void> fullSaveHistoryIfNeeded() async {
    _historySaveDebounce?.cancel();
    if (historyNeedsFullSave) {
      await _fullSaveHistoryToLocal();
      historyNeedsFullSave = false;
    }
  }

  // 전체 재정렬 저장 (삭제 등 인덱스가 바뀌는 작업 후에만 호출)
  Future<void> _fullSaveHistoryToLocal() async {
    try {
      final dir = await _getHistoryDir();

      // 기존 이미지/썸네일 파일만 삭제 (JSON은 유지)
      final existing = dir.listSync().whereType<File>();
      for (final f in existing) {
        final name = f.path.split('/').last;
        if (name.startsWith('img_') || name.startsWith('thumb_')) {
          await f.delete();
        }
      }

      final int total = historyImages.length;
      // _trimHistoryMemory 덕에 오래된 이미지는 이미 썸네일 (~10KB)
      final futures = <Future>[];
      for (int i = 0; i < total; i++) {
        final bool isSmall = historyImages[i].length < 50000;
        if (isSmall) {
          futures.add(File('${dir.path}/thumb_$i.jpg').writeAsBytes(historyImages[i]));
        } else {
          futures.add(File('${dir.path}/img_$i.png').writeAsBytes(historyImages[i]));
        }
      }
      // 병렬 쓰기
      await Future.wait(futures);

      // JSON 저장
      await File(
        '${dir.path}/metadata.json',
      ).writeAsString(jsonEncode(historyMetadata.map((m) => m?.toJson()).toList()));
      await File('${dir.path}/favorites.json').writeAsString(jsonEncode(historyFavorites));
      await File('${dir.path}/paths.json').writeAsString(jsonEncode(historyFilePaths));

      debugPrint("✅ 히스토리 전체 저장 완료 ($total개)");
    } catch (e) {
      debugPrint("❌ 히스토리 전체 저장 실패: $e");
    }
  }

  Future<void> _loadHistoryFromLocal() async {
    isHistoryLoading = true;
    try {
      final dir = await _getHistoryDir();
      final metaFile = File('${dir.path}/metadata.json');
      if (!await metaFile.exists()) {
        isHistoryLoading = false;
        notifyListeners();
        return;
      }

      final metaJson = jsonDecode(await metaFile.readAsString()) as List;

      List<Uint8List> loadedImages = [];
      List<NaiMetadata?> loadedMeta = [];

      for (int i = 0; i < metaJson.length; i++) {
        final imgFile = File('${dir.path}/img_$i.png');
        final thumbFile = File('${dir.path}/thumb_$i.jpg');

        if (await imgFile.exists()) {
          loadedImages.add(await imgFile.readAsBytes());
          loadedMeta.add(metaJson[i] != null ? NaiMetadata.fromJson(metaJson[i]) : null);
        } else if (await thumbFile.exists()) {
          loadedImages.add(await thumbFile.readAsBytes());
          loadedMeta.add(metaJson[i] != null ? NaiMetadata.fromJson(metaJson[i]) : null);
        }
      }

      historyImages = loadedImages;
      historyMetadata = loadedMeta;

      // 즐겨찾기 불러오기
      final favFile = File('${dir.path}/favorites.json');
      if (await favFile.exists()) {
        final favJson = jsonDecode(await favFile.readAsString()) as List;
        historyFavorites = favJson.map((e) => e as bool).toList();
      }

      // 파일 경로 불러오기
      final pathsFile = File('${dir.path}/paths.json');
      if (await pathsFile.exists()) {
        final pathsJson = jsonDecode(await pathsFile.readAsString()) as List;
        historyFilePaths = pathsJson.map((e) => e as String?).toList();
      }

      // 길이 보정
      while (historyFavorites.length < historyImages.length) {
        historyFavorites.add(false);
      }
      while (historyFilePaths.length < historyImages.length) {
        historyFilePaths.add(null);
      }

      if (historyImages.isNotEmpty) {
        selectedHistoryIndex = historyImages.length - 1;
      }
      debugPrint("✅ 히스토리 ${historyImages.length}개 로컬에서 불러오기 완료");
      await _trimHistoryMemory(); // 오래된 이미지 썸네일 변환
      isHistoryLoading = false;
      notifyListeners();
    } catch (e) {
      debugPrint("❌ 히스토리 불러오기 실패: $e");
      isHistoryLoading = false;
      notifyListeners();
    }
  }

  // ============================================================================
  // 파일 존재 여부 확인
  // ============================================================================
  bool checkFileExistsSync(int index) {
    if (index < 0 || index >= historyFilePaths.length) {
      return false;
    }
    final path = historyFilePaths[index];
    if (path == null || path.isEmpty) {
      return false;
    }
    return File(path).existsSync();
  }

  // ============================================================================
  // 히스토리 이미지가 썸네일(경량)인지 확인
  // ============================================================================
  bool isHistoryThumbnail(int index) {
    if (index < 0 || index >= historyImages.length) {
      return false;
    }
    final bytes = historyImages[index];
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true; // JPEG = 썸네일
    }
    return false; // PNG = 원본
  }

  // ============================================================================
  // 메타데이터로 이미지 재생성 (썸네일만 있는 경우)
  // ============================================================================
  // ============================================================================
  // 메타데이터 표시 모델명 → API 모델 ID 변환
  // (예: "NovelAI Diffusion V4.5 4BDE2A90" → "nai-diffusion-4-5-full")
  // 뒤의 해시는 패치마다 바뀌므로 버전 키워드로 매칭
  // ============================================================================
  String _resolveModelId(String displayName) {
    final lower = displayName.toLowerCase();

    // 이미 API 모델 ID 형식이면 그대로 반환
    if (lower.startsWith('nai-diffusion')) {
      return displayName;
    }

    // 버전 키워드 매칭 (구체적인 것부터 체크)
    if (lower.contains('v4.5')) {
      return 'nai-diffusion-4-5-full';
    }
    if (lower.contains('v4')) {
      return 'nai-diffusion-4-full';
    }
    if (lower.contains('v3')) {
      return 'nai-diffusion-3';
    }

    // 매칭 실패 → 현재 선택된 모델 사용
    return selectedModel;
  }

  Future<void> regenerateFromMetadata(BuildContext context, int index) async {
    if (index < 0 || index >= historyMetadata.length) {
      return;
    }
    final meta = historyMetadata[index];
    if (meta == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("메타데이터가 없어 재생성할 수 없습니다."),
          ),
        );
      }
      return;
    }

    if (apiToken.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("API 토큰이 설정되지 않았습니다."),
          ),
        );
      }
      return;
    }

    isLoading = true;
    notifyListeners();

    try {
      List<Map<String, dynamic>> characters = [];
      for (int i = 0; i < meta.characterPrompts.length; i++) {
        characters.add({
          'positive': meta.characterPrompts[i],
          'negative': i < meta.characterUndesiredContents.length
              ? meta.characterUndesiredContents[i]
              : '',
          'gridX': 2,
          'gridY': 2,
        });
      }

      final result = await _service.generateImage(
        positive: meta.positive,
        negative: meta.negative,
        token: apiToken,
        model: meta.source.isNotEmpty ? _resolveModelId(meta.source) : selectedModel,
        steps: meta.steps > 0 ? meta.steps : 28,
        sampler: meta.sampler.isNotEmpty ? meta.sampler : selectedSampler,
        scheduler: meta.extraParams['noise_schedule']?.toString() ?? selectedScheduler,
        isFurry: isFurryMode,
        width: meta.width > 0 ? meta.width : 832,
        height: meta.height > 0 ? meta.height : 1216,
        cfgScale: meta.promptGuidance > 0 ? meta.promptGuidance : 6.0,
        cfgRescale: meta.promptGuidanceRescale,
        seed: meta.seed,
        characters: characters,
        variancePlus: meta.extraParams['variety_plus'] == true,
      );

      if (result.image != null) {
        historyImages[index] = result.image!;

        String? savedPath;
        if (context.mounted) {
          savedPath = await autoSaveImage(context, result.image!);
        } else {
          savedPath = await autoSaveImage(null, result.image!);
        }
        if (index < historyFilePaths.length) {
          historyFilePaths[index] = savedPath;
        }
        saveHistoryToLocal();

        if (context.mounted && showGenerationMessage) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(milliseconds: 2400),
              content: Text("이미지 재생성 및 저장 완료!"),
            ),
          );
        }
      } else if (result.error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("재생성 실패: ${result.error}"),
          ),
        );
      }
      await fetchAnlas();
    } catch (e) {
      debugPrint("재생성 오류: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("재생성 중 오류가 발생했습니다."),
          ),
        );
      }
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  String _getFormattedFileName(String suffix) {
    String format = customFileNameController.text.trim();
    if (format.isEmpty) {
      format = "Nai-{yy}{mm}{dd}-{time}";
    }
    DateTime now = DateTime.now();
    String yy = DateFormat('yyyy').format(now);
    String mm = DateFormat('MM').format(now);
    String dd = DateFormat('dd').format(now);
    String time = DateFormat('HHmmss').format(now);
    String parsed = format
        .replaceAll('{yy}', yy)
        .replaceAll('{mm}', mm)
        .replaceAll('{dd}', dd)
        .replaceAll('{time}', time)
        .replaceAll('{count}', sessionSaveCount.toString().padLeft(3, '0'));
    return suffix.isEmpty ? parsed : "${parsed}_$suffix";
  }

  Future<String?> autoSaveImage(BuildContext? context, Uint8List bytes) async {
    sessionSaveCount++;
    sessionFolderName ??= DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

    String fileName = _getFormattedFileName("");
    final String ext = (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) ? 'jpg' : 'png';
    final messenger = context != null ? ScaffoldMessenger.of(context) : null;

    // 1차 시도: 커스텀 경로
    String basePath = customSavePathController.text.trim();
    if (basePath.isNotEmpty) {
      try {
        final directory = Directory('$basePath/DNaiApp/$sessionFolderName');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File("${directory.path}/$fileName.$ext");
        await file.writeAsBytes(bytes);
        _scanMedia(file.path);
        if (showGenerationMessage) {
          messenger?.showSnackBar(
            SnackBar(content: Text("자동 저장 완료 ($fileName)"), duration: const Duration(seconds: 1)),
          );
        }
        return file.path;
      } catch (e) {
        debugPrint("커스텀 경로 저장 실패 ($basePath): $e");
      }
    }

    // 2차 시도: 앱 전용 외부 디렉토리 (권한 불필요)
    try {
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        final directory = Directory('${appDir.path}/DNaiApp/$sessionFolderName');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File("${directory.path}/$fileName.$ext");
        await file.writeAsBytes(bytes);
        _scanMedia(file.path);
        if (showGenerationMessage) {
          messenger?.showSnackBar(
            SnackBar(content: Text("자동 저장 완료 ($fileName)"), duration: const Duration(seconds: 1)),
          );
        }
        return file.path;
      }
    } catch (e) {
      debugPrint("앱 디렉토리 저장 실패: $e");
    }

    // 3차 시도: 임시 디렉토리 (최후의 수단)
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File("${tempDir.path}/$fileName.$ext");
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (e) {
      debugPrint("임시 디렉토리 저장 실패: $e");
    }

    return null;
  }

  Future<void> manualSaveImage(BuildContext context, Uint8List bytes) async {
    sessionSaveCount++;
    sessionFolderName ??= DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

    String fileName = _getFormattedFileName("Manual");
    final String ext = (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) ? 'jpg' : 'png';
    final messenger = ScaffoldMessenger.of(context); // async gap 전에 캡처

    // 1차: 커스텀 경로
    String basePath = customSavePathController.text.trim();
    if (basePath.isNotEmpty) {
      try {
        final directory = Directory('$basePath/DNaiApp/$sessionFolderName');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File("${directory.path}/$fileName.$ext");
        await file.writeAsBytes(bytes);
        _scanMedia(file.path);
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("이미지가 지정된 경로에 저장되었습니다!"),
          ),
        );
        notifyListeners();
        return;
      } catch (e) {
        debugPrint("커스텀 경로 수동 저장 실패: $e");
      }
    }

    // 2차: 앱 전용 디렉토리
    try {
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        final directory = Directory('${appDir.path}/DNaiApp/$sessionFolderName');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File("${directory.path}/$fileName.$ext");
        await file.writeAsBytes(bytes);
        _scanMedia(file.path);
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("이미지가 앱 폴더에 저장되었습니다."),
          ),
        );
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint("앱 디렉토리 수동 저장 실패: $e");
    }

    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 2400),
        content: Text("저장에 실패했습니다. 저장 경로를 확인해주세요."),
      ),
    );
    notifyListeners();
  }

  void _scanMedia(String filePath) {
    if (Platform.isAndroid) {
      try {
        MediaScanner.loadMedia(path: filePath);
      } catch (_) {}
    }
  }

  Future<void> fetchAnlas() async {
    if (apiToken.isEmpty) {
      return;
    }
    final result = await _service.fetchUserInfo(apiToken);
    if (result != null) {
      currentAnlas = result['anlas'] ?? 0;
      subscriptionTier = result['tier'] ?? 0;
      isApiConnected = true;
      notifyListeners();
    }
  }

  bool checkIfAnlasConsumed() {
    int width = 832;
    int height = 1216;

    if (resolutionMode == "랜덤") {
      width = 1024;
      height = 1024;
    } else if (resolutionMode == "자동" && currentImageWidth > 0 && currentImageHeight > 0) {
      double maxPixels = 1048576.0;
      double ratio = currentImageWidth / currentImageHeight;
      double h = sqrt(maxPixels / ratio);
      double w = h * ratio;
      width = (w / 64).round() * 64;
      height = (h / 64).round() * 64;

      while ((width * height) > 1048576) {
        if (width > height) {
          width -= 64;
        } else {
          height -= 64;
        }
      }
      if (width < 64) {
        width = 64;
      }
      if (height < 64) {
        height = 64;
      }
    } else if (selectedResolution == "직접 입력" ||
        (resolutionMode == "자동" && currentImageWidth == 0)) {
      width = int.tryParse(customWidthController.text) ?? 832;
      height = int.tryParse(customHeightController.text) ?? 1216;
    } else {
      List<String> resParts = selectedResolution.replaceAll(" ", "").split("x");
      width = int.parse(resParts[0]);
      height = int.parse(resParts[1]);
    }

    // 배율 적용
    if (resolutionScale != 1.0) {
      width = ((width * resolutionScale) / 64).round() * 64;
      height = ((height * resolutionScale) / 64).round() * 64;
    }

    // 64px 단위 정렬
    width = ((width / 64).round() * 64).clamp(64, 9999);
    height = ((height / 64).round() * 64).clamp(64, 9999);

    // NovelAI 최대 픽셀 수 제한
    const int maxPixels = 3145728;
    while (width * height > maxPixels) {
      if (width > height) {
        width -= 64;
      } else {
        height -= 64;
      }
    }

    int steps = int.tryParse(stepsController.text) ?? 28;
    bool isOpus = subscriptionTier >= 3;

    // 활성 Precise Reference는 항상 Anlas 소모
    bool hasPrecise = preciseRefs.any((r) => (r['enabled'] as bool?) ?? true);
    if (hasPrecise) {
      return true;
    }

    // Vibe Transfer: 활성화된 것만, 인코딩 안 된 것이 있거나 4개 초과면 Anlas 소모
    final activeVibes = vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList();
    if (activeVibes.isNotEmpty) {
      bool hasUnencodedVibe = activeVibes.any((v) => v['_encoded'] == null);
      bool tooManyVibes = activeVibes.length > 4;
      if (hasUnencodedVibe || tooManyVibes) {
        return true;
      }
      // 전부 인코딩됨 + 4개 이하 → 해상도/스텝 기준으로만 판단 (아래로 진행)
    }

    if (isOpus && (width * height) <= 1048576 && steps <= 28) {
      return false;
    }

    return true;
  }

  // Vibe Transfer Anlas 비용 계산 (UI 표시용)
  int calculateVibeAnlas() {
    final activeVibes = vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList();
    if (activeVibes.isEmpty) {
      return 0;
    }
    int cost = 0;
    // 인코딩 안 된 vibe당 2 Anlas
    for (final v in activeVibes) {
      if (v['_encoded'] == null) {
        cost += 2;
      }
    }
    // 4개 초과 시 추가 vibe당 2 Anlas
    if (activeVibes.length > 4) {
      cost += (activeVibes.length - 4) * 2;
    }
    return cost;
  }

  // Precise Reference Anlas 비용 계산 (활성 이미지당 +5 Anlas)
  int calculatePreciseAnlas() {
    final activePrecise = preciseRefs.where((r) => (r['enabled'] as bool?) ?? true).toList();
    return activePrecise.length * 5;
  }

  void selectWildcard(int index) {
    if (index > 0 && index < wildcards.length) {
      final selected = wildcards.removeAt(index);
      wildcards.insert(0, selected);
    }
    selectedWildcardIndex = 0;
    saveAllSettings();
    notifyListeners();
  }

  void deleteWildcard(int index) {
    if (wildcards.isEmpty || index < 0 || index >= wildcards.length) {
      return;
    }

    wildcards.removeAt(index);

    if (wildcards.isNotEmpty) {
      selectedWildcardIndex = 0;
    } else {
      wildcards.add(NaiWildcard(name: "새 와일드카드", content: ""));
      selectedWildcardIndex = 0;
    }

    saveAllSettings();
    notifyListeners();
  }
}

// ============================================================================
// 조건부 트리거 파서 (재귀 하강)
// ============================================================================
class _ConditionParser {
  final String _input;
  final List<String> _tags;
  final String _rating;
  final AppState _state;
  int _pos = 0;

  _ConditionParser(this._input, this._tags, this._rating, this._state);

  void _skipSpaces() {
    while (_pos < _input.length && _input[_pos] == ' ') {
      _pos++;
    }
  }

  // or_expr = and_expr ('|' and_expr)*
  bool parseOrExpr() {
    bool result = _parseAndExpr();
    while (_pos < _input.length) {
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == '|') {
        _pos++;
        bool right = _parseAndExpr();
        result = result || right;
      } else {
        break;
      }
    }
    return result;
  }

  // and_expr = atom ('&' atom)*
  bool _parseAndExpr() {
    bool result = _parseAtom();
    while (_pos < _input.length) {
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == '&') {
        _pos++;
        bool right = _parseAtom();
        result = result && right;
      } else {
        break;
      }
    }
    return result;
  }

  // atom = '!' atom | '(' or_expr ')' | pattern
  bool _parseAtom() {
    _skipSpaces();
    if (_pos >= _input.length) {
      return false;
    }

    // 부정 연산자
    if (_input[_pos] == '!') {
      _pos++;
      return !_parseAtom();
    }

    // 괄호 그룹
    if (_input[_pos] == '(') {
      _pos++; // '(' 건너뛰기
      bool result = parseOrExpr();
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == ')') {
        _pos++; // ')' 건너뛰기
      }
      return result;
    }

    // 패턴 (& | ) 까지 읽기)
    StringBuffer buf = StringBuffer();
    while (_pos < _input.length &&
        _input[_pos] != '&' &&
        _input[_pos] != '|' &&
        _input[_pos] != ')') {
      buf.write(_input[_pos]);
      _pos++;
    }
    String pattern = buf.toString().trim();
    if (pattern.isEmpty) {
      return false;
    }

    return _state._matchAtom(pattern, _tags, _rating);
  }
}
