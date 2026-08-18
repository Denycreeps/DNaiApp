import 'package:flutter/services.dart' show rootBundle;
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data'; // BytesBuilder / Uint8List 직접 import (dart:io 간접 사용 경고 방지)
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
import 'package:saf_util/saf_util.dart';
import 'package:saf_stream/saf_stream.dart';

import '../novelai_service.dart';
import '../tag_filters.dart';
import '../app_theme.dart';
import 'nai_character.dart';
import 'model_caps.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

// i2i 작업 이미지가 바뀔 때 마스킹(_strokes)을 어떻게 처리할지.
// 1회용 소비 신호 대신 이 값을 함께 세팅하여 build 타이밍 문제를 방지한다.
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

  MaskStroke({
    required this.points,
    required this.size,
    required this.isEraser,
    required this.isCircle,
  });
}

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

  // "artist:" 특별 처리: artist의 앞부분("a"~"artist")으로 시작하면 맨 앞에 끼워넣기
  // (artist name 태그는 거의 안 쓰므로 artist: 접두사를 최우선 노출)
  String? artistPrefix;
  if (!lower.contains(':') && "artist".startsWith(lower)) {
    artistPrefix = 'artist:';
  }

  final fragments = lower.split(RegExp(r'\s+'));

  // 다중 조각 ("ca t", "lo a v" 등): 스마트 단어 매칭
  if (fragments.length > 1) {
    return _multiWordMatch(tags, fragments, limit);
  }

  // artist: 끼워넣기 헬퍼 (중복 방지, 맨 앞 배치)
  List<String> withArtist(List<String> results) {
    final prefix = artistPrefix;
    if (prefix == null) {
      return results;
    }
    final filtered = results.where((t) => t != prefix).toList();
    return [prefix, ...filtered].take(limit).toList();
  }

  // ======================================================================
  // 단일 조각
  // ======================================================================

  // 🔒 트레일링 스페이스 = "확정 모드": startsWith만 → 없으면 contains fallback
  if (hasTrailingSpace) {
    final startsResults = tags.where((t) => t.toLowerCase().startsWith(lower)).take(limit).toList();
    if (startsResults.isNotEmpty) {
      return withArtist(startsResults);
    }
    // startsWith 결과 없음 → contains fallback (연한 스타일)
    return withArtist(
      tags
          .where((t) => t.toLowerCase().contains(lower))
          .take(limit)
          .map((t) => '$kContainsMarker$t')
          .toList(),
    );
  }

  // 1~2글자: startsWith만 (contains는 노이즈 너무 많음)
  if (lower.length <= 2) {
    return withArtist(tags.where((t) => t.toLowerCase().startsWith(lower)).take(limit).toList());
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

  return withArtist([
    ...wordBoundaryResults.take(wordSlots),
    ...midWordResults.take(midSlots).map((t) => '$kContainsMarker$t'),
  ]);
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
String? _extractPngCommentJson(Uint8List bytes) {
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
Uint8List _buildExifBlock(String metadataJson) {
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
Uint8List? _injectExifIntoWebp(Uint8List webp, Uint8List exifBlock) {
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
    debugPrint("메타데이터 변환 실패: $e");
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

// i2i 스크래치 릴 결과 1개 (인페인트/모자이크/업스케일 반복 결과)
class I2iResult {
  Uint8List bytes;
  NaiMetadata? metadata;
  bool favorite;
  // 어떤 모드로 만들어졌는지 ('inpaint' | 'mosaic' | 'upscale' | 'img2img')
  // 릴 썸네일 구석에 작은 배지로 표시. 기존 저장분엔 없으므로 기본값은 인페인트.
  String source;
  I2iResult({required this.bytes, this.metadata, this.favorite = false, this.source = 'inpaint'});

  Map<String, dynamic> toJson() => {
    'img': base64Encode(bytes),
    'meta': metadata?.toJson(),
    'fav': favorite,
    'src': source,
  };
  factory I2iResult.fromJson(Map<String, dynamic> json) => I2iResult(
    bytes: base64Decode(json['img'] as String),
    metadata: json['meta'] != null
        ? NaiMetadata.fromJson(Map<String, dynamic>.from(json['meta']))
        : null,
    favorite: json['fav'] == true,
    source: (json['src'] as String?) ?? 'inpaint',
  );
}

// 프리셋 저장 다이얼로그 (프롬프트탭 + 갤러리 EXIF 메뉴 공용)
// 데이터 소스를 인자로 받아 작업창/이미지 메타데이터 어느 쪽이든 동일 UI로 저장.
void showPresetSaveDialog(
  BuildContext context,
  AppState state, {
  required String positive,
  required String negative,
  String prefix = '',
  String suffix = '',
  List<NaiCharacter> characters = const [],
  Map<String, dynamic>? Function()? settingsProvider,
  bool allowPrefixSuffix = true,
  bool allowSettings = true,
}) {
  final TextEditingController nameCtrl = TextEditingController();
  final Map<String, bool> fields = {
    'positive': true,
    'negative': true,
    if (allowPrefixSuffix) 'prefix': true,
    if (allowPrefixSuffix) 'suffix': true,
    'characters': false,
    if (allowSettings) 'settings': false,
  };
  // 캐릭터 개별 선택 (활성 캐릭터 기본 선택)
  final Set<int> selectedCharIndices = {};
  for (int i = 0; i < characters.length; i++) {
    if (characters[i].isActive) {
      selectedCharIndices.add(i);
    }
  }

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        Widget fieldChip(String key, String label, Color color) {
          final selected = fields[key] ?? false;
          return GestureDetector(
            onTap: () => setDialogState(() => fields[key] = !selected),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? color.withValues(alpha: 0.15)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? color : Colors.white24,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                    size: 16,
                    color: selected ? color : Colors.white38,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? color : Colors.white38,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            "프리셋 저장",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "프리셋 이름을 입력하세요",
                    hintStyle: const TextStyle(color: Colors.white30),
                    filled: true,
                    fillColor: const Color(0xFF121212),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text("저장할 항목 선택", style: TextStyle(color: Colors.white54, fontSize: 12)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: fieldChip('positive', '긍정적', const Color(0xFF00BFA5))),
                    const SizedBox(width: 8),
                    Expanded(child: fieldChip('negative', '부정적', const Color(0xFFFF5252))),
                  ],
                ),
                if (allowPrefixSuffix) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: fieldChip('prefix', '선행', const Color(0xFF29B6F6))),
                      const SizedBox(width: 8),
                      Expanded(child: fieldChip('suffix', '후행', const Color(0xFFFFA000))),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: fieldChip('characters', '캐릭터', Colors.deepPurpleAccent)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: allowSettings
                          ? fieldChip('settings', '설정', Colors.amber)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
                // 캐릭터 체크 시 캐릭터 목록 표시
                ...((fields['characters'] ?? false) && characters.isNotEmpty
                    ? [
                        const SizedBox(height: 8),
                        ...characters.asMap().entries.map((entry) {
                          final i = entry.key;
                          final c = entry.value;
                          final isSelected = selectedCharIndices.contains(i);
                          final charName = c.name.isNotEmpty ? c.name : "캐릭터 ${i + 1}";
                          final preview = c.positive.isNotEmpty ? c.positive : '(비어있음)';
                          return GestureDetector(
                            onTap: () => setDialogState(() {
                              if (isSelected) {
                                selectedCharIndices.remove(i);
                              } else {
                                selectedCharIndices.add(i);
                              }
                            }),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Colors.deepPurpleAccent.withValues(alpha: 0.1)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected
                                      ? Colors.deepPurpleAccent.withValues(alpha: 0.4)
                                      : Colors.white10,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isSelected ? Icons.check_circle : Icons.circle_outlined,
                                    size: 16,
                                    color: isSelected ? Colors.deepPurpleAccent : Colors.white38,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    charName,
                                    style: TextStyle(
                                      color: isSelected ? Colors.white : Colors.white54,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      preview,
                                      style: const TextStyle(color: Colors.white30, fontSize: 11),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ]
                    : []),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("취소", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) {
                  final now = DateTime.now();
                  nameCtrl.text =
                      "${now.year.toString().substring(2)}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}";
                }
                final savedFields = fields.entries.where((e) => e.value).map((e) => e.key).toSet();

                // 비어있는 필드는 저장에서 제외
                if (savedFields.contains('positive') && positive.trim().isEmpty) {
                  savedFields.remove('positive');
                }
                if (savedFields.contains('negative') && negative.trim().isEmpty) {
                  savedFields.remove('negative');
                }
                if (savedFields.contains('prefix') && prefix.trim().isEmpty) {
                  savedFields.remove('prefix');
                }
                if (savedFields.contains('suffix') && suffix.trim().isEmpty) {
                  savedFields.remove('suffix');
                }

                // 선택된 캐릭터만 저장
                List<Map<String, dynamic>>? charsToSave;
                if (savedFields.contains('characters') && selectedCharIndices.isNotEmpty) {
                  charsToSave = selectedCharIndices
                      .toList()
                      .where((i) => i < characters.length)
                      .map((i) => characters[i].toJson())
                      .toList();
                } else {
                  savedFields.remove('characters');
                }

                if (savedFields.isEmpty) {
                  Navigator.pop(ctx);
                  return;
                }
                state.presets.add(
                  NaiPreset(
                    name: nameCtrl.text.trim(),
                    positive: savedFields.contains('positive') ? positive : '',
                    negative: savedFields.contains('negative') ? negative : '',
                    prefix: savedFields.contains('prefix') ? prefix : '',
                    suffix: savedFields.contains('suffix') ? suffix : '',
                    settings: savedFields.contains('settings') ? (settingsProvider?.call()) : null,
                    characters: charsToSave,
                    savedFields: savedFields,
                  ),
                );
                state.saveAllSettings();
                state.refreshUI();
                Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
              child: const Text(
                "저장",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    ),
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
    return buildSyntaxSpan(text, style);
  }

  // 카드 본문(접힌 미리보기)에서도 동일한 음영을 쓰기 위한 static 헬퍼.
  static TextSpan buildSyntaxSpan(String text, TextStyle? style) {
    final lines = text.split('\n');
    final List<TextSpan> spans = [];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('#')) {
        // 주석: 회색
        spans.add(
          TextSpan(
            text: line,
            style: style?.copyWith(color: Colors.grey),
          ),
        );
      } else {
        // 조건부 트리거: 줄 맨 앞이 '(' 로 시작하면 조건 부분( '(' ~ 첫 ':' )에 음영
        // 예: (e|q):*skirt=*skirt → "(e|q):" 부분에 배경색
        final trimmedStart = line.trimLeft();
        final indent = line.length - trimmedStart.length;
        if (trimmedStart.startsWith('(')) {
          final colonIdx = line.indexOf(':');
          if (colonIdx != -1) {
            // 들여쓰기(공백) + 조건부( '(' ~ ':' ) + 나머지
            if (indent > 0) {
              spans.add(TextSpan(text: line.substring(0, indent), style: style));
            }
            spans.add(
              TextSpan(
                text: line.substring(indent, colonIdx + 1), // '(...):'
                style: style?.copyWith(
                  backgroundColor: const Color(
                    0xFFEC4899,
                  ).withValues(alpha: 0.30), // 조건부 섹션 색(핑크)과 통일
                  fontWeight: FontWeight.bold,
                ),
              ),
            );
            spans.add(TextSpan(text: line.substring(colonIdx + 1), style: style));
          } else {
            spans.add(TextSpan(text: line, style: style));
          }
        } else {
          spans.add(TextSpan(text: line, style: style));
        }
      }

      if (i < lines.length - 1) {
        spans.add(TextSpan(text: '\n', style: style));
      }
    }
    return TextSpan(style: style, children: spans);
  }
}

// NovelAI 가중치 문법(숫자::프롬프트 ::) 색상 하이라이트 컨트롤러
// 가중치 규칙 입력창 전용 강조
//  - 규칙이 꺼져 있으면 전체를 흐리게 (꺼진 상태가 한눈에 보이도록)
//  - '#'부터 콤마/줄바꿈 전까지는 주석이므로 회색 처리
class WeightRulesController extends TextEditingController {
  WeightRulesController({super.text});

  // AppState의 weightRulesEnabled와 동기화되는 현재 상태
  static bool rulesEnabled = false;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return buildRulesSpan(text, style, rulesEnabled);
  }

  // 카드 미리보기에서도 같은 음영을 쓰기 위한 static 헬퍼
  static TextSpan buildRulesSpan(String text, TextStyle? style, bool enabled) {
    if (!enabled) {
      // 꺼짐: 전체를 흐린 회색으로
      return TextSpan(
        text: text,
        style: style?.copyWith(color: Colors.white30),
      );
    }
    final List<TextSpan> spans = [];
    int i = 0;
    while (i < text.length) {
      final hash = text.indexOf('#', i);
      if (hash == -1) {
        spans.add(TextSpan(text: text.substring(i), style: style));
        break;
      }
      if (hash > i) {
        spans.add(TextSpan(text: text.substring(i, hash), style: style));
      }
      // '#'부터 콤마/줄바꿈 직전까지가 주석 범위
      int end = text.length;
      for (int j = hash; j < text.length; j++) {
        if (text[j] == ',' || text[j] == '\n') {
          end = j;
          break;
        }
      }
      spans.add(
        TextSpan(
          text: text.substring(hash, end),
          style: style?.copyWith(color: Colors.grey, fontStyle: FontStyle.italic),
        ),
      );
      i = end;
    }
    return TextSpan(style: style, children: spans);
  }
}

class WeightHighlightController extends TextEditingController {
  WeightHighlightController({super.text});

  // 전역 토글 (설정에서 제어)
  static bool highlightEnabled = true; // AppState.weightHighlight와 동기화 (기본 ON)

  // '::' 구분자 전용 색 (가중치/프롬프트 경계를 확실히 구분)
  // 신택스 하이라이팅 배색 (Nord/Night Owl 계열 — 채도를 낮춰 눈에 편하게)
  //  숫자는 전통적으로 파랑 계열, 구분자는 톤 다운해 덜 튀게
  static const Color _separatorColor = Color(0xFFC3A6E0); // '::' 차분한 라벤더 (구분자, 은은하게)
  static const Color _weightNumColor = Color(0xFF82AAFF); // 가중치 숫자 (Night Owl 파랑 — 표준 숫자색)

  // 가중치 → 색상 매핑
  // 1.0 = 중립(색 없음), >1.0 어두운 갈색→(10.0)완전 빨강, <1.0 파랑→검정파랑
  static Color? _weightColor(double weight) {
    if (weight == 1.0) {
      return null;
    }
    if (weight > 1.0) {
      // 1.0 어두운 갈색 → 10.0 완전 빨강
      final t = ((weight - 1.0) / 9.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF6B4423), const Color(0xFFFF0000), t);
    } else {
      // 1.0 파랑 → 0.0 이하 검정파랑
      final t = ((1.0 - weight) / 2.0).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFF4A90D9), const Color(0xFF0A1A4A), t);
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!highlightEnabled) {
      return TextSpan(text: text, style: style);
    }
    return buildWeightSpan(text, style);
  }

  // 가중치 문법을 색상 TextSpan으로 변환 (controller + RichText 공용)
  static TextSpan buildWeightSpan(String text, TextStyle? style) {
    final List<TextSpan> spans = [];
    // 가중치 시작: 단어 경계 뒤의 (숫자):: / 종료: ::
    // 단어 경계 = 문장 시작, 또는 앞 글자가 , [ ] { } 공백 중 하나
    // (artist:7010 같은 경우 숫자 앞이 ':' 또는 글자라 가중치로 인식 안 함)
    final startRegex = RegExp(r'(?:^|(?<=[,\[\]{}\s]))(-?\d+\.?\d*)\s*::');
    final endRegex = RegExp(r'::');

    int pos = 0;
    double? currentWeight;

    while (pos < text.length) {
      if (currentWeight == null) {
        // 가중치 시작 마커 찾기
        final m = startRegex.firstMatch(text.substring(pos));
        if (m == null) {
          // 더 이상 가중치 없음 → 나머지 일반 텍스트
          spans.add(TextSpan(text: text.substring(pos), style: style));
          break;
        }
        // 마커 이전 일반 텍스트
        if (m.start > 0) {
          spans.add(TextSpan(text: text.substring(pos, pos + m.start), style: style));
        }
        currentWeight = double.tryParse(m.group(1)!);
        final markerColor = currentWeight != null ? _weightColor(currentWeight) : null;
        // 시작 마커: 숫자만 볼드, :: 는 볼드 해제. 글씨 흰색, 배경 색상 음영.
        final numStr = m.group(1)!; // 숫자 부분
        final fullMarker = m.group(0)!; // 숫자 + (공백) + ::
        final afterNum = fullMarker.substring(numStr.length); // "::" 또는 " ::"
        // 숫자 (청록 글씨 + 볼드로 프롬프트 본문과 확실히 구분)
        spans.add(
          TextSpan(
            text: numStr,
            style: style?.copyWith(
              color: _weightNumColor,
              fontWeight: FontWeight.bold,
              backgroundColor: markerColor?.withValues(alpha: 0.4),
            ),
          ),
        );
        // :: 구분자 (노란 글씨 + 볼드로 가중치와 프롬프트 사이를 뚜렷이 구분)
        spans.add(
          TextSpan(
            text: afterNum,
            style: style?.copyWith(
              color: _separatorColor,
              fontWeight: FontWeight.bold,
              backgroundColor: markerColor?.withValues(alpha: 0.4),
            ),
          ),
        );
        pos += m.end;
      } else {
        // 가중치 구간 안 → 종료 :: 찾기
        final m = endRegex.firstMatch(text.substring(pos));
        final color = _weightColor(currentWeight);
        if (m == null) {
          // 종료 없이 끝까지 → 전부 음영 (글씨 흰색, 배경만 색상)
          spans.add(
            TextSpan(
              text: text.substring(pos),
              style: style?.copyWith(
                color: Colors.white,
                backgroundColor: color?.withValues(alpha: 0.32),
              ),
            ),
          );
          break;
        }
        // 구간 내용 (글씨 흰색, 배경만 음영)
        if (m.start > 0) {
          spans.add(
            TextSpan(
              text: text.substring(pos, pos + m.start),
              style: style?.copyWith(
                color: Colors.white,
                backgroundColor: color?.withValues(alpha: 0.32),
              ),
            ),
          );
        }
        // 종료 마커 :: (노란 글씨 + 볼드, 배경 음영 유지로 구간 끝까지 연결)
        spans.add(
          TextSpan(
            text: m.group(0),
            style: style?.copyWith(
              color: _separatorColor,
              fontWeight: FontWeight.bold,
              backgroundColor: color?.withValues(alpha: 0.32),
            ),
          ),
        );
        pos += m.end;
        currentWeight = null;
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

  // 업데이트 다이얼로그가 이번 세션에 이미 표시됐는지 (자동 알림/수동 열기 공유 가드).
  // 수동으로 열 때도 이 값을 켜서, main의 자동 알림이 겹쳐 뜨지 않게 한다.
  bool updateDialogShown = false;

  bool get hasUpdate =>
      latestVersion != null && _compareVersions(latestVersion!, currentVersion) > 0;

  /// 릴리즈 노트를 미리보기 형태로 변환
  List<String> get releaseNotePreview {
    if (updateNotes == null || updateNotes!.isEmpty) {
      return [];
    }
    String text = updateNotes!;
    // 1) <br>, </br>, <br/>, <br /> 등 줄바꿈 태그 → 실제 줄바꿈
    text = text.replaceAll(RegExp(r'<\s*/?\s*br\s*/?\s*>', caseSensitive: false), '\n');
    // 2) HTML 주석 <!-- ... --> 제거 (여러 줄 포함)
    text = text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
    // 3) 그 외 모든 HTML 태그 (<...>로 둘러싼 것) 제거
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');
    return text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('![')) // 이미지 라인 제외
        .map((line) {
          // 마크다운 헤더 정리
          line = line.replaceAll(RegExp(r'^#+\s*'), '');
          // 40자 넘으면 자르기
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
    // 이미 다운로드 중이면 중복 실행 무시 (버튼 연타/중복 호출 방지)
    if (isDownloadingUpdate) {
      return;
    }
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
  // 의상 상태/동작 태그 제거 (unworn, torn, grab 등)
  bool removeClothingEvents = false;

  // 캐릭터 탭에서 선택된 캐릭터를 한 번 더 눌러 ON/OFF 하는 기능
  // (자주 탭하는 사람은 오조작이 잦다는 의견이 있어 끌 수 있게 함)
  bool charRetapToggle = true;

  // 저장 폴더를 '날짜'로만 만든다 (기본 OFF = 실행할 때마다 날짜_시간 폴더)
  bool saveFolderByDateOnly = false;
  bool removeColors = false;
  bool isAutoSave = true;
  // 이미지를 WebP(무손실)로 저장 — 용량 약 26% 절감, 메타데이터는 EXIF로 보존
  bool saveAsWebp = false;
  // WebP 저장 시 손실 압축(품질 95) 사용 — 화질 차이 거의 없이 용량이 크게 줄어든다
  bool webpLossy = false;
  bool isRandomLocked = false;
  bool isFurryMode = false;
  bool isSeedLocked = false;
  double infillStrength = 0.7;
  // img2img: 원본 변형 강도(낮을수록 원본 충실) / 노이즈(새 디테일 추가량)
  double img2imgStrength = 0.5;
  double img2imgNoise = 0.1;
  bool isVariancePlus = false; // VAR+ (Variety+) 모드
  bool horizontalSwipeEnabled = false; // 좌우 스와이프 탭 전환
  // i2i탭 UI 배치 변경: ON이면 모드 칩 가로 1줄 + 실행 버튼 우하단 배치
  // ⚠️ [1차 UI 비활성] i2i 탭은 2차 배치(대체 UI)로 고정.
  //  - 이 값은 항상 true로 유지된다(설정 토글 제거 + 로드 시 강제).
  //    따라서 i2i_tab.dart의 `if (!state.i2iAltLayout)` 분기는 실행되지 않는다.
  //  - 1차 UI 코드는 i2i_tab.dart에 그대로 남아 있다(삭제 시 참고: 갈리는 곳 2군데,
  //    `_classicToolbarChildren`와 모드칩 2×2 배치).
  //  - 되살리려면: 아래 로드부의 강제 true를 풀고 settings_tab의 토글 주석을 해제.
  bool i2iAltLayout = true;
  // 프롬프트 탭 2번째 UI (합본 미리보기 + 기능 묶음). 기본 OFF — 기존 UI 유지
  // 프롬프트 탭을 개편된 새 레이아웃으로 표시 (기본 OFF = 기존 사용자에게 익숙한 예전 UI)
  bool promptNewLayout = false;

  // ⚠️ [보류] 프롬프트탭 2번째 UI. 설정 화면에서는 숨겨져 있다(settings_tab 참고).
  //  구현은 prompt_tab.dart의 _buildAltLayout 이하에 그대로 살아 있으므로,
  //  디버깅/참고용으로 이 값을 true 로 두면 다시 사용할 수 있다.
  bool promptAltLayout = false;
  // 검색 페이지 수 (API 키 있을 때만 유효). 기본 40, 상한 120.
  int gelbooruSearchPages = 40;
  // [실험] 정렬 축 다양화 (random+score+id 섞기) — 중복 줄이고 표본 확대
  bool diversifySearchSort = false;
  // 프롬프트 탭 캐릭터 편집 서랍 표시 (기본 OFF)
  bool promptCharDrawerEnabled = false;
  // 가중치 규칙: "태그=숫자" 형식으로 프롬프트의 특정 태그에 NovelAI 가중치를 자동 적용
  bool _weightRulesEnabled = false;
  bool get weightRulesEnabled => _weightRulesEnabled;
  set weightRulesEnabled(bool v) {
    _weightRulesEnabled = v;
    WeightRulesController.rulesEnabled = v; // 입력창 강조와 동기화
  }

  final WeightRulesController weightRulesController = WeightRulesController();
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

  // 현재 켜져 있는 i2i 모드 목록 (표시 순서 유지)
  List<String> get enabledI2iModes => [
    if (i2iModeInpaintEnabled) 'inpaint',
    if (i2iModeMosaicEnabled) 'mosaic',
    if (i2iModeImg2imgEnabled) 'img2img',
    if (i2iModeUpscaleEnabled) 'upscale',
  ];

  // i2i 모드 하나를 켜고 끈다. 모드가 모두 꺼지면 i2i 탭 자체도 함께 꺼진다.
  // i2i 모드 하나를 켜고 끈다.
  // 모드가 모두 꺼지면 i2i 탭도 함께 꺼지고, 빈 상태에서 모드를 켜면 탭도 되살아난다.
  // 그 외의 경우엔 사용자가 정한 탭 ON/OFF 상태를 건드리지 않는다.
  void setI2iModeEnabled(String mode, bool enabled) {
    final bool wasEmpty = enabledI2iModes.isEmpty;
    switch (mode) {
      case 'inpaint':
        i2iModeInpaintEnabled = enabled;
        break;
      case 'mosaic':
        i2iModeMosaicEnabled = enabled;
        break;
      case 'img2img':
        i2iModeImg2imgEnabled = enabled;
        break;
      case 'upscale':
        i2iModeUpscaleEnabled = enabled;
        break;
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
    'weightRules',
  ];

  // 앱에서 지원하는 전체 섹션 (저장된 순서와 대조해 누락/불명 항목 정리)
  static const List<String> _allSections = [
    'positive',
    'prefix',
    'suffix',
    'negative',
    'removeChips',
    'customRemove',
    'conditional',
    'weightRules',
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

  // 프롬프트 섹션 접기 상태
  Set<String> collapsedSections = {};

  // 프롬프트 탭에서 숨길 섹션들 (설정 > 프롬프트 창 표시)
  // 전부 숨겨도 프롬프트 탭 자체는 유지된다.
  Set<String> hiddenPromptSections = {};

  // 2번째 UI 전용: 묶음에서 꺼내 메인 화면에 고정할 창들
  // (기존 UI의 hiddenPromptSections와는 별개 — 서로 간섭하지 않게 분리)
  Set<String> pinnedPromptSections = {};

  // 조건부 트리거 문법 가이드 접힘 상태
  bool conditionalGuideCollapsed = false;

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

  // ===== SAF 저장 폴더 (Phase 1: 선택/해제/로드만, 저장·읽기 연결은 다음 단계) =====

  // 사용자에게 폴더 선택창을 띄워 SAF 트리 URI를 확보 (쓰기 권한 + 영속)
  // 반환: true=선택됨, false=취소/실패
  Future<bool> pickSafRoot() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      // persistablePermission: true → 재시작/재부팅 후에도 권한 유지 (takePersistableUriPermission)
      final dir = await _safUtil.pickDirectory(writePermission: true, persistablePermission: true);
      if (dir == null) {
        return false; // 사용자가 취소
      }
      safRootUri = dir.uri;
      safRootName = dir.name;
      _safSessionDirUri = null; // 루트 바뀌면 세션 캐시 무효화
      _safSessionDirName = null;
      clearSafBrowseLocation();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('safRootUri', dir.uri);
      await prefs.setString('safRootName', dir.name);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('SAF 폴더 선택 실패: $e');
      return false;
    }
  }

  // SAF 폴더 선택 해제 (영속 권한도 반납)
  Future<void> clearSafRoot() async {
    final uri = safRootUri;
    safRootUri = null;
    safRootName = null;
    _safSessionDirUri = null;
    _safSessionDirName = null;
    clearSafBrowseLocation();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('safRootUri');
      await prefs.remove('safRootName');
      if (uri != null && Platform.isAndroid) {
        await _safUtil.releasePersistedPermission(uri);
      }
    } catch (e) {
      debugPrint('SAF 폴더 해제 실패: $e');
    }
    notifyListeners();
  }

  // SAF 루트 폴더에 이미지 1장 저장 (Phase 2: 플랫 — 루트 폴더에 바로)
  // 반환: 성공 시 표시용 문자열, 미설정/실패 시 null
  Future<String?> _saveImageViaSaf(Uint8List bytes, String fileName, String ext) async {
    final root = safRootUri;
    if (root == null || !Platform.isAndroid) {
      return null;
    }
    try {
      // 확장자와 mime이 어긋나면 안드로이드가 확장자를 덧붙인다(예: name.webp.png)
      final mime = ext == 'jpg' ? 'image/jpeg' : (ext == 'webp' ? 'image/webp' : 'image/png');
      final session = _resolveSessionFolder();
      // 루트 폴더명이 이미 'DNaiApp'(대소문자 무시)이면 DNaiApp 중첩 생성 방지
      final rootIsDnai = (safRootName ?? '').trim().toLowerCase() == 'dnaiapp';
      final pathParts = rootIsDnai ? [session] : ['DNaiApp', session];
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
      final displayPath = rootIsDnai
          ? '$session/$fileName.$ext'
          : 'DNaiApp/$session/$fileName.$ext';
      return '${safRootName ?? 'SAF'}/$displayPath';
    } catch (e) {
      debugPrint('SAF 저장 실패: $e');
      return null;
    }
  }

  bool _isSafImageName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp');
  }

  // SAF 갤러리에서 마지막으로 보던 위치 (탭/모드 전환 후 복원용)
  // 갤러리(SAF/IO)가 등록하는 뒤로가기 핸들러. 처리했으면 true 반환.
  // main의 PopScope가 히스토리 탭일 때 호출 → 상위폴더 이동/선택해제 처리.
  bool Function()? galleryBackHandler;

  // i2i 탭이 등록하는 뒤로가기 핸들러. 릴(핸들)이 열려있으면 닫고 true 반환.
  bool Function()? i2iBackHandler;

  // 설정탭이 등록하는 "첫 탭([일반])으로 리셋" 핸들러. main이 설정 진입 시 호출.
  void Function()? settingsTabReset;

  // SAF에 이미지가 저장될 때마다 증가. 갤러리가 이 값 변화를 감지해 자동 갱신한다.
  int gallerySafRevision = 0;

  // 마지막으로 이미지를 저장한 세션 폴더 URI (갤러리 자동 갱신 시 대상 판별용).
  String? get lastSavedSafDirUri => _safSessionDirUri;

  String? safBrowseDirUri;
  String? safBrowseDirName;
  List<String> safBrowseStackUris = [];
  List<String> safBrowseStackNames = [];

  void saveSafBrowseLocation(
    String? dirUri,
    String? dirName,
    List<String> stackUris,
    List<String> stackNames,
  ) {
    safBrowseDirUri = dirUri;
    safBrowseDirName = dirName;
    safBrowseStackUris = List.from(stackUris);
    safBrowseStackNames = List.from(stackNames);
  }

  void clearSafBrowseLocation() {
    safBrowseDirUri = null;
    safBrowseDirName = null;
    safBrowseStackUris = [];
    safBrowseStackNames = [];
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
          subDirs.add((uri: f.uri, name: f.name));
        } else if (_isSafImageName(f.name)) {
          images.add((uri: f.uri, name: f.name));
        }
      }
      // 각 하위폴더 1회 조회 → 직접 이미지 수 + 하위폴더 유무 + 미리보기 refs (빈 폴더 제외)
      for (final d in subDirs) {
        int imgCount = 0;
        bool hasSub = false;
        final innerImgs = <({String uri, String name})>[];
        try {
          final inner = await _safUtil.list(d.uri);
          for (final f in inner) {
            if (f.isDir) {
              hasSub = true;
            } else if (_isSafImageName(f.name)) {
              imgCount++;
              innerImgs.add((uri: f.uri, name: f.name));
            }
          }
        } catch (_) {}
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
      final imgs = items.where((f) => !f.isDir && _isSafImageName(f.name)).toList()
        ..sort((a, b) => b.name.compareTo(a.name));
      for (final im in imgs) {
        out.add((uri: im.uri, name: im.name));
        if (out.length >= max) {
          return out;
        }
      }
      if (out.length < max) {
        final dirs = items.where((f) => f.isDir).toList()..sort((a, b) => b.name.compareTo(a.name));
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
  Future<String?> moveSafImage(String fileUri, String fromParentUri, String toParentUri) async {
    if (!Platform.isAndroid) {
      return null;
    }
    // 같은 폴더로의 이동은 무의미 → 그대로 성공 처리(새 uri 없음)
    if (fromParentUri == toParentUri) {
      return fileUri;
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
        if (f.isDir) {
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
    final bool rootIsDnai = (safRootName ?? '').trim().toLowerCase() == 'dnaiapp';

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
        final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'png';
        final mime = (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
        final bytes = await f.readAsBytes();
        await _safStream.writeFileBytes(dirUri, name, mime, bytes);
        copied++;
        if (deleteOriginals) {
          try {
            await f.delete();
            deleted++;
          } catch (_) {}
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
          // 세션 폴더 → DNaiApp/세션 (루트가 DNaiApp이면 세션만)
          final session = entity.path.split('/').last;
          final dirUri = await ensureDir(rootIsDnai ? [session] : ['DNaiApp', session]);
          if (dirUri == null) {
            continue;
          }
          for (final f in entity.listSync()) {
            if (f is File && _isSafImageName(f.path.split('/').last)) {
              await copyFile(f, dirUri);
            }
          }
        } else if (entity is File && _isSafImageName(entity.path.split('/').last)) {
          // 세션 없이 베이스 바로 아래 있는 이미지 → DNaiApp 루트
          final dirUri = await ensureDir(rootIsDnai ? [] : ['DNaiApp']);
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
        return await f.readAsBytes();
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
      final thumb = await compute(_makeSafThumbIsolate, bytes);
      if (thumb != null) {
        final f = thumbFile;
        if (f != null) {
          await f.writeAsBytes(thumb); // 다음부턴 디스크 캐시로 즉시
        }
        return thumb;
      }
    } catch (e) {
      debugPrint('썸네일 폴백 축소 실패: $e');
    }
    return bytes; // 축소까지 실패하면 원본이라도 표시
  }

  // 앱 시작 시 저장된 SAF 루트 복원 — 권한이 아직 유효할 때만
  Future<void> _loadSafRoot() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final uri = prefs.getString('safRootUri');
      if (uri == null || uri.isEmpty) {
        return;
      }
      final ok = await _safUtil.hasPersistedPermission(uri);
      if (ok) {
        safRootUri = uri;
        safRootName = prefs.getString('safRootName');
      } else {
        // 권한이 풀림(재부팅/회수/에뮬 초기화) → 캐시 정리
        await prefs.remove('safRootUri');
        await prefs.remove('safRootName');
      }
    } catch (e) {
      debugPrint('SAF 루트 로드 실패: $e');
    }
  }

  // 갤러리 모드 ON/OFF. SAF/앱 전용 폴더로 동작하므로 별도 권한 요청 없음.
  // 반환: 최종 galleryModeEnabled 값
  Future<bool> setGalleryModeEnabled(bool enabled) async {
    galleryModeEnabled = enabled;
    await saveAllSettings();
    notifyListeners();
    return enabled;
  }

  // 갤러리에서 선택 가능한 "위치 목록" (권한 불필요한 경로들).
  // 반환: [(라벨, 경로)] — 앱 외부 저장소 DNaiApp (+ SAF는 별도 처리)
  Future<List<(String, String)>> getGalleryLocations() async {
    final locations = <(String, String)>[];

    // 1. 앱 외부 저장소/DNaiApp (기본)
    final appDir = await getExternalStorageDirectory();
    if (appDir != null) {
      final dir = Directory('${appDir.path}/DNaiApp');
      if (await dir.exists()) {
        locations.add(("앱 저장 폴더", dir.path));
      }
    }

    // 문서 디렉토리 (폴백)
    if (locations.isEmpty) {
      final docDir = await getApplicationDocumentsDirectory();
      locations.add(("기본 폴더", docDir.path));
    }

    return locations;
  }

  // 갤러리 기본 경로 (앱 외부 저장소의 DNaiApp 폴더).
  Future<String> getGalleryBasePath() async {
    final appDir = await getExternalStorageDirectory();
    if (appDir != null) {
      final dir = Directory('${appDir.path}/DNaiApp');
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {}
      }
      return dir.path;
    }
    final docDir = await getApplicationDocumentsDirectory();
    return docDir.path;
  }

  String selectedModel = NaiModels.v45Full;
  String selectedSampler = "k_euler_ancestral";
  String selectedScheduler = "karras";
  String selectedResolution = "832 x 1216";
  double resolutionScale = 1.0; // 1.0, 1.5, 2.0

  // 픽셀/개수 한계 상수 (매직넘버 방지)
  //  - kMegapixelCap: 1024×1024. 자동 모드 상한이자 Opus 무료 생성 기준
  //  - kNaiPixelHardCap: NAI가 허용하는 절대 픽셀 상한
  static const int kMegapixelCap = 1048576;
  static const int kNaiPixelHardCap = 3145728;
  static const int kHistoryCap = 100; // 히스토리 최대 보관 장수
  List<String> customResolutions = []; // 사용자 추가 해상도

  List<NaiCharacter> characters = [NaiCharacter()];
  int selectedCharIndex = 0;
  bool useCharacterPosition = true; // 캐릭터 배치 적용 ON/OFF (그리드 좌표 반영)
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
  // 검색 후 단계 메시지 (분류/필터/캐시 — 페이지 수신 완료 후 표시)
  String gelbooruSearchStage = "";

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

  // i2i 스크래치 릴 (인페인트 등 반복 결과 임시 보관, 즐겨찾기만 영속)
  List<I2iResult> i2iResults = [];
  static const int i2iResultsCap = 30; // 릴 전체 보관 상한 (즐겨찾기 포함)
  static const int i2iFavoriteCap = 5; // 즐겨찾기 최대 개수
  double i2iHandleBottom = -1; // i2i 릴 핸들 세로 위치 (-1이면 기본값 사용)
  double promptCharHandleTop = -1; // 프롬프트 탭 캐릭터 편집 손잡이 세로 위치 (-1이면 기본값)
  bool i2iHistoryDisabled = false; // ON이면 릴 끄고 i2i 결과를 메인 히스토리에 저장
  // i2i 히스토리 핸들이 켜져 있을 때의 인페인트 세부 옵션
  bool inpaintNoAutoSwitch = false; // 인페인트 후 결과로 전환하지 않음 (기본 OFF = 전환함)
  bool inpaintAutoClearMask = false; // 인페인트 시 마스킹 자동 해제 (기본 OFF=유지)
  bool galleryModeEnabled = true; // 갤러리 모드(공용 폴더 탐색) 사용 여부 — 기본 ON

  // SAF (Storage Access Framework) — 사용자가 고른 저장 폴더의 트리 URI
  final SafUtil _safUtil = SafUtil();
  final SafStream _safStream = SafStream();
  String? safRootUri; // 선택된 SAF 트리 URI (null = 미선택)
  String? safRootName; // 표시용 폴더명
  String? _safSessionDirUri; // 현재 세션의 SAF 디렉토리 URI 캐시
  String? _safSessionDirName; // 캐시된 세션 이름

  List<Uint8List> i2iHistoryImages = [];
  List<NaiMetadata?> i2iHistoryMetadata = [];
  int selectedI2iHistoryIndex = -1;

  Uint8List? targetI2iImage;
  NaiMetadata? targetI2iMetadata;

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

  void setThemeAccent(int argb) {
    themeAccent = argb;
    AppColors.accent = Color(argb);
    saveAllSettings();
    notifyListeners();
  }

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

  Future<void> loadInitialData() async {
    // pubspec.yaml의 version을 자동으로 읽어옴
    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
    } catch (_) {}

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
        notifyListeners();
        return;
      }
    }

    apiToken = prefs.getString('api_token') ?? "";
    apiTokenController.text = apiToken;
    // 토큰이 있으면 실제 서버에 검증 (Anlas 조회)
    if (apiToken.isNotEmpty) {
      try {
        _setLoadingStatus("API 연결 확인 중...");
        await fetchAnlas();
        isApiConnected = currentAnlas >= 0;
      } catch (_) {
        isApiConnected = false;
      }
    } else {
      isApiConnected = false;
    }
    customFileNameController.text =
        prefs.getString('custom_file_name') ?? "Nai-{yy}{mm}{dd}-{time}";
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
    removeClothingEvents = prefs.getBool('remove_clothing_events') ?? false;
    charRetapToggle = prefs.getBool('charRetapToggle') ?? true;
    saveFolderByDateOnly = prefs.getBool('saveFolderByDateOnly') ?? false;
    removeColors = prefs.getBool('remove_colors') ?? false;
    customRemoveController.text = prefs.getString('custom_remove') ?? "";
    isAutoSave = prefs.getBool('auto_save') ?? true;
    saveAsWebp = prefs.getBool('saveAsWebp') ?? false;
    webpLossy = prefs.getBool('webpLossy') ?? false;
    isRandomLocked = prefs.getBool('random_lock') ?? false;
    isFurryMode = prefs.getBool('furry') ?? false;
    isSeedLocked = prefs.getBool('seedLocked') ?? false;
    infillStrength = prefs.getDouble('infillStrength') ?? 0.7;
    img2imgStrength = prefs.getDouble('img2imgStrength') ?? 0.5;
    img2imgNoise = prefs.getDouble('img2imgNoise') ?? 0.1;
    isVariancePlus = prefs.getBool('variancePlus') ?? false;
    horizontalSwipeEnabled = prefs.getBool('horizontalSwipeEnabled') ?? false;
    i2iAltLayout = true; // [1차 UI 비활성] 저장값과 무관하게 항상 2차 배치
    promptAltLayout = prefs.getBool('promptAltLayout') ?? false;
    promptNewLayout = prefs.getBool('promptNewLayout') ?? false;
    gelbooruSearchPages = (prefs.getInt('gelbooruSearchPages') ?? 40).clamp(40, 120);
    diversifySearchSort = prefs.getBool('diversifySearchSort') ?? false;
    promptCharDrawerEnabled = prefs.getBool('promptCharDrawerEnabled') ?? false;
    weightRulesEnabled = prefs.getBool('weightRulesEnabled') ?? false;
    weightRulesController.text = prefs.getString('weightRules') ?? "";
    historySlideEnabled = prefs.getBool('historySlideEnabled') ?? false;
    randomPromptAlphabetical = prefs.getBool('randomPromptAlphabetical') ?? false;
    ignoreRecommendedOrder = prefs.getBool('ignoreRecommendedOrder') ?? false;
    weightHighlight = prefs.getBool('weightHighlight') ?? true;
    e621Enabled = prefs.getBool('e621Enabled') ?? false;
    safCardOpen = prefs.getBool('safCardOpen') ?? true;
    fileCardOpen = prefs.getBool('fileCardOpen') ?? true;
    themeAccent = prefs.getInt('themeAccent') ?? 0xFF7C4DFF;
    AppColors.accent = Color(themeAccent);
    i2iHistoryDisabled = prefs.getBool('i2iHistoryDisabled') ?? false;
    // 옛 설정(inpaintAutoSwitchResult)은 의미가 반대였다. 남아 있으면 뒤집어서 이어받는다.
    final legacyAutoSwitch = prefs.getBool('inpaintAutoSwitchResult');
    inpaintNoAutoSwitch =
        prefs.getBool('inpaintNoAutoSwitch') ??
        (legacyAutoSwitch != null ? !legacyAutoSwitch : false);
    inpaintAutoClearMask = prefs.getBool('inpaintAutoClearMask') ?? false;
    galleryModeEnabled = prefs.getBool('galleryModeEnabled') ?? true;
    galleryCurrentPath = prefs.getString('galleryCurrentPath');
    galleryColumns = prefs.getInt('galleryColumns') ?? 3;
    promptEditorFontSize = prefs.getDouble('promptEditorFontSize') ?? 16.0;
    gallerySortMode = prefs.getString('gallerySortMode') ?? 'name_asc';
    WeightHighlightController.highlightEnabled = weightHighlight;
    batchDelay = prefs.getDouble('batchDelay') ?? 0.5;
    autoNextPromptInBatch = prefs.getBool('autoNextPromptInBatch') ?? false;
    repeatSamePromptEnabled = prefs.getBool('repeatSamePromptEnabled') ?? false;
    repeatSamePromptCount = prefs.getInt('repeatSamePromptCount') ?? 2;
    autoCheckUpdate = prefs.getBool('autoCheckUpdate') ?? true;
    historyTabEnabled = prefs.getBool('historyTabEnabled') ?? true;
    i2iTabEnabled = prefs.getBool('i2iTabEnabled') ?? true;
    i2iModeInpaintEnabled = prefs.getBool('i2iModeInpaintEnabled') ?? true;
    i2iModeMosaicEnabled = prefs.getBool('i2iModeMosaicEnabled') ?? true;
    i2iModeImg2imgEnabled = prefs.getBool('i2iModeImg2imgEnabled') ?? true;
    i2iModeUpscaleEnabled = prefs.getBool('i2iModeUpscaleEnabled') ?? true;
    // 일관성 보정: 모드가 전부 꺼져 있으면 탭도 꺼져 있어야 함 (모순 조합 정리)
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false;
    }
    characterTabEnabled = prefs.getBool('characterTabEnabled') ?? true;
    useCharacterPosition = prefs.getBool('useCharacterPosition') ?? true;
    randomCharacterOrder = prefs.getBool('randomCharacterOrder') ?? false;
    if (useCharacterPosition && randomCharacterOrder) {
      randomCharacterOrder = false; // 상호 배타 보정
    }
    wildcardTabEnabled = prefs.getBool('wildcardTabEnabled') ?? true;
    useGelbooruApiKey = prefs.getBool('useGelbooruApiKey') ?? true;
    resolutionMode = prefs.getString('resolutionMode') ?? "수동";
    final sectionOrderJson = prefs.getStringList('promptSectionOrder');
    if (sectionOrderJson != null && sectionOrderJson.isNotEmpty) {
      // 저장된 순서를 쓰되, 새로 생긴 섹션은 뒤에 붙이고 없어진 섹션은 버린다.
      // (길이를 고정하면 섹션이 추가될 때 저장된 순서가 통째로 무시됨)
      promptSectionOrder = _mergeSectionOrder(sectionOrderJson);
    }
    hiddenPromptSections = (prefs.getStringList('hiddenPromptSections') ?? []).toSet();
    pinnedPromptSections = (prefs.getStringList('pinnedPromptSections') ?? []).toSet();
    conditionalGuideCollapsed = prefs.getBool('conditionalGuideCollapsed') ?? false;
    collapsedI2iPrompts = (prefs.getStringList('collapsedI2iPrompts') ?? []).toSet();
    collapsedSettingGroups = (prefs.getStringList('collapsedSettingGroups') ?? []).toSet();
    final collapsedJson = prefs.getStringList('collapsedSections');
    if (collapsedJson != null) {
      collapsedSections = collapsedJson.toSet();
    }
    selectedModel = prefs.getString('model') ?? NaiModels.v45Full;
    // 제거된 테스트 모델이 저장돼 있으면 실제 v4.5로 교정 (드롭다운 크래시 방지)
    if (selectedModel == "nai-diffusion-4-5-full-test") {
      selectedModel = NaiModels.v45Full;
    }
    selectedSampler = prefs.getString('sampler') ?? "k_euler_ancestral";
    // ddim은 V4 계열에서 동작하지 않아 제거됨 — 예전 설정이 남아 있으면 기본값으로
    if (selectedSampler == 'ddim') {
      selectedSampler = "k_euler_ancestral";
    }
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
    _setLoadingStatus("히스토리 불러오는 중...");
    await _loadHistoryFromLocal();
    await loadReferencesFromLocal();
    await loadI2iFavorites();
    await _loadSafRoot();
    notifyListeners();

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
      'remove_clothing_events': removeClothingEvents,
      'charRetapToggle': charRetapToggle,
      'saveFolderByDateOnly': saveFolderByDateOnly,
      'remove_colors': removeColors,
      'auto_save': isAutoSave,
      'saveAsWebp': saveAsWebp,
      'webpLossy': webpLossy,
      'random_lock': isRandomLocked,
      'furry': isFurryMode,
      'seedLocked': isSeedLocked,
      'infillStrength': infillStrength,
      'img2imgStrength': img2imgStrength,
      'img2imgNoise': img2imgNoise,
      'variancePlus': isVariancePlus,
      'horizontalSwipeEnabled': horizontalSwipeEnabled,
      'i2iAltLayout': i2iAltLayout,
      'promptAltLayout': promptAltLayout,
      'promptNewLayout': promptNewLayout,
      'gelbooruSearchPages': gelbooruSearchPages,
      'diversifySearchSort': diversifySearchSort,
      'promptCharDrawerEnabled': promptCharDrawerEnabled,
      'weightRulesEnabled': weightRulesEnabled,
      'weightRules': weightRulesController.text,
      'historySlideEnabled': historySlideEnabled,
      'randomPromptAlphabetical': randomPromptAlphabetical,
      'ignoreRecommendedOrder': ignoreRecommendedOrder,
      'weightHighlight': weightHighlight,
      'e621Enabled': e621Enabled,
      'safCardOpen': safCardOpen,
      'fileCardOpen': fileCardOpen,
      'themeAccent': themeAccent,
      'i2iHistoryDisabled': i2iHistoryDisabled,
      'inpaintNoAutoSwitch': inpaintNoAutoSwitch,
      'inpaintAutoClearMask': inpaintAutoClearMask,
      'galleryModeEnabled': galleryModeEnabled,
      'galleryCurrentPath': galleryCurrentPath,
      'galleryColumns': galleryColumns,
      'promptEditorFontSize': promptEditorFontSize,
      'gallerySortMode': gallerySortMode,
      'batchDelay': batchDelay,
      'autoNextPromptInBatch': autoNextPromptInBatch,
      'repeatSamePromptEnabled': repeatSamePromptEnabled,
      'repeatSamePromptCount': repeatSamePromptCount,
      'historyTabEnabled': historyTabEnabled,
      'i2iTabEnabled': i2iTabEnabled,
      'i2iModeInpaintEnabled': i2iModeInpaintEnabled,
      'i2iModeMosaicEnabled': i2iModeMosaicEnabled,
      'i2iModeImg2imgEnabled': i2iModeImg2imgEnabled,
      'i2iModeUpscaleEnabled': i2iModeUpscaleEnabled,
      'characterTabEnabled': characterTabEnabled,
      'useCharacterPosition': useCharacterPosition,
      'randomCharacterOrder': randomCharacterOrder,
      'wildcardTabEnabled': wildcardTabEnabled,
      'useGelbooruApiKey': useGelbooruApiKey,
      'gelbooru_api_input': gelbooruApiController.text,
      'resolution': selectedResolution,
      'resolutionScale': resolutionScale,
      'customResolutions': customResolutions,
      'autoCheckUpdate': autoCheckUpdate,
      'collapsedSections': collapsedSections.toList(),
      'hiddenPromptSections': hiddenPromptSections.toList(),
      'pinnedPromptSections': pinnedPromptSections.toList(),
      'conditionalGuideCollapsed': conditionalGuideCollapsed,
      'collapsedI2iPrompts': collapsedI2iPrompts.toList(),
      'collapsedSettingGroups': collapsedSettingGroups.toList(),
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
    customFileNameController.text = data['custom_file_name'] ?? 'Nai-{yy}{mm}{dd}-{time}';
    customWidthController.text = data['custom_width'] ?? '832';
    customHeightController.text = data['custom_height'] ?? '1216';
    customRemoveController.text = data['custom_remove'] ?? '';
    selectedModel = data['model'] ?? NaiModels.v45Full;
    if (selectedModel == "nai-diffusion-4-5-full-test") {
      selectedModel = NaiModels.v45Full;
    }
    selectedSampler = data['sampler'] ?? 'k_euler_ancestral';
    selectedScheduler = data['scheduler'] ?? 'karras';
    resolutionMode = data['resolutionMode'] ?? '수동';
    if (data['promptSectionOrder'] != null) {
      promptSectionOrder = _mergeSectionOrder(List<String>.from(data['promptSectionOrder']));
    }
    ratingE = data['rating_e'] ?? false;
    ratingQ = data['rating_q'] ?? false;
    ratingS = data['rating_s'] ?? false;
    ratingG = data['rating_g'] ?? true;
    removeCharacteristics = data['remove_char_traits'] ?? false;
    removeClothes = data['remove_clothes'] ?? false;
    removeClothingEvents = data['remove_clothing_events'] ?? false;
    charRetapToggle = data['charRetapToggle'] ?? true;
    saveFolderByDateOnly = data['saveFolderByDateOnly'] ?? false;
    removeColors = data['remove_colors'] ?? false;
    isAutoSave = data['auto_save'] ?? true;
    saveAsWebp = data['saveAsWebp'] ?? false;
    webpLossy = data['webpLossy'] ?? false;
    isRandomLocked = data['random_lock'] ?? false;
    isFurryMode = data['furry'] ?? false;
    isSeedLocked = data['seedLocked'] ?? false;
    infillStrength = (data['infillStrength'] ?? 0.7).toDouble();
    img2imgStrength = (data['img2imgStrength'] ?? 0.5).toDouble();
    img2imgNoise = (data['img2imgNoise'] ?? 0.1).toDouble();
    isVariancePlus = data['variancePlus'] ?? false;
    horizontalSwipeEnabled = data['horizontalSwipeEnabled'] ?? false;
    i2iAltLayout = true; // [1차 UI 비활성] 백업을 불러와도 2차 배치 유지
    promptAltLayout = data['promptAltLayout'] ?? false;
    promptNewLayout = data['promptNewLayout'] ?? false;
    gelbooruSearchPages = ((data['gelbooruSearchPages'] ?? 40) as int).clamp(40, 120);
    diversifySearchSort = data['diversifySearchSort'] ?? false;
    promptCharDrawerEnabled = data['promptCharDrawerEnabled'] ?? false;
    weightRulesEnabled = data['weightRulesEnabled'] ?? false;
    weightRulesController.text = data['weightRules'] ?? "";
    historySlideEnabled = data['historySlideEnabled'] ?? false;
    randomPromptAlphabetical = data['randomPromptAlphabetical'] ?? false;
    ignoreRecommendedOrder = data['ignoreRecommendedOrder'] ?? false;
    weightHighlight = data['weightHighlight'] ?? true;
    e621Enabled = data['e621Enabled'] ?? false;
    safCardOpen = data['safCardOpen'] ?? true;
    fileCardOpen = data['fileCardOpen'] ?? true;
    themeAccent = data['themeAccent'] ?? 0xFF7C4DFF;
    AppColors.accent = Color(themeAccent);
    i2iHistoryDisabled = data['i2iHistoryDisabled'] ?? false;
    // 옛 백업 호환: inpaintAutoSwitchResult(반대 의미)가 있으면 뒤집어서 적용
    inpaintNoAutoSwitch =
        data['inpaintNoAutoSwitch'] ??
        (data['inpaintAutoSwitchResult'] != null ? !data['inpaintAutoSwitchResult'] : false);
    inpaintAutoClearMask = data['inpaintAutoClearMask'] ?? false;
    galleryModeEnabled = data['galleryModeEnabled'] ?? true;
    galleryCurrentPath = data['galleryCurrentPath'];
    galleryColumns = data['galleryColumns'] ?? 3;
    promptEditorFontSize = (data['promptEditorFontSize'] as num?)?.toDouble() ?? 16.0;
    gallerySortMode = data['gallerySortMode'] ?? 'name_asc';
    WeightHighlightController.highlightEnabled = weightHighlight;
    batchDelay = (data['batchDelay'] ?? 0.5).toDouble();
    autoNextPromptInBatch = data['autoNextPromptInBatch'] ?? false;
    repeatSamePromptEnabled = data['repeatSamePromptEnabled'] ?? false;
    repeatSamePromptCount = data['repeatSamePromptCount'] ?? 2;
    historyTabEnabled = data['historyTabEnabled'] ?? true;
    i2iTabEnabled = data['i2iTabEnabled'] ?? true;
    i2iModeInpaintEnabled = data['i2iModeInpaintEnabled'] ?? true;
    i2iModeMosaicEnabled = data['i2iModeMosaicEnabled'] ?? true;
    i2iModeImg2imgEnabled = data['i2iModeImg2imgEnabled'] ?? true;
    i2iModeUpscaleEnabled = data['i2iModeUpscaleEnabled'] ?? true;
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false; // 모순 조합 정리
    }
    characterTabEnabled = data['characterTabEnabled'] ?? true;
    useCharacterPosition = data['useCharacterPosition'] ?? true;
    randomCharacterOrder = data['randomCharacterOrder'] ?? false;
    if (useCharacterPosition && randomCharacterOrder) {
      randomCharacterOrder = false; // 상호 배타 보정
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
    wildcardTabEnabled = data['wildcardTabEnabled'] ?? true;
    historyTabEnabled = data['historyTabEnabled'] ?? true;
    i2iTabEnabled = data['i2iTabEnabled'] ?? true;
    i2iModeInpaintEnabled = data['i2iModeInpaintEnabled'] ?? true;
    i2iModeMosaicEnabled = data['i2iModeMosaicEnabled'] ?? true;
    i2iModeImg2imgEnabled = data['i2iModeImg2imgEnabled'] ?? true;
    i2iModeUpscaleEnabled = data['i2iModeUpscaleEnabled'] ?? true;
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false; // 모순 조합 정리
    }
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
    if (data['hiddenPromptSections'] != null) {
      hiddenPromptSections = Set<String>.from(data['hiddenPromptSections']);
    }
    if (data['pinnedPromptSections'] != null) {
      pinnedPromptSections = Set<String>.from(data['pinnedPromptSections']);
    }
    conditionalGuideCollapsed = data['conditionalGuideCollapsed'] ?? false;
    if (data['collapsedI2iPrompts'] != null) {
      collapsedI2iPrompts = Set<String>.from(data['collapsedI2iPrompts']);
    }
    if (data['collapsedSettingGroups'] != null) {
      collapsedSettingGroups = Set<String>.from(data['collapsedSettingGroups']);
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
      await prefs.setBool('remove_clothing_events', removeClothingEvents);
      await prefs.setBool('charRetapToggle', charRetapToggle);
      await prefs.setBool('saveFolderByDateOnly', saveFolderByDateOnly);
      await prefs.setBool('remove_colors', removeColors);
      await prefs.setString('custom_remove', customRemoveController.text);
      await prefs.setBool('auto_save', isAutoSave);
      await prefs.setBool('saveAsWebp', saveAsWebp);
      await prefs.setBool('webpLossy', webpLossy);
      await prefs.setBool('random_lock', isRandomLocked);
      await prefs.setBool('furry', isFurryMode);
      await prefs.setBool('seedLocked', isSeedLocked);
      await prefs.setDouble('infillStrength', infillStrength);
      await prefs.setDouble('img2imgStrength', img2imgStrength);
      await prefs.setDouble('img2imgNoise', img2imgNoise);
      await prefs.setBool('variancePlus', isVariancePlus);
      await prefs.setBool('horizontalSwipeEnabled', horizontalSwipeEnabled);
      await prefs.setBool('i2iAltLayout', i2iAltLayout);
      await prefs.setBool('promptAltLayout', promptAltLayout);
      await prefs.setBool('promptNewLayout', promptNewLayout);
      await prefs.setInt('gelbooruSearchPages', gelbooruSearchPages);
      await prefs.setBool('diversifySearchSort', diversifySearchSort);
      await prefs.setBool('promptCharDrawerEnabled', promptCharDrawerEnabled);
      await prefs.setBool('weightRulesEnabled', weightRulesEnabled);
      await prefs.setString('weightRules', weightRulesController.text);
      await prefs.setBool('historySlideEnabled', historySlideEnabled);
      await prefs.setBool('randomPromptAlphabetical', randomPromptAlphabetical);
      await prefs.setBool('ignoreRecommendedOrder', ignoreRecommendedOrder);
      await prefs.setBool('weightHighlight', weightHighlight);
      await prefs.setBool('e621Enabled', e621Enabled);
      await prefs.setBool('safCardOpen', safCardOpen);
      await prefs.setBool('fileCardOpen', fileCardOpen);
      await prefs.setInt('themeAccent', themeAccent);
      await prefs.setBool('i2iHistoryDisabled', i2iHistoryDisabled);
      await prefs.setBool('inpaintNoAutoSwitch', inpaintNoAutoSwitch);
      await prefs.setBool('inpaintAutoClearMask', inpaintAutoClearMask);
      await prefs.setBool('galleryModeEnabled', galleryModeEnabled);
      if (galleryCurrentPath != null) {
        await prefs.setString('galleryCurrentPath', galleryCurrentPath!);
      }
      await prefs.setInt('galleryColumns', galleryColumns);
      await prefs.setDouble('promptEditorFontSize', promptEditorFontSize);
      await prefs.setString('gallerySortMode', gallerySortMode);
      await prefs.setDouble('batchDelay', batchDelay);
      await prefs.setBool('autoNextPromptInBatch', autoNextPromptInBatch);
      await prefs.setBool('repeatSamePromptEnabled', repeatSamePromptEnabled);
      await prefs.setInt('repeatSamePromptCount', repeatSamePromptCount);
      await prefs.setBool('autoCheckUpdate', autoCheckUpdate);
      await prefs.setBool('historyTabEnabled', historyTabEnabled);
      await prefs.setBool('i2iTabEnabled', i2iTabEnabled);
      await prefs.setBool('i2iModeInpaintEnabled', i2iModeInpaintEnabled);
      await prefs.setBool('i2iModeMosaicEnabled', i2iModeMosaicEnabled);
      await prefs.setBool('i2iModeImg2imgEnabled', i2iModeImg2imgEnabled);
      await prefs.setBool('i2iModeUpscaleEnabled', i2iModeUpscaleEnabled);
      await prefs.setBool('characterTabEnabled', characterTabEnabled);
      await prefs.setBool('useCharacterPosition', useCharacterPosition);
      await prefs.setBool('randomCharacterOrder', randomCharacterOrder);
      await prefs.setBool('wildcardTabEnabled', wildcardTabEnabled);
      await prefs.setStringList('promptSectionOrder', promptSectionOrder);
      await prefs.setStringList('collapsedSections', collapsedSections.toList());
      await prefs.setStringList('hiddenPromptSections', hiddenPromptSections.toList());
      await prefs.setStringList('pinnedPromptSections', pinnedPromptSections.toList());
      await prefs.setBool('conditionalGuideCollapsed', conditionalGuideCollapsed);
      await prefs.setStringList('collapsedI2iPrompts', collapsedI2iPrompts.toList());
      await prefs.setStringList('collapsedSettingGroups', collapsedSettingGroups.toList());
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
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/settings_backup.json');
      // exportSettings에서 히스토리 제외 (용량 절약 + 빠른 저장)
      final data = await exportSettings(includeHistory: false);
      data['backup_time'] = DateTime.now().toIso8601String();
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
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
    i2iMaskActionOnChange = I2iMaskAction.clearMask; // 보내기는 항상 마스킹 초기화
    targetI2iImage = imageBytes;
    targetI2iMetadata = metadata;
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
    gelbooruSearchDone = 0;
    gelbooruSearchTotal = 0;
    gelbooruSearchStage = "";
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
        // 의상/특징 제거는 검색 결과엔 적용하지 않음 (원본 보존).
        // '다음 프롬프트'/'다시 불러오기' 시 _processAndSetPrompt에서 토글에 따라 걸러진다.
        removeCharacteristics: false,
        removeClothes: false,
        gelbooruUserId: gelbooruUserId,
        gelbooruApiKey: gelbooruApiKey,
        // API 키가 있을 때만 사용자 지정 페이지 수 적용 (없으면 서비스 기본값 사용)
        maxPagesToFetch: gelbooruApiKey.isNotEmpty ? gelbooruSearchPages : 20,
        diversifySort: diversifySearchSort,
        onProgress: (done, total, found) {
          gelbooruSearchDone = done;
          gelbooruSearchTotal = total;
          // '검색 : N' / '남음 : N'이 검색 중에도 점점 차오르도록 실시간 반영
          // (최종 정확한 값은 검색 완료 시 결과 개수로 다시 확정됨)
          gelbooruTotal = found;
          gelbooruRemaining = found;
          notifyListeners();
        },
        onStage: (stage) {
          gelbooruSearchStage = stage;
          notifyListeners();
        },
      );
      isGelbooruLoading = false;
      gelbooruSearchDone = 0;
      gelbooruSearchTotal = 0;
      gelbooruSearchStage = "";

      if (!context.mounted) {
        return;
      }

      if (results.isNotEmpty) {
        results.shuffle();
        gelbooruPrompts = results;
        gelbooruTotal = results.length;
        gelbooruRemaining = gelbooruTotal;
        saveAllSettings();
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
      gelbooruSearchDone = 0;
      gelbooruSearchTotal = 0;
      gelbooruSearchStage = "";
      // 실시간으로 차오르던 카운트도 리셋 (실패 시 실제 프롬프트는 없음)
      gelbooruTotal = 0;
      gelbooruRemaining = 0;
      if (!context.mounted) {
        return;
      }

      String errorMsg = e.toString().replaceFirst('Exception: ', '');
      String title;
      String detail;

      if (errorMsg.contains('__NO_RESULTS__')) {
        // 순수하게 검색 결과 0개 (에러 아님, 검색 범위 문제)
        title = "검색 결과 없음";
        detail =
            "조건에 맞는 이미지를 찾지 못했어요.\n\n"
            "포함 태그: ${gelbooruIncludeController.text}\n\n"
            "💡 검색 범위를 넓혀보세요:\n"
            "• 태그 수를 줄이기 (너무 구체적이면 결과가 적어요)\n"
            "• 레이팅 필터 확인 (G/S/Q/E)\n"
            "• 제외 태그가 너무 많은지 확인\n"
            "• 태그 철자 확인\n\n"
            "조건을 조정한 뒤 다시 검색해주세요.";
      } else if (errorMsg.contains('429') || errorMsg.contains('요청 과다')) {
        title = "요청이 너무 많습니다 (429)";
        detail =
            "짧은 시간에 검색을 너무 많이 했어요.\n\n$errorMsg\n\n"
            "💡 잠시(10~30초) 기다린 뒤 다시 검색해주세요.\n"
            "API 키를 설정하면 한도가 늘어납니다.";
      } else if (errorMsg.contains('시간 초과')) {
        title = "서버 응답 없음";
        detail =
            "Gelbooru 서버가 응답하지 않습니다.\n\n$errorMsg\n\n"
            "가능한 원인:\n"
            "• Gelbooru 서버 점검/장애\n"
            "• 인터넷 연결 불안정\n"
            "• 프록시 서버 문제";
      } else if (errorMsg.contains('서버 오류')) {
        title = "서버 오류";
        detail =
            "Gelbooru 서버에서 오류가 발생했습니다.\n\n$errorMsg\n\n"
            "💡 서버가 불안정할 수 있어요. 잠시 후 다시 시도해주세요.";
      } else if (errorMsg.contains('요청 오류')) {
        title = "요청 오류";
        detail =
            "요청에 문제가 있습니다.\n\n$errorMsg\n\n"
            "가능한 원인:\n"
            "• API 키 오류 (설정 탭에서 확인)\n"
            "• 태그 형식 오류";
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
      // 작가/캐릭터/작품 '이름' 백스톱: 검색 단계에서 카테고리 조회가 실패했거나(429/오프라인)
      // 과거에 저장된 프롬프트에 이름이 남아있는 경우를 여기서 최종 차단
      // (정적 사전 + 에셋 사전 + 패턴 안전장치를 isNameTag 하나로 통일)
      final String underscored = cleanTag.replaceAll(' ', '_');
      if (TagFilters.isNameTag(underscored)) {
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
      // 의상 상태/동작 (unworn, torn, grab 등) — 의상 제거와 짝으로 쓰면 옷 관련이 깔끔히 정리된다
      if (removeClothingEvents &&
          (TagFilters.clothingEventTags.contains(t) ||
              TagFilters.clothingEventTags.contains(cleanTag))) {
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

  // 순차 생성 <A|B|C>: 생성마다 다음 옵션을 순서대로 선택 (중첩 지원)
  // 카운터 키 = "경로/내용해시" → 중첩 시 실제 도달한 <>만 증가, 위치 무관하게 안정적.
  // 중첩 예: <A|<B|C>|D> → A → B → D → A → C → D (각 <> 독립 카운트)

  // 최상위 | 로 분리 (<> 안의 | 은 무시)
  // 최상위 | 로 분리 (<< >> 안의 | 은 무시)
  List<String> _splitTopPipe(String s) {
    final parts = <String>[];
    int depth = 0;
    final buf = StringBuffer();
    int i = 0;
    while (i < s.length) {
      if (i + 1 < s.length && s[i] == '<' && s[i + 1] == '<') {
        depth++;
        buf.write('<<');
        i += 2;
      } else if (i + 1 < s.length && s[i] == '>' && s[i + 1] == '>') {
        depth--;
        buf.write('>>');
        i += 2;
      } else if (s[i] == '|' && depth == 0) {
        parts.add(buf.toString().trim());
        buf.clear();
        i++;
      } else {
        buf.write(s[i]);
        i++;
      }
    }
    if (buf.toString().trim().isNotEmpty) {
      parts.add(buf.toString().trim());
    }
    return parts.where((e) => e.isNotEmpty).toList();
  }

  // 순차 처리 (재귀, 바깥 <<>>부터). path = 카운터 식별 경로.
  String _processSequentialRec(String text, String path) {
    final result = StringBuffer();
    int i = 0;
    int seqIdx = 0;
    while (i < text.length) {
      if (i + 1 < text.length && text[i] == '<' && text[i + 1] == '<') {
        // 매칭되는 >> 찾기 (중첩 깊이 고려)
        int depth = 1;
        int j = i + 2;
        while (j < text.length && depth > 0) {
          if (j + 1 < text.length && text[j] == '<' && text[j + 1] == '<') {
            depth++;
            j += 2;
          } else if (j + 1 < text.length && text[j] == '>' && text[j + 1] == '>') {
            depth--;
            j += 2;
          } else {
            j++;
          }
        }
        // 닫는 >>가 없으면(depth>0) 순차 문법이 아님 → '<'를 그대로 출력하고 진행
        if (depth > 0) {
          result.write(text[i]);
          i++;
          continue;
        }
        final inner = text.substring(i + 2, j - 2);
        final opts = _splitTopPipe(inner);
        if (opts.isEmpty) {
          // 빈 <<>> → 제거
        } else if (opts.length == 1) {
          result.write(_processSequentialRec(opts[0], "$path/$seqIdx"));
        } else {
          // 이 <<>>의 카운터 키 (경로 + 내용)
          final key = "$path/$seqIdx:$inner";
          final idx = _sequentialCounters[key] ?? 0;
          final chosen = opts[idx % opts.length];
          // 선택된 옵션 안에 또 <<>>가 있으면 재귀
          result.write(_processSequentialRec(chosen, key));
        }
        seqIdx++;
        i = j;
      } else {
        result.write(text[i]);
        i++;
      }
    }
    return result.toString();
  }

  String _processSequential(String prompt) {
    return _processSequentialRec(prompt, "");
  }

  // 순차 와일드카드(@) 카운터 전진. 프롬프트의 __@이름__ 등장 순서대로 +1.
  void _advanceSequentialWildcards(String prompt) {
    final regex = RegExp(r'__(@[^_]+?)__');
    int pos = 0;
    for (final m in regex.allMatches(prompt)) {
      String body = m.group(1)!.substring(1); // @ 제거
      // :숫자 제거 (이름만 추출)
      final colonIdx = body.lastIndexOf(':');
      if (colonIdx != -1 && int.tryParse(body.substring(colonIdx + 1)) != null) {
        body = body.substring(0, colonIdx);
      }
      final key = "wc@$pos:$body";
      _sequentialCounters[key] = (_sequentialCounters[key] ?? 0) + 1;
      pos++;
    }
  }

  // 순차 카운터 전진: 이번 생성에서 실제로 "도달한" <<>>만 +1 (중첩 정확성)
  void _advanceSequential(String prompt) {
    final evaluated = <String>[];
    void walk(String text, String path) {
      int i = 0;
      int seqIdx = 0;
      while (i < text.length) {
        if (i + 1 < text.length && text[i] == '<' && text[i + 1] == '<') {
          int depth = 1;
          int j = i + 2;
          while (j < text.length && depth > 0) {
            if (j + 1 < text.length && text[j] == '<' && text[j + 1] == '<') {
              depth++;
              j += 2;
            } else if (j + 1 < text.length && text[j] == '>' && text[j + 1] == '>') {
              depth--;
              j += 2;
            } else {
              j++;
            }
          }
          // 닫는 >>가 없으면 순차 문법이 아님 → 건너뜀
          if (depth > 0) {
            i++;
            continue;
          }
          final inner = text.substring(i + 2, j - 2);
          final opts = _splitTopPipe(inner);
          if (opts.length == 1) {
            walk(opts[0], "$path/$seqIdx");
          } else if (opts.isNotEmpty) {
            final key = "$path/$seqIdx:$inner";
            evaluated.add(key);
            final idx = _sequentialCounters[key] ?? 0;
            walk(opts[idx % opts.length], key);
          }
          seqIdx++;
          i = j;
        } else {
          i++;
        }
      }
    }

    walk(prompt, "");
    for (final k in evaluated) {
      _sequentialCounters[k] = (_sequentialCounters[k] ?? 0) + 1;
    }
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
    // 순차 와일드카드(@) 위치 카운터: 같은 패스 내 등장 순서별 독립
    int seqWildcardPos = 0;
    while (regex.hasMatch(result) && depth < 5) {
      result = result.replaceAllMapped(regex, (match) {
        String wName = match.group(1)!;

        // 순차 와일드카드 문법: @이름 또는 @이름:시작행
        // 예: @Cloth → 줄 순서대로, @Cloth:2 → 2번째 행부터 시작
        bool isSequential = false;
        int startOffset = 0;
        if (wName.startsWith('@')) {
          isSequential = true;
          String body = wName.substring(1); // @ 제거
          // :숫자 (시작 행) 파싱
          final colonIdx = body.lastIndexOf(':');
          if (colonIdx != -1) {
            final numStr = body.substring(colonIdx + 1);
            final parsed = int.tryParse(numStr);
            if (parsed != null && parsed >= 1) {
              startOffset = parsed - 1; // 2번째 행 = 인덱스 1
              body = body.substring(0, colonIdx);
            }
          }
          wName = body;
        }

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

        // 순차 와일드카드: 줄 순서대로 (시작 오프셋 적용)
        if (isSequential) {
          // 카운터 키 = "wc@위치:이름" (같은 와일드카드 여러 번 쓰면 위치로 독립)
          final key = "wc@$seqWildcardPos:$wName";
          seqWildcardPos++;
          final counter = _sequentialCounters[key] ?? 0;
          final idx = (counter + startOffset) % options.length;
          // 가중치 문법(N)텍스트)이 있으면 텍스트만 추출
          String selected = options[idx];
          final wm = RegExp(r'^(\d+)\)(.*)$').firstMatch(selected);
          if (wm != null) {
            selected = wm.group(2)!.trim();
          }
          return selected;
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

  // 조건부 트리거 규칙 텍스트 → (조건, 액션) 쌍 목록. 두 적용 함수가 공유하는 파서.
  // ⚠️ 적용 함수 2개는 '의도적으로' 별도 구현이다 (병합 금지):
  //  - _applyConditionalRules (random 모드): 단일 프롬프트에 적용, 마지막에 toSet() 중복 제거
  //  - _applyConditionalRulesSectioned (generate 모드): 선행/긍정/후행 경계 보존, 중복 제거 없음
  List<({String cond, String action})> _parseConditionalRules() {
    final List<({String cond, String action})> parsed = [];
    final rules = conditionalRuleController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('#'))
        .toList();
    for (final ruleStr in rules) {
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
      parsed.add((cond: ruleStr.substring(1, sepIdx), action: ruleStr.substring(sepIdx + 2)));
    }
    return parsed;
  }

  String _applyConditionalRules(String prompt, String rating) {
    if (conditionalRuleController.text.trim().isEmpty) {
      return prompt;
    }
    List<String> tags = prompt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    for (final rule in _parseConditionalRules()) {
      String condStr = rule.cond;
      String actionStr = rule.action;

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

  // 생성 모드용: 선행+긍정+후행을 합쳐 조건 검사 후, 영역 경계를 보존하며 적용
  // - 조건 판정: 전체 합친 태그 기준
  // - 교체(^, =): 세 영역 모두 제자리
  // - prefix=결과: 긍정 프롬프트 맨 앞에 추가 (선행과 긍정 사이)
  // - suffix=결과: 긍정 프롬프트 맨 끝에 추가 (긍정과 후행 사이)
  ({String prefix, String positive, String suffix}) _applyConditionalRulesSectioned(
    String prefix,
    String positive,
    String suffix,
    String rating,
  ) {
    if (conditionalRuleController.text.trim().isEmpty) {
      return (prefix: prefix, positive: positive, suffix: suffix);
    }

    List<String> prefixTags = prefix
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    List<String> positiveTags = positive
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    List<String> suffixTags = suffix
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    // prefix=로 추가될 태그(긍정 앞)와 suffix=로 추가될 태그(긍정 뒤)
    List<String> positiveFront = [];
    List<String> positiveBack = [];

    for (final rule in _parseConditionalRules()) {
      String condStr = rule.cond;
      String actionStr = rule.action;

      // 1. 조건 판정은 전체 합친 태그(선행+긍정+후행) 기준
      List<String> allTags = [
        ...prefixTags,
        ...positiveFront,
        ...positiveTags,
        ...positiveBack,
        ...suffixTags,
      ];
      bool conditionMet = _evaluateCondition(condStr, allTags, rating);
      if (!conditionMet) {
        continue;
      }

      if (actionStr.startsWith('prefix=')) {
        // 2. 긍정 프롬프트 맨 앞에 추가
        String b = actionStr.substring(7).trim();
        if (!allTags.contains(b) && !positiveFront.contains(b)) {
          positiveFront.add(b);
        }
      } else if (actionStr.startsWith('suffix=')) {
        // 3. 긍정 프롬프트 맨 끝에 추가
        String b = actionStr.substring(7).trim();
        if (!allTags.contains(b) && !positiveBack.contains(b)) {
          positiveBack.add(b);
        }
      } else if (actionStr.contains('^')) {
        int idx = actionStr.indexOf('^');
        String a = actionStr.substring(0, idx).trim();
        String b = actionStr.substring(idx + 1).trim();
        String literalA = a.replaceAll('*', '');
        String literalB = b.replaceAll('*', '');
        for (final list in [prefixTags, positiveTags, suffixTags]) {
          for (int i = 0; i < list.length; i++) {
            if (_isMatch(list[i], a)) {
              list[i] = literalA.isNotEmpty ? list[i].replaceAll(literalA, literalB) : b;
            }
          }
        }
      } else if (actionStr.contains('=')) {
        int eqIdx = actionStr.indexOf('=');
        String a = actionStr.substring(0, eqIdx).trim();
        String b = actionStr.substring(eqIdx + 1).trim();
        for (final list in [prefixTags, positiveTags, suffixTags]) {
          for (int i = 0; i < list.length; i++) {
            if (_isMatch(list[i], a)) {
              list[i] = b;
            }
          }
        }
      }
    }

    // 긍정 = [prefix=추가분] + [원래 긍정] + [suffix=추가분]
    List<String> finalPositive = [...positiveFront, ...positiveTags, ...positiveBack];

    return (
      prefix: prefixTags.join(', '),
      positive: finalPositive.join(', '),
      suffix: suffixTags.join(', '),
    );
  }

  // 가중치 규칙 적용: 사용자가 "태그=숫자"로 정의한 규칙에 따라
  // 프롬프트 안의 해당 태그를 NovelAI 가중치 문법(숫자::태그 ::)으로 감싼다.
  //  예) 규칙 "sleeping=0.5" → 프롬프트의 sleeping 을 "0.5::sleeping ::" 으로 치환
  //  - 한 줄에 규칙 하나, 줄 맨 앞에 # 이 있으면 그 줄은 건너뜀
  //  - 숫자는 음수/소수/1 이상 모두 허용 (NovelAI V4 numeric emphasis)
  // 프롬프트 내용에서 레이팅 글자 추출 (조건부 트리거 조건 판정용)
  String _ratingLetterOf(String source) {
    final lower = source.toLowerCase();
    if (lower.contains("explicit")) {
      return "e";
    }
    if (lower.contains("questionable")) {
      return "q";
    }
    if (lower.contains("sensitive")) {
      return "s";
    }
    return "g";
  }

  // 최종 프롬프트 미리보기 (2번째 UI 상단 표시용)
  // 생성과 같은 순서로 합치되, 와일드카드는 생성 시마다 바뀌므로 원문(__foo__)을 그대로 남긴다.
  String buildPreviewPrompt() {
    String prefixText = prefixController.text;
    String positiveText = positiveController.text;
    String suffixText = suffixController.text;

    // 조건부 트리거가 generate 모드면 영역별로 적용 (random 모드는 이미 반영돼 있음)
    if (conditionalTriggerMode == "generate") {
      final rating = _ratingLetterOf("$prefixText,$positiveText,$suffixText");
      final sectioned = _applyConditionalRulesSectioned(
        prefixText,
        positiveText,
        suffixText,
        rating,
      );
      prefixText = sectioned.prefix;
      positiveText = sectioned.positive;
      suffixText = sectioned.suffix;
    }

    // 표시용 구분: 선행/긍정/후행 사이에 빈 줄을 넣어 영역을 눈으로 구분한다.
    // (실제 전송은 handleGenerate가 따로 조립하므로 여기 줄바꿈은 화면에만 영향)
    const sep = "\n\n";
    final parts = [
      _service.sanitizePrompt(prefixText),
      _service.sanitizePrompt(positiveText),
      _service.sanitizePrompt(suffixText),
    ];
    // 비어 있는 영역은 구분선도 만들지 않아 불필요한 여백/콤마가 남지 않게
    final combined = parts.where((e) => e.trim().isNotEmpty).join(",$sep");
    return _applyWeightRules(combined);
  }

  String _applyWeightRules(String prompt) {
    if (!weightRulesEnabled) {
      return prompt;
    }
    // 규칙 구분자: 콤마 또는 줄바꿈 (앞뒤 공백은 자동으로 다듬음)
    final rawRules = weightRulesController.text.split(RegExp(r'[,\n]'));
    String result = prompt;
    for (final rawLine in rawRules) {
      // '#'이 나오면 그 항목의 끝(콤마/줄바꿈)까지는 주석으로 무시한다.
      //  예) "sleeping=0.5 #메모" → "sleeping=0.5" 만 규칙으로 인식
      final hash = rawLine.indexOf('#');
      final line = (hash >= 0 ? rawLine.substring(0, hash) : rawLine).trim();
      if (line.isEmpty) {
        continue;
      }
      final eq = line.lastIndexOf('=');
      if (eq <= 0 || eq == line.length - 1) {
        continue; // '=' 가 없거나 좌/우가 비면 잘못된 규칙
      }
      final tag = line.substring(0, eq).trim();
      final weightStr = line.substring(eq + 1).trim();
      final weight = double.tryParse(weightStr);
      if (tag.isEmpty || weight == null) {
        continue; // 숫자가 아니면 건너뜀
      }
      // 대상 태그를 정확히(콤마/문자열 경계 기준) 찾아 치환.
      final escaped = RegExp.escape(tag);
      // 이미 가중치가 걸려 있으면(예: "1.1::sleeping ::", "1::tag::", "-1::hat ::")
      // 사용자가 직접 지정한 값이므로 규칙을 적용하지 않고 그대로 둔다.
      final alreadyWeighted = RegExp('-?[0-9.]+\\s*::\\s*$escaped\\s*::', caseSensitive: false);
      if (alreadyWeighted.hasMatch(result)) {
        continue;
      }
      // 콤마 또는 문자열 시작/끝으로 둘러싸인 태그를 매칭 (앞뒤 공백 허용)
      final re = RegExp('(^|,)\\s*$escaped\\s*(?=,|\$)', caseSensitive: false);
      result = result.replaceAllMapped(re, (m) {
        final lead = m.group(1) ?? '';
        // 앞이 콤마면 ", "로 정리해 태그 간 간격을 유지 (문자열 시작이면 공백 없음)
        final prefix = lead == ',' ? ', ' : lead;
        return '$prefix$weight::$tag ::';
      });
    }
    return result;
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
            notificationTitle: "NovelAI 생성 중",
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
    // 설정 저장은 생성과 병렬로 (95개 키 기록을 생성 시작이 기다릴 필요 없음)
    unawaited(saveAllSettings());
    int width = 832;
    int height = 1216;

    if (resolutionMode == "랜덤") {
      final List<String> randomList = kNaiResolutions;
      String rndRes = randomList[Random().nextInt(randomList.length)];
      List<String> resParts = rndRes.replaceAll(" ", "").split("x");
      width = int.parse(resParts[0]);
      height = int.parse(resParts[1]);
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
    const int maxPixels = kNaiPixelHardCap;
    while (width * height > maxPixels) {
      if (width > height) {
        width -= 64;
      } else {
        height -= 64;
      }
    }

    // 처리 순서: 와일드카드 개봉 → 조건부 트리거(generate 모드) → 합치기 → sanitize
    String prefixText = prefixController.text;
    String positiveText = positiveController.text;
    String suffixText = suffixController.text;

    // 0. 순차 생성 <A|B|C>: 세 영역을 합친 기준으로 처리 (영역 간 독립 보장)
    //    구분자(\u0001)로 합쳐 처리 후 다시 분리
    const sep = '\u0001';
    final seqInput = "$prefixText$sep$positiveText$sep$suffixText";
    final seqCombined = _processSequential(seqInput);
    final seqParts = seqCombined.split(sep);
    prefixText = seqParts.isNotEmpty ? seqParts[0] : prefixText;
    positiveText = seqParts.length > 1 ? seqParts[1] : positiveText;
    suffixText = seqParts.length > 2 ? seqParts[2] : suffixText;
    _advanceSequential(seqInput); // 도달한 <>만 카운터 +1 (생성 1회 = 1전진)

    // 1. 와일드카드(랜덤 파이프 + __wildcard__) 개봉
    //    순차 와일드카드(@) 위치 일관성을 위해 세 영역을 합쳐서 개봉 후 분리
    final wcInput = "$prefixText$sep$positiveText$sep$suffixText";
    final wcCombined = _processWildcards(wcInput);
    _advanceSequentialWildcards(wcInput); // 개봉 후 순차 와일드카드 @ 카운터 전진
    final wcParts = wcCombined.split(sep);
    prefixText = wcParts.isNotEmpty ? wcParts[0] : prefixText;
    positiveText = wcParts.length > 1 ? wcParts[1] : positiveText;
    suffixText = wcParts.length > 2 ? wcParts[2] : suffixText;

    // 2. 조건부 트리거가 "generate" 모드면 와일드카드 개봉 후 적용
    if (conditionalTriggerMode == "generate") {
      final rating = _ratingLetterOf("$prefixText,$positiveText,$suffixText");
      final sectioned = _applyConditionalRulesSectioned(
        prefixText,
        positiveText,
        suffixText,
        rating,
      );
      prefixText = sectioned.prefix;
      positiveText = sectioned.positive;
      suffixText = sectioned.suffix;
    }

    // 3. 합치기 (와일드카드는 이미 개봉됨)
    String combined = "$prefixText,$positiveText,$suffixText";

    String finalPrompt = _service.sanitizePrompt(combined);
    finalPrompt = _applyWeightRules(finalPrompt);
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

    // vibe 인코딩 캐시 갱신 감지용 지문 (생성 후 비교)
    final String vibeSigBefore = _vibeCacheSignature();

    final bool bgInitialized = await _enableBackgroundExecution();

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
        // 모델이 미지원이면 VAR+는 전송하지 않는다
        variancePlus: isVariancePlus && modelCapsFor(selectedModel).supportsVarietyPlus,
        useCharacterPosition: useCharacterPosition,
        randomCharacterOrder: randomCharacterOrder,
        // 정밀 참조가 있으면 vibe 대신 정밀 참조 우선 (기존 동작 그대로, 필터는 위에서 1회)
        vibeTransfers: (activeVibes.isNotEmpty && activePrecise.isEmpty) ? activeVibes : null,
        preciseRefs: activePrecise.isNotEmpty ? activePrecise : null,
      );

      isLoading = false;
      currentImageBytes = result.image ?? currentImageBytes;
      lastErrorMessage = result.error;
      // 이미지가 도착한 즉시 화면에 표시.
      // (이게 없으면 아래 fetchAnlas 네트워크 왕복이 끝나야 갱신돼 수백 ms를 그냥 기다림)
      notifyListeners();

      if (result.image != null) {
        sessionGenerateCount++;
        // 인코딩 캐시가 '실제로' 갱신된 경우에만 저장
        // (매 생성마다 vibe base64 전체를 jsonEncode하면 메인 스레드가 수 MB를 인코딩하게 됨)
        if (_vibeCacheSignature() != vibeSigBefore) {
          saveReferencesToLocal();
        }

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
    currentRepeatIndex = 0;
    currentRepeatTotal = 0;
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

    // 연속 생성(2개 이상 또는 무한) + 자동 전환 ON이면, 첫 생성 "전에" 다음 프롬프트로 1번 넘긴다.
    // → 이전 배치의 마지막 프롬프트와 겹치는 것을 방지 (예: 이전이 A B C면 다음은 B C D).
    // 1개 생성일 때는 "지금 보는 프롬프트로 1장" 의도를 존중해 넘기지 않는다.
    if (isBatchMode && autoNextPromptInBatch) {
      handleNextPrompt();
    }

    while (batchRemaining > 0) {
      // 탭을 옮겨 프롬프트 탭이 dispose돼도(context unmounted) 자동생성은 계속되어야 한다.
      // → context.mounted로 중단하지 않는다. 중단 조건은 API 끊김 / 남은 수 소진 / 사용자 정지뿐.
      if (!isApiConnected) {
        break;
      } // API 끊기면 중지

      // 같은 프롬프트 반복 생성 횟수 (자동 전환 ON + 반복 ON일 때만 2회 이상)
      final int repeats = (autoNextPromptInBatch && repeatSamePromptEnabled)
          ? repeatSamePromptCount.clamp(1, 99)
          : 1;
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

        // context가 죽어도 handleGenerate 내부에서 (context.mounted ? context : null)로
        // 안전 처리되므로, 여기서는 의도적으로 mounted 가드 없이 넘긴다.
        // ignore: use_build_context_synchronously
        await handleGenerate(context, onScrollToHistoryEnd);

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

    batchRemaining = 0;
    isBatchMode = false;
    currentRepeatIndex = 0;
    currentRepeatTotal = 0;
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

    bool bgInitialized = false;
    try {
      if (!isSeedLocked || seedController.text.isEmpty) {
        seedController.text = Random().nextInt(4294967296).toString();
      }

      unawaited(saveAllSettings()); // 생성과 병렬 저장

      int width = targetI2iMetadata!.width;
      int height = targetI2iMetadata!.height;

      String combined =
          "${inpaintPrefixController.text},${inpaintPositiveController.text},${inpaintSuffixController.text}";
      String step1 = _processWildcards(combined);

      String finalPrompt = _service.sanitizePrompt(step1);
      finalPrompt = _applyWeightRules(finalPrompt);
      String finalNegative = _service.sanitizePrompt(
        _processWildcards(inpaintNegativeController.text),
      );

      bgInitialized = await _enableBackgroundExecution();

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
        // 모델이 미지원이면 VAR+는 전송하지 않는다
        variancePlus: isVariancePlus && modelCapsFor(selectedModel).supportsVarietyPlus,
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

        // ⚠️ 순서 중요: 마스크 처리 방식/이미지 전환을 먼저 정한 뒤 addI2iResult를 호출한다.
        // addI2iResult가 notifyListeners()를 부르므로, 그 전에 상태가 정해져 있어야
        // i2i_tab build가 올바르게 판단한다.
        if (!inpaintNoAutoSwitch) {
          // 결과를 작업 이미지로 자동 전환 → 이미지 변경 시 자동 해제 설정을 따라 마스크 처리
          i2iMaskActionOnChange = I2iMaskAction.followInpaintSetting;
          targetI2iImage = result.image!;
          targetI2iMetadata = parsedMeta;
          recordI2iView(result.image!, parsedMeta); // 본 이미지 기록 추가
        } else if (inpaintAutoClearMask) {
          // 자동 전환은 안 하지만 자동 해제는 ON → 이미지는 그대로 두고 마스크만 즉시 해제
          i2iMaskClearRevision++;
        }
        // (자동 전환 OFF + 자동 해제 OFF → 아무것도 안 함, 마스크 유지)

        // 인페인트 결과는 메인 히스토리 대신 i2i 스크래치 릴로 (여기서 notifyListeners 발생)
        addI2iResult(result.image!, parsedMeta, source: 'inpaint');
      }

      await fetchAnlas();
    } catch (e) {
      debugPrint('인페인트 파이프라인 에러: $e'); //
    } finally {
      // 백그라운드 실행 해제 (켰으면 반드시 끔 — 알림이 남지 않도록)
      if (bgInitialized) {
        try {
          await FlutterBackground.disableBackgroundExecution();
        } catch (_) {}
      }
      // 성공/실패 여부와 관계없이 반드시 락 해제
      _isInpaintProcessing = false;
      isInpaintLoading = false;
      inpaintStatusMessage = "";
      notifyListeners();
    }
  }

  Future<void> handleImg2ImgGenerate(BuildContext context) async {
    // 인페인트와 뮤텍스/로딩 상태를 공유 (i2i 탭에서 동시에 실행될 수 없음)
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

    _isInpaintProcessing = true;
    isInpaintLoading = true;
    inpaintStatusMessage = "연결 중...";
    lastErrorMessage = null;
    notifyListeners();

    bool bgInitialized = false;
    try {
      if (!isSeedLocked || seedController.text.isEmpty) {
        seedController.text = Random().nextInt(4294967296).toString();
      }

      unawaited(saveAllSettings()); // 생성과 병렬 저장

      int width = targetI2iMetadata!.width;
      int height = targetI2iMetadata!.height;

      // i2i 탭의 프롬프트 입력란을 그대로 사용 (인페인트와 공유)
      String combined =
          "${inpaintPrefixController.text},${inpaintPositiveController.text},${inpaintSuffixController.text}";
      String finalPrompt = _service.sanitizePrompt(_processWildcards(combined));
      finalPrompt = _applyWeightRules(finalPrompt);
      String finalNegative = _service.sanitizePrompt(
        _processWildcards(inpaintNegativeController.text),
      );

      bgInitialized = await _enableBackgroundExecution();

      // 실행 시점의 활성 캐릭터를 그대로 전송 (프롬프트 탭 생성과 동일 처리)
      List<Map<String, dynamic>> processedCharacters = characters
          .where((char) => char.isActive)
          .map((char) {
            Map<String, dynamic> charJson = char.toJson();
            if (charJson.containsKey('positive')) {
              charJson['positive'] = _processWildcards(charJson['positive'].toString());
            }
            if (charJson.containsKey('negative')) {
              charJson['negative'] = _processWildcards(charJson['negative'].toString());
            }
            return charJson;
          })
          .toList();

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
        image: targetI2iImage,
        action: "img2img",
        img2imgStrength: img2imgStrength,
        img2imgNoise: img2imgNoise,
        // 모델이 미지원이면 VAR+는 전송하지 않는다
        variancePlus: isVariancePlus && modelCapsFor(selectedModel).supportsVarietyPlus,
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
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.redAccent),
                  SizedBox(width: 8),
                  Text(
                    "img2img 생성 오류",
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

        // 인페인트와 동일: 자동 전환 설정을 따르고, 결과는 릴에 추가
        if (!inpaintNoAutoSwitch) {
          i2iMaskActionOnChange = I2iMaskAction.followInpaintSetting;
          targetI2iImage = result.image!;
          targetI2iMetadata = parsedMeta;
          recordI2iView(result.image!, parsedMeta);
        } else if (inpaintAutoClearMask) {
          i2iMaskClearRevision++;
        }

        addI2iResult(result.image!, parsedMeta, source: 'img2img');
      }

      await fetchAnlas();
    } catch (e) {
      debugPrint('img2img 파이프라인 에러: $e');
    } finally {
      if (bgInitialized) {
        try {
          await FlutterBackground.disableBackgroundExecution();
        } catch (e) {
          debugPrint("백그라운드 해제 오류: $e");
        }
      }
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
    if ((width * height) > kMegapixelCap) {
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

        // 업스케일 결과도 i2i 스크래치 릴로
        addI2iResult(result.image!, parsedMeta, source: 'upscale');
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
        if (!context.mounted) {
          return;
        }
        await addBytesToHistory(bytes, context); // 불러온 이미지는 저장 경로 없음(null)
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

  // 바이트를 히스토리에 추가하는 핵심 로직 (이미지 불러오기 / 갤러리 추가 공용)
  // 바이트를 히스토리에 추가 (이미지 불러오기 / 갤러리 추가 공용)
  // 핵심 적재는 addImageToHistory를 재사용하고, 메타 파싱·알림·메시지만 담당
  Future<void> addBytesToHistory(
    Uint8List bytes,
    BuildContext context, {
    String? filePath,
    bool showSuccess = true,
  }) async {
    final NaiMetadata? parsedMeta = extractNovelAIMetadata(bytes);
    await addImageToHistory(
      image: bytes,
      metadata: parsedMeta,
      context: context,
      presetFilePath: filePath, // 전달된 실제 경로 사용 (없으면 null)
      skipAutoSave: true, // 불러온/기존 파일은 자동저장 안 함
    );
    notifyListeners();

    if (!showSuccess || !context.mounted) {
      return;
    }
  }

  // 여러 파일을 한 번에 히스토리에 추가 (갤러리 다중 선택용)
  Future<int> addFilesToHistory(List<File> files, BuildContext context) async {
    int added = 0;
    for (final f in files) {
      try {
        final bytes = await f.readAsBytes();
        if (!context.mounted) {
          return added;
        }
        await addBytesToHistory(bytes, context, filePath: f.path, showSuccess: false);
        added++;
      } catch (e) {
        debugPrint("히스토리 일괄 추가 실패 (${f.path}): $e");
      }
    }
    if (context.mounted && added > 0) {}
    return added;
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
    String? presetFilePath, // 이미 디스크에 있는 파일(갤러리 등): 이 경로 사용
    bool skipAutoSave = false, // 불러오기/갤러리 추가: 자동저장 안 함
  }) async {
    if (historyImages.length >= kHistoryCap) {
      _removeOldestNonFavorite();
    }
    historyImages.add(image);
    historyFavorites.add(false);
    historyMetadata.add(metadata);

    String? savedPath;
    if (presetFilePath != null) {
      savedPath = presetFilePath;
    } else if (!skipAutoSave && (forceSave || isAutoSave)) {
      savedPath = await autoSaveImage((context != null && context.mounted) ? context : null, image);
    }
    historyFilePaths.add(savedPath);

    selectedHistoryIndex = historyImages.length - 1;
    scrollToThumbnailEnd = true;
    saveHistoryToLocal();
    await _trimHistoryMemory();

    return savedPath;
  }

  // ===== i2i 스크래치 릴 =====
  // 결과를 릴에 추가 (디스크 저장 안 함 — 스크래치)
  // i2iHistoryDisabled가 켜져 있으면 릴 대신 메인 히스토리에 저장 (기존 동작)
  void addI2iResult(Uint8List bytes, NaiMetadata? metadata, {String source = 'inpaint'}) {
    if (i2iHistoryDisabled) {
      addImageToHistory(image: bytes, metadata: metadata, forceSave: true);
      return;
    }
    i2iResults.add(I2iResult(bytes: bytes, metadata: metadata, source: source));
    _trimI2iResults();
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

  // 즐겨찾기 토글 (영속 저장)
  // 반환: true=토글됨, false=즐겨찾기 한도(i2iFavoriteCap) 초과로 막힘
  bool toggleI2iFavorite(int index) {
    if (index < 0 || index >= i2iResults.length) {
      return true;
    }
    final r = i2iResults[index];
    if (!r.favorite) {
      final favCount = i2iResults.where((x) => x.favorite).length;
      if (favCount >= i2iFavoriteCap) {
        return false; // 한도 초과 — 호출 측에서 안내
      }
    }
    r.favorite = !r.favorite;
    saveI2iFavorites();
    notifyListeners();
    return true;
  }

  // 릴에서 결과 삭제 (내역에서 제거)
  void removeI2iResult(int index) {
    if (index < 0 || index >= i2iResults.length) {
      return;
    }
    final bool wasFav = i2iResults[index].favorite;
    i2iResults.removeAt(index);
    if (wasFav) {
      saveI2iFavorites();
    }
    notifyListeners();
  }

  // ── i2i 마스크 처리 방식 (1회용 소비 신호 대신 "상태 기반"으로 관리) ──
  // targetI2iImage를 바꾸는 쪽이 "왜 바꾸는지"를 함께 세팅하고,
  // i2i_tab은 이미지 변경을 감지하면 이 값을 읽어 마스크를 어떻게 할지 결정한다.
  // enum은 소비하지 않으므로(다음 변경 시 덮어써짐) build 타이밍에 안전하다.
  I2iMaskAction i2iMaskActionOnChange = I2iMaskAction.clearMask;

  // 인페인트 마스크 획 목록. 위젯(i2i_tab)이 아니라 여기 보관하여 탭 재생성에도 유지.
  final List<MaskStroke> i2iMaskStrokes = [];

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

  // 릴의 결과를 작업 이미지로 채택 (이어서 인페인트 등)
  void useI2iResult(int index) {
    if (index < 0 || index >= i2iResults.length) {
      return;
    }
    i2iMaskActionOnChange = I2iMaskAction.keepMask; // 릴 탭은 마스킹 유지
    targetI2iImage = i2iResults[index].bytes;
    targetI2iMetadata = i2iResults[index].metadata;
    recordI2iView(i2iResults[index].bytes, i2iResults[index].metadata); // 본 이미지 기록 추가
    notifyListeners();
  }

  // 메인 히스토리로 보내기 (디스크 저장 포함)
  Future<void> promoteI2iToHistory(int index, BuildContext context) async {
    if (index < 0 || index >= i2iResults.length) {
      return;
    }
    final r = i2iResults[index];
    await addImageToHistory(
      image: r.bytes,
      metadata: r.metadata,
      context: context.mounted ? context : null,
      forceSave: true,
    );
    if (context.mounted) {}
  }

  // 폴더에 저장 (DNaiApp 갤러리 폴더로)
  Future<void> saveI2iToFolder(int index, BuildContext context) async {
    if (index < 0 || index >= i2iResults.length) {
      return;
    }
    final r = i2iResults[index];
    final path = await autoSaveImage(context.mounted ? context : null, r.bytes);
    if (!context.mounted) {
      return;
    }
    if (path != null) {
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("저장에 실패했습니다.")));
    }
  }

  Future<void> saveI2iFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final favs = i2iResults.where((r) => r.favorite).map((r) => r.toJson()).toList();
      await prefs.setString('i2iFavorites', jsonEncode(favs));
    } catch (e) {
      debugPrint("i2i 즐겨찾기 저장 실패: $e");
    }
  }

  Future<void> loadI2iFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      i2iHandleBottom = prefs.getDouble('i2iHandleBottom') ?? -1;
      promptCharHandleTop = prefs.getDouble('promptCharHandleTop') ?? -1;
      final s = prefs.getString('i2iFavorites');
      if (s == null || s.isEmpty) {
        return;
      }
      final list = jsonDecode(s) as List;
      i2iResults = list.map((e) => I2iResult.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (e) {
      debugPrint("i2i 즐겨찾기 로드 실패: $e");
    }
  }

  Future<void> savePromptCharHandleTop(double value) async {
    promptCharHandleTop = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('promptCharHandleTop', value);
    } catch (_) {}
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
    // v5 메타데이터가 v4로 오인되지 않도록 v5를 먼저 검사한다.
    if (lower.contains('v5')) {
      return NaiModels.v5Test;
    }
    if (lower.contains('v4.5')) {
      return NaiModels.v45Full;
    }
    if (lower.contains('v4')) {
      return NaiModels.v4Full;
    }
    if (lower.contains('v3')) {
      return NaiModels.v3;
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

  // PNG 바이트를 WebP(무손실)로 변환하고 원본 메타데이터를 EXIF로 이식한다.
  // 실패하면 null을 반환해 호출부가 원본(PNG)으로 폴백하도록 한다.
  Future<Uint8List?> _convertToWebpWithMetadata(Uint8List pngBytes) async {
    try {
      // 1) 원본 PNG의 파라미터 JSON을 먼저 확보 (변환하면 사라지므로)
      String? metaJson;
      final chunkJson = _extractPngCommentJson(pngBytes);
      if (chunkJson != null && chunkJson.trim().startsWith('{')) {
        metaJson = chunkJson;
      }

      // 2) WebP 인코딩 (안드로이드 시스템 API — 빠름)
      //    quality 100 = 무손실, 95 = 손실이지만 화질 차이가 거의 없고 용량이 크게 준다
      final encoded = await FlutterImageCompress.compressWithList(
        pngBytes,
        format: CompressFormat.webp,
        quality: webpLossy ? 95 : 100,
      );
      if (encoded.isEmpty) {
        return null;
      }
      final webp = Uint8List.fromList(encoded);

      // 3) 메타데이터가 있으면 EXIF 청크로 이식
      if (metaJson == null) {
        return webp;
      }
      return _injectExifIntoWebp(webp, _buildExifBlock(metaJson)) ?? webp;
    } catch (e) {
      debugPrint('WebP 변환 실패(원본 유지): $e');
      return null;
    }
  }

  Future<String?> autoSaveImage(BuildContext? context, Uint8List bytes) async {
    sessionSaveCount++;
    final sessionFolder = _resolveSessionFolder();

    String fileName = _getFormattedFileName("");
    final bool isJpeg = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    String ext = isJpeg ? 'jpg' : 'png';

    // 설정이 켜져 있고 PNG일 때만 WebP로 변환 (실패하면 원본 그대로)
    if (saveAsWebp && !isJpeg) {
      final converted = await _convertToWebpWithMetadata(bytes);
      if (converted != null) {
        bytes = converted;
        ext = 'webp';
      }
    }

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
    final bool isJpeg = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    String ext = isJpeg ? 'jpg' : 'png';
    final messenger = ScaffoldMessenger.of(context); // async gap 전에 캡처

    // 자동 저장과 동일하게 WebP 설정을 반영 (실패 시 원본 유지)
    if (saveAsWebp && !isJpeg) {
      final converted = await _convertToWebpWithMetadata(bytes);
      if (converted != null) {
        bytes = converted;
        ext = 'webp';
      }
    }

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
    const int maxPixels = kNaiPixelHardCap;
    while (width * height > maxPixels) {
      if (width > height) {
        width -= 64;
      } else {
        height -= 64;
      }
    }

    int steps = int.tryParse(stepsController.text) ?? 28;
    bool isOpus = subscriptionTier >= 3;

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
      bool hasUnencodedVibe = activeVibes.any((v) => v['_encoded'] == null);
      bool tooManyVibes = activeVibes.length > 4;
      if (hasUnencodedVibe || tooManyVibes) {
        return true;
      }
      // 전부 인코딩됨 + 4개 이하 → 해상도/스텝 기준으로만 판단 (아래로 진행)
    }

    if (isOpus && (width * height) <= kMegapixelCap && steps <= 28) {
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
