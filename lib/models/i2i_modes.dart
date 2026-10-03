// lib/models/i2i_modes.dart
//
// i2i 탭의 모드 — 이름·아이콘·색·성질을 한 곳에서.
//
// 왜 한 곳인가:
//  예전엔 모드마다 이름·아이콘·색이 다섯 곳(i2i 모드 칩·실행 버튼 색·실행 버튼 아이콘·
//  결과 릴 색·설정 탭 토글)에 따로 적혀 있었고, 모드 이름('inpaint' 등)이 글자로
//  60번 넘게 쓰였다. 'img2imag' 같은 오타 하나면 오류 없이 조용히 안 맞는 구조였다.
import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'model_caps.dart';

enum I2iMode {
  inpaint('inpaint', '인페인트', Icons.format_paint),
  mosaic('mosaic', '모자이크', Icons.grid_on),
  img2img('img2img', 'img2img', Icons.auto_fix_high),
  upscale('upscale', '업스케일', Icons.high_quality);

  const I2iMode(this.id, this.label, this.icon);

  /// 저장·결과 표시에 쓰는 이름. ⚠️ 설정과 결과 기록에 남으므로 바꾸면 안 된다.
  final String id;

  /// 화면에 보이는 이름
  final String label;

  final IconData icon;

  /// img2img 모드 색 (앱의 다른 의미색과 겹치지 않는 파랑)
  static const Color _img2imgBlue = Color(0xFF3B82F6);

  /// 모드 색. 모자이크는 사용자가 바꿀 수 있는 액센트라 const 로 둘 수 없다.
  Color get color => switch (this) {
    I2iMode.inpaint => AppColors.teal,
    I2iMode.mosaic => AppColors.accent,
    I2iMode.img2img => _img2imgBlue,
    I2iMode.upscale => AppColors.orange,
  };

  /// 마스크를 그리는 모드인지 (연필·지우개를 쓰는 모드).
  ///  img2img·업스케일은 그림 전체를 쓰므로 그리지 않는다.
  bool get usesMask => this == I2iMode.inpaint || this == I2iMode.mosaic;

  /// 지금 모델이 이 모드를 지원하는지
  bool supportedBy(ModelCaps caps) => switch (this) {
    // 모자이크는 인페인트 파이프라인을 그대로 쓴다
    I2iMode.inpaint || I2iMode.mosaic => caps.supportsInpaint,
    I2iMode.img2img => caps.supportsImg2img,
    I2iMode.upscale => caps.supportsUpscale,
  };

  /// 저장된 이름 → 모드. 모르는 이름이면 null (결과 릴의 'origin' 같은 것).
  static I2iMode? fromId(String id) {
    for (final m in I2iMode.values) {
      if (m.id == id) {
        return m;
      }
    }
    return null;
  }
}
