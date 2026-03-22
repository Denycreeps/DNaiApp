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

// 🚀 [추가] 샘플러 표시명 매핑 (NovelAI 웹사이트와 동일)
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
const List<String> _resolutions = [
  "1344 x 768",
  "1216 x 832",
  "1152 x 896",
  "1088 x 960",
  "1024 x 1024",
  "960 x 1088",
  "896 x 1152",
  "832 x 1216",
  "768 x 1344",
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
                      Expanded(
                        flex: 55,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("해상도"),
                            buildInputContainer(
                              DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: state.selectedResolution,
                                  isExpanded: true,
                                  isDense: true,
                                  dropdownColor: const Color(0xFF2A2A2D),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: Colors.grey,
                                    size: 20,
                                  ),
                                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                  items: _resolutions
                                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                                      .toList(),
                                  onChanged: state.resolutionMode != "수동"
                                      ? null
                                      : (val) {
                                          if (val != null) {
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
                            if (state.selectedResolution == "직접 입력" &&
                                state.resolutionMode == "수동") ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: buildInputContainer(
                                      TextField(
                                        controller: state.customWidthController,
                                        keyboardType: TextInputType.number,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                        decoration: const InputDecoration(
                                          border: InputBorder.none,
                                          isCollapsed: true,
                                          hintText: "가로",
                                          hintStyle: TextStyle(color: Colors.white30),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 6),
                                    child: Text("x", style: TextStyle(color: Colors.white54)),
                                  ),
                                  Expanded(
                                    child: buildInputContainer(
                                      TextField(
                                        controller: state.customHeightController,
                                        keyboardType: TextInputType.number,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                        decoration: const InputDecoration(
                                          border: InputBorder.none,
                                          isCollapsed: true,
                                          hintText: "세로",
                                          hintStyle: TextStyle(color: Colors.white30),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 45,
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
                                  items: [
                                    "수동",
                                    "랜덤",
                                    "자동",
                                  ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
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
                                  value: state.selectedModel,
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

void showSaveImageModal(BuildContext context, AppState state, Uint8List imageBytes) {
  if (state.isLoading) return;

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
              leading: const Icon(Icons.download, color: Colors.deepPurpleAccent),
              title: const Text("기본 폴더에 저장", style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                "지정된 경로로 원본 이미지가 저장됩니다.",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(modalContext);
                state.manualSaveImage(context, imageBytes);
              },
            ),

            // 🚀 [추가] i2i 전송 액션 및 탭 이동!
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

                // 🚀 i2i 탭(2번 탭)으로 즉시 이동!
                state.navigateToTab(2);

                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text("이미지를 i2i 탭으로 보냈습니다! 👉")));
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
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text("이 이미지에서 메타데이터를 찾을 수 없습니다.")));
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
    if (_resolutions.contains(resString)) {
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text("${applied.join(', ')}을(를) 불러왔습니다!")));
  }
}
