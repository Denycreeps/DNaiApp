// lib/models/image_metadata.dart
//
// 이미지에 담긴 NovelAI 생성 정보(메타데이터)를 읽고 쓰는 코드.
//  app_state.dart가 커져서 성격이 뚜렷한 이 부분을 따로 뺐다.
//  · NaiMetadata            — 생성 파라미터 모델
//  · extractNovelAIMetadata — PNG(tEXt) / WebP(EXIF)에서 읽기
//  · buildExifBlock 외     — WebP에 EXIF로 심기
//  ⚠️ AppState를 참조하지 않는다 (순환 import 방지).
import 'dart:convert';
import 'dart:io'; // zlib (PNG 압축 해제)
import 'dart:typed_data';

import 'package:flutter/foundation.dart'; // debugPrint

class NaiMetadata {
  final String positive;
  final String negative;
  final List<String> characterPrompts;
  final List<String> characterUndesiredContents;

  /// 캐릭터 위치 (0.0~1.0). 없으면 빈 리스트.
  ///  프롬프트를 불러올 때 배치까지 되살리는 데 쓴다.
  final List<List<double>> characterCenters;
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
    this.characterCenters = const [],
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
    'characterCenters': characterCenters,
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
    characterCenters:
        (json['characterCenters'] as List?)
            ?.map((e) => List<double>.from((e as List).map((v) => (v as num).toDouble())))
            .toList() ??
        const [],
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
      characterCenters: characterCenters,
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

  // 설정 요약 텍스트 (히스토리 '세팅' 탭 + 갤러리 EXIF 공용)
  String settingsText() {
    String scheduler = extraParams['noise_schedule']?.toString() ?? 'native';
    String modelName = source.isEmpty ? '알 수 없음' : source;
    String samplerName = sampler.isEmpty ? '알 수 없음' : sampler;
    bool varPlus = extraParams['variety_plus'] == true;

    final refStrength = extraParams['reference_strength_multiple'];
    bool vibeOn = refStrength is List && refStrength.isNotEmpty;

    final dirStrength = extraParams['director_reference_strengths'];
    bool chaRefOn = dirStrength is List && dirStrength.isNotEmpty;

    return '''
🔹 해상도 : $width x $height
🔹 시드 : $seed
🔹 모델 : $modelName
🔹 스텝 : $steps
🔹 샘플러 : $samplerName
🔹 스케줄러 : $scheduler
🔹 CFG Scale : $promptGuidance
🔹 Rescale : $promptGuidanceRescale
🔹 VAR+ : ${varPlus ? 'ON' : 'OFF'}
🔹 Vibe : ${vibeOn ? 'ON' : 'OFF'}
🔹 Cha. Ref. : ${chaRefOn ? 'ON' : 'OFF'}
''';
  }
}

// 갤러리 EXIF용: 메타데이터 전체를 한 번에 보여주는 요약 텍스트
String buildExifSummary(NaiMetadata? meta) {
  if (meta == null) {
    return "이 이미지에는 저장된 메타데이터가 없습니다.\n\n(메신저 전송, 이미지 편집 등을 거치면서\n파일 내부의 메타데이터가 삭제된 이미지입니다.)";
  }
  final sb = StringBuffer();
  sb.writeln("■ 긍정적 프롬프트");
  sb.writeln(meta.positive.isEmpty ? "(없음)" : meta.positive);
  if (meta.characterPrompts.isNotEmpty) {
    sb.writeln("\n■ 캐릭터 프롬프트");
    for (int i = 0; i < meta.characterPrompts.length; i++) {
      final pos = meta.characterPrompts[i];
      final neg = i < meta.characterUndesiredContents.length
          ? meta.characterUndesiredContents[i]
          : "";
      sb.writeln("C${i + 1}.\nPositive : $pos\nNegative : $neg");
    }
  }
  sb.writeln("\n■ 부정적 프롬프트");
  sb.writeln(meta.negative.isEmpty ? "(없음)" : meta.negative);
  sb.writeln("\n■ 설정");
  sb.write(meta.settingsText().trim());
  return sb.toString();
}

// ── WebP(RIFF) 메타데이터 추출 ──
// NovelAI는 WebP로 저장할 때 EXIF 청크에 파라미터를 넣는다.
//   RIFF/WEBP → VP8X(플래그) → VP8L/VP8(픽셀) → EXIF(TIFF)
//   TIFF IFD0의 0x8769(Exif SubIFD) → 0x9286(UserComment) 안에 JSON이 통째로 들어있다.
//   UserComment는 앞 8바이트가 인코딩 표기("ASCII\0\0\0")이고 그 뒤가 본문.
// 반환값은 PNG의 tEXt와 동일한 형태의 JSON 문자열(없으면 null).
String? _extractWebpMetadataJson(Uint8List bytes) {
  try {
    if (bytes.length < 16) {
      return null;
    }
    // RIFF....WEBP 확인
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WEBP') {
      return null;
    }

    final view = ByteData.sublistView(bytes);
    int offset = 12;
    Uint8List? exif;

    // 청크 순회 (크기는 리틀엔디안, 홀수면 패딩 1바이트)
    while (offset + 8 <= bytes.length) {
      final fourcc = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final len = view.getUint32(offset + 4, Endian.little);
      final dataStart = offset + 8;
      if (dataStart + len > bytes.length) {
        break;
      }
      if (fourcc == 'EXIF') {
        exif = Uint8List.sublistView(bytes, dataStart, dataStart + len);
        break;
      }
      offset = dataStart + len + (len.isOdd ? 1 : 0);
    }
    if (exif == null || exif.length < 8) {
      return null;
    }

    // TIFF 헤더: 'II'(리틀) 또는 'MM'(빅) — NAI는 MM(빅엔디안)을 쓴다
    final ev = ByteData.sublistView(exif);
    final bo = String.fromCharCodes(exif.sublist(0, 2));
    final endian = bo == 'II' ? Endian.little : Endian.big;
    if (bo != 'II' && bo != 'MM') {
      return null;
    }
    if (ev.getUint16(2, endian) != 42) {
      return null;
    }

    // IFD를 훑어 지정한 태그의 (타입, 개수, 값오프셋)을 찾는다
    int? findTag(int ifdOffset, int wantTag) {
      if (ifdOffset + 2 > exif!.length) {
        return null;
      }
      final count = ev.getUint16(ifdOffset, endian);
      for (int i = 0; i < count; i++) {
        final e = ifdOffset + 2 + i * 12;
        if (e + 12 > exif.length) {
          break;
        }
        final tag = ev.getUint16(e, endian);
        if (tag == wantTag) {
          return e;
        }
      }
      return null;
    }

    final ifd0 = ev.getUint32(4, endian);
    // 0x8769 = Exif SubIFD 포인터
    final subPtr = findTag(ifd0, 0x8769);
    if (subPtr == null) {
      return null;
    }
    final subIfd = ev.getUint32(subPtr + 8, endian);

    // 0x9286 = UserComment (JSON 본문)
    final ucEntry = findTag(subIfd, 0x9286);
    if (ucEntry == null) {
      return null;
    }
    final ucCount = ev.getUint32(ucEntry + 4, endian);
    // 4바이트를 넘으면 값이 아니라 오프셋이 들어있다
    final ucOffset = ucCount <= 4 ? (ucEntry + 8) : ev.getUint32(ucEntry + 8, endian);
    if (ucOffset + ucCount > exif.length) {
      return null;
    }
    var body = exif.sublist(ucOffset, ucOffset + ucCount);
    // 인코딩 표기 8바이트 제거 (ASCII/UNICODE/JIS/Undefined)
    if (body.length > 8) {
      body = body.sublist(8);
    }
    var text = utf8.decode(body, allowMalformed: true).replaceAll('\u0000', '').trim();
    if (text.isEmpty) {
      return null;
    }

    // 바깥 JSON의 Comment 안에 실제 파라미터 JSON이 들어있다
    try {
      final outer = jsonDecode(text);
      if (outer is Map && outer['Comment'] is String) {
        return outer['Comment'] as String;
      }
    } catch (_) {}
    // Comment 래핑이 없으면 본문 자체가 파라미터 JSON일 수 있다
    return text.startsWith('{') ? text : null;
  } catch (_) {
    return null;
  }
}

// PNG 텍스트 청크에서 파라미터 JSON 문자열을 그대로 꺼낸다.
// (extractNovelAIMetadata는 파싱된 객체를 주지만, WebP로 이식할 땐 원문이 필요)
String? extractPngCommentJson(Uint8List bytes) {
  try {
    const sig = [137, 80, 78, 71, 13, 10, 26, 10];
    for (int i = 0; i < sig.length; i++) {
      if (bytes[i] != sig[i]) {
        return null;
      }
    }
    final view = ByteData.sublistView(bytes);
    int offset = 8;
    while (offset + 8 <= bytes.length) {
      final length = view.getUint32(offset);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      if (type == 'tEXt' || type == 'zTXt' || type == 'iTXt') {
        final data = bytes.sublist(offset + 8, offset + 8 + length);
        final nullIdx = data.indexOf(0);
        if (nullIdx != -1) {
          final raw = data.sublist(nullIdx + 1);
          String? value;
          if (type == 'tEXt') {
            value = utf8.decode(raw, allowMalformed: true);
          } else if (type == 'zTXt') {
            if (raw.length > 1) {
              try {
                value = utf8.decode(zlib.decode(raw.sublist(1)), allowMalformed: true);
              } catch (_) {}
            }
          } else {
            if (raw.length >= 2) {
              final compFlag = raw[0];
              final langEnd = raw.indexOf(0, 2);
              if (langEnd != -1) {
                final transEnd = raw.indexOf(0, langEnd + 1);
                if (transEnd != -1) {
                  final body = raw.sublist(transEnd + 1);
                  if (compFlag == 1) {
                    try {
                      value = utf8.decode(zlib.decode(body), allowMalformed: true);
                    } catch (_) {}
                  } else {
                    value = utf8.decode(body, allowMalformed: true);
                  }
                }
              }
            }
          }
          final v = value?.trim();
          if (v != null &&
              v.startsWith('{') &&
              (v.contains('"prompt"') || v.contains('"v4_prompt"'))) {
            return v;
          }
        }
      }
      offset += 12 + length;
    }
  } catch (_) {}
  return null;
}

// ── WebP 저장 (메타데이터 보존) ──
// NovelAI 공식 WebP와 동일한 구조로 EXIF 청크를 만들어 붙인다.
//   RIFF/WEBP → VP8X(EXIF 플래그) → VP8L/VP8(픽셀) → EXIF(TIFF)
//   TIFF IFD0 → 0x8769(SubIFD) → 0x9286(UserComment) → {"Comment": "<파라미터 JSON>"}
// 이렇게 하면 우리 앱은 물론 novelai.net/inspect 에서도 그대로 읽힌다.

// UserComment에 넣을 JSON으로 TIFF/EXIF 블록 생성 (빅엔디안 MM)
Uint8List buildExifBlock(String metadataJson) {
  // NAI와 동일하게 바깥을 {"Comment": "..."} 로 감싼다
  final wrapped = jsonEncode({'Comment': metadataJson});
  // UserComment는 앞 8바이트가 인코딩 표기
  final body = <int>[...utf8.encode('ASCII'), 0, 0, 0, ...utf8.encode(wrapped)];

  const ifd0Size = 2 + 12 + 4; // 엔트리1개 + 다음IFD포인터
  const subOffset = 8 + ifd0Size;
  const subIfdSize = 2 + 12 + 4;
  const dataOffset = subOffset + subIfdSize;

  final out = BytesBuilder();
  // TIFF 헤더 (MM = 빅엔디안, 매직 42, IFD0 오프셋 8)
  out.add([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]);

  void u16(int v) => out.add([(v >> 8) & 0xFF, v & 0xFF]);
  void u32(int v) => out.add([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);

  // IFD0: 0x8769(Exif SubIFD 포인터) 하나만
  u16(1);
  u16(0x8769);
  u16(4); // LONG
  u32(1);
  u32(subOffset);
  u32(0); // 다음 IFD 없음

  // SubIFD: 0x9286(UserComment)
  u16(1);
  u16(0x9286);
  u16(7); // UNDEFINED
  u32(body.length);
  u32(dataOffset);
  u32(0);

  out.add(body);
  return out.toBytes();
}

// WebP 바이트에 VP8X + EXIF 청크를 주입한다.
// 이미 EXIF가 있으면 교체한다. 실패 시 null.
Uint8List? injectExifIntoWebp(Uint8List webp, Uint8List exifBlock) {
  try {
    if (webp.length < 16 ||
        String.fromCharCodes(webp.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(webp.sublist(8, 12)) != 'WEBP') {
      return null;
    }
    final view = ByteData.sublistView(webp);

    // 기존 청크 수집 (EXIF/VP8X는 새로 만들므로 제외)
    final chunks = <MapEntry<String, Uint8List>>[];
    int width = 0;
    int height = 0;
    int offset = 12;
    while (offset + 8 <= webp.length) {
      final fourcc = String.fromCharCodes(webp.sublist(offset, offset + 4));
      final len = view.getUint32(offset + 4, Endian.little);
      final start = offset + 8;
      if (start + len > webp.length) {
        break;
      }
      final data = Uint8List.sublistView(webp, start, start + len);

      if (fourcc == 'VP8L' && len >= 5) {
        // VP8L 헤더에서 크기 추출 (14비트씩, 실제값-1)
        final bits = data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24);
        width = (bits & 0x3FFF) + 1;
        height = ((bits >> 14) & 0x3FFF) + 1;
      } else if (fourcc == 'VP8 ' && len >= 10) {
        width = ((data[7] << 8) | data[6]) & 0x3FFF;
        height = ((data[9] << 8) | data[8]) & 0x3FFF;
      }

      if (fourcc != 'EXIF' && fourcc != 'VP8X') {
        chunks.add(MapEntry(fourcc, data));
      }
      offset = start + len + (len.isOdd ? 1 : 0);
    }
    if (chunks.isEmpty || width <= 0 || height <= 0) {
      return null;
    }

    // 청크 하나를 바이트로 (홀수 길이면 패딩 1바이트)
    List<int> makeChunk(String fourcc, List<int> data) {
      final len = data.length;
      return [
        ...utf8.encode(fourcc),
        len & 0xFF,
        (len >> 8) & 0xFF,
        (len >> 16) & 0xFF,
        (len >> 24) & 0xFF,
        ...data,
        if (len.isOdd) 0,
      ];
    }

    // VP8X: 플래그(EXIF=0x08) + 예약3 + 폭-1(3바이트) + 높이-1(3바이트)
    final w1 = width - 1;
    final h1 = height - 1;
    final vp8x = <int>[
      0x08,
      0,
      0,
      0,
      w1 & 0xFF,
      (w1 >> 8) & 0xFF,
      (w1 >> 16) & 0xFF,
      h1 & 0xFF,
      (h1 >> 8) & 0xFF,
      (h1 >> 16) & 0xFF,
    ];

    final body = <int>[];
    body.addAll(makeChunk('VP8X', vp8x));
    for (final c in chunks) {
      body.addAll(makeChunk(c.key, c.value));
    }
    body.addAll(makeChunk('EXIF', exifBlock));

    final riffSize = 4 + body.length; // 'WEBP' + 본문
    return Uint8List.fromList([
      ...utf8.encode('RIFF'),
      riffSize & 0xFF,
      (riffSize >> 8) & 0xFF,
      (riffSize >> 16) & 0xFF,
      (riffSize >> 24) & 0xFF,
      ...utf8.encode('WEBP'),
      ...body,
    ]);
  } catch (e) {
    debugPrint('WebP EXIF 주입 실패: $e');
    return null;
  }
}

NaiMetadata? extractNovelAIMetadata(Uint8List imageBytes) {
  try {
    Map<String, String> textChunks = {};
    int imageWidth = 0;
    int imageHeight = 0;

    // ── WebP 먼저 처리 (NAI 공식 WebP 저장 지원) ──
    // EXIF 청크에서 JSON을 꺼내 PNG와 동일한 흐름으로 합류시킨다.
    final webpJson = _extractWebpMetadataJson(imageBytes);
    if (webpJson != null) {
      textChunks['Comment'] = webpJson;
      // 크기는 VP8X 청크에서 (24비트 리틀엔디안, 실제값-1로 저장됨)
      try {
        final v = ByteData.sublistView(imageBytes);
        if (String.fromCharCodes(imageBytes.sublist(12, 16)) == 'VP8X') {
          final w = v.getUint8(24) | (v.getUint8(25) << 8) | (v.getUint8(26) << 16);
          final h = v.getUint8(27) | (v.getUint8(28) << 8) | (v.getUint8(29) << 16);
          imageWidth = w + 1;
          imageHeight = h + 1;
        }
      } catch (_) {}
      return _buildMetadataFromChunks(textChunks, imageWidth, imageHeight, imageBytes);
    }

    final pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
    for (int i = 0; i < pngSignature.length; i++) {
      if (imageBytes[i] != pngSignature[i]) {
        return null;
      }
    }

    int offset = 8;

    while (offset < imageBytes.length) {
      if (offset + 8 > imageBytes.length) {
        break;
      }

      int length = ByteData.sublistView(imageBytes).getUint32(offset);
      String type = String.fromCharCodes(imageBytes.sublist(offset + 4, offset + 8));

      if (type == 'IHDR' && length >= 8) {
        imageWidth = ByteData.sublistView(imageBytes).getUint32(offset + 8);
        imageHeight = ByteData.sublistView(imageBytes).getUint32(offset + 12);
      } else if (type == 'tEXt' || type == 'zTXt' || type == 'iTXt') {
        // PNG 텍스트 청크는 3종류. tEXt만 읽으면 다른 툴/최신 NAI가 쓴
        // zTXt(압축)·iTXt(UTF-8, 압축 가능) 메타데이터를 통째로 놓친다.
        List<int> chunkData = imageBytes.sublist(offset + 8, offset + 8 + length);
        int nullIdx = chunkData.indexOf(0);
        if (nullIdx != -1) {
          String key = String.fromCharCodes(chunkData.sublist(0, nullIdx));
          List<int> raw = chunkData.sublist(nullIdx + 1);
          String? value;

          if (type == 'tEXt') {
            value = utf8.decode(raw, allowMalformed: true);
          } else if (type == 'zTXt') {
            // [압축방식 1바이트][zlib 압축 데이터]
            if (raw.length > 1) {
              try {
                value = utf8.decode(zlib.decode(raw.sublist(1)), allowMalformed: true);
              } catch (_) {}
            }
          } else {
            // iTXt: [압축플래그][압축방식][언어태그\0][번역키워드\0][본문]
            if (raw.length >= 2) {
              final int compFlag = raw[0];
              final int langEnd = raw.indexOf(0, 2);
              if (langEnd != -1) {
                final int transEnd = raw.indexOf(0, langEnd + 1);
                if (transEnd != -1) {
                  final List<int> body = raw.sublist(transEnd + 1);
                  if (compFlag == 1) {
                    try {
                      value = utf8.decode(zlib.decode(body), allowMalformed: true);
                    } catch (_) {}
                  } else {
                    value = utf8.decode(body, allowMalformed: true);
                  }
                }
              }
            }
          }

          if (value != null && value.isNotEmpty) {
            textChunks[key] = value;
          }
        }
      }
      offset += 12 + length;
    }

    return _buildMetadataFromChunks(textChunks, imageWidth, imageHeight, imageBytes);
  } catch (e) {
    debugPrint("메타데이터 파싱 실패: $e");
    return null;
  }
}

// 텍스트 청크(Comment JSON) → NaiMetadata 변환. PNG·WebP 공용.
NaiMetadata? _buildMetadataFromChunks(
  Map<String, String> textChunks,
  int imageWidth,
  int imageHeight,
  Uint8List imageBytes,
) {
  try {
    String prompt = textChunks['Description'] ?? '';
    String source = textChunks['Source'] ?? '';
    String commentString = textChunks['Comment'] ?? '{}';

    // 'Comment' 이외의 키에 들어있는 경우도 구제 (툴마다 키 이름이 다름)
    if (commentString == '{}' || commentString.isEmpty) {
      for (final entry in textChunks.entries) {
        final v = entry.value.trim();
        if (v.startsWith('{') && (v.contains('"prompt"') || v.contains('"v4_prompt"'))) {
          commentString = v;
          break;
        }
      }
    }

    if (commentString == '{}' || commentString.isEmpty) {
      try {
        String rawString = utf8.decode(imageBytes, allowMalformed: true);
        // 콜론 뒤 공백이 있어도 찾도록 정규식 사용
        final m = RegExp(r'\{\s*"(?:prompt|v4_prompt)"\s*:').firstMatch(rawString);
        int startIndex = m?.start ?? -1;
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
    // 캐릭터 위치(0.0~1.0). 프롬프트를 불러올 때 배치까지 되살리기 위함.
    List<List<double>> charCenters = [];

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
                // centers: [{x: 0.3, y: 0.5}] — 첫 좌표만 쓴다
                final centers = c['centers'];
                if (centers is List && centers.isNotEmpty && centers.first is Map) {
                  final p = centers.first as Map;
                  final x = p['x'];
                  final y = p['y'];
                  if (x is num && y is num) {
                    charCenters.add([x.toDouble(), y.toDouble()]);
                  }
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
      characterCenters: charCenters,
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
    debugPrint("메타데이터 변환 실패: $e");
    return null;
  }
}
