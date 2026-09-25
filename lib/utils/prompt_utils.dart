// lib/utils/prompt_utils.dart
// 프롬프트 입력 관련 공유 유틸리티

import 'dart:math';
import 'package:flutter/widgets.dart';

// † 접두어 = 보조 매칭 결과 (UI에서 연한 스타일로 구분)
//  app_state.dart 가 이 이름을 다시 내보내므로 기존 호출부는 그대로 쓸 수 있다.
const String kContainsMarker = '* ';

// [limit] 한 번에 돌려줄 제안 개수.
//  같은 접두어를 가진 태그가 20~30개인 경우가 흔해 15는 너무 빡빡했다.
//  목록이 가상화(ListView.builder)되어 있어 개수를 늘려도 그린 만큼만 비용이 든다.
List<String> smartMatchTags(List<String> tags, String query, {int limit = 40}) {
  // 트레일링 스페이스 감지 (trim 전에!)
  final hasTrailingSpace = query.endsWith(' ');
  final lower = query.toLowerCase().trim();
  if (lower.isEmpty) {
    return [];
  }

  // "artist:" 특별 처리: artist의 앞부분("a"~"artist")으로 시작하면 맨 앞에 끼워넣기
  // (artist name 태그는 거의 안 쓰므로 artist: 접두사를 최우선 노출)
  String? artistPrefix;
  if (!lower.contains(':') && "artist".startsWith(lower)) {
    artistPrefix = 'artist:';
  }

  final fragments = lower.split(RegExp(r'\s+'));

  // 다중 조각 ("ca t", "lo a v" 등): 스마트 단어 매칭
  if (fragments.length > 1) {
    return _multiWordMatch(tags, fragments, limit);
  }

  // artist: 끼워넣기 헬퍼 (중복 방지, 맨 앞 배치)
  List<String> withArtist(List<String> results) {
    final prefix = artistPrefix;
    if (prefix == null) {
      return results;
    }
    final filtered = results.where((t) => t != prefix).toList();
    return [prefix, ...filtered].take(limit).toList();
  }

  // ======================================================================
  // 단일 조각
  // ======================================================================

  // 🔒 트레일링 스페이스 = "확정 모드": startsWith만 → 없으면 contains fallback
  if (hasTrailingSpace) {
    final startsResults = tags
        .where((t) => t.toLowerCase().startsWith(lower))
        .take(limit)
        .toList();
    if (startsResults.isNotEmpty) {
      return withArtist(startsResults);
    }
    // startsWith 결과 없음 → contains fallback (연한 스타일)
    return withArtist(
      tags
          .where((t) => t.toLowerCase().contains(lower))
          .take(limit)
          .map((t) => '$kContainsMarker$t')
          .toList(),
    );
  }

  // 1~2글자: startsWith만 (contains는 노이즈 너무 많음)
  if (lower.length <= 2) {
    return withArtist(
      tags.where((t) => t.toLowerCase().startsWith(lower)).take(limit).toList(),
    );
  }

  // 3글자+, 스페이스 없음: 단어경계 우선 + 중간매칭 후순위
  final wordBoundaryResults = <String>[];
  final midWordResults = <String>[];

  for (final tag in tags) {
    final tagLower = tag.toLowerCase();
    if (tagLower.startsWith(lower)) {
      // 태그 자체가 쿼리로 시작 (최우선)
      wordBoundaryResults.add(tag);
    } else if (tagLower.split(' ').any((w) => w.startsWith(lower))) {
      // 태그 안의 단어가 쿼리로 시작 (단어 경계 매칭)
      wordBoundaryResults.add(tag);
    } else if (tagLower.contains(lower)) {
      // 단어 중간에 포함 (최후순위)
      midWordResults.add(tag);
    }
    if (wordBoundaryResults.length >= limit && midWordResults.length >= limit) {
      break;
    }
  }

  // 점진적 할당: 쿼리가 길수록 midWord 비중 증가
  final wordSlots = (wordBoundaryResults.length < limit - 3)
      ? wordBoundaryResults.length
      : max<int>(limit - lower.length, 5).clamp(0, limit);
  final midSlots = limit - min<int>(wordBoundaryResults.length, wordSlots);

  return withArtist([
    ...wordBoundaryResults.take(wordSlots),
    ...midWordResults.take(midSlots).map((t) => '$kContainsMarker$t'),
  ]);
}

List<String> _multiWordMatch(
  List<String> tags,
  List<String> fragments,
  int limit,
) {
  final first = fragments.first;
  final rest = fragments.sublist(1);

  return tags
      .where((tag) {
        final tagLower = tag.toLowerCase();
        if (!tagLower.startsWith(first)) {
          return false;
        }

        final words = tagLower.split(RegExp(r'[_ ]'));
        int wordIdx = 1;
        for (final frag in rest) {
          bool found = false;
          while (wordIdx < words.length) {
            if (words[wordIdx].startsWith(frag)) {
              wordIdx++;
              found = true;
              break;
            }
            wordIdx++;
          }
          if (!found) {
            return false;
          }
        }
        return true;
      })
      .take(limit)
      .toList();
}

/// 자동완성에서 '지금 입력 중인 단어'를 잘라낼 때 쓰는 구분자.
///
/// ⚠️ '(' 와 ')' 는 일부러 넣지 않는다.
///    태그 이름 자체에 괄호가 들어가기 때문이다(예: "artist:test (te").
///    괄호를 구분자로 보면 자동완성이 끊기거나 겹쳐 붙는다.
///    NovelAI 강조 문법은 {} / [] 라 영향이 없다.
///    (buildCompletedText 의 _lastSyntaxOpenParen 과 같은 판단이다 — 둘이 어긋나면
///     "찾을 때는 괄호에서 끊고 넣을 때는 안 끊는" 상태가 되어 결과가 깨진다)
const List<String> kWordDelimiters = [',', ':', '\n', '{', '|'];

class PromptUtils {
  // ============================================================================
  // 확대 입력창(프롬프트 편집 다이얼로그) 공용 스타일
  //   prompt_tab / i2i_tab / character_tab 의 확대 입력 다이얼로그가 공유.
  //   ※ 껍데기(여백·폰트)만 공용화하고, 자동완성/저장 로직은 각 탭이 그대로 유지.
  // ============================================================================

  /// 확대 입력 다이얼로그의 좌우/상하 여백 (Dialog.insetPadding)
  static const EdgeInsets promptEditorDialogInsets = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 24,
  );

  /// 확대 입력창 TextField 텍스트 스타일.
  /// [fontSize]에는 AppState.promptEditorFontSize 값을 그대로 넘긴다.
  /// (AppState를 직접 참조하지 않아 순환 import를 피함)
  static TextStyle promptEditorTextStyle(double fontSize) {
    return TextStyle(
      color: const Color(0xFFFFFFFF),
      height: 1.5,
      fontSize: fontSize,
    );
  }

  // ============================================================================
  // 자동완성 후보 만들기 (프롬프트탭 / 확대 입력창 / 와일드카드탭 공유)
  //   화면 모양은 탭마다 다르지만(세로 목록 vs 가로 칩) '무엇을 보여줄지'는 같다.
  //   예전에는 세 곳이 같은 코드를 복붙해 두고 있어서, 개수를 바꾸거나 구분자를
  //   손볼 때마다 세 군데를 따로 고쳐야 했다.
  // ============================================================================

  /// 커서 앞에서 '지금 입력 중인 단어'를 잘라낸다.
  ///  구분자(kWordDelimiters) 뒤부터 커서까지가 입력 중인 단어다.
  static String currentWordBefore(String text, int cursor) {
    if (cursor < 0 || cursor > text.length) {
      cursor = text.length;
    }
    final beforeCursor = text.substring(0, cursor);
    int lastDelimiter = -1;
    for (final d in kWordDelimiters) {
      final i = beforeCursor.lastIndexOf(d);
      if (i > lastDelimiter) {
        lastDelimiter = i;
      }
    }
    final word = lastDelimiter == -1
        ? beforeCursor
        : beforeCursor.substring(lastDelimiter + 1);
    return word.trimLeft();
  }

  /// 입력 중인 단어에 맞는 자동완성 후보.
  ///  · "__" 로 시작하면 와일드카드 이름 목록
  ///  · 그 밖에는 태그 매칭(smartMatchTags)
  ///  단어가 비어 있으면 빈 목록을 돌려준다(후보를 지우라는 뜻).
  ///
  ///  AppState를 인자로 받지 않는다 — 순환 import를 피하기 위함이며,
  ///  덕분에 이 함수만 따로 테스트할 수 있다.
  static List<String> suggestionsFor({
    required String currentWord,
    required List<String> tags,
    required List<String> wildcardNames,
    int limit = 40,
  }) {
    if (currentWord.isEmpty) {
      return const [];
    }
    if (currentWord.startsWith('__')) {
      final searchWord = currentWord.replaceAll('__', '').toLowerCase();
      return wildcardNames
          .where((n) => n.toLowerCase().startsWith(searchWord))
          .map((n) => '__${n}__')
          .take(15) // 사용자가 직접 만든 목록이라 15개면 충분하다
          .toList();
    }
    return smartMatchTags(tags, currentWord, limit: limit);
  }

  // ============================================================================
  // 자동완성 태그 삽입 유틸리티 (모든 탭에서 공유)
  // ============================================================================
  // 태그명에 포함된 '(' 는 구분자가 아니다.
  //  예: "artist:test (te" 에서 '(' 를 구분자로 보면 자동완성이 겹쳐 붙는다
  //      ("test (test (test)"). 앞에 공백이 있는 '(' 는 태그명의 일부로 간주하고 건너뛴다.
  //  반면 "{a|b" 나 "b(c" 처럼 문법/연결로 쓰인 괄호는 구분자로 인정한다.
  static int _lastSyntaxOpenParen(String text) {
    int i = text.lastIndexOf('(');
    while (i > 0) {
      if (text[i - 1] == ' ') {
        i = text.lastIndexOf('(', i - 1);
      } else {
        return i;
      }
    }
    return i;
  }

  static String buildCompletedText(String beforeCursor, String tag) {
    // 특별 처리: 선택한 태그가 'artist:' 같은 접두사 자체면
    // 뒤에 작가명을 이어 입력해야 하므로 쉼표/공백/:: 없이 그대로 끝낸다.
    // (예: "2::" 뒤에서 artist: 선택 → "2::artist:" 로 끝)
    const prefixOnlyTags = {
      'artist:',
      'rating:',
      'character:',
      'copyright:',
      'meta:',
    };
    if (prefixOnlyTags.contains(tag)) {
      // 커서 앞의 마지막 구분자 다음부터(타이핑 중이던 부분)를 잘라내고 접두사로 교체
      int lastComma = beforeCursor.lastIndexOf(',');
      int lastNewline = beforeCursor.lastIndexOf('\n');
      int lastColon = beforeCursor.lastIndexOf(':');
      int lastOpen = max(
        _lastSyntaxOpenParen(beforeCursor),
        max(beforeCursor.lastIndexOf('{'), beforeCursor.lastIndexOf('|')),
      );
      int cut = max(lastComma, max(lastNewline, max(lastColon, lastOpen)));
      String head = cut == -1 ? "" : beforeCursor.substring(0, cut + 1);
      // head가 ',' 로 끝나면 공백 하나 붙여 정리 (", " 형태), ':'/'(' 등은 그대로
      if (head.endsWith(',')) {
        head = "$head ";
      }
      return "$head$tag";
    }

    int lastComma = beforeCursor.lastIndexOf(',');
    int lastColon = beforeCursor.lastIndexOf(':');
    int lastNewline = beforeCursor.lastIndexOf('\n');
    // 닫는 ')' 도 태그명 끝일 수 있으나, 그 뒤에 새 태그를 쓰는 상황이므로 구분자로 둔다
    int lastCloseParen = beforeCursor.lastIndexOf(')');
    int lastOpenParen = max(
      _lastSyntaxOpenParen(beforeCursor),
      max(beforeCursor.lastIndexOf('{'), beforeCursor.lastIndexOf('|')),
    );
    int lastParen = max(lastCloseParen, lastOpenParen);
    int lastDelimiter = max(
      lastComma,
      max(lastColon, max(lastNewline, lastParen)),
    );

    if (lastDelimiter == -1) {
      return "$tag, ";
    }

    String delimiterStr = beforeCursor.substring(
      lastDelimiter,
      lastDelimiter + 1,
    );

    if (delimiterStr == ':') {
      // 특수 접두사(artist:, rating: 등) 처리:
      // "2::artist:" 처럼 가중치 구문 안에 특수 접두사가 있는 경우,
      // 접두사의 ':'가 아니라 그 앞의 '::' 가중치를 인식해야 한다.
      const specialPrefixes = [
        'artist:',
        'rating:',
        'character:',
        'copyright:',
        'meta:',
      ];
      String beforePrefix = beforeCursor.substring(
        0,
        lastDelimiter + 1,
      ); // ':' 포함
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
        // 접두사까지(artist: 포함)만 남기고, 그 뒤 타이핑 중이던 부분은 버린다.
        // 예: "artist:lk" + tag "lk149" → "artist:" + "lk149"
        String head = beforeCursor.substring(
          0,
          lastDelimiter + 1,
        ); // "...artist:"
        if (weightOpen) {
          // 2::artist:lk → 2::artist:lk149 ::,
          return "$head$tag ::, ";
        } else {
          // artist:lk → artist:lk149,
          return "$head$tag, ";
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
    // afterCursor 앞쪽 정리:
    // - 쉼표가 있으면: 공백+쉼표+공백 제거 (", red" → "red", 중복 쉼표 방지)
    // - 쉼표가 없으면: 선행 공백만 제거 (" red" → "red", 공백 2개 방지)
    if (RegExp(r'^\s*,').hasMatch(afterCursor)) {
      return afterCursor.replaceFirst(RegExp(r'^\s*,\s*'), '');
    }
    return afterCursor.replaceFirst(RegExp(r'^\s+'), '');
  }

  // 자동완성 제안의 표시용 텍스트 (contains 마커 '* ' 제거 + 언더스코어를 공백으로)
  // 미리보기에도 'long hair'처럼 보여서 실제 삽입 결과와 일치시킨다.
  // 단, 와일드카드(__name__)는 _ 가 문법이므로 변환하지 않는다.
  static String displayTag(String rawTag) {
    final stripped = rawTag.replaceFirst(RegExp(r'^\* '), '');
    if (stripped.startsWith('__') && stripped.endsWith('__')) {
      return stripped;
    }
    return stripped.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ');
  }

  // 자동완성 태그를 컨트롤러에 삽입 (커서 위치 기준, 중복 쉼표 정리 포함)
  // 모든 탭의 insertTag에서 공유. UI 갱신(setState 등)은 호출 측에서 처리.
  static void applyTagToController(
    TextEditingController controller,
    String rawTag,
  ) {
    // contains 마커(연한 표시용 '* ' 접두) 제거 → 순수 태그만 삽입
    // (app_state.dart의 kContainsMarker와 동일 값. 순환 import 방지 위해 로컬 정의)
    String tag = rawTag.replaceFirst(RegExp(r'^\* '), '');
    // Danbooru/e621 태그는 'long_hair' → NovelAI 'long hair' (언더스코어를 공백으로).
    // 단, 와일드카드(__name__)는 _ 가 문법이므로 변환하지 않는다.
    if (!(tag.startsWith('__') && tag.endsWith('__'))) {
      tag = tag.replaceAll('_', ' ');
      tag = tag.replaceAll(RegExp(r'\s+'), ' '); // 연속 공백 → 1개 (희귀한 __ 태그 방어)
    }
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
