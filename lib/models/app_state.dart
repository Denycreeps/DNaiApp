import 'package:flutter/services.dart' show rootBundle;
// smartMatchTags / kContainsMarker 의 실제 정의는 utils/prompt_utils.dart 에 있다.
// app_state 를 import 하던 기존 호출부가 그대로 쓰도록 이름만 다시 내보낸다.
export '../utils/prompt_utils.dart' show smartMatchTags, kContainsMarker;
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:collection'; // ListBase — 히스토리 필드 창(_HistoryField)
import 'dart:convert';
import 'dart:isolate'; // 큰 설정 묶음 JSON 만들기·읽기를 화면 밖에서 (encodeSettingsJson)
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_stream/saf_stream.dart';

import '../novelai_service.dart';
import '../tag_filters.dart';
import '../app_theme.dart';
import 'nai_character.dart';
import 'model_caps.dart';
import 'app_tabs.dart';
import 'i2i_modes.dart';
import 'outpaint.dart'
    show kOutpaintStrength, OutpaintPlacement, OutpaintRect; // 확장(i2i 인페인트로 빈칸 채우기) — 강도 · 직전 배치
import 'focus_inpaint.dart'
    show FocusPlan, focusPlan, composeFocusResult, kFocusContextDefault, kFocusContextMax; // 부분 인페인트
import 'director_tools.dart';
import 'prompt_dict.dart';
import '../utils/image_codec.dart'; // WebP 굽기·썸네일 규칙 (한곳)
import 'nai_account.dart';
import 'text_controllers.dart';
import 'preset_models.dart';
import 'image_metadata.dart';
import 'nai_presets.dart';
import '../utils/qwen_tokenizer.dart';
import '../utils/split_image_store.dart'; // i2i 릴·즐겨찾기 보관 (목록 + 그림 파일)
import '../utils/temp_files.dart'; // 그림 고르기 · 캐시 잠깐 파일 정리 · 섬네일 캐시 상한
import '../utils/generation_notifier.dart'; // 생성 진행 · 완료 알림 (app_state_notify.dart 가 부른다)
import 'setting_field.dart'; // 설정 한 줄 등록 (AppState._settings)
import 'prompt_pipeline.dart'; // 와일드카드 · 순차 생성 · 조건부 트리거 · 가중치 표시 (순수 함수)
import 'prompt_search.dart'; // 검색어 펼치기 · 받은 태그 다듬기 (순수 함수)
import '../widgets/app_toast.dart';
import '../widgets/confirm_dialog.dart';

// AppState 를 기능별 파일로 나눈 것 (같은 라이브러리 — 숨은 값도 그대로 쓴다)
part 'app_state_search.dart'; // 프롬프트 검색 (Gelbooru)
part 'app_state_history.dart'; // 히스토리 (넣기 · 지우기 · 저장/불러오기 · 다시 생성 · 다시 뽑기 · HistoryEntry)
part 'app_state_update.dart'; // 앱 업데이트 (새 버전 확인 · APK 내려받기/설치 · 업데이트 전 자동 백업)
part 'app_state_notify.dart'; // 생성 진행 · 완료 알림 (언제 무엇을 알릴지)

// i2i 작업 이미지가 바뀔 때 마스킹(_strokes)을 어떻게 처리할지.
// 1회용 소비 신호 대신 이 값을 함께 세팅하여 build 타이밍 문제를 방지한다.
/// Anlas 추정 대상 작업.
///  작업마다 계산 규칙이 달라 AppState.anlasFor 가 여기서 갈라진다.
enum AnlasJob { generate, inpaint, img2img, director, upscale }

/// 저장 폴더(SAF) 고르기 결과 — 설정 화면이 알맞은 안내를 띄우는 데 쓴다.
enum SafPickResult { picked, cancelled, duplicate }

/// 이미지 한 장 생성의 결과 — 연속 생성이 계속할지 정하는 데 쓴다 (AppState.handleGenerate).
enum GenerateOutcome {
  /// 그림을 받았다 (또는 할 일이 없었다)
  ok,

  /// 서버가 바쁘거나 연결이 흔들렸다 — 다음 장은 될 수도 있다 (연속으로 여러 번이면 멈춘다)
  retryable,

  /// 다시 해도 같을 오류 (키 · Anlas · 요청 내용 · 한도 · Vibe 인코딩 · 앱 쪽 오류) — 연속 생성을 바로 멈춘다
  stop,
}

enum I2iMaskAction {
  clearMask, // 마스크 초기화 (i2i로 새 이미지 보내기 등)
  keepMask, // 마스크 유지 (릴 결과 채택 등)
  followInpaintSetting, // 인페인트 자동 해제 설정(inpaintAutoClearMask)을 따름
}

// 인페인트 마스크의 한 획. AppState에 보관하여 i2i 탭 위젯이 재생성돼도(PageView가
// 멀리 있는 페이지를 정리하는 경우) 마스크가 사라지지 않도록 한다.
class MaskStroke {
  final List<Offset> points;
  final double size;
  final bool isEraser;
  final bool isCircle;

  /// 마스킹 반전 표시 (점이 없다) — 앞의 획들을 다 그린 뒤 칠한 곳 ↔ 안 칠한 곳을 뒤집는다.
  ///  뒤의 획은 그 위에 그대로 그린다 (반전한 뒤 붓으로 칠하면 칠해지고, 지우개로 지우면 지워진다).
  ///  화면(MaskPainter) · 보내는 마스크(_buildMaskRaw) · 모자이크가 같은 순서로 따른다 (i2i_tab.dart).
  final bool isInvert;

  MaskStroke({
    required this.points,
    required this.size,
    required this.isEraser,
    required this.isCircle,
    this.isInvert = false,
  });

  /// 마스킹 반전 (브러시 설정 창의 '마스킹 반전')
  MaskStroke.invert()
    : points = const [],
      size = 0,
      isEraser = false,
      isCircle = false,
      isInvert = true;
}

// ============================================================================
// 스마트 태그 매칭: 공백으로 단어 조각을 구분하여 검색
// "ca t" → cat_tail (ca→cat, t→tail) 매칭, cat_ears 제외
// 단일 단어면 기존 startsWith 동작과 동일
// ============================================================================
// † 접두어 = 보조 매칭 결과 (UI에서 연한 스타일로 구분)
// ============================================================================

// ============================================================================
// 프롬프트 토큰 추정기
// ============================================================================
//  모델마다 토크나이저가 달라 방식을 나눈다 (ModelCaps.tokenizer).
//
//  · T5   (V4/V4.5) : 영문 태그 기준 평균 3.1글자당 1토큰. 글자수 근사로 충분.
//  · Qwen (V5)      : QwenTokenizer가 실제 BPE를 돌려 '정확한' 값을 낸다.
//                     글자수 근사는 영문 4.2 / 일본어 1.0 글자당 1토큰으로
//                     4배 넘게 벌어져 쓸 수 없다.
//                     (사전 로드 전이면 QwenTokenizer가 알아서 근사값을 준다)

// 토큰 수 캐시.
//
// ⚠️ 이게 없으면 앱이 멈춘다.
//    화면에는 토큰 표시가 3곳 있고, 각 표시가 estimateBaseTokens +
//    estimateCharacterTokens 를 부른다. 즉 리빌드 한 번에 BPE 가 6번 돈다.
//    V5(Qwen)는 글자수 나눗셈이 아니라 실제 BPE 병합을 돌리므로,
//    프롬프트가 길면 한 번에 수십만 번의 병합 연산이 된다.
//    입력창을 닫으면 saveAllSettings·refreshUI·setLocal 로 리빌드가 연달아
//    일어나는데, 그때마다 이 계산이 통째로 다시 돌아 메인 스레드가 막혔다.
//
//    같은 문자열은 결과가 항상 같으므로 그대로 재사용한다.
final Map<String, int> _tokenCountCache = {};

int estimateTokenCount(String prompt, {PromptTokenizer tokenizer = PromptTokenizer.t5}) {
  final t = prompt.trim();
  if (t.isEmpty) {
    return 0;
  }
  // T5 는 나눗셈 한 번이라 캐시가 필요 없다
  if (tokenizer == PromptTokenizer.t5) {
    return (t.length / 3.1).round();
  }

  final cached = _tokenCountCache[t];
  if (cached != null) {
    return cached;
  }
  final v = QwenTokenizer.countTokens(t);
  // 프롬프트를 고칠 때마다 새 항목이 쌓이므로 상한을 둔다.
  //  (오래된 것부터 버린다 — Map 은 넣은 순서를 유지한다)
  if (_tokenCountCache.length >= 64) {
    _tokenCountCache.remove(_tokenCountCache.keys.first);
  }
  _tokenCountCache[t] = v;
  return v;
}

/// 현재 선택된 모델이 쓰는 토크나이저
PromptTokenizer _tokenizerOf(AppState state) => modelCapsFor(state.selectedModel).tokenizer;

// 베이스 프롬프트(선행 + 긍정 + 후행 + Quality Tags)의 토큰 수.
//  ⚠️ 부정 프롬프트(UC)는 여기에 더하지 않는다.
//     긍정(베이스+캐릭터)과 부정(UC+캐릭터 UC)은 서로 다른 한도를 쓰기 때문에,
//     합산하면 부정을 길게 쓸수록 긍정 여유가 줄어드는 것처럼 잘못 보인다.
//     (예전 코드는 둘을 더해서 공식 카운터보다 훨씬 큰 값을 표시했다.)
int estimateBaseTokens(AppState state) {
  final combined = [
    state.prefixController.text,
    state.positiveController.text,
    state.suffixController.text,
  ].where((t) => t.trim().isNotEmpty).join(', ');
  final withQuality = state.applyQualityTags(combined);
  return estimateTokenCount(withQuality, tokenizer: _tokenizerOf(state));
}

/// 부정 프롬프트(UC 프리셋 포함)의 토큰 수. 긍정과는 별도 한도.
///
/// ⚠️ 현재 어디서도 부르지 않는다 (2026-08 기준).
///    긍정/부정 토큰을 분리하면서 함께 만들었지만, 부정 프롬프트가 한도에
///    닿는 경우가 사실상 없어서 화면에는 표시하지 않기로 했다.
///    "왜 부정은 안 세지?" 라는 의문이 생겼을 때 답이 되도록 남겨 둔다.
///    부정 카운터를 붙이고 싶으면 buildTokenLabel 옆에 이 값을 쓰면 되고,
///    끝내 필요 없다고 판단되면 이 함수째로 지워도 된다.
int estimateNegativeTokens(AppState state) {
  final negative = state.applyUcPreset(state.negativeController.text);
  return estimateTokenCount(negative, tokenizer: _tokenizerOf(state));
}

// 활성 캐릭터 프롬프트만의 토큰 수
int estimateCharacterTokens(AppState state) {
  final parts = <String>[];
  for (final c in state.characters) {
    if (!c.isActive) {
      continue;
    }
    parts.add(c.positive);
  }
  if (parts.isEmpty) {
    return 0;
  }
  return estimateTokenCount(
    parts.where((t) => t.trim().isNotEmpty).join(', '),
    tokenizer: _tokenizerOf(state),
  );
}

// 토큰 표시용 문자열. 캐릭터가 있으면 얼마나 차지하는지 구분해서 보여준다.
//   캐릭터 없음: "256 / 512"
//   캐릭터 있음: "312 (256+56) / 512"
String buildTokenLabel(AppState state, int maxTokens) {
  final base = estimateBaseTokens(state);
  final chars = estimateCharacterTokens(state);
  if (chars == 0) {
    return "$base / $maxTokens";
  }
  return "${base + chars} ($base+$chars) / $maxTokens";
}

// 현재 프롬프트의 총 토큰 수 (선행 + 긍정 + 후행 + 활성 캐릭터).
// NovelAI V4/V4.5는 "base prompt + 모든 character prompts를 합쳐서" ~512 토큰 제한이므로
// 캐릭터 프롬프트도 반드시 합산해야 실제 한도와 맞는다.
//   https://docs.novelai.net/en/image/models/
int estimateTotalTokens(AppState state) {
  return estimateBaseTokens(state) + estimateCharacterTokens(state);
}
// 구획 경계의 가중치 표시(weightTouchesBoundary) · 중첩 가중치 펼치기(expandNestedWeights)는
//  models/prompt_pipeline.dart 에 있다 (와일드카드 · 조건부 규칙 등과 함께 — 테스트하려고).
// 자동완성 매칭기(smartMatchTags)는 utils/prompt_utils.dart 로 옮겼다.
//  프롬프트탭·확대 입력창·와일드카드탭이 함께 쓰는데 AppState를 전혀 참조하지
//  않아서, 여기 두면 세 화면이 app_state 전체를 끌어와야 했다.
//  기존 호출부가 그대로 동작하도록 파일 상단에서 이름만 다시 내보낸다.

/// 프롬프트 검색 '검색 양' 한 단계 — 받을 페이지 수(1페이지 = 100개)와 화면에 보일 이름
typedef SearchAmount = ({int pages, String name, String amount});

/// 생성 과정 미리보기 한 장 — 중간 단계 그림(JPEG)과 몇 번째 스텝인지 (AppState.previewFrame)
typedef PreviewFrame = ({Uint8List image, int step, int steps});

/// 저장 폴더(SAF)의 그림 한 장 — 든 폴더(parentUri)와 수정 시각(ms)까지 (갤러리 검색 · listSafImagesDeep).
///  폴더가 섞인 목록에서 지우거나 옮길 때 원래 폴더를 알아야 해서 같이 들고 다닌다.
typedef SafImageRef = ({String uri, String name, String parentUri, int modified});

/// 옮길(휴지통 · 이동) 그림 한 장 — 지금 든 폴더(fromDirUri)까지.
///  갤러리 검색 결과처럼 폴더가 섞인 목록을 한 번에 다루려고 그림마다 들고 다닌다
///  (휴지통은 되돌릴 폴더로 적어 두고, 이동은 옮길 때 원래 폴더로 넘긴다).
typedef SafSourceRef = ({String uri, String name, String fromDirUri});

/// 직전 확장 한 번 — 보낸 원본 그림 · 그 정보 · 자리(크기 · 회전) · 자른 곳 · 경계 · 판 크기 (AppState.lastOutpaint).
///  i2i 탭의 '확장' 꾹이 이걸로 그때 배치를 그대로 다시 놓는다.
typedef LastOutpaint = ({
  Uint8List image,
  NaiMetadata? meta,
  OutpaintPlacement placement,
  OutpaintRect crop,
  int overlap,
  int canvasW,
  int canvasH,
});

class AppState extends ChangeNotifier {
  // ============================================================================
  // 앱 버전 & 업데이트 체크 — 값만 여기. 확인 · 내려받기 · 설치 · 업데이트 전 자동 백업은 app_state_update.dart
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

  // 업데이트 다이얼로그가 이번 세션에 이미 표시됐는지 (자동 알림/수동 열기 공유 가드).
  // 수동으로 열 때도 이 값을 켜서, main의 자동 알림이 겹쳐 뜨지 않게 한다.
  bool updateDialogShown = false;

  /// 업데이트 전 백업 중인지 (설정 > 기타 에 상태를 보여 주는 데 쓴다)
  bool isBackingUpBeforeUpdate = false;

  /// 이번에 앱을 켠 뒤 이미 백업해 둔 대상 버전.
  ///  ⚠️ 설치창에서 취소하고 다시 누를 때마다 백업하면, 거의 같은 파일 3개가
  ///     칸을 다 채워 '이전 버전 때 백업'이 밀려난다. 그래서 한 번만 뜬다.
  ///  일부러 저장하지 않는다 — 앱이 꺼졌다 켜지면 상태가 바뀌었을 수 있으니
  ///  그때는 다시 뜨는 게 맞다.
  String? _autoBackupDoneFor;

  // ============================================================================

  final TextEditingController positiveController = WeightHighlightController();
  final TextEditingController negativeController = WeightHighlightController();
  final TextEditingController prefixController = WeightHighlightController();
  final TextEditingController suffixController = WeightHighlightController();

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
  final TextEditingController customFileNameController = TextEditingController(
    text: "Nai-{yy}{mm}{dd}-{time}",
  );
  final TextEditingController customWidthController = TextEditingController(text: "$kDefaultWidth");
  final TextEditingController customHeightController = TextEditingController(
    text: "$kDefaultHeight",
  );

  final SyntaxHighlightController conditionalRuleController = SyntaxHighlightController();

  /// AppState가 버려질 때 컨트롤러·타이머를 정리한다.
  ///  ⚠️ 여기 목록은 위에서 선언한 Controller와 1:1로 맞춰야 한다.
  ///     새 컨트롤러를 추가하면 반드시 이 목록에도 넣을 것.
  ///  ※ 앱 수명 = AppState 수명이라 실사용에선 종료 시점에만 불리지만,
  ///     ChangeNotifier 계약상 정리 책임은 이쪽에 있다.
  @override
  void dispose() {
    // 예약된 저장 작업이 남아 있으면 취소 (dispose 이후 notifyListeners 방지)
    _saveSettingsDebounce?.cancel();
    _historySaveDebounce?.cancel();

    for (final c in <TextEditingController>[
      positiveController,
      negativeController,
      prefixController,
      suffixController,
      inpaintPositiveController,
      inpaintNegativeController,
      inpaintPrefixController,
      inpaintSuffixController,
      stepsController,
      cfgScaleController,
      cfgRescaleController,
      seedController,
      apiTokenController,
      gelbooruApiController,
      gelbooruIncludeController,
      gelbooruExcludeController,
      customRemoveController,
      customFileNameController,
      customWidthController,
      customHeightController,
      conditionalRuleController,
    ]) {
      c.dispose();
    }
    previewFrame.dispose();
    super.dispose();
  }

  // 조건부 트리거 작동 시점: "random"(랜덤 프롬프트 생성 시) / "generate"(이미지 생성 시)
  String conditionalTriggerMode = "random";

  bool ratingE = false;
  bool ratingQ = false;
  bool ratingS = false;
  bool ratingG = true;
  bool removeCharacteristics = false;
  bool removeClothes = false;
  // 의상 상태/동작 태그 제거 (unworn, torn, grab 등)
  bool removeClothingEvents = false;
  // 중복 태그 정리: 구체적인 태그가 있으면 그것이 함의하는 상위 태그를 제거
  //   예: "plaid skirt"가 있으면 "skirt"는 중복이므로 삭제 → 토큰 절약
  bool removeImpliedTags = false;

  // 캐릭터 탭에서 선택된 캐릭터를 한 번 더 눌러 ON/OFF 하는 기능
  // (자주 탭하는 사람은 오조작이 잦다는 의견이 있어 끌 수 있게 함)
  bool charRetapToggle = true;

  // 저장 폴더를 '날짜'로만 만든다 (기본 OFF = 실행할 때마다 날짜_시간 폴더)
  bool saveFolderByDateOnly = true;
  bool removeColors = false;
  // 랜덤 프롬프트에서 캐릭터 이름 태그 제거 (기본 켜짐 = 예전처럼 지운다).
  //  검색할 때 캐릭터는 항상 살려서 표시해 두고, 이 스위치는 적용할 때만 본다
  //  → 끄면 다시 검색할 필요 없이 캐릭터가 살아난다. (작가·작품·메타는 늘 지운다)
  bool removeCharacterTags = true;
  bool isAutoSave = true;
  // 자동 저장 버튼 잠금 — 잠그면 눌러도 ON/OFF 가 안 바뀐다 (꾹 눌러 잠그고 · 풀기). 기본 꺼짐
  bool autoSaveLocked = false;
  // 자동 저장이 꺼진 채 연속 생성(2장 이상 · 무한)을 누르면 한 번 묻는다 (설정 > 저장). 기본 꺼짐
  bool warnBatchWithoutAutoSave = false;
  // Anlas 소모 확인 창 안 띄우기 (설정 > 일반 > 동작 · 기타, 기본 꺼짐 = 예전처럼 묻는다).
  //  켜면 묻지 않는 대신 Anlas 가 드는 실행 버튼에 빨간 테두리가 생긴다 (anlasMarked).
  //  ⚠️ 원본 모델을 몰라 지금 모델로 만들 때(다시 뽑기)처럼 비용이 아닌 이유로 묻는 창은 그대로 뜬다.
  bool skipAnlasConfirm = false;
  // 이미지를 WebP(무손실)로 저장 — 용량 약 26% 절감, 메타데이터는 EXIF로 보존
  bool saveAsWebp = false;
  // WebP 저장 시 손실 압축(품질 95) 사용 — 화질 차이 거의 없이 용량이 크게 줄어든다
  bool webpLossy = false;

  /// 설정(두 스위치)으로 정해지는 저장 형식.
  ///  설정 값 자체(saveAsWebp·webpLossy)는 그대로 두고 여기서 해석만 한다
  ///  → 옛 설정·백업과 그대로 호환된다. 확장자·품질은 image_codec.dart 의 SaveFormat 에 있다.
  SaveFormat get saveFormat =>
      !saveAsWebp ? SaveFormat.png : (webpLossy ? SaveFormat.webpLossy : SaveFormat.webpLossless);
  bool isRandomLocked = false;
  bool isSeedLocked = false;
  // 인페인트 강도 — 1 = 칠한 곳을 처음부터 새로 그린다 (공식 기본값). 낮추면 원래 모양을 남긴 채 다시 그린다 (img2img 인페인트).
  //  ⚠️ 예전 기본값은 0.7 이었다 — 물건을 지우려 해도 원래 모양이 남아 비슷한 것이 다시 그려졌다 (저장된 값은 그대로 둔다).
  double infillStrength = 1.0;
  // 부분 인페인트의 맥락 폭 (보낼 판 픽셀) — 상자 안쪽 테두리의 빨간 띠 (다시 그리지 않고 둘레를 보는 데만, focus_inpaint.dart).
  //  i2i 탭의 '부분' 을 한 번 더 누르면 바꾼다 (공식 'Minimum Context Area').
  int focusInpaintContext = kFocusContextDefault;
  // img2img: 원본 변형 강도(낮을수록 원본 충실) / 노이즈(새 디테일 추가량)
  double img2imgStrength = 0.5;
  double img2imgNoise = 0.1;
  bool isVariancePlus = false; // VAR+ (Variety+) 모드
  // V5 Full 의 Medium effort (상세 환경 오른쪽 아래 'Effort' — 켜면 Medium). V5 Full 에서만 쓰인다.
  //  켜면 공식처럼 스텝 14 · Euler Ancestral · Rescale 0 · 부정 프롬프트 고정(Heavy)으로 보낸다 — 입력칸의 값은 그대로 둔다.
  bool effortMedium = false;

  /// 지금 생성에 Medium effort 가 실제로 쓰이는지 (V5 Full 을 골랐을 때만)
  bool get effortMediumActive => effortMedium && selectedModel == NaiModels.v5Full;

  /// 보낼 스텝 — Medium 이면 14 고정, 아니면 입력값 (비용 추정 · 무료 판단 · 생성이 같이 쓴다)
  int get effectiveSteps =>
      effortMediumActive ? kMediumEffortSteps : (int.tryParse(stepsController.text) ?? 28);
  bool horizontalSwipeEnabled = false; // 좌우 스와이프 탭 전환
  // 검색 양 = 받을 페이지 수 (본인 API 키가 있을 때만 쓰인다). searchAmounts 중 하나 — 기본 40.
  int gelbooruSearchPages = 40;
  // (예전 '[실험] 정렬 다양화' 는 섞기 번호(sort:random:번호)를 쓰면서 쓸모가 없어져 뺐다 —
  //  점수순·최신순은 늘 같은 순서라, 섞으면 검색을 거듭할수록 오히려 같은 그림이 반복됐다)

  /// 검색 양 단계. 예전엔 40~120 슬라이더(5 단위)였는데, 이제 결과 수를 보고 필요한 만큼만 받고
  ///  섞기 순서로 고르게 뽑아서 45 와 50 같은 차이는 체감되지 않는다 → 세 단계로 줄였다.
  static const List<SearchAmount> searchAmounts = [
    (pages: 40, name: "보통", amount: "약 4천 개"),
    (pages: 80, name: "많이", amount: "약 8천 개"),
    (pages: 120, name: "최대", amount: "약 1만 2천 개"),
  ];

  /// 저장된 값을 가장 가까운 단계로 맞춘다 (예전 슬라이더 값·가져온 설정 파일 값 — 같은 거리면 작은 쪽)
  static int snapSearchPages(int v) {
    int best = searchAmounts.first.pages;
    for (final a in searchAmounts) {
      if ((a.pages - v).abs() < (best - v).abs()) {
        best = a.pages;
      }
    }
    return best;
  }
  // 프롬프트 탭 캐릭터 편집 서랍 표시 (기본 OFF)
  bool promptCharDrawerEnabled = true;
  bool historySlideEnabled = false; // 히스토리 이미지 슬라이드 (화살표 + 애니메이션)
  bool randomPromptAlphabetical = false; // 랜덤 프롬프트 나머지 태그 알파벳 순서
  bool ignoreRecommendedOrder = false; // NovelAI 권장 순서(인원/solo/시점 등) 무시
  bool weightHighlight = true; // 가중치 문법 색상 하이라이트 (기본 ON)

  // 배치 생성
  int batchCount = 1; // 1, 2, 3, 4, 0(무한)
  // 순차 생성 <A|B|C> 카운터: 키=위치인덱스, 값=현재 회차
  final Map<String, int> _sequentialCounters = {};
  int batchRemaining = 0; // 남은 생성 수
  bool isBatchMode = false;
  double batchDelay = 0.5; // 연속 생성 딜레이 (초)
  bool autoNextPromptInBatch = false; // 자동생성 중 이미지 1장마다 다음 프롬프트 자동 전환
  // 같은 프롬프트로 N번 반복 후 다음 프롬프트로 (자동 전환이 ON일 때만 의미 있음)
  bool repeatSamePromptEnabled = false;
  int repeatSamePromptCount = 2;
  // 현재 반복 진행 상황 (UI 표시용) — 반복 미사용 시 0
  int currentRepeatIndex = 0; // 현재 몇 번째 반복인지 (1부터)
  int currentRepeatTotal = 0; // 이번 회차의 총 반복 횟수

  /// 프롬프트 하나당 몇 장 만드는지 (같은 프롬프트 반복 — 자동 전환 + 반복이 둘 다 ON 일 때만 2 이상)
  int get _repeatsPerPrompt =>
      (autoNextPromptInBatch && repeatSamePromptEnabled) ? repeatSamePromptCount.clamp(1, 99) : 1;

  // 생성 진행 · 완료 알림 (설정, 기본 꺼짐 — 쓰던 사람이 헷갈리지 않게). 하는 일은 app_state_notify.dart
  bool generationNotify = false;

  // 생성 과정 미리보기 (설정, 기본 꺼짐) — 켜면 스트리밍으로 생성해 중간 단계를 이미지 자리에 보여 준다.
  //  중간 그림은 AppState 전체를 다시 그리지 않게 따로 알린다 (main.dart 이미지 자리만 ValueListenableBuilder 로 듣는다).
  bool streamPreview = false;
  final ValueNotifier<PreviewFrame?> previewFrame = ValueNotifier<PreviewFrame?>(null);

  /// 미리보기를 받을 곳 — 설정이 꺼져 있으면 null (그러면 보통 요청으로 생성한다)
  void Function(Uint8List image, int step, int steps)? get _previewSink => streamPreview
      ? (Uint8List image, int step, int steps) =>
            _setPreview((image: image, step: step, steps: steps))
      : null;

  /// 미리보기를 걷는다 — 생성이 끝날 때 · 스트리밍 시도가 실패해 다시 할 때 (generateImage 의 onPreviewReset)
  void _clearPreview() => _setPreview(null);

  /// 미리보기를 바꿔 끼운다 (null = 걷기). 앞 그림은 그림 캐시에서 뺀다.
  ///  ⚠️ 중간 그림은 스텝마다 새 그림이라, 그대로 두면 한 장 만드는 동안 수십 장이 그림 캐시(100MB)를 채워
  ///     히스토리 · 갤러리 썸네일이 캐시에서 밀려나 다시 풀어야 했다. (화면에 떠 있는 그림은 빼도 그대로 보인다)
  void _setPreview(PreviewFrame? next) {
    final PreviewFrame? old = previewFrame.value;
    if (old != null) {
      PaintingBinding.instance.imageCache.evict(MemoryImage(old.image));
    }
    previewFrame.value = next;
  }
  bool _ntfRunning = false; // 이번 생성을 알리는 중인지 (시작할 때 설정이 켜져 있었는지)
  int _ntfTotal = 0; // 이번에 만들 전체 장수 (1 = 한 장, 0 = 무한)
  int _ntfTried = 0; // 시도한 수 (진행 막대)
  int _ntfStartCount = 0; // 시작할 때의 sessionGenerateCount — 받은 장수 = 지금 값 - 이 값

  // 탭 활성화 상태 (프롬프트/설정은 항상 켜짐)
  bool historyTabEnabled = true;
  // 설정 하위탭별 스크롤 위치. 탭 표시를 토글하면 PageView가 재생성되어
  // 위젯 로컬 ScrollController가 초기화되므로, 위치를 여기 보관해 복원한다.
  final Map<int, double> settingsScrollOffsets = {};

  bool i2iTabEnabled = true;
  // i2i 탭 안에서 각 모드를 보일지 (4개 모두 끄면 i2i 탭 자체가 꺼짐)
  bool i2iModeInpaintEnabled = true;
  bool i2iModeMosaicEnabled = true;
  bool i2iModeImg2imgEnabled = true;
  bool i2iModeUpscaleEnabled = true;

  /// 모드가 켜져 있는지 (설정 값은 모드마다 따로 저장돼 있다)
  bool isI2iModeEnabled(I2iMode mode) => switch (mode) {
    I2iMode.inpaint => i2iModeInpaintEnabled,
    I2iMode.mosaic => i2iModeMosaicEnabled,
    I2iMode.img2img => i2iModeImg2imgEnabled,
    I2iMode.upscale => i2iModeUpscaleEnabled,
  };

  // 현재 켜져 있는 i2i 모드 목록 (표시 순서 = I2iMode 에 적힌 순서)
  List<I2iMode> get enabledI2iModes => [
    for (final m in I2iMode.values)
      if (isI2iModeEnabled(m)) m,
  ];

  // i2i 모드 하나를 켜고 끈다.
  // 모드가 모두 꺼지면 i2i 탭도 함께 꺼지고, 빈 상태에서 모드를 켜면 탭도 되살아난다.
  // 그 외의 경우엔 사용자가 정한 탭 ON/OFF 상태를 건드리지 않는다.
  void setI2iModeEnabled(I2iMode mode, bool enabled) {
    final bool wasEmpty = enabledI2iModes.isEmpty;
    switch (mode) {
      case I2iMode.inpaint:
        i2iModeInpaintEnabled = enabled;
      case I2iMode.mosaic:
        i2iModeMosaicEnabled = enabled;
      case I2iMode.img2img:
        i2iModeImg2imgEnabled = enabled;
      case I2iMode.upscale:
        i2iModeUpscaleEnabled = enabled;
    }
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false; // 모드가 하나도 없으면 탭도 끔
    } else if (wasEmpty && enabled) {
      i2iTabEnabled = true; // 전부 꺼졌던 상태에서 모드를 켬 → 탭 부활
    }
    saveAllSettings();
    notifyListeners();
  }

  // 탭 표시 설정에서 i2i 탭을 켜고 끈다.
  // 모드가 전부 꺼진 상태에서 탭을 다시 켜면, 모드도 함께 되살린다.
  void setI2iTabEnabled(bool enabled) {
    i2iTabEnabled = enabled;
    if (enabled && enabledI2iModes.isEmpty) {
      // 켤 모드가 없으면 전부 복구 (그래야 탭이 의미가 있음)
      i2iModeInpaintEnabled = true;
      i2iModeMosaicEnabled = true;
      i2iModeImg2imgEnabled = true;
      i2iModeUpscaleEnabled = true;
    }
    saveAllSettings();
    notifyListeners();
  }

  bool characterTabEnabled = true;
  bool wildcardTabEnabled = true;

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

  // 앱에서 지원하는 전체 섹션 (저장된 순서와 대조해 누락/불명 항목 정리)
  //  ⚠️ 섹션을 지우면 여기서 빼기만 하면 된다 — 저장된 순서 · 접기 · 숨김 · 고정 목록에서도 읽을 때 빠진다
  //     (_mergeSectionOrder · _knownSections). 남겨 두면 프롬프트탭 머리줄이 모르는 섹션을 그리다 멈춘다.
  //     3.14.0: 'weightRules'(가중치 규칙)를 뺐다 — 조건부 트리거의 A=숫자::A :: 로 같은 일을 한다.
  static const List<String> _allSections = [
    'positive',
    'prefix',
    'suffix',
    'negative',
    'removeChips',
    'customRemove',
    'conditional',
  ];

  List<String> _mergeSectionOrder(List<String> saved) {
    final merged = saved.where(_allSections.contains).toList();
    for (final sec in _allSections) {
      if (!merged.contains(sec)) {
        merged.add(sec); // 새로 추가된 섹션은 뒤에
      }
    }
    return merged;
  }

  /// 저장된 섹션 이름 목록(접기 · 숨김 · 고정)에서 지금 없는 섹션을 뺀다
  List<String> _knownSections(List<String> saved) => saved.where(_allSections.contains).toList();

  // 프롬프트 섹션 접기 상태
  Set<String> collapsedSections = {};

  // 프롬프트 탭에서 숨길 섹션들 (설정 > 프롬프트 창 표시)
  // 전부 숨겨도 프롬프트 탭 자체는 유지된다.
  Set<String> hiddenPromptSections = {};

  // 2번째 UI 전용: 묶음에서 꺼내 메인 화면에 고정할 창들
  // (기존 UI의 hiddenPromptSections와는 별개 — 서로 간섭하지 않게 분리)
  Set<String> pinnedPromptSections = {};

  void togglePinnedSection(String sectionId) {
    if (pinnedPromptSections.contains(sectionId)) {
      pinnedPromptSections.remove(sectionId);
    } else {
      pinnedPromptSections.add(sectionId);
    }
    saveAllSettings();
    notifyListeners();
  }

  // i2i 탭 프롬프트 카드 접기 상태 (positive/prefix/suffix/negative)
  // 부정적처럼 한 번 넣고 신경 끄는 항목을 접어둘 수 있게 저장까지 유지한다.
  Set<String> collapsedI2iPrompts = {};

  // 설정 탭에서 접어둔 그룹들 (설정이 많아져 그룹별로 접을 수 있게 함)
  Set<String> collapsedSettingGroups = {};

  /// 앱 액센트 색을 바꾼다.
  ///  themeAccent(저장용 int)와 AppColors.accent(그리기용 Color)를 함께 갱신해
  ///  둘이 어긋나는 사고를 원천 차단한다.
  void setThemeAccent(int argb) {
    themeAccent = argb;
    AppColors.accent = Color(argb);
    saveAllSettings();
    notifyListeners();
  }

  void toggleSettingGroup(String groupId) {
    if (collapsedSettingGroups.contains(groupId)) {
      collapsedSettingGroups.remove(groupId);
    } else {
      collapsedSettingGroups.add(groupId);
    }
    saveAllSettings();
    notifyListeners();
  }

  void toggleI2iPromptCollapsed(String cardId) {
    if (collapsedI2iPrompts.contains(cardId)) {
      collapsedI2iPrompts.remove(cardId);
    } else {
      collapsedI2iPrompts.add(cardId);
    }
    saveAllSettings();
    notifyListeners();
  }

  void setPromptSectionVisible(String sectionId, bool visible) {
    if (visible) {
      hiddenPromptSections.remove(sectionId);
    } else {
      hiddenPromptSections.add(sectionId);
    }
    saveAllSettings();
    notifyListeners();
  }

  String resolutionMode = "수동";
  int currentImageWidth = 0;
  int currentImageHeight = 0;
  String apiToken = "";

  // ── NovelAI 계정(토큰) 여러 개 관리 ──
  //  V5의 시간당 사용 한도 때문에 계정을 번갈아 쓰는 경우가 생겼다.
  //  apiToken은 '지금 선택된 계정의 토큰'을 담는다 → 전송 코드는 그대로 둔다.
  List<NaiAccount> naiAccounts = [];
  int activeAccountIndex = 0;

  NaiAccount? get activeAccount =>
      (activeAccountIndex >= 0 && activeAccountIndex < naiAccounts.length)
      ? naiAccounts[activeAccountIndex]
      : null;

  /// 계정 전환 — 토큰을 갈아끼우고 잔액을 다시 확인한다.
  Future<void> switchAccount(int index) async {
    if (index < 0 || index >= naiAccounts.length) {
      return;
    }
    // 번호가 아니라 그 계정을 잡아 둔다 — 잔액 확인을 기다리는 사이 계정을 지우거나 또 바꿀 수 있다 (DEVNOTES 5)
    final NaiAccount target = naiAccounts[index];
    activeAccountIndex = index;
    apiToken = target.token;
    apiTokenController.text = apiToken;
    isApiConnected = false; // 조회가 성공해야 연결로 본다
    // ⚠️ 이전 계정의 잔액이 남아 있으면 새 계정 것으로 오해된다 → 먼저 비운다
    currentAnlas = 0;
    v5LimitPercent = null;
    v5ExtraPercent = 0;
    v5LimitNegative = false; // 이전 계정의 '한도 소진' 이 새 계정에 남지 않게 (무료 판단에 쓰인다)
    notifyListeners();

    if (apiToken.isEmpty) {
      target.anlas = -1; // 토큰이 없으면 '미확인'
      await saveAllSettings();
      notifyListeners();
      return;
    }

    // 새 계정의 잔액·한도를 확인 (한 번의 조회로 함께 온다)
    await fetchAnlas();
    // 기다리는 사이 다른 계정으로 바꿨으면 여기서 적지 않는다 (받은 답은 fetchAnlas 가 그 계정에 이미 적었다)
    if (identical(activeAccount, target)) {
      target.anlas = isApiConnected ? currentAnlas : -1;
    }
    await saveAllSettings();
    notifyListeners();
  }

  /// 계정 추가
  Future<void> addAccount(String label, String token) async {
    final wasEmpty = naiAccounts.isEmpty;
    naiAccounts.add(
      NaiAccount(
        label: label.trim().isEmpty ? '계정 ${naiAccounts.length + 1}' : label.trim(),
        token: token.trim(),
      ),
    );
    await saveAllSettings();
    notifyListeners();
    // 첫 계정이면 바로 연결한다 (따로 고를 필요 없이)
    if (wasEmpty) {
      await switchAccount(0);
    }
  }

  /// 계정 수정
  void updateAccount(int index, {String? label, String? token}) {
    if (index < 0 || index >= naiAccounts.length) {
      return;
    }
    final acc = naiAccounts[index];
    if (label != null) {
      acc.label = label.trim();
    }
    if (token != null) {
      final changed = acc.token != token.trim();
      acc.token = token.trim();
      if (changed) {
        acc.anlas = -1; // 토큰이 바뀌었으니 잔액은 다시 확인해야 한다
      }
      if (index == activeAccountIndex) {
        apiToken = acc.token;
        apiTokenController.text = acc.token;
        if (changed) {
          // 잔액이 낡은 채로 남으면 생성 시 '포인트 소모' 경고가 잘못 뜬다
          currentAnlas = 0;
          isApiConnected = false;
          v5LimitPercent = null;
          v5ExtraPercent = 0;
          v5LimitNegative = false; // 옛 토큰의 '한도 소진' 이 남지 않게 (무료 판단에 쓰인다)
          notifyListeners();
          // 새 토큰으로 즉시 확인
          fetchAnlas().then((_) {
            // 기다리는 사이 다른 계정으로 바꿨으면 지금 표시값은 그 계정 것이다 — 이 계정에 적지 않는다
            if (identical(activeAccount, acc)) {
              acc.anlas = isApiConnected ? currentAnlas : -1;
            }
            saveAllSettings();
            notifyListeners();
          });
        }
      }
    }
    saveAllSettings();
    notifyListeners();
  }

  /// 계정 삭제 — 마지막 하나는 남긴다.
  Future<void> removeAccount(int index) async {
    if (naiAccounts.length <= 1 || index < 0 || index >= naiAccounts.length) {
      return;
    }
    final wasActive = index == activeAccountIndex;
    naiAccounts.removeAt(index);

    // 남은 계정 중 어디를 쓸지 정한다
    int next = activeAccountIndex;
    if (next >= naiAccounts.length) {
      next = naiAccounts.length - 1;
    } else if (index < activeAccountIndex) {
      next--;
    }

    // 지운 게 쓰던 계정이면, 사용자가 직접 고른 것과 똑같이 전환한다.
    //  (그래야 Anlas·연결 상태가 제대로 갱신된다)
    if (wasActive) {
      activeAccountIndex = -1; // switchAccount가 '같은 인덱스'로 보고 건너뛰지 않게
      await switchAccount(next);
      return;
    }

    activeAccountIndex = next;
    await saveAllSettings();
    notifyListeners();
  }

  /// 예전 버전(토큰 1개)에서 넘어온 데이터를 계정 목록으로 옮긴다.
  void _migrateSingleToken() {
    if (naiAccounts.isNotEmpty) {
      return;
    }
    // 토큰이 없으면 빈 계정을 만들지 않는다.
    //  목록이 비어 있으면 UI가 '계정을 추가해 주세요'를 보여주고,
    //  첫 계정을 만들면 addAccount가 자동으로 연결한다.
    if (apiToken.trim().isEmpty) {
      return;
    }
    naiAccounts.add(NaiAccount(label: '계정 1', token: apiToken));
    activeAccountIndex = 0;
  }

  bool isApiConnected = false;
  int sessionSaveCount = 0;
  int sessionGenerateCount = 0;
  String? sessionFolderName;

  // 저장 폴더 이름을 결정한다.
  //  - 기본: 앱 실행 세션마다 'yyyyMMdd_HHmmss' (껐다 켤 때마다 새 폴더)
  //  - saveFolderByDateOnly: 'yyyyMMdd' 로 하루에 한 폴더만 사용
  //    (자정을 넘기면 자동으로 다음 날짜 폴더가 만들어진다)
  String _resolveSessionFolder() {
    if (saveFolderByDateOnly) {
      return DateFormat('yyyyMMdd').format(DateTime.now());
    }
    return sessionFolderName ??= DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
  }

  // 갤러리 모드 상태
  String? galleryCurrentPath; // 현재 보고 있는 폴더 (마지막 본 폴더 기억)
  int galleryColumns = 3; // 갤러리 가로 표시 개수 (기본 3)
  double promptEditorFontSize = 16.0; // 프롬프트 확대 입력창 폰트 크기 (기본 16)
  String gallerySortMode = 'name_asc'; // 갤러리 정렬 (name_asc/name_desc, 추후 date_* 등 확장)

  // ===== SAF 저장 폴더 (두 칸 — 고르기·전환·해제·불러오기) =====

  // 칸별 저장 이름. 1번 칸은 예전 이름 그대로 (업데이트해도 고른 폴더가 유지되게).
  static String _safUriKey(int slot) => slot == 0 ? 'safRootUri' : 'safRootUri${slot + 1}';
  static String _safNameKey(int slot) => slot == 0 ? 'safRootName' : 'safRootName${slot + 1}';

  /// 저장 폴더(어느 칸이든)가 바뀌었을 때 공통 정리 — 세션 폴더 캐시·갤러리 위치를 비우고 갤러리에 알린다.
  void _onSafRootChanged() {
    _safSessionDirUri = null; // 루트 바뀌면 세션 캐시 무효화
    _safSessionDirName = null;
    clearSafBrowseLocation();
    safRootRevision++;
  }

  /// [slot] 말고 폴더가 들어 있는 칸 (없으면 null)
  int? _otherFilledSafSlot(int slot) {
    for (int i = 0; i < kSafSlotCount; i++) {
      if (i != slot && safSlotUris[i] != null) {
        return i;
      }
    }
    return null;
  }

  /// 폴더의 영속 권한을 돌려준다 — 다른 칸이 같은 폴더를 쓰고 있으면 두고.
  Future<void> _releaseSafIfUnused(String uri) async {
    if (!Platform.isAndroid || safSlotUris.contains(uri)) {
      return;
    }
    try {
      await _safUtil.releasePersistedPermission(uri);
    } catch (e) {
      debugPrint('SAF 권한 반납 실패(무시): $e');
    }
  }

  /// 폴더 선택창을 띄워 [slot] 칸(기본: 지금 쓰는 칸)에 저장 폴더를 넣는다.
  ///  그 칸만 바꾼다 — 쓰는 칸은 그대로 (전환은 칸을 눌러서).
  ///  단, 지금 쓰는 칸이 비어 있으면(처음 지정) 고른 칸을 바로 쓴다.
  ///  다른 칸에 이미 있는 폴더는 받지 않는다 (같은 폴더 두 칸은 전환할 의미가 없다).
  Future<SafPickResult> pickSafRoot({int? slot}) async {
    if (!Platform.isAndroid) {
      return SafPickResult.cancelled;
    }
    final int target = slot ?? activeSafSlot;
    try {
      // persistablePermission: true → 재시작/재부팅 후에도 권한 유지 (takePersistableUriPermission)
      final dir = await _safUtil.pickDirectory(writePermission: true, persistablePermission: true);
      if (dir == null) {
        return SafPickResult.cancelled; // 사용자가 취소
      }
      for (int i = 0; i < kSafSlotCount; i++) {
        if (i != target && safSlotUris[i] == dir.uri) {
          return SafPickResult.duplicate; // 권한은 그 칸이 쓰고 있으니 돌려주지 않는다
        }
      }
      final String? old = safSlotUris[target];
      safSlotUris[target] = dir.uri;
      safSlotNames[target] = dir.name;
      if (safSlotUris[activeSafSlot] == null) {
        activeSafSlot = target;
      }
      _onSafRootChanged();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_safUriKey(target), dir.uri);
      await prefs.setString(_safNameKey(target), dir.name);
      await prefs.setInt('safActiveSlot', activeSafSlot);
      // 칸에 있던 옛 폴더의 권한은 돌려준다
      //  (⚠️ 예전엔 폴더를 다시 고를 때마다 옛 권한이 쌓이기만 했다)
      if (old != null && old != dir.uri) {
        await _releaseSafIfUnused(old);
      }
      notifyListeners();
      return SafPickResult.picked;
    } catch (e) {
      debugPrint('SAF 폴더 선택 실패: $e');
      return SafPickResult.cancelled;
    }
  }

  /// 생성 전에 저장 폴더(SAF)가 있는지 확인한다. 없으면 고르게 하고, 폴더가 생기면 true.
  ///  생성한 그림은 저장 폴더에만 둔다 — 폴더 없이 생성하면 앱 전용 폴더(파일 앱에서 잘 안 보이는 곳)에
  ///  따로 쌓여, 저장 폴더와 두 군데를 챙겨야 했다.
  ///  부르는 곳: 생성(프롬프트탭) · 다시 생성(히스토리) · i2i(img2img · 인페인트 · 업스케일 · 디렉터 도구).
  ///  Anlas 확인 창보다 '먼저' 부른다 (폴더를 고른 뒤 비용을 확인하는 순서).
  ///  안드로이드가 아니면 고를 폴더가 없으므로 그냥 통과한다.
  Future<bool> ensureSaveFolder(BuildContext context) async {
    if (safRootUri != null || !Platform.isAndroid) {
      return true;
    }
    final bool pick = await showConfirmDialog(
      context,
      title: "저장 폴더가 필요해요",
      message: "생성한 이미지는 저장 폴더에만 저장해요.\n먼저 저장 폴더를 골라 주세요.\n(설정 > 저장 에서도 바꿀 수 있어요)",
      confirmLabel: "폴더 고르기",
      icon: Icons.folder_open,
      destructive: false,
    );
    if (!pick) {
      return false;
    }
    final SafPickResult result = await pickSafRoot();
    final bool ok = result == SafPickResult.picked && safRootUri != null;
    // 골랐으면 그대로 생성이 이어지니 알리지 않는다 — 안 골라 생성하지 않았을 때만 이유를 알려 준다
    if (!ok && context.mounted) {
      showToast(context, "저장 폴더를 고르지 않아 생성하지 않았어요.");
    }
    return ok;
  }

  /// 저장 폴더 전환 — NovelAI 계정 전환처럼 켜진 칸만 바꾼다. 빈 칸으로는 전환하지 않는다.
  Future<void> switchSafSlot(int slot) async {
    if (slot < 0 || slot >= kSafSlotCount || slot == activeSafSlot || safSlotUris[slot] == null) {
      return;
    }
    activeSafSlot = slot;
    _onSafRootChanged();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('safActiveSlot', slot);
    } catch (e) {
      debugPrint('SAF 폴더 전환 저장 실패: $e');
    }
  }

  /// [slot] 칸(기본: 지금 쓰는 칸)을 비운다 (영속 권한도 반납).
  ///  쓰던 칸을 비우면 다른 칸에 폴더가 있을 때 그쪽으로 넘어간다 (계정 삭제와 같은 규칙).
  Future<void> clearSafRoot({int? slot}) async {
    final int target = slot ?? activeSafSlot;
    final String? uri = safSlotUris[target];
    safSlotUris[target] = null;
    safSlotNames[target] = null;
    if (target == activeSafSlot) {
      activeSafSlot = _otherFilledSafSlot(target) ?? activeSafSlot;
    }
    // 쓰지 않던 칸이어도 알린다 — 갤러리가 그 칸을 둘러보는 중일 수 있다
    _onSafRootChanged();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_safUriKey(target));
      await prefs.remove(_safNameKey(target));
      await prefs.setInt('safActiveSlot', activeSafSlot);
      if (uri != null) {
        await _releaseSafIfUnused(uri);
      }
    } catch (e) {
      debugPrint('SAF 폴더 해제 실패: $e');
    }
    notifyListeners();
  }

  /// SAF 루트 폴더의 settings/ 안에 파일을 저장한다.
  ///  설정 백업 · 바이브 · 정밀 참조 내보내기 (widgets/export_sheet.dart). 반환은 표시용 경로, SAF 미설정/실패면 null.
  ///  ⚠️ settings/ 안에 하위 폴더를 만들지 않는다 — 하위 폴더가 생기면 갤러리에 settings 폴더 칸이 나타난다
  ///     (그림도 하위 폴더도 없는 폴더는 갤러리에서 숨긴다 — listSafDirDetailed).
  ///
  ///  ⚠️ 왜 SAF를 쓰는가:
  ///     예전에는 getExternalStorageDirectory()(=/Android/data/<패키지>/files)에
  ///     저장했는데, 안드로이드 11(API 30)부터 문서 선택기가 Android/data 안을
  ///     들여다볼 수 없게 막혔다. 그래서 저장은 되는데 '가져오기'에서 폴더 자체가
  ///     보이지 않는 문제가 있었다. SAF 폴더는 사용자가 직접 고른 위치라 안전하다.
  ///
  ///  고른 폴더 바로 아래에 만든다 (세션 폴더·settings 모두).
  ///  ⚠️ 예전엔 고른 폴더 이름이 'DNaiApp' 이 아니면 그 안에 DNaiApp 폴더를 하나 더 만들었다.
  ///
  ///  ⚠️ 진짜 이름으로 바로 쓰면, 쓰는 도중에 앱이 꺼졌을 때 이름은 멀쩡한데 내용이 반쯤인
  ///     백업이 남는다. 가져오기에서 'JSON 형식 오류'가 나고, 자동 백업이면 '최근 3개'에
  ///     한 자리로 세어져 멀쩡한 옛 백업을 밀어낸다. (업데이트 전 자동 백업은 설치가 시작되면
  ///     앱이 꺼지므로 실제로 일어날 수 있다)
  ///     그래서 임시 이름([_kSafWritingPrefix] + 이름)으로 다 쓴 뒤 이름만 바꾼다.
  ///     임시 이름도 진짜 이름과 같은 확장자로 끝난다.
  ///  ⚠️ [mimeType] 은 확장자와 맞춘다 — 안 맞으면 안드로이드가 그 MIME 의 확장자를 덧붙인다
  ///     (.naiv4vibe 를 application/json 으로 쓰면 '….naiv4vibe.json').
  ///     안드로이드가 모르는 확장자는 application/octet-stream — 그때는 이름을 그대로 둔다.
  ///  [bytes] 는 다 만든 내용 — 큰 설정 묶음은 encodeSettingsJson 으로 화면 밖에서 만들어 넘긴다.
  Future<String?> saveSettingsViaSaf(
    String fileName,
    Uint8List bytes, {
    String mimeType = 'application/json',
  }) async {
    final root = safRootUri;
    if (root == null || !Platform.isAndroid) {
      return null;
    }
    try {
      final dir = await _safUtil.mkdirp(root, ['settings']);
      String? tmpUri;
      try {
        final tmp = await _safStream.writeFileBytes(
          dir.uri,
          '$_kSafWritingPrefix$fileName',
          mimeType,
          bytes,
          overwrite: true, // 예전에 쓰다 만 같은 임시 파일이 있으면 그 자리에 다시 쓴다
        );
        tmpUri = tmp.uri.toString();
      } catch (e) {
        // 임시 이름('.' 으로 시작)을 받지 않는 저장소일 수 있다 — 아래에서 진짜 이름으로 바로 쓴다
        debugPrint('설정 파일 임시 이름 쓰기 실패, 바로 씀: $e');
      }
      String savedName = fileName;
      bool renamed = false;
      if (tmpUri != null) {
        try {
          // 같은 이름이 이미 있으면 안드로이드가 '이름 (1).json' 처럼 바꿔 준다
          savedName = (await _safUtil.rename(tmpUri, false, fileName)).name;
          renamed = true;
        } catch (e) {
          debugPrint('설정 파일 이름 바꾸기 실패, 바로 씀: $e');
          try {
            await _safUtil.delete(tmpUri, false);
          } catch (_) {
            // 남은 임시 파일은 다음 자동 백업 정리 때 지워진다 (_pruneAutoBackups)
          }
        }
      }
      if (!renamed) {
        // 임시 이름을 못 쓰거나 이름을 못 바꾸는 저장소 — 예전처럼 진짜 이름으로 바로 쓴다
        final direct = await _safStream.writeFileBytes(dir.uri, fileName, mimeType, bytes);
        savedName = direct.fileName ?? fileName;
      }
      return '${safRootName ?? 'SAF'}/settings/$savedName';
    } catch (e) {
      debugPrint('설정 SAF 저장 실패: $e');
      return null;
    }
  }

  /// 저장 폴더 settings/ 에 쓰는 중인 파일의 이름 앞머리 (다 쓰면 이 앞머리를 뗀 이름으로 바뀐다).
  ///  '.' 으로 시작해 파일 앱·문서 선택기에서 숨겨진다.
  static const String _kSafWritingPrefix = '.writing_';

  /// 설정 묶음(exportSettings)을 UTF-8 JSON 바이트로 — 백그라운드 isolate 에서 만든다.
  ///  히스토리 썸네일·사전 큰 이미지·i2i 즐겨찾기 원본이 base64 로 들어가 수십 MB 가 될 수 있어,
  ///  화면 쪽(메인 isolate)에서 만들면 그동안 화면이 멈췄다. [pretty] 면 사람이 읽기 좋게 들여쓴다.
  ///  ⚠️ static 이어야 한다 — 안에서 만드는 함수가 AppState(this)를 붙잡으면 isolate 로 못 보낸다.
  static Future<Uint8List> encodeSettingsJson(Map<String, dynamic> data, {bool pretty = false}) {
    return Isolate.run(
      () => utf8.encode(pretty ? const JsonEncoder.withIndent('  ').convert(data) : jsonEncode(data)),
    );
  }

  /// 설정 파일(가져오기)을 읽어 JSON 으로 — 읽기·풀기 모두 백그라운드 isolate 에서.
  ///  형식이 틀리면 예외를 던진다 (부른 쪽이 '읽지 못했다'를 알린다).
  static Future<Map<String, dynamic>> decodeSettingsJsonFile(String path) {
    return Isolate.run(() async {
      final v = jsonDecode(await File(path).readAsString());
      if (v is! Map<String, dynamic>) {
        throw const FormatException('설정 파일이 아님');
      }
      return v;
    });
  }

  // SAF 저장 폴더에 이미지 1장 저장 — 고른 폴더 바로 아래 세션 폴더에
  // 반환: 성공 시 표시용 문자열, 미설정/실패 시 null
  Future<String?> _saveImageViaSaf(Uint8List bytes, String fileName, String ext) async {
    final root = safRootUri;
    if (root == null || !Platform.isAndroid) {
      return null;
    }
    try {
      // 확장자와 mime이 어긋나면 안드로이드가 확장자를 덧붙인다(예: name.webp.png)
      final mime = mimeForExt(ext);
      final session = _resolveSessionFolder();
      final pathParts = [session];
      // 세션 폴더 확보 (같은 세션이면 캐시 재사용 → mkdirp 반복 호출 방지)
      String dirUri;
      final cachedDir = _safSessionDirUri;
      if (_safSessionDirName == session && cachedDir != null) {
        dirUri = cachedDir;
      } else {
        final dir = await _safUtil.mkdirp(root, pathParts);
        dirUri = dir.uri;
        _safSessionDirName = session;
        _safSessionDirUri = dirUri;
      }
      await _safStream.writeFileBytes(dirUri, '$fileName.$ext', mime, bytes);
      gallerySafRevision++; // 갤러리 자동 갱신 신호 (호출자의 notifyListeners로 전파됨)
      return '${safRootName ?? 'SAF'}/$session/$fileName.$ext';
    } catch (e) {
      debugPrint('SAF 저장 실패: $e');
      return null;
    }
  }

  // SAF 갤러리에서 마지막으로 보던 위치 (탭/모드 전환 후 복원용)
  // 갤러리(SAF/IO)가 등록하는 뒤로가기 핸들러. 처리했으면 true 반환.
  // main의 PopScope가 히스토리 탭일 때 호출 → 상위폴더 이동/선택해제 처리.
  bool Function()? galleryBackHandler;

  // i2i 탭이 등록하는 뒤로가기 핸들러. 릴(핸들)이 열려있으면 닫고 true 반환.
  bool Function()? i2iBackHandler;

  // SAF에 이미지가 저장될 때마다 증가. 갤러리가 이 값 변화를 감지해 자동 갱신한다.
  int gallerySafRevision = 0;

  // 마지막으로 이미지를 저장한 세션 폴더 URI (갤러리 자동 갱신 시 대상 판별용).
  String? get lastSavedSafDirUri => _safSessionDirUri;

  String? safBrowseDirUri;
  String? safBrowseDirName;
  List<String> safBrowseStackUris = [];
  List<String> safBrowseStackNames = [];
  // 갤러리가 둘러보던 저장 폴더 칸 (null = 저장 중인 칸). 갤러리는 저장 칸을 바꾸지 않고 다른 칸을 볼 수 있다.
  int? safBrowseSlot;

  void saveSafBrowseLocation(
    String? dirUri,
    String? dirName,
    List<String> stackUris,
    List<String> stackNames, {
    int? slot,
  }) {
    safBrowseDirUri = dirUri;
    safBrowseDirName = dirName;
    safBrowseStackUris = List.from(stackUris);
    safBrowseStackNames = List.from(stackNames);
    safBrowseSlot = slot;
  }

  void clearSafBrowseLocation() {
    safBrowseDirUri = null;
    safBrowseDirName = null;
    safBrowseStackUris = [];
    safBrowseStackNames = [];
    safBrowseSlot = null;
  }

  // 현재 폴더의 '이미지 목록만' 빠르게 읽는다 (SAF 조회 1회).
  //  자동 새로고침처럼 하위 폴더가 바뀔 일이 없을 때 쓰면
  //  폴더 수와 무관하게 항상 1회 조회로 끝난다.
  Future<List<({String uri, String name})>> listSafImagesOnly(String dirUri) async {
    final images = <({String uri, String name})>[];
    if (!Platform.isAndroid) {
      return images;
    }
    try {
      final items = await _safUtil.list(dirUri);
      for (final f in items) {
        if (!f.isDir && isImageFileName(f.name)) {
          images.add((uri: f.uri, name: f.name));
        }
      }
      images.sort((a, b) => b.name.compareTo(a.name));
    } catch (e) {
      debugPrint('listSafImagesOnly 실패 ($dirUri): $e');
    }
    return images;
  }

  // SAF 디렉토리 1단계 목록 (하위폴더[개수+미리보기refs 포함] + 이미지). 빈 폴더는 제외.
  // 개수를 세는 김에 미리보기 후보(최신 4장)도 같이 뽑아 폴더당 조회를 1회로 줄인다.
  Future<
    ({
      List<({String uri, String name, int imageCount, List<({String uri, String name})> previews})>
      folders,
      List<({String uri, String name})> images,
    })
  >
  listSafDirDetailed(String dirUri) async {
    final folders =
        <({String uri, String name, int imageCount, List<({String uri, String name})> previews})>[];
    final images = <({String uri, String name})>[];
    if (!Platform.isAndroid) {
      return (folders: folders, images: images);
    }
    try {
      final items = await _safUtil.list(dirUri);
      final subDirs = <({String uri, String name})>[];
      for (final f in items) {
        if (f.isDir) {
          // '.' 으로 시작하는 폴더(휴지통 '.trash' 등)는 숨긴다
          if (!f.name.startsWith('.')) {
            subDirs.add((uri: f.uri, name: f.name));
          }
        } else if (isImageFileName(f.name)) {
          images.add((uri: f.uri, name: f.name));
        }
      }
      // 각 하위폴더 1회 조회 → 직접 이미지 수 + 하위폴더 유무 + 미리보기 refs (빈 폴더 제외)
      // ⚡ 순차로 돌면 폴더 20개일 때 20번을 기다려야 한다(체감 1초 이상) — 함께 조회한다 (_safListEach).
      //  실패한 폴더는 건너뛰되 나머지 결과는 살린다.
      final inners = await _safListEach([for (final d in subDirs) d.uri], _safUtil.list);
      for (int i = 0; i < subDirs.length; i++) {
        final d = subDirs[i];
        int imgCount = 0;
        bool hasSub = false;
        final innerImgs = <({String uri, String name})>[];
        final inner = inners[i];
        if (inner == null) {
          continue; // 조회 실패한 폴더는 건너뛴다
        }
        for (final f in inner) {
          if (f.isDir) {
            hasSub = hasSub || !f.name.startsWith('.'); // 숨김 폴더는 하위 폴더로 치지 않는다
          } else if (isImageFileName(f.name)) {
            imgCount++;
            innerImgs.add((uri: f.uri, name: f.name));
          }
        }
        if (imgCount > 0 || hasSub) {
          innerImgs.sort((a, b) => b.name.compareTo(a.name)); // 최신순
          folders.add((
            uri: d.uri,
            name: d.name,
            imageCount: imgCount,
            previews: innerImgs.take(4).toList(),
          ));
        }
      }
      folders.sort((a, b) => b.name.compareTo(a.name));
      images.sort((a, b) => b.name.compareTo(a.name));
    } catch (e) {
      debugPrint('listSafDirDetailed 실패 ($dirUri): $e');
    }
    return (folders: folders, images: images);
  }

  // 폴더의 대표 미리보기 이미지 최대 N장 (없으면 하위폴더로 얕게 탐색)
  Future<List<({String uri, String name})>> firstSafImagesIn(
    String dirUri, {
    int max = 4,
    int depth = 0,
  }) async {
    final out = <({String uri, String name})>[];
    if (!Platform.isAndroid || depth > 2) {
      return out;
    }
    try {
      final items = await _safUtil.list(dirUri);
      final imgs = items.where((f) => !f.isDir && isImageFileName(f.name)).toList()
        ..sort((a, b) => b.name.compareTo(a.name));
      for (final im in imgs) {
        out.add((uri: im.uri, name: im.name));
        if (out.length >= max) {
          return out;
        }
      }
      if (out.length < max) {
        final dirs = items.where((f) => f.isDir && !f.name.startsWith('.')).toList()
          ..sort((a, b) => b.name.compareTo(a.name));
        for (final d in dirs) {
          final sub = await firstSafImagesIn(d.uri, max: max - out.length, depth: depth + 1);
          out.addAll(sub);
          if (out.length >= max) {
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('firstSafImagesIn 실패 ($dirUri): $e');
    }
    return out;
  }

  // SAF 이미지 1장 삭제
  Future<bool> deleteSafImage(String fileUri) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      await _safUtil.delete(fileUri, false); // isDir=false
      return true;
    } catch (e) {
      debugPrint('deleteSafImage 실패: $e');
      return false;
    }
  }

  // SAF 파일을 다른 폴더로 이동. 권한받은 루트 트리 내부 폴더 간에만 동작.
  //   fileUri: 이동할 파일 URI
  //   fromParentUri: 현재 파일이 든 부모 폴더 URI
  //   toParentUri: 이동 대상 폴더 URI
  // 반환: 성공 시 이동된 파일의 새 URI, 실패 시 null.
  ///  [name] 은 파일 이름 — 저장 폴더 칸 사이 이동(복사 후 삭제)에 쓴다.
  Future<String?> moveSafImage(
    String fileUri,
    String fromParentUri,
    String toParentUri, {
    String? name,
  }) async {
    if (!Platform.isAndroid) {
      return null;
    }
    // 같은 폴더로의 이동은 무의미 → 그대로 성공 처리(새 uri 없음)
    if (fromParentUri == toParentUri) {
      return fileUri;
    }
    // 다른 저장 폴더 칸(다른 권한 트리)으로 가면 '옮기기'를 쓰지 않는다.
    //  안드로이드의 옮기기는 새 파일 주소를 '원래 트리' 기준으로 만들어 돌려주는데,
    //  그 주소는 원래 트리 밖이라 읽는 순간 권한 오류가 난다 — 파일은 옮겨졌는데
    //  앱은 실패로 알게 된다. 그래서 복사한 뒤 원본을 지운다.
    if (name != null && _safTreeOf(fromParentUri) != _safTreeOf(toParentUri)) {
      return _copyThenDeleteSaf(fileUri, toParentUri, name);
    }
    try {
      final moved = await _safUtil.moveTo(
        fileUri,
        false, // isDir=false
        fromParentUri,
        toParentUri,
      );
      return moved.uri;
    } catch (e) {
      debugPrint('moveSafImage 실패: $e');
      return null;
    }
  }

  /// SAF 주소가 속한 권한 트리 (`…/tree/{트리}/document/…` 의 {트리} 부분). 트리 주소가 아니면 null.
  static String? _safTreeOf(String uri) {
    final segs = Uri.parse(uri).pathSegments;
    final i = segs.indexOf('tree');
    return (i >= 0 && i + 1 < segs.length) ? segs[i + 1] : null;
  }

  /// [fileUri] 를 [toParentUri] 폴더에 같은 이름으로 복사한 뒤 원본을 지운다.
  ///  복사가 끝나야만 지운다 — 중간에 실패해도 그림이 사라지지 않는다.
  ///  반환: 성공하면 대상 폴더 주소(새 파일 주소 대신), 실패면 null.
  Future<String?> _copyThenDeleteSaf(String fileUri, String toParentUri, String name) async {
    try {
      final bytes = Uint8List.fromList(await _safStream.readFileBytes(fileUri));
      await _safStream.writeFileBytes(toParentUri, name, mimeForExt(extOf(name)), bytes);
    } catch (e) {
      debugPrint('SAF 폴더 간 복사 실패: $e');
      return null;
    }
    try {
      await _safUtil.delete(fileUri, false);
    } catch (e) {
      // 복사는 됐으니 이동은 성공으로 친다 (원본이 남을 뿐 그림은 잃지 않는다)
      debugPrint('SAF 폴더 간 이동 — 원본 삭제 실패(복사본은 있음): $e');
    }
    return toParentUri;
  }

  // ===== 휴지통 (저장 폴더마다 맨 위의 '.trash') =====
  //  갤러리에서 지운 그림을 바로 없애지 않고 여기로 옮겨 둔다. [trashKeepDays] 일이 지나면 자동으로 지운다.
  //  · 폴더 이름이 '.' 으로 시작하고 안에 '.nomedia' 가 있어 폰 갤러리 앱엔 뜨지 않는다.
  //    (파일 관리자에서 '숨김 파일 보기'를 켜면 보인다 — 여기까진 막을 수 없다)
  //  · 우리 갤러리도 '.' 으로 시작하는 폴더는 목록에서 뺀다 (listSafDirDetailed 등).
  //  · 버린 시각·원래 폴더는 휴지통 안의 '.index.json' 에 적어 둔다.
  //    옮기기(이름 바꾸기)는 파일의 수정 시각을 바꾸지 않아 시각을 따로 적어야 한다.
  //    기록이 없는 그림(기록 파일이 지워졌거나 손으로 넣은 것)은 처음 본 때를 버린 시각으로 친다.

  static const String kSafTrashDirName = '.trash';
  static const String _kTrashIndexName = '.index.json';
  static const int _kDayMs = 24 * 60 * 60 * 1000;

  // 이번 실행에서 '.nomedia' 를 확인한 휴지통 (매번 확인하지 않게)
  final Set<String> _trashCheckedDirs = {};

  /// 버린 지 [deletedAtMs] 인 그림이 자동으로 지워지기까지 남은 날 (0 이하 = 곧 지워짐).
  int trashDaysLeft(int deletedAtMs) {
    final int expireAt = deletedAtMs + trashKeepDays * _kDayMs;
    final int leftMs = expireAt - DateTime.now().millisecondsSinceEpoch;
    return leftMs <= 0 ? 0 : (leftMs / _kDayMs).ceil();
  }

  /// 저장 폴더 [rootUri] 의 휴지통 폴더 주소. [create] 가 true 면 없을 때 만든다 ('.nomedia' 도 같이).
  Future<String?> _safTrashDir(String rootUri, {bool create = true}) async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      String dirUri;
      if (create) {
        dirUri = (await _safUtil.mkdirp(rootUri, [kSafTrashDirName])).uri;
      } else {
        final found = await _safUtil.child(rootUri, [kSafTrashDirName]);
        if (found == null || !found.isDir) {
          return null;
        }
        dirUri = found.uri;
      }
      if (_trashCheckedDirs.add(dirUri)) {
        final nomedia = await _safUtil.child(dirUri, ['.nomedia']);
        if (nomedia == null) {
          await _safStream.writeFileBytes(dirUri, '.nomedia', 'application/octet-stream', Uint8List(0));
        }
      }
      return dirUri;
    } catch (e) {
      debugPrint('휴지통 폴더 준비 실패: $e');
      return null;
    }
  }

  /// 휴지통 기록 읽기 — {파일 이름: {'t': 버린 시각(ms), 'p': 원래 폴더 경로('2026-09-30/sub', 맨 위면 '')}}
  Future<Map<String, dynamic>> _readTrashIndex(String trashUri) async {
    try {
      final f = await _safUtil.child(trashUri, [_kTrashIndexName]);
      if (f == null) {
        return {};
      }
      final data = jsonDecode(utf8.decode(await _safStream.readFileBytes(f.uri)));
      return data is Map<String, dynamic> ? data : {};
    } catch (e) {
      debugPrint('휴지통 기록 읽기 실패(새로 시작): $e');
      return {};
    }
  }

  // 휴지통 일은 한 번에 하나씩 (보내기 · 열기 · 되돌리기 · 영구 삭제 · 켤 때 정리).
  //  기록을 읽고 → 고치고 → 통째로 쓰는 사이에 다른 일이 끼면 나중에 쓴 쪽이 앞의 기록을 덮는다 —
  //  덮인 그림은 '어디서 왔는지' 를 잃어 되돌리면 맨 위 폴더로 간다 (여러 폴더를 한 번에 보내면 몇 초 걸려 겹치기 쉽다).
  //  ⚠️ 이 안에서 다른 휴지통 공개 함수를 부르지 않는다 — 자기 차례를 기다리느라 영영 멈춘다 (안쪽은 _purgeTrashDir 같은 비공개 함수로).
  Future<void> _trashQueue = Future<void>.value();
  Future<T> _trashJob<T>(Future<T> Function() job) {
    final Future<T> run = _trashQueue.then((_) => job());
    _trashQueue = run.then<void>((_) {}, onError: (Object _) {}); // 실패해도 줄이 막히지 않게
    return run;
  }

  Future<void> _writeTrashIndex(String trashUri, Map<String, dynamic> index) async {
    try {
      await _safStream.writeFileBytes(
        trashUri,
        _kTrashIndexName,
        'application/json',
        Uint8List.fromList(utf8.encode(jsonEncode(index))),
        overwrite: true,
      );
    } catch (e) {
      debugPrint('휴지통 기록 쓰기 실패: $e');
    }
  }

  /// SAF 주소의 문서 ID ('…/document/{id}', 없으면 '…/tree/{id}'). 알 수 없으면 null.
  static String? _safDocIdOf(String uri) {
    final segs = Uri.parse(uri).pathSegments;
    final int d = segs.indexOf('document');
    if (d >= 0 && d + 1 < segs.length) {
      return segs[d + 1];
    }
    final int t = segs.indexOf('tree');
    return (t >= 0 && t + 1 < segs.length) ? segs[t + 1] : null;
  }

  /// 폴더 [dirUri] 가 저장 폴더 [rootUri] 안에서 어디인지 ('2026-09-30/sub'). 맨 위이거나 알 수 없으면 ''.
  static String _safRelPath(String rootUri, String dirUri) {
    final String? root = _safDocIdOf(rootUri);
    final String? dir = _safDocIdOf(dirUri);
    if (root == null || dir == null || !dir.startsWith('$root/')) {
      return '';
    }
    return dir.replaceFirst('$root/', '');
  }

  /// [fileUri] 를 폴더 [toDirUri] 로 옮긴다. 옮기기가 안 되면(같은 이름이 있음·다른 권한 트리)
  ///  복사한 뒤 원본을 지운다 — 이때 같은 이름이 있으면 안드로이드가 이름을 바꿔 준다 ('이름 (1).png').
  ///  반환: 옮겨진 뒤의 파일 이름, 실패면 null.
  Future<String?> _safRelocate(
    String fileUri,
    String name,
    String fromDirUri,
    String toDirUri,
  ) async {
    try {
      final moved = await _safUtil.moveTo(fileUri, false, fromDirUri, toDirUri);
      return moved.name;
    } catch (_) {
      // 아래에서 복사로 다시 해 본다
    }
    try {
      final bytes = Uint8List.fromList(await _safStream.readFileBytes(fileUri));
      final created = await _safStream.writeFileBytes(toDirUri, name, mimeForExt(extOf(name)), bytes);
      try {
        await _safUtil.delete(fileUri, false);
      } catch (e) {
        debugPrint('옮긴 뒤 원본 삭제 실패(복사본은 있음): $e');
      }
      return created.fileName ?? name;
    } catch (e) {
      debugPrint('SAF 옮기기 실패 ($name): $e');
      return null;
    }
  }

  /// 그림들을 저장 폴더 [rootUri] 의 휴지통으로 보낸다. 그림마다 있던 폴더(fromDirUri)를 휴지통 기록에 적어
  ///  되돌릴 때 그리로 돌려놓는다 — 갤러리 검색 결과처럼 폴더가 섞여 있어도 한 번에 (기록은 한 번만 쓴다).
  ///  반환: 휴지통으로 간 그림의 (원래) 주소들.
  ///  ⚠️ 예전엔 폴더를 하나만 받아, 폴더가 섞인 목록을 넘기면 다 그 폴더로 적혔다.
  Future<List<String>> trashSafImages(
    List<SafSourceRef> refs, {
    required String rootUri,
  }) => _trashJob(() async {
    final done = <String>[];
    final trash = await _safTrashDir(rootUri);
    if (trash == null || refs.isEmpty) {
      return done;
    }
    final index = await _readTrashIndex(trash);
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final r in refs) {
      final String? trashedName = await _safRelocate(r.uri, r.name, r.fromDirUri, trash);
      if (trashedName != null) {
        index[trashedName] = {'t': now, 'p': _safRelPath(rootUri, r.fromDirUri)};
        done.add(r.uri);
      }
    }
    if (done.isNotEmpty) {
      await _writeTrashIndex(trash, index);
    }
    return done;
  });

  /// 휴지통 열기 — 기한이 지난 그림을 먼저 지우고, 휴지통 주소와 그림별 버린 시각을 돌려준다.
  Future<({String dirUri, Map<String, int> deletedAt})?> openSafTrash(String rootUri) =>
      _trashJob(() async {
    final trash = await _safTrashDir(rootUri);
    if (trash == null) {
      return null;
    }
    final index = await _purgeTrashDir(trash);
    final deletedAt = <String, int>{};
    for (final e in index.entries) {
      final v = e.value;
      if (v is Map && v['t'] is num) {
        deletedAt[e.key] = (v['t'] as num).toInt();
      }
    }
    return (dirUri: trash, deletedAt: deletedAt);
  });

  /// 휴지통 [trashUri] 정리 — 기한이 지난 그림을 지우고, 기록을 실제 파일에 맞춘다. 정리된 기록을 돌려준다.
  Future<Map<String, dynamic>> _purgeTrashDir(String trashUri) async {
    final index = await _readTrashIndex(trashUri);
    bool changed = false;
    try {
      final files = (await _safUtil.list(trashUri)).where((f) => !f.isDir && isImageFileName(f.name));
      final int now = DateTime.now().millisecondsSinceEpoch;
      final names = <String>{};
      for (final f in files) {
        final entry = index[f.name];
        final int? t = (entry is Map && entry['t'] is num) ? (entry['t'] as num).toInt() : null;
        if (t == null) {
          index[f.name] = {'t': now, 'p': ''}; // 기록 없는 그림 — 지금 버린 것으로 친다
          changed = true;
          names.add(f.name);
        } else if (now - t >= trashKeepDays * _kDayMs) {
          try {
            await _safUtil.delete(f.uri, false);
            index.remove(f.name);
            changed = true;
          } catch (e) {
            debugPrint('휴지통 자동 비우기 실패 (${f.name}): $e');
            names.add(f.name);
          }
        } else {
          names.add(f.name);
        }
      }
      // 파일은 없는데 기록만 남은 것 (다른 앱에서 지웠거나 옮김)
      final int before = index.length;
      index.removeWhere((name, _) => !names.contains(name));
      changed = changed || index.length != before;
    } catch (e) {
      debugPrint('휴지통 정리 실패: $e');
      return index;
    }
    if (changed) {
      await _writeTrashIndex(trashUri, index);
    }
    return index;
  }

  /// 저장 폴더 [rootUri] 의 휴지통에 든 그림 수 — 갤러리 '변경' 목록의 휴지통 버튼에 보인다.
  ///  휴지통이 없으면 0 (만들지 않는다). 기한 지난 그림 정리는 하지 않는다 — 여는 순간(openSafTrash) 한다.
  Future<int> countSafTrash(String rootUri) async {
    final trash = await _safTrashDir(rootUri, create: false);
    if (trash == null) {
      return 0;
    }
    try {
      return (await _safUtil.list(trash)).where((f) => !f.isDir && isImageFileName(f.name)).length;
    } catch (e) {
      debugPrint('휴지통 그림 수 세기 실패: $e');
      return 0;
    }
  }

  /// 앱을 켤 때 — 저장 폴더 두 칸의 휴지통에서 기한이 지난 그림을 지운다 (휴지통이 없으면 만들지 않는다).
  Future<void> purgeAllSafTrash() => _trashJob(() async {
    for (final root in safSlotUris.whereType<String>().toSet()) {
      final trash = await _safTrashDir(root, create: false);
      if (trash != null) {
        await _purgeTrashDir(trash);
      }
    }
  });

  /// 휴지통에서 되돌린다 — 원래 폴더로 (없어졌으면 다시 만든다). 반환: 되돌린 그림의 (휴지통) 주소들.
  Future<List<String>> restoreSafTrash(
    List<({String uri, String name})> refs, {
    required String rootUri,
  }) => _trashJob(() async {
    final done = <String>[];
    final trash = await _safTrashDir(rootUri);
    if (trash == null || refs.isEmpty) {
      return done;
    }
    final index = await _readTrashIndex(trash);
    for (final r in refs) {
      final entry = index[r.name];
      final String path = (entry is Map && entry['p'] is String) ? entry['p'] as String : '';
      final parts = path.split('/').where((e) => e.isNotEmpty).toList();
      try {
        final String target = parts.isEmpty ? rootUri : (await _safUtil.mkdirp(rootUri, parts)).uri;
        if (await _safRelocate(r.uri, r.name, trash, target) != null) {
          index.remove(r.name);
          done.add(r.uri);
        }
      } catch (e) {
        debugPrint('휴지통 되돌리기 실패 (${r.name}): $e');
      }
    }
    if (done.isNotEmpty) {
      await _writeTrashIndex(trash, index);
      gallerySafRevision++; // 원래 폴더를 보고 있던 갤러리가 새로 읽게
    }
    return done;
  });

  /// 휴지통에서 완전히 지운다. 반환: 지운 그림의 주소들.
  Future<List<String>> deleteSafTrash(
    List<({String uri, String name})> refs, {
    required String rootUri,
  }) => _trashJob(() async {
    final done = <String>[];
    final trash = await _safTrashDir(rootUri);
    if (trash == null || refs.isEmpty) {
      return done;
    }
    final index = await _readTrashIndex(trash);
    for (final r in refs) {
      try {
        await _safUtil.delete(r.uri, false);
        index.remove(r.name);
        done.add(r.uri);
      } catch (e) {
        debugPrint('휴지통 영구 삭제 실패 (${r.name}): $e');
      }
    }
    if (done.isNotEmpty) {
      await _writeTrashIndex(trash, index);
    }
    return done;
  });

  // SAF 폴더의 하위 폴더 목록만 조회 (이동 대상 선택용).
  // 반환: (uri, name) 리스트. 실패 시 빈 리스트.
  Future<List<({String uri, String name})>> listSafSubFolders(String dirUri) async {
    if (!Platform.isAndroid) {
      return [];
    }
    try {
      final items = await _safUtil.list(dirUri);
      final folders = <({String uri, String name})>[];
      for (final f in items) {
        if (f.isDir && !f.name.startsWith('.')) {
          folders.add((uri: f.uri, name: f.name));
        }
      }
      folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return folders;
    } catch (e) {
      debugPrint('listSafSubFolders 실패: $e');
      return [];
    }
  }

  // 앱 전용 폴더(getGalleryBasePath/DNaiApp)의 기존 이미지를 SAF 폴더로 이전.
  // deleteOriginals=true면 복사 성공한 원본을 삭제. 반환: (복사, 실패, 삭제) 수.
  Future<({int copied, int failed, int deleted})> migrateAppFolderToSaf({
    bool deleteOriginals = false,
  }) async {
    int copied = 0;
    int failed = 0;
    int deleted = 0;
    final root = safRootUri;
    if (root == null || !Platform.isAndroid) {
      return (copied: 0, failed: 0, deleted: 0);
    }

    Future<String?> ensureDir(List<String> names) async {
      try {
        if (names.isEmpty) {
          return root; // 루트 자체
        }
        final d = await _safUtil.mkdirp(root, names);
        return d.uri;
      } catch (e) {
        debugPrint('migrate mkdirp 실패 ($names): $e');
        return null;
      }
    }

    Future<void> copyFile(File f, String dirUri) async {
      try {
        final name = f.path.split('/').last;
        // ⚠️ 예전엔 jpg 가 아니면 모두 image/png 로 넘겨, WebP 파일이 '그림.webp.png' 가 됐다
        final mime = mimeForExt(extOf(name));
        final bytes = await f.readAsBytes();
        await _safStream.writeFileBytes(dirUri, name, mime, bytes);
        copied++;
        if (deleteOriginals) {
          try {
            await f.delete();
            deleted++;
          } catch (_) {
            // 원본 삭제 실패는 넘어간다. 복사는 이미 끝났으므로 이전 자체는 성공이고,
            // 여기서 멈추면 남은 파일들까지 못 옮긴다. 실패분은 앱 폴더에 그대로 남는다.
          }
        }
      } catch (e) {
        failed++;
        debugPrint('migrate 복사 실패 (${f.path}): $e');
      }
    }

    try {
      final basePath = await getGalleryBasePath(); // .../DNaiApp
      final baseDir = Directory(basePath);
      if (!await baseDir.exists()) {
        return (copied: 0, failed: 0, deleted: 0);
      }
      final entries = baseDir.listSync();
      for (final entity in entries) {
        if (entity is Directory) {
          // 세션 폴더 → 저장 폴더/세션
          final session = entity.path.split('/').last;
          final dirUri = await ensureDir([session]);
          if (dirUri == null) {
            continue;
          }
          for (final f in entity.listSync()) {
            if (f is File && isImageFileName(f.path.split('/').last)) {
              await copyFile(f, dirUri);
            }
          }
        } else if (entity is File && isImageFileName(entity.path.split('/').last)) {
          // 세션 없이 베이스 바로 아래 있는 이미지 → 저장 폴더 바로 아래
          final dirUri = await ensureDir([]);
          if (dirUri != null) {
            await copyFile(entity, dirUri);
          }
        }
      }
    } catch (e) {
      debugPrint('앱 폴더→SAF 이전 에러: $e');
    }
    return (copied: copied, failed: failed, deleted: deleted);
  }

  /// SAF 파일의 [start] 부터 [count] 바이트 (파일 끝이면 그보다 짧다). 읽지 못하면 null.
  ///  갤러리 검색이 그림 정보 부분만 읽을 때 쓴다 (utils/gallery_search_index.dart — 통째로 읽지 않게).
  Future<Uint8List?> readSafRange(String fileUri, int start, int count) async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      // (readSafImage 와 같이 Uint8List 로 감싼다 — 플러그인 판마다 돌려주는 형이 달랐다)
      return Uint8List.fromList(await _safStream.readFileBytes(fileUri, start: start, count: count));
    } catch (e) {
      debugPrint('readSafRange 실패: $e');
      return null;
    }
  }

  /// 여러 폴더를 함께 조회한다 — SAF 조회는 I/O 대기라 겹쳐 던지면 거의 한 번 시간에 끝난다.
  ///  못 읽은 폴더는 null (나머지 결과는 살린다). 조회 함수를 받는 건 list() 의 원소 형을 그대로 쓰려고.
  Future<List<T?>> _safListEach<T>(List<String> dirUris, Future<T> Function(String uri) list) =>
      Future.wait(
        dirUris.map((d) async {
          try {
            return await list(d);
          } catch (e) {
            debugPrint('SAF 폴더 조회 실패 — 건너뜀 ($d): $e');
            return null;
          }
        }),
      );

  /// [dirUri] 아래의 그림 전부 — 하위 폴더까지 ('.' 으로 시작하는 폴더는 건너뛴다 — 휴지통 등).
  ///  그림마다 든 폴더와 수정 시각을 같이 준다 (갤러리 검색). 순서는 정하지 않는다 (부르는 쪽이 정렬).
  ///  같은 깊이의 폴더는 몇 개씩 함께 조회한다 (SAF 조회는 I/O 대기라 겹치면 빠르다 — listSafDirDetailed 와 같다).
  ///  [isCancelled] 가 true 를 돌려주면 그만둔다. 못 읽은 폴더는 건너뛴다.
  Future<List<SafImageRef>> listSafImagesDeep(String dirUri, {bool Function()? isCancelled}) async {
    final out = <SafImageRef>[];
    if (!Platform.isAndroid) {
      return out;
    }
    const int batch = 8; // 한꺼번에 조회할 폴더 수
    const int maxDepth = 8; // 너무 깊이는 내려가지 않는다 (폴더가 서로 가리키는 이상한 경우에도 끝나게)
    List<String> level = [dirUri];
    for (int depth = 0; depth <= maxDepth && level.isNotEmpty; depth++) {
      final next = <String>[];
      for (int i = 0; i < level.length; i += batch) {
        if (isCancelled?.call() ?? false) {
          return out;
        }
        final part = level.sublist(i, min(i + batch, level.length));
        final lists = await _safListEach(part, _safUtil.list);
        for (int k = 0; k < part.length; k++) {
          final items = lists[k];
          if (items == null) {
            continue;
          }
          for (final f in items) {
            if (f.isDir) {
              if (!f.name.startsWith('.')) {
                next.add(f.uri);
              }
            } else if (isImageFileName(f.name)) {
              out.add((uri: f.uri, name: f.name, parentUri: part[k], modified: f.lastModified));
            }
          }
        }
      }
      level = next;
    }
    return out;
  }

  // SAF 파일 바이트 읽기
  Future<Uint8List?> readSafImage(String fileUri) async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final bytes = await _safStream.readFileBytes(fileUri);
      return Uint8List.fromList(bytes);
    } catch (e) {
      debugPrint('readSafImage 실패: $e');
      return null;
    }
  }

  // ===== SAF 썸네일 캐시 =====
  // 갤러리 그리드/폴더 미리보기는 원본 대신 작은 썸네일(jpeg)을 사용해
  // 로딩 속도와 메모리를 크게 줄인다. 앱 캐시 폴더에 파일로 저장돼 재실행에도 유지.
  Directory? _safThumbDirCache;

  Future<Directory> _safThumbDir() async {
    final cached = _safThumbDirCache;
    if (cached != null) {
      return cached;
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/saf_thumbs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _safThumbDirCache = dir;
    return dir;
  }

  // URI → 캐시 파일명 키. content URI는 파일명으로 못 쓰니 32비트 FNV-1a를
  // 정방향+역방향 두 번 돌려 64비트 상당으로 충돌 확률을 낮춘다 (결정적).
  String _thumbKeyFor(String uri) {
    int fnv(Iterable<int> units) {
      int h = 0x811c9dc5;
      for (final c in units) {
        h ^= c;
        h = (h * 0x01000193) & 0xFFFFFFFF;
      }
      return h;
    }

    final f = fnv(uri.codeUnits).toRadixString(16);
    final b = fnv(uri.codeUnits.reversed).toRadixString(16);
    return '${f}_$b';
  }

  // 폴백용: 원본 바이트 → 320px JPG (백그라운드 isolate에서 실행해 UI 버벅임 방지)
  static Uint8List? _makeSafThumbIsolate(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return null;
      }
      final resized = decoded.width <= 320 ? decoded : img.copyResize(decoded, width: 320);
      return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    } catch (_) {
      return null;
    }
  }

  /// 앱을 켤 때 캐시 정리 (utils/temp_files.dart) — 시작 일이 끝나고 조금 뒤에.
  ///  · 캐시에 남은 잠깐 파일 (내보내기 · 그림/파일 고르기 복사본)
  ///  · 갤러리 섬네일 캐시가 200MB 를 넘으면 오래 안 본 것부터 150MB 까지 (볼 때 다시 만든다)
  ///  ⚠️ 히스토리 · 사전 · i2i 즐겨찾기 같은 앱 데이터는 건드리지 않는다 — 각자 자기 규칙으로 정리한다.
  ///  안드로이드에서만 — 데스크톱의 캐시는 다른 프로그램과 같이 쓰는 임시 폴더다.
  Future<void> _tidyCacheSoon() async {
    if (!Platform.isAndroid) {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 8));
    await cleanCacheLeftovers();
    try {
      final int removed = await trimThumbCache(await _safThumbDir());
      if (removed > 0) {
        debugPrint('갤러리 섬네일 캐시 정리: $removed장 (오래 안 본 것)');
      }
    } catch (e) {
      debugPrint('갤러리 섬네일 캐시 정리 실패(무시): $e'); // 기다리지 않는 일이라 여기서 받는다
    }
  }

  // SAF 이미지의 썸네일 바이트 (디스크 캐시 → 네이티브 생성 → 직접 축소 → 실패 시 원본 폴백)
  Future<Uint8List?> readSafThumb(String fileUri) async {
    if (!Platform.isAndroid) {
      return null;
    }
    File? thumbFile;
    try {
      final dir = await _safThumbDir();
      thumbFile = File('${dir.path}/${_thumbKeyFor(fileUri)}.jpg');
      final f = thumbFile;
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        unawaited(touchCacheFile(f)); // 자주 보는 섬네일은 캐시 정리(_tidyCacheSoon)에서 남게
        return bytes;
      }
      final ok = await _safUtil.saveThumbnailToFile(
        uri: fileUri,
        width: 320,
        height: 320,
        destPath: f.path,
      );
      if (ok && await f.exists()) {
        return await f.readAsBytes();
      }
    } catch (e) {
      debugPrint('readSafThumb 실패: $e');
    }
    // 썸네일 미지원/실패 → 원본을 읽어 직접 축소 (원본 통째 반환은 메모리 낭비라 최후 수단)
    final bytes = await readSafImage(fileUri);
    if (bytes == null) {
      return null;
    }
    try {
      // 네이티브 WebP 가 먼저 (순수 Dart 로 PNG 를 푸는 것보다 훨씬 빠르다), 안 되면 옛 방식
      final thumb = await makeGalleryThumb(bytes) ?? await compute(_makeSafThumbIsolate, bytes);
      if (thumb != null) {
        final f = thumbFile;
        if (f != null) {
          // 다음부턴 디스크 캐시로 즉시. 반쯤 쓴 썸네일이 남으면 그 그림이 계속 깨져 보여서 안전하게 쓴다.
          await _writeBytesAtomic(f, thumb);
        }
        return thumb;
      }
    } catch (e) {
      debugPrint('썸네일 폴백 축소 실패: $e');
    }
    return bytes; // 축소까지 실패하면 원본이라도 표시
  }

  // 앱 시작 시 저장된 SAF 폴더(두 칸) 복원 — 권한이 아직 유효한 칸만
  Future<void> _loadSafRoot() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      for (int i = 0; i < kSafSlotCount; i++) {
        final uri = prefs.getString(_safUriKey(i));
        if (uri == null || uri.isEmpty) {
          continue;
        }
        if (await _safUtil.hasPersistedPermission(uri)) {
          safSlotUris[i] = uri;
          safSlotNames[i] = prefs.getString(_safNameKey(i));
        } else {
          // 권한이 풀림(재부팅/회수/에뮬 초기화) → 캐시 정리
          await prefs.remove(_safUriKey(i));
          await prefs.remove(_safNameKey(i));
        }
      }
      activeSafSlot = (prefs.getInt('safActiveSlot') ?? 0).clamp(0, kSafSlotCount - 1);
      // 쓰던 칸이 비었으면(권한이 풀림) 폴더가 남은 칸으로 — 앱 전용 폴더로 몰래 새지 않게
      if (safSlotUris[activeSafSlot] == null) {
        activeSafSlot = _otherFilledSafSlot(activeSafSlot) ?? activeSafSlot;
      }
    } catch (e) {
      debugPrint('SAF 루트 로드 실패: $e');
    }
  }

  // 갤러리 '변경' 목록의 '기타' 위치 (권한 불필요한 경로들 — 저장 폴더(SAF)는 따로 보여 준다).
  // 반환: [(이름, 경로, 그 안(하위 폴더 포함)의 그림 수)] — 지금은 앱 저장 폴더 하나.
  //  폴더가 있기만 하면 그림이 0장이어도 돌려준다. 보여 줄지는 갤러리가 정한다
  //  (저장 폴더를 안 정해 지금 이 폴더를 보고 있으면 비어 있어도 보여야 하므로).
  //  ⚠️ 예전엔 폴더가 있기만 하면 늘 보였다. 그런데 이 폴더는 '들여다보기만 해도' 생기고
  //     (getGalleryBasePath 가 만들었다), 앱 폴더 → SAF 이전으로 옮긴 뒤에도 빈 세션 폴더가 남아,
  //     볼 게 없는 빈 폴더가 목록에 계속 떠 있었다.
  Future<List<({String label, String path, int images})>> getGalleryLocations() async {
    final locations = <({String label, String path, int images})>[];

    // 1. 앱 외부 저장소/DNaiApp — 저장 폴더를 정하기 전(또는 저장 폴더에 저장이 실패했을 때) 그림이 가는 곳
    final appDir = await getExternalStorageDirectory();
    if (appDir != null) {
      final dir = Directory('${appDir.path}/DNaiApp');
      if (await dir.exists()) {
        locations.add((label: "앱 저장 폴더", path: dir.path, images: await _countImagesIn(dir)));
      }
    }

    // ⚠️ 예전엔 앱 저장 폴더가 없으면 '기본 폴더'(앱 내부 문서 폴더)를 대신 보여 줬다.
    //    거긴 히스토리 원본·썸네일·설정 같은 앱 살림 파일만 있는 곳이라 볼 일이 없고,
    //    갤러리에서 지우거나 옮기면 히스토리가 깨질 수 있어 목록에서 뺐다.
    return locations;
  }

  /// [dir] 안(하위 폴더 포함)의 그림 수. 읽지 못하면 0.
  Future<int> _countImagesIn(Directory dir) async {
    int n = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File && isImageFileName(e.path)) {
          n++;
        }
      }
    } catch (e) {
      debugPrint('그림 수 세기 실패 (${dir.path}): $e');
    }
    return n;
  }

  // 갤러리 기본 경로 (앱 외부 저장소의 DNaiApp 폴더).
  //  경로만 돌려주고 폴더는 만들지 않는다 — 여기를 부르는 곳(갤러리 둘러보기 · 앱 폴더 → SAF 이전)은
  //  읽기만 한다. 그림을 저장할 때는 저장하는 쪽이 세션 폴더까지 알아서 만든다.
  //  ⚠️ 예전엔 여기서 만들어서, 저장 폴더를 정하기 전에 갤러리를 한 번 열기만 해도
  //     빈 '앱 저장 폴더'가 생겨 '변경' 목록에 계속 떠 있었다.
  //     (폴더가 없으면 갤러리는 '이 폴더는 비어있어요'로 보여 준다)
  Future<String> getGalleryBasePath() async {
    final appDir = await getExternalStorageDirectory();
    if (appDir != null) {
      return '${appDir.path}/DNaiApp';
    }
    final docDir = await getApplicationDocumentsDirectory();
    return docDir.path;
  }

  // ── 모델별 상세환경 기억 ──
  //  모델마다 잘 맞는 설정값이 다르다(예: V4.5는 28스텝, V5는 25스텝).
  //  모델을 바꿀 때 지금 값을 그 모델 앞으로 저장해두고,
  //  새 모델에서 마지막으로 쓰던 값을 되살린다.
  //  기록이 없으면 현재 값을 유지한다(첫 전환에서 값이 튀지 않게).
  Map<String, Map<String, String>> modelSettingProfiles = {};

  Map<String, String> _currentDetailSnapshot() => {
    'steps': stepsController.text,
    'cfg': cfgScaleController.text,
    'rescale': cfgRescaleController.text,
    'sampler': selectedSampler,
    'scheduler': selectedScheduler,
    'resolution': selectedResolution,
    'resolutionMode': resolutionMode,
  };

  void _applyDetailSnapshot(Map<String, String> p) {
    stepsController.text = p['steps'] ?? stepsController.text;
    cfgScaleController.text = p['cfg'] ?? cfgScaleController.text;
    cfgRescaleController.text = p['rescale'] ?? cfgRescaleController.text;
    selectedSampler = validSampler(p['sampler'] ?? selectedSampler);
    selectedScheduler = validScheduler(p['scheduler'] ?? selectedScheduler);
    selectedResolution = validResolution(p['resolution'] ?? selectedResolution);
    resolutionMode = p['resolutionMode'] ?? resolutionMode;
  }

  // 모델별 권장 기본값 (그 모델을 처음 쓸 때만 적용된다).
  //  공식 UI 기본값 기준 — V5는 스텝 23 / Guidance 7 / karras.
  static const Map<String, Map<String, String>> _modelDefaults = {
    NaiModels.v5Full: {
      'steps': '23',
      'cfg': '7.0',
      'rescale': '0.00',
      'sampler': kDefaultSampler,
      'scheduler': kDefaultScheduler,
    },
  };

  /// 모델 교체 — 현재 설정을 이전 모델 앞으로 저장하고, 새 모델의 기록을 불러온다.
  void switchModel(String newModel) {
    if (newModel == selectedModel) {
      return;
    }
    modelSettingProfiles[selectedModel] = _currentDetailSnapshot();
    selectedModel = newModel;
    final saved = modelSettingProfiles[newModel];
    if (saved != null) {
      // 그 모델에서 마지막으로 쓰던 값 복원
      _applyDetailSnapshot(saved);
    } else {
      // 처음 쓰는 모델이면 권장 기본값을 적용한다
      final defaults = _modelDefaults[newModel];
      if (defaults != null) {
        _applyDetailSnapshot(defaults);
      }
    }
    final caps = modelCapsFor(newModel);
    // ⚠️ 모델마다 캐릭터 상한이 다르다 (V5=32, V4.5=6).
    //    많은 쪽에서 적은 쪽으로 바꾸면 초과분이 그대로 전송돼 오류가 난다.
    //    지우지는 않고 '비활성'으로 돌려 데이터는 보존한다.
    //    (다시 V5로 오면 켜서 쓸 수 있다)
    if (characters.length > caps.maxCharacters) {
      for (int i = caps.maxCharacters; i < characters.length; i++) {
        characters[i].isActive = false;
      }
    }
    // 선택 인덱스가 범위를 벗어나면 되돌린다
    if (selectedCharIndex >= characters.length) {
      selectedCharIndex = characters.isEmpty ? 0 : characters.length - 1;
    }
    saveAllSettings();
    notifyListeners();
  }

  String selectedModel = kDefaultModel;
  String selectedSampler = kDefaultSampler;
  String selectedScheduler = kDefaultScheduler;

  /// 스케줄러 잠금 해제 — 스케줄러가 고정된 모델(V5 = karras)에서도 다른 값을 쓸 수 있게 한다.
  ///  꺼져 있으면(기본) 그 모델은 고정값으로만 보낸다. 실수로 바꾸지 않게 잠가 두는 것.
  bool schedulerUnlocked = false;

  /// [model] 로 보낼 스케줄러. 고정 모델이고 잠금 해제가 꺼져 있으면 고정값,
  ///  아니면 [requested] (없으면 고른 값).
  ///  ⚠️ 고른 값(selectedScheduler)은 건드리지 않는다 — 잠금을 풀면 전에 고른 값이 다시 쓰인다.
  String schedulerFor(String model, [String? requested]) {
    final fixed = modelCapsFor(model).fixedScheduler;
    if (fixed != null && !schedulerUnlocked) {
      return fixed;
    }
    return requested ?? selectedScheduler;
  }

  /// 지금 모델에서 스케줄러가 잠겨 있으면 그 고정값, 아니면 null (상세 환경 화면용)
  String? get lockedScheduler =>
      schedulerUnlocked ? null : modelCapsFor(selectedModel).fixedScheduler;
  String selectedResolution = kDefaultResolution;
  double resolutionScale = 1.0; // kResolutionScales 중 하나 (1.0 · 1.25 · 1.5)

  // 픽셀/개수 한계 상수 (매직넘버 방지)
  //  - kMegapixelCap: 1024×1024. 자동 모드 상한이자 Opus 무료 생성 기준
  //  - kNaiPixelHardCap: NAI가 허용하는 절대 픽셀 상한
  //    ⚠️ 실제 생성 시 상한은 ModelCaps.maxPixels가 단일 출처다.
  //       이 상수는 모델과 무관한 기본값(=V4.5 기준)으로만 남겨 둔다.
  static const int kMegapixelCap = 1048576;
  static const int kNaiPixelHardCap = 3145728;
  // 히스토리 최대 보관 장수 (즐겨찾기는 넘쳐도 남는다).
  //  최근 30장만 원본, 나머지는 긴 변 768 WebP(장당 20~30KB) — 300장이어도 늘어나는 건 디스크 · 메모리 7MB 남짓.
  //  ⚠️ 더 크게(1000장 쯤) 올리려면 먼저: history.json 을 생성마다 통째로 화면 쪽에서 굽는 것 · 켤 때 그림을 다 읽는 것
  //     (DEVNOTES '히스토리 저장 형식'). 3.12.0 에서 100 → 300.
  static const int kHistoryCap = 300;
  List<String> customResolutions = []; // 사용자 추가 해상도

  /// 해상도 값 검사 — 드롭다운에 있는 값(기본 목록·사용자 목록·직접 입력)이면 그대로,
  ///  아니면 기본값. 값이 들어오는 모든 길(앱 켤 때·백업 복원·프리셋·모델 전환)이 거친다.
  ///  ⚠️ 예전엔 드롭다운이 '화면에만' 기본값을 보여 주고 상태엔 이상한 값이 남아,
  ///     생성할 때 그 값을 풀다가 예외가 났다.
  String validResolution(Object? v) {
    if (v is! String) {
      return kDefaultResolution;
    }
    if (v == kCustomResolutionLabel ||
        kNaiResolutions.contains(v) ||
        customResolutions.contains(v)) {
      return v;
    }
    return kDefaultResolution;
  }

  List<NaiCharacter> characters = [NaiCharacter()];

  /// 캐릭터 목록이 '외부에서' 통째로 바뀔 때마다 1씩 오른다.
  ///  (이미지에서 프롬프트 불러오기, 프리셋 적용, 삭제·순서 변경 등)
  ///
  ///  화면이 캐릭터별로 캐시해 둔 입력 컨트롤러는 이 값이 달라졌을 때
  ///  '편집 중이라도' 내용을 다시 맞춰야 한다. 그러지 않으면 옛 텍스트를 든
  ///  컨트롤러가 나중에 모델을 되돌려 버린다.
  int charactersRevision = 0;

  /// 캐릭터 목록을 외부에서 바꾼 뒤 호출한다.
  /// 지금 고른 캐릭터. 목록이 비었으면 null.
  ///
  /// ⚠️ selectedCharIndex 를 그대로 믿고 characters[...] 를 읽으면 안 된다.
  ///    프롬프트 불러오기로 캐릭터가 3개에서 1개로 줄어도 선택 번호는 2로
  ///    남아 있을 수 있고, 그 상태로 읽으면 범위를 벗어난다.
  ///    읽기 전에 이 getter 로 한 번 거르면 어느 화면에서든 안전하다.
  NaiCharacter? get selectedCharacter {
    if (characters.isEmpty) {
      return null;
    }
    if (selectedCharIndex < 0 || selectedCharIndex >= characters.length) {
      // 범위를 벗어나 있었다면 여기서 바로잡아 둔다 (다음 접근부터는 정상)
      selectedCharIndex = characters.length - 1;
    }
    return characters[selectedCharIndex];
  }

  // ── 캐릭터 하나씩 넣고 빼기 ──────────────────────────────────────
  //  목록을 바꾼 뒤엔 늘 '선택 번호 맞추기 → 캐시 다시 맞추기(markCharactersReplaced)
  //  → 저장'을 함께 해야 한다. 화면마다 따라 적으면 한 줄 빠뜨려 번호가 어긋나기 쉬워
  //  여기로 모은다. (여러 개를 한꺼번에 넣는 프리셋·메타데이터 적용은 각자 끝에서
  //  markCharactersReplaced 를 부른다)

  /// 캐릭터를 하나 더하고 그 캐릭터를 선택한다.
  void addCharacter([NaiCharacter? character]) {
    characters.add(character ?? NaiCharacter());
    selectedCharIndex = characters.length - 1;
    markCharactersReplaced(); // 화면 갱신도 여기서
    unawaited(saveAllSettings());
  }

  /// [index] 번 캐릭터를 지운다. 선택은 같은 캐릭터(또는 바로 앞)를 따라간다.
  ///  목록이 비면 빈 캐릭터 하나를 둔다 (캐릭터 화면이 빈 번호를 가리키지 않게).
  void removeCharacterAt(int index) {
    if (index < 0 || index >= characters.length) {
      return;
    }
    characters.removeAt(index);
    if (selectedCharIndex > 0 && selectedCharIndex >= index) {
      selectedCharIndex--;
    }
    if (characters.isEmpty) {
      characters.add(NaiCharacter());
    }
    markCharactersReplaced();
    unawaited(saveAllSettings());
  }

  /// [from] 번 캐릭터를 [to] 자리로 옮기고, 선택이 옮긴 캐릭터를 따라가게 한다.
  void moveCharacter(int from, int to) {
    if (from == to || from < 0 || to < 0 || from >= characters.length || to >= characters.length) {
      return;
    }
    final moved = characters.removeAt(from);
    characters.insert(to, moved);
    selectedCharIndex = to;
    markCharactersReplaced();
    unawaited(saveAllSettings());
  }

  void markCharactersReplaced() {
    charactersRevision++;
    // 목록이 바뀌면 선택 번호부터 바로잡는다.
    //  (여기서 한 번 맞춰 두면 화면들이 각자 검사하지 않아도 된다)
    if (selectedCharIndex >= characters.length) {
      selectedCharIndex = characters.isEmpty ? 0 : characters.length - 1;
    }
    _pruneCharacterUndo();
    notifyListeners();
  }

  /// 지금 없는 캐릭터의 되돌리기 기록을 버린다.
  ///
  /// 캐릭터를 지우거나 프롬프트 불러오기로 통째로 교체하면 옛 기록이 남는다.
  /// 그대로 두면 설정 파일만 계속 불어나고, 우연히 같은 uid 가 생기면
  /// 엉뚱한 내용으로 되돌아갈 수도 있다.
  ///  ⚠️ 목록을 바꾸는 곳마다 따로 지우게 하면 빠뜨리기 쉬우므로,
  ///     '캐릭터가 바뀌었다'는 신호 한 곳에서만 처리한다.
  void _pruneCharacterUndo() {
    if (promptUndoHistory.isEmpty) {
      return;
    }
    final alive = characters.map((c) => c.uid).toSet();
    // 캐릭터 기록의 열쇠는 'char/<uid>/긍정' 형태다
    final dead = promptUndoHistory.keys
        .where((k) => k.startsWith('char/') && !alive.contains(k.split('/')[1]))
        .toList();
    if (dead.isEmpty) {
      return;
    }
    for (final k in dead) {
      promptUndoHistory.remove(k);
    }
    // ⚠️ 여기서 saveAllSettings 를 부르지 않는다.
    //    이 함수를 부르는 쪽(삭제·교체·프리셋 적용)이 모두 곧바로 저장하므로,
    //    여기서 또 부르면 설정 116개를 잇달아 두 번 쓰게 된다.
    //    그 연쇄가 겹치면 화면이 멈춘 것처럼 보인다.
  }

  int selectedCharIndex = 0;
  bool useCharacterPosition = true; // 캐릭터 배치 적용 ON/OFF (그리드 좌표 반영)

  // V5 캐릭터 캔버스 옵션
  bool charCanvasShowGrid = false; // 정렬용 격자선
  bool charCanvasSnap = false; // 0.05 단위로 맞추기

  // Position 캔버스 배경으로 그림을 깔지 여부.
  //  공식처럼 실제 그림을 보면서 캐릭터 위치를 잡을 수 있다.
  //  i2i 작업 이미지가 있으면 그것을, 없으면 최근 생성 결과를 쓴다.
  bool charCanvasShowImage = false;

  // 격자 칸 수 (2~12). 2면 가운데 1줄이 생긴다.
  int charGridCols = 5;
  int charGridRows = 5;

  /// 사용자가 직접 고른 배경 이미지.
  ///  null이면 자동(i2i 작업 이미지 → 없으면 최근 생성물)으로 고른다.
  ///  ⚠️ 메모리에만 두고 저장하지 않는다 (용량이 크고, 켤 때마다 다시 고르면 된다).
  Uint8List? charCanvasPickedImage;

  /// 캔버스 배경으로 쓸 이미지 (없으면 null)
  Uint8List? get charCanvasBackground {
    if (!charCanvasShowImage) {
      return null;
    }
    // 직접 고른 게 있으면 그걸 우선
    if (charCanvasPickedImage != null) {
      return charCanvasPickedImage;
    }
    // 자동 — 히스토리의 가장 최신 결과
    if (historyImages.isNotEmpty) {
      return historyImages.last;
    }
    // 히스토리가 비었으면 i2i 작업 이미지라도
    if (targetI2iImage != null) {
      return targetI2iImage;
    }
    return null;
  }

  /// 배경 이미지를 직접 고른다 (null이면 자동으로 되돌림)
  void setCharCanvasImage(Uint8List? bytes) {
    charCanvasPickedImage = bytes;
    if (bytes != null) {
      charCanvasShowImage = true; // 고르면 자동으로 켠다
    }
    saveAllSettings();
    notifyListeners();
  }

  // 투명 배경 (V5 전용).
  //  켜면 요청에 straight_alpha를 실어 알파 채널이 살아있는 이미지를 받는다.
  //  ⚠️ JPEG는 알파를 담지 못하므로 PNG나 WebP로 저장해야 의미가 있다.
  bool transparentBackground = false;

  // ── 공식 프리셋 (NovelAI 웹과 동일한 자동 태그) ──
  //  Quality Tags: 긍정 프롬프트 '뒤'에 붙는 품질 태그
  //  UC Preset:    부정 프롬프트에 붙는 기본 제외 태그
  //  값은 프리셋 '이름'을 저장한다 (모델이 바뀌어도 같은 이름이면 이어진다).
  String qualityTagsPreset = 'None';
  String ucPreset = 'None';
  bool randomCharacterOrder = false; // 캐릭터 순서 랜덤 (배치 적용과 상호 배타)

  // 배치 적용 ↔ 랜덤 배치는 동시에 켤 수 없다 (둘 다 끄는 건 가능)
  void setUseCharacterPosition(bool v) {
    useCharacterPosition = v;
    if (v) {
      randomCharacterOrder = false;
    }
    saveAllSettings();
    notifyListeners();
  }

  void setRandomCharacterOrder(bool v) {
    randomCharacterOrder = v;
    if (v) {
      useCharacterPosition = false;
    }
    saveAllSettings();
    notifyListeners();
  }

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
  // 검색 진행 상황 (실시간 표시용)
  int gelbooruSearchDone = 0;
  int gelbooruSearchTotal = 0;
  // 검색 중 지금까지 찾은 개수 — 검색 버튼에 표시한다.
  //  ('다음 (P : N)' 은 검색 중에도 예전 목록의 남은 개수를 그대로 보여 준다)
  int gelbooruSearchFound = 0;
  // 검색 후 단계 메시지 (분류/필터/캐시 — 페이지 수신 완료 후 표시)
  String gelbooruSearchStage = "";
  // 검색 목록 파일 보관 (검색 쪽 메서드는 app_state_search.dart)
  int _promptsSaveSeq = 0; // 저장이 겹치면 마지막 것만 쓰려고
  bool _gelbooruPromptsLoaded = false; // 불러오기가 중간에 끊긴 경우를 loadInitialData 가 메운다

  final NovelAiService _service = NovelAiService();
  Uint8List? currentImageBytes;
  String? lastErrorMessage;

  bool isLoading = false;
  bool isUpscaleLoading = false;
  bool isInpaintLoading = false;
  String inpaintStatusMessage = ""; // 인페인트 진행 상태 실시간 표시용

  int currentAnlas = 0;

  // ── V5 사용 한도 ──
  //  V5는 시간당 회복되는 사용 한도가 있다.
  //  값은 fetchAnlas() 가 /user/subscription 응답의 usage 필드에서 채운다
  //  (잔액과 같은 요청 한 번에 함께 온다 — 따로 조회하지 않는다).
  //  · null  = 아직 모름 (UI에 "확인중" 표시)
  //  · 0~100 = 남은 비율(%)
  double? v5LimitPercent;
  DateTime? v5LimitCheckedAt;

  /// 부스트로 산 추가 사용량(%, 공식 화면의 'Extra Usage'). 없으면 0.
  ///  기본 한도(v5LimitPercent)와 따로 오고, 기본을 다 쓰면 이걸 쓴다 — 그래서 기본이 0% 여도 무료로 생성된다.
  double v5ExtraPercent = 0;

  /// 한도를 다 써서 Anlas를 소모하는 중인지
  bool v5LimitNegative = false;

  /// V5 무료 한도가 바닥났는지 (조회한 값 기준 — 모르면 false).
  ///  공식 설명상 한도가 다 되면 그때부터는 Anlas 로 생성된다 → 무료로 보지 않는다 (_opusFreeSize).
  ///  부스트(추가 사용량)가 남아 있으면 아직 아니다 — 예전엔 기본 0% 만 보고 '소진' 으로 봐서 연속 생성이 멈췄다.
  bool get v5LimitExhausted => v5LimitNegative || ((v5LimitPercent ?? 1) + v5ExtraPercent) <= 0;

  // ⚠️ 예전엔 fetchV5Limit() 이라는 fetchAnlas() 별칭이 있어, fetchAnlas() 바로 뒤에 불러
  //    같은 요청을 두 번 보냈다 (앱을 켤 때는 최대 4번을 기다렸다). 지워서 한 번으로 줄였다.
  int subscriptionTier = 0;

  // 히스토리 — 한 칸 = 이미지·정보·즐겨찾기·경로 한 덩어리 (HistoryEntry).
  //  ⚠️ 예전엔 이 넷이 따로 된 목록 네 개였고 번호로 짝을 맞췄다. 하나라도 어긋나면
  //     즐겨찾기가 한 칸씩 밀리거나 경로가 이웃 칸에 붙었다 (실제로 '즐겨찾기가 풀렸다'
  //     버그가 있었다). 이제 칸을 넣고 빼는 건 [history] 로만 한다.
  List<HistoryEntry> history = [];

  // 옛 이름 넷은 [history] 를 들여다보는 창이다 — 읽기와 '한 칸 바꾸기'만 된다.
  //  (예: historyFavorites[i] = true 는 history[i].favorite 를 바꾼다)
  //  넣고 빼기(add·removeAt·clear…)를 하면 바로 오류가 난다 — 어긋날 길을 막으려고.
  late final List<Uint8List> historyImages = _HistoryField(
    () => history,
    (e) => e.image,
    (e, v) => e.image = v,
  );
  late final List<NaiMetadata?> historyMetadata = _HistoryField(
    () => history,
    (e) => e.metadata,
    (e, v) => e.metadata = v,
  );
  late final List<bool> historyFavorites = _HistoryField(
    () => history,
    (e) => e.favorite,
    (e, v) => e.favorite = v,
  );
  late final List<String?> historyFilePaths = // 자동저장된 파일 경로 추적
  _HistoryField(
    () => history,
    (e) => e.filePath,
    (e, v) => e.filePath = v,
  );
  int selectedHistoryIndex = -1;

  // i2i 스크래치 릴 (인페인트 등 반복 결과 임시 보관, 즐겨찾기만 영속)
  List<I2iResult> i2iResults = [];
  static const int i2iResultsCap = 30; // 릴 전체 보관 상한 (즐겨찾기 포함)
  static const int i2iFavoriteCap = 5; // 즐겨찾기 최대 개수
  double i2iHandleBottom = -1; // i2i 릴 핸들 세로 위치 (-1이면 기본값 사용)
  double promptCharHandleTop = -1; // 프롬프트 탭 캐릭터 편집 손잡이 세로 위치 (-1이면 기본값)
  bool i2iHistoryDisabled = false; // ON이면 릴 끄고 i2i 결과를 메인 히스토리에 저장
  // i2i 히스토리 핸들이 켜져 있을 때의 인페인트 세부 옵션
  // 작업 결과를 곧바로 '작업 이미지'로 바꾸지 않음 (기본 OFF = 바꿈).
  //  이름은 인페인트에서 시작했지만 모자이크·Director 결과에도 함께 적용된다.
  //  설정 키를 바꾸면 기존 사용자 설정이 초기화되므로 이름은 그대로 둔다.
  bool inpaintNoAutoSwitch = false;
  bool inpaintAutoClearMask = false;

  /// i2i 탭에 Director Tool 전환 버튼을 보여 줄지. 기본 ON.
  ///  꺼도 이미 만들어 둔 결과나 설정은 그대로 남는다 — 버튼만 감춘다.
  bool directorToolVisible = true;
  bool galleryModeEnabled = true; // 갤러리 모드(공용 폴더 탐색) 사용 여부 — 기본 ON

  /// 갤러리에서 지운 그림을 휴지통(저장 폴더의 '.trash')으로 보낼지. 기본 ON — OFF 면 바로 영구 삭제.
  ///  휴지통은 저장 폴더(SAF)에만 있다 — 앱 폴더의 그림은 늘 바로 지운다.
  ///  5곳 패턴: 선언 · 불러오기 · 내보내기 · 가져오기 · 저장
  bool trashEnabled = true;

  /// 휴지통의 그림을 며칠 뒤 자동으로 지울지 (1~30일, 기본 14). 5곳 패턴.
  int trashKeepDays = 14;

  /// 히스토리 탭에 들어올 때 마지막으로 보던 보기(목록·그리드 / 갤러리)를 그대로 보여 줄지. 기본 OFF.
  ///  OFF 면 늘 목록·그리드부터 (탭을 떠날 때 갤러리를 닫아 둔다 — resetHistoryGalleryInBackground).
  ///  5곳 패턴: 선언 · 불러오기 · 내보내기 · 가져오기 · 저장
  bool historyKeepLastView = false;

  /// 히스토리 탭이 마지막으로 갤러리 모드였는지 (historyKeepLastView 가 켜져 있을 때 쓴다).
  ///  앱을 껐다 켜도 이어지게 저장한다. 5곳 패턴에 같이 들어 있다.
  bool historyLastWasGallery = false;

  /// 히스토리 탭의 보기가 바뀔 때 기억한다 — 바뀐 값 하나만 바로 저장.
  void setHistoryLastWasGallery(bool value) {
    if (historyLastWasGallery == value) {
      return;
    }
    historyLastWasGallery = value;
    SharedPreferences.getInstance().then((p) => p.setBool('historyLastWasGallery', value));
  }

  // SAF (Storage Access Framework) — 사용자가 고른 저장 폴더의 트리 URI
  final SafUtil _safUtil = SafUtil();
  final SafStream _safStream = SafStream();
  // 저장 폴더는 두 칸 — NovelAI 계정처럼 하나만 켜서 쓴다 (켜진 칸 = 저장·갤러리·백업 위치).
  //  칸마다 트리 URI 와 표시용 이름. null = 빈 칸.
  //  ⚠️ 1번 칸은 예전 설정 이름(safRootUri·safRootName)을 그대로 써서, 업데이트해도 고른 폴더가 유지된다.
  static const int kSafSlotCount = 2;
  final List<String?> safSlotUris = List<String?>.filled(kSafSlotCount, null);
  final List<String?> safSlotNames = List<String?>.filled(kSafSlotCount, null);
  int activeSafSlot = 0;

  /// 저장 폴더가 바뀔 때마다(지정·전환·해제) 1씩 는다 — 열려 있는 갤러리가 새 폴더로 다시 연다.
  int safRootRevision = 0;

  /// 지금 쓰는 저장 폴더의 트리 URI (null = 미선택)
  String? get safRootUri => safSlotUris[activeSafSlot];

  /// 지금 쓰는 저장 폴더의 표시용 이름
  String? get safRootName => safSlotNames[activeSafSlot];
  String? _safSessionDirUri; // 현재 세션의 SAF 디렉토리 URI 캐시
  String? _safSessionDirName; // 캐시된 세션 이름

  List<NaiMetadata?> i2iHistoryMetadata = [];
  int selectedI2iHistoryIndex = -1;

  Uint8List? targetI2iImage;
  NaiMetadata? targetI2iMetadata;

  /// i2i 비교 보기의 '기준' 그림 — 보통은 i2i 로 보낸 원본 (sendToI2i).
  ///  📌 로 다른 그림(지금 그림 · 릴의 결과)을 기준으로 고정할 수 있다 (setI2iCompareBase).
  ///  메모리에만 둔다 — 앱을 다시 켜면 i2i 그림도 비어 있으니 같이 비어 있다.
  Uint8List? i2iCompareBase;

  /// 기준을 사용자가 직접 고정했는지 (아니면 보낸 원본) — 비교 보기의 이름표에 쓴다
  bool i2iCompareBasePinned = false;

  List<String> danbooruTags = [];
  // e621 확장: Danbooru에 없는 태그만 (토글 ON 시 검색에 합류)
  List<String> e621Tags = [];
  Set<String> e621TagSet = {}; // 색상 구분용 (e621 전용 태그 빠른 판별)
  List<String> _combinedTags = []; // Danbooru+e621 count순 미리 정렬 (검색용)
  bool e621Enabled = false; // e621 프롬프트 확장 토글

  // ── 영속되는 UI 상태 (펼침/접힘 등) ── 앞으로 이런 상태는 여기에 모아 기억 + 백업 포함
  bool safCardOpen = true; // 설정탭 '저장 폴더(SAF)' 카드 펼침 여부
  bool fileCardOpen = true; // 설정탭 '파일 이름' 카드 펼침 여부

  // 앱 테마 액센트 색 (ARGB int, 기본: deepPurpleAccent). AppColors.accent에 반영됨.
  int themeAccent = 0xFF7C4DFF;

  // 자동완성 검색용 태그 리스트 (e621 토글에 따라 합류)
  List<String> get searchTags {
    if (!e621Enabled || _combinedTags.isEmpty) {
      return danbooruTags;
    }
    return _combinedTags;
  }

  // 해당 태그가 e621 전용 태그인지 (색상 구분용). contains 마커 '* ' 제거 후 판별.
  bool isE621Tag(String rawTag) {
    if (!e621Enabled) {
      return false;
    }
    final clean = rawTag.replaceFirst(RegExp(r'^\* '), '');
    return e621TagSet.contains(clean);
  }

  double historyThumbnailScrollOffset = 0.0;
  bool scrollToThumbnailEnd = false;

  // 히스토리 목록을 맨 아래로 내려달라는 요청 신호.
  //  ⚠️ 예전에는 main이 ScrollController를 만들어 HistoryTab에 넘겼는데,
  //     KeepAlive를 켜면 탭 전환 중 두 인스턴스가 같은 컨트롤러를 붙잡아
  //     'attached to multiple scroll views' 오류로 앱이 멈췄다.
  //     컨트롤러는 HistoryTab이 직접 갖고, 요청만 이 값으로 전달한다.
  int historyScrollToEndRevision = 0;

  /// 라이브러리 탭 안에서 마지막으로 본 쪽 (0 와일드카드 / 1 프롬프트 사전 / 2 조건부 트리거 — app_tabs.dart 의 kLibrary…Page).
  ///  라이브러리 탭은 떠날 때마다 새로 만들어지므로 여기에 기억해 둔다 — 다른 탭에 갔다 오면 보던 쪽 그대로.
  ///  앱을 켤 때는 늘 와일드카드부터 — 저장하지 않는다 (3.15.0 요청).
  ///  ⚠️ 예전엔 설정에 저장해서, 사전을 보다 앱을 끄면 다음에 켤 때도 사전부터 열렸다.
  ///     옛 버전이 남긴 'wildcardSubTab' 값은 읽지 않는다 (남아 있어도 아무 일도 없다).
  int wildcardSubTab = kLibraryWildcardPage;

  void setWildcardSubTab(int index) {
    // 화면을 다시 그릴 필요가 없어 notifyListeners 는 부르지 않는다
    wildcardSubTab = index;
  }

  /// 히스토리 탭을 '떠날 때마다' 1씩 오른다.
  ///  히스토리 탭은 이 값이 바뀐 것을 보고 갤러리 모드를 닫아 둔다.
  ///  (갤러리는 가끔 들여다보는 곳이라, 다시 들어오면 목록부터 보이는 게 자연스럽다)
  ///  단, '히스토리 탭 마지막 보기 유지'(historyKeepLastView)가 켜져 있으면 닫지 않고,
  ///  다른 저장 폴더를 보던 중이면 지금 저장 중인 폴더로만 돌려 둔다.
  ///
  ///  ⚠️ '들어올 때' 닫으면 탭이 보이고 나서 0.5초 뒤에 화면이 휙 바뀐다.
  ///     떠날 때 닫아 두면 화면 밖에서 조용히 바뀌어 있어 다시 들어와도 티가 안 난다.
  int historyGalleryResetRevision = 0;

  void resetHistoryGalleryInBackground() {
    historyGalleryResetRevision++;
    notifyListeners();
  }

  void requestHistoryScrollToEnd() {
    historyScrollToEndRevision++;
    notifyListeners();
  }

  bool isHistoryGridView = false;

  /// 다른 화면이 보내 달라고 한 탭 (main.dart 가 옮긴 뒤 비운다)
  AppTab? requestedTab;

  /// 설정 탭 안에서 펼쳐 보여 줄 하위 탭 (0 일반 / 1 저장 / 2 API / 3 기타).
  ///  설정 화면이 이 값을 보고 그 탭으로 옮긴 뒤 스스로 비운다.
  int? requestedSettingsSubTab;

  /// 설정 탭의 [subTab] 을 펼친 채로 설정 화면을 연다.
  void navigateToSettings(int subTab) {
    requestedSettingsSubTab = subTab;
    navigateToTab(AppTab.settings);
  }

  void consumeSettingsSubTabRequest() {
    requestedSettingsSubTab = null;
  }

  /// 라이브러리 탭 안에서 펼쳐 보여 줄 쪽 (kLibrary…Page). 설정의 [requestedSettingsSubTab] 과 같은 방식 —
  ///  라이브러리 화면이 이 값을 보고 그 쪽으로 옮긴 뒤 스스로 비운다.
  ///  (프롬프트탭의 조건부 트리거 칸을 누르면 '조건부 트리거' 쪽으로 — trigger_library.dart 의 openTriggerLibrary)
  int? requestedLibrarySubTab;

  /// 라이브러리 탭의 [subTab] 쪽을 펼친 채로 라이브러리 탭을 연다.
  void navigateToLibrary(int subTab) {
    requestedLibrarySubTab = subTab;
    navigateToTab(AppTab.library);
  }

  void consumeLibrarySubTabRequest() {
    requestedLibrarySubTab = null;
  }

  void navigateToTab(AppTab tab) {
    requestedTab = tab;
    notifyListeners();
  }

  void clearNavigation() {
    requestedTab = null;
  }

  /// 탭이 보이는지 — 프롬프트·설정은 늘 보이고, 나머지는 설정에서 켜고 끈다.
  bool isTabShown(AppTab tab) => switch (tab) {
    AppTab.prompt || AppTab.settings => true,
    AppTab.history => historyTabEnabled,
    AppTab.i2i => i2iTabEnabled,
    AppTab.character => characterTabEnabled,
    AppTab.library => wildcardTabEnabled,
  };

  // 앱 초기 로딩 완료 여부 (false 동안 로딩 화면으로 조작 차단 → 프리징/크래시 방지)
  bool isAppReady = false;
  // 로딩창에 표시할 현재 단계 (1줄)
  String loadingStatusMessage = "준비 중...";
  void _setLoadingStatus(String msg) {
    loadingStatusMessage = msg;
    notifyListeners();
  }

  void markAppReady() {
    if (isAppReady) {
      return;
    }
    isAppReady = true;
    notifyListeners();
  }

  // ── 처음 불러오기가 끝났는지 ──
  //  ⚠️ 불러오기가 끝나기 전에 저장하면, 아직 비어 있는 값(프롬프트·캐릭터·와일드카드·
  //     프리셋·사전 …)이 저장돼 있던 내용을 덮어써 통째로 사라진다.
  //     로딩 화면에서 홈 버튼·뒤로 가기로 앱을 내리면 그렇게 됐다 —
  //     앱이 내려갈 때 하는 '마지막 저장'(main.dart 의 didChangeAppLifecycleState)이
  //     불러오기보다 먼저 돌아, 빈 입력창을 저장해 버린다.
  //     사전은 더 나빴다: 빈 목록이 저장된 뒤 그걸 읽고, '주인 없는 큰 이미지'로 보고 전부 지웠다.
  //  그래서 끝나기 전에는 저장 함수(saveAllSettings · savePromptDict · savePresetsToFile)가
  //  아무것도 쓰지 않는다. 끝나는 건 성공·실패와 상관없다 (loadInitialData 의 finally).
  bool _initialLoadFinished = false;

  // 설정(SharedPreferences)을 실제로 다 읽었는지 — 앱 안의 사본에서 되살렸거나, 가져오기로 통째로 채운 것도 포함.
  //  ⚠️ _initialLoadFinished 는 '끝났다'일 뿐 '읽었다'가 아니다. 설정을 읽기 전에 오류가 나서
  //     불러오기가 끝나 버리면(이름 필터 사전·저장소 열기 실패 등), 화면은 초기값인데 저장이 풀려
  //     다음 저장이 프롬프트·캐릭터·계정·설정 사본(settings_backup.json)까지 초기값으로 덮었다.
  //     → 읽지 못했으면 이번 실행에서는 설정을 저장하지 않고, 화면에 알린다.
  bool _settingsRead = false;

  // 사전·프리셋을 파일에서 읽었는지.
  //  불러오기가 중간에 끊기면(오류·백업 복구) 둘은 아직 빈 목록이다.
  //  그대로 저장이 풀리면 파일을 빈 목록으로 덮으므로, 끝날 때 따로 읽어 둔다.
  bool _promptDictLoaded = false;
  bool _presetsLoaded = false;

  // 설정을 앱 안의 사본(settings_backup.json)에서 되살렸으면, 불러오기가 끝난 뒤
  //  한 번 저장해 SharedPreferences·파일에 반영한다 (불러오는 동안에는 저장이 막혀 있으므로).
  bool _saveAfterLoad = false;

  Future<void> loadInitialData() async {
    try {
      await _loadInitialDataInner();
    } finally {
      // 불러오기가 도중에 끊겼거나(오류) 일찍 끝났으면(백업 복구) 사전·프리셋을 여기서 읽는다.
      //  (둘 다 안에서 오류를 잡는다 — 여기서 또 멈추면 저장이 영영 막힌다)
      if (!_promptDictLoaded) {
        await _loadPromptDict();
      }
      if (!_presetsLoaded) {
        try {
          await _loadPresets(await SharedPreferences.getInstance());
        } catch (_) {
          // 프리셋을 못 읽어도 앱은 켜져야 한다
        }
      }
      // i2i 즐겨찾기도 같은 이유로 (안에서 오류를 잡는다). 릴 되살리기보다 먼저 —
      //  되살릴 때 즐겨찾기와 겹치는 결과를 빼야 한다.
      if (!_i2iFavoritesLoaded) {
        await loadI2iFavorites();
      }
      // 프롬프트 검색 목록도 (설정을 백업 사본에서 되살린 경우 등 — 목록은 설정이 아니라 파일에 있다)
      if (!_gelbooruPromptsLoaded) {
        try {
          await _loadGelbooruPrompts(await SharedPreferences.getInstance());
          _syncPromptCounters();
        } catch (_) {
          // 목록을 못 읽어도 앱은 켜져야 한다
        }
      }
      // 예전 버전이 설정에 남긴 태그 분류 캐시(~1MB)를 파일로 옮긴다 — 기다리지 않는다.
      //  (검색을 안 하면 옮길 기회가 없어, 설정이 바뀔 때마다 그 1MB 를 같이 다시 썼다)
      unawaited(NovelAiService.migrateLegacyTagCache());
      _initialLoadFinished = true;
      if (!_settingsRead) {
        debugPrint('설정을 읽지 못함 — 이번 실행에서는 설정을 저장하지 않습니다');
        lastErrorMessage = "설정을 읽다가 문제가 생겼어요.\n저장된 설정을 지키려고 이번 실행에서는 설정을 저장하지 않아요.\n앱을 다시 켜 주세요.";
      }
      // 지난 실행의 i2i 결과 릴 되살리기 — 기다리지 않는다 (로딩 화면을 늘리지 않게)
      unawaited(_restoreI2iReel());
      // 캐시 정리 (잠깐 파일 · 섬네일 상한) — 조금 뒤에, 기다리지 않는다
      unawaited(_tidyCacheSoon());
      if (_saveAfterLoad) {
        _saveAfterLoad = false;
        unawaited(saveAllSettings()); // 프리셋 파일도 이 안에서 함께 저장된다
        unawaited(savePromptDict());
        unawaited(saveI2iFavorites());
      }
    }
  }

  Future<void> _loadInitialDataInner() async {
    // pubspec.yaml의 version을 자동으로 읽어옴
    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
      // 업데이트가 끝나면(= 새 버전으로 켜지면) 받아 둔 설치 파일은 필요 없다.
      //  설치가 취소됐을 때 다시 쓰려고 남겨 두는 것이므로, 설치가 됐으면 지운다.
      unawaited(_cleanupOldApks());
    } catch (_) {
      // 버전을 못 읽으면 초기값("0.0.0")이 남는다.
      // 업데이트 확인이 항상 '새 버전 있음'으로 보일 뿐, 앱 동작에는 지장이 없다.
    }

    // 권한: 파일 접근은 앱 전용 디렉토리 사용 (권한 불필요)
    // 커스텀 경로 저장 시 실패하면 앱 전용 폴더로 자동 대체
    _setLoadingStatus("자동완성 태그 불러오는 중...");
    await _loadTagsFromJson();

    // 이름 필터 사전(에셋)을 로딩창 단계에서 미리 로드
    // → 첫 검색 때 느려지는 대신 앱 시작 시 한 번에 처리.
    // 백업 복구 경로가 아래에서 조기 return할 수 있으므로 반드시 그보다 먼저 수행.
    _setLoadingStatus("이름 필터 사전 불러오는 중...");
    await TagFilters.ensureNamesLoaded();

    _setLoadingStatus("설정 불러오는 중...");
    final prefs = await SharedPreferences.getInstance();

    // SharedPreferences가 비어있으면 백업에서 복구 시도
    final hasSettings = prefs.getString('api_token') != null || prefs.getString('positive') != null;
    if (!hasSettings) {
      final recovered = await tryRecoverFromBackup();
      if (recovered) {
        debugPrint("백업에서 설정 복구 완료");
        // 복구 성공해도 히스토리/레퍼런스는 별도 저장소에서 로드해야 함
        _setLoadingStatus("히스토리 불러오는 중...");
        await _loadHistoryFromLocal();
        await loadReferencesFromLocal();
        _settingsRead = true; // 사본에서 통째로 되살렸다
        // 불러오는 동안엔 저장이 막혀 있어 되살린 값이 아직 어디에도 안 쓰였다 → 끝나면 한 번 저장.
        //  사전·프리셋은 loadInitialData 의 finally 가 각자의 파일에서 다시 읽는다
        //  (파일이 이 사본보다 최신이다. 파일이 없으면 사본에서 되살린 것을 그대로 쓴다)
        _saveAfterLoad = true;
        notifyListeners();
        return;
      }
    }

    apiToken = prefs.getString('api_token') ?? "";
    // 계정 목록 복원 (없으면 기존 단일 토큰을 옮긴다)
    final accRaw = prefs.getString('naiAccounts');
    if (accRaw != null && accRaw.isNotEmpty) {
      try {
        final list = jsonDecode(accRaw) as List;
        naiAccounts = list
            .map((e) => NaiAccount.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        // 저장된 값이 깨졌거나 형식이 바뀐 경우. 기본값으로 시작한다.
        // (여기서 멈추면 나머지 설정까지 못 읽어 앱이 초기 상태로 보인다)
      }
    }
    activeAccountIndex = prefs.getInt('activeAccountIndex') ?? 0;
    _migrateSingleToken();
    // 선택된 계정의 토큰을 실제 사용 토큰으로 맞춘다
    if (activeAccountIndex >= naiAccounts.length) {
      activeAccountIndex = 0;
    }
    if (naiAccounts.isNotEmpty) {
      apiToken = naiAccounts[activeAccountIndex].token;
    }
    apiTokenController.text = apiToken;
    // 토큰이 있으면 실제 서버에 검증 (Anlas 조회)
    if (apiToken.isNotEmpty) {
      try {
        _setLoadingStatus("API 연결 확인 중...");
        // 잔액·V5 한도는 한 번의 조회로 함께 온다 (fetchAnlas)
        await fetchAnlas();
        isApiConnected = currentAnlas >= 0;
      } catch (_) {
        isApiConnected = false;
      }
    } else {
      isApiConnected = false;
    }
    // 설정 값들 — _settings 목록을 돌며 읽는다 (가져오기와 같은 함수 · 보정도 그 안에서)
    _applySettings(prefs.get, fromBackup: false);
    // 지운 설정 — 휴대폰에 남은 값을 치운다
    //  (3.9.0: 예전 i2i·프롬프트탭 배치, 쓰지 않던 Gelbooru 키 스위치 / 3.11.0: 검색 정렬 다양화 /
    //   3.14.0: 가중치 규칙 · 조건부 트리거 가이드 접기)
    for (final k in const [
      'i2iAltLayout',
      'promptAltLayout',
      'promptNewLayout',
      'useGelbooruApiKey',
      'diversifySearchSort',
      'weightRules',
      'weightRulesEnabled',
      'conditionalGuideCollapsed',
    ]) {
      if (prefs.containsKey(k)) {
        unawaited(prefs.remove(k));
      }
    }
    // 프롬프트 되돌리기 기록 (입력창 이름 → 최근 내용 목록) — JSON 글자로 저장
    final undoRaw = prefs.getString('promptUndoHistory');
    if (undoRaw != null) {
      try {
        promptUndoHistory = (jsonDecode(undoRaw) as Map).map(
          (k, v) => MapEntry(k as String, List<String>.from(v as List)),
        );
      } catch (_) {
        // 형식이 깨졌으면 버린다. 되돌리기 기록은 없어도 앱 동작에 지장이 없다.
      }
      _dropObsoleteUndo();
    }
    // 모델별 기억값 — JSON 글자로 저장
    final profRaw = prefs.getString('modelSettingProfiles');
    if (profRaw != null && profRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(profRaw) as Map<String, dynamic>;
        modelSettingProfiles = decoded.map(
          (k, v) => MapEntry(k, Map<String, String>.from(v as Map)),
        );
      } catch (_) {
        // 저장된 값이 깨졌거나 형식이 바뀐 경우. 기본값으로 시작한다.
        // (여기서 멈추면 나머지 설정까지 못 읽어 앱이 초기 상태로 보인다)
      }
    }
    // 새로 설치했으면(저장된 모델이 없으면) 기본 모델의 권장값으로 시작한다.
    //  ⚠️ 권장값(V5: 스텝 23 · Guidance 7)은 원래 '그 모델로 처음 전환할 때' 들어가는데,
    //     처음부터 기본 모델(V5)이면 전환이 없어 공통 기본값(스텝 28 · Guidance 6)으로 시작해 버린다.
    if (prefs.getString('model') == null) {
      final defaults = _modelDefaults[selectedModel];
      if (defaults != null) {
        _applyDetailSnapshot(defaults);
      }
    }

    // ⚠️ 저장된 값이 깨져 있어도 여기서 멈추면 안 된다.
    //    멈추면 아래(와일드카드·프리셋·사전·히스토리 …)를 하나도 못 읽은 채 앱이 켜지고,
    //    다음 저장이 그 빈 값으로 전부 덮어쓴다. 깨진 목록 하나만 기본값으로 시작한다.
    String? charJson = prefs.getString('characters');
    if (charJson != null) {
      try {
        List<dynamic> decoded = jsonDecode(charJson);
        characters = decoded.map((e) => NaiCharacter.fromJson(e)).toList();
      } catch (e) {
        debugPrint("캐릭터 목록 읽기 실패(기본값으로 시작): $e");
      }
    }
    if (characters.isEmpty) {
      characters.add(NaiCharacter());
    }
    String? wildcardJson = prefs.getString('wildcards');
    if (wildcardJson != null) {
      try {
        List<dynamic> decoded = jsonDecode(wildcardJson);
        wildcards = decoded.map((e) => NaiWildcard.fromJson(e)).toList();
      } catch (e) {
        debugPrint("와일드카드 목록 읽기 실패(기본값으로 시작): $e");
      }
    }
    // (처음 설치했을 땐 저장된 목록이 없어 선언부의 '의상' 예시가 그대로 쓰인다)
    ensureWildcards(); // 저장된 목록이 비어 있었으면 빈 것 하나

    // 프리셋: 파일 우선. 없으면 예전 방식(prefs)에서 읽어 파일로 옮긴다.
    await _loadPresets(prefs);
    await _loadPromptDict();

    // 검색 목록: 파일에서 (예전 버전이 설정에 둔 목록이 있으면 파일로 옮긴다)
    await _loadGelbooruPrompts(prefs);
    _syncPromptCounters(); // 순번(위 _applySettings 에서 읽음)이 목록 밖이면 여기서 0 으로 맞춘다

    _settingsRead = true; // 여기까지 왔으면 설정을 다 읽었다 (위에서 오류가 나면 여기 오지 않는다)

    // 설정을 다 읽은 뒤 잔액을 한 번 더 확인한다 — 위에서 실패했으면(네트워크) 여기서 다시 연결된다.
    //  기다리지 않는다: 로딩 화면이 네트워크 왕복만큼 길어질 이유가 없다
    //  (로딩이 길수록 '로딩 중 앱을 내리는' 사고가 날 틈도 넓어진다).
    //  ⚠️ 예전엔 여기서 같은 조회를 두 번(fetchAnlas + fetchV5Limit) 기다렸다 — 위까지 합쳐 최대 4번.
    refreshBalanceInBackground();
    _setLoadingStatus("히스토리 불러오는 중...");
    await _loadHistoryFromLocal();
    await loadReferencesFromLocal();
    await loadI2iFavorites();
    await _loadSafRoot();
    // 휴지통에서 기한이 지난 그림 지우기 — 기다리지 않는다 (앱 시작을 늦추지 않게)
    unawaited(purgeAllSafTrash());
    notifyListeners();

    // 지난번에 앱이 생성 도중 꺼져 남은 진행 알림을 치운다 (알림을 켠 사람만 — 끈 사람은 알림을 준비하지도 않는다)
    if (generationNotify) {
      unawaited(GenerationNotifier.instance.clearStaleProgress());
    }

    // 업데이트 체크 (조건부, 앱 시작을 블로킹하지 않음)
    if (autoCheckUpdate) {
      checkForUpdate();
    }
  }

  Future<void> _loadTagsFromJson() async {
    Map<String, int> danbooruCounts = {};
    try {
      final String jsonString = await rootBundle.loadString('assets/tags.json');
      final List<dynamic> jsonData = jsonDecode(jsonString);

      jsonData.sort((a, b) => (b['post_count'] ?? 0).compareTo(a['post_count'] ?? 0));
      danbooruTags = jsonData.map((e) => e['tag_name'].toString()).toList();
      for (final e in jsonData) {
        danbooruCounts[e['tag_name'].toString()] = (e['post_count'] ?? 0) as int;
      }
      debugPrint("✅ Danbooru 태그 로딩 완료! 총 ${danbooruTags.length}개");
    } catch (e) {
      debugPrint("❌ Danbooru 태그 파일 읽기 실패: $e");
    }

    // e621 태그 로딩 (Danbooru에 없는 것만 = 세밀한 전용 태그)
    try {
      final danbooruSet = danbooruTags.toSet();
      final String e621String = await rootBundle.loadString('assets/e621_tags.json');
      final List<dynamic> e621Data = jsonDecode(e621String);

      // Danbooru에 이미 있는 태그는 제외 (Danbooru 우선)
      final filtered = e621Data
          .where((e) => !danbooruSet.contains(e['tag_name'].toString()))
          .toList();
      filtered.sort((a, b) => (b['post_count'] ?? 0).compareTo(a['post_count'] ?? 0));

      e621Tags = filtered.map((e) => e['tag_name'].toString()).toList();
      e621TagSet = e621Tags.toSet();

      // 검색용 통합 리스트: Danbooru + e621 전체를 count순으로 미리 정렬
      final Map<String, int> e621Counts = {};
      for (final e in filtered) {
        e621Counts[e['tag_name'].toString()] = (e['post_count'] ?? 0) as int;
      }
      _combinedTags = [...danbooruTags, ...e621Tags];
      _combinedTags.sort((a, b) {
        final ca = danbooruCounts[a] ?? e621Counts[a] ?? 0;
        final cb = danbooruCounts[b] ?? e621Counts[b] ?? 0;
        return cb.compareTo(ca);
      });

      debugPrint("✅ e621 전용 태그 로딩 완료! 총 ${e621Tags.length}개 (중복 제거됨)");
    } catch (e) {
      debugPrint("❌ e621 태그 파일 읽기 실패: $e");
    }
  }

  // ============================================================================
  // 설정 내보내기/가져오기
  // ============================================================================
  /// [favoritesOnly] 면 히스토리 중 즐겨찾기한 것만 담는다.
  ///  (지금은 쓰는 곳이 없다 — 업데이트 전 자동 백업도 3.10.0 부터 전체를 담는다)
  ///
  /// [includeDictImages] 면 사전의 '크게 볼 이미지'(장당 40~65KB)도 담는다.
  ///  내보내기·업데이트 전 자동 백업은 담고, 앱 안의 설정 사본(settings_backup.json)은 뺀다
  ///  — 설정을 바꿀 때마다 새로 쓰는 파일이라 가벼워야 하고, 원본이 같은 폴더에 있어 담을 이유도 없다.
  Future<Map<String, dynamic>> exportSettings({
    bool includeHistory = true,
    bool favoritesOnly = false,
    bool includeDictImages = true,
    bool includeFileBacked = true,
  }) async {
    // 히스토리 썸네일 생성 → 백그라운드 isolate로 처리
    List<Map<String, dynamic>> historyExport = [];
    if (includeHistory && history.isNotEmpty) {
      // 칸을 먼저 골라 잡아 둔다 — 아래에서 원본을 줄이며 기다리는 사이 생성이 끝나 상한 정리가 일어나면
      //  번호가 하나씩 밀린다. 번호로 다시 읽으면 그림과 정보 · 즐겨찾기가 이웃 칸 것과 섞여 백업됐다 (DEVNOTES 5).
      final List<HistoryEntry> entries = [
        for (final e in history)
          if (!favoritesOnly || e.favorite) e,
      ];
      if (entries.isNotEmpty) {
        // 큰 원본(최근 이미지)은 히스토리 썸네일과 같은 규칙으로 먼저 줄인다.
        //  isolate 안에서는 네이티브 인코더를 못 쓰므로 여기서 처리하고,
        //  isolate 는 이미 작은 것을 그대로 담기만 한다. (실패한 것만 isolate 가 옛 방식으로 줄인다)
        final images = [for (final e in entries) e.image];
        for (int k = 0; k < images.length; k++) {
          if (images[k].length >= kThumbBytesLimit) {
            images[k] = await makeHistoryThumb(images[k]) ?? images[k];
          }
        }
        historyExport = await compute(_exportHistoryIsolate, {
          'images': images,
          'metadata': [for (final e in entries) e.metadata?.toJson()],
          'favorites': [for (final e in entries) e.favorite],
          'filePaths': [for (final e in entries) e.filePath],
        });
      }
    }

    final dictImages = includeDictImages ? await _exportDictImages() : null;

    return {
      'version': currentVersion,
      'api_token': apiToken,
      'naiAccounts': naiAccounts.map((e) => e.toJson()).toList(),
      'activeAccountIndex': activeAccountIndex,
      // 설정 값들 (_settings 중 백업에 넣는 것)
      for (final s in _settings)
        if (s.backup) s.key: s.value,
      'modelSettingProfiles': modelSettingProfiles,
      'promptUndoHistory': promptUndoHistory,
      'characters': characters.map((c) => c.toJson()).toList(),
      'wildcards': wildcards.map((w) => w.toJson()).toList(),
      // 사전은 파일로 따로 저장하지만 백업에는 함께 담는다 (잃으면 복구 불가)
      if (includeFileBacked) 'promptDict': promptDict.map((e) => e.toJson()).toList(),
      if (includeFileBacked)
        'promptDictCategories': promptDictCategories.map((c) => c.toJson()).toList(),
      // 크게 볼 이미지 (항목 id → WebP base64). 없으면 되살려도 흐린 썸네일만 남는다.
      'promptDictImages': ?dictImages, // null 이면 이 칸 자체가 빠진다 (includeDictImages: false)
      // i2i 즐겨찾기 — 사용자가 모아둔 결과물이라 기기를 옮겨도 남아야 한다
      if (includeFileBacked)
        'i2iFavorites': i2iResults.where((r) => r.favorite).map((r) => r.toJson()).toList(),
      if (includeFileBacked) 'presets': presets.map((p) => p.toJson()).toList(),
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
      if (images[i].length < kThumbBytesLimit) {
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
      if (data['naiAccounts'] != null) {
        try {
          final List<NaiAccount> accs = (data['naiAccounts'] as List)
              .map((e) => NaiAccount.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          // 고른 계정: 백업의 번호가 맞고 그 계정 토큰이 백업 토큰과 같으면 그대로 (보통은 여기),
          //  아니면 같은 토큰을 가진 계정 → 그것도 없으면 범위 안의 번호 → 첫 계정.
          //  ⚠️ 예전엔 번호를 확인하지 않아, 깨진 백업이면 고른 계정과 실제로 쓰는 토큰이 어긋날 수 있었다.
          final Object? saved = data['activeAccountIndex'];
          final int savedIdx = saved is int && saved >= 0 && saved < accs.length ? saved : -1;
          int idx;
          if (savedIdx >= 0 && accs[savedIdx].token == apiToken) {
            idx = savedIdx;
          } else {
            final int byToken = accs.indexWhere((a) => a.token == apiToken);
            idx = byToken >= 0 ? byToken : (savedIdx >= 0 ? savedIdx : 0);
          }
          naiAccounts = accs;
          activeAccountIndex = idx;
          if (accs.isNotEmpty) {
            apiToken = accs[idx].token; // 켤 때와 같게 — 고른 계정의 토큰을 실제 사용 토큰으로
          }
        } catch (_) {
          // 계정 목록이 깨져 있으면 통째로 건너뛴다.
          // 백업 파일이 옛 버전이거나 손상된 경우인데, 여기서 멈추면
          // 나머지 설정까지 복원되지 않는다. 계정은 다시 등록하면 된다.
        }
      }
      _migrateSingleToken();
      apiTokenController.text = apiToken;
      // 토큰만 복원, 연결 상태는 다음 기동 시 검증
      isApiConnected = false;
    }

    // 설정 값들 — 불러오기와 같은 목록 · 같은 함수 (백업에 그 칸이 없으면 지금 값 유지, 보정도 그 안에서)
    _applySettings((k) => data[k], fromBackup: true);
    if (data['modelSettingProfiles'] != null) {
      try {
        modelSettingProfiles = (data['modelSettingProfiles'] as Map).map(
          (k, v) => MapEntry(k as String, Map<String, String>.from(v as Map)),
        );
      } catch (_) {
        // 모델별 기억값은 편의 기능이라 형식이 안 맞으면 버린다.
        // 비워 두면 다음에 모델을 바꿀 때 현재 값으로 다시 채워진다.
      }
    }
    if (data['promptDict'] != null) {
      try {
        promptDict = (data['promptDict'] as List).map((e) => PromptDictEntry.fromJson(e)).toList();
        promptDictCategories = ((data['promptDictCategories'] as List?) ?? const [])
            .map((e) => PromptDictCategory.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _dropDanglingCategoryRefs();
        _dictThumbCache.clear(); // 항목이 통째로 바뀌었으니 옛 미리보기 풀이는 버린다
        unawaited(savePromptDict()); // 복원분을 파일에도 반영
        // 백업에 담긴 큰 이미지를 되살리고, 복원으로 사라진 항목의 큰 이미지는 치운다
        //  (옛 백업엔 큰 이미지가 없다 — 그땐 치우기만. 기기에 남아 있던 같은 id 의 그림은 그대로 쓰인다)
        unawaited(_restoreDictImages(data['promptDictImages']));
      } catch (_) {
        // 옛 백업이거나 형식이 다르면 사전만 건너뛴다
      }
    }
    if (data['promptUndoHistory'] != null) {
      try {
        promptUndoHistory = (data['promptUndoHistory'] as Map).map(
          (k, v) => MapEntry(k as String, List<String>.from(v as List)),
        );
      } catch (_) {
        // 백업이 옛 형식이면 되돌리기 기록만 건너뛴다
      }
      _dropObsoleteUndo();
    }
    // i2i 즐겨찾기 복원 (형식이 달라도 앱이 멈추지 않게 감싼다)
    if (data['i2iFavorites'] != null) {
      try {
        final list = data['i2iFavorites'] as List;
        i2iResults = list
            .map((e) => I2iResult.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        // 릴이 백업의 즐겨찾기로 통째로 바뀌었다 → 두 보관함 모두 맞춘다 (즐겨찾기를 먼저 쓴다)
        unawaited(saveI2iFavorites().then((_) => _saveReelSoon()));
      } catch (e) {
        debugPrint('i2i 즐겨찾기 복원 실패: $e');
      }
    }
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
    if (data['characters'] != null) {
      characters = (data['characters'] as List).map((e) => NaiCharacter.fromJson(e)).toList();
      if (characters.isEmpty) {
        characters.add(NaiCharacter());
      }
    }
    if (data['wildcards'] != null) {
      wildcards = (data['wildcards'] as List).map((e) => NaiWildcard.fromJson(e)).toList();
    }
    ensureWildcards(); // 빈 목록이 복원돼도 화면이 비지 않게
    if (data['presets'] != null) {
      presets = (data['presets'] as List).map((e) => NaiPreset.fromJson(e)).toList();
      unawaited(savePresetsToFile()); // 백업 복원분도 파일에 반영
    }

    // 히스토리 복원 (썸네일 base64 → Uint8List)
    if (data['history'] != null) {
      final historyData = data['history'] as List;
      // 백업으로 히스토리를 통째로 바꾸는 것이므로 막아 둔 저장을 다시 푼다
      _historyLoadFailed = false;
      history.clear();

      for (final item in historyData) {
        try {
          final imageBase64 = item['image'] as String?;
          if (imageBase64 != null) {
            history.add(
              HistoryEntry(
                image: base64Decode(imageBase64),
                metadata: item['metadata'] != null ? NaiMetadata.fromJson(item['metadata']) : null,
                favorite: item['favorite'] ?? false,
                filePath: item['filePath'] as String?,
              ),
            );
          }
        } catch (_) {
          // 손상된 항목 건너뛰기 (한 칸이 통째로 빠지므로 다른 칸과 어긋나지 않는다)
        }
      }

      if (historyImages.isNotEmpty) {
        selectedHistoryIndex = historyImages.length - 1;
      }
      _fullSaveHistoryToLocal();
    }

    _settingsRead = true; // 가져오기로 통째로 채웠다 — 이제 저장해도 된다
    saveAllSettings();
    notifyListeners();

    // 복원한 토큰으로 곧바로 연결을 확인한다.
    //  이게 없으면 토큰은 들어왔는데 isApiConnected가 false로 남아
    //  "연결되지 않음"이 뜨고, 사용자가 앱을 다시 켜야 정상으로 보였다.
    if (apiToken.trim().isNotEmpty) {
      unawaited(
        fetchAnlas().then((_) {
          // 계정 목록도 함께 되살아났으므로 각 계정 상태를 갱신
          unawaited(refreshAllAccountQuotas(force: true));
        }),
      );
    }
  }

  // ============================================================================
  // 설정 목록 — 설정 하나 = 한 줄 (models/setting_field.dart)
  // ============================================================================
  //  불러오기(_loadInitialDataInner) · 저장(saveAllSettings) · 내보내기(exportSettings) ·
  //  가져오기(importSettings) 가 모두 이 목록을 돈다. 새 설정은 필드를 선언하고 여기 한 줄만 더한다.
  //   · 키 = 저장 키 = 백업 키. 바꾸면 기존 사용자의 저장값을 못 읽는다 (옛 이름은 _applySettings 에서 이어받기).
  //   · def 가 기본값의 '원본' — 필드 선언의 초기값은 불러오기 전 잠깐만 쓰인다 (같게 둔다).
  //   · backup: false = 이 기기에서만 의미 있는 값 (내보내기 · 가져오기에서 뺀다).
  //  ⚠️ 여기 없는 것 (형이 복잡하거나 따로 다루는 것):
  //     api_token · naiAccounts · activeAccountIndex (계정 이관·연결 확인),
  //     promptUndoHistory · modelSettingProfiles · characters · wildcards (JSON 묶음),
  //     사전 · 프리셋 · i2i 즐겨찾기 · 검색 목록 · 히스토리 (각자의 파일)
  late final List<SettingField<Object?>> _settings = _buildSettings();

  /// 입력창 글자 한 칸
  SettingField<String> _text(String key, TextEditingController c, [String def = ""]) =>
      SettingField<String>(key, get: () => c.text, set: (v) => c.text = v, def: def);

  // 아래 넷은 형만 다른 줄임말 — (키, 읽기, 쓰기, 기본값) 순서로 적는다
  SettingField<bool> _bool(
    String key,
    bool Function() get,
    void Function(bool) set,
    bool def, {
    bool backup = true,
  }) => SettingField<bool>(key, get: get, set: set, def: def, backup: backup);

  SettingField<int> _int(
    String key,
    int Function() get,
    void Function(int) set,
    int def, {
    int Function(int)? fix,
    bool backup = true,
  }) => SettingField<int>(key, get: get, set: set, def: def, fix: fix, backup: backup);

  SettingField<double> _double(
    String key,
    double Function() get,
    void Function(double) set,
    double def, {
    double Function(double)? fix,
  }) => SettingField<double>(key, get: get, set: set, def: def, fix: fix);

  SettingField<String> _string(
    String key,
    String Function() get,
    void Function(String) set,
    String def, {
    String Function(String)? fix,
  }) => SettingField<String>(key, get: get, set: set, def: def, fix: fix);

  /// 글자 묶음(Set) — 저장소에는 목록으로 둔다 (기본값은 빈 묶음)
  SettingField<List<String>> _strSet(
    String key,
    Set<String> Function() get,
    void Function(Set<String>) set, {
    List<String> Function(List<String>)? fix,
  }) => SettingField<List<String>>(
    key,
    get: () => get().toList(),
    set: (v) => set(v.toSet()),
    def: const [],
    fix: fix,
  );

  List<SettingField<Object?>> _buildSettings() {
    final list = <SettingField<Object?>>[
      // ── 프롬프트 입력창 ──
      _text('positive', positiveController),
      _text('negative', negativeController),
      _text('prefix', prefixController),
      _text('suffix', suffixController),
      _text('inpaint_pos', inpaintPositiveController),
      _text('inpaint_neg', inpaintNegativeController),
      _text('inpaint_prefix', inpaintPrefixController),
      _text('inpaint_suffix', inpaintSuffixController),
      _text('conditional_rules', conditionalRuleController),
      _string('conditionalTriggerMode', () => conditionalTriggerMode, (v) => conditionalTriggerMode = v, "random"),
      _text('custom_remove', customRemoveController),
      _bool('expandNestedWeights', () => expandNestedWeightsEnabled, (v) => expandNestedWeightsEnabled = v, false),
      _bool('weightHighlight', () => weightHighlight, (v) => weightHighlight = v, true),
      _bool('e621Enabled', () => e621Enabled, (v) => e621Enabled = v, false),
      _string('qualityTagsPreset', () => qualityTagsPreset, (v) => qualityTagsPreset = v, 'None'),
      _string('ucPreset', () => ucPreset, (v) => ucPreset = v, 'None'),

      // ── 생성 상세 ──
      // 지워진 테스트 모델 등은 기본값으로 · 목록에 없는 샘플러/스케줄러(예전의 ddim 등)도 기본값으로 (model_caps.dart)
      _string('model', () => selectedModel, (v) => selectedModel = v, kDefaultModel, fix: validModel),
      _string('sampler', () => selectedSampler, (v) => selectedSampler = v, kDefaultSampler, fix: validSampler),
      _string('scheduler', () => selectedScheduler, (v) => selectedScheduler = v, kDefaultScheduler, fix: validScheduler),
      _bool('schedulerUnlocked', () => schedulerUnlocked, (v) => schedulerUnlocked = v, false),
      _text('steps', stepsController, "28"),
      _text('cfgScale', cfgScaleController, "6.0"),
      _text('cfgRescale', cfgRescaleController, "0.00"),
      _text('seed', seedController),
      _bool('seedLocked', () => isSeedLocked, (v) => isSeedLocked = v, false),
      _bool('variancePlus', () => isVariancePlus, (v) => isVariancePlus = v, false),
      _bool('effortMedium', () => effortMedium, (v) => effortMedium = v, false),
      _bool('transparentBackground', () => transparentBackground, (v) => transparentBackground = v, false),
      _string('resolutionMode', () => resolutionMode, (v) => resolutionMode = v, "수동"),
      // 해상도는 사용자 해상도 목록까지 읽은 뒤에 검사한다 (_applySettings 끝)
      _string('resolution', () => selectedResolution, (v) => selectedResolution = v, kDefaultResolution),
      // kResolutionScales 에 있는 값만 (옛 값 · 잘못된 백업은 1.0)
      _double('resolutionScale', () => resolutionScale, (v) => resolutionScale = v, 1.0, fix: validResolutionScale),
      SettingField<List<String>>(
        'customResolutions',
        get: () => customResolutions,
        set: (v) => customResolutions = v,
        def: const [], // 목록은 늘 새 사본으로 들어온다 (SettingField._coerce) — 그대로 고쳐도 된다
      ),
      _text('custom_width', customWidthController, "$kDefaultWidth"),
      _text('custom_height', customHeightController, "$kDefaultHeight"),

      // ── 캐릭터 ──
      _bool('useCharacterPosition', () => useCharacterPosition, (v) => useCharacterPosition = v, true),
      _bool('randomCharacterOrder', () => randomCharacterOrder, (v) => randomCharacterOrder = v, false),
      _bool('charRetapToggle', () => charRetapToggle, (v) => charRetapToggle = v, true),
      _bool('charCanvasShowGrid', () => charCanvasShowGrid, (v) => charCanvasShowGrid = v, false),
      _bool('charCanvasSnap', () => charCanvasSnap, (v) => charCanvasSnap = v, false),
      _bool('charCanvasShowImage', () => charCanvasShowImage, (v) => charCanvasShowImage = v, false),
      _int('charGridCols', () => charGridCols, (v) => charGridCols = v, 5),
      _int('charGridRows', () => charGridRows, (v) => charGridRows = v, 5),

      // ── 프롬프트 검색 (Gelbooru) ──
      _text('gelbooru_inc', gelbooruIncludeController),
      _text('gelbooru_exc', gelbooruExcludeController),
      _text('gelbooru_api_input', gelbooruApiController), // 읽은 뒤 parseGelbooruApi (_applySettings 끝)
      _bool('rating_e', () => ratingE, (v) => ratingE = v, false),
      _bool('rating_q', () => ratingQ, (v) => ratingQ = v, false),
      _bool('rating_s', () => ratingS, (v) => ratingS = v, false),
      _bool('rating_g', () => ratingG, (v) => ratingG = v, true),
      _bool('remove_char_traits', () => removeCharacteristics, (v) => removeCharacteristics = v, false),
      _bool('remove_clothes', () => removeClothes, (v) => removeClothes = v, false),
      _bool('remove_clothing_events', () => removeClothingEvents, (v) => removeClothingEvents = v, false),
      _bool('remove_implied_tags', () => removeImpliedTags, (v) => removeImpliedTags = v, false),
      _bool('remove_colors', () => removeColors, (v) => removeColors = v, false),
      _bool('remove_character_tags', () => removeCharacterTags, (v) => removeCharacterTags = v, true),
      _bool('random_lock', () => isRandomLocked, (v) => isRandomLocked = v, false),
      _bool('randomPromptAlphabetical', () => randomPromptAlphabetical, (v) => randomPromptAlphabetical = v, false),
      _bool('ignoreRecommendedOrder', () => ignoreRecommendedOrder, (v) => ignoreRecommendedOrder = v, false),
      // 예전 슬라이더 값 → 가장 가까운 단계 (AppState.searchAmounts)
      _int('gelbooruSearchPages', () => gelbooruSearchPages, (v) => gelbooruSearchPages = v, 40, fix: snapSearchPages),
      // 검색 목록 안의 순번 — 목록 자체는 백업에 넣지 않으므로 순번도 뺀다 (목록을 읽은 뒤 _syncPromptCounters)
      _int('currentPromptIndex', () => currentPromptIndex, (v) => currentPromptIndex = v, 0, backup: false),

      // ── 일괄 생성 ──
      _double('batchDelay', () => batchDelay, (v) => batchDelay = v, 0.5),
      _bool('autoNextPromptInBatch', () => autoNextPromptInBatch, (v) => autoNextPromptInBatch = v, false),
      _bool('repeatSamePromptEnabled', () => repeatSamePromptEnabled, (v) => repeatSamePromptEnabled = v, false),
      _int('repeatSamePromptCount', () => repeatSamePromptCount, (v) => repeatSamePromptCount = v, 2),
      // 알림 권한은 기기마다 따로라 백업에 넣지 않는다 (다른 폰에 가져가면 권한을 묻지 않은 채 켜져 알림이 안 뜬다)
      _bool('generationNotify', () => generationNotify, (v) => generationNotify = v, false, backup: false),
      _bool('streamPreview', () => streamPreview, (v) => streamPreview = v, false),
      // Anlas 확인 창 안 띄우기 — 대신 실행 버튼에 빨간 테두리 (anlasMarked)
      _bool('skipAnlasConfirm', () => skipAnlasConfirm, (v) => skipAnlasConfirm = v, false),

      // ── i2i · 인페인트 · Director ──
      _double('infillStrength', () => infillStrength, (v) => infillStrength = v, 1.0),
      _int('focusInpaintContext', () => focusInpaintContext, (v) => focusInpaintContext = v, kFocusContextDefault,
          fix: (v) => v.clamp(0, kFocusContextMax)),
      _double('img2imgStrength', () => img2imgStrength, (v) => img2imgStrength = v, 0.5),
      _double('img2imgNoise', () => img2imgNoise, (v) => img2imgNoise = v, 0.1),
      _bool('i2iHistoryDisabled', () => i2iHistoryDisabled, (v) => i2iHistoryDisabled = v, false),
      // 옛 이름(inpaintAutoSwitchResult)은 _applySettings 에서 이어받는다
      _bool('inpaintNoAutoSwitch', () => inpaintNoAutoSwitch, (v) => inpaintNoAutoSwitch = v, false),
      _bool('inpaintAutoClearMask', () => inpaintAutoClearMask, (v) => inpaintAutoClearMask = v, false),
      _string('directorTool', () => directorTool, (v) => directorTool = v, 'bg-removal'),
      _bool('directorToolVisible', () => directorToolVisible, (v) => directorToolVisible = v, true),

      // ── 저장 · 파일 ──
      _bool('auto_save', () => isAutoSave, (v) => isAutoSave = v, true),
      _bool('autoSaveLocked', () => autoSaveLocked, (v) => autoSaveLocked = v, false),
      _bool(
        'warnBatchWithoutAutoSave',
        () => warnBatchWithoutAutoSave,
        (v) => warnBatchWithoutAutoSave = v,
        false,
      ),
      _bool('saveAsWebp', () => saveAsWebp, (v) => saveAsWebp = v, false),
      _bool('webpLossy', () => webpLossy, (v) => webpLossy = v, false),
      _bool('saveFolderByDateOnly', () => saveFolderByDateOnly, (v) => saveFolderByDateOnly = v, true),
      _text('custom_file_name', customFileNameController, "Nai-{yy}{mm}{dd}-{time}"),
      _bool('trashEnabled', () => trashEnabled, (v) => trashEnabled = v, true),
      // 휴지통 보관 일수 1~30
      _int('trashKeepDays', () => trashKeepDays, (v) => trashKeepDays = v, 14, fix: (v) => v.clamp(1, 30)),

      // ── 히스토리 · 갤러리 ──
      _bool('historySlideEnabled', () => historySlideEnabled, (v) => historySlideEnabled = v, false),
      _bool('galleryModeEnabled', () => galleryModeEnabled, (v) => galleryModeEnabled = v, true),
      _bool('historyKeepLastView', () => historyKeepLastView, (v) => historyKeepLastView = v, false),
      _bool('historyLastWasGallery', () => historyLastWasGallery, (v) => historyLastWasGallery = v, false),
      // 마지막 본 폴더 — 없으면(null) 저장하지 않는다
      SettingField<String?>(
        'galleryCurrentPath',
        get: () => galleryCurrentPath,
        set: (v) => galleryCurrentPath = v,
        def: null,
      ),
      _int('galleryColumns', () => galleryColumns, (v) => galleryColumns = v, 3),
      _string('gallerySortMode', () => gallerySortMode, (v) => gallerySortMode = v, 'name_asc'),

      // ── 화면 · 탭 ──
      _bool('historyTabEnabled', () => historyTabEnabled, (v) => historyTabEnabled = v, true),
      _bool('i2iTabEnabled', () => i2iTabEnabled, (v) => i2iTabEnabled = v, true),
      _bool('i2iModeInpaintEnabled', () => i2iModeInpaintEnabled, (v) => i2iModeInpaintEnabled = v, true),
      _bool('i2iModeMosaicEnabled', () => i2iModeMosaicEnabled, (v) => i2iModeMosaicEnabled = v, true),
      _bool('i2iModeImg2imgEnabled', () => i2iModeImg2imgEnabled, (v) => i2iModeImg2imgEnabled = v, true),
      _bool('i2iModeUpscaleEnabled', () => i2iModeUpscaleEnabled, (v) => i2iModeUpscaleEnabled = v, true),
      _bool('characterTabEnabled', () => characterTabEnabled, (v) => characterTabEnabled = v, true),
      _bool('wildcardTabEnabled', () => wildcardTabEnabled, (v) => wildcardTabEnabled = v, true),
      _bool('horizontalSwipeEnabled', () => horizontalSwipeEnabled, (v) => horizontalSwipeEnabled = v, false),
      _bool('promptCharDrawerEnabled', () => promptCharDrawerEnabled, (v) => promptCharDrawerEnabled = v, true),
      _double('promptEditorFontSize', () => promptEditorFontSize, (v) => promptEditorFontSize = v, 16.0),
      _int('themeAccent', () => themeAccent, (v) => themeAccent = v, 0xFF7C4DFF), // 읽은 뒤 AppColors.accent 에도 (_applySettings 끝)
      _bool('safCardOpen', () => safCardOpen, (v) => safCardOpen = v, true),
      _bool('fileCardOpen', () => fileCardOpen, (v) => fileCardOpen = v, true),
      _bool('promptDictCompact', () => promptDictCompact, (v) => promptDictCompact = v, false),
      // (라이브러리 탭의 안쪽 쪽 wildcardSubTab 은 저장하지 않는다 — 앱을 켤 때마다 와일드카드부터)
      _bool('autoCheckUpdate', () => autoCheckUpdate, (v) => autoCheckUpdate = v, true),

      // ── 접기 · 순서 (목록) ──
      SettingField<List<String>>(
        'promptSectionOrder',
        get: () => promptSectionOrder,
        set: (v) => promptSectionOrder = v,
        def: _allSections,
        // 새로 생긴 섹션은 뒤에 붙이고 없어진 섹션은 버린다 (길이를 고정하면 섹션이 늘 때 순서가 통째로 무시됨)
        fix: _mergeSectionOrder,
      ),
      // 섹션 이름 목록 — 지운 섹션(예: 3.14.0 의 weightRules)은 읽을 때 뺀다
      _strSet('collapsedSections', () => collapsedSections, (v) => collapsedSections = v, fix: _knownSections),
      _strSet('hiddenPromptSections', () => hiddenPromptSections, (v) => hiddenPromptSections = v, fix: _knownSections),
      _strSet('pinnedPromptSections', () => pinnedPromptSections, (v) => pinnedPromptSections = v, fix: _knownSections),
      _strSet('collapsedI2iPrompts', () => collapsedI2iPrompts, (v) => collapsedI2iPrompts = v),
      _strSet('collapsedSettingGroups', () => collapsedSettingGroups, (v) => collapsedSettingGroups = v),
    ];
    assert(() {
      // 같은 키가 두 번 있거나, 따로 다루는 키와 겹치면 한쪽이 다른 쪽을 덮는다
      const handledElsewhere = {
        // 저장 · 내보내기를 따로 하는 값
        'api_token',
        'naiAccounts',
        'activeAccountIndex',
        'promptUndoHistory',
        'modelSettingProfiles',
        'characters',
        'wildcards',
        // 내보내기 파일에만 있는 칸 · 옛 이름
        'version',
        'presets',
        'history',
        'promptDict',
        'promptDictCategories',
        'promptDictImages',
        'i2iFavorites',
        'vibeTransfers',
        'preciseRefs',
        'inpaintAutoSwitchResult',
      };
      final keys = [for (final s in list) s.key];
      return keys.toSet().length == keys.length && !keys.any(handledElsewhere.contains);
    }(), '설정 목록(_settings)에 겹치는 키가 있다');
    return list;
  }

  /// 설정 값들을 [read] 로 읽어 적용한다 — 불러오기(저장소)와 가져오기(백업 파일)가 같은 함수를 쓴다.
  ///  (예전엔 둘이 각자 100줄 넘게 같은 일을 했고, 아래 보정 코드도 두 벌이었다 — 가져오기 쪽엔
  ///   탭 켜기 다섯 줄이 실수로 두 번 들어가 있었다)
  ///  [fromBackup] 이면 —
  ///   · 백업에 넣지 않는 값(backup: false)은 건드리지 않는다.
  ///   · 백업에 그 칸이 없으면(그 설정이 생기기 전의 옛 백업) 지금 값을 그대로 둔다.
  ///     '정보 없음' 을 '기본값으로' 로 읽으면 옛 백업 하나로 사용자 해상도 목록 ·
  ///     Gelbooru 키처럼 다시 만들기 번거로운 값이 지워진다.
  ///   (저장소에서 읽을 때 칸이 없으면 기본값 — 새로 깐 앱이거나 그 설정이 새로 생긴 것)
  void _applySettings(Object? Function(String key) read, {required bool fromBackup}) {
    for (final s in _settings) {
      if (fromBackup && !s.backup) {
        continue;
      }
      final raw = read(s.key);
      if (fromBackup && raw == null) {
        continue;
      }
      s.apply(raw);
    }
    // 옛 이름 이어받기 — inpaintAutoSwitchResult 는 inpaintNoAutoSwitch 와 의미가 반대였다
    if (read('inpaintNoAutoSwitch') == null) {
      final old = read('inpaintAutoSwitchResult');
      if (old is bool) {
        inpaintNoAutoSwitch = !old;
      }
    }
    // 값끼리 맞추기 — 저장된 조합이 모순이면 바로잡는다
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false; // 모드가 전부 꺼져 있으면 탭도 꺼져 있어야 한다
    }
    if (useCharacterPosition && randomCharacterOrder) {
      randomCharacterOrder = false; // 상호 배타
    }
    selectedResolution = validResolution(selectedResolution); // 사용자 해상도 목록을 읽은 '뒤에'
    // 값에 따라 바뀌는 바깥 상태
    AppColors.accent = Color(themeAccent);
    WeightHighlightController.highlightEnabled = weightHighlight;
    parseGelbooruApi();
  }

  Future<void> saveAllSettings() async {
    // 불러오기가 끝나기 전엔 쓰지 않는다 — 아직 빈 입력창이 저장된 내용을 덮는다
    //  (_initialLoadFinished 참고. 로딩 중 앱을 내렸을 때 탭 내용이 통째로 사라지던 원인)
    //  끝났어도 설정을 못 읽었으면 쓰지 않는다 (_settingsRead 참고)
    if (!_initialLoadFinished || !_settingsRead) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      // ⚠️ 바뀐 값만 쓴다 (_putS · SettingField.save). 안드로이드 설정 저장소는 값 하나를 쓸 때마다
      //    '파일 전체'를 다시 쓰는데, 예전엔 여기서 매번 백 개가 넘는 값을 전부 써서
      //    프롬프트를 치다 멈출 때마다(0.5초) 그 파일을 백 번 넘게 다시 썼다.
      //    이제 보통은 방금 고친 칸 하나만 쓴다.
      // 입력창(controller)이 아니라 실제 사용 중인 토큰을 저장한다.
      //  계정 전환은 apiToken을 바꾸므로 controller가 낡아 있을 수 있다.
      await _putS(prefs, 'api_token', apiToken);
      await _putS(prefs, 'naiAccounts', jsonEncode(naiAccounts.map((e) => e.toJson()).toList()));
      await _putI(prefs, 'activeAccountIndex', activeAccountIndex);
      // 설정 값들 (_settings) — 바뀐 것만 쓴다 (SettingField.save)
      for (final s in _settings) {
        await s.save(prefs);
      }
      await _putS(prefs, 'promptUndoHistory', jsonEncode(promptUndoHistory));
      await _putS(prefs, 'modelSettingProfiles', jsonEncode(modelSettingProfiles));
      await _putS(prefs, 'characters', jsonEncode(characters.map((e) => e.toJson()).toList()));
      await _putS(prefs, 'wildcards', jsonEncode(wildcards.map((e) => e.toJson()).toList()));
      // 프리셋은 썸네일(base64)을 품고 있어 prefs에 두면 수백 KB가 된다 → 파일로 저장
      unawaited(savePresetsToFile());
      // 검색 목록(gelbooruPrompts)은 여기서 쓰지 않는다 — 파일에 따로, 바뀔 때만 (_saveGelbooruPromptsFile)
      //  (순번 currentPromptIndex 는 위 _settings 에 있다)

      // 설정 백업 파일 저장 (SharedPreferences 손실 방지)
      await _saveSettingsBackup();
    } catch (e) {
      debugPrint("설정 저장 실패: $e");
    }
  }

  // ============================================================================
  // 설정 백업/복구 (SharedPreferences 손실 방지)
  // ============================================================================
  // 마지막으로 쓴 설정 사본의 내용 (저장 시각 빼고) — 같으면 다시 쓰지 않는다
  String? _lastSettingsBackupBody;

  Future<void> _saveSettingsBackup() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/settings_backup.json');
      // 히스토리·사전 큰 이미지 제외 (용량 절약 + 빠른 저장 — 설정을 바꿀 때마다 쓰는 파일이다)
      // 사전·프리셋·i2i 즐겨찾기도 뺀다 — 같은 앱 폴더에 각자의 파일이 따로 있어 담을 이유가 없고,
      //  넣으면 설정을 바꿀 때마다(타자 칠 때도) 수 MB 를 다시 만들어 쓰게 된다 (즐겨찾기는 원본 그림째).
      //  이 사본은 설정 저장소(SharedPreferences)가 날아갔을 때만 쓴다 (tryRecoverFromBackup).
      final data = await exportSettings(
        includeHistory: false,
        includeDictImages: false,
        includeFileBacked: false,
      );
      // 지난번에 쓴 것과 같으면 다시 쓰지 않는다 (저장 시각만 다른 사본을 매번 쓰지 않게)
      final body = jsonEncode(data);
      if (body == _lastSettingsBackupBody) {
        return;
      }
      data['backup_time'] = DateTime.now().toIso8601String();
      await _writeAtomic(file, jsonEncode(data)); // 쓰다 꺼져도 직전 사본이 남는다
      _lastSettingsBackupBody = body;
    } catch (_) {
      // 자동 백업 실패는 알리지 않는다.
      // 설정은 이미 SharedPreferences 에 저장돼 있고, 이건 그 사본일 뿐이다.
      // 저장 공간이 부족할 때 매번 알림이 뜨면 오히려 방해가 된다.
    }
  }

  Future<bool> tryRecoverFromBackup() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/settings_backup.json');
      if (!file.existsSync()) {
        // 구버전 호환: 예전 임시 디렉토리 백업도 확인
        final tmpDir = await getTemporaryDirectory();
        final tmpFile = File('${tmpDir.path}/settings_backup.json');
        if (!tmpFile.existsSync()) {
          return false;
        }
        final tmpData = jsonDecode(await tmpFile.readAsString()) as Map<String, dynamic>;
        importSettings(tmpData);
        debugPrint("임시 디렉토리 백업에서 복구 성공");
        return true;
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

  // ── 설정 저장소에 '바뀐 값만' 쓰기 (saveAllSettings 전용) ──
  //  저장소가 들고 있는 값(메모리 사본)과 같으면 건너뛴다.
  static Future<void> _putS(SharedPreferences p, String k, String v) async {
    if (p.get(k) != v) {
      await p.setString(k, v);
    }
  }

  static Future<void> _putI(SharedPreferences p, String k, int v) async {
    if (p.get(k) != v) {
      await p.setInt(k, v);
    }
  }

  /// 설정을 저장하고 화면을 다시 그린다 — 설정 값을 바꾼 직후 늘 함께 하는 두 가지.
  ///  (예전엔 이 두 줄이 화면 곳곳에 70번 가까이 복사돼 있었다)
  void saveAndRefresh() {
    unawaited(saveAllSettings());
    notifyListeners();
  }

  // ── 공식 프리셋 적용 ──
  //  NovelAI 웹이 자동으로 붙여 주는 태그를 우리도 똑같이 붙인다.
  //  · Quality Tags는 프롬프트 '뒤'에 (공식과 같은 위치)
  //  · UC 프리셋은 부정 프롬프트 '앞'에
  String applyQualityTags(String prompt) {
    final opt = NaiPresets.find(NaiPresets.qualityFor(selectedModel), qualityTagsPreset);
    if (opt.tags.isEmpty) {
      return prompt;
    }
    if (prompt.trim().isEmpty) {
      return opt.tags;
    }
    return '$prompt, ${opt.tags}';
  }

  /// [positive] 는 실제로 보낼 긍정(캐릭터 포함) — nsfw 가 있는지 여기서 본다.
  ///  없으면(토큰 세기 등) 프롬프트탭의 글로 대신 본다.
  ///  ⚠️ 예전엔 늘 프롬프트탭의 글을 봐서, i2i(인페인트 · img2img)는 i2i 프롬프트에 nsfw 가 있어도
  ///     부정에 nsfw 가 붙었고, 와일드카드로 들어온 nsfw 도 못 알아봤다.
  ///  [preset] 을 주면 고른 프리셋 대신 그 이름으로 (Medium effort 의 고정 Heavy).
  String applyUcPreset(String negative, {String? positive, String? preset}) {
    final opt = NaiPresets.find(NaiPresets.ucFor(selectedModel), preset ?? ucPreset);
    if (opt.tags.isEmpty) {
      return negative; // None — 프리셋을 껐으므로 nsfw도 붙이지 않는다
    }

    // 공식은 프리셋 맨 앞에 nsfw를 함께 넣는다.
    //  단, 긍정 프롬프트에 nsfw가 있으면 서로 상쇄되므로 빼 준다.
    final positiveAll =
        (positive ??
                [
                  prefixController.text,
                  positiveController.text,
                  suffixController.text,
                  for (final c in characters)
                    if (c.isActive) c.positive,
                ].join(', '))
            .toLowerCase();
    final wantsNsfw = RegExp(r'(^|[,\s{[])nsfw($|[,\s}\]])').hasMatch(positiveAll);

    // ⚠️ 이름을 'preset' 으로 두면 위의 매개변수 [preset] 을 가린다 (분석기 오류)
    final presetTags = wantsNsfw ? opt.tags : 'nsfw, ${opt.tags}';
    if (negative.trim().isEmpty) {
      return presetTags;
    }
    return '$presetTags, $negative';
  }

  // 설정 저장 디바운스.
  //  saveAllSettings는 prefs에 100여 개를 쓰므로(수십 ms) 타이핑마다 부르면 버벅인다.
  //  입력이 멈춘 뒤 한 번만 저장한다.
  Timer? _saveSettingsDebounce;

  void saveAllSettingsDebounced({int ms = 500}) {
    _saveSettingsDebounce?.cancel();
    _saveSettingsDebounce = Timer(Duration(milliseconds: ms), () {
      saveAllSettings();
    });
  }

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
      // 공식 프리셋 — 프롬프트 스타일의 일부라 프리셋에 함께 담는다
      'qualityTagsPreset': qualityTagsPreset,
      'ucPreset': ucPreset,
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
      selectedSampler = validSampler(s['sampler']);
    }
    if (s['scheduler'] != null) {
      selectedScheduler = validScheduler(s['scheduler']);
    }
    if (s['model'] != null) {
      selectedModel = validModel(s['model']);
    }
    if (s['resolution'] != null) {
      selectedResolution = validResolution(s['resolution']);
    }
    if (s['seedLocked'] != null) {
      isSeedLocked = s['seedLocked'];
    }
    if (s['variancePlus'] != null) {
      isVariancePlus = s['variancePlus'];
    }
    if (s['qualityTagsPreset'] != null) {
      qualityTagsPreset = s['qualityTagsPreset'];
    }
    if (s['ucPreset'] != null) {
      ucPreset = s['ucPreset'];
    }
  }

  void sendToI2i(Uint8List imageBytes, NaiMetadata? metadata) {
    i2iMaskActionOnChange = I2iMaskAction.clearMask; // 보내기는 항상 마스킹 초기화
    targetI2iImage = imageBytes;
    targetI2iMetadata = metadata;
    i2iCompareBase = imageBytes; // 비교 보기의 기준 = 보낸 원본 (새로 보내면 고정해 둔 것도 바뀐다)
    i2iCompareBasePinned = false;
    recordI2iView(imageBytes, metadata, reset: true); // 본 이미지 기록 새로 시작
    // i2i 탭이 꺼져 있으면 자동으로 켜기.
    // setI2iTabEnabled를 거쳐야 "모드가 전부 꺼져 있던 경우 모드 복구"까지 함께 처리된다.
    if (!i2iTabEnabled) {
      setI2iTabEnabled(true);
    }
    // 릴이 켜져 있으면 보낸 원본도 릴에 추가 (작업 후 원본으로 복귀 가능하게).
    // 릴이 꺼져 있으면(=히스토리 모드) 보낸 이미지는 추가하지 않음 (히스토리에 따로 있음).
    if (!i2iHistoryDisabled) {
      addI2iResult(imageBytes, metadata, source: 'origin');
    }
    notifyListeners();
  }

  // 프롬프트 검색(검색 돌리기 · 목록 보관 · 다음/다시 불러오기)은 app_state_search.dart
  //  글자 처리(검색어 펼치기 · 태그 다듬기)는 prompt_search.dart

  // ── 프롬프트 처리 연결부 ──
  //  실제 처리는 models/prompt_pipeline.dart 의 순수 함수가 한다. 여기서는 이 상태의 값
  //  (와일드카드 목록 · 순차 카운터 · 규칙 글 · 설정)을 넘겨 주기만 한다.

  /// 랜덤 a|b · 와일드카드 열기 (순차 와일드카드 카운터는 [_sequentialCounters])
  String _processWildcards(String prompt) =>
      processWildcards(prompt, contentOf: _wildcardContent, counters: _sequentialCounters);

  /// 이름이 같은 와일드카드의 내용 (없으면 null — 그 자리는 그대로 남는다)
  String? _wildcardContent(String name) {
    for (final w in wildcards) {
      if (w.name == name) {
        return w.content;
      }
    }
    return null;
  }

  /// 인원수 앞으로 — 'NovelAI 권장 순서 무시' 가 켜져 있으면 하지 않는다
  String _hoistCountTags(String text) => ignoreRecommendedOrder ? text : hoistCountTags(text);

  // 최종 프롬프트 미리보기 (2번째 UI 상단 표시용)
  // 생성과 같은 순서로 합치되, 와일드카드는 생성 시마다 바뀌므로 원문(__foo__)을 그대로 남긴다.
  String buildPreviewPrompt() {
    String prefixText = prefixController.text;
    String positiveText = positiveController.text;
    String suffixText = suffixController.text;

    // 조건부 트리거가 generate 모드면 영역별로 적용 (random 모드는 이미 반영돼 있음)
    if (conditionalTriggerMode == "generate") {
      final rating = ratingLetterOf("$prefixText,$positiveText,$suffixText");
      final sectioned = applyConditionalRulesSectioned(
        prefixText,
        positiveText,
        suffixText,
        rating,
        conditionalRuleController.text,
      );
      prefixText = sectioned.prefix;
      positiveText = sectioned.positive;
      suffixText = sectioned.suffix;
    }

    // 표시용 구분: 선행/긍정/후행 사이에 빈 줄을 넣어 영역을 눈으로 구분한다.
    // (실제 전송은 handleGenerate가 따로 조립하므로 여기 줄바꿈은 화면에만 영향)
    //  각 구획 '안'의 줄바꿈은 sanitizePrompt가 보존하므로 사용자가 짠 줄 구성이 그대로 보인다.
    const sep = "\n\n";
    final parts = [
      _service.sanitizePrompt(prefixText),
      _service.sanitizePrompt(positiveText),
      _service.sanitizePrompt(suffixText),
    ];
    // 비어 있는 영역은 구분선도 만들지 않아 불필요한 여백/콤마가 남지 않게
    final shown = parts.where((e) => e.trim().isNotEmpty).toList();
    final buf = StringBuffer();
    for (int i = 0; i < shown.length; i++) {
      if (i > 0) {
        // 보낼 때(joinPromptSections)처럼 — 경계가 가중치 표시(1.1:: · ::)에 닿으면 쉼표를 넣지 않는다
        buf.write(weightTouchesBoundary(shown[i - 1], shown[i]) ? sep : ",$sep");
      }
      buf.write(shown[i]);
    }
    return buf.toString();
  }

  // FlutterBackground는 최초 1회만 initialize.
  // (매 생성마다 알림 채널을 다시 세팅하면 그만큼 생성 시작이 늦어짐)
  // 이후 생성부터는 enable/disable만 토글한다.
  bool _bgServiceReady = false;
  Future<bool> _enableBackgroundExecution() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      if (!_bgServiceReady) {
        _bgServiceReady = await FlutterBackground.initialize(
          androidConfig: const FlutterBackgroundAndroidConfig(
            // 생성뿐 아니라 검색·업스케일 등에도 쓰여서 중립적인 이름으로 둔다
            notificationTitle: "DNaiApp 작업 중",
            notificationText: "백그라운드에서 안전하게 통신 중입니다...",
            notificationImportance: AndroidNotificationImportance.normal,
            notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
          ),
        );
      }
      if (_bgServiceReady) {
        await FlutterBackground.enableBackgroundExecution();
        return true;
      }
    } catch (e) {
      debugPrint("백그라운드 실행 권한이 없거나 오류 발생: $e");
    }
    return false;
  }

  // ── 백그라운드 실행 붙잡기 ('생성 중' 알림 서비스) ──
  //  오래 걸리는 서버 작업(생성·배치·i2i·업스케일·디렉터 도구·프롬프트 검색) 동안 앱이 뒤로 가도 끊기지 않게 켜 둔다.
  //  여러 작업이 겹쳐도 처음 하나가 켜고 마지막 하나가 끈다 — _holdBackground / _releaseBackground 는 반드시 짝.
  //  ⚠️ 예전엔 생성 한 장마다 켰다 껐다 했다. 그런데 안드로이드 12부터는 앱이 뒤에 있을 때
  //     이 서비스를 '새로' 켜는 게 막혀서, 배치 생성 중 앱을 내리면 두 번째 장부터는 보호 없이 돌았고
  //     장 사이 대기 동안엔 시스템이 앱을 얼려 배치가 멈추기도 했다. → 배치는 처음부터 끝까지 한 번에 붙잡는다.
  //  ⚠️ 업스케일·디렉터 도구는 아예 켜지 않아, 도중에 앱을 내리면 연결이 끊길 수 있었다
  //     (Anlas 는 나갔는데 결과는 못 받는다).
  int _bgHolds = 0; // 지금 붙잡고 있는 작업 수
  bool _bgActive = false; // 서비스가 실제로 켜져 있는지

  Future<void> _holdBackground() async {
    _bgHolds++;
    if (_bgHolds != 1 || _bgActive) {
      return; // 이미 다른 작업이 켜 둠
    }
    final bool ok = await _enableBackgroundExecution();
    if (!ok) {
      return;
    }
    if (_bgHolds == 0) {
      // 켜는 사이 작업이 이미 다 끝났다 → 바로 끈다 (알림이 남지 않게)
      await _disableBackgroundQuietly();
    } else {
      _bgActive = true;
    }
  }

  Future<void> _releaseBackground() async {
    if (_bgHolds > 0) {
      _bgHolds--;
    }
    if (_bgHolds == 0 && _bgActive) {
      _bgActive = false;
      await _disableBackgroundQuietly();
    }
  }

  Future<void> _disableBackgroundQuietly() async {
    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (e) {
      // 이미 꺼졌거나 권한이 사라진 경우다. 작업은 끝난 뒤라 알릴 필요가 없다.
      debugPrint("백그라운드 해제 오류(무시): $e");
    }
  }

  // 생성 중복 실행 방지.
  //  isLoading은 "이미지가 도착한 순간" 먼저 풀어 화면을 빨리 갱신하는데,
  //  그 뒤에도 저장·히스토리 추가·잔액 조회가 남아 있다.
  //  그 틈에 버튼을 다시 누르면 생성이 두 번 돌아 이미지가 하나 더 나온다.
  //  → 후처리까지 모두 끝나야 풀리는 별도 잠금을 둔다. (i2i의 방식과 동일)
  bool _isGenerateProcessing = false;

  /// 생성이 완전히 끝났는지 (후처리 포함). 버튼 비활성 판단에 쓴다.
  bool get isGenerateBusy => _isGenerateProcessing;

  /// 잔액(Anlas)과 V5 시간당 한도를 갱신한다. 기다리지 않는다.
  ///
  /// ⚠️ 일부러 await하지 않는다.
  ///    이 둘은 화면의 숫자만 바꾸는 조회라서 다음 생성과 경합하지 않는다.
  ///    예전에는 생성 직후 이걸 await 하는 바람에 이미지가 이미 화면에 떴는데도
  ///    네트워크 왕복 동안 생성 버튼이 계속 잠겨 있었다.
  ///    조회가 끝나면 fetchAnlas 가 알아서 notifyListeners()로 숫자를 갱신한다.
  ///  (잔액과 V5 한도는 한 번의 조회로 함께 온다 — 예전엔 같은 요청을 V5 에서 두 번 보냈다)
  void refreshBalanceInBackground() {
    final Future<void> job = () async {
      try {
        await fetchAnlas();
      } catch (e) {
        debugPrint('잔액 조회 실패(무시): $e');
      }
    }();
    _balanceRefresh = job; // 무료 연속 생성의 지킴이가 다음 장 전에 이 조회를 기다린다 (_runBatchLoop)
    unawaited(job);
  }

  /// 마지막으로 시작한 잔액 조회 (끝났을 수도 있다)
  Future<void>? _balanceRefresh;

  /// 연속 생성 밖에서 Anlas 를 쓰는 작업(i2i · 업스케일 · 디렉터)이 시작 · 끝날(finally) 때마다 +1.
  ///  무료 연속 생성 지킴이가 그 Anlas 를 연속 생성 탓으로 보지 않게 기준을 다시 잡는 데 쓴다
  ///  (도는 동안은 지킴이가 그 작업의 '불러오는 중' 표시를 보고 비교하지 않는다).
  int _otherSpendSerial = 0;

  /// 이미지 1장 생성. 반환: 연속 생성이 계속해도 되는지 ([GenerateOutcome]).
  ///  · 서버 오류의 메시지는 화면(이미지 자리)에 뜬다.
  ///  · stop — 다시 해도 같은 오류(4xx · 한도 · Vibe 인코딩)거나 준비 · 후처리 중 예외 → 배치가 바로 멈춘다.
  ///  · retryable — 서버 바쁨 · 5xx · 시간 초과 · 연결 → 배치는 연속 몇 번까지만 넘어간다.
  ///  ⚠️ 예전엔 서버가 거절한 것도 '정상 끝'으로 봐서, 키 · Anlas 문제여도 0.5초마다 같은 실패 요청을 끝없이 보냈다.
  ///
  ///  ⚠️ 예전엔 잠금(_isGenerateProcessing)을 건 뒤 준비 단계(와일드카드·순차 생성·조건부 규칙·
  ///     캐릭터 정리 …)가 try 밖에 있었다. 거기서 오류가 한 번이라도 나면 잠금이 안 풀려,
  ///     앱을 다시 켤 때까지 생성 버튼이 잠기고 로딩 표시가 계속 돌았다.
  ///     → 잠금을 건 '바로 다음'부터 전부 감싸서, 무슨 일이 있어도 풀리게 한다.
  ///  [samples] 가 2 이상이면 요청 한 번에 그 장수 (생성 버튼 꾹 — n_samples). 받은 그림은 한 장씩 히스토리에 들어간다.
  Future<GenerateOutcome> handleGenerate(
    BuildContext context,
    VoidCallback onScrollToHistoryEnd, {
    int samples = 1,
  }) async {
    if (_isGenerateProcessing) {
      debugPrint('이미 생성 처리 중입니다. 중복 요청을 무시합니다.');
      return GenerateOutcome.ok;
    }
    if (!isApiConnected) {
      return GenerateOutcome.stop; // 만들지 않았다 — 배치가 '받은 것' 으로 세지 않게
    }
    _isGenerateProcessing = true;
    final before = currentImageBytes; // 이번에 새 그림이 왔는지 보려고
    try {
      return await _generateOnce(context, onScrollToHistoryEnd, samples: samples);
    } catch (e, st) {
      debugPrint('생성 처리 오류: $e\n$st');
      // 이미지 자리에 빨간 글씨로 뜬다 (main.dart _buildImageArea).
      //  단 그림이 이미 왔으면(그 뒤 저장·히스토리 단계의 오류) 그 그림을 가리지 않는다 — Anlas 를 들인 결과다.
      if (identical(currentImageBytes, before)) {
        lastErrorMessage = "생성 중 오류가 났어요.\n$e";
      }
      return GenerateOutcome.stop;
    } finally {
      // 후처리까지 끝난 지금 잠금을 푼다 (성공/실패/오류 무관)
      _isGenerateProcessing = false;
      isLoading = false;
      notifyListeners();
    }
  }

  /// handleGenerate 의 본문 — 잠금·해제는 부르는 쪽(handleGenerate)이 맡는다.
  Future<GenerateOutcome> _generateOnce(
    BuildContext context,
    VoidCallback onScrollToHistoryEnd, {
    int samples = 1,
  }) async {
    if (!isSeedLocked || seedController.text.isEmpty) {
      seedController.text = Random().nextInt(4294967296).toString();
    }
    isLoading = true;
    lastErrorMessage = null;
    notifyListeners();
    // 설정 저장은 생성과 병렬로 (95개 키 기록을 생성 시작이 기다릴 필요 없음)
    unawaited(saveAllSettings());
    var (width, height) = (kDefaultWidth, kDefaultHeight); // 아래에서 모드별로 정해진다

    if (resolutionMode == "랜덤") {
      final List<String> randomList = kNaiResolutions;
      String rndRes = randomList[Random().nextInt(randomList.length)];
      (width, height) = resolutionOrDefault(rndRes);
    } else if (resolutionMode == "자동" && currentImageWidth > 0 && currentImageHeight > 0) {
      double maxPixels = kMegapixelCap.toDouble();
      double ratio = currentImageWidth / currentImageHeight;
      double h = sqrt(maxPixels / ratio);
      double w = h * ratio;
      width = (w / 64).round() * 64;
      height = (h / 64).round() * 64;
      while (width * height > kMegapixelCap) {
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
    } else if (selectedResolution == kCustomResolutionLabel ||
        (resolutionMode == "자동" && currentImageWidth == 0)) {
      (width, height) = _customResolution();
    } else {
      (width, height) = resolutionOrDefault(selectedResolution);
    }

    // 해상도 배율 + 64px 정렬 + 모델별 픽셀 상한 (공용 헬퍼 — 상한을 넘으면 비율을 지킨 채 줄인다)
    (width, height) = scaledResolution(width, height, resolutionScale, modelCapsFor(selectedModel).maxPixels);

    // 처리 순서: 와일드카드 개봉 → 조건부 트리거(generate 모드) → 합치기 → sanitize
    String prefixText = prefixController.text;
    String positiveText = positiveController.text;
    String suffixText = suffixController.text;

    // 0. 순차 생성 <A|B|C>: 세 영역을 합친 기준으로 처리 (영역 간 독립 보장)
    //    구분자(\u0001)로 합쳐 처리 후 다시 분리
    const sep = '\u0001';
    final seqInput = "$prefixText$sep$positiveText$sep$suffixText";
    final seqCombined = processSequential(seqInput, _sequentialCounters);
    final seqParts = seqCombined.split(sep);
    prefixText = seqParts.isNotEmpty ? seqParts[0] : prefixText;
    positiveText = seqParts.length > 1 ? seqParts[1] : positiveText;
    suffixText = seqParts.length > 2 ? seqParts[2] : suffixText;
    advanceSequential(seqInput, _sequentialCounters); // 도달한 <>만 카운터 +1 (생성 1회 = 1전진)

    // 1. 와일드카드(랜덤 파이프 + __wildcard__) 개봉
    //    순차 와일드카드(@) 위치 일관성을 위해 세 영역을 합쳐서 개봉 후 분리
    final wcInput = "$prefixText$sep$positiveText$sep$suffixText";
    final wcCombined = _processWildcards(wcInput);
    advanceSequentialWildcards(wcInput, _sequentialCounters); // 개봉 후 순차 와일드카드 @ 카운터 전진
    final wcParts = wcCombined.split(sep);
    prefixText = wcParts.isNotEmpty ? wcParts[0] : prefixText;
    positiveText = wcParts.length > 1 ? wcParts[1] : positiveText;
    suffixText = wcParts.length > 2 ? wcParts[2] : suffixText;

    // 2. 조건부 트리거가 "generate" 모드면 와일드카드 개봉 후 적용
    if (conditionalTriggerMode == "generate") {
      final rating = ratingLetterOf("$prefixText,$positiveText,$suffixText");
      final sectioned = applyConditionalRulesSectioned(
        prefixText,
        positiveText,
        suffixText,
        rating,
        conditionalRuleController.text,
      );
      prefixText = sectioned.prefix;
      positiveText = sectioned.positive;
      suffixText = sectioned.suffix;
    }

    // 3. 합치기 (와일드카드는 이미 개봉됨)
    //  구획별로 정리한 뒤 ", " 로 잇는다. 구획 '안'의 줄바꿈은 그대로 살아남는다.
    //  보내기 직전 마무리까지 — i2i 와 똑같은 단계를 거친다 (_joinForSend 참고)
    final String finalPrompt = _joinForSend(prefixText, positiveText, suffixText);

    // 모델 상한을 넘으면 서버가 거부한다 (V4.5=6, V5=32)
    List<Map<String, dynamic>> processedCharacters = characters
        .where((char) => char.isActive)
        .take(modelCapsFor(selectedModel).maxCharacters)
        .map((char) {
          return _characterForSend(char);
        })
        .toList();
    // 부정은 보낼 긍정 · 캐릭터를 보고 마무리한다 (UC 프리셋의 nsfw — applyUcPreset)
    final String finalNegative = _finishNegative(
      negativeController.text,
      sentPositive: _sentPositiveOf(finalPrompt, processedCharacters),
    );

    // vibe 인코딩 캐시 갱신 감지용 지문 (생성 후 비교)
    final String vibeSigBefore = _vibeCacheSignature();

    // 앱이 뒤로 가도 끊기지 않게 (배치 중이면 배치가 이미 붙잡고 있어 그대로 이어진다)
    await _holdBackground();

    try {
      // 활성 vibe/정밀 참조 필터는 한 번만 (같은 where를 세 번 돌리지 않도록)
      // 모델이 지원하지 않으면(예: V5) 항목이 담겨 있어도 전송하지 않는다.
      final caps = modelCapsFor(selectedModel);
      final activeVibes = caps.supportsVibe
          ? vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList()
          : <Map<String, dynamic>>[];
      final activePrecise = caps.supportsPrecise
          ? preciseRefs.where((r) => (r['enabled'] as bool?) ?? true).toList()
          : <Map<String, dynamic>>[];

      // VAR+ 는 보낼 때의 값을 잡아 둔다 — 생성 중에 스위치를 바꾸면 그림 정보(다시 뽑기가 읽는다)에 다른 값이 적혔다
      final bool varPlus = isVariancePlus;
      final result = await _service.generateImage(
        positive: finalPrompt,
        negative: finalNegative,
        token: apiToken,
        model: selectedModel,
        steps: effectiveSteps,
        sampler: selectedSampler,
        scheduler: schedulerFor(selectedModel), // V5 잠금은 여기서 (설정 '스케줄러 잠금 해제')
        width: width,
        height: height,
        cfgScale: double.tryParse(cfgScaleController.text) ?? 6.0,
        cfgRescale: double.tryParse(cfgRescaleController.text) ?? 0.0,
        seed: int.tryParse(seedController.text) ?? 0,
        characters: processedCharacters,
        mediumEffort: effortMediumActive, // V5 Full Medium — 스텝 · 샘플러 · Rescale 은 보내는 쪽이 고정값으로
        // 모델이 미지원이면 VAR+는 전송하지 않는다
        variancePlus: varPlus && modelCapsFor(selectedModel).supportsVarietyPlus,
        // 투명 배경 (모델이 지원할 때만)
        transparentBackground: transparentBackground,
        useCharacterPosition: useCharacterPosition,
        randomCharacterOrder: randomCharacterOrder,
        // 정밀 참조가 있으면 vibe 대신 정밀 참조 우선 (기존 동작 그대로, 필터는 위에서 1회)
        vibeTransfers: (activeVibes.isNotEmpty && activePrecise.isEmpty) ? activeVibes : null,
        preciseRefs: activePrecise.isNotEmpty ? activePrecise : null,
        onPreview: _previewSink, // 생성 과정 미리보기 (설정이 꺼져 있으면 null → 보통 요청)
        onPreviewReset: _clearPreview, // 실패해 다시 할 때 지난 미리보기를 걷는다
        samples: samples, // 한 번에 여러 장이면 미리보기 없이 보통 요청으로 (보내는 쪽이 정한다)
      );

      isLoading = false;
      // 받은 그림 전부 (한 번에 여러 장이면 둘째 장부터 result.more)
      final List<Uint8List> images = [?result.image, ...result.more];
      currentImageBytes = result.image ?? currentImageBytes;
      lastErrorMessage = result.error;
      _clearPreview(); // 미리보기를 걷고 완성 그림으로 (같은 화면 갱신에서 바뀐다)
      // 이미지가 도착한 즉시 화면에 표시.
      // (이게 없으면 아래 fetchAnlas 네트워크 왕복이 끝나야 갱신돼 수백 ms를 그냥 기다림)
      notifyListeners();

      // 인코딩 캐시가 '실제로' 갱신된 경우에만 저장
      // (매 생성마다 vibe base64 전체를 jsonEncode하면 메인 스레드가 수 MB를 인코딩하게 됨)
      //  생성이 실패해도 본다 — Vibe 여럿 중 하나만 인코딩에 실패하면 앞의 것은 Anlas 를 내고 캐시에 들어갔다
      if (_vibeCacheSignature() != vibeSigBefore) {
        saveReferencesToLocal();
      }

      if (images.isNotEmpty) {
        // 한 장씩 히스토리에 — 그림마다 정보(시드 등)가 따로 들어 있다.
        //  지금 그림은 히스토리의 새 칸과 같은 객체로 둔다 (historyEntryOf) → 끝나면 마지막 장이 보인다.
        for (final Uint8List pic in images) {
          sessionGenerateCount++;

          NaiMetadata? parsedMeta = extractNovelAIMetadata(pic);
          if (parsedMeta != null) {
            parsedMeta = parsedMeta.copyWithExtra({'variety_plus': varPlus});
          }

          currentImageBytes = pic;
          await addImageToHistory(
            image: pic,
            metadata: parsedMeta,
            context: context.mounted ? context : null,
          );
        }

        if (!isHistoryGridView) {
          onScrollToHistoryEnd();
        }
      }

      // 잔액·한도 갱신은 기다리지 않는다 (버튼이 그만큼 늦게 풀린다)
      refreshBalanceInBackground();
      if (result.image != null) {
        return GenerateOutcome.ok;
      }
      return result.fatal ? GenerateOutcome.stop : GenerateOutcome.retryable;
    } finally {
      _clearPreview(); // 오류로 끝나도 미리보기가 남지 않게
      await _releaseBackground();
    }
  }

  // ============================================================================
  // 배치 생성 (연속 생성)
  // ============================================================================
  void cancelBatch() {
    batchRemaining = 0;
    isBatchMode = false;
    currentRepeatIndex = 0;
    currentRepeatTotal = 0;
    notifyListeners();
  }

  ///  [samples] 가 2 이상이면 생성 버튼 꾹 — 연속 생성 설정과 무관하게 요청 한 번으로 그 장수 (n_samples).
  Future<void> handleBatchGenerate(
    BuildContext context,
    VoidCallback onScrollToHistoryEnd, {
    int samples = 1,
  }) async {
    if (isLoading || isInpaintLoading || isUpscaleLoading) {
      return;
    }

    final bool multi = samples > 1;
    final count = multi ? 1 : batchCount; // 0 = 무한 (한 번에 여러 장은 요청 한 번)
    batchRemaining = count == 0 ? 999 : count;
    isBatchMode = count > 1 || count == 0;
    notifyListeners();

    // 배치 전체를 한 번에 붙잡는다 — 앱이 앞에 있을 때(버튼을 누른 지금) 켜 둬야
    //  나중에 앱을 내려도 끝까지 이어진다 (_holdBackground 설명 참고)
    //  기다리지 않는다: 붙잡은 수는 바로 올라가서 첫 장의 handleGenerate 가 다시 켜려 하지 않고,
    //  여기서 기다리면 그 뒤에 context 를 넘기는 게 '비동기 틈 너머의 context' 가 된다.
    unawaited(_holdBackground());
    // 생성 진행 · 완료 알림 — 전체 장수 = 프롬프트 수 × 프롬프트당 장수 (무한은 0). 짝은 아래 finally 의 _notifyEnd
    //  한 장 생성(isBatchMode 아님)은 반복 설정이 켜져 있어도 한 장만 만든다 (_runBatchLoop 가 첫 장 뒤에 멈춘다)
    _notifyStart(
      multi ? samples : (count == 0 ? 0 : (isBatchMode ? count * _repeatsPerPrompt : 1)),
    );
    try {
      // 연속 생성(2개 이상 또는 무한) + 자동 전환 ON이면, 첫 생성 "전에" 다음 프롬프트로 1번 넘긴다.
      // → 이전 배치의 마지막 프롬프트와 겹치는 것을 방지 (예: 이전이 A B C면 다음은 B C D).
      // 1개 생성일 때는 "지금 보는 프롬프트로 1장" 의도를 존중해 넘기지 않는다.
      // (try 안에 둔다 — 여기서 오류가 나도 '배치 중' 표시가 남지 않게)
      if (isBatchMode && autoNextPromptInBatch) {
        handleNextPrompt();
      }
      await _runBatchLoop(context, onScrollToHistoryEnd, count, samples: samples);
    } finally {
      await _releaseBackground();
      // 도중에 오류가 나도 '배치 중' 표시가 남지 않게
      batchRemaining = 0;
      isBatchMode = false;
      currentRepeatIndex = 0;
      currentRepeatTotal = 0;
      _notifyEnd();
      notifyListeners();
    }
  }

  /// 일시 오류(서버 바쁨 · 5xx · 시간 초과 · 연결)가 이만큼 연속이면 연속 생성을 멈춘다
  static const int _kBatchFailLimit = 3;

  Future<void> _runBatchLoop(
    BuildContext context,
    VoidCallback onScrollToHistoryEnd,
    int count, {
    int samples = 1, // 한 번에 여러 장 — 연속 생성이 아니라 한 번만 돈다 (isBatchMode 가 아니다)
  }) async {
    int failStreak = 0; // 일시 오류가 연속으로 난 횟수 (그림을 받으면 0)

    // ── 무료로 시작한 연속 생성 지킴이 ──
    //  시작할 때 '소모 없음' 이었는데 도중에 돈이 나가기 시작하면 멈춘다 (장마다 생성 전에 본다).
    //  · V5 무료 한도가 바닥남 — 공식 설명상 그때부터는 Anlas 로 생성된다
    //  · 잔액이 줄었음 — 서버가 어떻게 하든 확실한 신호 (잔액은 장마다 뒤에서 다시 조회한다)
    //  한 장 생성은 보지 않는다 — 멈출 다음 장이 없고, 기다리는 동안 버튼이 풀려 보인다.
    final bool startedFree = isBatchMode && !checkIfAnlasConsumed();
    NaiAccount? guardAccount;
    String? guardToken;
    int guardSpend = -1; // 배치 밖 유료 작업 번호 (_otherSpendSerial) — 바뀌면 기준을 다시 잡는다
    int guardAnlas = -1;
    Future<String?> paidSinceStart() async {
      if (!startedFree) {
        return null;
      }
      // 앞 장 뒤의 잔액 조회를 잠깐 기다린다 (보통 1초 안 — 안 기다리면 한 장 늦게 알아챈다)
      //  (연속 생성 중이라 버튼은 '정지' 로 보이고 있다)
      final Future<void>? pending = _balanceRefresh;
      if (pending != null) {
        try {
          await pending.timeout(const Duration(seconds: 3));
        } catch (_) {
          // 늦어지면 지난 값으로 본다
        }
      }
      if (modelCapsFor(selectedModel).hasHourlyLimit && v5LimitExhausted) {
        return "V5 무료 한도가 다 돼서 연속 생성을 멈췄어요.";
      }
      final NaiAccount? acc = activeAccount;
      final int now = acc?.anlas ?? -1;
      // 처음 · 계정이나 토큰을 바꿈 · 배치 밖의 유료 작업(i2i · 업스케일 · 디렉터)이 있었거나 도는 중
      //  → 비교하지 않고 기준만 다시 잡는다 (그 Anlas 를 연속 생성 탓으로 보지 않게)
      if (!identical(acc, guardAccount) ||
          acc?.token != guardToken ||
          guardSpend != _otherSpendSerial ||
          isInpaintLoading ||
          isUpscaleLoading ||
          isDirectorLoading) {
        guardAccount = acc;
        guardToken = acc?.token;
        guardSpend = _otherSpendSerial;
        guardAnlas = now;
        return null;
      }
      if (now >= 0 && guardAnlas >= 0 && now < guardAnlas) {
        return "Anlas가 줄어서 연속 생성을 멈췄어요.\n(V5 무료 한도가 다 됐을 수 있어요)";
      }
      if (now > guardAnlas) {
        guardAnlas = now; // 충전 · 늦게 온 첫 조회
      }
      return null;
    }

    while (batchRemaining > 0) {
      // 탭을 옮겨 프롬프트 탭이 dispose돼도(context unmounted) 자동생성은 계속되어야 한다.
      // → context.mounted로 중단하지 않는다. 중단 조건은 API 끊김 / 남은 수 소진 / 사용자 정지뿐.
      if (!isApiConnected) {
        break;
      } // API 끊기면 중지

      // 같은 프롬프트 반복 생성 횟수 (자동 전환 ON + 반복 ON일 때만 2회 이상)
      final int repeats = _repeatsPerPrompt;
      // UI 표시용 (반복이 1회뿐이면 표시하지 않도록 0으로)
      currentRepeatTotal = repeats > 1 ? repeats : 0;

      bool aborted = false;
      for (int r = 0; r < repeats; r++) {
        if (!isApiConnected) {
          aborted = true;
          break;
        }
        currentRepeatIndex = repeats > 1 ? r + 1 : 0;
        notifyListeners();

        final String? paid = await paidSinceStart();
        if (paid != null) {
          lastErrorMessage = paid;
          aborted = true;
          break;
        }
        // 기다리는 사이 정지를 눌렀거나 연결이 끊겼을(계정 전환 등) 수 있다
        if (batchRemaining <= 0 || !isApiConnected) {
          aborted = true;
          break;
        }

        // context가 죽어도 handleGenerate 내부에서 (context.mounted ? context : null)로
        // 안전 처리되므로, 여기서는 의도적으로 mounted 가드 없이 넘긴다.
        final GenerateOutcome outcome = await handleGenerate(
          // ignore: use_build_context_synchronously
          context,
          onScrollToHistoryEnd,
          samples: samples,
        );
        _notifyTick(samples); // 진행 알림 (설정이 켜져 있을 때만) — 한 번에 여러 장이면 그 장수만큼 시도
        // 다시 해도 같을 오류면 바로, 일시 오류면 연속 몇 번째에 멈춘다.
        //  메시지는 화면에 남는다 (다음 장을 시작하지 않으니 지워지지 않는다).
        if (outcome == GenerateOutcome.ok) {
          failStreak = 0;
        } else if (outcome == GenerateOutcome.stop || ++failStreak >= _kBatchFailLimit) {
          _noteBatchStopped(outcome == GenerateOutcome.retryable ? failStreak : 0);
          aborted = true;
          break;
        }

        // 사용자 정지 감지: cancelBatch()가 batchRemaining=0, isBatchMode=false로 만든다.
        // batchRemaining을 보면 유한/무한(batchCount==0) 모두 정확히 잡힌다.
        // (isBatchMode만 보면 무한 생성 시 정지가 감지되지 않아 반복이 계속 돌아버림)
        if (batchRemaining <= 0 || !isBatchMode) {
          aborted = true;
          break;
        }
        // 반복 사이에도 딜레이 (마지막 반복 뒤엔 아래 공통 딜레이가 처리)
        if (r < repeats - 1) {
          notifyListeners();
          await Future.delayed(Duration(milliseconds: (batchDelay * 1000).round()));
          // 딜레이 중에 정지를 눌렀을 수도 있으니 한 번 더 확인
          if (batchRemaining <= 0 || !isBatchMode) {
            aborted = true;
            break;
          }
        }
      }
      if (aborted) {
        break;
      }

      if (count != 0) {
        batchRemaining--;
      }

      // 다음 생성이 남아있을 때만 다음 프롬프트로 전환 (마지막 생성 뒤엔 넘기지 않음).
      // → 넘기면 인덱스가 앞서가서 다음 배치가 겹치게 됨.
      if (batchRemaining <= 0) {
        break;
      }
      if (autoNextPromptInBatch) {
        handleNextPrompt();
      }
      notifyListeners();

      // 다음 생성 전 잠깐 대기 (서버 부하 방지)
      await Future.delayed(Duration(milliseconds: (batchDelay * 1000).round()));
    }
  }

  /// 연속 생성을 오류로 멈출 때 — 화면의 오류 메시지 끝에 멈췄다는 말을 붙인다 (한 장 생성이면 붙이지 않는다).
  ///  [streak] 이 0 보다 크면 일시 오류가 그만큼 연속이라 멈춘 것.
  void _noteBatchStopped(int streak) {
    final String? msg = lastErrorMessage;
    if (!isBatchMode || msg == null) {
      return;
    }
    lastErrorMessage = streak > 0
        ? "$msg\n\n$streak번 연속 실패해서 연속 생성을 멈췄어요."
        : "$msg\n\n연속 생성을 멈췄어요.";
  }

  // [추가] 엄격한 뮤텍스 잠금을 위한 변수 선언
  bool _isInpaintProcessing = false;

  // i2i와 인페인트는 흐름이 거의 같다(같은 입력창·같은 뮤텍스·같은 결과 처리).
  //  예전에는 170줄짜리 함수 두 벌이라 한쪽만 고치면 다른 쪽이 어긋나기 쉬웠다.
  //  차이나는 부분(마스크·action·강도·캐릭터 전송)만 매개변수로 받고 하나로 합쳤다.
  Future<void> _runI2iPipeline(
    BuildContext context, {
    required String action, // "img2img" 또는 "infill"
    required String errorTitle,
    required String resultSource,
    Uint8List? maskBytes,
    bool sendCharacters = true,
    // 확장(빈칸 채우기)으로 새로 짠 판 — 주면 지금 그림 · 보낼 계획 대신 이 그림을 이 크기로 보낸다
    ({Uint8List image, int w, int h})? canvas,
    // 인페인트 강도를 이 값으로 (null 이면 설정값 — 확장은 늘 1)
    double? infillStrengthOverride,
    // 받은 결과를 작업 그림 · 릴에 넣기 전에 다듬는다 (부분 인페인트 — 줄여서 원본에 붙인다). null 을 돌려주면 실패.
    Future<Uint8List?> Function(Uint8List result)? finishResult,
    // 결과가 작업 그림으로 바뀔 때 마스크를 어떻게 할지 (null 이면: 판을 새로 짰으면 지운다 · 아니면 인페인트 설정대로)
    I2iMaskAction? resultMaskAction,
  }) async {
    // 뮤텍스: 앞선 작업이 진행 중이면 중복 클릭을 무시한다
    if (_isInpaintProcessing) {
      debugPrint('이미 처리 중입니다. 중복 요청을 무시합니다.');
      return;
    }

    if (!isApiConnected) {
      if (context.mounted) {
        showToast(context, "설정 탭에서 API 키를 먼저 연결해주세요.");
      }
      return;
    }
    if (targetI2iImage == null) {
      if (context.mounted) {
        showToast(context, "히스토리 탭에서 이미지를 먼저 선택해주세요.");
      }
      return;
    }
    // 판을 새로 짰으면 그 크기 그대로 (이미 64 의 배수 · 상한 안 — 같은 규칙으로 한 번 더 거른다)
    final plan = canvas != null
        ? _planForNai(canvas.w, canvas.h, modelCapsFor(selectedModel).maxPixels)
        : i2iSendPlan;
    if (plan == null) {
      if (context.mounted) {
        showToast(context, "이미지 크기를 읽지 못했습니다.");
      }
      return;
    }

    _isInpaintProcessing = true;
    isInpaintLoading = true;
    _otherSpendSerial++; // 무료 연속 생성 지킴이가 이 Anlas 를 배치 탓으로 보지 않게
    inpaintStatusMessage = "연결 중...";
    lastErrorMessage = null;
    notifyListeners();

    bool held = false; // 백그라운드를 붙잡았는지 (붙잡은 경우에만 놓는다)
    try {
      if (!isSeedLocked || seedController.text.isEmpty) {
        seedController.text = Random().nextInt(4294967296).toString();
      }

      unawaited(saveAllSettings()); // 생성과 병렬 저장

      // 서버에 보낼 크기 (64 의 배수) — 그림은 plan.w×plan.h 로 두고 나머지를 채워 보낸다 (i2iSendPlan)
      final int width = plan.sendW;
      final int height = plan.sendH;

      // i2i 탭의 프롬프트 입력란을 그대로 사용 (인페인트와 공유)
      //  잇고 보내기 직전 마무리까지 — 생성과 똑같은 단계를 거친다 (_joinForSend 참고)
      final String finalPrompt = _joinForSend(
        _processWildcards(inpaintPrefixController.text),
        _processWildcards(inpaintPositiveController.text),
        _processWildcards(inpaintSuffixController.text),
      );
      // 실행 시점의 활성 캐릭터를 그대로 전송 (인페인트는 캐릭터를 보내지 않는다)
      final List<Map<String, dynamic>> processedCharacters = sendCharacters
          ? characters
                .where((char) => char.isActive)
                // 모델 상한을 넘으면 서버가 거부한다 (V4.5=6, V5=32)
                .take(modelCapsFor(selectedModel).maxCharacters)
                .map((char) {
                  return _characterForSend(char);
                })
                .toList()
          : <Map<String, dynamic>>[];
      // 부정은 i2i 에서 보낼 긍정 · 캐릭터를 보고 마무리한다 (예전엔 프롬프트탭의 글을 봤다)
      final String finalNegative = _finishNegative(
        inpaintNegativeController.text,
        sentPositive: _sentPositiveOf(finalPrompt, processedCharacters),
      );

      await _holdBackground();
      held = true;

      final result = await _service.generateImage(
        positive: finalPrompt,
        negative: finalNegative,
        token: apiToken,
        model: selectedModel,
        steps: effectiveSteps,
        sampler: selectedSampler,
        scheduler: schedulerFor(selectedModel), // V5 잠금은 여기서 (설정 '스케줄러 잠금 해제')
        width: width,
        height: height,
        cfgScale: double.tryParse(cfgScaleController.text) ?? 6.0,
        cfgRescale: double.tryParse(cfgRescaleController.text) ?? 0.0,
        seed: int.tryParse(seedController.text) ?? 0,
        characters: processedCharacters,
        mediumEffort: effortMediumActive, // V5 Full Medium (인페인트는 보내는 쪽이 -inpainting 을 붙인다)
        image: canvas?.image ?? targetI2iImage,
        mask: maskBytes,
        action: action,
        // 새로 짠 판은 NovelAI 가 만든 PNG 가 아니다 — 3채널 PNG 로 다시 맞춰 보낸다
        imageFromNovelAi: canvas == null && targetI2iMetadata != null,
        contentWidth: plan.w, // 결과는 이 크기로 잘라 돌려받는다
        contentHeight: plan.h,
        img2imgStrength: img2imgStrength,
        img2imgNoise: img2imgNoise,
        infillStrength: infillStrengthOverride ?? infillStrength,
        // 모델이 미지원이면 VAR+는 전송하지 않는다
        variancePlus: isVariancePlus && modelCapsFor(selectedModel).supportsVarietyPlus,
        // 투명 배경 (모델이 지원할 때만)
        transparentBackground: transparentBackground,
        useCharacterPosition: useCharacterPosition,
        randomCharacterOrder: randomCharacterOrder,
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
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  Text(
                    errorTitle,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Text(result.error!, style: const TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text("닫기", style: TextStyle(color: AppColors.accent)),
                ),
              ],
            ),
          );
        }
      } else if (result.image != null) {
        Uint8List image = result.image!;
        // 결과 다듬기 (부분 인페인트 — 받은 그림을 줄여 원본에 붙인다)
        bool finished = true;
        if (finishResult != null) {
          inpaintStatusMessage = "원본에 붙이는 중...";
          notifyListeners();
          final Uint8List? done = await finishResult(image);
          if (done != null) {
            image = done;
          } else {
            finished = false;
          }
        }
        final NaiMetadata? parsedMeta = extractNovelAIMetadata(image);

        // ⚠️ 순서 중요: 마스크 처리 방식/이미지 전환을 먼저 정한 뒤 addI2iResult를 호출한다.
        //    addI2iResult가 notifyListeners()를 부르므로, 그 전에 상태가 정해져 있어야
        //    i2i_tab build가 올바르게 판단한다.
        if (!finished) {
          // 붙이지 못했다 — 받은 그림(잘라 보낸 크기)만 릴에 넣는다 (Anlas 를 쓴 결과라 버리지 않는다).
          //  작업 그림은 바꾸지 않는다 — 크기가 달라 칠해 둔 마스크 · 상자가 어긋난다.
          if (context.mounted) {
            showToast(context, "결과를 원본에 붙이지 못해, 받은 그림만 결과 목록에 넣었어요.");
          }
        } else if (!inpaintNoAutoSwitch) {
          // 결과를 작업 이미지로 자동 전환 → 이미지 변경 시 자동 해제 설정을 따라 마스크 처리
          //  확장의 결과는 판 크기의 새 그림이라, 원래 그림 위에 칠해 둔 마스크가 맞지 않는다 → 지운다
          //  (부분 인페인트는 판을 짜 보내지만 결과는 원래 크기라 인페인트처럼 — resultMaskAction)
          i2iMaskActionOnChange =
              resultMaskAction ??
              (canvas != null ? I2iMaskAction.clearMask : I2iMaskAction.followInpaintSetting);
          targetI2iImage = image;
          targetI2iMetadata = parsedMeta;
          recordI2iView(image, parsedMeta); // 본 이미지 기록 추가
        } else if (inpaintAutoClearMask) {
          // 자동 전환은 안 하지만 자동 해제는 ON → 이미지는 그대로 두고 마스크만 즉시 해제
          i2iMaskClearRevision++;
        }
        // (자동 전환 OFF + 자동 해제 OFF → 아무것도 안 함, 마스크 유지)

        // 결과는 메인 히스토리 대신 i2i 스크래치 릴로 (여기서 notifyListeners 발생)
        addI2iResult(image, parsedMeta, source: resultSource);
      }

      // 잔액·한도 갱신은 기다리지 않는다 (버튼이 그만큼 늦게 풀린다)
      refreshBalanceInBackground();
    } catch (e) {
      debugPrint('$action 파이프라인 에러: $e');
    } finally {
      // 백그라운드 실행 해제 (붙잡았으면 반드시 놓는다 — 알림이 남지 않도록)
      if (held) {
        await _releaseBackground();
      }
      // 성공/실패 여부와 관계없이 반드시 락 해제
      _isInpaintProcessing = false;
      isInpaintLoading = false;
      _otherSpendSerial++; // 끝 — 무료 연속 생성 지킴이가 기준을 다시 잡게 (오류로 끝나도)
      inpaintStatusMessage = "";
      notifyListeners();
    }
  }

  /// i2i 생성 — 원본 이미지를 참고해 다시 그린다.
  Future<void> handleImg2ImgGenerate(BuildContext context) {
    return _runI2iPipeline(
      context,
      action: "img2img",
      errorTitle: "img2img 생성 오류",
      resultSource: I2iMode.img2img.id,
    );
  }

  /// 인페인트 생성 — 마스크로 칠한 부분만 다시 그린다.
  Future<void> handleInpaintGenerate(BuildContext context, Uint8List maskBytes) {
    return _runI2iPipeline(
      context,
      action: "infill",
      errorTitle: "인페인트 생성 오류",
      resultSource: I2iMode.inpaint.id,
      maskBytes: maskBytes,
      sendCharacters: false, // 인페인트는 캐릭터를 보내지 않는다
    );
  }

  /// 확장(빈칸 채우기) — 판 위로 옮기고 돌린 그림([image], [width]×[height])의 빈칸을 인페인트로 채운다.
  ///  판 · 마스크는 i2i 탭이 만든다 (lib/models/outpaint.dart 의 composeOutpaint).
  ///  강도는 늘 1 — 빈칸엔 원본이 없다 (kOutpaintStrength). 결과는 인페인트 결과처럼 릴에 쌓인다.
  Future<void> handleOutpaintGenerate(
    BuildContext context,
    Uint8List image,
    Uint8List maskBytes,
    int width,
    int height,
  ) {
    return _runI2iPipeline(
      context,
      action: "infill",
      errorTitle: "확장 오류",
      resultSource: I2iMode.inpaint.id,
      maskBytes: maskBytes,
      sendCharacters: false,
      canvas: (image: image, w: width, h: height),
      infillStrengthOverride: kOutpaintStrength,
    );
  }

  /// 부분 인페인트 — 상자 부분만 잘라 키운 그림([crop], 보낼 크기)을 인페인트하고, 결과를 줄여 원본([original])의
  ///  다시 그린 칸에만 붙인다 (lib/models/focus_inpaint.dart). 마스크 · 잘라 키우기는 i2i 탭이 만든다.
  ///  결과는 원래 크기의 새 그림 — 인페인트처럼 작업 그림 · 릴로 (마스크는 인페인트 설정대로).
  Future<void> handleFocusInpaintGenerate(
    BuildContext context, {
    required Uint8List original,
    required Uint8List crop,
    required Uint8List mask,
    required FocusPlan plan,
  }) {
    return _runI2iPipeline(
      context,
      action: "infill",
      errorTitle: "부분 인페인트 오류",
      resultSource: I2iMode.inpaint.id,
      maskBytes: mask,
      sendCharacters: false, // 인페인트는 캐릭터를 보내지 않는다
      canvas: (image: crop, w: plan.sendW, h: plan.sendH),
      resultMaskAction: I2iMaskAction.followInpaintSetting,
      finishResult: (Uint8List result) async {
        try {
          return await compute(
            composeFocusResult,
            (original: original, result: result, mask: mask, plan: plan),
          );
        } catch (e) {
          debugPrint('부분 인페인트 결과 붙이기 실패: $e');
          return null;
        }
      },
    );
  }

  Future<void> handleUpscaleGenerate(BuildContext context) async {
    if (!isApiConnected) {
      if (!context.mounted) {
        return;
      }
      showToast(context, "설정 탭에서 API 키를 먼저 연결해주세요.");
      return;
    }
    // 지금 그림과 그 정보를 '누른 순간' 것으로 잡아 둔다 — 확인 창이 떠 있는 사이나 업스케일하는 동안
    //  (수 초~수십 초) 릴에서 다른 그림을 고르거나 히스토리 · 갤러리에서 보내 오면 지금 그림이 바뀐다.
    //  끝난 뒤에 '지금' 정보를 읽으면 결과에 엉뚱한 그림의 프롬프트 · 시드가 붙었다 (DEVNOTES 5).
    // 새 업스케일러는 크기 정보를 받지 않아, 메타데이터가 없는 그림(밖에서 가져온 그림)도 된다
    final Uint8List? src = targetI2iImage;
    final NaiMetadata? srcMeta = targetI2iMetadata;
    if (src == null) {
      if (!context.mounted) {
        return;
      }
      showToast(context, "히스토리 탭에서 이미지를 먼저 선택해주세요.");
      return;
    }

    // ⚠️ 예전엔 여기서 '1024×1024 이하만' 을 막았다. 그건 옛 업스케일러의 제한이었고,
    //    지금의 V5 업스케일러는 공개된 크기 제한이 없다(NovelAI 웹도 막지 않는다).
    //    앱이 옛 기준으로 막으면 오히려 쓸 수 있는 그림을 못 쓰게 되므로,
    //    크기는 서버가 판단하게 두고 거절되면 그 메시지를 그대로 보여 준다.

    // 확인 창을 끈 경우(설정 — skipAnlasConfirm) 묻지 않는다 (실행 버튼의 빨간 테두리가 대신 알린다)
    final bool proceed = skipAnlasConfirm || await showConfirmDialog(
      context,
      title: "업스케일 진행",
      message:
          "업스케일(${NovelAiService.upscaleScale}배)을 진행합니다.\n${anlasText(anlasFor(AnlasJob.upscale))}\n\n계속 진행하시겠습니까?",
      confirmLabel: "업스케일 시작",
      icon: Icons.high_quality,
      iconColor: AppColors.amber,
      confirmColor: Colors.amber[700],
    );

    if (!proceed) {
      return;
    }

    if (!context.mounted) {
      return;
    }

    isUpscaleLoading = true;
    _otherSpendSerial++; // 무료 연속 생성 지킴이가 이 Anlas 를 배치 탓으로 보지 않게
    lastErrorMessage = null;
    notifyListeners();

    // 업스케일은 오래 걸린다 — 도중에 앱을 내려도 끊기지 않게 (예전엔 없었다)
    await _holdBackground();
    try {
      final result = await _service.upscaleImage(image: src, token: apiToken);

      isUpscaleLoading = false;

      if (result.error != null) {
        if (!context.mounted) {
          return;
        }
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
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
                child: Text(
                  "닫기",
                  style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
      } else if (result.image != null) {
        // ⚠️ 배율을 가정하지 않고 결과 그림의 실제 크기를 읽는다.
        //    예전엔 'width * 4' 로 적어서, 배율이 2배로 바뀐 뒤엔 틀린 크기가 기록될 뻔했다.
        final (outW, outH) = await readImageSize(result.image!) ?? (0, 0);
        NaiMetadata? parsedMeta;
        if (srcMeta != null) {
          parsedMeta = NaiMetadata(
            positive: srcMeta.positive,
            negative: srcMeta.negative,
            characterPrompts: srcMeta.characterPrompts,
            characterUndesiredContents: srcMeta.characterUndesiredContents,
            characterCenters: srcMeta.characterCenters, // 다시 생성 · 불러오기에서 위치가 살게
            width: outW > 0 ? outW : srcMeta.width * NovelAiService.upscaleScale,
            height: outH > 0 ? outH : srcMeta.height * NovelAiService.upscaleScale,
            seed: srcMeta.seed,
            steps: srcMeta.steps,
            sampler: srcMeta.sampler,
            promptGuidance: srcMeta.promptGuidance,
            promptGuidanceRescale: srcMeta.promptGuidanceRescale,
            undesiredContentStrength: srcMeta.undesiredContentStrength,
            source: srcMeta.source,
            extraParams: srcMeta.extraParams,
          );
        } else {
          parsedMeta = extractNovelAIMetadata(result.image!);
        }

        // 업스케일 결과도 i2i 스크래치 릴로
        addI2iResult(result.image!, parsedMeta, source: I2iMode.upscale.id);
      }

      // 잔액·한도 갱신은 기다리지 않는다 (버튼이 그만큼 늦게 풀린다)
      refreshBalanceInBackground();
    } finally {
      await _releaseBackground();
      isUpscaleLoading = false;
      _otherSpendSerial++; // 끝 — 무료 연속 생성 지킴이가 기준을 다시 잡게 (오류로 끝나도)
      notifyListeners();
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Director Tools
  // ══════════════════════════════════════════════════════════════

  // ══════════════════════════════════════════════════════════════
  // 프롬프트 되돌리기 기록
  // ══════════════════════════════════════════════════════════════
  //
  // 확대 입력창에서 내용을 통째로 갈아엎기 전의 상태를 입력창별로 남긴다.
  //  예: 그림체 프롬프트를 써 둔 채 "이 작가는 어떻게 그려질까?" 하고
  //      전부 지운 뒤 하나만 시험해 보는 흐름. 예전에는 원래 내용을 직접
  //      복사해 두거나 프리셋에 저장해야 했다.
  //
  // key 는 입력창 이름(title). 최신 기록이 리스트 앞에 온다.
  Map<String, List<String>> promptUndoHistory = {};

  /// 한 입력창이 기억하는 최대 개수.
  // 입력창마다 남기는 되돌리기 기록 수.
  //  창을 열 때 '지금 글'도 한 칸 차지하므로, 실제로 돌아갈 수 있는 곳은 이보다 하나 적다.
  //  (3 이던 때는 돌아갈 곳이 2개뿐이었다 → 4: 지금 + 이전 3개)
  static const int kPromptUndoLimit = 4;

  /// [title] 입력창의 현재 내용을 되돌리기 기록에 넣는다.
  ///
  /// 내용이 통째로 바뀌기 '직전'에 부른다. 타이핑마다 부르면 안 된다.
  ///  · 빈 내용은 되돌릴 가치가 없어 넣지 않는다
  ///  · 맨 앞 기록과 같으면 중복이므로 넣지 않는다
  void pushPromptUndo(String title, String text) {
    final t = text.trim();
    if (t.isEmpty) {
      return;
    }
    final list = promptUndoHistory[title] ?? <String>[];
    // ⚠️ 같은 글은 기록에 한 번만 — 이미 있으면 빼고 맨 앞으로 다시 넣는다.
    //    예전엔 '맨 앞과 같을 때만' 건너뛰어서, 떨어진 자리에 같은 글이 쌓였다.
    //    그러면 목록에 '바로 전'과 '2번 전'이 똑같이 보이고 칸만 차지했다.
    //    (앞뒤 공백만 다른 글도 같은 글로 본다)
    list.removeWhere((e) => e.trim() == t);
    list.insert(0, text);
    while (list.length > kPromptUndoLimit) {
      list.removeLast();
    }
    promptUndoHistory[title] = list;
    // 저장은 부르는 쪽이 한다 (버튼은 saveAndRefresh, 창을 열 때 남긴 기록은 창을 닫을 때).
    //  여기서도 저장하면 버튼 한 번에 설정 전체를 두 번 쓴다.
  }

  /// 없어진 입력창의 되돌리기 기록 — 저장소 · 백업에서 읽을 때 버린다 (설정 파일만 불어난다)
  static const List<String> _obsoleteUndoKeys = [
    'prompt/가중치 규칙 (콤마/줄바꿈 구분)', // 3.14.0 가중치 규칙 삭제
  ];

  void _dropObsoleteUndo() {
    for (final k in _obsoleteUndoKeys) {
      promptUndoHistory.remove(k);
    }
  }

  /// [title] 입력창의 되돌리기 기록. 최신이 앞.
  List<String> promptUndoList(String title) => promptUndoHistory[title] ?? const [];

  /// 되돌리기 기록을 비운다.
  void clearPromptUndo(String title) {
    promptUndoHistory.remove(title);
    saveAllSettings();
  }

  /// 중첩 가중치를 보내기 직전에 펼칠지. 기본 OFF.
  ///
  /// NovelAI 는 숫자 없는 `::` 를 만나면 앞의 가중치를 전부 끝내 버린다.
  /// 켜 두면 `5.0::A, 1.5::B ::, C ::,` 를
  /// `5.0::A, 1.5::B ::, 5.0::C ::,` 로 바꿔 보낸다.
  ///
  /// 입력한 프롬프트 자체는 건드리지 않는다 — 전송분에만 적용된다.
  ///  ⚠️ 설명은 '기본 OFF' 였는데 선언·불러오기·가져오기 세 곳 모두 true 였다 (새로 설치하면 켜져 있었다).
  bool expandNestedWeightsEnabled = false;

  /// 캐릭터 하나를 '보낼 모양'으로 만든다 (생성·i2i 공통).
  ///  ⚠️ 예전엔 두 경로에 똑같은 17줄이 따로 있어서, 한쪽만 고치면 동작이 갈렸다.
  ///     (임시 프롬프트·중첩 가중치를 넣을 때 실제로 i2i 쪽을 빠뜨린 적이 있다)
  Map<String, dynamic> _characterForSend(NaiCharacter char) {
    final Map<String, dynamic> charJson = char.toJson();
    // 임시 프롬프트는 원본 뒤에 붙인다. char.positive 자체는 건드리지 않는다
    //  — 화면의 원본은 그대로 두고 '이번 전송분'에만 더하는 기능이다.
    if (char.tempActive) {
      final String base = char.positive.trim();
      final String temp = char.tempPositive.trim();
      // 둘 사이에만 쉼표 — 경계가 가중치 표시(1.1:: · ::)에 닿으면 넣지 않는다 (구획 잇기와 같은 규칙)
      charJson['positive'] = base.isEmpty || temp.isEmpty
          ? '$base$temp'
          : '$base${weightTouchesBoundary(base, temp) ? '' : ', '}$temp';
    }
    // ⚠️ 사용자가 쓴 글의 쉼표는 건드리지 않는다 (예전엔 '::' 앞뒤 쉼표를 지워 '1.2::a, ::' 가 바뀌어 나갔다)
    if (charJson.containsKey('positive')) {
      charJson['positive'] = _maybeExpandWeights(
        _processWildcards(charJson['positive'].toString()),
      );
    }
    if (charJson.containsKey('negative')) {
      charJson['negative'] = _maybeExpandWeights(
        _processWildcards(charJson['negative'].toString()),
      );
    }
    return charJson;
  }

  /// 선행 · 긍정 · 후행을 이어 보내기 직전 모양으로 (생성 · i2i 공통).
  ///  성별 focus 는 잇기 '전에' 긍정 맨 앞으로 모은다 — 이은 뒤엔 어디까지가 긍정인지 모른다.
  ///  인원수 · solo 는 이은 뒤 맨 앞으로 (_finishPositive → _hoistCountTags).
  ///  → '1girl, solo, (선행), female focus, (긍정 나머지), (후행)'
  String _joinForSend(String prefix, String positive, String suffix) {
    final s = ignoreRecommendedOrder
        ? (prefix: prefix, positive: positive, suffix: suffix)
        : moveGenderFocusToPositive(prefix, positive, suffix);
    return _finishPositive(_service.joinPromptSections([s.prefix, s.positive, s.suffix]));
  }

  /// 합친 긍정 프롬프트를 보내기 직전 모양으로 마무리한다 (생성·i2i 공통).
  ///  순서: 인원수를 앞으로 → 품질 태그 → 중첩 가중치 펼치기 (3.14.0 에 가중치 규칙을 뺐다)
  ///  (구획 경계에 걸친 가중치는 잇는 단계(joinPromptSections)가 이미 쉼표 없이 붙여 두어, 뒤 단계들이 제대로 알아본다)
  ///  ⚠️ 예전엔 맨 앞에서 '::' 앞뒤 쉼표를 전부 지워(tidyWeightMarkers), 사용자가 쓴 '1.2::test, ::' 까지
  ///     '1.2::test::' 로 바뀌어 나갔다. 이제 사용자가 쓴 쉼표는 그대로 보낸다.
  String _finishPositive(String joined) => _maybeExpandWeights(
    applyQualityTags(_hoistCountTags(joined)),
  );

  /// 부정 프롬프트를 보내기 직전 모양으로 (생성·i2i 공통).
  ///  [sentPositive] 는 실제로 보낼 긍정 · 캐릭터 글 (_sentPositiveOf) — UC 프리셋이 nsfw 를 넣을지 본다.
  ///  Medium effort 는 공식이 부정 프롬프트를 잠근다 — 쓴 부정 · 고른 UC 프리셋 대신 Heavy 프리셋만
  ///  (긍정에 nsfw 가 없으면 앞에 nsfw — 보통 프리셋과 같은 규칙). 캐릭터 부정은 보내는 쪽이 비운다.
  String _finishNegative(String raw, {required String sentPositive}) => effortMediumActive
      ? applyUcPreset('', positive: sentPositive, preset: 'Heavy')
      : _maybeExpandWeights(
          applyUcPreset(_service.sanitizePrompt(_processWildcards(raw)), positive: sentPositive),
        );

  /// 실제로 보낼 긍정 + 캐릭터 긍정 (nsfw 확인용)
  static String _sentPositiveOf(String finalPrompt, List<Map<String, dynamic>> chars) => [
    finalPrompt,
    for (final c in chars) (c['positive'] ?? '').toString(),
  ].join(', ');

  /// 설정이 켜져 있을 때만 중첩 가중치를 펼친다.
  ///  전송 직전에 한 번만 통과시키면 되므로 조립이 끝난 문자열에 적용한다.
  String _maybeExpandWeights(String text) =>
      expandNestedWeightsEnabled ? expandNestedWeights(text) : text;

  /// 지금 고른 Director 도구 (req_type). 5곳 패턴으로 저장된다.
  String directorTool = 'bg-removal';

  /// 도구가 도는 중인지. 실행 버튼을 잠그는 데 쓴다.
  bool isDirectorLoading = false;

  // ── i2i 그림 크기 (인페인트·img2img·Director·캔버스 공용) ──
  //  메타데이터가 없는 그림(밖에서 가져온 그림·Director 결과)은 파일 머리에서 읽고,
  //  같은 그림이면 한 번 읽은 값을 쓴다 (화면을 그릴 때마다 불린다).
  Uint8List? _sizedImage;
  (int, int)? _sizedImageWH;

  /// 지금 i2i 그림의 크기 — 그림 정보가 있으면 그 크기, 없으면 파일 머리에서 읽은 크기. 그림이 없으면 null.
  (int, int)? get i2iImageSize {
    final Uint8List? image = targetI2iImage;
    if (image == null) {
      return null;
    }
    final meta = targetI2iMetadata;
    if (meta != null && meta.width > 0 && meta.height > 0) {
      return (meta.width, meta.height);
    }
    if (!identical(_sizedImage, image)) {
      _sizedImage = image;
      _sizedImageWH = imageSizeFromHeader(image);
    }
    return _sizedImageWH;
  }

  /// 인페인트·img2img 로 보낼 계획 — 그림을 둘 크기(w·h)와 서버에 보낼 크기(sendW·sendH).
  ///  · 보낼 크기는 64 의 배수이고 모델 픽셀 상한 이하 (서버 규칙).
  ///  · 그림은 늘이거나 누르지 않는다. 64 의 배수까지 모자란 오른쪽·아래는 채워 보내고,
  ///    결과에서 그만큼 잘라내 '둘 크기'로 돌려받는다 (NovelAiService 의 _processImage3Channel·
  ///    _cropResultToContent). 그래서 상한 안쪽 그림은 원래 해상도 그대로 돌아온다.
  ///  · 상한을 넘는 그림(폰 사진 등)만 비율을 지켜 줄인다 — 이때 결과도 줄인 크기다.
  ///  NovelAI 그림(64 의 배수)은 둘 크기 = 보낼 크기라 아무것도 바뀌지 않는다.
  ///  ⚠️ 예전엔 그림 정보(메타데이터)가 없으면 인페인트·img2img 를 아예 막았다.
  ///     정보에서 쓰는 건 크기뿐이라(프롬프트는 i2i 탭 입력창), 크기만 알면 된다.
  ({int w, int h, int sendW, int sendH})? get i2iSendPlan {
    final size = i2iImageSize;
    if (size == null) {
      return null;
    }
    return _planForNai(size.$1, size.$2, modelCapsFor(selectedModel).maxPixels);
  }

  /// 서버에 보낼 크기 (i2iSendPlan 의 sendW·sendH) — Anlas 는 이 크기로 센다.
  (int, int)? get i2iSendSize {
    final plan = i2iSendPlan;
    return plan == null ? null : (plan.sendW, plan.sendH);
  }

  static int _ceil64(int v) => max(64, ((v + 63) ~/ 64) * 64);

  /// [w]×[h] 그림의 보낼 계획. 64 의 배수로 올려 채운 크기가 [maxPixels] 를 넘을 때만
  ///  비율을 지켜 줄인다 (키우지는 않는다).
  ///   예) 1080×1920 → 그대로 두고 1088×1920 으로 채워 보냄 → 결과 1080×1920
  ///       3024×4032 → 1536×2048 로 줄여 보냄(채울 것 없음) → 결과 1536×2048
  ///       3840×2160 → 2294×1290 으로 줄여 2304×1344 로 채워 보냄 → 결과 2294×1290
  static ({int w, int h, int sendW, int sendH}) _planForNai(int w, int h, int maxPixels) {
    bool fits(int a, int b) => maxPixels <= 0 || _ceil64(a) * _ceil64(b) <= maxPixels;
    int cw = w;
    int ch = h;
    if (!fits(cw, ch)) {
      double s = min(1.0, sqrt(maxPixels / (w * h))); // 키우지 않는다
      do {
        cw = max(1, (w * s).floor());
        ch = max(1, (h * s).floor());
        s *= 0.995; // 채운 크기가 상한을 넘으면 조금씩 더 줄인다 (보통 한두 번)
      } while (!fits(cw, ch) && cw > 1 && ch > 1);
    }
    return (w: cw, h: ch, sendW: _ceil64(cw), sendH: _ceil64(ch));
  }

  /// 지금 고른 이미지 기준으로 Director 도구의 예상 Anlas 를 돌려준다.
  ///  0 이면 소모 없음(Opus 무료 범위), -1 이면 계산 불가(너무 큼).
  int directorCostFor(String reqType) {
    // ⚠️ Director 칩을 그릴 때마다(칩 4개 × 2번) 불린다 — 크기는 i2iImageSize 가 한 번만 잰다.
    //    (예전엔 여기서 그림을 통째로 풀어 쟀다)
    final (w, h) = i2iImageSize ?? (0, 0);
    if (w <= 0 || h <= 0) {
      return 0; // 크기를 모르면 경고를 띄우지 않는다 (실행 단계에서 다시 검사한다)
    }
    return directorToolCost(reqType: reqType, width: w, height: h, tier: subscriptionTier);
  }

  void setDirectorTool(String reqType) {
    directorTool = reqType;
    saveAllSettings();
    notifyListeners();
  }

  /// 선택한 이미지에 Director 도구를 적용한다.
  ///
  /// 결과는 i2i 결과 릴에 쌓인다. 배경 제거는 3장이 한 번에 들어간다.
  Future<void> handleDirectorTool(BuildContext context) async {
    if (isDirectorLoading) {
      return; // 연타 방지 — 느린 도구라 특히 중요하다
    }
    if (apiToken.isEmpty) {
      showToast(context, "설정 탭에서 API 키를 먼저 연결해주세요.");
      return;
    }
    if (targetI2iImage == null) {
      showToast(context, "히스토리 탭에서 이미지를 먼저 선택해주세요.");
      return;
    }

    // 크기는 메타데이터가 있으면 그걸 쓰고, 없으면 파일 머리에서 읽는다 (i2iImageSize)
    final size = i2iImageSize;
    if (size == null) {
      showToast(context, "이미지 크기를 읽지 못했습니다.");
      return;
    }
    final (width, height) = size;

    final tool = directorToolFor(directorTool);
    isDirectorLoading = true;
    _otherSpendSerial++; // 무료 연속 생성 지킴이가 이 Anlas 를 배치 탓으로 보지 않게
    lastErrorMessage = null;
    notifyListeners();

    // 느린 도구라 도중에 앱을 내리기 쉽다 — 끊기지 않게 (예전엔 없었다)
    await _holdBackground();
    try {
      final result = await _service.runDirectorTool(
        image: targetI2iImage!,
        width: width,
        height: height,
        token: apiToken,
        reqType: tool.reqType,
      );

      if (result.error != null) {
        lastErrorMessage = result.error;
        if (context.mounted) {
          showToast(context, result.error!, length: ToastLength.long);
        }
        return;
      }

      if (result.images.isEmpty) {
        if (context.mounted) {
          showToast(context, "결과를 받지 못했습니다.");
        }
        return;
      }

      // ⚠️ 순서 중요: 이미지 전환을 먼저 정한 뒤 addI2iResult 를 호출한다.
      //    addI2iResult 가 notifyListeners() 를 부르므로,
      //    그 전에 상태가 정해져 있어야 i2i_tab build 가 올바르게 판단한다.
      //    (인페인트 파이프라인과 같은 규칙)
      if (!inpaintNoAutoSwitch) {
        // 결과를 작업 이미지로 자동 전환.
        //  배경 제거는 3장이지만 첫 장(Masked)으로 바꾼다.
        //  나머지는 릴에 남아 있으니 눌러서 바꿔 볼 수 있다.
        final first = result.images.first;
        final firstMeta = extractNovelAIMetadata(first);
        i2iMaskActionOnChange = I2iMaskAction.followInpaintSetting;
        targetI2iImage = first;
        targetI2iMetadata = firstMeta;
        recordI2iView(first, firstMeta); // 본 이미지 기록 추가
      } else if (inpaintAutoClearMask) {
        // 전환은 안 하지만 마스크 자동 해제는 ON → 마스크만 즉시 해제
        i2iMaskClearRevision++;
      }

      // 결과를 릴에 넣는다. 배경 제거는 3장이라 배지에 종류를 붙여 구분한다.
      for (int i = 0; i < result.images.length; i++) {
        final bytes = result.images[i];
        final String badge = (tool.multiResult && i < kBgRemovalVariants.length)
            ? '${tool.badge}-${kBgRemovalVariants[i][0]}' // BG-M / BG-G / BG-B
            : tool.badge;
        addI2iResult(bytes, extractNovelAIMetadata(bytes), source: badge);
      }
      // (예전엔 '${tool.label} 완료 — 결과 N장' 알림을 띄웠다 — 결과가 릴에 바로 보여 뺐다. 생성 · 인페인트도 완료 알림은 없다)

      // 도구도 Anlas 를 쓰므로 잔액을 갱신한다 (기다리지는 않는다)
      refreshBalanceInBackground();
    } finally {
      await _releaseBackground();
      isDirectorLoading = false;
      _otherSpendSerial++; // 끝 — 무료 연속 생성 지킴이가 기준을 다시 잡게 (오류로 끝나도)
      notifyListeners();
    }
  }

  // 히스토리 (넣기 · 지우기 · 디스크 저장/불러오기 · 다시 생성)는 app_state_history.dart
  bool isHistoryLoading = true; // 히스토리 로드 중 플래그

  // ===== i2i 스크래치 릴 =====
  // 결과를 릴에 추가 (디스크 저장 안 함 — 스크래치)
  // i2iHistoryDisabled가 켜져 있으면 릴 대신 메인 히스토리에 저장 (기존 동작)
  /// [source] 는 결과 릴에 보일 출처 — 모드 이름(I2iMode.id) 또는 Director 도구 표시.
  void addI2iResult(Uint8List bytes, NaiMetadata? metadata, {String? source}) {
    source ??= I2iMode.inpaint.id;
    if (i2iHistoryDisabled) {
      addImageToHistory(image: bytes, metadata: metadata, forceSave: true);
      return;
    }
    i2iResults.add(I2iResult(bytes: bytes, metadata: metadata, source: source));
    _trimI2iResults();
    unawaited(_saveReelSoon()); // 나온 순간 캐시에 보관 — 앱이 꺼져도 되살아난다
    notifyListeners();
  }

  // 비즐겨찾기 결과가 상한을 넘으면 오래된 것부터 제거 (즐겨찾기는 유지)
  void _trimI2iResults() {
    // 전체(즐겨찾기 포함)가 상한을 넘으면 가장 오래된 '비즐겨찾기'부터 제거.
    // 예: 즐겨찾기 4개면 일반 이미지는 26개까지 = 총 30개.
    while (i2iResults.length > i2iResultsCap) {
      final idx = i2iResults.indexWhere((r) => !r.favorite);
      if (idx < 0) {
        break; // 전부 즐겨찾기 (즐겨찾기 상한 5라 실제로는 도달하지 않음)
      }
      i2iResults.removeAt(idx);
    }
  }

  // ⚠️ 릴 결과는 번호가 아니라 결과(객체)로 받는다 — 즐겨찾기 · 지우기 · 쓰기 · 히스토리로 · 폴더에.
  //  새 결과가 들어와 상한(30)에서 오래된 것이 빠지면 번호가 하나씩(배경 제거는 셋까지) 밀린다.
  //  예전엔 번호로 받아, 꾹 메뉴를 띄운 사이 작업이 끝나면 '내역에서 삭제' 가 옆 결과를 지웠다 —
  //  그게 즐겨찾기면 보관 파일까지 지워져 되살릴 수 없었다 (DEVNOTES 5).

  // 즐겨찾기 토글 (영속 저장)
  // 반환: true=토글됨(또는 이미 릴에서 빠진 결과), false=즐겨찾기 한도(i2iFavoriteCap) 초과로 막힘
  bool toggleI2iFavorite(I2iResult r) {
    if (!i2iResults.contains(r)) {
      return true; // 그 사이 정리된 결과 — 바꿀 것이 없다
    }
    if (!r.favorite) {
      final favCount = i2iResults.where((x) => x.favorite).length;
      if (favCount >= i2iFavoriteCap) {
        return false; // 한도 초과 — 호출 측에서 안내
      }
    }
    r.favorite = !r.favorite;
    // 그림이 한 보관함에서 다른 보관함으로 옮겨 간다 (★ = 즐겨찾기 보관함, 아니면 릴 보관함).
    //  새 자리부터 맞춘다 — 옛 자리는 새 자리에 쓰인 걸 확인한 뒤에야 지운다 (_reelKeep · _favKeep).
    if (r.favorite) {
      unawaited(saveI2iFavorites().then((_) => _saveReelSoon()));
    } else {
      unawaited(_saveReelSoon().then((_) => saveI2iFavorites()));
    }
    notifyListeners();
    return true;
  }

  // 릴에서 결과 삭제 (내역에서 제거) — 그 결과만 (이미 정리됐으면 아무것도 안 한다)
  void removeI2iResult(I2iResult r) {
    final int index = i2iResults.indexOf(r);
    if (index < 0) {
      return;
    }
    final bool wasFav = r.favorite;
    i2iResults.removeAt(index);
    unawaited(wasFav ? saveI2iFavorites() : _saveReelSoon());
    notifyListeners();
  }

  // ── i2i 마스크 처리 방식 (1회용 소비 신호 대신 "상태 기반"으로 관리) ──
  // targetI2iImage를 바꾸는 쪽이 "왜 바꾸는지"를 함께 세팅하고,
  // i2i_tab은 이미지 변경을 감지하면 이 값을 읽어 마스크를 어떻게 할지 결정한다.
  // enum은 소비하지 않으므로(다음 변경 시 덮어써짐) build 타이밍에 안전하다.
  I2iMaskAction i2iMaskActionOnChange = I2iMaskAction.clearMask;

  // 인페인트 마스크 획 목록. 위젯(i2i_tab)이 아니라 여기 보관하여 탭 재생성에도 유지.
  final List<MaskStroke> i2iMaskStrokes = [];

  /// 직전 확장 — i2i 탭이 확장을 보낼 때 남긴다 (보낸 원본 · 자리 · 자르기 · 회전 · 경계 · 판 크기).
  ///  '확장' 꾹이 이걸로 그때 배치 그대로 다시 불러온다 — 결과가 마음에 안 들면 실행만 다시 누르면 된다.
  ///  (예전엔 결과가 작업 그림으로 바뀌는 순간 자리가 지워져, 다시 돌리려면 위치 · 크기 · 회전을 처음부터 맞춰야 했다)
  ///  i2i 탭이 PageView 에서 다시 만들어져도 남게 여기에 둔다. 저장하지 않는다 — 그림이 수 MB 라 앱을 끄면 끝.
  LastOutpaint? lastOutpaint;

  // ── i2i "본 이미지" 기록 (직전 이미지 버튼용) ──
  // 이미지가 바뀔 때마다 본 순서를 기록하고, 버튼으로 한 칸씩 거꾸로 걷는다.
  // 새 이미지 전송(마스크 무조건 초기화 타이밍) 시 기록을 리셋하고 새로 시작.
  final List<({Uint8List bytes, NaiMetadata? meta})> _i2iViewHistory = [];
  int _i2iViewCursor = -1; // 현재 보고 있는 기록 위치
  static const int _i2iViewHistoryMax = 30; // 기록 상한 (오래된 것부터 버림)

  // 본 이미지 기록. reset=true면 기록을 비우고 새 세션 시작 (새 이미지 전송/모자이크).
  // 버튼으로 되돌아간 전환은 이 함수를 부르지 않으므로 기록되지 않는다 (계속 거꾸로 걷기 가능).
  void recordI2iView(Uint8List bytes, NaiMetadata? meta, {bool reset = false}) {
    if (reset) {
      _i2iViewHistory.clear();
      _i2iViewCursor = -1;
    }
    // 지금 보고 있는 것과 같은 이미지는 중복 기록하지 않음
    if (_i2iViewCursor >= 0 && identical(_i2iViewHistory[_i2iViewCursor].bytes, bytes)) {
      return;
    }
    // 커서가 중간이면(되돌아간 상태에서 새 전환) 커서 뒤를 잘라냄 — 브라우저 히스토리 방식
    if (_i2iViewCursor < _i2iViewHistory.length - 1) {
      _i2iViewHistory.removeRange(_i2iViewCursor + 1, _i2iViewHistory.length);
    }
    _i2iViewHistory.add((bytes: bytes, meta: meta));
    if (_i2iViewHistory.length > _i2iViewHistoryMax) {
      _i2iViewHistory.removeAt(0);
    }
    _i2iViewCursor = _i2iViewHistory.length - 1;
  }

  // 직전에 본 이미지로 전환 (기록을 한 칸 뒤로). 더 갈 곳이 없으면 false (무반응).
  bool i2iGoBackView() {
    if (_i2iViewCursor <= 0) {
      return false;
    }
    _i2iViewCursor--;
    final entry = _i2iViewHistory[_i2iViewCursor];
    i2iMaskActionOnChange = I2iMaskAction.keepMask; // 비교 용도의 전환 → 마스크 유지
    targetI2iImage = entry.bytes;
    targetI2iMetadata = entry.meta;
    notifyListeners();
    return true;
  }

  // 앞으로(기록을 한 칸 앞으로) — 뒤로 갔던 것을 되돌린다. 최상위면 false (무반응).
  bool i2iGoForwardView() {
    if (_i2iViewCursor < 0 || _i2iViewCursor >= _i2iViewHistory.length - 1) {
      return false;
    }
    _i2iViewCursor++;
    final entry = _i2iViewHistory[_i2iViewCursor];
    i2iMaskActionOnChange = I2iMaskAction.keepMask; // 비교 용도의 전환 → 마스크 유지
    targetI2iImage = entry.bytes;
    targetI2iMetadata = entry.meta;
    notifyListeners();
    return true;
  }

  // 이미지를 바꾸지 않고 "마스크만 즉시 해제"해야 할 때 쓰는 리비전 카운터.
  // (예: 인페인트 자동전환 OFF + 자동해제 ON) 증가시키면 i2i_tab이 1회만 반영.
  int i2iMaskClearRevision = 0;

  // 릴의 결과를 작업 이미지로 채택 (이어서 인페인트 등) — 누른 그 결과로
  void useI2iResult(I2iResult r) {
    i2iMaskActionOnChange = I2iMaskAction.keepMask; // 릴 탭은 마스킹 유지
    targetI2iImage = r.bytes;
    targetI2iMetadata = r.metadata;
    recordI2iView(r.bytes, r.metadata); // 본 이미지 기록 추가
    notifyListeners();
  }

  /// i2i 비교 보기의 기준을 [bytes] 로 바꾼다 — 비교 보기의 📌 · 릴 결과 꾹 누르기 메뉴 (사용자가 고정).
  ///  [pinned] 가 false 면 이름표가 '원본' 그대로다 (기준이 비어 지금 그림으로 채울 때).
  void setI2iCompareBase(Uint8List bytes, {bool pinned = true}) {
    i2iCompareBase = bytes;
    i2iCompareBasePinned = pinned;
    notifyListeners();
  }

  // 메인 히스토리로 보내기 (디스크 저장 포함) — 고른 그 결과 (메뉴를 띄운 사이 릴에서 정리됐어도 그 그림)
  Future<void> promoteI2iToHistory(I2iResult r, BuildContext context) async {
    await addImageToHistory(
      image: r.bytes,
      metadata: r.metadata,
      context: context.mounted ? context : null,
      forceSave: true,
    );
    if (context.mounted) {}
  }

  // 폴더에 저장 (DNaiApp 갤러리 폴더로) — 고른 그 결과
  Future<void> saveI2iToFolder(I2iResult r, BuildContext context) async {
    final path = await autoSaveImage(context.mounted ? context : null, r.bytes);
    if (!context.mounted) {
      return;
    }
    if (path != null) {
      // 어디에 무슨 이름으로 저장됐는지 알려준다 (릴에서 꾹 누르지 않고 저장했을 때 특히 유용)
      final name = path.split(RegExp(r'[/\\]')).last;
      final where = safRootUri != null ? (safRootName ?? '저장 폴더') : 'DNaiApp';
      showToast(context, "💾 $where 에 저장했어요\n$name");
    } else {
      showToast(context, "저장에 실패했습니다.");
    }
  }

  // ══════════════════════════════════════════════════════════════
  // i2i 결과 보관 — 릴(캐시 폴더)과 즐겨찾기(문서 폴더)
  // ══════════════════════════════════════════════════════════════
  //  둘 다 같은 방식(SplitImageStore — utils/split_image_store.dart)으로 둔다:
  //  작은 목록 파일 하나 + 그림 파일 한 장씩. 쓰는 순서·도중에 꺼졌을 때의 처리는 그 파일 설명 참고.
  //
  //  · 릴: 앱 캐시 폴더의 i2i_reel/ — 즐겨찾기 '아닌' 결과. 저장 공간이 모자라면 시스템이 치울 수 있다
  //        (스크래치 릴이라 괜찮다 — 그땐 릴만 비어 보인다). 상한은 릴과 같다 (i2iResultsCap).
  //  · 즐겨찾기: 앱 문서 폴더의 i2i_favorites/ — 시스템이 치우지 않는 곳.
  //  ⚠️ 릴은 원래 메모리에만 있어서, 앱을 내려둔 사이 안드로이드가 앱을 끄면 즐겨찾기 말고는 사라졌다.
  //  ⚠️ 즐겨찾기는 예전엔 원본을 base64 로 바꿔 한 파일(그 전엔 설정 저장소)에 통째로 넣었다
  //     — 33% 커지고, ★ 하나에 전부 다시 쓰고, 읽을 때 메모리를 2~3배 먹었다.
  //  ⚠️ 둘 다 처음 읽기를 마치기 전엔 맞추지(=정리하지) 않는다 — 안 읽은 그림을 지우게 된다.

  late final SplitImageStore _reelStore = SplitImageStore(
    dir: () async => Directory('${(await getTemporaryDirectory()).path}/i2i_reel'),
    indexName: 'reel.json',
    filePrefix: 'r_',
  );
  late final SplitImageStore _favStore = SplitImageStore(
    dir: () async => Directory('${(await getApplicationDocumentsDirectory()).path}/i2i_favorites'),
    indexName: 'favorites.json',
    filePrefix: 'f_',
  );
  bool _reelReady = false; // 지난 릴을 '제대로' 되살렸는지 — 그 뒤에만 릴 보관함을 맞춘다
  bool _i2iFavoritesLoaded = false; // 즐겨찾기 읽기를 시도했는지 (loadInitialData 의 finally 가 본다)
  bool _i2iFavoritesReady = false; // 즐겨찾기를 '제대로' 읽었는지 — 그 뒤에만 즐겨찾기 보관함을 맞춘다
  //  ⚠️ 읽다가 실패했는데 '읽었다'고 치면, 다음 맞추기가 안 읽힌 그림을 '목록에 없음'으로 보고 지운다.
  //     실패했으면 이번 실행에서는 그 보관함을 건드리지 않는다 (다음 실행에 다시 읽는다).

  static StoredImage _toStored(I2iResult r) => (
    id: r.id,
    bytes: r.bytes,
    info: {'t': r.createdAt, 'src': r.source, 'fav': r.favorite, 'meta': r.metadata?.toJson()},
  );

  /// 보관함의 한 장 → 릴 결과. 오류를 던지지 않는다 (정보가 깨졌으면 그 정보만 버린다).
  ///  [favorite] 은 목록에 'fav' 가 없을 때 쓰는 기본값 (보관함마다 다르다).
  static I2iResult _fromStored(StoredImage s, {required bool favorite}) {
    final meta = s.info['meta'];
    final src = s.info['src'];
    final t = s.info['t'];
    final fav = s.info['fav'];
    NaiMetadata? metadata;
    try {
      metadata = meta is Map ? NaiMetadata.fromJson(Map<String, dynamic>.from(meta)) : null;
    } catch (_) {
      metadata = null; // 옛 형식 등으로 못 읽으면 정보 없이 그림만
    }
    return I2iResult(
      bytes: s.bytes,
      metadata: metadata,
      favorite: fav is bool ? fav : favorite,
      source: src is String ? src : I2iMode.inpaint.id,
      id: s.id,
      createdAt: t is num ? t.toInt() : 0,
    );
  }

  // ── 두 보관함에 '무엇을 둘지' ──
  //  기본: 즐겨찾기 아닌 것 → 릴 보관함, 즐겨찾기 → 즐겨찾기 보관함.
  //  ★를 누르거나 풀면 그림이 한쪽에서 다른 쪽으로 옮겨 간다. 이때 '새 자리에 아직 안 쓰였으면
  //  옛 자리에서 지우지 않는다' — 두 보관함은 각자 따로 맞추므로, 순서를 정해 두는 것만으로는
  //  그 사이에 다른 맞추기(새 결과 등)가 끼어들어 옛 자리를 먼저 지울 수 있다.
  //  잠깐 양쪽에 다 있어도 괜찮다: 목록에 'fav' 가 함께 적혀 있어 어느 쪽에서 읽어도 제 상태로 돌아오고,
  //  되살릴 때 id 로 겹침을 거른다. 새 자리에 쓰인 뒤의 맞추기에서 옛 자리가 정리된다.
  List<StoredImage> _reelKeep() => [
    for (final r in i2iResults)
      if (!r.favorite || (_reelStore.isStored(r.id) && !_favStore.isStored(r.id))) _toStored(r),
  ];

  List<StoredImage> _favKeep() => [
    for (final r in i2iResults)
      if (r.favorite || (_favStore.isStored(r.id) && !_reelStore.isStored(r.id))) _toStored(r),
  ];

  /// 릴이 바뀌었을 때 부른다 — 릴 보관함을 지금 릴(즐겨찾기 아닌 것)에 맞춘다.
  ///  되살리기 전이면 아무것도 안 한다 — 되살리기가 끝나며 한 번 맞춘다 (_restoreI2iReel).
  Future<void> _saveReelSoon() async {
    if (!_reelReady) {
      return;
    }
    await _reelStore.sync(_reelKeep);
  }

  /// 지난 실행의 릴을 되살린다 (로딩이 끝난 뒤 한 번).
  ///  그 사이 생긴 결과·즐겨찾기와 '만든 순서'대로 섞는다.
  Future<void> _restoreI2iReel() async {
    try {
      final stored = await _reelStore.load() ?? const <StoredImage>[];
      final have = {for (final r in i2iResults) r.id}; // 이미 있는 것(즐겨찾기 등)은 겹치지 않게
      final restored = [
        for (final s in stored)
          if (!have.contains(s.id)) _fromStored(s, favorite: false), // ★ 로 옮겨 가던 것은 'fav' 로 돌아온다
      ];
      if (restored.isNotEmpty) {
        // 만든 순서대로 (같은 시각이면 원래 순서 — 정렬이 순서를 섞지 않게 번호를 함께 본다)
        final merged = [...restored, ...i2iResults];
        final order = {for (int i = 0; i < merged.length; i++) merged[i].id: i};
        merged.sort((a, b) {
          final c = a.createdAt.compareTo(b.createdAt);
          return c != 0 ? c : order[a.id]!.compareTo(order[b.id]!);
        });
        i2iResults = merged;
        _trimI2iResults();
        notifyListeners();
      }
      _reelReady = true;
      // 되살리는 사이 바뀐 것까지 포함해 한 번 맞춘다 (남은 쓰레기 파일도 여기서 치운다).
      //  즐겨찾기 쪽도 한 번 — ★ 로 옮겨 가던 도중에 꺼졌던 그림이 여기서 제자리를 찾는다.
      unawaited(_saveReelSoon().then((_) => saveI2iFavorites()));
    } catch (e) {
      // 못 읽었으면 이번 실행에서는 릴 보관함을 건드리지 않는다 (안 읽힌 그림을 지우지 않게).
      //  이번 실행의 새 결과는 보관되지 않지만, 지난 것은 다음 실행에 다시 읽는다.
      debugPrint('i2i 릴 되살리기 실패 — 이번 실행에선 릴을 보관하지 않음: $e');
    }
  }

  Future<void> saveI2iFavorites() async {
    // 제대로 읽기 전엔 쓰지 않는다 — 안 읽은 즐겨찾기 그림을 '목록에 없음' 으로 보고 지우게 된다
    if (!_i2iFavoritesReady) {
      return;
    }
    await _favStore.sync(_favKeep);
  }

  Future<void> loadI2iFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      i2iHandleBottom = prefs.getDouble('i2iHandleBottom') ?? -1;
      promptCharHandleTop = prefs.getDouble('promptCharHandleTop') ?? -1;

      List<I2iResult>? favs;
      final stored = await _favStore.load();
      if (stored != null) {
        favs = [for (final s in stored) _fromStored(s, favorite: true)];
      } else {
        favs = await _migrateLegacyI2iFavorites(prefs);
      }
      if (favs != null) {
        // 보관함이 가장 믿을 만하다 — 지금 들고 있는 즐겨찾기(가져오기로 들어온 것 등)는 버린다
        i2iResults = [...favs, ...i2iResults.where((r) => !r.favorite)];
      }
      _i2iFavoritesReady = true;
    } catch (e) {
      // 못 읽었으면 이번 실행에서는 즐겨찾기 보관함을 건드리지 않는다 (위 _i2iFavoritesReady 설명)
      debugPrint("i2i 즐겨찾기 로드 실패 — 이번 실행에선 즐겨찾기를 저장하지 않음: $e");
    } finally {
      _i2iFavoritesLoaded = true;
    }
  }

  /// 옛 형식의 즐겨찾기를 보관함으로 옮긴다. 옮길 게 없으면 null.
  ///  · 3.10 개발판: 앱 문서 폴더의 i2i_favorites.json (base64 째 한 파일)
  ///  · 그 전: 설정 저장소(SharedPreferences)의 'i2iFavorites'
  ///  새 보관함에 다 쓴 '뒤에만' 옛 것을 지운다 — 도중에 꺼져도 둘 중 한 곳엔 남는다.
  Future<List<I2iResult>?> _migrateLegacyI2iFavorites(SharedPreferences prefs) async {
    final legacyFile = File('${(await getApplicationDocumentsDirectory()).path}/i2i_favorites.json');
    final String? raw = await legacyFile.exists()
        ? await legacyFile.readAsString()
        : prefs.getString('i2iFavorites');
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final migrated = <I2iResult>[];
    for (final e in jsonDecode(raw) as List) {
      try {
        migrated.add(I2iResult.fromJson(Map<String, dynamic>.from(e as Map))..favorite = true);
      } catch (_) {
        // 한 장이 깨졌으면 그 장만 건너뛴다
      }
    }
    final ok = await _favStore.sync(() => [for (final r in migrated) _toStored(r)]);
    if (ok) {
      if (await legacyFile.exists()) {
        await legacyFile.delete();
      }
      await prefs.remove('i2iFavorites');
      debugPrint("i2i 즐겨찾기 ${migrated.length}장을 보관함으로 옮겼습니다");
    }
    return migrated;
  }

  Future<void> savePromptCharHandleTop(double value) async {
    promptCharHandleTop = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('promptCharHandleTop', value);
    } catch (_) {
      // 손잡이 위치는 화면 편의값이라 저장에 실패해도 무시한다.
      // 이번 실행 중에는 promptCharHandleTop 값이 그대로 쓰인다.
    }
  }

  Future<void> saveI2iHandleBottom(double value) async {
    i2iHandleBottom = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('i2iHandleBottom', value);
    } catch (e) {
      debugPrint("i2i 핸들 위치 저장 실패: $e");
    }
  }

  // ============================================================================
  // 프리셋 파일 저장
  //  썸네일(base64 JPEG)이 포함돼 있어 SharedPreferences에 두기엔 너무 크다.
  //  히스토리와 같은 방식으로 앱 문서 폴더에 JSON 파일로 둔다.
  // ============================================================================
  Future<File> _presetsFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/presets.json');
  }

  // ══════════════════════════════════════════════════════════════
  // 프롬프트 사전
  // ══════════════════════════════════════════════════════════════
  //  미리보기 그림을 품고 있어 SharedPreferences 가 아니라 파일에 둔다.
  //  (프리셋과 같은 이유 — prefs 는 앱 시작 때 통째로 메모리에 올라온다)
  List<PromptDictEntry> promptDict = [];
  List<PromptDictCategory> promptDictCategories = [];

  /// 확대 입력창의 사전 선택 창에서 마지막으로 고른 분류 (앱을 켜 있는 동안만 기억).
  ///  캐릭터 입력창에서 '캐릭터' 분류를 골라 두면 다음에 열 때도 그대로 보인다.
  String dictPickerFilter = kDictFilterAll;

  /// 사전 '간단히 보기' — 한 줄에 '이름 - 분류' 만 (사전이 길어졌을 때). 기본 꺼짐.
  ///  라이브러리 탭의 사전 목록과 확대 입력창의 선택 창이 함께 쓴다 (widgets/dict_compact.dart).
  bool promptDictCompact = false;

  /// 간단히 보기 켜기/끄기 — 저장까지
  void toggleDictCompact() {
    promptDictCompact = !promptDictCompact;
    saveAndRefresh();
  }

  Future<File> _promptDictFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/prompt_dict.json');
  }

  Future<void> savePromptDict() async {
    // 불러오기가 끝나기 전엔 쓰지 않는다 — 아직 빈 사전이 파일을 덮는다 (_initialLoadFinished 참고)
    if (!_initialLoadFinished) {
      return;
    }
    try {
      final f = await _promptDictFile();
      // 반쯤 쓰다 꺼져도 옛 내용이 남도록 통째로 바꾼다
      await _writeAtomic(
        f,
        jsonEncode({
          'categories': promptDictCategories.map((c) => c.toJson()).toList(),
          'entries': promptDict.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('프롬프트 사전 저장 실패: $e');
    }
  }

  Future<void> _loadPromptDict() async {
    // 읽기를 '마쳤다'고 표시한다 — 성공·파일 없음·깨짐(따로 보관) 모두 여기서 끝난다
    _promptDictLoaded = true;
    try {
      final f = await _promptDictFile();
      if (!await f.exists()) {
        return;
      }
      final raw = jsonDecode(await f.readAsString());
      // 다 풀린 뒤에만 바꾼다 (분류만 바뀌고 항목은 그대로인 반쪽 상태가 생기지 않게)
      // 옛 형식: 항목 목록만 있었다 (분류 기능 이전)
      if (raw is List) {
        promptDict = raw.map((e) => PromptDictEntry.fromJson(e)).toList();
      } else if (raw is Map) {
        final cats = ((raw['categories'] as List?) ?? const [])
            .map((e) => PromptDictCategory.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        final entries = ((raw['entries'] as List?) ?? const [])
            .map((e) => PromptDictEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        promptDictCategories = cats;
        promptDict = entries;
      }
      _dropDanglingCategoryRefs();
      // 불러오기에 성공했을 때만 주인 없는 큰 이미지를 치운다
      unawaited(_cleanupDictImages());
    } catch (e) {
      debugPrint('프롬프트 사전 불러오기 실패: $e');
      // ⚠️ 빈 목록으로 시작한 채 저장하면 깨진(하지만 살릴 수도 있는) 파일을 덮어쓴다.
      //    그래서 깨진 파일은 이름을 바꿔 따로 보관하고 새로 시작한다.
      //    큰 이미지도 이번엔 치우지 않는다 (나중에 살릴 때 필요할 수 있다).
      try {
        final f = await _promptDictFile();
        if (await f.exists()) {
          await f.rename('${f.path}.broken_${DateTime.now().millisecondsSinceEpoch}');
        }
      } catch (_) {
        // 이름조차 못 바꾸면 그대로 둔다 — 앱 실행을 막지 않는다
      }
      // 들고 있던 것은 그대로 둔다. 보통은 빈 목록이고, 앱 안의 설정 사본에서 되살린 경우엔
      //  그 사전이다 — 비우면 곧이은 저장(_saveAfterLoad)이 되살린 사전까지 빈 목록으로 덮는다.
    }
  }

  // ── 사전 큰 이미지 ──────────────────────────────────────────────
  //  목록용 작은 썸네일은 prompt_dict.json 안에(base64), 크게 볼 이미지는 파일로 따로 둔다.
  //  ⚠️ 큰 이미지(장당 40~65KB)까지 JSON 에 넣으면 앱을 켤 때마다 수 MB 를 통째로 읽고,
  //     항목 하나 고칠 때마다 통째로 다시 쓰게 된다.
  //  파일 이름은 항목 id — 목록 순서와 무관해 삭제·정렬에 안전하다.
  //  내보내기·업데이트 전 자동 백업에는 함께 담는다 (promptDictImages, 3.10.0~).
  //  3.9 이전에 만든 백업으로 되살리면 큰 이미지가 없어 작은 썸네일만 돌아온다.

  Future<Directory> _dictImageDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/prompt_dict_images');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  Future<File> _dictImageFile(String id) async => File('${(await _dictImageDir()).path}/$id.webp');

  /// 큰 이미지를 저장한다 (임시 파일에 쓴 뒤 이름만 바꿔, 도중에 꺼져도 깨진 파일이 남지 않게).
  Future<void> saveDictImage(String id, Uint8List bytes) async {
    try {
      final f = await _dictImageFile(id);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('사전 큰 이미지 저장 실패: $e');
    }
  }

  /// 큰 이미지를 읽는다. 없으면 null (그땐 작은 썸네일로 대신 보여 준다).
  Future<Uint8List?> loadDictImage(String id) async {
    try {
      final f = await _dictImageFile(id);
      return await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteDictImage(String id) async {
    try {
      final f = await _dictImageFile(id);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // 지우지 못해도 다음 정리 때 치워진다
    }
  }

  /// 백업에 담을 큰 이미지들 (항목 id → WebP base64). 파일이 없는 항목은 빠진다.
  Future<Map<String, String>> _exportDictImages() async {
    final out = <String, String>{};
    for (final e in promptDict) {
      final bytes = await loadDictImage(e.id);
      if (bytes != null) {
        out[e.id] = base64Encode(bytes);
      }
    }
    return out;
  }

  /// 백업의 큰 이미지([raw] = 항목 id → base64)를 파일로 되살린 뒤, 주인 없는 그림을 치운다.
  ///  ⚠️ 순서가 중요하다 — 치우기를 먼저(또는 동시에) 하면 쓰는 중인 임시 파일(.tmp)을 지울 수 있다.
  ///  지금 사전에 있는 항목의 그림만 쓴다 (백업과 사전이 어긋나도 쓰레기 파일이 생기지 않게).
  Future<void> _restoreDictImages(Object? raw) async {
    if (raw is Map) {
      final alive = promptDict.map((e) => e.id).toSet();
      for (final entry in raw.entries) {
        final id = entry.key;
        final b64 = entry.value;
        if (id is! String || b64 is! String || !alive.contains(id)) {
          continue;
        }
        try {
          await saveDictImage(id, base64Decode(b64));
        } catch (_) {
          // 한 장이 깨졌으면 그 장만 건너뛴다 (그 항목은 작은 썸네일로 보인다)
        }
      }
    }
    // 앱을 켜는 도중(앱 안의 사본에서 설정을 되살릴 때)엔 치우지 않는다.
    //  곧 사전 파일을 다시 읽는데(loadInitialData 의 finally), 그쪽 항목이 더 많을 수 있다.
    //  그 읽기가 끝나면 거기서 알아서 치운다.
    if (_initialLoadFinished) {
      await _cleanupDictImages();
    }
  }

  /// 어느 항목에도 속하지 않는 큰 이미지 파일을 지운다 (항목을 지운 뒤 남은 것, 쓰다 만 .tmp 등).
  Future<void> _cleanupDictImages() async {
    // ⚠️ 사전이 비어 있으면 치우지 않는다.
    //    사전 파일이 어떤 사고로 빈 목록이 됐을 때 여기서 큰 이미지까지 지우면,
    //    나중에 백업으로 항목을 되살려도(id 가 같다) 흐린 썸네일만 남는다.
    //    항목을 직접 지울 땐 removePromptDictEntry 가 그 그림을 바로 지우므로
    //    이렇게 남겨 둬도 쌓이는 쓰레기는 거의 없다.
    if (promptDict.isEmpty) {
      return;
    }
    try {
      // ⚠️ 깨진 사전 파일(.broken_*)이 보관돼 있으면 정리하지 않는다.
      //    그 파일을 살렸을 때 필요한 큰 이미지까지 지우게 된다.
      //    (보관 파일을 지우면 다음 실행부터 다시 정리한다)
      final dictFile = await _promptDictFile();
      final hasBroken = dictFile.parent.listSync().whereType<File>().any(
        (f) => f.uri.pathSegments.last.startsWith('prompt_dict.json.broken_'),
      );
      if (hasBroken) {
        return;
      }
      final alive = promptDict.map((e) => e.id).toSet();
      final dir = await _dictImageDir();
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final id = name.endsWith('.webp') ? name.substring(0, name.length - 5) : null;
        if (id == null || !alive.contains(id)) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint('사전 이미지 정리 실패(무시): $e');
    }
  }

  void addPromptDictEntry(PromptDictEntry e) {
    promptDict.insert(0, e); // 새 항목이 맨 위에
    unawaited(savePromptDict());
    notifyListeners();
  }

  void updatePromptDictEntry(PromptDictEntry e) {
    final i = promptDict.indexWhere((x) => x.id == e.id);
    if (i < 0) {
      return;
    }
    promptDict[i] = e;
    unawaited(savePromptDict());
    notifyListeners();
  }

  /// 분류 id → 보여 줄 이름. 분류가 없거나(null) 지워졌으면 '미분류'.
  ///  (사전 간단히 보기의 '이름 - 분류' · 선택 창의 분류 버튼)
  String dictCategoryLabel(String? id) {
    if (id != null) {
      for (final c in promptDictCategories) {
        if (c.id == id) {
          return c.name;
        }
      }
    }
    return "미분류";
  }

  /// 거르기 값이 아직 유효한가. 지워진 분류를 가리키면 '전체'를 돌려준다.
  ///  (사전 탭 칩 줄과 확대 입력창 선택 창이 함께 쓴다)
  String validDictFilter(String f) {
    if (f == kDictFilterAll || f == kDictFilterNone) {
      return f;
    }
    return promptDictCategories.any((c) => c.id == f) ? f : kDictFilterAll;
  }

  // 사전 미리보기(base64)를 푼 결과. 사전 탭과 입력창 선택 창이 함께 쓴다.
  //  원래 문자열을 함께 들고 있다가 미리보기가 바뀌면 다시 푼다.
  final Map<String, (String, Uint8List?)> _dictThumbCache = {};

  /// 사전 항목의 미리보기 바이트 (없거나 깨졌으면 null).
  Uint8List? dictThumb(PromptDictEntry e) {
    final t = e.thumbnail;
    if (t == null) {
      return null;
    }
    final c = _dictThumbCache[e.id];
    if (c != null && identical(c.$1, t)) {
      return c.$2;
    }
    Uint8List? b;
    try {
      b = base64Decode(t);
    } catch (_) {
      b = null; // 깨진 미리보기는 아이콘으로 대신한다
    }
    _dictThumbCache[e.id] = (t, b);
    return b;
  }

  /// 새 분류. 이름이 비었거나 이미 있으면 null.
  PromptDictCategory? addPromptDictCategory(String name) {
    final n = name.trim();
    if (n.isEmpty || _categoryNameTaken(n)) {
      return null;
    }
    final c = PromptDictCategory(name: n);
    promptDictCategories.add(c);
    unawaited(savePromptDict());
    notifyListeners();
    return c;
  }

  /// 분류 이름 바꾸기. 성공하면 true.
  bool renamePromptDictCategory(String id, String name) {
    final n = name.trim();
    final i = promptDictCategories.indexWhere((x) => x.id == id);
    if (i < 0 || n.isEmpty || _categoryNameTaken(n, exceptId: id)) {
      return false;
    }
    promptDictCategories[i].name = n;
    unawaited(savePromptDict());
    notifyListeners();
    return true;
  }

  /// 분류를 지운다. 안의 항목은 지우지 않고 '미분류'로 돌린다.
  void removePromptDictCategory(String id) {
    promptDictCategories.removeWhere((c) => c.id == id);
    for (final e in promptDict) {
      if (e.categoryId == id) {
        e.categoryId = null;
      }
    }
    dictPickerFilter = validDictFilter(dictPickerFilter);
    unawaited(savePromptDict());
    notifyListeners();
  }

  bool _categoryNameTaken(String name, {String? exceptId}) =>
      categoryNameProblem(name, exceptId: exceptId) != null;

  /// [name] 을 사전 분류 이름으로 쓸 수 없으면 그 이유(안내 문구), 쓸 수 있으면 null.
  ///  이름 입력 창이 닫기 전에 미리 물어본다 (와일드카드의 wildcardNameProblem 과 같은 모양).
  String? categoryNameProblem(String name, {String? exceptId}) {
    final n = name.trim();
    if (n.isEmpty) {
      return "이름을 입력해 주세요.";
    }
    final low = n.toLowerCase();
    // '전체'·'미분류'는 칩 이름으로 이미 쓰고 있어 헷갈리므로 막는다
    if (low == '전체' || low == '미분류') {
      return "'$n' 은(는) 이미 쓰는 칩 이름이에요.";
    }
    if (promptDictCategories.any((c) => c.id != exceptId && c.name.toLowerCase() == low)) {
      return "'$n' 분류는 이미 있어요.";
    }
    return null;
  }

  /// 없는 분류를 가리키는 항목은 미분류로 (백업 복원·파일 손상 대비)
  void _dropDanglingCategoryRefs() {
    final ids = promptDictCategories.map((c) => c.id).toSet();
    for (final e in promptDict) {
      if (e.categoryId != null && !ids.contains(e.categoryId)) {
        e.categoryId = null;
      }
    }
  }

  /// [prefix] 로 시작하는 되돌리기 기록 중, 이제 없는 대상의 기록을 지운다.
  ///  예) prefix 'dict/' + 남아 있는 사전 id 들 → 지워진 항목의 기록만 버린다.
  ///  (캐릭터는 uid 가 얽혀 있어 _pruneCharacterUndo 가 따로 맡는다)
  void pruneUndoKeys(String prefix, Iterable<String> alive) {
    final keep = alive.toSet();
    final dead = promptUndoHistory.keys
        .where((k) => k.startsWith(prefix) && !keep.contains(k.substring(prefix.length)))
        .toList();
    for (final k in dead) {
      promptUndoHistory.remove(k);
    }
  }

  /// 되돌리기 기록의 열쇠를 바꾼다 (이름을 바꿔도 기록이 이어지게).
  void renameUndoKey(String from, String to) {
    if (from == to) {
      return;
    }
    final v = promptUndoHistory.remove(from);
    if (v != null) {
      promptUndoHistory[to] = v;
    }
  }

  void removePromptDictEntry(String id) {
    promptDict.removeWhere((x) => x.id == id);
    _dictThumbCache.remove(id);
    unawaited(deleteDictImage(id));
    // 지운 항목의 되돌리기 기록도 버린다 ('dict/new' 는 새 항목용이라 남긴다)
    pruneUndoKeys('dict/', [...promptDict.map((e) => e.id), 'new']);
    unawaited(savePromptDict());
    notifyListeners();
  }

  Future<void> savePresetsToFile() async {
    // 불러오기가 끝나기 전엔 쓰지 않는다 — 아직 빈 목록이 파일을 덮는다 (_initialLoadFinished 참고)
    if (!_initialLoadFinished) {
      return;
    }
    await _writePresetsFile();
  }

  /// 프리셋 파일을 실제로 쓴다 (막아 두는 조건 없이).
  ///  불러오는 도중의 옛 데이터 이관([_loadPresets])만 이걸 직접 부른다.
  ///  반환: 다 썼는지 (옛 데이터 이관이 이걸 보고 옛 값을 지운다).
  ///  내용이 지난번에 쓴(또는 읽은) 것과 같으면 쓰지 않는다 — saveAllSettings 가 설정을 저장할
  ///  때마다(프롬프트를 치다 멈출 때마다) 부르는데, 프리셋은 썸네일을 품고 있어 크다.
  String? _lastPresetsJson; // 프리셋 파일에 마지막으로 쓴(또는 읽은) 내용

  Future<bool> _writePresetsFile() async {
    try {
      final json = jsonEncode(presets.map((e) => e.toJson()).toList());
      if (json == _lastPresetsJson) {
        return true;
      }
      final f = await _presetsFile();
      // ⚠️ 바로 덮어쓰면, 쓰다 꺼진 반쪽 파일을 다음에 못 읽고 빈 목록으로 시작한다.
      //    그 상태로 프리셋을 하나라도 저장하면 빈 목록으로 덮어써 전부 사라진다.
      await _writeAtomic(f, json);
      _lastPresetsJson = json;
      return true;
    } catch (e) {
      debugPrint('프리셋 저장 실패: $e');
      return false;
    }
  }

  /// 프리셋을 읽어 온다.
  ///  1) presets.json 이 있으면 그걸 쓴다.
  ///  2) 없으면 예전에 쓰던 prefs['presets']에서 읽어 파일로 옮기고 prefs는 지운다.
  ///     (앱을 업데이트한 사용자의 기존 프리셋이 사라지지 않게 하기 위함)
  Future<void> _loadPresets(SharedPreferences prefs) async {
    _presetsLoaded = true; // 읽기를 '마쳤다' (성공·파일 없음·깨짐 모두)
    try {
      final f = await _presetsFile();
      if (await f.exists()) {
        try {
          final raw = await f.readAsString();
          final decoded = jsonDecode(raw) as List;
          presets = decoded.map((e) => NaiPreset.fromJson(e)).toList();
          _lastPresetsJson = raw; // 그대로면 다음 저장 때 다시 쓰지 않는다
          return;
        } catch (e) {
          debugPrint('프리셋 파일 읽기 실패: $e');
          // ⚠️ 그대로 두면 다음 저장이 깨진(하지만 살릴 수도 있는) 파일을 덮어쓴다.
          //    사전처럼 이름을 바꿔 따로 보관한다.
          await f.rename('${f.path}.broken_${DateTime.now().millisecondsSinceEpoch}');
        }
      }
    } catch (e) {
      debugPrint('프리셋 파일 확인 실패: $e');
    }
    // 구버전 데이터 이관
    final legacy = prefs.getString('presets');
    if (legacy != null) {
      try {
        final decoded = jsonDecode(legacy) as List;
        presets = decoded.map((e) => NaiPreset.fromJson(e)).toList();
        // 불러오는 도중이라 savePresetsToFile 은 막혀 있다 → 직접 쓴다
        //  (바로 아래에서 prefs 의 옛 값을 지우므로, 파일에 먼저 남겨야 한다)
        if (await _writePresetsFile()) {
          await prefs.remove('presets');
          debugPrint('프리셋 ${presets.length}개를 파일로 이관했습니다');
        }
      } catch (e) {
        debugPrint('프리셋 이관 실패: $e');
      }
    }
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
    // v5는 Vibe 미지원이라 여기 오지 않아야 하지만, 안전하게 v4.5 키로 폴백
    if (model.contains("5") && !model.contains("4-5") && !model.contains("4.5")) {
      return "v4-5full";
    }
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

  // vibe 인코딩 캐시의 가벼운 지문 (identityHashCode라 O(1), 큰 문자열 해시 안 함)
  // 생성 전후로 비교해서 실제로 캐시가 갱신된 경우에만 디스크 저장을 트리거한다.
  String _vibeCacheSignature() {
    return vibeTransfers
        .map(
          (v) => '${identityHashCode(v['_encoded'])}:${v['_encodedInfoExt']}:${v['_encodedModel']}',
        )
        .join('|');
  }

  Future<void> saveReferencesToLocal() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/references.json');
      final data = {'vibeTransfers': vibeTransfers, 'preciseRefs': preciseRefs};
      await _writeAtomic(file, jsonEncode(data)); // 쓰다 꺼져도 옛 내용이 남는다
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

  // 히스토리 디스크 저장 — 짧게 모으는 타이머와 쓰기 줄 (쓰는 곳: app_state_history.dart)
  Timer? _historySaveDebounce;

  Future<void> _historyWriteChain = Future.value();

  Future<void> _writeBytesAtomic(File f, Uint8List bytes) => _serialWrite(f.path, () async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  });

  /// 파일을 '통째로' 바꾼다: 임시 파일에 다 쓴 뒤 이름만 바꾼다.
  ///  ⚠️ 그냥 덮어쓰다 앱이 꺼지면 반쯤 쓴 JSON 이 남아 다음 실행에 읽지 못한다.
  ///     이름 바꾸기는 한 번에 일어나므로 '옛 내용' 아니면 '새 내용'만 남는다.
  // 파일을 '임시 파일에 다 쓴 뒤 이름 바꾸기'로 쓴다 — 도중에 꺼져도 옛 내용이 온전히 남는다.
  //  앱이 계속 들고 있는 파일(설정 사본·프리셋·참조·히스토리·사전)은 전부 이걸로 쓴다.
  Future<void> _writeAtomic(File f, String content) => _serialWrite(f.path, () async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  });

  // 같은 파일에 대한 쓰기를 차례로 돌린다.
  //  임시 파일 이름(파일.tmp)이 같아서, 두 쓰기가 겹치면 한쪽이 쓰는 도중의 임시 파일을
  //  다른 쪽이 이름 바꿔 가져가 반쯤 쓴 파일이 남을 수 있다 (예: 프리셋을 빠르게 연달아 저장).
  final Map<String, Future<void>> _writeChains = {};
  Future<void> _serialWrite(String path, Future<void> Function() write) {
    final next = (_writeChains[path] ?? Future.value()).then((_) => write());
    _writeChains[path] = next.catchError((_) {}); // 앞 쓰기가 실패해도 줄이 막히지 않게
    return next; // 실패는 부른 쪽이 받는다
  }

  /// 히스토리를 불러오지 못했는지. true 면 히스토리 파일을 건드리지 않는다.
  bool _historyLoadFailed = false;

  // ============================================================================
  // 파일 존재 여부 확인 (checkFileExistsSync — app_state_history.dart)
  // ============================================================================
  // 경로별 존재 여부 캐시.
  //  checkFileExistsSync 는 히스토리 그리드/리스트의 itemBuilder에서 불리므로
  //  스크롤 한 번에 수십~수백 번 호출된다. 매번 디스크를 두드리면
  //  스크롤이 눈에 띄게 끊기므로 결과를 기억해 둔다.
  //  (저장·삭제처럼 파일이 바뀌는 시점에 invalidateFileExistsCache로 비운다)
  final Map<String, bool> _fileExistsCache = {}; // 쓰는 곳: app_state_history.dart

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

  /// 저장 직전 준비: 설정에 맞춰 형식을 바꾸고 확장자를 정한다.
  ///  ⚠️ 예전엔 자동 저장·수동 저장에 똑같은 코드가 두 벌 있었다. 여기 하나로 모은다.
  Future<(Uint8List, String)> _prepareForSave(Uint8List bytes) async {
    // 이미 압축된 그림(밖에서 가져온 JPEG · WebP 로 저장해 둔 그림을 다시 불러온 것 등)은 다시 굽지 않고 내용 그대로,
    //  확장자도 내용대로 (image_codec.dart 의 compressedImageExt). 저장 형식 설정은 PNG(생성 결과)를 구울 때만 쓴다.
    //  ⚠️ 예전엔 JPEG 만 알아봤다 — WebP 그림을 'WebP 저장' 을 끈 채 저장하면 WebP 내용이 .png 이름으로 저장됐고,
    //     켠 채 저장하면 다시 구워 화질이 한 번 더 깎이고 그림 정보가 사라졌다 (정보는 PNG 글자 청크에서만 옮긴다).
    //     PNG 로 바꿔 주지 않는 이유 — 이미 깎인 화질은 돌아오지 않고 용량만 몇 배가 된다.
    final String? kept = compressedImageExt(bytes);
    if (kept != null) {
      return (bytes, kept);
    }
    var format = saveFormat;
    // ⚠️ 투명 배경으로 뽑은 그림을 손실 WebP 로 저장하면 알파가 뭉개진다 → 무손실로
    if (format == SaveFormat.webpLossy && transparentBackground) {
      format = SaveFormat.webpLossless;
    }
    if (format.quality == null) {
      return (bytes, format.ext); // 원본 그대로 쓰는 형식
    }
    final converted = await _convertWithMetadata(bytes, format);
    // 실패하면 원본(PNG) 그대로 저장한다
    return converted == null ? (bytes, SaveFormat.png.ext) : (converted, format.ext);
  }

  // PNG 바이트를 [format] 으로 굽고 원본 메타데이터를 옮겨 담는다.
  // 실패하면 null을 반환해 호출부가 원본(PNG)으로 폴백하도록 한다.
  //  ⚠️ 새 저장 형식을 더할 때는 메타데이터를 담는 방법도 정해야 한다
  //     (PNG 는 tEXt 청크, WebP 는 EXIF — 형식마다 다르다).
  Future<Uint8List?> _convertWithMetadata(Uint8List pngBytes, SaveFormat format) async {
    try {
      // 1) 원본 PNG 의 글자 청크를 '전부' 먼저 확보 (변환하면 사라지므로).
      //    Comment(파라미터)만 옮기면 novelai.net/inspect 가 Title·Description·
      //    Software·Source 를 못 보여 준다 — NovelAI 와 같은 모양으로 전부 옮긴다.
      //    생성 파라미터가 없는 그림(모자이크 결과 등)은 메타데이터 없이 굽는다.
      final chunks = extractPngTextChunks(pngBytes);
      final bool hasParams = paramsJsonOf(chunks) != null; // PNG 를 다시 훑지 않는다

      // 2) 굽기 — 품질·방식은 image_codec.dart 의 SaveFormat 이 정한다
      //    ⚠️ 공용 인코더를 쓴다. 플러그인을 직접 부르면 크기 기본값(1920×1080)
      //       때문에 업스케일한 큰 그림(예: 2176×3840)이 저장할 때 조용히 줄어든다.
      final encoded = await encodeForSave(pngBytes, format);
      if (encoded == null) {
        return null;
      }

      // 3) 메타데이터가 있으면 형식에 맞게 이식
      if (!hasParams) {
        return encoded;
      }
      switch (format.ext) {
        case 'webp':
          return injectExifIntoWebp(encoded, buildExifBlock(chunks)) ?? encoded;
        default:
          return encoded; // 이식 방법이 정해지지 않은 형식은 그림만
      }
    } catch (e) {
      debugPrint('${format.ext} 변환 실패(원본 유지): $e');
      return null;
    }
  }

  Future<String?> autoSaveImage(BuildContext? context, Uint8List bytes) async {
    sessionSaveCount++;
    final sessionFolder = _resolveSessionFolder();

    String fileName = _getFormattedFileName("");
    // 설정에 맞춰 형식을 바꾸고 확장자를 정한다 (실패하면 원본 그대로)
    final (saveBytes, ext) = await _prepareForSave(bytes);
    bytes = saveBytes;

    // 0차: SAF 폴더가 지정돼 있으면 그곳에 저장 (MANAGE 권한 불필요)
    if (safRootUri != null) {
      final safPath = await _saveImageViaSaf(bytes, fileName, ext);
      if (safPath != null) {
        return safPath;
      }
      // SAF 저장 실패 시 아래 기존 경로로 폴백
    }

    // 앱 전용 외부 디렉토리 (권한 불필요)
    try {
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        final directory = Directory('${appDir.path}/DNaiApp/$sessionFolder');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File("${directory.path}/$fileName.$ext");
        await file.writeAsBytes(bytes);
        _scanMedia(file.path);
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
    final sessionFolder = _resolveSessionFolder();

    String fileName = _getFormattedFileName("Manual");
    final messenger = ScaffoldMessenger.of(context); // async gap 전에 캡처
    // 자동 저장과 같은 준비 과정 (형식 변환·확장자 결정, 실패하면 원본 그대로)
    final (saveBytes, ext) = await _prepareForSave(bytes);
    bytes = saveBytes;

    // 0차: SAF 폴더가 지정돼 있으면 그곳에 저장 (MANAGE 권한 불필요)
    if (safRootUri != null) {
      final safPath = await _saveImageViaSaf(bytes, fileName, ext);
      if (safPath != null) {
        notifyListeners();
        return;
      }
      // SAF 저장 실패 시 아래 기존 경로로 폴백
    }

    // 앱 전용 디렉토리 (권한 불필요)
    try {
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        final directory = Directory('${appDir.path}/DNaiApp/$sessionFolder');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File("${directory.path}/$fileName.$ext");
        await file.writeAsBytes(bytes);
        _scanMedia(file.path);
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint("앱 디렉토리 수동 저장 실패: $e");
    }

    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(milliseconds: 2400),
        content: Text("저장에 실패했습니다. 저장 경로를 확인해주세요."),
      ),
    );
    notifyListeners();
  }

  void _scanMedia(String filePath) {
    if (Platform.isAndroid) {
      try {
        MediaScanner.loadMedia(path: filePath);
      } catch (_) {
        // 갤러리 앱에 새 파일을 알리는 작업. 실패해도 파일은 이미 저장돼 있고,
        // 기기가 다음에 스캔할 때 잡힌다.
      }
    }
  }

  /// 계정 목록을 갱신하는 중인지. UI에서 새로고침 스피너를 띄우는 데 쓴다.
  bool isRefreshingAccounts = false;

  /// 등록된 모든 계정의 잔액·할당량을 확인한다.
  ///  계정을 갈아끼우지 않고 각 토큰으로 직접 조회하므로 현재 연결이 끊기지 않는다.
  ///  [force]가 false면 최근에 확인한 계정은 건너뛴다(API 호출 낭비 방지).
  Future<void> refreshAllAccountQuotas({bool force = false, Duration? maxAge}) async {
    if (isRefreshingAccounts || naiAccounts.isEmpty) {
      return;
    }
    final stale = maxAge ?? const Duration(minutes: 5);
    isRefreshingAccounts = true;
    notifyListeners();
    try {
      final now = DateTime.now();
      // 사본을 돈다 — 조회를 기다리는 사이 계정을 더하거나 지우면 목록을 돌던 중 오류로 멈췄다
      for (final acc in List.of(naiAccounts)) {
        final String token = acc.token;
        if (token.trim().isEmpty) {
          continue;
        }
        if (!force && acc.checkedAtMs > 0) {
          final age = now.difference(DateTime.fromMillisecondsSinceEpoch(acc.checkedAtMs));
          if (age < stale) {
            continue; // 아직 신선하다
          }
        }
        try {
          final r = await _service.fetchUserInfo(token);
          // 그 사이 지웠거나 토큰을 바꾼 계정이면 이 답은 버린다 (옛 토큰의 잔액이다)
          if (!naiAccounts.contains(acc) || acc.token != token) {
            continue;
          }
          if (r != null) {
            acc.anlas = (r['anlas'] as int?) ?? 0;
            acc.limitPercent = r['usagePercent'] as double?;
            acc.extraPercent = (r['usageExtra'] as double?) ?? 0;
            acc.checkedAtMs = DateTime.now().millisecondsSinceEpoch;
            // 지금 쓰고 있는 계정이면 화면 상단 표시값도 같이 맞춘다
            if (identical(acc, activeAccount)) {
              currentAnlas = acc.anlas;
              subscriptionTier = (r['tier'] as int?) ?? subscriptionTier;
              v5LimitPercent = acc.limitPercent;
              v5ExtraPercent = acc.extraPercent;
              v5LimitNegative = r['usageNegative'] == true;
              v5LimitCheckedAt = DateTime.now();
              isApiConnected = true;
            }
          }
        } catch (e) {
          debugPrint('계정 "${acc.label}" 조회 실패: $e');
        }
        notifyListeners(); // 한 계정씩 즉시 반영 (전부 끝날 때까지 기다리지 않게)
      }
      await saveAllSettings();
    } finally {
      isRefreshingAccounts = false;
      notifyListeners();
    }
  }

  Future<void> fetchAnlas() async {
    if (apiToken.isEmpty) {
      // 토큰이 없으면 잔액도 없는 상태로 되돌린다
      currentAnlas = 0;
      isApiConnected = false;
      final empty = activeAccount;
      if (empty != null) {
        empty.anlas = -1;
      }
      notifyListeners();
      return;
    }
    // 누구의 잔액을 묻는지 잡아 둔다 — 답을 기다리는 사이 계정을 바꾸면(생성 뒤 백그라운드 확인 중 전환)
    //  A 계정의 답이 B 계정 · 화면 위에 적혀, B 가 확인된 것으로 5분 동안 다시 확인되지 않았다 (DEVNOTES 5).
    final String token = apiToken;
    final NaiAccount? asked = activeAccount;
    final result = await _service.fetchUserInfo(token);
    if (result != null && (token != apiToken || !identical(asked, activeAccount))) {
      // 그 사이 계정이 바뀌었다 — 답은 물어본 계정에만 (토큰이 그대로일 때), 화면 위 표시는 건드리지 않는다
      if (asked != null && asked.token == token && naiAccounts.contains(asked)) {
        asked.anlas = (result['anlas'] as int?) ?? 0;
        asked.limitPercent = result['usagePercent'] as double?;
        asked.extraPercent = (result['usageExtra'] as double?) ?? 0;
        asked.checkedAtMs = DateTime.now().millisecondsSinceEpoch;
        notifyListeners();
      }
      return;
    }
    if (result != null) {
      currentAnlas = (result['anlas'] as int?) ?? 0;
      subscriptionTier = (result['tier'] as int?) ?? 0;
      isApiConnected = true;
      // V5 사용 한도 (Opus 전용 — 응답에 없으면 null 그대로)
      v5LimitPercent = result['usagePercent'] as double?;
      v5ExtraPercent = (result['usageExtra'] as double?) ?? 0;
      v5LimitNegative = result['usageNegative'] == true;
      v5LimitCheckedAt = DateTime.now();
      // 계정 목록에도 잔액/한도를 기록해 어느 계정이 여유 있는지 보이게 한다
      final acc = activeAccount;
      if (acc != null) {
        acc.anlas = currentAnlas;
        acc.limitPercent = v5LimitPercent;
        acc.extraPercent = v5ExtraPercent;
        acc.checkedAtMs = DateTime.now().millisecondsSinceEpoch;
      }
      notifyListeners();
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Anlas 추정
  // ══════════════════════════════════════════════════════════════
  //
  // ⚠️ 공식 계산식을 재현하지 못했다.
  //    널리 쓰이는 SDK 의 식(면적 x 스텝 선형)을 그대로 넣어 보면 실제 표시값과
  //    1.5배쯤 어긋나고, 계수를 다시 맞춰 봐도 관측 12개를 동시에 만족하는
  //    값이 존재하지 않았다. 식의 구조 자체가 다른 것으로 보인다.
  //
  //    그래서 공식 앱에서 직접 읽은 값을 표로 넣고, 표에 없는 조건은
  //    가까운 값에서 비례로 추정한다. 어디까지나 '대략' 이므로
  //    화면에도 '약 N Anlas' 로 표시한다.
  //
  //    측정 환경: Opus, 1장, V4.5 (2026-09)
  //    표를 늘리려면 공식 웹에서 생성 버튼의 숫자를 읽어 아래에 추가하면 된다.
  //    (1MP 이하 해상도는 28스텝까지 무료라 0 이 뜬다.
  //     값을 보려면 스텝을 29 이상으로 올리거나 장수를 2로 둘 것)
  static const Map<int, Map<int, int>> _anlasTable = {
    // 1024x1536 (1,572,864px)
    1572864: {23: 39, 24: 41, 25: 42, 26: 44, 27: 45, 28: 45},
    // 1088x1920 (2,088,960px)
    2088960: {23: 51, 24: 54, 25: 56, 26: 57, 27: 59, 28: 60},
  };

  /// 이미지 한 장을 만드는 데 드는 Anlas 추정치. 모르면 -1.
  ///
  /// [strength] 를 주면 인페인트·img2img 로 계산한다.
  ///  (실측 확인: 생성 비용 x 강도, 올림. 최소 2)
  int _estimateSingleAnlas(int width, int height, int steps, {double? strength}) {
    final int pixels = width * height;

    int? base;
    final table = _anlasTable[pixels];
    if (table != null) {
      base = table[steps];
      if (base == null && table.isNotEmpty) {
        // 표에 없는 스텝은 가장 가까운 스텝에서 비례로 늘린다
        final nearest = table.keys.reduce((a, b) => (a - steps).abs() <= (b - steps).abs() ? a : b);
        base = (table[nearest]! * steps / nearest).ceil();
      }
    } else {
      // 면적이 표에 없으면, 표에서 가장 가까운 면적을 찾아 면적 비로 늘린다
      if (_anlasTable.isEmpty) {
        return -1;
      }
      final nearPixels = _anlasTable.keys.reduce(
        (a, b) => (a - pixels).abs() <= (b - pixels).abs() ? a : b,
      );
      final nearTable = _anlasTable[nearPixels]!;
      final nearStep = nearTable.keys.reduce(
        (a, b) => (a - steps).abs() <= (b - steps).abs() ? a : b,
      );
      base = (nearTable[nearStep]! * (pixels / nearPixels) * (steps / nearStep)).ceil();
    }

    if (base == null || base <= 0) {
      return -1;
    }
    if (strength == null) {
      return base;
    }
    final v = (base * strength).ceil();
    return v < 2 ? 2 : v;
  }

  /// 이번에 실행할 작업의 Anlas 추정치를 돌려주는 단일 진입점.
  ///
  ///  · 0  = 소모 없음 (Opus 무료 범위 등)
  ///  · -1 = 추정할 수 없음 (표에 없는 조건)
  ///
  /// 작업마다 계산 규칙이 꽤 다르기 때문에, 여기서는 '어느 계산기를 쓸지'만 고르고
  /// 실제 셈은 각 계산기에 맡긴다. 규칙을 한 함수에 몰아넣으면 조건문이 겹겹이
  /// 쌓여 오히려 고치기 어려워진다.
  ///
  /// 호출부는 이 함수 하나만 부르면 된다. '소모되는가'는 결과가 0인지로 판단한다.
  int anlasFor(AnlasJob job) {
    switch (job) {
      case AnlasJob.generate:
        return _estimateImageJob();
      case AnlasJob.inpaint:
        return _estimateImageJob(strength: infillStrength, i2iSize: i2iSendSize);
      case AnlasJob.img2img:
        return _estimateImageJob(strength: img2imgStrength, i2iSize: i2iSendSize);
      case AnlasJob.director:
        return directorCostFor(directorTool);
      case AnlasJob.upscale:
        // V5 업스케일러는 입력 크기·구독 등급과 무관하게 고정 비용이다
        return NovelAiService.upscaleAnlasCost;
    }
  }

  /// 생성·인페인트·img2img 공통 계산.
  ///  [strength] 가 있으면 인페인트 계열(기본 비용 x 강도)로 본다.
  ///  [i2iSize] 가 있으면 i2i — 그 크기로 한 장만 센다 (생성 해상도·장수·바이브와 무관).
  ///  [samples] 가 2 이상이면 '한 번에 여러 장' (생성 버튼 꾹 — n_samples) — 연속 생성 장수와 무관하게 그 장수로 센다.
  ///  ⚠️ 예전엔 i2i 도 생성 설정으로 셌다. 밖에서 가져온 큰 그림을 인페인트해도 '무료'로 나왔다.
  int _estimateImageJob({double? strength, (int, int)? i2iSize, int samples = 1}) {
    final bool isI2i = i2iSize != null;
    final bool multi = !isI2i && samples > 1;
    // 무료 조건이면 굳이 추정하지 않는다 — 여러 장 동시 생성은 무료가 아니라 여기서 돌려보내지 않는다
    if (!isI2i && !multi && !checkIfAnlasConsumed()) {
      return 0;
    }
    final (w, h) = i2iSize ?? _plannedResolution();
    final steps = effectiveSteps; // Medium 이면 14 고정

    int per = _estimateSingleAnlas(w, h, steps, strength: strength);
    if (per < 0) {
      return -1;
    }

    // 배치: 무한(0)은 셀 수 없으므로 1장 기준으로 둔다 (i2i 는 늘 한 장)
    int count = isI2i
        ? 1
        : multi
        ? samples
        : (batchCount <= 0 ? 1 : batchCount);
    // Opus 는 28스텝 이하·1MP 이하 한 장을 무료로 만들어 준다
    //  공식 설명상 '한 번에 한 장' 일 때만 — 여러 장을 한 번에 만들면 전부 Anlas 다
    if (!multi && _opusFreeSize(w, h, steps) && count > 0) {
      count -= 1;
    }

    // i2i 는 바이브·정밀 참조를 보내지 않는다
    //  여러 장 동시 생성: 바이브 인코딩은 요청에 한 번, 정밀 참조는 장마다로 센다 (어디까지나 추정)
    final extras = isI2i
        ? 0
        : calculateVibeAnlas() + calculatePreciseAnlas() * (multi ? samples : 1);
    return per * count + extras;
  }

  /// 생성 버튼 꾹 — [samples] 장을 한 번에 만들 때의 Anlas 추정 (-1 = 추정할 수 없음). 무료인 경우는 없다.
  int anlasForSamples(int samples) => _estimateImageJob(samples: samples);

  /// 실행 버튼에 'Anlas 가 든다' 빨간 표시를 할지 — 확인 창을 끈 경우(skipAnlasConfirm)에만, 비용이 0 이 아닐 때.
  ///  창이 뜨는 동안엔 창이 알려 주므로 표시하지 않는다.
  bool anlasMarked(int cost) => skipAnlasConfirm && cost != 0;

  /// Opus 무료 크기인지 — 28스텝 이하 · 1MP 이하 한 장은 Anlas 가 들지 않는다.
  ///  (비용 추정 · 소모 여부 판단 · 다시 뽑기 추정이 같은 규칙을 쓰게 한 곳에)
  ///  [model] 은 생성할 모델 (없으면 지금 고른 모델).
  ///  ⚠️ V5(한도가 있는 모델)는 무료 한도가 바닥났으면 무료가 아니다 — 공식 설명상 그때부터는 Anlas 로 생성된다.
  ///     예전엔 크기 · 스텝만 봐서, 한도가 다 된 뒤에도 '소모 없음' 으로 확인 없이 생성됐다.
  bool _opusFreeSize(int width, int height, int steps, {String? model}) =>
      subscriptionTier >= 3 &&
      steps <= 28 &&
      width * height <= kMegapixelCap &&
      !(modelCapsFor(model ?? selectedModel).hasHourlyLimit && v5LimitExhausted);

  /// 추정치를 화면에 보여 줄 문장으로 바꾼다.
  ///  ⚠️ 공식 계산식을 재현하지 못해 실측 표 기반 추정이다. 그래서 '약' 을 붙인다.
  static String anlasText(int cost) {
    if (cost == 0) {
      return "Anlas가 소모되지 않습니다.";
    }
    if (cost < 0) {
      return "Anlas가 소모됩니다. (소모량은 추정할 수 없습니다)";
    }
    return "약 $cost Anlas가 소모됩니다.";
  }

  /// 지금 설정으로 생성했을 때 실제로 쓰일 해상도.
  ///  비용 추정과 소모 여부 판단이 같은 값을 보도록 한 곳으로 모았다.
  (int, int) _plannedResolution() {
    var (width, height) = (kDefaultWidth, kDefaultHeight); // 아래에서 모드별로 정해진다

    if (resolutionMode == "랜덤") {
      width = 1024;
      height = 1024;
    } else if (resolutionMode == "자동" && currentImageWidth > 0 && currentImageHeight > 0) {
      double maxPixels = kMegapixelCap.toDouble();
      double ratio = currentImageWidth / currentImageHeight;
      double h = sqrt(maxPixels / ratio);
      double w = h * ratio;
      width = (w / 64).round() * 64;
      height = (h / 64).round() * 64;

      while ((width * height) > kMegapixelCap) {
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
    } else if (selectedResolution == kCustomResolutionLabel ||
        (resolutionMode == "자동" && currentImageWidth == 0)) {
      (width, height) = _customResolution();
    } else {
      (width, height) = resolutionOrDefault(selectedResolution);
    }

    // 해상도 배율 + 64px 정렬 + 모델별 픽셀 상한 (생성과 같은 공용 헬퍼)
    (width, height) = scaledResolution(width, height, resolutionScale, modelCapsFor(selectedModel).maxPixels);

    return (width, height);
  }

  /// 상세 환경의 직접 입력 해상도 (배율 · 상한 전). 숫자가 아니면 기본값.
  (int, int) _customResolution() => (
    int.tryParse(customWidthController.text) ?? kDefaultWidth,
    int.tryParse(customHeightController.text) ?? kDefaultHeight,
  );

  /// 확장(i2i 탭 · 인페인트로 빈칸 채우기)의 판 크기 — 상세 환경에서 고른 해상도(프리셋 · 직접 입력) × 배율, 모델 상한 안.
  ///  랜덤 · 자동 모드여도 '수동' 칸에 골라 둔 해상도를 쓴다 (판이 생성할 때마다 바뀌면 그림을 놓을 수 없다).
  ///  [scaledResolution] 이 64 의 배수로 맞추므로 그대로 서버에 보낼 수 있다.
  (int, int) get outpaintCanvasSize {
    final (int w, int h) = selectedResolution == kCustomResolutionLabel
        ? _customResolution()
        : resolutionOrDefault(selectedResolution);
    return scaledResolution(w, h, resolutionScale, modelCapsFor(selectedModel).maxPixels);
  }

  /// 확장의 예상 Anlas — 판 크기 한 장 · 강도 1 (빈칸은 늘 새로 그린다 — kOutpaintStrength)
  int get outpaintAnlas => _estimateImageJob(strength: kOutpaintStrength, i2iSize: outpaintCanvasSize);

  /// 부분 인페인트로 보낼 넓이 상한 — 1MP (공식 '약 1메가픽셀' · Opus 무료 기준). 모델 상한이 더 작으면 그것.
  int get focusTargetPixels {
    final int cap = modelCapsFor(selectedModel).maxPixels;
    return cap > 0 ? min(kMegapixelCap, cap) : kMegapixelCap;
  }

  /// 부분 인페인트 계획 — 지금 그림의 상자 [box] (그림 픽셀). 그림 크기를 모르면 null.
  FocusPlan? focusPlanFor(OutpaintRect box) {
    final (int, int)? size = i2iImageSize;
    if (size == null) {
      return null;
    }
    return focusPlan(
      box,
      size.$1,
      size.$2,
      context: focusInpaintContext,
      targetPixels: focusTargetPixels,
    );
  }

  /// 부분 인페인트의 예상 Anlas — 보낼 크기(약 1MP) 한 장 · 인페인트 강도. 그림이 커도 Opus 는 대개 무료다.
  int focusAnlas(FocusPlan plan) =>
      _estimateImageJob(strength: infillStrength, i2iSize: (plan.sendW, plan.sendH));

  bool checkIfAnlasConsumed() {
    final (width, height) = _plannedResolution();

    int steps = effectiveSteps; // Medium 이면 14 고정

    // 모델이 지원하지 않으면 vibe/precise는 전송되지 않으므로 비용 계산에서도 제외
    final capsForCost = modelCapsFor(selectedModel);

    // 활성 Precise Reference는 항상 Anlas 소모
    bool hasPrecise =
        capsForCost.supportsPrecise && preciseRefs.any((r) => (r['enabled'] as bool?) ?? true);
    if (hasPrecise) {
      return true;
    }

    // Vibe Transfer: 활성화된 것만, 인코딩 안 된 것이 있거나 4개 초과면 Anlas 소모
    final activeVibes = capsForCost.supportsVibe
        ? vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList()
        : <Map<String, dynamic>>[];
    if (activeVibes.isNotEmpty) {
      bool hasUnencodedVibe = activeVibes.any(_vibeNeedsEncode);
      bool tooManyVibes = activeVibes.length > 4;
      if (hasUnencodedVibe || tooManyVibes) {
        return true;
      }
      // 전부 인코딩됨 + 4개 이하 → 해상도/스텝 기준으로만 판단 (아래로 진행)
    }

    if (_opusFreeSize(width, height, steps)) {
      return false;
    }

    return true;
  }

  // Vibe Transfer Anlas 비용 계산 (UI 표시용)
  /// 이번 생성에서 이 Vibe 를 (다시) 인코딩해야 하는지 — 2 Anlas.
  ///  보내는 쪽(NovelAiService.generateImage)의 캐시 판단과 같게: 인코딩이 없거나, 다른 모델 · 다른 정보추출 값으로 한 것.
  ///  ⚠️ 예전엔 인코딩이 '있는지' 만 봐서, 모델을 바꾼 뒤 다시 인코딩하는 2 Anlas 를 '소모 없음' 으로 셌다.
  bool _vibeNeedsEncode(Map<String, dynamic> v) =>
      v['_encoded'] == null ||
      v['_encodedModel'] != modelCapsFor(selectedModel).serverModelId ||
      v['_encodedInfoExt'] != ((v['infoExtracted'] as double?) ?? 1.0);

  int calculateVibeAnlas() {
    if (!modelCapsFor(selectedModel).supportsVibe) {
      return 0; // 이 모델은 Vibe 를 보내지 않는다 (예: V5) — 담겨 있어도 비용이 없다
    }
    final activeVibes = vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList();
    if (activeVibes.isEmpty) {
      return 0;
    }
    int cost = 0;
    // 인코딩 안 된 vibe당 2 Anlas
    for (final v in activeVibes) {
      if (_vibeNeedsEncode(v)) {
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

  // ── 와일드카드 이름 ─────────────────────────────────────────────
  //  프롬프트에서 __이름__ 으로 부르고, 이름이 같은 와일드카드 중 '먼저 있는 하나'만 쓰인다.
  //  그래서 이름이 비거나 겹치거나 부르는 기호와 부딪히면 조용히 안 불린다.

  /// [name] 을 와일드카드 이름으로 쓸 수 없으면 그 이유(안내 문구), 쓸 수 있으면 null.
  ///  [except] 는 이름을 바꾸는 중인 자기 자신 (자기 이름과 같은 건 괜찮다).
  String? wildcardNameProblem(String name, {NaiWildcard? except}) {
    final n = name.trim();
    if (n.isEmpty) {
      return "이름을 입력해 주세요.";
    }
    if (n.contains('__')) {
      return "이름에 '__' 는 쓸 수 없어요 (와일드카드를 부르는 기호예요).";
    }
    if (n.startsWith('@')) {
      return "'@' 로 시작할 수 없어요 (순서대로 부르는 기호예요).";
    }
    if (wildcards.any((w) => !identical(w, except) && w.name == n)) {
      return "'$n' 은(는) 이미 있어요. 이름이 겹치면 하나만 불려요.";
    }
    return null;
  }

  /// 새 와일드카드를 맨 앞에 만들고 고른다. 이름 문제가 있으면 그 이유를 돌려주고 만들지 않는다.
  String? createWildcard(String name) {
    final problem = wildcardNameProblem(name);
    if (problem != null) {
      return problem;
    }
    wildcards.insert(0, NaiWildcard(name: name.trim(), content: ""));
    selectedWildcardIndex = 0;
    saveAndRefresh();
    return null;
  }

  /// 와일드카드 이름을 바꾼다 (되돌리기 기록도 새 이름으로 옮긴다). 문제가 있으면 그 이유.
  String? renameWildcard(NaiWildcard card, String newName) {
    final n = newName.trim();
    final problem = wildcardNameProblem(n, except: card);
    if (problem != null) {
      return problem;
    }
    // ⚠️ 새 이름이 다른 와일드카드 것이면 그쪽 기록을 덮어쓸 수 있었다 — 위 검사로 막는다
    renameUndoKey('wildcard/${card.name}', 'wildcard/$n');
    card.name = n;
    saveAndRefresh();
    return null;
  }

  /// 와일드카드가 하나도 없으면 빈 것 하나를 두고, 선택 번호를 범위 안으로.
  ///  목록을 통째로 바꾸는 곳(앱 켤 때·백업 복원·삭제)에서 부른다.
  ///  ⚠️ 예전엔 세 곳이 각자 다른 이름('의상'·'새 와일드카드'·'기본')으로 채웠고,
  ///     그중 하나는 화면을 그리는 도중에 데이터를 바꿨다.
  void ensureWildcards() {
    if (wildcards.isEmpty) {
      wildcards.add(NaiWildcard(name: "새 와일드카드", content: ""));
    }
    if (selectedWildcardIndex < 0 || selectedWildcardIndex >= wildcards.length) {
      selectedWildcardIndex = 0;
    }
  }

  void selectWildcard(int index) {
    if (index > 0 && index < wildcards.length) {
      final selected = wildcards.removeAt(index);
      wildcards.insert(0, selected);
    }
    selectedWildcardIndex = 0;
    saveAndRefresh();
  }

  void deleteWildcard(int index) {
    if (wildcards.isEmpty || index < 0 || index >= wildcards.length) {
      return;
    }

    wildcards.removeAt(index);
    // 지운 와일드카드의 되돌리기 기록도 버린다
    pruneUndoKeys('wildcard/', wildcards.map((w) => w.name));

    selectedWildcardIndex = 0;
    ensureWildcards(); // 마지막 하나를 지웠으면 빈 것 하나

    saveAllSettings();
    notifyListeners();
  }
}
