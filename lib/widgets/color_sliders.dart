// lib/widgets/color_sliders.dart
//
// 색 고르기 슬라이더 — 막대 자체가 그라데이션이고 하얀 손잡이만 보인다.
//  캐릭터 색(캐릭터탭)과 액센트 색(설정 > 테마)이 같이 쓴다.
//  (예전엔 캐릭터탭 안에 _hueSlider / _hsvSlider 로만 있었다 — 액센트 색을 더하며 여기로 옮겼다)
import 'package:flutter/material.dart';

/// 색상(Hue) 0~360 — 무지개 막대
class HueSlider extends StatelessWidget {
  const HueSlider({super.key, required this.hue, required this.onChanged, this.onChangeEnd});

  final double hue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// 무지개 (빨강→빨강) — 설정의 '직접 고르기' 칸 테두리도 이걸 쓴다
  static const List<Color> rainbow = [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  Widget build(BuildContext context) {
    return _GradientSliderRow(
      label: "색상",
      colors: rainbow,
      value: hue,
      max: 360,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
  }
}

/// 채도·밝기처럼 0~1 값 — [colors] 는 막대 왼쪽→오른쪽 그라데이션
class HsvGradientSlider extends StatelessWidget {
  const HsvGradientSlider({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return _GradientSliderRow(
      label: label,
      colors: colors,
      value: value,
      max: 1,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
  }
}

class _GradientSliderRow extends StatelessWidget {
  const _GradientSliderRow({
    required this.label,
    required this.colors,
    required this.value,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
  });

  final String label;
  final List<Color> colors;
  final double value;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        ),
        Expanded(
          child: Container(
            height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: LinearGradient(colors: colors),
            ),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 0,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                thumbColor: Colors.white,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              ),
              child: Slider(
                value: value.clamp(0, max).toDouble(),
                min: 0,
                max: max,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
