// lib/models/preset_models.dart
//
// 프리셋·와일드카드·i2i 결과 모델.
//  app_state.dart가 커져서 데이터 모델만 따로 뺐다.
//  ⚠️ AppState를 참조하지 않는다 (순환 import 방지).
import 'dart:convert'; // base64Encode/Decode
import 'dart:typed_data';

import 'image_metadata.dart' show NaiMetadata;

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
