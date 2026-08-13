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

  // ---- v5 (정식 출시 전 · 임시 테스트용) ----
  // ⚠️ 실제 API 문자열이 공개되지 않았다. 출시되면 이 값을 실제 문자열로 교체할 것.
  //    지금은 UI에서 '선택만' 가능하게 두는 용도이며, 실제 생성은 보장되지 않는다.
  static const String v5Test = 'nai-diffusion-5-test';
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

  /// 업스케일 입력 최대 픽셀 수(width * height). 0이면 미확인/제한없음.
  /// ⚠️ 현재 정확한 공식 수치를 확보하지 못했다. 확인 후 채울 것.
  final int maxUpscalePixels;

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
  maxUpscalePixels: 0, // TODO: 공식 업스케일 최대 크기 확인 후 채울 것
  isPlaceholder: false,
);

// V5 (임시 테스트). 출시 전이라 스펙 대부분이 미확정.
// 확정된 것: Vibe / Precise Reference 는 초기 버전에서 사용 불가.
// 그 외 요청 포맷·인페인트는 당분간 V4.5와 동일한 방식으로 처리한다.
const ModelCaps _v5Test = ModelCaps(
  id: NaiModels.v5Test,
  // 실제 v5 API 문자열이 공개되지 않았으므로, 서버로는 V4.5 Full을 보낸다.
  // (선택만 가능하게 하려는 목적 — 인페인트도 자동으로 V4.5와 동일 방식으로 진행됨)
  // ⚠️ v5 정식 출시 후 이 override를 제거하고 실제 문자열로 교체할 것.
  serverModelIdOverride: NaiModels.v45Full,
  displayName: 'NovelAI v5 test',
  supportsVibe: false, // V5 초기 버전 미지원 (확정)
  supportsPrecise: false, // V5 초기 버전 미지원 (확정)
  supportsInpaint: true, // V4.5와 동일 방식으로 진행
  supportsImg2img: true,
  supportsUpscale: true,
  supportsVarietyPlus: false, // V5 동작 여부 미확인 → 막아둠 (확인되면 true로)
  usesV4Prompt: true, // 당분간 V4.5와 동일 포맷
  usesEncodeVibe: false, // Vibe 미지원
  maxPromptTokens: 512, // V4.5 기준 (미확정)
  maxUpscalePixels: 0, // 미확인
  isPlaceholder: true, // 출시 후 실제 스펙으로 교체 필요
);

/// 모델 문자열 → ModelCaps 매핑 테이블.
final Map<String, ModelCaps> _capsTable = {
  // ---- V4.5 ----
  NaiModels.v45Full: _v45Full,
  NaiModels.v45Curated: _v45Full.copyWith(
    id: NaiModels.v45Curated,
    displayName: 'NAI Diffusion V4.5 Curated',
  ),

  // ---- V4 (쭈인 요청: 현재는 V4.5와 동일하게 취급) ----
  // ※ 참고: NovelAI 공식상 Precise Reference는 V4.5 전용이지만,
  //    현재 앱 동작(=V4/V4.5 동일 취급)에 맞춰 캡도 동일하게 둔다.
  //    실제 API 연결 단계에서 필요하면 이 부분만 갈라주면 된다.
  NaiModels.v4Full: _v45Full.copyWith(id: NaiModels.v4Full, displayName: 'NAI Diffusion V4 Full'),
  NaiModels.v4Curated: _v45Full.copyWith(
    id: NaiModels.v4Curated,
    displayName: 'NAI Diffusion V4 Curated',
  ),

  // ---- V5 (임시 테스트) ----
  NaiModels.v5Test: _v5Test,
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
    return _v5Test.copyWith(id: model);
  }
  if (model.contains('4-5') || model.contains('4.5')) {
    return _v45Full.copyWith(id: model);
  }
  if (model.contains('4')) {
    return _v45Full.copyWith(id: model);
  }

  // 3) 폴백
  return _fallbackCaps(model);
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
