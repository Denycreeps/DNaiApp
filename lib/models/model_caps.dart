// lib/models/model_caps.dart
//
// NovelAI 모델별 능력(capability)을 한 곳에서 정의한다.
//
// 목적: 기능별(이미지 생성 / Vibe / Precise / 인페인트 / 업스케일 ...)로
//       "현재 모델이 무엇을 지원하는가"를 문자열 비교로 여기저기 흩뿌리지 않고,
//       이 파일 한 곳만 참조하도록 만든다.
//
// 새 모델(예: v5 curated)이 출시되면:
//   1) NaiModels 에 API 문자열 상수 추가
//   2) _capsTable 에 ModelCaps 한 항목 추가
//   3) (UI/서비스는 자동으로 modelCapsFor() 를 통해 반영)
//
// ⚠️ 이 파일은 아직 "정의"만 담는다. 실제 API 호출부/UI 연결(하드코딩 분기 치환)은
//    다음 단계에서 점진적으로 진행한다. (지금 단계에서는 기존 동작 변화 없음)

import 'dart:math' show sqrt;

/// 프롬프트 토큰을 세는 방식.
///  모델마다 토크나이저가 달라 같은 글에서도 토큰 수가 크게 달라진다.
enum PromptTokenizer {
  /// V4 / V4.5 — T5 서브워드. 영문 태그 기준 평균 3.1글자당 1토큰.
  t5,

  /// V5 — Qwen 계열 BPE. 글자수 비례가 전혀 맞지 않는다.
  ///  (실측: 영문 태그 4.2글자/토큰, 가중치 구문 2.0, 일본어 1.0)
  qwen,
}

/// NovelAI API 모델 문자열 상수 모음.
class NaiModels {
  // ---- 현재 사용 중인 모델 ----
  static const String v45Full = 'nai-diffusion-4-5-full';
  static const String v45Curated = 'nai-diffusion-4-5-curated';
  static const String v4Full = 'nai-diffusion-4-full';
  static const String v4Curated = 'nai-diffusion-4-curated';
  static const String v3 = 'nai-diffusion-3';
  static const String furryV3 = 'nai-diffusion-furry-3';
  static const String v2 = 'nai-diffusion-2'; // infill 접미사 예외 처리용 (레거시)

  // ---- v5 ----
  static const String v5Full = 'nai-diffusion-5-full';

  /// V5 Full 의 'Medium' effort (2026-10 공식 추가) — 14스텝용으로 증류한 별도 모델.
  ///  요청에 effort 값을 넣는 게 아니라 모델 이름을 바꿔 보낸다 (인페인트는 뒤에 -inpainting).
  ///  고를 수 있는 모델 목록에는 넣지 않는다 — V5 Full 을 고른 채 상세 환경의 Effort 를 켜면 이 이름으로 보낸다.
  ///  ⚠️ 공식 문서엔 API 표기가 없어, 공식 웹 코드를 옮긴 다른 앱들(ComfyUI_RS_NAI_API_Request · MooshieUI)의 값을 따른다.
  static const String v5FullMedium = 'nai-diffusion-5-full-medium';
}

/// Medium effort 에서 공식이 잠그는 값 (공식 안내: 스텝 14 · Euler Ancestral · CFG Rescale 미지원 · 부정 프롬프트 고정)
const int kMediumEffortSteps = 14;
const String kMediumEffortSampler = 'k_euler_ancestral';

/// 그림 정보의 모델 이름(Source)이 V5 Full Medium(생성 · 인페인트)인지 — 이름 뒤의 해시로 가른다.
///  ⚠️ 공식 문서에 없는 값이라 다른 앱(MooshieUI)이 공식 웹에서 옮긴 해시를 따른다.
///     틀리면 Medium 그림을 High(V5 Full)로 볼 뿐이다 (다시 생성이 High 로 만든다).
bool isMediumEffortSource(String source) {
  final String s = source.toLowerCase();
  return s.contains('93f4bd30') || s.contains('70ab5786');
}

/// 한 모델이 지원하는 기능 / 제약을 나타낸다.
///
/// bool 필드는 "이 모델에서 해당 기능을 켤 수 있는가"를 뜻하고,
/// uses* 필드는 "API 요청을 어떤 방식으로 만들어야 하는가"를 뜻한다.
class ModelCaps {
  /// API 모델 문자열 (예: nai-diffusion-4-5-full)
  final String id;

  /// 서버로 실제 전송할 모델 문자열 override.
  /// null이면 [id]를 그대로 사용한다.
  /// 테스트 모델처럼 "UI id"와 "실제 전송 id"가 다를 때만 지정한다.
  final String? serverModelIdOverride;

  /// 서버로 실제 전송할 모델 문자열. (override 없으면 id)
  String get serverModelId => serverModelIdOverride ?? id;

  /// UI 표시용 이름
  final String displayName;

  // ---- 기능 지원 여부 ----
  /// Vibe Transfer 사용 가능
  final bool supportsVibe;

  /// Precise Reference(director reference) 사용 가능
  final bool supportsPrecise;

  /// 인페인트(마스킹 부분 재생성) 사용 가능
  final bool supportsInpaint;

  /// i2i(이미지→이미지) 사용 가능
  final bool supportsImg2img;

  /// 업스케일 사용 가능
  final bool supportsUpscale;

  /// Variety+ (skip_cfg_above_sigma) 사용 가능
  /// V5에서 동작 여부가 확인되지 않아 기본적으로 막아둔다.
  final bool supportsVarietyPlus;

  // ---- API 요청 구성 방식 ----
  /// v4_prompt / v4_negative_prompt 필드를 요청에 넣어야 하는 아키텍처인가.
  /// (V4 계열 아키텍처는 true. V3 등 구형은 false)
  final bool usesV4Prompt;

  /// Vibe를 encode-vibe 엔드포인트로 인코딩해야 하는가.
  /// (V4 이상: true / V3 구식 vibe: false — reference_image 방식)
  final bool usesEncodeVibe;

  // ---- 수치 제약 ----
  /// 프롬프트 토큰 상한(근사치). base + 캐릭터 프롬프트 합산 기준.
  /// V4/V4.5: ~512 (T5 토크나이저). 값이 0이면 "미확인/해당없음".
  final int maxPromptTokens;

  /// 캐릭터 프롬프트 최대 개수 (V4.5=6, V5=32)
  final int maxCharacters;

  /// 이 모델이 쓰는 토크나이저 계열. 토큰 추정 방식을 고른다.
  ///  V4/V4.5 : T5 (글자수/3.1 근사)
  ///  V5      : Qwen 계열 BPE — 글자수 근사가 크게 빗나가므로 구조 기반으로 센다
  final PromptTokenizer tokenizer;

  /// CFG(Guidance) 상한. V5는 10까지만 허용된다.
  final double maxCfgScale;

  /// 스텝 상한 (검증 기준)
  final int maxSteps;

  /// 공식 UI가 고정해 두는 노이즈 스케줄. null 이면 자유롭게 고른다.
  ///  V5는 karras — 설정의 '스케줄러 잠금 해제'를 켜야 다른 값을 쓸 수 있다
  ///  (보낼 때 판단은 AppState.schedulerFor 한 곳).
  final String? fixedScheduler;

  /// 총 픽셀 상한 (width * height)
  final int maxPixels;

  /// 투명 배경(알파 채널)을 지원하는지. V5부터 가능.
  final bool supportsTransparency;

  /// 캐릭터 위치를 자유 좌표로 찍을 수 있는지 (V5). false면 5x5 그리드.
  final bool usesFreePositioning;

  /// 업스케일 입력 최대 픽셀 수(width * height). 0이면 제한 없음.
  final int maxUpscalePixels;

  /// 시간당 생성 한도가 있는 모델인가 (V5). true면 생성 후 잔여 한도를 조회한다.
  final bool hasHourlyLimit;

  // ---- 상태 ----
  /// 아직 정식 출시 전(값이 확정되지 않은 placeholder)인가.
  /// true면 UI에서 선택지로 노출하지 않는 등 별도 처리 가능.
  final bool isPlaceholder;

  const ModelCaps({
    required this.id,
    required this.displayName,
    required this.supportsVibe,
    required this.supportsPrecise,
    required this.supportsInpaint,
    required this.supportsImg2img,
    required this.supportsUpscale,
    required this.supportsVarietyPlus,
    required this.usesV4Prompt,
    required this.usesEncodeVibe,
    required this.maxPromptTokens,
    this.maxCharacters = 6,
    this.tokenizer = PromptTokenizer.t5,
    this.maxCfgScale = 25.0,
    this.maxSteps = 50,
    this.fixedScheduler,
    this.maxPixels = 3145728,
    this.supportsTransparency = false,
    this.usesFreePositioning = false,
    this.hasHourlyLimit = false,
    required this.maxUpscalePixels,
    this.serverModelIdOverride,
    this.isPlaceholder = false,
  });

  /// 일부 값만 바꾼 사본 생성 (테이블 정의 시 중복 줄이기용).
  ModelCaps copyWith({
    String? id,
    String? serverModelIdOverride,
    String? displayName,
    bool? supportsVibe,
    bool? supportsPrecise,
    bool? supportsInpaint,
    bool? supportsImg2img,
    bool? supportsUpscale,
    bool? supportsVarietyPlus,
    bool? usesV4Prompt,
    bool? usesEncodeVibe,
    int? maxPromptTokens,
    int? maxCharacters,
    PromptTokenizer? tokenizer,
    double? maxCfgScale,
    int? maxSteps,
    String? fixedScheduler,
    int? maxPixels,
    bool? supportsTransparency,
    bool? usesFreePositioning,
    bool? hasHourlyLimit,
    int? maxUpscalePixels,
    bool? isPlaceholder,
  }) {
    return ModelCaps(
      id: id ?? this.id,
      serverModelIdOverride: serverModelIdOverride ?? this.serverModelIdOverride,
      displayName: displayName ?? this.displayName,
      supportsVibe: supportsVibe ?? this.supportsVibe,
      supportsPrecise: supportsPrecise ?? this.supportsPrecise,
      supportsInpaint: supportsInpaint ?? this.supportsInpaint,
      supportsImg2img: supportsImg2img ?? this.supportsImg2img,
      supportsUpscale: supportsUpscale ?? this.supportsUpscale,
      supportsVarietyPlus: supportsVarietyPlus ?? this.supportsVarietyPlus,
      usesV4Prompt: usesV4Prompt ?? this.usesV4Prompt,
      usesEncodeVibe: usesEncodeVibe ?? this.usesEncodeVibe,
      maxPromptTokens: maxPromptTokens ?? this.maxPromptTokens,
      maxCharacters: maxCharacters ?? this.maxCharacters,
      tokenizer: tokenizer ?? this.tokenizer,
      maxCfgScale: maxCfgScale ?? this.maxCfgScale,
      maxSteps: maxSteps ?? this.maxSteps,
      fixedScheduler: fixedScheduler ?? this.fixedScheduler,
      maxPixels: maxPixels ?? this.maxPixels,
      supportsTransparency: supportsTransparency ?? this.supportsTransparency,
      usesFreePositioning: usesFreePositioning ?? this.usesFreePositioning,
      hasHourlyLimit: hasHourlyLimit ?? this.hasHourlyLimit,
      maxUpscalePixels: maxUpscalePixels ?? this.maxUpscalePixels,
      isPlaceholder: isPlaceholder ?? this.isPlaceholder,
    );
  }
}

// ============================================================================
// 능력 테이블
// ============================================================================

/// V4.5 계열의 기준 능력값.
/// (조사 근거: Precise는 V4.5 전용 / Vibe는 V4부터 encode-vibe 방식 /
///  토큰 ~512 T5 / 인페인트·i2i·업스케일 지원)
const ModelCaps _v45Full = ModelCaps(
  id: NaiModels.v45Full,
  displayName: 'NAI Diffusion V4.5 Full',
  supportsVibe: true,
  supportsPrecise: true,
  supportsInpaint: true,
  supportsImg2img: true,
  supportsUpscale: true,
  supportsVarietyPlus: true,
  usesV4Prompt: true,
  usesEncodeVibe: true,
  maxPromptTokens: 512,
  // 업스케일 API는 1024x1024(=1,048,576px) 이하 원본만 받는다.
  //  (앱이 이미 모든 모델에 이 값을 강제하고 있어 그대로 옮겨 왔다)
  maxUpscalePixels: 1024 * 1024,
  isPlaceholder: false,
);

// V5 Full. 32채널 VAE·알파 투명도 지원, 더 긴 프롬프트.
// 요청 포맷(v4_prompt)과 인페인트 방식은 V4.5와 동일하다.
// Vibe / Precise Reference 는 초기 버전에서 사용 불가.
const ModelCaps _v5Full = ModelCaps(
  id: NaiModels.v5Full,
  displayName: 'NovelAI v5 Full',
  supportsVibe: false, // V5 초기 버전 미지원
  supportsPrecise: false, // V5 초기 버전 미지원
  supportsInpaint: true,
  supportsImg2img: true,
  supportsUpscale: true,
  supportsVarietyPlus: true, // skip_cfg_above_sigma 사용 확인됨
  usesV4Prompt: true, // V4.5와 동일 포맷
  usesEncodeVibe: false, // Vibe 미지원
  maxPromptTokens: 1471, // V5는 프롬프트 상한이 크게 늘었다 (V4.5는 512)
  maxCharacters: 32, // V4.5는 6개, V5는 32개 슬롯
  tokenizer: PromptTokenizer.qwen, // T5가 아니라 Qwen 계열 BPE
  maxCfgScale: 10.0, // V5 Guidance 상한
  maxSteps: 50,
  fixedScheduler: 'karras', // 공식 UI는 스케줄러 선택기를 숨긴다 (설정에서 잠금 해제 가능)
  maxPixels: 3145728,
  supportsTransparency: true, // 32채널 VAE가 알파를 네이티브 지원
  usesFreePositioning: true, // 그리드 대신 캔버스에서 자유 배치
  hasHourlyLimit: true, // V5는 시간당 생성 한도가 있다
  maxUpscalePixels: 1024 * 1024,
);

// V3 계열 (nai-diffusion-3 / nai-diffusion-furry-3).
// V4 이전 아키텍처라 요청 구성 방식이 근본적으로 다르다.
//  · v4_prompt 필드를 쓰지 않는다 (프롬프트를 통째로 하나 보낸다)
//  · 캐릭터 프롬프트 개념 자체가 없다 → maxCharacters 0
//  · Vibe는 encode-vibe가 아니라 reference_image 방식
//  · Precise Reference(director reference)는 V4.5 전용이라 미지원
// 이 항목이 없으면 modelCapsFor()가 V4.5 캡으로 폴백해
// "V3인데 Precise 지원"이라고 잘못 대답한다.
const ModelCaps _v3 = ModelCaps(
  id: NaiModels.v3,
  displayName: 'NAI Diffusion Anime V3',
  supportsVibe: true, // 구식 reference_image 방식
  supportsPrecise: false, // V4.5 전용 기능
  supportsInpaint: true,
  supportsImg2img: true,
  supportsUpscale: true,
  supportsVarietyPlus: true, // 기존 동작 유지 (확인되면 조정)
  usesV4Prompt: false, // ★ V4 이전 아키텍처
  usesEncodeVibe: false, // ★ encode-vibe 엔드포인트를 쓰지 않는다
  maxPromptTokens: 225, // CLIP 토크나이저 (75 x 3 청크)
  maxCharacters: 0, // 캐릭터 프롬프트 미지원
  maxCfgScale: 25.0,
  maxSteps: 50,
  maxPixels: 3145728,
  supportsTransparency: false,
  usesFreePositioning: false,
  maxUpscalePixels: 0,
);

/// 모델 문자열 → ModelCaps 매핑 테이블.
final Map<String, ModelCaps> _capsTable = {
  // ---- V4.5 ----
  NaiModels.v45Full: _v45Full,
  NaiModels.v45Curated: _v45Full.copyWith(
    id: NaiModels.v45Curated,
    displayName: 'NAI Diffusion V4.5 Curated',
  ),

  // ---- V4 (현재는 V4.5와 동일하게 취급) ----
  // ※ 참고: NovelAI 공식상 Precise Reference는 V4.5 전용이지만,
  //    현재 앱 동작(=V4/V4.5 동일 취급)에 맞춰 캡도 동일하게 둔다.
  //    실제 API 연결 단계에서 필요하면 이 부분만 갈라주면 된다.
  NaiModels.v4Full: _v45Full.copyWith(id: NaiModels.v4Full, displayName: 'NAI Diffusion V4 Full'),
  NaiModels.v4Curated: _v45Full.copyWith(
    id: NaiModels.v4Curated,
    displayName: 'NAI Diffusion V4 Curated',
  ),

  // ---- V5 (임시 테스트) ----
  NaiModels.v5Full: _v5Full,

  // ---- V3 계열 (UI 선택지에는 없지만, 히스토리 메타데이터 재생성 경로로 들어온다) ----
  //  app_state._resolveModelId()가 "V3" 메타데이터를 만나면 이 값을 돌려준다.
  NaiModels.v3: _v3,
  NaiModels.furryV3: _v3.copyWith(id: NaiModels.furryV3, displayName: 'NAI Diffusion Furry V3'),
  // 레거시 V2 — 정확한 캡은 미확인이나, 최소한 V4.5로 오인되지 않게 V3 기준으로 둔다.
  NaiModels.v2: _v3.copyWith(id: NaiModels.v2, displayName: 'NAI Diffusion V2'),
};

/// 알 수 없는 모델 문자열에 대한 안전 기본값.
/// (미지의 모델이 와도 앱이 죽지 않도록 V4.5 기준으로 폴백)
ModelCaps _fallbackCaps(String model) {
  return _v45Full.copyWith(id: model, displayName: model);
}

/// 모델 문자열로 능력을 조회한다.
/// 정확 매칭 우선, 실패 시 부분 매칭(4-5 / 4 / 5 등), 최후에 폴백.
ModelCaps modelCapsFor(String model) {
  // 1) 정확 매칭
  final exact = _capsTable[model];
  if (exact != null) {
    return exact.copyWith(id: model);
  }

  // 2) 부분 매칭 (예: -inpainting 접미사가 붙은 경우 등)
  //    가장 구체적인 것부터 검사한다.
  // v5 계열 (4-5 / 4.5 는 V4.5이므로 먼저 걸러야 한다)
  if (!model.contains('4-5') && !model.contains('4.5') && model.contains('5')) {
    return _v5Full.copyWith(id: model);
  }
  if (model.contains('4-5') || model.contains('4.5')) {
    return _v45Full.copyWith(id: model);
  }
  if (model.contains('4')) {
    return _v45Full.copyWith(id: model);
  }
  // v3 계열 (nai-diffusion-3-inpainting 등 접미사가 붙은 경우)
  //  ※ 위에서 4/5를 모두 걸러낸 뒤이므로 여기 오는 '3'은 V3가 맞다.
  if (model.contains('3')) {
    return _v3.copyWith(
      id: model,
      displayName: model.contains('furry') ? 'NAI Diffusion Furry V3' : 'NAI Diffusion Anime V3',
    );
  }

  // 3) 폴백
  return _fallbackCaps(model);
}

/// 한 변의 최대 길이 — 64 의 배수여야 한다.
///  (예전엔 9999 로 잘라서, 그보다 긴 값을 넣으면 64 의 배수가 아닌 값이 그대로 나갔다)
const int kMaxResolutionSide = 9984;

/// 해상도를 64px 단위로 맞추고, [maxPixels](총 픽셀 상한, 0 이하면 상한 없음)를 넘으면
/// 비율을 지킨 채 상한 안에서 가장 크게 줄인다.
///  NovelAI는 64의 배수만 받고, 총 픽셀 상한도 있다.
///  직접 입력 해상도 저장 · 생성 · 비용 추정 · 미리보기가 모두 이것(과 [scaledResolution])을 거친다.
///  ⚠️ 예전엔 긴 변만 64 씩 깎아서, 상한을 크게 넘으면 그림 모양이 바뀌었다
///     (직접 입력 2048x3072 → 1792x1728 거의 정사각형 · 4000x3000 → 1792x1728).
(int, int) clampResolution(int width, int height, int maxPixels) =>
    _fitResolution(width.toDouble(), height.toDouble(), maxPixels);

/// 해상도 배율 단계 — 상세 환경의 배율 버튼을 누를 때마다 이 순서로 돈다 (1x → 1.25x → 1.5x → 1x).
///  · 1.25x: 832x1216 · 1216x832 에 곱하면 공식 Large(1024x1536 · 1536x1024)와 같은 크기
///  · 1.5x : 예전부터 있던 값 — 예전 저장값 · 백업이 그대로 이어진다
///  ⚠️ 2배는 넣지 않는다 — 기본 해상도만 해도 4MP 라 픽셀 상한을 넘는다.
///     더 크게 하려면 직접 입력 해상도에 배율을 곱한다 (상한에서 비율을 지킨 채 멈춘다).
const List<double> kResolutionScales = [1.0, 1.25, 1.5];

/// 목록에 있는 배율이면 그대로, 아니면(옛 값 · 잘못된 백업) 1.0
double validResolutionScale(double v) => kResolutionScales.contains(v) ? v : 1.0;

/// 배율 버튼을 한 번 눌렀을 때의 다음 배율 (끝에서는 1x 로 돌아간다)
double nextResolutionScale(double current) {
  final i = kResolutionScales.indexOf(current);
  return kResolutionScales[(i + 1) % kResolutionScales.length];
}

/// 배율 버튼 글자 — 1.0 → "1x", 1.25 → "1.25x", 1.5 → "1.5x"
String resolutionScaleLabel(double scale) =>
    '${scale.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}x';

/// 배율을 곱한 실제 생성 해상도 — 생성 · 비용 추정 · 상세 환경 미리보기가 모두 이것 하나를 쓴다.
///  [width]x[height] 에 [scale] 을 곱한 뒤 [clampResolution] 과 같은 규칙 (64 정렬 · 상한을 넘으면 비율 유지).
///  배율이 1 이면 clampResolution 과 똑같다.
///  ⚠️ 예전엔 곱한 뒤 긴 변만 깎아서 모양이 바뀌었다 (832x1216 의 2배 → 1664x1856, 거의 정사각형).
(int, int) scaledResolution(int width, int height, double scale, int maxPixels) =>
    _fitResolution(width * scale, height * scale, maxPixels);

/// [clampResolution] · [scaledResolution] 의 실제 계산 (둘이 따로 계산하지 않게 한 곳에).
///  1) 64 단위 반올림 · 한 변 64 ~ [kMaxResolutionSide]. 상한 안이면 여기서 끝 (예전과 같은 값)
///  2) 상한을 넘으면 상한에 딱 맞는 배율로 다시 — 64 단위 내림 · 올림 네 조합 중 상한 안에서
///     비율이 원래와 가장 가까운 것 (비율이 같으면 큰 쪽)
///  3) 그래도 못 고르면 (한 변이 64 밑으로 내려가야 하는 아주 가는 그림) 예전처럼 긴 변부터 64 씩
(int, int) _fitResolution(double width, double height, int maxPixels) {
  int w = ((width / 64).round() * 64).clamp(64, kMaxResolutionSide);
  int h = ((height / 64).round() * 64).clamp(64, kMaxResolutionSide);
  if (maxPixels <= 0 || w * h <= maxPixels) {
    return (w, h);
  }
  if (width > 0 && height > 0) {
    final fit = sqrt(maxPixels / (width * height));
    final ratio = width / height;
    final fw = width * fit / 64;
    final fh = height * fit / 64;
    (int, int)? best;
    double bestErr = double.infinity;
    for (final cw in {fw.floor(), fw.ceil()}) {
      for (final ch in {fh.floor(), fh.ceil()}) {
        final a = cw * 64;
        final b = ch * 64;
        if (a < 64 || b < 64 || a > kMaxResolutionSide || b > kMaxResolutionSide || a * b > maxPixels) {
          continue;
        }
        final err = ((a / b) / ratio - 1).abs();
        final bigger = best != null && a * b > best.$1 * best.$2;
        if (best == null || err < bestErr - 1e-9 || ((err - bestErr).abs() <= 1e-9 && bigger)) {
          best = (a, b);
          bestErr = err;
        }
      }
    }
    if (best != null) {
      return best;
    }
  }
  while (w * h > maxPixels && (w > 64 || h > 64)) {
    if (w > h) {
      w -= 64;
    } else {
      h -= 64;
    }
  }
  return (w, h);
}

// NAI 표준 해상도 목록 — 랜덤 해상도(app_state)와 상세 환경 드롭다운(detail_settings_modal)이 공유.
// 한쪽만 고쳐서 두 목록이 어긋나는 사고를 막기 위해 이곳 한 곳에서만 관리한다.
const List<String> kNaiResolutions = [
  "768 x 1344",
  "832 x 1216",
  "896 x 1152",
  "960 x 1088",
  "1024 x 1024",
  "1088 x 960",
  "1152 x 896",
  "1216 x 832",
  "1344 x 768",
];

// 샘플러 (API 값 → 화면 이름, NovelAI 웹과 같은 이름). 적힌 순서가 드롭다운 순서다.
//  ⚠️ "ddim" 은 뺐다 — V4 계열에서 정상 동작하지 않는다(노이즈 이미지/에러).
//  예전엔 이 목록이 상세 환경 화면 안에만 있고, 이름표도 따로 한 번 더 적혀 있었다.
const Map<String, String> kNaiSamplerNames = {
  "k_euler_ancestral": "Euler Ancestral",
  "k_euler": "Euler",
  "k_dpmpp_2s_ancestral": "DPM++ 2S Ancestral",
  "k_dpmpp_2m_sde": "DPM++ 2M SDE",
  "k_dpmpp_2m": "DPM++ 2M",
  "k_dpmpp_sde": "DPM++ SDE",
};

// 노이즈 스케줄 ('native' = 보내지 않아 서버 기본값을 쓴다)
const List<String> kNaiSchedulers = ["native", "karras", "exponential", "polyexponential"];

const String kDefaultSampler = "k_euler_ancestral";
const String kDefaultScheduler = "karras";

/// 목록에 있는 샘플러면 그대로, 아니면(옛 ddim·잘못된 백업 등) 기본값.
///  ⚠️ 목록에 없는 값이 상태에 남으면 드롭다운은 다른 걸 보여 주는데
///     실제로는 그 값이 전송된다. 값이 들어오는 모든 길에서 이걸 거친다.
String validSampler(Object? v) =>
    (v is String && kNaiSamplerNames.containsKey(v)) ? v : kDefaultSampler;

/// 목록에 있는 스케줄러면 그대로, 아니면 기본값.
///  (목록에 없는 값이면 드롭다운이 디버그 모드에서 빨간 화면으로 멈춘다)
String validScheduler(Object? v) =>
    (v is String && kNaiSchedulers.contains(v)) ? v : kDefaultScheduler;

// 상세 환경에서 고를 수 있는 모델 (적힌 순서가 드롭다운 순서)
//  예전엔 이 목록이 상세 환경 화면 안에만 있었고, 앱 상태는 옛 테스트 모델 이름 하나만
//  글자로 두 번 걸러 냈다. 이제 값이 들어오는 모든 길에서 validModel 을 거친다.
const List<String> kSelectableModels = [NaiModels.v4Full, NaiModels.v45Full, NaiModels.v5Full];
// 새로 설치했을 때(와 저장된 모델이 목록에 없을 때) 쓰는 모델.
//  기존 사용자는 저장된 모델을 그대로 쓴다.
const String kDefaultModel = NaiModels.v5Full;

/// 고를 수 있는 모델이면 그대로, 아니면(지워진 테스트 모델·옛 프리셋 등) 기본값.
///  ⚠️ 목록에 없는 값이 남으면 드롭다운은 다른 모델을 보여 주는데 실제로는 그 값으로 생성한다.
String validModel(Object? v) => (v is String && kSelectableModels.contains(v)) ? v : kDefaultModel;

// 해상도 기본값과 '직접 입력' 표시 (드롭다운 항목이면서 특별한 값)
const int kDefaultWidth = 832;
const int kDefaultHeight = 1216;
const String kDefaultResolution = "$kDefaultWidth x $kDefaultHeight"; // "832 x 1216"
const String kCustomResolutionLabel = "직접 입력";

/// "832 x 1216" 같은 글자를 (가로, 세로)로. 모양이 틀리면 null.
///  (띄어쓰기·대문자 X·곱하기 기호 × 도 받아 준다)
///  ⚠️ 예전엔 앱 곳곳에서 split("x") 뒤 int.parse 를 따로 해서, 이상한 글자가 들어오면
///     생성 버튼이 멈추거나(생성 중 표시가 안 꺼짐) 비용 표시가 화면 그리기를 망쳤다.
(int, int)? parseResolution(String s) {
  final parts = s.replaceAll(' ', '').toLowerCase().replaceAll('×', 'x').split('x');
  if (parts.length != 2) {
    return null;
  }
  final w = int.tryParse(parts[0]);
  final h = int.tryParse(parts[1]);
  if (w == null || h == null || w <= 0 || h <= 0) {
    return null;
  }
  return (w, h);
}

/// [parseResolution] 이 실패하면 기본 해상도로.
(int, int) resolutionOrDefault(String s) => parseResolution(s) ?? (kDefaultWidth, kDefaultHeight);
