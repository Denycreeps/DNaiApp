import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/image_metadata.dart';
import '../models/nai_character.dart';
import '../models/model_caps.dart';
import '../app_theme.dart';

const List<String> _models = [NaiModels.v4Full, NaiModels.v45Full, NaiModels.v5Full];
const List<String> _samplers = [
  "k_euler_ancestral",
  "k_euler",
  "k_dpmpp_2s_ancestral",
  "k_dpmpp_2m_sde",
  "k_dpmpp_2m",
  "k_dpmpp_sde",
  // "ddim" 제거: V4 계열에서 정상 동작하지 않는다(API로 보내면 노이즈 이미지/에러).
];

// [추가] 샘플러 표시명 매핑 (NovelAI 웹사이트와 동일)
const Map<String, String> _samplerDisplayNames = {
  "k_euler_ancestral": "Euler Ancestral",
  "k_euler": "Euler",
  "k_dpmpp_2s_ancestral": "DPM++ 2S Ancestral",
  "k_dpmpp_2m_sde": "DPM++ 2M SDE",
  "k_dpmpp_2m": "DPM++ 2M",
  "k_dpmpp_sde": "DPM++ SDE",
};
const List<String> _schedulers = ["native", "karras", "exponential", "polyexponential"];
// 해상도 목록은 model_caps.kNaiResolutions 한 곳에서만 관리 (중복 하드코딩 제거)
const List<String> _defaultResolutions = [...kNaiResolutions, "직접 입력"];

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
          // VAR+ 토글 (모델이 미지원이면 잠금) — 하단 토글 줄에서 쓴다
          Widget varPlusToggle() {
            return GestureDetector(
              onTap: () {
                if (!modelCapsFor(state.selectedModel).supportsVarietyPlus) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        "${modelCapsFor(state.selectedModel).displayName}에선 VAR+를 사용할 수 없어요",
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  return;
                }
                setModalState(() => state.isVariancePlus = !state.isVariancePlus);
              },
              child: Opacity(
                opacity: modelCapsFor(state.selectedModel).supportsVarietyPlus ? 1.0 : 0.35,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: state.isVariancePlus
                        ? AppColors.accent.withValues(alpha: 0.25)
                        : AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: state.isVariancePlus ? AppColors.accent : Colors.white24,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "VAR+",
                        style: TextStyle(
                          color: state.isVariancePlus ? AppColors.accent : Colors.white38,
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
                          color: state.isVariancePlus ? AppColors.accent : Colors.white24,
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
            );
          }

          // 투명 배경(알파) 토글 — V5 전용
          Widget alphaToggle() {
            final on = state.transparentBackground;
            return GestureDetector(
              onTap: () {
                setModalState(() => state.transparentBackground = !on);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: on ? AppColors.teal.withValues(alpha: 0.22) : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: on ? AppColors.teal : Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      on ? Icons.check_box_outlined : Icons.check_box_outline_blank,
                      size: 16,
                      color: on ? AppColors.teal : Colors.white38,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      "알파",
                      style: TextStyle(
                        color: on ? AppColors.teal : Colors.white38,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

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
              color: AppColors.surfaceAlt,
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
              color: AppColors.surface,
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
                        "상세 환경",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 모델을 제목 옆에 둔다.
                      //  아래 설정들이 '이 모델의 값'이라는 게 한눈에 보이도록 한 배치.
                      //  모델을 바꾸면 그 모델에서 마지막으로 쓰던 설정이 복원된다.
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              // 저장된 모델이 목록에 없으면(예: 제거된 테스트 모델) 기본값으로 폴백
                              value: _models.contains(state.selectedModel)
                                  ? state.selectedModel
                                  : NaiModels.v45Full,
                              isExpanded: true,
                              isDense: true,
                              dropdownColor: AppColors.surfaceAlt,
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Colors.grey,
                                size: 20,
                              ),
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              items: _models
                                  .map(
                                    (e) => DropdownMenuItem(
                                      value: e,
                                      child: Text(
                                        modelCapsFor(e).isPlaceholder
                                            ? modelCapsFor(e).displayName
                                            : e,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  // 모델별 상세환경을 저장·복원한다
                                  setModalState(() => state.switchModel(val));
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
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
                                        final (w, h) = clampResolution(
                                          ((int.tryParse(resParts[0]) ?? 832) * 1.5).round(),
                                          ((int.tryParse(resParts[1]) ?? 1216) * 1.5).round(),
                                          modelCapsFor(state.selectedModel).maxPixels,
                                        );
                                        final anlas = (w * h > AppState.kMegapixelCap)
                                            ? " Anlas"
                                            : "";
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
                                  dropdownColor: AppColors.surfaceAlt,
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
                                  ? AppColors.purple.withValues(alpha: 0.2)
                                  : AppColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: state.resolutionScale == 1.5
                                    ? AppColors.purple
                                    : Colors.white12,
                                width: state.resolutionScale == 1.5 ? 1.5 : 1,
                              ),
                            ),
                            child: Text(
                              "1.5x",
                              style: TextStyle(
                                color: state.resolutionScale == 1.5
                                    ? AppColors.purple
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
                                  dropdownColor: AppColors.surfaceAlt,
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
                                            color: AppColors.purple,
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

                  // 모델은 맨 위(제목 옆)로 옮겼다. 여기는 스텝 + 투명 배경.
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
                                  // 예전에 저장된 값이 목록에 없으면(예: 제거된 ddim) 기본값으로 폴백
                                  value: _samplers.contains(state.selectedSampler)
                                      ? state.selectedSampler
                                      : _samplers.first,
                                  isExpanded: true,
                                  isDense: true,
                                  dropdownColor: AppColors.surfaceAlt,
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
                            // V5는 Karras 고정이라 선택기를 잠근다 (공식 UI도 숨김 처리)
                            Builder(
                              builder: (context) {
                                final caps = modelCapsFor(state.selectedModel);
                                if (!caps.allowsSchedulerChoice) {
                                  return buildInputContainer(
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.lock_outline,
                                          size: 14,
                                          color: Colors.white24,
                                        ),
                                        const SizedBox(width: 8),
                                        const Text(
                                          "karras (고정)",
                                          style: TextStyle(color: Colors.white38, fontSize: 13.5),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                                return buildInputContainer(
                                  DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: state.selectedScheduler,
                                      isExpanded: true,
                                      isDense: true,
                                      dropdownColor: AppColors.surfaceAlt,
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
                                );
                              },
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
                                        activeColor: AppColors.accent,
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

                  // 스텝 · 프롬프트 가이던스 · 리스케일을 한 줄에
                  Row(
                    children: [
                      Expanded(
                        flex: 30,
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
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 35,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("Prompt Guidance"),
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
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 35,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildLabel("Prompt Rescale"),
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
                  const SizedBox(height: 16),
                  // 하단 토글 줄 — 앞으로 버튼이 더 늘어날 수 있어 Wrap으로 둔다
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      varPlusToggle(),
                      if (modelCapsFor(state.selectedModel).supportsTransparency) alphaToggle(),
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
    backgroundColor: AppColors.surface,
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
                color: alreadySaved ? Colors.tealAccent : AppColors.accent,
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
              leading: Icon(Icons.brush, color: AppColors.accent),
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
              leading: Icon(Icons.file_download_outlined, color: AppColors.accent),
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
                showLoadPromptDialog(context, state, meta);
              },
            ),

            const SizedBox(height: 16),
          ],
        ),
      );
    },
  );
}

void showLoadPromptDialog(BuildContext context, AppState state, NaiMetadata meta) {
  bool loadPositive = true;
  bool loadNegative = true;
  bool loadCharacters = true;
  bool addCharactersAsNew = true;
  bool loadSettings = true;

  final int charCount = meta.characterPrompts.length;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setDialogState) {
        // 항목 한 줄 — 왼쪽 아이콘 + 이름, 오른쪽 스위치
        Widget row({
          required IconData icon,
          required String label,
          String? trailingText,
          required bool value,
          required ValueChanged<bool> onChanged,
        }) {
          return InkWell(
            onTap: () => onChanged(!value),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              // 손가락으로 누르기 편하게 위아래 여백을 넉넉히
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: value ? AppColors.accent : Colors.white24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(color: value ? Colors.white : Colors.white38, fontSize: 16),
                    ),
                  ),
                  if (trailingText != null) ...[
                    Text(trailingText, style: const TextStyle(color: Colors.white38, fontSize: 14)),
                    const SizedBox(width: 8),
                  ],
                  SizedBox(
                    height: 24,
                    child: Switch(
                      value: value,
                      onChanged: onChanged,
                      activeThumbColor: AppColors.accent,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          title: Row(
            children: [
              Icon(Icons.file_download_outlined, color: AppColors.accent, size: 20),
              SizedBox(width: 8),
              Text(
                "불러오기",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row(
                  icon: Icons.add_circle_outline,
                  label: "긍정적 프롬프트",
                  value: loadPositive,
                  onChanged: (v) => setDialogState(() => loadPositive = v),
                ),
                row(
                  icon: Icons.remove_circle_outline,
                  label: "부정적 프롬프트",
                  value: loadNegative,
                  onChanged: (v) => setDialogState(() => loadNegative = v),
                ),
                row(
                  icon: Icons.people_alt_outlined,
                  label: "캐릭터",
                  trailingText: charCount > 0 ? "$charCount개" : null,
                  value: loadCharacters,
                  onChanged: (v) => setDialogState(() => loadCharacters = v),
                ),
                // ⚠️ 캐릭터를 끄면 이 줄이 사라져 창 높이가 갑자기 줄고,
                //    그 바람에 아래 버튼을 잘못 누르게 된다.
                //    자리는 유지하고 '흐리게 + 반응 없음'으로만 처리한다.
                IgnorePointer(
                  ignoring: !loadCharacters || charCount == 0,
                  child: Opacity(
                    opacity: (loadCharacters && charCount > 0) ? 1.0 : 0.35,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 22),
                      child: row(
                        icon: Icons.playlist_add,
                        label: "기존 뒤에 추가",
                        value: addCharactersAsNew,
                        onChanged: (v) => setDialogState(() => addCharactersAsNew = v),
                      ),
                    ),
                  ),
                ),
                row(
                  icon: Icons.tune,
                  label: "상세 설정",
                  value: loadSettings,
                  onChanged: (v) => setDialogState(() => loadSettings = v),
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
    // '새로 추가하기' 켜짐 → 뒤에 이어 붙인다
    // '새로 추가하기' 꺼짐 → 1번부터 덮어쓴다 (나머지는 그대로 둔다)
    final int startIndex = addCharactersAsNew ? state.characters.length : 0;

    for (int i = 0; i < meta.characterPrompts.length; i++) {
      final int slot = startIndex + i;
      final String positive = meta.characterPrompts[i];
      final String negative = i < meta.characterUndesiredContents.length
          ? meta.characterUndesiredContents[i]
          : "";

      // 덮어쓸 자리가 있으면 그 캐릭터의 내용만 바꾼다.
      //  (이름·색 같은 사용자 설정은 최대한 살린다)
      if (slot < state.characters.length) {
        final ch = state.characters[slot];
        ch.positive = positive;
        ch.negative = negative;
        ch.isActive = true; // 덮어쓴 자리는 켜 둔다
        if (i < meta.characterCenters.length) {
          final c = meta.characterCenters[i];
          if (c.length >= 2) {
            ch.setPosition(c[0], c[1]);
          }
        }
      } else {
        // 자리가 모자라면 새로 만든다
        final ch = NaiCharacter(name: "캐릭터 ${slot + 1}", positive: positive, negative: negative);
        if (i < meta.characterCenters.length) {
          final c = meta.characterCenters[i];
          if (c.length >= 2) {
            ch.setPosition(c[0], c[1]);
          }
        }
        state.characters.add(ch);
      }
    }

    // 선택 인덱스가 범위를 벗어나지 않게 보정
    if (state.selectedCharIndex >= state.characters.length) {
      state.selectedCharIndex = state.characters.isEmpty ? 0 : state.characters.length - 1;
    }

    applied.add(
      addCharactersAsNew
          ? "캐릭터 ${meta.characterPrompts.length}개 추가"
          : "캐릭터 ${meta.characterPrompts.length}개 덮어쓰기",
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
      // 해상도 '값'만 넣고 모드(수동/랜덤/자동)는 사용자가 고른 것을 유지한다.
      // 예전에는 여기서 무조건 "수동"으로 바꿔버려 랜덤/자동 설정이 풀렸다.
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
        backgroundColor: AppColors.surface,
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
                        fillColor: AppColors.background,
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
                        fillColor: AppColors.background,
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
                        // 64px 정렬 + 모델별 픽셀 상한 (공용 헬퍼)
                        final (aw, ah) = clampResolution(
                          w,
                          h,
                          modelCapsFor(state.selectedModel).maxPixels,
                        );
                        final res = "$aw x $ah";
                        final adjusted = (aw != w || ah != h);
                        final warning = (aw * ah > AppState.kMegapixelCap) ? " (Anlas 소모)" : "";
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
                      backgroundColor: AppColors.purple,
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
                  final consumesAnlas = pixels > AppState.kMegapixelCap;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: state.selectedResolution == res
                          ? AppColors.purple.withValues(alpha: 0.1)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: state.selectedResolution == res
                            ? AppColors.purple.withValues(alpha: 0.4)
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
  ).then((_) {
    // 다이얼로그가 완전히 닫힌 뒤에 정리 (닫히는 중에 버리면 예외가 난다)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      wCtrl.dispose();
      hCtrl.dispose();
    });
  });
}
