// lib/widgets/confirm_dialog.dart
//
// "정말 하시겠습니까?" 확인 다이얼로그.
//
// 예전에는 같은 모양을 16곳에서 각자 만들어 두고 있었다.
// 그러다 보니 라운드 모서리가 있는 것과 없는 것, 아이콘이 있는 것과 없는 것,
// 실행 버튼이 ElevatedButton 인 곳과 TextButton 인 곳이 뒤섞였다.
// 같은 '삭제 확인'인데 화면마다 다르게 보이던 이유다.
import 'package:flutter/material.dart';

import '../app_theme.dart';

/// 확인 다이얼로그를 띄우고 사용자가 실행을 눌렀는지 돌려준다.
///
/// 취소하거나 바깥을 눌러 닫으면 `false`.
///
/// 호출 쪽에서 결과를 받아 처리하므로, 버튼 안에서 무슨 일을 하든
/// (setState, 비동기 작업, 화면 이동) 이 함수는 신경 쓰지 않는다.
///
/// ```dart
/// final ok = await showConfirmDialog(
///   context,
///   title: "이미지 삭제",
///   message: "이 이미지를 삭제할까요?",
///   confirmLabel: "삭제",
///   icon: Icons.delete_outline,
/// );
/// if (!ok || !context.mounted) return;
/// ...
/// ```
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,

  /// 실행 버튼 글자. 기본은 "확인".
  String confirmLabel = "확인",

  /// 취소 버튼 글자.
  String cancelLabel = "취소",

  /// 제목 왼쪽 아이콘. 없으면 제목만 표시한다.
  IconData? icon,

  /// 아이콘 색. 지정하지 않으면 [destructive] 여부에 따라 정해진다.
  Color? iconColor,

  /// 되돌릴 수 없는 작업인가. true면 실행 버튼이 빨간색이 된다.
  bool destructive = true,

  /// 실행 버튼 배경색을 직접 지정하고 싶을 때.
  Color? confirmColor,
}) async {
  final Color accent =
      confirmColor ?? (destructive ? Colors.redAccent : AppColors.accent);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: icon == null
          ? Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            )
          : Row(
              children: [
                Icon(icon, color: iconColor ?? accent, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
      content: Text(
        message,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 14,
          height: 1.4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel, style: const TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            confirmLabel,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}
