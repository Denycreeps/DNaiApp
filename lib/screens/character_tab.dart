import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/nai_character.dart';
import 'prompt_edit_dialog.dart';
import '../models/model_caps.dart';
import '../widgets/character_canvas.dart';
import '../app_theme.dart';

class CharacterTab extends StatefulWidget {
  const CharacterTab({super.key});

  @override
  State<CharacterTab> createState() => _CharacterTabState();
}

class _CharacterTabState extends State<CharacterTab> with AutomaticKeepAliveClientMixin {
  // 탭 전환 시 상태를 유지해 재방문이 즉시 이뤄지게 한다
  @override
  bool get wantKeepAlive => true;

  bool _isGridActive = false; // 그리드에서 캐릭터 선택됨 (이동 대기)

  // 프롬프트 입력 다이얼로그 — 공용 구현(prompt_edit_dialog.dart)을 사용한다.
  //  캐릭터 탭은 값+콜백 방식으로 호출하므로, 임시 컨트롤러를 만들어 연결한다.
  void _showPromptEditDialog(
    BuildContext context,
    AppState state,
    String title,
    IconData icon,
    Color color,
    String currentText,
    ValueChanged<String> onSaved,
  ) {
    final tc = TextEditingController(text: currentText);
    // 입력 내용을 실시간으로 콜백에 전달 (공용 다이얼로그는 컨트롤러 기반)
    tc.addListener(() => onSaved(tc.text));
    // 이 컨트롤러는 여기서 만들었으므로 다이얼로그가 닫힐 때 직접 정리한다
    // (공용 다이얼로그는 외부에서 받은 컨트롤러를 dispose 하지 않는다)
    showPromptEditDialog(context, state, title, icon, color, tc, onClosed: tc.dispose);
  }

  // 캐릭터 칩 줄 — 가로 스크롤.
  //  · 세로 목록보다 터치 영역이 크고, 편집 영역이 화면 전폭을 쓴다.
  //  · 칩 색은 캔버스 마커와 같은 팔레트라 서로 대응된다.
  //  · 한 화면에 8개 정도 보이도록 40x34 크기로 잡았다.
  //  · 2개째부터 위아래로 번갈아 채워 가로 스크롤을 절반으로 줄인다.
  Widget _buildCharacterChipBar(AppState state) {
    const double chipW = 40;
    const double chipH = 34;
    const double gap = 6;

    final maxChars = modelCapsFor(state.selectedModel).maxCharacters;
    final canAdd = state.characters.length < maxChars;

    // 화면에 놓을 항목들 (캐릭터 + 추가 버튼)
    final items = <Widget>[
      for (int i = 0; i < state.characters.length; i++) _charChip(state, i, chipW, chipH),
      if (canAdd) _addChip(state, chipW, chipH),
    ];

    // 세로 우선으로 채운다.
    //  [1][3][5]
    //  [2][4][+]
    //  → 위아래를 번갈아 쓰므로 가로 스크롤이 절반으로 줄고,
    //    '+'는 항상 다음 번호가 들어갈 자리에 놓여 직관적이다.
    final top = <Widget>[];
    final bottom = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      (i.isEven ? top : bottom).add(items[i]);
    }

    Widget rowOf(List<Widget> children) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final w in children) ...[w, const SizedBox(width: gap)],
        ],
      );
    }

    return SizedBox(
      // 아랫줄이 비어도 높이를 유지해 화면이 덜컹이지 않게 한다
      height: chipH * 2 + gap + 16,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            rowOf(top),
            if (bottom.isNotEmpty) ...[const SizedBox(height: gap), rowOf(bottom)],
          ],
        ),
      ),
    );
  }

  // 격자 칸 수 설정 (가로/세로 따로). 격자 버튼을 꾹 누르면 열린다.
  //  공식처럼 "칸 수"를 정한다 — 2면 가운데 1줄이 생긴다.
  void _showGridSettings(AppState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "격자 칸 수",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 16),
                _gridStepper(
                  label: "가로",
                  value: state.charGridCols,
                  onChanged: (v) {
                    setSheet(() => state.charGridCols = v);
                    state.saveAllSettings();
                    state.refreshUI();
                  },
                ),
                const SizedBox(height: 10),
                _gridStepper(
                  label: "세로",
                  value: state.charGridRows,
                  onChanged: (v) {
                    setSheet(() => state.charGridRows = v);
                    state.saveAllSettings();
                    state.refreshUI();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // [－ 5 ＋] 형태의 숫자 조절기 (2~12칸)
  Widget _gridStepper({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    const int minV = 2;
    const int maxV = 12;
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _stepperButton(Icons.remove, value > minV, () => onChanged(value - 1)),
                Text(
                  "$value",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                _stepperButton(Icons.add, value < maxV, () => onChanged(value + 1)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _stepperButton(IconData icon, bool enabled, VoidCallback onTap) {
    return IconButton(
      icon: Icon(icon, size: 18, color: enabled ? Colors.white : Colors.white24),
      onPressed: enabled ? onTap : null,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    );
  }

  // 캐릭터 색 고르기 — 칩을 꾹 누르면 열린다.
  void _showColorPicker(AppState state, int index) {
    if (index < 0 || index >= state.characters.length) {
      return;
    }
    // 기본 팔레트 + 자주 쓰는 색
    const swatches = [
      AppColors.purple,
      AppColors.teal,
      Color(0xFFFF7043),
      Color(0xFF42A5F5),
      Color(0xFFEC407A),
      Color(0xFF9CCC65),
      Color(0xFFFFCA28),
      Color(0xFF26C6DA),
      Color(0xFFEF5350),
      Color(0xFFAB47BC),
      Color(0xFF5C6BC0),
      Color(0xFF66BB6A),
      Color(0xFFFFA726),
      Color(0xFF78909C),
      Color(0xFFD4E157),
      Color(0xFFFFFFFF),
    ];
    // 슬라이더로 미세 조정할 때 쓰는 현재 색
    Color current = state.characters[index].colorArgb != null
        ? Color(state.characters[index].colorArgb!)
        : _charColor(index);
    HSVColor hsv = HSVColor.fromColor(current);

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void apply(Color c) {
            setSheet(() {
              hsv = HSVColor.fromColor(c);
              current = c;
            });
            // 반투명 값이 섞이지 않게 알파는 항상 불투명으로 저장한다
            state.characters[index].colorArgb = c.withValues(alpha: 1.0).toARGB32();
            state.saveAllSettings();
            state.refreshUI();
            setState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
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
                          color: hsv.toColor(),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white24),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        "캐릭터 ${index + 1} 색",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const Spacer(),
                      // 기본값으로 되돌리기
                      TextButton(
                        onPressed: () {
                          state.characters[index].colorArgb = null;
                          state.saveAllSettings();
                          state.refreshUI();
                          setState(() {});
                          Navigator.pop(ctx);
                        },
                        child: const Text(
                          "기본값",
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 미리 준비한 색
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in swatches)
                        GestureDetector(
                          onTap: () => apply(c),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: c.toARGB32() == hsv.toColor().toARGB32()
                                    ? Colors.white
                                    : Colors.white24,
                                width: c.toARGB32() == hsv.toColor().toARGB32() ? 2.5 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text("직접 고르기", style: TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 8),
                  // 색상(Hue)
                  _hueSlider(hsv, (h) => apply(hsv.withHue(h).toColor())),
                  const SizedBox(height: 8),
                  // 채도
                  _hsvSlider(
                    label: "채도",
                    value: hsv.saturation,
                    gradient: [
                      HSVColor.fromAHSV(1, hsv.hue, 0, hsv.value).toColor(),
                      HSVColor.fromAHSV(1, hsv.hue, 1, hsv.value).toColor(),
                    ],
                    onChanged: (v) => apply(hsv.withSaturation(v).toColor()),
                  ),
                  const SizedBox(height: 8),
                  // 밝기
                  _hsvSlider(
                    label: "밝기",
                    value: hsv.value,
                    gradient: [
                      Colors.black,
                      HSVColor.fromAHSV(1, hsv.hue, hsv.saturation, 1).toColor(),
                    ],
                    onChanged: (v) => apply(hsv.withValue(v).toColor()),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _hueSlider(HSVColor hsv, ValueChanged<double> onChanged) {
    return Row(
      children: [
        const SizedBox(
          width: 34,
          child: Text("색상", style: TextStyle(color: Colors.white54, fontSize: 11)),
        ),
        Expanded(
          child: Container(
            height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFFF0000),
                  Color(0xFFFFFF00),
                  Color(0xFF00FF00),
                  Color(0xFF00FFFF),
                  Color(0xFF0000FF),
                  Color(0xFFFF00FF),
                  Color(0xFFFF0000),
                ],
              ),
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
              child: Slider(value: hsv.hue, min: 0, max: 360, onChanged: onChanged),
            ),
          ),
        ),
      ],
    );
  }

  Widget _hsvSlider({
    required String label,
    required double value,
    required List<Color> gradient,
    required ValueChanged<double> onChanged,
  }) {
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
              gradient: LinearGradient(colors: gradient),
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
              child: Slider(value: value, onChanged: onChanged),
            ),
          ),
        ),
      ],
    );
  }

  // 캐릭터 칩 하나
  Widget _charChip(AppState state, int index, double w, double h) {
    final isSelected = state.selectedCharIndex == index;
    final isActive = state.characters[index].isActive;
    // 이 모델이 받는 개수를 넘었는지 (넘으면 전송되지 않는다)
    final overLimit = index >= modelCapsFor(state.selectedModel).maxCharacters;
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected && state.charRetapToggle) {
            // 이미 선택된 상태에서 한 번 더 누르면 ON/OFF
            state.characters[index].isActive = !isActive;
          } else {
            state.selectedCharIndex = index;
          }
          _isGridActive = false;
        });
        state.saveAllSettings();
        state.refreshUI();
      },
      // 꾹 누르면 색을 고른다
      onLongPress: () => _showColorPicker(state, index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: isActive
              ? _charColor(index).withValues(alpha: isSelected ? 1.0 : 0.45)
              : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            // 모델 상한을 넘은 칸은 주황 테두리로 알린다
            //  (V5에서 만든 캐릭터를 V4.5로 바꾸면 뒤쪽은 전송되지 않는다)
            color: isSelected
                ? Colors.white
                : (overLimit ? Colors.orangeAccent.withValues(alpha: 0.7) : Colors.transparent),
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        // 이름이 있으면 앞 세 글자, 없으면 번호를 보여준다.
        //  칩이 작아서 긴 이름은 FittedBox가 알아서 줄여준다.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            _chipLabel(state, index),
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.white38,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  // 칩에 표시할 글자 — 이름 앞부분(최대 3글자) 또는 번호
  //  ⚠️ substring은 이모지 중간을 잘라 크래시하므로 runes(실제 글자) 기준으로 자른다.
  String _chipLabel(AppState state, int index) {
    final name = state.characters[index].name.trim();
    if (name.isEmpty) {
      return "${index + 1}";
    }
    final runes = name.runes.toList();
    if (runes.length <= 3) {
      return name;
    }
    return String.fromCharCodes(runes.take(3));
  }

  // 추가 버튼 칩 (슬롯이 남았을 때만 호출된다)
  Widget _addChip(AppState state, double w, double h) {
    return GestureDetector(
      onTap: () {
        state.characters.add(NaiCharacter());
        state.selectedCharIndex = state.characters.length - 1;
        state.saveAllSettings();
        state.refreshUI();
      },
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.accent, width: 1.5),
        ),
        child: Icon(Icons.add, size: 18, color: AppColors.accent),
      ),
    );
  }

  // 캐릭터 번호별 색 — 캔버스 마커와 같은 팔레트를 써서 서로 대응된다
  static const List<Color> _charPalette = [
    AppColors.purple,
    AppColors.teal,
    Color(0xFFFF7043),
    Color(0xFF42A5F5),
    Color(0xFFEC407A),
    Color(0xFF9CCC65),
    Color(0xFFFFCA28),
    Color(0xFF26C6DA),
  ];

  // 사용자가 정한 색이 있으면 그걸 쓰고, 없으면 번호별 기본 팔레트
  //  (캔버스 마커와 같은 규칙이라 서로 대응된다)
  Color _charColor(int i) {
    final state = context.read<AppState>();
    if (i < state.characters.length) {
      final custom = state.characters[i].colorArgb;
      if (custom != null) {
        return Color(custom);
      }
    }
    return _charPalette[i % _charPalette.length];
  }

  // 편집 영역 높이 — 실제로 쓸 수 있는 세로 공간의 40%
  //  MediaQuery.size는 시스템 UI를 포함하므로 padding을 빼야 정확하다.
  double _editorHeight(BuildContext context) {
    final mq = MediaQuery.of(context);
    final usable = mq.size.height - mq.padding.top - mq.padding.bottom;
    // 칩바(약 90) + 이름줄 + 프롬프트 카드 2장이 들어가야 한다.
    //  0.4로는 작은 화면에서 몇십 px이 넘쳐 스크롤이 생겼다.
    return usable * 0.45;
  }

  // 배경 그림 고르기 — '그림' 버튼을 꾹 누르면 열린다.
  //  히스토리와 i2i 결과에서 원하는 그림을 직접 고를 수 있다.
  void _showBackgroundPicker(AppState state) {
    // 최근 것부터 보여준다
    final history = state.historyImages.reversed.toList();
    final i2i = state.i2iResults.map((r) => r.bytes).toList().reversed.toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    "배경 그림",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  // 자동으로 되돌리기
                  TextButton(
                    onPressed: () {
                      // 자동으로 되돌린다 (히스토리 최신을 따라감)
                      state.charCanvasPickedImage = null;
                      state.charCanvasShowImage = true;
                      state.saveAllSettings();
                      state.refreshUI();
                      setState(() {});
                      Navigator.pop(ctx);
                    },
                    child: Text(
                      "자동",
                      style: TextStyle(
                        color: state.charCanvasPickedImage == null
                            ? AppColors.purple
                            : Colors.white38,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (history.isEmpty && i2i.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      "고를 수 있는 그림이 없어요",
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  ),
                ),
              if (i2i.isNotEmpty) ...[
                const Text("i2i 결과", style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 6),
                _bgThumbRow(state, i2i, ctx),
                const SizedBox(height: 14),
              ],
              if (history.isNotEmpty) ...[
                const Text("히스토리", style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 6),
                _bgThumbRow(state, history, ctx),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 가로로 늘어놓은 썸네일 줄
  Widget _bgThumbRow(AppState state, List<Uint8List> images, BuildContext sheetCtx) {
    final picked = state.charCanvasPickedImage;
    return SizedBox(
      height: 84,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        itemBuilder: (c, i) {
          final bytes = images[i];
          final isPicked = picked != null && identical(picked, bytes);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                state.setCharCanvasImage(bytes);
                setState(() {});
                Navigator.pop(sheetCtx);
              },
              child: Container(
                width: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isPicked ? AppColors.purple : Colors.white12,
                    width: isPicked ? 2.5 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    // 작게만 보이므로 원본을 통째로 디코드하지 않는다
                    cacheWidth: 192,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // 배치 모드 칩 — 탭하면 세 가지 중 고른다.
  //  기본     : 랜덤 OFF, 배치 OFF (모델이 알아서 배치)
  //  랜덤     : 랜덤 ON  (캐릭터 순서를 섞음)
  //  배치 적용 : 배치 ON  (내가 찍은 좌표를 그대로 사용)
  //  세 상태는 서로 배타적이라 목록으로 고르는 편이 명확하다.
  Widget _positionModeChip(AppState state) {
    final isRandom = state.randomCharacterOrder;
    final isPosition = state.useCharacterPosition;
    final label = isRandom ? "랜덤" : (isPosition ? "배치 적용" : "기본");
    final color = isRandom
        ? const Color(0xFF3B82F6)
        : (isPosition ? AppColors.purple : Colors.white54);
    final isDefault = !isRandom && !isPosition;

    return GestureDetector(
      onTap: () => _showPositionModePicker(state),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: isDefault ? Colors.transparent : color.withValues(alpha: 0.15),
          border: Border.all(color: isDefault ? Colors.white24 : color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down_rounded, size: 13, color: color),
          ],
        ),
      ),
    );
  }

  void _showPositionModePicker(AppState state) {
    final options = [
      ("기본", Colors.white54, Icons.auto_mode),
      ("랜덤", const Color(0xFF3B82F6), Icons.shuffle),
      ("배치 적용", AppColors.purple, Icons.my_location),
    ];
    final current = state.randomCharacterOrder
        ? "랜덤"
        : (state.useCharacterPosition ? "배치 적용" : "기본");

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "배치 모드",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Divider(height: 1, color: Colors.white12),
            for (final (label, color, icon) in options)
              ListTile(
                dense: true,
                leading: Icon(icon, size: 18, color: current == label ? color : Colors.white24),
                title: Text(
                  label,
                  style: TextStyle(
                    color: current == label ? color : Colors.white,
                    fontSize: 14,
                    fontWeight: current == label ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                trailing: current == label ? Icon(Icons.check, size: 18, color: color) : null,
                onTap: () {
                  // 두 플래그를 한 번에 정해 서로 어긋나지 않게 한다
                  if (label == "랜덤") {
                    state.setRandomCharacterOrder(true);
                  } else if (label == "배치 적용") {
                    state.setUseCharacterPosition(true);
                  } else {
                    state.setRandomCharacterOrder(false);
                    state.setUseCharacterPosition(false);
                  }
                  setState(() {});
                  state.refreshUI();
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // 캔버스 옵션 토글 (격자선 / 스냅)
  Widget _canvasToggle(
    AppState state, {
    required String label,
    required bool active,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppColors.purple.withValues(alpha: 0.2) : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? AppColors.purple : Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? AppColors.purple : Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  // 캔버스 비율 — 항상 '생성 해상도'를 따라간다.
  //  ⚠️ 배경 그림의 비율을 쓰면 안 된다.
  //     예: 1024x1024 그림 + 832x1216 생성 → 실제로는 양옆이 잘린다.
  //     캔버스를 생성 해상도로 두고 그림을 cover로 채우면,
  //     화면에 보이는 영역이 곧 실제로 그려질 영역이 되어 좌표가 어긋나지 않는다.
  double _canvasAspectRatio(AppState state) {
    final m = RegExp(r'(\d+)\s*x\s*(\d+)').firstMatch(state.selectedResolution);
    if (m != null) {
      final w = int.tryParse(m.group(1)!) ?? 832;
      final h = int.tryParse(m.group(2)!) ?? 1216;
      if (w > 0 && h > 0) {
        return w / h;
      }
    }
    return 832 / 1216;
  }

  Widget _buildPromptCard({
    required String title,
    required IconData icon,
    required Color color,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 제목바 — 세로 공간을 아끼려고 최대한 얇게
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: color, size: 14),
                      const SizedBox(width: 5),
                      Text(
                        title,
                        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                    ],
                  ),
                  Icon(Icons.edit, color: color, size: 13),
                ],
              ),
            ),
            // 내용이 아무리 길어도 카드 높이는 2줄로 고정한다.
            //  길이에 따라 늘어나면 아래 Position이 밀려 스크롤해야 해서 불편하다.
            //  전문은 카드를 탭하면 편집창에서 볼 수 있다.
            SizedBox(
              height: 56, // 글자 13 × 1.4 × 2줄 + 위아래 여백
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Align(
                  alignment: text.isEmpty ? Alignment.center : Alignment.topLeft,
                  child: Text(
                    text.isEmpty ? "프롬프트를 입력하세요." : text,
                    textAlign: text.isEmpty ? TextAlign.center : TextAlign.start,
                    style: TextStyle(
                      color: text.isEmpty ? Colors.white30 : Colors.white,
                      fontSize: 13,
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 선택된 캐릭터를 위(-1)/아래(+1)로 한 칸 이동.
  // 캐릭터 순서 = 생성 시 배치 순서라, 프롬프트를 안 바꾸고도 좌우 배치를 조정할 수 있다.
  void _moveCharacter(AppState state, int direction) {
    final from = state.selectedCharIndex;
    final to = from + direction;
    if (to < 0 || to >= state.characters.length) {
      return;
    }
    setState(() {
      final moved = state.characters.removeAt(from);
      state.characters.insert(to, moved);
      state.selectedCharIndex = to; // 선택이 옮긴 캐릭터를 계속 따라가게
      state.saveAllSettings();
      state.refreshUI();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive 필수 호출
    final state = context.watch<AppState>();

    return Column(
      children: [
        // 캐릭터 에디터 (먼저)
        //  내용(칩바 + 이름줄 + 프롬프트 카드 2장)만큼만 차지한다.
        //  고정 높이로 두면 화면이 클 때 아래가 빈 채로 남아 어색했다.
        //  ⚠️ 상한을 둬서 아래 Position이 지나치게 밀리지 않게 한다.
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: _editorHeight(context)),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
            ),
            child: Column(
              // 내용만큼만 차지한다 (남는 공간을 억지로 채우지 않게)
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 캐릭터 칩 줄 (가로 스크롤) ──
                //  좌측 세로 목록을 없애고 위로 올렸다.
                //  편집 영역이 화면 전체 폭을 쓸 수 있어 프롬프트가 훨씬 잘 보인다.
                _buildCharacterChipBar(state),
                const Divider(height: 1, color: Colors.white12),
                // Expanded가 아니라 Flexible — 내용이 짧으면 그만큼만,
                //  넘치면 남은 공간에 맞춰 줄어든다(그때만 스크롤).
                Flexible(
                  child: state.characters.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text("캐릭터를 추가해주세요.", style: TextStyle(color: Colors.grey)),
                          ),
                        )
                      // 높이를 고정했으므로 내용이 넘치면 스크롤되게 한다.
                      //  ⚠️ 기본 physics는 내용이 짧아도 손가락을 따라 통통 튄다.
                      //     화면에 딱 맞는데 움직이면 어색하므로, 넘칠 때만 움직이게
                      //     ClampingScrollPhysics를 쓰고 오버스크롤 효과도 없앤다.
                      : ScrollConfiguration(
                          behavior: const _NoGlowBehavior(),
                          child: SingleChildScrollView(
                            physics: const ClampingScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Row(
                                        children: [
                                          // Expanded로 폭을 확정해야 안쪽 Text가 안전하게 줄어든다.
                                          // (Flexible은 자식이 스스로 폭을 정하길 기대해서 제약이 꼬인다)
                                          Expanded(
                                            child: GestureDetector(
                                              onTap: () {
                                                TextEditingController nameCtrl =
                                                    TextEditingController(
                                                      text:
                                                          state
                                                              .characters[state.selectedCharIndex]
                                                              .name
                                                              .isEmpty
                                                          ? "캐릭터 #${state.selectedCharIndex + 1}"
                                                          : state
                                                                .characters[state.selectedCharIndex]
                                                                .name,
                                                    );
                                                showDialog(
                                                  context: context,
                                                  builder: (ctx) => AlertDialog(
                                                    backgroundColor: AppColors.surface,
                                                    title: const Text(
                                                      "캐릭터 이름 수정",
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 16,
                                                      ),
                                                    ),
                                                    content: TextField(
                                                      controller: nameCtrl,
                                                      maxLength: 12,
                                                      style: const TextStyle(color: Colors.white),
                                                      decoration: InputDecoration(
                                                        counterText: "",
                                                        hintText: "새 이름 입력",
                                                        hintStyle: TextStyle(color: Colors.white30),
                                                        enabledBorder: UnderlineInputBorder(
                                                          borderSide: BorderSide(
                                                            color: AppColors.accent,
                                                          ),
                                                        ),
                                                        focusedBorder: UnderlineInputBorder(
                                                          borderSide: BorderSide(
                                                            color: AppColors.accent,
                                                            width: 2,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () => Navigator.pop(ctx),
                                                        child: const Text(
                                                          "취소",
                                                          style: TextStyle(color: Colors.grey),
                                                        ),
                                                      ),
                                                      ElevatedButton(
                                                        style: ElevatedButton.styleFrom(
                                                          backgroundColor: AppColors.accent,
                                                        ),
                                                        onPressed: () {
                                                          final idx = state.selectedCharIndex;
                                                          if (idx < 0 ||
                                                              idx >= state.characters.length) {
                                                            Navigator.pop(ctx);
                                                            return;
                                                          }
                                                          state.characters[idx].name = nameCtrl.text
                                                              .trim();
                                                          state.saveAllSettings();
                                                          state.refreshUI();
                                                          Navigator.pop(ctx);
                                                        },
                                                        child: const Text(
                                                          "저장",
                                                          style: TextStyle(color: Colors.white),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ).then((_) {
                                                  // ⚠️ 다이얼로그가 닫히는 애니메이션이 끝나기 전에
                                                  //    컨트롤러를 버리면, 아직 그려지고 있는 TextField가
                                                  //    죽은 컨트롤러를 참조해 예외가 난다.
                                                  //    한 프레임 뒤로 미뤄 안전하게 정리한다.
                                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                                    nameCtrl.dispose();
                                                  });
                                                });
                                              },
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 16,
                                                  vertical: 8,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.deepPurple.withValues(alpha: 0.2),
                                                  borderRadius: BorderRadius.circular(20),
                                                ),
                                                // 아이콘을 없앤 뒤로는 자식이 하나뿐이라
                                                // Row/Flexible을 두면 폭 제약이 꼬여 오류가 난다.
                                                // Text 하나만 두고 말줄임으로 처리한다.
                                                child: Text(
                                                  state
                                                          .characters[state.selectedCharIndex]
                                                          .name
                                                          .isEmpty
                                                      ? "캐릭터 #${state.selectedCharIndex + 1}"
                                                      : state
                                                            .characters[state.selectedCharIndex]
                                                            .name,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: AppColors.accent,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Builder(
                                            builder: (context) {
                                              bool isCurrentActive = state
                                                  .characters[state.selectedCharIndex]
                                                  .isActive;
                                              return IconButton(
                                                icon: Icon(
                                                  isCurrentActive
                                                      ? Icons.visibility
                                                      : Icons.visibility_off,
                                                  color: isCurrentActive
                                                      ? AppColors.accent
                                                      : Colors.grey,
                                                  size: 20,
                                                ),
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(
                                                  minWidth: 26,
                                                  minHeight: 34,
                                                ),
                                                visualDensity: VisualDensity.compact,
                                                tooltip: isCurrentActive ? "캐릭터 끄기" : "캐릭터 켜기",
                                                onPressed: () {
                                                  state
                                                          .characters[state.selectedCharIndex]
                                                          .isActive =
                                                      !isCurrentActive;
                                                  state.saveAllSettings();
                                                  state.refreshUI();
                                                },
                                              );
                                            },
                                          ),
                                          // 순서 위로 (왼쪽으로 배치) — 첫 번째면 비활성
                                          IconButton(
                                            icon: const Icon(Icons.keyboard_arrow_up, size: 22),
                                            color: state.selectedCharIndex > 0
                                                ? Colors.white70
                                                : Colors.white24,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 26,
                                              minHeight: 34,
                                            ),
                                            visualDensity: VisualDensity.compact,
                                            tooltip: "순서 위로",
                                            onPressed: state.selectedCharIndex > 0
                                                ? () => _moveCharacter(state, -1)
                                                : null,
                                          ),
                                          // 순서 아래로 (오른쪽으로 배치) — 마지막이면 비활성
                                          IconButton(
                                            icon: const Icon(Icons.keyboard_arrow_down, size: 22),
                                            color:
                                                state.selectedCharIndex <
                                                    state.characters.length - 1
                                                ? Colors.white70
                                                : Colors.white24,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 26,
                                              minHeight: 34,
                                            ),
                                            visualDensity: VisualDensity.compact,
                                            tooltip: "순서 아래로",
                                            onPressed:
                                                state.selectedCharIndex <
                                                    state.characters.length - 1
                                                ? () => _moveCharacter(state, 1)
                                                : null,
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete,
                                        color: Colors.redAccent,
                                        size: 20,
                                      ),
                                      // 다른 버튼과 같은 폭으로 맞춰 이름 칸을 넓힌다
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 26,
                                        minHeight: 34,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () {
                                        showDialog(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            backgroundColor: AppColors.surface,
                                            title: const Text(
                                              "캐릭터 삭제",
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            content: const Text(
                                              "이 캐릭터를 정말 삭제하시겠습니까?",
                                              style: TextStyle(color: Colors.white70),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(ctx),
                                                child: const Text(
                                                  "취소",
                                                  style: TextStyle(color: Colors.grey),
                                                ),
                                              ),
                                              ElevatedButton(
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: Colors.redAccent,
                                                ),
                                                onPressed: () {
                                                  state.characters.removeAt(
                                                    state.selectedCharIndex,
                                                  );
                                                  // Linter 규칙 준수: 중괄호 추가
                                                  if (state.selectedCharIndex > 0) {
                                                    state.selectedCharIndex--;
                                                  }
                                                  if (state.characters.isEmpty) {
                                                    state.characters.add(NaiCharacter());
                                                  }
                                                  state.saveAllSettings();
                                                  state.refreshUI();
                                                  Navigator.pop(ctx);
                                                },
                                                child: const Text(
                                                  "삭제",
                                                  style: TextStyle(color: Colors.white),
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                _buildPromptCard(
                                  title: "캐릭터 긍정 프롬프트",
                                  icon: Icons.add_circle_outline,
                                  color: AppColors.teal,
                                  text: state.characters[state.selectedCharIndex].positive,
                                  onTap: () => _showPromptEditDialog(
                                    context,
                                    state,
                                    "긍정적 프롬프트",
                                    Icons.add_circle_outline,
                                    AppColors.teal,
                                    state.characters[state.selectedCharIndex].positive,
                                    (val) {
                                      state.characters[state.selectedCharIndex].positive = val;
                                    },
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _buildPromptCard(
                                  title: "캐릭터 부정 프롬프트",
                                  icon: Icons.remove_circle_outline,
                                  color: const Color(0xFFE57373),
                                  text: state.characters[state.selectedCharIndex].negative,
                                  onTap: () => _showPromptEditDialog(
                                    context,
                                    state,
                                    "부정적 프롬프트",
                                    Icons.remove_circle_outline,
                                    const Color(0xFFE57373),
                                    state.characters[state.selectedCharIndex].negative,
                                    (val) {
                                      state.characters[state.selectedCharIndex].negative = val;
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),

        // 캐릭터 위치 미리보기 그리드 (맨 아래)
        if (state.characters.isNotEmpty)
          // 남은 공간을 정확히 채워 스크롤이 생기지 않게 한다
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.grid_on, color: AppColors.accent, size: 16),
                      const SizedBox(width: 6),
                      const Text(
                        "Position",
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      // 배치 모드 — 셋 중 하나만 (기본 / 랜덤 / 배치 적용)
                      //  예전에는 토글 두 개라 "이거 켜고 저거 끄고"가 번거로웠다.
                      _positionModeChip(state),
                      const SizedBox(width: 6),
                      // 캔버스 옵션 (V5에서만)
                      if (modelCapsFor(state.selectedModel).usesFreePositioning) ...[
                        _canvasToggle(
                          state,
                          label: "격자",
                          active: state.charCanvasShowGrid,
                          onTap: () {
                            state.charCanvasShowGrid = !state.charCanvasShowGrid;
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                          // 꾹 누르면 칸 수를 고른다
                          onLongPress: () => _showGridSettings(state),
                        ),
                        const SizedBox(width: 6),
                        _canvasToggle(
                          state,
                          label: "스냅",
                          active: state.charCanvasSnap,
                          onTap: () {
                            state.charCanvasSnap = !state.charCanvasSnap;
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                        ),
                        const SizedBox(width: 6),
                        // 배경에 그림 깔기 — 실제 그림을 보며 위치를 잡는다
                        // 배경 이미지 — 툭 누르면 켜고 끄기, 꾹 누르면 직접 고르기.
                        //  직접 고른 상태는 '선택중'으로 표시해 구분한다.
                        _canvasToggle(
                          state,
                          label: state.charCanvasPickedImage != null && state.charCanvasShowImage
                              ? "선택중"
                              : "이미지",
                          active: state.charCanvasShowImage,
                          onTap: () {
                            if (state.charCanvasShowImage) {
                              // 켜져 있으면 끄고, 직접 고른 것도 함께 푼다
                              state.charCanvasShowImage = false;
                              state.charCanvasPickedImage = null;
                            } else {
                              // 꺼져 있으면 자동(히스토리 최신)으로 켠다
                              state.charCanvasShowImage = true;
                              state.charCanvasPickedImage = null;
                            }
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                          // 꾹 누르면 어떤 이미지를 깔지 고른다
                          onLongPress: () => _showBackgroundPicker(state),
                        ),
                        const SizedBox(width: 6),
                      ],
                      // 위치 초기화
                      GestureDetector(
                        onTap: () {
                          for (final char in state.characters) {
                            char.gridX = 2;
                            char.gridY = 2;
                            // 자유 좌표도 함께 초기화 (V5)
                            char.posX = null;
                            char.posY = null;
                          }
                          state.saveAllSettings();
                          state.refreshUI();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text(
                            "초기화",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // V5는 캔버스에서 자유 좌표로, 그 외 모델은 기존 5x5 그리드로 배치한다.
                  if (modelCapsFor(state.selectedModel).usesFreePositioning)
                    // Expanded로 남은 높이에 맞춘다 (세로 비율이라 그냥 두면 넘침)
                    Expanded(
                      child: Center(
                        child: CharacterCanvas(
                          characters: state.characters,
                          selectedIndex: state.selectedCharIndex,
                          aspectRatio: _canvasAspectRatio(state),
                          showGrid: state.charCanvasShowGrid,
                          snapToGrid: state.charCanvasSnap,
                          gridCols: state.charGridCols,
                          gridRows: state.charGridRows,
                          backgroundImage: state.charCanvasBackground,
                          onSelect: (i) {
                            setState(() {
                              state.selectedCharIndex = i;
                              _isGridActive = true;
                            });
                            state.refreshUI();
                          },
                          onMove: (i, x, y) {
                            setState(() => state.characters[i].setPosition(x, y));
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                        ),
                      ),
                    )
                  else
                    AspectRatio(
                      aspectRatio: 5 / 5,
                      child: GridView.builder(
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          crossAxisSpacing: 3,
                          mainAxisSpacing: 3,
                        ),
                        itemCount: 25,
                        itemBuilder: (context, index) {
                          int gx = index % 5;
                          int gy = index ~/ 5;

                          // 활성 캐릭터만 그리드에 표시
                          List<int> charsHere = [];
                          for (int ci = 0; ci < state.characters.length; ci++) {
                            if (state.characters[ci].isActive &&
                                state.characters[ci].gridX == gx &&
                                state.characters[ci].gridY == gy) {
                              charsHere.add(ci);
                            }
                          }

                          bool isSelected =
                              _isGridActive && charsHere.contains(state.selectedCharIndex);

                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                if (charsHere.isNotEmpty) {
                                  if (isSelected && charsHere.length > 1) {
                                    // 같은 칸에 여러 캐릭터 → 순환 선택
                                    int curIdx = charsHere.indexOf(state.selectedCharIndex);
                                    state.selectedCharIndex =
                                        charsHere[(curIdx + 1) % charsHere.length];
                                  } else if (isSelected) {
                                    // 이미 선택된 캐릭터 다시 탭 → 선택 해제
                                    _isGridActive = false;
                                  } else if (_isGridActive) {
                                    // 다른 캐릭터 탭 → 자리 교환 + 선택 해제
                                    final myChar = state.characters[state.selectedCharIndex];
                                    final otherChar = state.characters[charsHere.first];
                                    final tempX = myChar.gridX;
                                    final tempY = myChar.gridY;
                                    myChar.gridX = otherChar.gridX;
                                    myChar.gridY = otherChar.gridY;
                                    otherChar.gridX = tempX;
                                    otherChar.gridY = tempY;
                                    _isGridActive = false;
                                    state.saveAllSettings();
                                  } else {
                                    // 선택 안 된 상태 → 선택
                                    state.selectedCharIndex = charsHere.first;
                                    _isGridActive = true;
                                  }
                                } else {
                                  // 빈 칸 탭: 선택된 캐릭터가 있으면 이동
                                  if (_isGridActive &&
                                      state.selectedCharIndex < state.characters.length) {
                                    state.characters[state.selectedCharIndex].gridX = gx;
                                    state.characters[state.selectedCharIndex].gridY = gy;
                                    _isGridActive = false;
                                    state.saveAllSettings();
                                  }
                                }
                                state.refreshUI();
                              });
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: charsHere.isNotEmpty
                                    ? (isSelected
                                          ? AppColors.accent.withValues(alpha: 0.4)
                                          : AppColors.accent.withValues(alpha: 0.15))
                                    : Colors.white.withValues(alpha: 0.03),
                                border: Border.all(
                                  color: isSelected
                                      ? AppColors.accent
                                      : Colors.white.withValues(alpha: 0.1),
                                  width: isSelected ? 1.5 : 0.5,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Center(
                                child: charsHere.isNotEmpty
                                    ? Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: charsHere
                                            .map(
                                              (i) => Text(
                                                "C${i + 1}",
                                                style: TextStyle(
                                                  color:
                                                      (_isGridActive &&
                                                          state.selectedCharIndex == i)
                                                      ? Colors.white
                                                      : Colors.white38,
                                                  fontSize: charsHere.length > 2
                                                      ? 8
                                                      : (charsHere.length > 1 ? 9 : 11),
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            )
                                            .toList(),
                                      )
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    ); // Column closing
  }
}

/// 오버스크롤 글로우를 없애는 동작.
///  편집 영역이 화면에 딱 맞는데도 파랗게 번지며 튀는 걸 막는다.
class _NoGlowBehavior extends ScrollBehavior {
  const _NoGlowBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    return child; // 글로우 표시 안 함
  }
}
