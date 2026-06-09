// lib/utils/prompt_utils.dart
// 프롬프트 입력 관련 공유 유틸리티

import 'dart:math';
import 'package:flutter/widgets.dart';

class PromptUtils {
  // ============================================================================
  // 자동완성 태그 삽입 유틸리티 (모든 탭에서 공유)
  // ============================================================================
  static String buildCompletedText(String beforeCursor, String tag) {
    int lastComma = beforeCursor.lastIndexOf(',');
    int lastColon = beforeCursor.lastIndexOf(':');
    int lastNewline = beforeCursor.lastIndexOf('\n');
    int lastCloseParen = beforeCursor.lastIndexOf(')');
    int lastOpenParen = max(
      beforeCursor.lastIndexOf('('),
      max(beforeCursor.lastIndexOf('{'), beforeCursor.lastIndexOf('|')),
    );
    int lastParen = max(lastCloseParen, lastOpenParen);
    int lastDelimiter = max(lastComma, max(lastColon, max(lastNewline, lastParen)));

    if (lastDelimiter == -1) {
      return "$tag, ";
    }

    String delimiterStr = beforeCursor.substring(lastDelimiter, lastDelimiter + 1);

    if (delimiterStr == ':') {
      // 특수 접두사(artist:, rating: 등) 처리:
      // "2::artist:" 처럼 가중치 구문 안에 특수 접두사가 있는 경우,
      // 접두사의 ':'가 아니라 그 앞의 '::' 가중치를 인식해야 한다.
      const specialPrefixes = ['artist:', 'rating:', 'character:', 'copyright:', 'meta:'];
      String beforePrefix = beforeCursor.substring(0, lastDelimiter + 1); // ':' 포함
      String? matchedPrefix;
      for (final p in specialPrefixes) {
        if (beforePrefix.endsWith(p)) {
          matchedPrefix = p;
          break;
        }
      }

      if (matchedPrefix != null) {
        // 특수 접두사 앞에 '::' 가중치가 열려있는지 확인
        int prefixStart = lastDelimiter + 1 - matchedPrefix.length;
        bool weightOpen =
            prefixStart >= 2 &&
            beforeCursor[prefixStart - 1] == ':' &&
            beforeCursor[prefixStart - 2] == ':' &&
            (prefixStart < 3 || beforeCursor[prefixStart - 3] != ':');
        if (weightOpen) {
          // 2::artist:작가명 → 2::artist:작가명 ::,
          return "$beforeCursor$tag ::, ";
        } else {
          // 그냥 artist:작가명 → artist:작가명,
          return "$beforeCursor$tag, ";
        }
      }

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
    } else if (delimiterStr == '{') {
      // {A|B} 구문: { 뒤에 태그만 넣고 쉼표 안 붙임
      return "${beforeCursor.substring(0, lastDelimiter)}{$tag";
    } else if (delimiterStr == '|') {
      // {A|B} 구문의 | 뒤: 태그만 넣고 쉼표 안 붙임
      return "${beforeCursor.substring(0, lastDelimiter)}|$tag";
    } else if (delimiterStr == ')') {
      return "${beforeCursor.substring(0, lastDelimiter)}) $tag, ";
    } else {
      return "${beforeCursor.substring(0, lastDelimiter)}, $tag, ";
    }
  }

  // 자동완성 삽입 시, 커서 뒤(afterCursor)가 쉼표/공백으로 시작하면
  // 중복 쉼표가 생기지 않도록 앞쪽 쉼표·공백을 제거한다.
  // 단, newBefore가 이미 ", "로 끝날 때만 정리 (쉼표 안 붙는 구문 ( { | 는 보존).
  static String trimAfterCursor(String newBefore, String afterCursor) {
    if (!newBefore.endsWith(', ')) {
      return afterCursor;
    }
    // afterCursor 앞쪽의 공백 + 쉼표 + 공백 패턴 제거
    // 예: ", red eyes" → "red eyes",  " , red eyes" → "red eyes"
    return afterCursor.replaceFirst(RegExp(r'^\s*,\s*'), '');
  }

  // 자동완성 태그를 컨트롤러에 삽입 (커서 위치 기준, 중복 쉼표 정리 포함)
  // 모든 탭의 insertTag에서 공유. UI 갱신(setState 등)은 호출 측에서 처리.
  static void applyTagToController(TextEditingController controller, String tag) {
    String text = controller.text;
    int cursor = controller.selection.baseOffset;
    if (cursor < 0) {
      cursor = text.length;
    }

    String beforeCursor = text.substring(0, cursor);
    String afterCursor = text.substring(cursor);
    String newBefore = buildCompletedText(beforeCursor, tag);
    afterCursor = trimAfterCursor(newBefore, afterCursor);

    controller.value = TextEditingValue(
      text: newBefore + afterCursor,
      selection: TextSelection.collapsed(offset: newBefore.length),
    );
  }
}
