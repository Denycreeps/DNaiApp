// lib/utils/prompt_utils.dart
// 프롬프트 입력 관련 공유 유틸리티

import 'dart:math';

class PromptUtils {
  // ============================================================================
  // 자동완성 태그 삽입 유틸리티 (모든 탭에서 공유)
  // ============================================================================
  static String buildCompletedText(String beforeCursor, String tag) {
    int lastComma = beforeCursor.lastIndexOf(',');
    int lastColon = beforeCursor.lastIndexOf(':');
    int lastNewline = beforeCursor.lastIndexOf('\n');
    int lastCloseParen = beforeCursor.lastIndexOf(')');
    int lastOpenParen = beforeCursor.lastIndexOf('(');
    int lastParen = max(lastCloseParen, lastOpenParen);
    int lastDelimiter = max(lastComma, max(lastColon, max(lastNewline, lastParen)));

    if (lastDelimiter == -1) {
      return "$tag, ";
    }

    String delimiterStr = beforeCursor.substring(lastDelimiter, lastDelimiter + 1);

    if (delimiterStr == ':') {
      // :: (가중치 구문) 감지: 정확히 2개일 때만
      bool isDoubleColon =
          lastDelimiter > 0 &&
          beforeCursor[lastDelimiter - 1] == ':' &&
          (lastDelimiter < 2 || beforeCursor[lastDelimiter - 2] != ':');
      if (isDoubleColon) {
        return "${beforeCursor.substring(0, lastDelimiter)}:$tag ::, ";
      } else {
        return "${beforeCursor.substring(0, lastDelimiter)}:$tag, ";
      }
    } else if (delimiterStr == '\n') {
      return "${beforeCursor.substring(0, lastDelimiter)}\n$tag, ";
    } else if (delimiterStr == '(') {
      // 조건부 트리거 등: ( 뒤에 태그만 넣고 쉼표 안 붙임
      return "${beforeCursor.substring(0, lastDelimiter)}($tag";
    } else if (delimiterStr == ')') {
      return "${beforeCursor.substring(0, lastDelimiter)}) $tag, ";
    } else {
      return "${beforeCursor.substring(0, lastDelimiter)}, $tag, ";
    }
  }
}
