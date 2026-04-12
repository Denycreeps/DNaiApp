import 'package:flutter/services.dart' show rootBundle;
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

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
const String kContainsMarker = '†';

// ============================================================================
// 프롬프트 토큰 추정기 (NAI V4/V4.5 T5 토크나이저 기준 ~512 토큰 제한)
// T5 토크나이저는 서브워드 기반으로, 평균 ~3.2글자당 1토큰
// (콤마·괄호·가중치 구문 모두 토큰으로 소비됨)
// ============================================================================
int estimateTokenCount(String prompt) {
  if (prompt.trim().isEmpty) return 0;
  return (prompt.trim().length / 3.1).round();
}

List<String> smartMatchTags(List<String> tags, String query, {int limit = 15}) {
  // 트레일링 스페이스 감지 (trim 전에!)
  final hasTrailingSpace = query.endsWith(' ');
  final lower = query.toLowerCase().trim();
  if (lower.isEmpty) return [];

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
    if (startsResults.isNotEmpty) return startsResults;
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
    if (wordBoundaryResults.length >= limit && midWordResults.length >= limit) break;
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
        if (!tagLower.startsWith(first)) return false;

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
          if (!found) return false;
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

  NaiPreset({
    required this.name,
    required this.positive,
    required this.negative,
    required this.prefix,
    required this.suffix,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'positive': positive,
    'negative': negative,
    'prefix': prefix,
    'suffix': suffix,
  };

  factory NaiPreset.fromJson(Map<String, dynamic> json) => NaiPreset(
    name: json['name'] ?? '',
    positive: json['positive'] ?? '',
    negative: json['negative'] ?? '',
    prefix: json['prefix'] ?? '',
    suffix: json['suffix'] ?? '',
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
  // 🚀 GitHub 저장소 주소 (본인 리포로 변경!)
  static const String githubRepo = "YOUR_USERNAME/YOUR_REPO";

  String? latestVersion;
  String? updateUrl;
  String? updateNotes;
  bool get hasUpdate =>
      latestVersion != null && _compareVersions(latestVersion!, currentVersion) > 0;

  static int _compareVersions(String a, String b) {
    final pa = a.replaceFirst('v', '').split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.replaceFirst('v', '').split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  Future<void> checkForUpdate() async {
    try {
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$githubRepo/releases/latest'),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final tag = data['tag_name']?.toString() ?? "";
        if (tag.isNotEmpty && _compareVersions(tag, currentVersion) > 0) {
          latestVersion = tag.replaceFirst('v', '');
          updateUrl = data['html_url']?.toString();
          updateNotes = data['body']?.toString();
          notifyListeners();
        }
      }
    } catch (_) {
      // 네트워크 실패 시 무시 (업데이트 체크는 부가 기능)
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
  bool showImageInOtherTabs = false;
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

  bool isI2iScrollDisabled = false;
  void setI2iScrollDisabled(bool disabled) {
    if (isI2iScrollDisabled != disabled) {
      isI2iScrollDisabled = disabled;
      notifyListeners();
    }
  }

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

  List<NaiCharacter> characters = [NaiCharacter()];
  int selectedCharIndex = 0;
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

    await [Permission.storage, Permission.manageExternalStorage].request();
    await _loadTagsFromJson();
    final prefs = await SharedPreferences.getInstance();
    apiToken = prefs.getString('api_token') ?? "";
    apiTokenController.text = apiToken;
    isApiConnected = apiToken.isNotEmpty;
    customSavePathController.text =
        prefs.getString('custom_save_path') ?? "/storage/emulated/0/Download";
    customFileNameController.text =
        prefs.getString('custom_file_name') ?? "Nai-{yy}{mm}{dd}-{time}-{count}";
    customWidthController.text = prefs.getString('custom_width') ?? "832";
    customHeightController.text = prefs.getString('custom_height') ?? "1216";
    conditionalRuleController.text = prefs.getString('conditional_rules') ?? "";

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
    showImageInOtherTabs = prefs.getBool('showImageInOtherTabs') ?? false;
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
    notifyListeners();

    // 업데이트 체크 (비동기, 앱 시작을 블로킹하지 않음)
    checkForUpdate();
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
  Map<String, dynamic> exportSettings() {
    return {
      'version': currentVersion,
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
      'showImageInOtherTabs': showImageInOtherTabs,
      'useGelbooruApiKey': useGelbooruApiKey,
      'characters': characters.map((c) => c.toJson()).toList(),
      'wildcards': wildcards.map((w) => w.toJson()).toList(),
    };
  }

  void importSettings(Map<String, dynamic> data) {
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
    showImageInOtherTabs = data['showImageInOtherTabs'] ?? false;
    useGelbooruApiKey = data['useGelbooruApiKey'] ?? true;

    if (data['characters'] != null) {
      characters = (data['characters'] as List).map((e) => NaiCharacter.fromJson(e)).toList();
      if (characters.isEmpty) characters.add(NaiCharacter());
    }
    if (data['wildcards'] != null) {
      wildcards = (data['wildcards'] as List).map((e) => NaiWildcard.fromJson(e)).toList();
    }

    saveAllSettings();
    notifyListeners();
  }

  Future<void> saveAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_token', apiTokenController.text);
    await prefs.setString('custom_save_path', customSavePathController.text);
    await prefs.setString('custom_file_name', customFileNameController.text);
    await prefs.setString('custom_width', customWidthController.text);
    await prefs.setString('custom_height', customHeightController.text);
    await prefs.setString('conditional_rules', conditionalRuleController.text);

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
    await prefs.setBool('showImageInOtherTabs', showImageInOtherTabs);
    await prefs.setStringList('promptSectionOrder', promptSectionOrder);
    await prefs.setStringList('collapsedSections', collapsedSections.toList());
    await prefs.setBool('useGelbooruApiKey', useGelbooruApiKey);
    await prefs.setString('resolutionMode', resolutionMode);
    await prefs.setString('model', selectedModel);
    await prefs.setString('sampler', selectedSampler);
    await prefs.setString('scheduler', selectedScheduler);
    await prefs.setString('resolution', selectedResolution);
    await prefs.setString('characters', jsonEncode(characters.map((e) => e.toJson()).toList()));
    await prefs.setString('wildcards', jsonEncode(wildcards.map((e) => e.toJson()).toList()));
    await prefs.setString('presets', jsonEncode(presets.map((e) => e.toJson()).toList()));
    await prefs.setStringList('gelbooruPrompts', gelbooruPrompts);
    await prefs.setInt('currentPromptIndex', currentPromptIndex);
  }

  void refreshUI() => notifyListeners();

  void sendToI2i(Uint8List imageBytes, NaiMetadata? metadata) {
    targetI2iImage = imageBytes;
    targetI2iMetadata = metadata;
    notifyListeners();
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
      List<String> results = await _service.fetchDanbooruTags(
        includeTags: gelbooruIncludeController.text,
        excludeTags: gelbooruExcludeController.text,
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${results.length}개의 프롬프트를 찾았습니다.")));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("조건에 맞는 결과가 없습니다.")));
      }
    } catch (e) {
      isGelbooruLoading = false;
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("검색에 실패했습니다. 다시 시도해주세요."), backgroundColor: Colors.redAccent),
      );
    }
    notifyListeners();
  }

  String _sortNovelAIPrompt(String prompt) {
    List<String> tags = prompt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    List<String> group1 = [];
    List<String> group2 = [];
    List<String> group3 = [];
    List<String> group4 = [];
    List<String> groupRest = [];

    final personRegex = RegExp(r'^(\d+|\d+\+)\s?(girl|girls|boy|boys)$');

    for (String tag in tags) {
      String lowerTag = tag.toLowerCase();

      if (personRegex.hasMatch(lowerTag) ||
          lowerTag == 'multiple girls' ||
          lowerTag == 'multiple boys') {
        group1.add(tag);
      } else if (lowerTag.startsWith('from ')) {
        group2.add(tag);
      } else if (lowerTag.startsWith('looking ')) {
        group3.add(tag);
      } else if (lowerTag.contains('background')) {
        group4.add(tag);
      } else {
        groupRest.add(tag);
      }
    }

    List<String> sortedTags = [...group1, ...group2, ...group3, ...groupRest, ...group4];
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
        if (hasColor) continue;
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

    String finalConditioned = _applyConditionalRules(combined, rating);
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
      if (options.length < 2) return match.group(0)!;
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
      int sepIdx = ruleStr.indexOf('):');
      if (sepIdx == -1) {
        continue;
      }

      String condStr = ruleStr.substring(1, sepIdx);
      String actionStr = ruleStr.substring(sepIdx + 2);

      List<String> orGroups = condStr.split('|');
      bool conditionMet = false;

      for (String group in orGroups) {
        List<String> andConditions = group.split('&');
        bool groupMet = true;

        for (String c in andConditions) {
          String trimmedC = c.trim();
          if (trimmedC.isEmpty) {
            continue;
          }

          bool negate = trimmedC.startsWith('!');
          String pattern = negate ? trimmedC.substring(1) : trimmedC;
          bool matched = false;

          if (pattern == 'g' || pattern == 's' || pattern == 'q' || pattern == 'e') {
            matched = (rating.toLowerCase() == pattern.toLowerCase());
          } else {
            matched = tags.any((tag) => _isMatch(tag, pattern));
          }

          if (negate && matched) {
            groupMet = false;
            break;
          }
          if (!negate && !matched) {
            groupMet = false;
            break;
          }
        }
        if (groupMet) {
          conditionMet = true;
          break;
        }
      }

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

    String combined =
        "${prefixController.text},${positiveController.text},${suffixController.text}";
    String step1 = _processWildcards(combined);

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
      );

      isLoading = false;
      currentImageBytes = result.image ?? currentImageBytes;
      lastErrorMessage = result.error;

      if (result.image != null) {
        sessionGenerateCount++;
        if (historyImages.length >= 100) {
          _removeOldestNonFavorite();
        }
        historyImages.add(result.image!);
        historyFavorites.add(false);

        String? savedPath;
        if (isAutoSave) {
          if (context.mounted) {
            savedPath = await autoSaveImage(context, result.image!);
          } else {
            savedPath = await autoSaveImage(null, result.image!);
          }
        }
        historyFilePaths.add(savedPath);

        NaiMetadata? parsedMeta = extractNovelAIMetadata(result.image!);
        // 서버가 PNG 메타데이터에 variety_plus를 기록하지 않으므로 앱에서 직접 주입
        if (parsedMeta != null) {
          parsedMeta = parsedMeta.copyWithExtra({'variety_plus': isVariancePlus});
        }
        historyMetadata.add(parsedMeta);

        selectedHistoryIndex = historyImages.length - 1;
        scrollToThumbnailEnd = true;
        saveHistoryToLocal();

        onScrollToHistoryEnd();
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

  // 🚀 [추가] 엄격한 뮤텍스 잠금을 위한 변수 선언 [cite: 479]
  bool _isInpaintProcessing = false;

  Future<void> handleInpaintGenerate(BuildContext context, Uint8List maskBytes) async {
    // 1. 뮤텍스 검사: 앞선 작업 진행 중이라면 다중 클릭 무시 [cite: 62]
    if (_isInpaintProcessing) {
      debugPrint('이미 처리 중입니다. 중복 요청을 무시합니다.');
      return;
    }

    if (!isApiConnected) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("설정 탭에서 API 키를 먼저 연결해주세요.")));
      }
      return;
    }
    if (targetI2iImage == null || targetI2iMetadata == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("히스토리 탭에서 이미지를 먼저 선택해주세요.")));
      }
      return;
    }

    // 🚀 잠금 활성화 [cite: 64]
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
          if (bgInitialized) await FlutterBackground.enableBackgroundExecution();
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
        if (historyImages.length >= 100) {
          _removeOldestNonFavorite();
        }
        historyImages.add(result.image!);
        historyFavorites.add(false);

        NaiMetadata? parsedMeta = extractNovelAIMetadata(result.image!);
        historyMetadata.add(parsedMeta);

        String? savedPath;
        if (isAutoSave) {
          savedPath = await autoSaveImage(context.mounted ? context : null, result.image!);
        }
        historyFilePaths.add(savedPath);

        selectedHistoryIndex = historyImages.length - 1;
        scrollToThumbnailEnd = true;
        saveHistoryToLocal();
        navigateToTab(1);
      }

      await fetchAnlas();
    } catch (e) {
      debugPrint('인페인트 파이프라인 에러: $e'); // [cite: 73]
    } finally {
      // 🚀 성공/실패 여부와 관계없이 반드시 락 해제 [cite: 75]
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("설정 탭에서 API 키를 먼저 연결해주세요.")));
      return;
    }
    if (targetI2iImage == null || targetI2iMetadata == null) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("히스토리 탭에서 이미지를 먼저 선택해주세요.")));
      return;
    }

    int width = targetI2iMetadata!.width;
    int height = targetI2iMetadata!.height;

    // 🚀 [수정] PDF 가이드라인 적용: 1024x1024 픽셀 한계 검증 (면적 기준 계산) [cite: 168]
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
            "업스케일 API는 1024x1024 (1,048,576 픽셀) 면적 이하인 원본 이미지만 처리할 수 있습니다.\n\n현재 해상도: ${width}x$height", // [cite: 168]
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
        if (historyImages.length >= 100) {
          _removeOldestNonFavorite();
        }
        historyImages.add(result.image!);
        historyFavorites.add(false);

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

        historyMetadata.add(parsedMeta);

        // 업스케일 결과는 항상 저장
        String? savedPath;
        if (context.mounted) {
          savedPath = await autoSaveImage(context, result.image!);
        } else {
          savedPath = await autoSaveImage(null, result.image!);
        }
        historyFilePaths.add(savedPath);

        selectedHistoryIndex = historyImages.length - 1;
        scrollToThumbnailEnd = true;
        saveHistoryToLocal();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("이미지를 성공적으로 불러왔습니다!")));
      }
    } catch (e) {
      debugPrint("이미지 불러오기 오류: $e");
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("이미지를 불러오는 데 실패했습니다.")));
    }
  }

  void toggleHistoryFavorite(int index) {
    if (index < 0 || index >= historyFavorites.length) return;
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
    if (targetIndex == -1) return;

    historyImages.removeAt(targetIndex);
    if (targetIndex < historyMetadata.length) historyMetadata.removeAt(targetIndex);
    if (targetIndex < historyFavorites.length) historyFavorites.removeAt(targetIndex);
    if (targetIndex < historyFilePaths.length) historyFilePaths.removeAt(targetIndex);

    // selectedHistoryIndex 보정
    if (targetIndex <= selectedHistoryIndex) {
      selectedHistoryIndex--;
      if (selectedHistoryIndex < 0) selectedHistoryIndex = 0;
    }
  }

  void deleteHistoryImage(int index) {
    if (index < 0 || index >= historyImages.length) {
      return;
    }

    historyImages.removeAt(index);
    if (index < historyMetadata.length) historyMetadata.removeAt(index);
    if (index < historyFavorites.length) historyFavorites.removeAt(index);
    if (index < historyFilePaths.length) historyFilePaths.removeAt(index);

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
    saveHistoryToLocal();
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

  Future<void> saveHistoryToLocal() async {
    try {
      final dir = await _getHistoryDir();

      // 기존 파일 전부 삭제 후 새로 저장
      final existing = dir.listSync().whereType<File>();
      for (final f in existing) {
        await f.delete();
      }

      // 이미지 저장 (최신 30개: 원본 PNG, 나머지: 썸네일 JPEG)
      final int total = historyImages.length;
      for (int i = 0; i < total; i++) {
        final bool isRecent = (total - i) <= 30;
        final bool hasFileOnDevice = await _checkFileExists(i);

        if (isRecent || hasFileOnDevice) {
          final file = File('${dir.path}/img_$i.png');
          await file.writeAsBytes(historyImages[i]);
        } else {
          try {
            final decoded = img.decodeImage(historyImages[i]);
            if (decoded != null) {
              final thumbnail = img.copyResize(decoded, width: 200);
              final jpegBytes = img.encodeJpg(thumbnail, quality: 70);
              final file = File('${dir.path}/thumb_$i.jpg');
              await file.writeAsBytes(jpegBytes);
            } else {
              final file = File('${dir.path}/img_$i.png');
              await file.writeAsBytes(historyImages[i]);
            }
          } catch (_) {
            final file = File('${dir.path}/img_$i.png');
            await file.writeAsBytes(historyImages[i]);
          }
        }
      }

      // 메타데이터 저장
      final metaList = historyMetadata.map((m) => m?.toJson()).toList();
      final metaFile = File('${dir.path}/metadata.json');
      await metaFile.writeAsString(jsonEncode(metaList));

      // 즐겨찾기 저장
      final favFile = File('${dir.path}/favorites.json');
      await favFile.writeAsString(jsonEncode(historyFavorites));

      // 파일 경로 저장
      final pathsFile = File('${dir.path}/paths.json');
      await pathsFile.writeAsString(jsonEncode(historyFilePaths));

      debugPrint("✅ 히스토리 ${historyImages.length}개 로컬 저장 완료");
    } catch (e) {
      debugPrint("❌ 히스토리 저장 실패: $e");
    }
  }

  Future<void> _loadHistoryFromLocal() async {
    try {
      final dir = await _getHistoryDir();
      final metaFile = File('${dir.path}/metadata.json');
      if (!await metaFile.exists()) return;

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
    } catch (e) {
      debugPrint("❌ 히스토리 불러오기 실패: $e");
    }
  }

  // ============================================================================
  // 파일 존재 여부 확인
  // ============================================================================
  Future<bool> _checkFileExists(int index) async {
    if (index < 0 || index >= historyFilePaths.length) return false;
    final path = historyFilePaths[index];
    if (path == null || path.isEmpty) return false;
    return File(path).exists();
  }

  bool checkFileExistsSync(int index) {
    if (index < 0 || index >= historyFilePaths.length) return false;
    final path = historyFilePaths[index];
    if (path == null || path.isEmpty) return false;
    return File(path).existsSync();
  }

  // ============================================================================
  // 히스토리 이미지가 썸네일(경량)인지 확인
  // ============================================================================
  bool isHistoryThumbnail(int index) {
    if (index < 0 || index >= historyImages.length) return false;
    final bytes = historyImages[index];
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true; // JPEG = 썸네일
    }
    return false; // PNG = 원본
  }

  // ============================================================================
  // 메타데이터로 이미지 재생성 (썸네일만 있는 경우)
  // ============================================================================
  Future<void> regenerateFromMetadata(BuildContext context, int index) async {
    if (index < 0 || index >= historyMetadata.length) return;
    final meta = historyMetadata[index];
    if (meta == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("메타데이터가 없어 재생성할 수 없습니다.")));
      }
      return;
    }

    if (apiToken.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("API 토큰이 설정되지 않았습니다.")));
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
        model: meta.source.isNotEmpty ? meta.source : selectedModel,
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

        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("이미지 재생성 및 저장 완료!")));
        }
      } else if (result.error != null && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("재생성 실패: ${result.error}")));
      }
      await fetchAnlas();
    } catch (e) {
      debugPrint("재생성 오류: $e");
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("재생성 중 오류가 발생했습니다.")));
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
    try {
      String basePath = customSavePathController.text.trim();
      if (basePath.isEmpty) {
        basePath = '/storage/emulated/0/Download';
      }
      final directory = Directory('$basePath/DNaiApp/$sessionFolderName');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      String fileName = _getFormattedFileName("");
      final file = File("${directory.path}/$fileName.png");
      await file.writeAsBytes(bytes);

      if (Platform.isAndroid) {
        try {
          MediaScanner.loadMedia(path: file.path);
        } catch (e) {
          debugPrint("자동 저장 미디어 스캔 오류: $e");
        }
      }

      if (context != null) {
        if (!context.mounted) {
          return file.path;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("자동 저장 완료 ($fileName)"), duration: const Duration(seconds: 1)),
        );
      }
      return file.path;
    } catch (e) {
      debugPrint("자동 저장 오류: $e");
    }
    notifyListeners();
    return null;
  }

  Future<void> manualSaveImage(BuildContext context, Uint8List bytes) async {
    sessionSaveCount++;
    sessionFolderName ??= DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    try {
      String basePath = customSavePathController.text.trim();
      if (basePath.isEmpty) {
        basePath = '/storage/emulated/0/Download';
      }
      final directory = Directory('$basePath/DNaiApp/$sessionFolderName');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      String fileName = _getFormattedFileName("Manual");
      final file = File("${directory.path}/$fileName.png");
      await file.writeAsBytes(bytes);

      if (Platform.isAndroid) {
        try {
          MediaScanner.loadMedia(path: file.path);
        } catch (e) {
          debugPrint("수동 저장 미디어 스캔 오류: $e");
        }
      }

      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("이미지가 지정된 경로에 안전하게 저장되었습니다!")));
    } catch (e) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("저장에 실패했습니다. 저장 경로를 확인해주세요.")));
    }
    notifyListeners();
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

    int steps = int.tryParse(stepsController.text) ?? 28;
    bool isOpus = subscriptionTier >= 3;

    if (isOpus && (width * height) <= 1048576 && steps <= 28) {
      return false;
    }

    return true;
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
