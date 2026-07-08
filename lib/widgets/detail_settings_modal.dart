import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/nai_character.dart';

const List<String> _models = ["nai-diffusion-4-full", "nai-diffusion-4-5-full"];
const List<String> _samplers = [
  "k_euler_ancestral",
  "k_euler",
  "k_dpmpp_2s_ancestral",
  "k_dpmpp_2m_sde",
  "k_dpmpp_2m",
  "k_dpmpp_sde",
  "ddim",
];

// [추가] 샘플러 표시명 매핑 (NovelAI 웹사이트와 동일)
const Map<String, String> _samplerDisplayNames = {
  "k_euler_ancestral": "Euler Ancestral",
  "k_euler": "Euler",
  "k_dpmpp_2s_ancestral": "DPM++ 2S Ancestral",
  "k_dpmpp_2m_sde": "DPM++ 2M SDE",
  "k_dpmpp_2m": "DPM++ 2M",
  "k_dpmpp_sde": "DPM++ SDE",
  "ddim": "DDIM",
};
const List<String> _schedulers = ["native", "karras", "exponential", "polyexponential"];
const List<String> _defaultResolutions = [
  "768 x 1344",
  "832 x 1216",
  "896 x 1152",
  "960 x 1088",
  "1024 x 1024",
  "1088 x 960",
  "1152 x 896",
  "1216 x 832",
  "1344 x 768",
  "직접 입력",
];

void showDetailSettingsModal(BuildContext context) {
  FocusScope.of(context).unfocus();
  final state = context.read<AppState>();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (modalContext) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setModalState) {
          Widget buildLabel(String text) => Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text(
              text,
              style: TextStyle(
                color: Colors.grey[300],
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          );

          Widget buildInputContainer(Widget child) => Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2D),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: child,
          );

          return Container(
            padding: EdgeInsets.only(
              bottom:
                  MediaQuery.of(modalContext).viewInsets.bottom +
                  MediaQuery.of(modalContext).padding.bottom +
                  16,
              left: 20,
              right: 20,
              top: 12,
            ),
            decoration: const BoxDecoration(
              color: Color(0xFF1E1E1E),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey[600],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text(
                        "상세 환경 설정",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // VAR+ 토글 버튼
                      GestureDetector(
                        onTap: () =>
                            setModalState(() => state.isVariancePlus = !state.isVariancePlus),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: state.isVariancePlus
                                ? Colors.deepPurpleAccent.withValues(alpha: 0.25)
                                : const Color(0xFF2A2A2D),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: state.isVariancePlus
                                  ? Colors.deepPurpleAccent
                                  : Colors.white24,
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                "VAR+",
                                style: TextStyle(
                                  color: state.isVariancePlus
                                      ? Colors.deepPurpleAccent
                                      : Colors.white38,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(width: 6),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                width: 28,
                                height: 16,
                                decoration: BoxDecoration(
                                  color: state.isVariancePlus
                                      ? Colors.deepPurpleAccent
                                      : Colors.white24,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: AnimatedAlign(
                                  duration: const Duration(milliseconds: 200),
                                  alignment: state.isVariancePlus
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Container(
                                    width: 12,
                                    height: 12,
                                    margin: const EdgeInsets.symmetric(horizontal: 2),
                                    decoration: const BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 해상도 드롭다운
                      Expanded(
                        flex: 45,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 해상도 라벨 + 실제 해상도
                            Row(
                              children: [
                                buildLabel("해상도"),
                                if (state.resolutionScale == 1.5 &&
                                    state.selectedResolution != "직접 입력" &&
                                    state.selectedResolution.contains("x"))
                                  Expanded(
                                    child: Text(
                                      () {
                                        final resParts = state.selectedResolution
                                            .replaceAll(" ", "")
                                            .split("x");
                                        if (resParts.length < 2) {
                                          return "";
                                        }
                                        var w =
                                            ((int.tryParse(resParts[0]) ?? 832) * 1.5 / 64)
                                                .round() *
                                            64;
                                        var h =
                                            ((int.tryParse(resParts[1]) ?? 1216) * 1.5 / 64)
                                                .round() *
                                            64;
                                        while (w * h > 3145728) {
                                          if (w > h) {
                                            w -= 64;
                                          } else {
                                            h -= 64;
                                          }
                                        }
                                        final anlas = (w * h > 1048576) ? " Anlas" : "";
                                        return " → $w x $h$anlas";
                                      }(),
                                      style: TextStyle(
                                        color: Colors.amber.withValues(alpha: 0.8),
                                        fontSize: 10,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                            buildInputContainer(
                              DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value:
                                      (state.selectedResolution != "직접 입력" &&
                                          [
                                            ..._defaultResolutions,
                                            ...state.customResolutions,
                                          ].contains(state.selectedResolution))
                                      ? state.selectedResolution
                                      : "832 x 1216",
                                  isExpanded: true,
                                  isDense: true,
                                  dropdownColor: const Color(0xFF2A2A2D),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                  items: [
                                    ..._defaultResolutions.map(
                                      (e) => DropdownMenuItem(value: e, child: Text(e)),
                                    ),
                                    if (state.customResolutions.isNotEmpty)
                                      const DropdownMenuItem(
                                        enabled: false,
                                        value: null,
                                        child: Divider(color: Colors.white24, height: 1),
                                      ),
                                    ...state.customResolutions.map(
                                      (e) => DropdownMenuItem(
                                        value: e,
                                        child: Row(
                                          children: [
                                            const Icon(Icons.star, color: Colors.amber, size: 14),
                                            const SizedBox(width: 6),
                                            Text(e),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: state.resolutionMode != "수동"
                                      ? null
                                      : (val) {
                                          if (val == "직접 입력") {
                                            _showCustomResolutionDialog(
                                              context,
                                              state,
                                              setModalState,
                                            );
                                          } else if (val != null) {
                                            setModalState(() => state.selectedResolution = val);
                                          }
                                        },
                                  disabledHint: Text(
                                    state.resolutionMode == "자동"
                                        ? "자동 맞춤"
                                        : (state.resolutionMode == "랜덤"
                                              ? "랜덤 지정됨"
                                              : state.selectedResolution),
                                    style: const TextStyle(fontSize: 13.5, color: Colors.white54),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 1.5x 토글 버튼
                      Padding(
                        padding: const EdgeInsets.only(top: 26),
                        child: GestureDetector(
                          onTap: () {
                            setModalState(() {
                              state.resolutionScale = state.resolutionScale == 1.5 ? 1.0 : 1.5;
                            });
                            state.saveAllSettings();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                            decoration: BoxDecoration(
                              color: state.resolutionScale == 1.5
                                  ? const Color(0xFF8B5CF6).withValues(alpha: 0.2)
                                  : const Color(0xFF2A2A2D),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: state.resolutionScale == 1.5
                                    ? const Color(0xFF8B5CF6)
                                    : Colors.white12,
                                width: state.resolutionScale == 1.5 ? 1.5 : 1,
                              ),
                            ),
                            child: Text(
                              "1.5x",
                              style: TextStyle(
                                color: state.resolutionScale == 1.5
                                    ? const Color(0xFF8B5CF6)
                                    : Colors.white54,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 해상도 모드
                      Expanded(
                        flex: 40,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("해상도 모드"),
                            buildInputContainer(
                              DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: state.resolutionMode,
                                  isExpanded: true,
                                  isDense: true,
                                  dropdownColor: const Color(0xFF2A2A2D),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                  selectedItemBuilder: (context) {
                                    return ["수동", "랜덤", "자동"].map((e) {
                                      final label = e == "수동"
                                          ? "수동"
                                          : (e == "랜덤" ? "🔀 랜덤" : "🪄 자동");
                                      return Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          label,
                                          style: const TextStyle(
                                            color: Color(0xFF8B5CF6),
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      );
                                    }).toList();
                                  },
                                  items: [("수동", "수동"), ("랜덤", "🔀 랜덤"), ("자동", "🪄 자동")]
                                      .map((e) => DropdownMenuItem(value: e.$1, child: Text(e.$2)))
                                      .toList(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      setModalState(() => state.resolutionMode = val);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        flex: 55,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("모델"),
                            buildInputContainer(
                              DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  // 저장된 모델이 목록에 없으면(예: 제거된 테스트 모델) 기본값으로 폴백
                                  value: _models.contains(state.selectedModel)
                                      ? state.selectedModel
                                      : "nai-diffusion-4-5-full",
                                  isExpanded: true,
                                  isDense: true,
                                  dropdownColor: const Color(0xFF2A2A2D),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                  items: _models
                                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                                      .toList(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      setModalState(() => state.selectedModel = val);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 45,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("스텝"),
                            buildInputContainer(
                              TextField(
                                controller: state.stepsController,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  isCollapsed: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        flex: 55,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("샘플러"),
                            buildInputContainer(
                              DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: state.selectedSampler,
                                  isExpanded: true,
                                  isDense: true,
                                  dropdownColor: const Color(0xFF2A2A2D),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                  items: _samplers
                                      .map(
                                        (e) => DropdownMenuItem(
                                          value: e,
                                          child: Text(_samplerDisplayNames[e] ?? e),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      setModalState(() => state.selectedSampler = val);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 45,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("스케줄러"),
                            buildInputContainer(
                              DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: state.selectedScheduler,
                                  isExpanded: true,
                                  isDense: true,
                                  dropdownColor: const Color(0xFF2A2A2D),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                  items: _schedulers
                                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                                      .toList(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      setModalState(() => state.selectedScheduler = val);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        flex: 55,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("시드"),
                            buildInputContainer(
                              TextField(
                                controller: state.seedController,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                decoration: const InputDecoration(
                                  hintText: "랜덤",
                                  hintStyle: TextStyle(color: Colors.white30),
                                  border: InputBorder.none,
                                  isCollapsed: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 45,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("시드 고정"),
                            GestureDetector(
                              onTap: () {
                                setModalState(() => state.isSeedLocked = !state.isSeedLocked);
                              },
                              child: buildInputContainer(
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: Checkbox(
                                        value: state.isSeedLocked,
                                        activeColor: Colors.deepPurpleAccent,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        onChanged: (val) {
                                          setModalState(() => state.isSeedLocked = val ?? false);
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      "고정",
                                      style: TextStyle(color: Colors.white, fontSize: 13.5),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        flex: 55,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("CFG Scale"),
                            buildInputContainer(
                              TextField(
                                controller: state.cfgScaleController,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  isCollapsed: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 45,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("CFG Rescale"),
                            buildInputContainer(
                              TextField(
                                controller: state.cfgRescaleController,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  isCollapsed: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  ).whenComplete(() {
    state.saveAllSettings();
    state.refreshUI();
  });
}

void showSaveImageModal(
  BuildContext context,
  AppState state,
  Uint8List imageBytes, {
  String? savedFilePath,
}) {
  if (state.isLoading) return;

  // 파일이 이미 존재하는지 확인
  final bool alreadySaved =
      savedFilePath != null && savedFilePath.isNotEmpty && File(savedFilePath).existsSync();

  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1E1E1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (modalContext) {
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(modalContext).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "이미지 옵션",
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),

            ListTile(
              leading: Icon(
                alreadySaved ? Icons.check_circle : Icons.download,
                color: alreadySaved ? Colors.tealAccent : Colors.deepPurpleAccent,
              ),
              title: Text(
                alreadySaved ? "이미 저장된 이미지" : "기본 폴더에 저장",
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                alreadySaved ? "이 이미지는 이미 기기에 저장되어 있습니다." : "지정된 경로로 원본 이미지가 저장됩니다.",
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: alreadySaved
                  ? () {
                      Navigator.pop(modalContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          duration: const Duration(milliseconds: 2400),
                          content: Text("이미 저장된 이미지입니다."),
                        ),
                      );
                    }
                  : () {
                      Navigator.pop(modalContext);
                      state.manualSaveImage(context, imageBytes);
                    },
            ),

            // [추가] i2i 전송 액션 및 탭 이동!
            ListTile(
              leading: const Icon(Icons.brush, color: Colors.deepPurpleAccent),
              title: const Text("이미지 수정하기 (i2i)", style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                "i2i 탭으로 이미지를 보내 후가공(인페인트 등)을 진행합니다.",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(modalContext);
                NaiMetadata? parsedMetadata = extractNovelAIMetadata(imageBytes);
                state.sendToI2i(imageBytes, parsedMetadata);

                // i2i 탭(2번 탭)으로 즉시 이동!
                state.navigateToTab(2);

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(milliseconds: 2400),
                    content: Text("이미지를 i2i 탭으로 보냈습니다! 👉"),
                  ),
                );
              },
            ),

            ListTile(
              leading: const Icon(Icons.file_download_outlined, color: Colors.deepPurpleAccent),
              title: const Text("프롬프트 불러오기", style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                "이 이미지의 프롬프트와 설정을 현재 작업 환경에 불러옵니다.",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(modalContext);
                NaiMetadata? meta = extractNovelAIMetadata(imageBytes);
                if (meta == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(milliseconds: 2400),
                      content: Text("이 이미지에서 메타데이터를 찾을 수 없습니다."),
                    ),
                  );
                  return;
                }
                _showLoadPromptDialog(context, state, meta);
              },
            ),

            const SizedBox(height: 16),
          ],
        ),
      );
    },
  );
}

void _showLoadPromptDialog(BuildContext context, AppState state, NaiMetadata meta) {
  bool loadPositive = true;
  bool loadNegative = true;
  bool loadCharacters = true;
  bool addCharactersAsNew = true;
  bool loadSettings = true;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        Widget checkItem(
          String label,
          bool value,
          ValueChanged<bool?> onChanged, {
          double leftPadding = 0,
        }) {
          return InkWell(
            onTap: () => onChanged(!value),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.only(left: leftPadding, top: 6, bottom: 6),
              child: Row(
                children: [
                  Checkbox(
                    value: value,
                    onChanged: onChanged,
                    activeColor: Colors.deepPurpleAccent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  Expanded(
                    child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 15)),
                  ),
                ],
              ),
            ),
          );
        }

        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.file_download_outlined, color: Colors.deepPurpleAccent),
              SizedBox(width: 8),
              Text(
                "프롬프트 불러오기",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("불러올 항목을 선택하세요.", style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 12),
              checkItem("긍정적 프롬프트", loadPositive, (v) {
                setDialogState(() => loadPositive = v ?? true);
              }),
              checkItem("부정적 프롬프트", loadNegative, (v) {
                setDialogState(() => loadNegative = v ?? true);
              }),
              checkItem("캐릭터 (${meta.characterPrompts.length}개)", loadCharacters, (v) {
                setDialogState(() => loadCharacters = v ?? true);
              }),
              if (loadCharacters && meta.characterPrompts.isNotEmpty)
                checkItem("└ 새로 추가하기", addCharactersAsNew, (v) {
                  setDialogState(() => addCharactersAsNew = v ?? true);
                }, leftPadding: 24),
              checkItem("상세 설정 (샘플러, 스텝, 시드 등)", loadSettings, (v) {
                setDialogState(() => loadSettings = v ?? true);
              }),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("취소", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _applyMetadata(
                  context,
                  state,
                  meta,
                  positive: loadPositive,
                  negative: loadNegative,
                  characters: loadCharacters,
                  addCharactersAsNew: addCharactersAsNew,
                  settings: loadSettings,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurpleAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text(
                "불러오기",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    ),
  );
}

void _applyMetadata(
  BuildContext context,
  AppState state,
  NaiMetadata meta, {
  required bool positive,
  required bool negative,
  required bool characters,
  required bool addCharactersAsNew,
  required bool settings,
}) {
  List<String> applied = [];

  if (positive && meta.positive.isNotEmpty) {
    state.positiveController.text = meta.positive;
    applied.add("긍정적 프롬프트");
  }

  if (negative && meta.negative.isNotEmpty) {
    state.negativeController.text = meta.negative;
    applied.add("부정적 프롬프트");
  }

  if (characters && meta.characterPrompts.isNotEmpty) {
    if (!addCharactersAsNew) {
      state.characters.clear();
    }
    int startIndex = state.characters.length;
    for (int i = 0; i < meta.characterPrompts.length; i++) {
      state.characters.add(
        NaiCharacter(
          name: "캐릭터 ${startIndex + i + 1}",
          positive: meta.characterPrompts[i],
          negative: i < meta.characterUndesiredContents.length
              ? meta.characterUndesiredContents[i]
              : "",
        ),
      );
    }
    applied.add(
      addCharactersAsNew
          ? "캐릭터 ${meta.characterPrompts.length}개 추가"
          : "캐릭터 ${meta.characterPrompts.length}개",
    );
  }

  if (settings) {
    if (meta.sampler.isNotEmpty && _samplers.contains(meta.sampler)) {
      state.selectedSampler = meta.sampler;
    }

    String? scheduler = meta.extraParams['noise_schedule']?.toString();
    if (scheduler != null && _schedulers.contains(scheduler)) {
      state.selectedScheduler = scheduler;
    }

    if (meta.steps > 0) {
      state.stepsController.text = meta.steps.toString();
    }

    if (meta.promptGuidance > 0) {
      state.cfgScaleController.text = meta.promptGuidance.toString();
    }

    state.cfgRescaleController.text = meta.promptGuidanceRescale.toString();

    if (meta.seed > 0) {
      state.seedController.text = meta.seed.toString();
    }

    String resString = "${meta.width} x ${meta.height}";
    if (_defaultResolutions.contains(resString) || state.customResolutions.contains(resString)) {
      state.selectedResolution = resString;
      state.resolutionMode = "수동";
    }

    var skipCfg = meta.extraParams['skip_cfg_above_sigma'];
    state.isVariancePlus = skipCfg != null && skipCfg.toString() != "null";

    applied.add("상세 설정");
  }

  state.saveAllSettings();
  // 프롬프트 탭으로 이동 (UI 리빌드도 동시에 트리거)
  state.navigateToTab(0);

  if (applied.isNotEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 2400),
        content: Text("${applied.join(', ')}을(를) 불러왔습니다!"),
      ),
    );
  }
}

void _showCustomResolutionDialog(BuildContext context, AppState state, StateSetter setModalState) {
  final wCtrl = TextEditingController();
  final hCtrl = TextEditingController();

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "커스텀 해상도",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 입력 영역
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: wCtrl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: "가로",
                        hintStyle: const TextStyle(color: Colors.white30),
                        filled: true,
                        fillColor: const Color(0xFF121212),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text("x", style: TextStyle(color: Colors.white54, fontSize: 16)),
                  ),
                  Expanded(
                    child: TextField(
                      controller: hCtrl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: "세로",
                        hintStyle: const TextStyle(color: Colors.white30),
                        filled: true,
                        fillColor: const Color(0xFF121212),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      final w = int.tryParse(wCtrl.text);
                      final h = int.tryParse(hCtrl.text);
                      if (w != null && h != null && w > 0 && h > 0) {
                        // 64px 정렬
                        var aw = ((w / 64).round() * 64).clamp(64, 9999);
                        var ah = ((h / 64).round() * 64).clamp(64, 9999);
                        // 최대 픽셀 제한 (3,145,728px)
                        while (aw * ah > 3145728) {
                          if (aw > ah) {
                            aw -= 64;
                          } else {
                            ah -= 64;
                          }
                        }
                        final res = "$aw x $ah";
                        final adjusted = (aw != w || ah != h);
                        final warning = (aw * ah > 1048576) ? " (Anlas 소모)" : "";
                        if (!state.customResolutions.contains(res)) {
                          state.customResolutions.add(res);
                          state.saveAllSettings();
                        }
                        setModalState(() => state.selectedResolution = res);
                        setDialogState(() {});
                        wCtrl.clear();
                        hCtrl.clear();
                        final adjustNote = adjusted ? "\n입력: $w x $h → 조정됨" : "";
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            duration: const Duration(milliseconds: 2400),
                            content: Text("$res 추가됨$warning$adjustNote"),
                          ),
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8B5CF6),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text(
                      "추가",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
              // 저장된 목록
              if (state.customResolutions.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  "저장된 해상도",
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                ...state.customResolutions.map((res) {
                  final parts = res.replaceAll(" ", "").split("x");
                  final pixels =
                      (int.tryParse(parts[0]) ?? 0) *
                      (int.tryParse(parts.length > 1 ? parts[1] : "0") ?? 0);
                  final consumesAnlas = pixels > 1048576;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: state.selectedResolution == res
                          ? const Color(0xFF8B5CF6).withValues(alpha: 0.1)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: state.selectedResolution == res
                            ? const Color(0xFF8B5CF6).withValues(alpha: 0.4)
                            : Colors.white12,
                      ),
                    ),
                    child: ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -3),
                      title: Row(
                        children: [
                          Text("⭐ $res", style: const TextStyle(color: Colors.white, fontSize: 13)),
                          if (consumesAnlas)
                            Text(
                              "  (Anlas)",
                              style: TextStyle(
                                color: Colors.amber.withValues(alpha: 0.8),
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                      trailing: GestureDetector(
                        onTap: () {
                          state.customResolutions.remove(res);
                          if (state.selectedResolution == res) {
                            state.selectedResolution = "832 x 1216";
                          }
                          state.saveAllSettings();
                          setModalState(() {});
                          setDialogState(() {});
                        },
                        child: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                      ),
                      onTap: () {
                        setModalState(() => state.selectedResolution = res);
                        setDialogState(() {});
                      },
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("닫기", style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    ),
  );
}
