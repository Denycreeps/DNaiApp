// lib/widgets/preset_save_dialog.dart
//
// 프리셋 저장 다이얼로그.
//  AppState를 인자로 받으므로 models가 아니라 widgets에 둔다
//  (models가 위젯을 import하면 순환이 생긴다).
import 'package:flutter/material.dart';

import '../models/app_state.dart';
import '../models/nai_character.dart';
import '../models/preset_models.dart';
import '../app_theme.dart';

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
          backgroundColor: AppColors.surface,
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
                    fillColor: AppColors.background,
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
                    Expanded(child: fieldChip('positive', '긍정적', AppColors.teal)),
                    const SizedBox(width: 8),
                    Expanded(child: fieldChip('negative', '부정적', AppColors.red)),
                  ],
                ),
                if (allowPrefixSuffix) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: fieldChip('prefix', '선행', AppColors.blue)),
                      const SizedBox(width: 8),
                      Expanded(child: fieldChip('suffix', '후행', AppColors.orange)),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: fieldChip('characters', '캐릭터', AppColors.accent)),
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
                                    ? AppColors.accent.withValues(alpha: 0.1)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected
                                      ? AppColors.accent.withValues(alpha: 0.4)
                                      : Colors.white10,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isSelected ? Icons.check_circle : Icons.circle_outlined,
                                    size: 16,
                                    color: isSelected ? AppColors.accent : Colors.white38,
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
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
              child: const Text(
                "저장",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    ),
  ).then((_) {
    // 다이얼로그가 완전히 닫힌 뒤에 정리 (닫히는 중에 버리면 예외가 난다)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameCtrl.dispose();
    });
  });
}
