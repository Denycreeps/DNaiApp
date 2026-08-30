// lib/models/nai_presets.dart
//
// NovelAI 공식이 자동으로 붙여 주는 프롬프트 모음.
//  · Quality Tags — 긍정 프롬프트 뒤에 붙는 품질 태그
//  · UC Preset    — 부정 프롬프트에 붙는 기본 제외 태그
//
// 출처: https://docs.novelai.net/en/image/qualitytags
//       https://docs.novelai.net/en/image/undesiredcontent
//
// ⚠️ V5는 아직 공식 문서에 표가 없어 V4.5 Full 기준으로 넣어 두었다.
//    공식 값이 공개되면 아래 _v5 항목만 고치면 UI는 그대로 동작한다.

import 'model_caps.dart';

/// 프리셋 하나 (표시 이름 + 실제로 붙는 태그)
class NaiPresetOption {
  final String label; // 화면에 보이는 이름
  final String tags; // 실제로 붙는 태그 (빈 문자열이면 아무것도 안 붙음)

  const NaiPresetOption(this.label, this.tags);
}

class NaiPresets {
  // ── Quality Tags (긍정) ──
  //  프롬프트 '뒤'에 붙는다.
  static const List<NaiPresetOption> _qualityV45Full = [
    NaiPresetOption('Standard', 'location, very aesthetic, masterpiece, no text'),
    NaiPresetOption('Light', 'location, masterpiece, no text'),
    NaiPresetOption('None', ''),
  ];

  static const List<NaiPresetOption> _qualityV4Full = [
    NaiPresetOption('Standard', 'no text, best quality, very aesthetic, absurdres'),
    NaiPresetOption('Light', 'no text, best quality'),
    NaiPresetOption('None', ''),
  ];

  // V5 — 공식 표가 나오면 여기만 교체하면 된다 (현재는 V4.5 Full과 동일)
  //  ⚠️ 내용을 복사해 두지 말고 별칭으로 둔다.
  //     복사해 두면 V4.5 표를 고칠 때 V5 쪽을 깜빡해 두 목록이 조용히 어긋난다.
  //     (아래 _ucV5와 동일한 방식)
  static const List<NaiPresetOption> _qualityV5 = _qualityV45Full;

  // ── UC Preset (부정) ──
  static const List<NaiPresetOption> _ucV45Full = [
    NaiPresetOption(
      'Heavy',
      'lowres, artistic error, film grain, scan artifacts, worst quality, bad quality, '
          'jpeg artifacts, very displeasing, chromatic aberration, dithering, halftone, '
          'screentone, multiple views, logo, too many watermarks, negative space, blank page',
    ),
    NaiPresetOption(
      'Light',
      'lowres, artistic error, scan artifacts, worst quality, bad quality, jpeg artifacts, '
          'multiple views, very displeasing, too many watermarks, negative space, blank page',
    ),
    NaiPresetOption(
      'Furry Focus',
      '{worst quality}, distracting watermark, unfinished, bad quality, {widescreen}, upscale, '
          '{sequence}, {{grandfathered content}}, blurred foreground, chromatic aberration, sketch, '
          'everyone, [sketch background], simple, [flat colors], ych (character), outline, '
          'multiple scenes, [[horror (theme)]], comic',
    ),
    NaiPresetOption(
      'Human Focus',
      'lowres, artistic error, film grain, scan artifacts, worst quality, bad quality, '
          'jpeg artifacts, very displeasing, chromatic aberration, dithering, halftone, '
          'screentone, multiple views, logo, too many watermarks, negative space, blank page, '
          '@_@, mismatched pupils, glowing eyes, bad anatomy',
    ),
    NaiPresetOption('None', ''),
  ];

  static const List<NaiPresetOption> _ucV4Full = [
    NaiPresetOption(
      'Heavy',
      'blurry, lowres, error, film grain, scan artifacts, worst quality, bad quality, '
          'jpeg artifacts, very displeasing, chromatic aberration, multiple views, logo, '
          'too many watermarks',
    ),
    NaiPresetOption(
      'Light',
      'blurry, lowres, error, worst quality, bad quality, jpeg artifacts, very displeasing',
    ),
    NaiPresetOption('None', ''),
  ];

  // V5 — 공식 표가 나오면 여기만 교체 (현재는 V4.5 Full과 동일)
  static const List<NaiPresetOption> _ucV5 = _ucV45Full;

  /// 모델에 맞는 Quality Tags 목록
  static List<NaiPresetOption> qualityFor(String model) {
    if (model == NaiModels.v5Full) {
      return _qualityV5;
    }
    if (model == NaiModels.v4Full) {
      return _qualityV4Full;
    }
    return _qualityV45Full;
  }

  /// 모델에 맞는 UC 프리셋 목록
  static List<NaiPresetOption> ucFor(String model) {
    if (model == NaiModels.v5Full) {
      return _ucV5;
    }
    if (model == NaiModels.v4Full) {
      return _ucV4Full;
    }
    return _ucV45Full;
  }

  /// 저장된 이름으로 프리셋을 찾는다. 없으면 첫 번째(기본값).
  static NaiPresetOption find(List<NaiPresetOption> list, String label) {
    for (final o in list) {
      if (o.label == label) {
        return o;
      }
    }
    return list.first;
  }
}
