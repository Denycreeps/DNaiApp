// lib/widgets/custom_cards.dart
import 'package:flutter/material.dart';

// 1. 공통 프롬프트 입력 카드 (긍정, 부정 등)
class CustomPromptCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final TextEditingController controller;
  final VoidCallback onTap;

  const CustomPromptCard({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.controller,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: color, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        title,
                        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ],
                  ),
                  Icon(Icons.edit, color: color, size: 18),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                controller.text.isEmpty ? "$title을(를) 입력하세요..." : controller.text,
                style: TextStyle(
                  color: controller.text.isEmpty ? Colors.white30 : Colors.white,
                  fontSize: 14,
                  height: 1.5,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 2. 공통 스위치 버튼 (의상 제거, 캐릭터 특징 제거 등)
class CustomFilterSwitch extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const CustomFilterSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.deepPurpleAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_fix_high, color: Colors.deepPurpleAccent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Switch(value: value, onChanged: onChanged, activeThumbColor: Colors.deepPurpleAccent),
        ],
      ),
    );
  }
}
