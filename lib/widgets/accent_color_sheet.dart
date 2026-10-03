// lib/widgets/accent_color_sheet.dart
//
// 액센트 색 직접 고르기 (설정 > 테마 > 액센트 색의 무지개 칸)
//  · 색상·채도·밝기 슬라이더 + HEX 입력 — 고르는 동안은 이 창 안에서만 미리 보고,
//    '적용' 을 눌러야 앱 전체에 반영·저장한다.
//    (슬라이더를 움직일 때마다 바꾸면 앱 전체를 다시 그리고 설정을 저장하는 일이 수십 번 일어난다)
//  · 저장은 기존 '액센트 색' 값(themeAccent) 그대로 — 새 설정이 아니다.
//  · 읽기 어려운 색(너무 어둡거나 너무 밝음)은 막지 않고 알려만 준다.
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/app_state.dart';
import 'color_sliders.dart';

Future<void> showAccentColorSheet(BuildContext context, AppState state) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true, // HEX 입력 때 키보드가 올라와도 가려지지 않게
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _AccentColorSheet(state: state),
  );
}

class _AccentColorSheet extends StatefulWidget {
  const _AccentColorSheet({required this.state});

  final AppState state;

  @override
  State<_AccentColorSheet> createState() => _AccentColorSheetState();
}

class _AccentColorSheetState extends State<_AccentColorSheet> {
  // 색상(hue)을 따로 들고 있어야 채도나 밝기를 0 으로 내렸다 올려도 색상이 0(빨강)으로 튀지 않는다
  late HSVColor _hsv;
  // 이 창이 만들고 이 창이 닫힐 때 치운다 (창 바깥에서 dispose 하는 게 아니라 안전하다)
  late final TextEditingController _hex;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(Color(widget.state.themeAccent));
    _hex = TextEditingController(text: _hexOf(_hsv.toColor()));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  static String _hexOf(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return v.toRadixString(16).padLeft(6, '0').toUpperCase();
  }

  /// '#7C4DFF', '7c4dff', '#7C4' 같은 입력 → 색. 아니면 null
  static Color? _parseHex(String raw) {
    var t = raw.trim().replaceFirst('#', '');
    if (t.length == 3) {
      t = t.split('').map((ch) => '$ch$ch').join(); // 짧은 형식 #RGB → #RRGGBB
    }
    if (t.length != 6) {
      return null;
    }
    final v = int.tryParse(t, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  // 슬라이더로 바꿨을 때 — HEX 칸도 따라 바꾼다
  void _setHsv(HSVColor next) {
    setState(() {
      _hsv = next;
      _hex.text = _hexOf(next.toColor());
    });
  }

  // HEX 칸에 맞는 색을 다 적었을 때 — 칸은 그대로 둔다 (적는 중인 글자를 덮지 않게)
  void _onHexChanged(String raw) {
    final c = _parseHex(raw);
    if (c != null) {
      setState(() => _hsv = HSVColor.fromColor(c));
    }
  }

  /// 읽기 어려운 색이면 그 이유 (괜찮으면 null).
  ///  기준은 넉넉하게 — 원래 목록의 색(라임·호박 등)은 걸리지 않고, 정말 극단적인 색만 알린다.
  String? get _warning {
    final lum = _color.computeLuminance();
    if (lum < 0.05) {
      return "어두워서 배경과 잘 구분되지 않을 수 있어요";
    }
    if (lum > 0.7) {
      return "밝아서 이 색 버튼 위의 흰 글자가 잘 안 보일 수 있어요";
    }
    return null;
  }

  void _apply() {
    widget.state.setThemeAccent(_color.withValues(alpha: 1.0).toARGB32());
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    final warning = _warning;
    return SafeArea(
      child: Padding(
        // 키보드가 올라오면 그만큼 위로
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    "액센트 색 직접 고르기",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const Spacer(),
                  // 기본 보라로 (적용은 아래 버튼으로)
                  TextButton(
                    onPressed: () => _setHsv(HSVColor.fromColor(AppColors.defaultAccent)),
                    child: const Text(
                      "기본값",
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _preview(color),
              const SizedBox(height: 16),
              HueSlider(hue: _hsv.hue, onChanged: (h) => _setHsv(_hsv.withHue(h))),
              const SizedBox(height: 8),
              HsvGradientSlider(
                label: "채도",
                value: _hsv.saturation,
                colors: [
                  HSVColor.fromAHSV(1, _hsv.hue, 0, _hsv.value).toColor(),
                  HSVColor.fromAHSV(1, _hsv.hue, 1, _hsv.value).toColor(),
                ],
                onChanged: (v) => _setHsv(_hsv.withSaturation(v)),
              ),
              const SizedBox(height: 8),
              HsvGradientSlider(
                label: "밝기",
                value: _hsv.value,
                colors: [
                  Colors.black,
                  HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor(),
                ],
                onChanged: (v) => _setHsv(_hsv.withValue(v)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 34,
                    child: Text("HEX", style: TextStyle(color: Colors.white54, fontSize: 11)),
                  ),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _hex,
                      onChanged: _onHexChanged,
                      maxLength: 7, // '#' 포함
                      style: const TextStyle(color: Colors.white, fontSize: 14, letterSpacing: 1),
                      decoration: InputDecoration(
                        isDense: true,
                        counterText: "",
                        prefixText: "# ",
                        prefixStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                        hintText: "7C4DFF",
                        hintStyle: const TextStyle(color: Colors.white24),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: color),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (warning != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.info_outline, color: AppColors.amber, size: 14),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        warning,
                        style: const TextStyle(color: AppColors.amber, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text("취소", style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _apply,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: color,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text(
                        "적용",
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 앱에서 실제로 쓰이는 모양 몇 가지로 미리 보기 (버튼 · 강조 글자 · 선택된 칩)
  Widget _preview(Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
            child: const Text(
              "버튼",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.auto_awesome, color: color, size: 18),
          const SizedBox(width: 4),
          Text("강조", style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(width: 12),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color.withValues(alpha: 0.8), width: 1.5),
              ),
              child: Text(
                "선택됨",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
