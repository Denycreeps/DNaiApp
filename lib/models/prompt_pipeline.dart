// lib/models/prompt_pipeline.dart
//
// 프롬프트를 '보낼 모양' 으로 바꾸는 순수 함수들.
//  순차 생성 <<A|B>> · 랜덤 a|b · 와일드카드 __이름__ · 조건부 트리거 ·
//  가중치 표시 정리 · 인원수 앞으로 · 성별 focus 는 긍정 앞으로 · 랜덤 프롬프트 정렬.
//
// 예전엔 전부 AppState 안에 있었다. 화면 · 저장소 · 서버와 무관한 글자 처리라서 여기로 옮겼고,
// 덕분에 앱을 띄우지 않고 테스트할 수 있다 (test/prompt_pipeline_test.dart).
//  · AppState 의 값(와일드카드 목록 · 규칙 글 · 순차 카운터 · 설정)은 인자로 받는다 — 여기서는 AppState 를 모른다.
//  · 랜덤은 [Random] 을 받을 수 있다 (안 주면 공용 Random). 테스트가 결과를 고정할 때 쓴다.
//  · 순차 카운터(Map)는 AppState 가 들고 있고, 여기서는 읽거나(process…) 올린다(advance…).
import 'dart:math';

final Random _random = Random();

// ============================================================================
// 가중치 표시 (N:: … ::)
// ============================================================================
/// 구획(선행 · 긍정 · 후행 등)을 이을 때, 그 경계가 가중치 표시에 닿는지.
///  앞 구획이 여는 표시(1.1::)로 끝나거나 뒤 구획이 닫는 표시(::)로 시작하면 true —
///  이때는 앱이 경계에 넣는 쉼표를 빼고 잇는다 (가중치가 다음 태그에 · 앞 태그에 바로 붙게).
///
///  선행 '1girl, 1.1::'  +  긍정 'shirt, standing'  +  후행 '::, masterpiece'
///   쉼표를 늘 넣으면 : 1girl, 1.1::, shirt, standing, ::, masterpiece
///   경계만 보면     : 1girl, 1.1::shirt, standing::, masterpiece
///
///  [before] · [after] 는 정리(sanitizePrompt)를 마친 앞 · 뒤 구획.
///  ⚠️ 경계만 본다 — 사용자가 구획 '안'에 쓴 쉼표는 절대 건드리지 않는다.
///     예전엔 이은 '전체'에서 '::' 앞뒤 쉼표를 지워(tidyWeightMarkers), 사용자가 쓴
///     '1.2::test, ::' 가 '1.2::test::' 로, '1.2::a, ::b' 는 '1.2::a::b'(두 태그가 붙음)로 바뀌어 나갔다.
///  여는 표시는 NovelAI 문서대로 숫자가 '::' 바로 앞에 붙고, 숫자 앞은 처음 · 쉼표 · 공백일 때만 —
///   'year 2024 ::' 처럼 띄어 쓴 숫자는 닫는 표시로 본다 (잘못 보면 쉼표가 빠져 태그가 붙는다).
bool weightTouchesBoundary(String before, String after) =>
    _openWeightAtEnd.hasMatch(before) || after.trimLeft().startsWith('::');

final RegExp _openWeightAtEnd = RegExp(r'(?:^|[\s,])-?\d+(?:\.\d+)?::\s*$');

/// 중첩된 가중치 구간을 NovelAI 가 실제로 해석하는 방식에 맞춰 펼친다.
///
/// NovelAI 의 `::` 는 '스택'이 아니라 '평면'이다.
/// 숫자 없는 `::` 를 만나면 그 앞의 가중치가 **전부** 끝나고 1.0 으로 돌아간다.
/// 즉 아래 두 줄에서 D 는 5.0 이 아니라 1.0 으로 들어간다.
///
/// ```
/// 5.0::A, B, 1.5::C ::, D ::,      ← D 는 1.0 (사람이 기대하는 것과 다름)
/// 5.0::A, B, 1.5::C ::, 5.0::D ::, ← D 를 5.0 으로 두려면 이렇게 써야 한다
/// ```
///
/// 이 함수는 앞 줄을 뒤 줄로 바꿔 준다. 괄호의 짝을 맞추듯 여는 가중치를
/// 스택에 쌓아 두었다가, 구간이 닫히면 바깥 가중치를 다시 열어 준다.
///
/// 건드리지 않는 경우:
///  · 중첩이 없으면 원문 그대로 (스택이 비면 다시 열 것이 없다)
///  · 닫는 `::` 가 남거나 모자라도 무너지지 않는다
///  · `{}` `[]` 같은 다른 강조 문법과는 무관하다
String expandNestedWeights(String input) {
  if (!input.contains('::')) {
    return input;
  }

  // 여는 표시(1.5::)와 닫는 표시(::)를 모두 찾는다.
  //  여는 쪽은 숫자가 바로 앞에 붙어 있어야 한다.
  final marker = RegExp(r'(-?\d+(?:\.\d+)?)\s*::|::');

  final buf = StringBuffer();
  final stack = <String>[]; // 열려 있는 가중치들 (바깥 → 안쪽)
  int last = 0;
  bool changed = false;

  for (final m in marker.allMatches(input)) {
    buf.write(input.substring(last, m.start));
    final weight = m.group(1);

    if (weight != null) {
      // 여는 표시 — 원문 그대로 두고 스택에 쌓는다
      buf.write(m.group(0));
      stack.add(weight);
      last = m.end;
      continue;
    }

    // 닫는 표시
    buf.write('::');
    last = m.end;
    if (stack.isNotEmpty) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      continue; // 바깥에 남은 가중치가 없으면 되살릴 것도 없다
    }

    // 바깥 가중치를 다시 연다. 구분자(쉼표·공백·줄바꿈)는 그대로 두고
    // 실제 내용이 시작되는 자리 바로 앞에 끼워 넣는다.
    int p = last;
    while (p < input.length && (input[p] == ',' || _isSpace(input[p]))) {
      p++;
    }
    // 뒤에 내용이 없거나 곧바로 또 닫는다면 넣을 필요가 없다
    if (p >= input.length || input.startsWith('::', p)) {
      continue;
    }
    buf.write(input.substring(last, p));
    buf.write('${stack.last}::');
    last = p;
    changed = true;
  }

  buf.write(input.substring(last));
  return changed ? buf.toString() : input;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

// ============================================================================
// 인원수 · solo 는 맨 앞으로 · 성별 focus 는 긍정 앞으로 · 랜덤 프롬프트 정렬
// ============================================================================
/// 인원수(1girl · 2boys · 1other …)와 solo 를 프롬프트 '맨 앞'으로 옮긴다.
///
/// NovelAI 는 인원수를 모든 프롬프트의 맨 앞에 두기를 권장한다.
/// 예전엔 그 자리를 지키려고 선행 프롬프트를 계속 고쳐야 했는데,
/// 이제 긍정·선행·후행 어디에 써도 보낼 때 알아서 맨 앞으로 모은다.
///
///  'masterpiece, smile, 1girl, solo'  →  '1girl, solo, masterpiece, smile'
///
/// 성별 focus(male focus 등)는 여기서 옮기지 않는다 — 구획을 잇기 전에
/// [moveGenderFocusToPositive] 가 '긍정' 맨 앞으로 모은다 (선행 앞으로 끼어들지 않게).
///  ⚠️ 예전엔 focus 도 함께 맨 앞으로 옮겨서 'female focus' 가 선행(화풍 · 작가)보다 앞에 붙었다.
///
/// 건드리지 않는 경우:
///  · 가중치 구간 안의 태그 (5.0::1girl, smile :: 처럼) — 빼 내면 가중치가 바뀐다
///  · 괄호로 강조한 태그 ({1girl}) — 사용자가 일부러 꾸민 것
///  · 'NovelAI 권장 순서 무시' 가 켜져 있을 때 (AppState 가 이 함수를 부르지 않는다)
///
/// 같은 태그가 여러 번 나오면 하나만 남긴다.
/// 입력창 내용은 바꾸지 않는다 — 보내는 프롬프트에만 적용된다.
String hoistCountTags(String text) {
  if (text.trim().isEmpty) {
    return text;
  }
  final p = _TagPuller(_countGroup, 2);
  final rest = p.pull(text);
  final head = [...p.groups[0], ...p.groups[1]].join(', '); // 인원수 → solo 순서
  if (head.isEmpty) {
    return text; // 옮길 것이 없으면 원문 그대로 (서식을 건드리지 않는다)
  }
  return _prependHead(head, rest);
}

/// 성별 focus(solo focus · male focus · other focus · female focus)를 '긍정' 프롬프트 맨 앞으로 모은다.
///  선행 · 후행에 있어도 옮긴다. 구획을 잇기 '전에' 부른다 (이은 뒤엔 어디까지가 긍정인지 모른다).
///  인원수 · solo 는 이은 뒤 [hoistCountTags] 가 맨 앞으로 옮기므로, 보내는 순서는
///   '1girl, solo, (선행), female focus, (긍정 나머지), (후행)' 이 된다.
///  가중치 구간 안 · 괄호 강조는 건드리지 않는다 (선행 끝에서 연 가중치가 긍정까지 걸린 것도 알아본다).
///  같은 태그는 하나만 남긴다. 옮길 것이 없으면 세 구획 모두 원문 그대로.
({String prefix, String positive, String suffix}) moveGenderFocusToPositive(
  String prefix,
  String positive,
  String suffix,
) {
  final p = _TagPuller(_genderFocusGroup, 1, keepTrailingBreak: true);
  final pre = p.pull(prefix);
  final pos = p.pull(positive);
  final suf = p.pull(suffix);
  final head = p.groups[0].join(', ');
  if (head.isEmpty) {
    return (prefix: prefix, positive: positive, suffix: suffix);
  }
  return (prefix: pre, positive: _prependHead(head, pos), suffix: suf);
}

// 인원수 → 0 · solo → 1 · 그 밖 → -1 (hoistCountTags)
int _countGroup(String low) {
  if (_personTag.hasMatch(low) || _multiplePersonTags.contains(low)) {
    return 0;
  }
  return low == 'solo' ? 1 : -1;
}

// 성별 focus → 0 · 그 밖 → -1 (moveGenderFocusToPositive)
int _genderFocusGroup(String low) => _genderFocusTags.contains(low) ? 0 : -1;

/// 쉼표 조각을 차례로 훑어 고른 태그를 빼 낸다 (인원수 앞으로 · focus 옮기기 공용).
///  · 꾸밈 없는 맨 태그만 — 가중치 구간 안(N:: … ::) · 가중치 표시가 든 조각 · 괄호 강조({} [])는 그대로 둔다.
///  · 같은 태그는 처음 것만 [groups] 에 담고, 뒤에 또 나오면 빼기만 한다.
///  · 여러 구획을 차례로 [pull] 하면 가중치 구간 상태가 이어진다.
class _TagPuller {
  _TagPuller(this._group, int groupCount, {this.keepTrailingBreak = false})
    : groups = List.generate(groupCount, (_) => <String>[]);

  /// 소문자 태그 → 담을 묶음 번호 (-1 이면 그대로 둔다)
  final int Function(String low) _group;

  /// 묶음마다 뺀 태그 (나온 순서대로)
  final List<List<String>> groups;

  /// 맨 끝에서 뺀 조각의 줄바꿈을 남길지 — 구획 단위로 뺄 때 쓴다
  ///  (구획을 이을 때 구획 끝의 줄바꿈을 보고 줄을 나누므로, 지우면 줄이 붙는다)
  final bool keepTrailingBreak;

  final Set<String> _seen = {};

  // NovelAI 의 가중치는 '평면'이다: N:: 로 열리고 숫자 없는 :: 에서 전부 닫힌다
  bool _inWeight = false;

  /// [text] 에서 고른 태그를 뺀 나머지. 뺀 것이 없으면 원문 그대로.
  String pull(String text) {
    final rest = <String>[];
    bool removed = false;
    // 뺀 조각이 줄 첫머리였으면 그 줄바꿈을 다음 조각이 이어받는다 (줄 구성 유지)
    //  'tags,⏎⏎1girl, 자연어' → '1girl, tags,⏎⏎자연어'  (예전엔 'tags, 자연어' 로 붙었다)
    String carry = '';
    for (final piece in text.split(',')) {
      final core = piece.trim();
      final low = core.toLowerCase();
      final plain = core.isNotEmpty && !piece.contains('::') && !core.contains(_emphasisBrackets);
      final group = plain && !_inWeight ? _group(low) : -1;

      if (group >= 0) {
        removed = true;
        if (_seen.add(low)) {
          groups[group].add(core);
        }
        // 원래 자리에서는 뺀다 (중복도 함께 사라진다)
        final lead = _leadingSpace.firstMatch(piece)?[0] ?? '';
        if (lead.contains('\n')) {
          carry = lead;
        }
      } else if (carry.isNotEmpty) {
        rest.add(piece.replaceFirst(_leadingSpace, carry));
        carry = '';
      } else {
        rest.add(piece);
      }
      // 이 조각이 가중치 구간을 열거나 닫는지 반영
      for (final m in _weightMarkerAny.allMatches(piece)) {
        _inWeight = m.group(1) != null;
      }
    }
    if (!removed) {
      return text;
    }
    if (keepTrailingBreak && carry.isNotEmpty) {
      rest.add(carry);
    }
    return rest.join(',');
  }
}

// [head] 를 [rest] 앞에 ', ' 로 붙인다. 앞에서 뺀 자리에 남은 쉼표 · 공백은 정리하되,
//  줄바꿈이 있었으면 줄은 그대로 나눈다.
//  '1girl, solo,⏎⏎자연어' → '1girl, solo,⏎⏎자연어'  (예전엔 '1girl, solo, 자연어' 로 붙었다)
String _prependHead(String head, String rest) {
  final String blank = _leadingBlankRun.firstMatch(rest)?[0] ?? '';
  final String tail = rest.replaceFirst(_leadingBlankRun, '');
  if (tail.isEmpty) {
    return head;
  }
  final int breaks = '\n'.allMatches(blank).length;
  return breaks > 0 ? '$head,${'\n' * breaks}$tail' : '$head, $tail';
}

// 가중치 표시 — 여는 'N::' (group 1 = 숫자) 또는 닫는 '::'
final RegExp _weightMarkerAny = RegExp(r'(-?\d+(?:\.\d+)?)\s*::|::');
final RegExp _emphasisBrackets = RegExp(r'[{}\[\]]');

final RegExp _leadingSpace = RegExp(r'^\s*');
final RegExp _leadingBlankRun = RegExp(r'^[\s,]+');

final RegExp _personTag = RegExp(r'^\d+\+?\s?(girl|girls|boy|boys|other|others)$');
const Set<String> _multiplePersonTags = {
  'multiple girls',
  'multiple boys',
  'multiple others',
};

// ── 정렬에 쓰는 태그 묶음 (보낼 때 hoistCountTags · 랜덤 정렬 sortNovelAIPrompt 공용) ──

/// 성별 focus — "누가 주인공인가".
///  랜덤 프롬프트 정렬에선 solo 바로 뒤에 두고, 보낼 때는 '긍정' 맨 앞으로 모은다 (선행 뒤 — moveGenderFocusToPositive).
///  단보루는 solo focus · male focus · other focus 를 인원수 묶음(tag group:character count)으로 다루고
///  '1boy, solo, male focus' 처럼 붙여 쓴다. (female focus 는 단보루엔 없지만 쓰는 사람이 있어 같이 묶는다)
const Set<String> _genderFocusTags = {
  'solo focus',
  'male focus',
  'other focus',
  'female focus',
};

/// 구도(framing) — NovelAI 공식 튜토리얼 목록 (보이는 범위가 넓어지는 순).
///  공식 예시가 '1girl, solo, full body, …' 처럼 주체 바로 뒤에 둔다.
const Set<String> _framingTags = {
  'close-up',
  'portrait',
  'upper body',
  'lower body',
  'cowboy shot',
  'feet out of frame',
  'foot out of frame',
  'full body',
  'wide shot',
  'very wide shot',
};

/// 시점(view angle) — 공식 튜토리얼 목록. 'from ~' 은 접두어로 따로 잡는다.
///  (straight-on · pov 는 공식 기초 문서가 시점·구도 예시로 드는 카메라 태그라 여기에 둔다)
const Set<String> _viewAngleTags = {
  'dutch angle',
  'facing viewer',
  'profile',
  'sideways',
  'upside-down',
  'straight-on',
  'pov',
};

/// 신체 부위 focus — "카메라가 무엇을 크게 담는가". 시점 바로 뒤에 둔다 ('from behind, ass focus').
///  단보루 focus 태그 묶음의 신체 부위 목록 (+ pussy focus). 사물 focus · soft focus 는 건드리지 않는다.
const Set<String> _bodyFocusTags = {
  'armpit focus',
  'ass focus',
  'back focus',
  'breast focus',
  'eye focus',
  'foot focus',
  'hand focus',
  'hip focus',
  'leg focus',
  'navel focus',
  'pectoral focus',
  'penis focus',
  'pussy focus',
  'thigh focus',
};

/// 프롬프트 검색으로 받은 태그를 NovelAI 권장 순서로 늘어놓는다 (랜덤 프롬프트 · '다음 프롬프트').
///  [ignoreRecommendedOrder] 면 묶음 없이 전체를 섞거나([random]) 알파벳 순으로([alphabetical]).
String sortNovelAIPrompt(
  String prompt, {
  required bool ignoreRecommendedOrder,
  required bool alphabetical,
  Random? random,
}) {
  List<String> tags = prompt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  // NovelAI 권장 순서 무시: 그룹 분류 없이 전체 처리
  if (ignoreRecommendedOrder) {
    if (alphabetical) {
      // 알파벳 순서
      tags.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    } else {
      // 랜덤 섞기
      tags.shuffle(random);
    }
    return tags.join(', ');
  }

  // 순서는 NovelAI 공식 튜토리얼('1girl, solo, full body, …')과 단보루 관례를 따른다.
  List<String> gPerson = []; // 1. 인원수 (1girl, 2boys, 1other)
  List<String> gSolo = []; // 2. solo
  List<String> gGenderFocus = []; // 3. 성별 focus (male focus 등) — solo 바로 뒤
  List<String> gFraming = []; // 4. 구도 (full body, close-up …) — 공식: 주체 바로 뒤
  List<String> gAngle = []; // 5. 시점 (from ~, dutch angle, profile …)
  List<String> gBodyFocus = []; // 6. 신체 부위 focus (ass focus …) — 시점 바로 뒤
  List<String> gLooking = []; // 7. 시선 (looking ~)
  List<String> gRest = []; // 8. 나머지 (알파벳 정렬 대상)
  List<String> gBackground = []; // 9. 배경

  for (String tag in tags) {
    String lowerTag = tag.toLowerCase();

    // 인원수는 보낼 때(hoistCountTags)와 같은 기준 — 예전엔 여기만 girl/boy 로 찾아 1other 를 놓쳤다
    if (_personTag.hasMatch(lowerTag) || _multiplePersonTags.contains(lowerTag)) {
      gPerson.add(tag);
    } else if (lowerTag == 'solo') {
      gSolo.add(tag);
    } else if (_genderFocusTags.contains(lowerTag)) {
      gGenderFocus.add(tag);
    } else if (_framingTags.contains(lowerTag)) {
      gFraming.add(tag);
    } else if (lowerTag.startsWith('from ') || _viewAngleTags.contains(lowerTag)) {
      gAngle.add(tag);
    } else if (_bodyFocusTags.contains(lowerTag)) {
      gBodyFocus.add(tag);
    } else if (lowerTag.startsWith('looking ')) {
      gLooking.add(tag);
    } else if (lowerTag.contains('background')) {
      gBackground.add(tag);
    } else {
      gRest.add(tag);
    }
  }

  // 알파벳 순서 옵션이 켜져있으면 나머지 그룹만 정렬 (고정 그룹은 제외)
  if (alphabetical) {
    gRest.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<String> sortedTags = [
    ...gPerson,
    ...gSolo,
    ...gGenderFocus,
    ...gFraming,
    ...gAngle,
    ...gBodyFocus,
    ...gLooking,
    ...gRest,
    ...gBackground,
  ];
  return sortedTags.join(', ');
}

// ============================================================================
// 순차 생성 <<A|B>> · 랜덤 a|b · 와일드카드 __이름__
// ============================================================================
// 순차 생성 <<A|B|C>>: 생성마다 다음 옵션을 순서대로 선택 (중첩 지원)
// 카운터 키 = "경로/내용" → 중첩 시 실제 도달한 <<>>만 증가, 위치 무관하게 안정적.
// 중첩 예: <<A|<<B|C>>|D>> → A → B → D → A → C → D (각 <<>> 독립 카운트)

// 최상위 | 로 분리 (<< >> 안의 | 은 무시)
List<String> _splitTopPipe(String s) {
  final parts = <String>[];
  int depth = 0;
  final buf = StringBuffer();
  int i = 0;
  while (i < s.length) {
    if (i + 1 < s.length && s[i] == '<' && s[i + 1] == '<') {
      depth++;
      buf.write('<<');
      i += 2;
    } else if (i + 1 < s.length && s[i] == '>' && s[i + 1] == '>') {
      depth--;
      buf.write('>>');
      i += 2;
    } else if (s[i] == '|' && depth == 0) {
      parts.add(buf.toString().trim());
      buf.clear();
      i++;
    } else {
      buf.write(s[i]);
      i++;
    }
  }
  if (buf.toString().trim().isNotEmpty) {
    parts.add(buf.toString().trim());
  }
  return parts.where((e) => e.isNotEmpty).toList();
}

// 순차 처리 (재귀, 바깥 <<>>부터). path = 카운터 식별 경로.
String _processSequentialRec(String text, String path, Map<String, int> counters) {
  final result = StringBuffer();
  int i = 0;
  int seqIdx = 0;
  while (i < text.length) {
    if (i + 1 < text.length && text[i] == '<' && text[i + 1] == '<') {
      // 매칭되는 >> 찾기 (중첩 깊이 고려)
      int depth = 1;
      int j = i + 2;
      while (j < text.length && depth > 0) {
        if (j + 1 < text.length && text[j] == '<' && text[j + 1] == '<') {
          depth++;
          j += 2;
        } else if (j + 1 < text.length && text[j] == '>' && text[j + 1] == '>') {
          depth--;
          j += 2;
        } else {
          j++;
        }
      }
      // 닫는 >>가 없으면(depth>0) 순차 문법이 아님 → '<'를 그대로 출력하고 진행
      if (depth > 0) {
        result.write(text[i]);
        i++;
        continue;
      }
      final inner = text.substring(i + 2, j - 2);
      final opts = _splitTopPipe(inner);
      if (opts.isEmpty) {
        // 빈 <<>> → 제거
      } else if (opts.length == 1) {
        result.write(_processSequentialRec(opts[0], "$path/$seqIdx", counters));
      } else {
        // 이 <<>>의 카운터 키 (경로 + 내용)
        final key = "$path/$seqIdx:$inner";
        final idx = counters[key] ?? 0;
        final chosen = opts[idx % opts.length];
        // 선택된 옵션 안에 또 <<>>가 있으면 재귀
        result.write(_processSequentialRec(chosen, key, counters));
      }
      seqIdx++;
      i = j;
    } else {
      result.write(text[i]);
      i++;
    }
  }
  return result.toString();
}

/// `<<A|B|C>>` 를 지금 차례의 옵션으로 바꾼다 (카운터는 읽기만 — 올리는 건 [advanceSequential]).
String processSequential(String prompt, Map<String, int> counters) {
  return _processSequentialRec(prompt, "", counters);
}

// 순차 와일드카드(@) 카운터 전진. 프롬프트의 __@이름__ 등장 순서대로 +1.
void advanceSequentialWildcards(String prompt, Map<String, int> counters) {
  final regex = RegExp(r'__(@[^_]+?)__');
  int pos = 0;
  for (final m in regex.allMatches(prompt)) {
    String body = m.group(1)!.substring(1); // @ 제거
    // :숫자 제거 (이름만 추출)
    final colonIdx = body.lastIndexOf(':');
    if (colonIdx != -1 && int.tryParse(body.substring(colonIdx + 1)) != null) {
      body = body.substring(0, colonIdx);
    }
    final key = "wc@$pos:$body";
    counters[key] = (counters[key] ?? 0) + 1;
    pos++;
  }
}

// 순차 카운터 전진: 이번 생성에서 실제로 "도달한" <<>>만 +1 (중첩 정확성)
void advanceSequential(String prompt, Map<String, int> counters) {
  final evaluated = <String>[];
  void walk(String text, String path) {
    int i = 0;
    int seqIdx = 0;
    while (i < text.length) {
      if (i + 1 < text.length && text[i] == '<' && text[i + 1] == '<') {
        int depth = 1;
        int j = i + 2;
        while (j < text.length && depth > 0) {
          if (j + 1 < text.length && text[j] == '<' && text[j + 1] == '<') {
            depth++;
            j += 2;
          } else if (j + 1 < text.length && text[j] == '>' && text[j + 1] == '>') {
            depth--;
            j += 2;
          } else {
            j++;
          }
        }
        // 닫는 >>가 없으면 순차 문법이 아님 → 건너뜀
        if (depth > 0) {
          i++;
          continue;
        }
        final inner = text.substring(i + 2, j - 2);
        final opts = _splitTopPipe(inner);
        if (opts.length == 1) {
          walk(opts[0], "$path/$seqIdx");
        } else if (opts.isNotEmpty) {
          final key = "$path/$seqIdx:$inner";
          evaluated.add(key);
          final idx = counters[key] ?? 0;
          walk(opts[idx % opts.length], key);
        }
        seqIdx++;
        i = j;
      } else {
        i++;
      }
    }
  }

  walk(prompt, "");
  for (final k in evaluated) {
    counters[k] = (counters[k] ?? 0) + 1;
  }
}

String processPipeOptions(String prompt, {Random? random}) {
  // "a|b|c," → 셋 중 하나를 랜덤 선택. 쉼표 또는 줄끝 앞의 word|word 패턴 처리
  final RegExp pipeRegex = RegExp(r'([\w \t][^\n,|]*(?:\|[^\n,|]+)+)(?=[,\n]|$)');
  return prompt.replaceAllMapped(pipeRegex, (match) {
    final List<String> options = match
        .group(0)!
        .split('|')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (options.length < 2) {
      return match.group(0)!;
    }
    return options[(random ?? _random).nextInt(options.length)];
  });
}

/// 랜덤 `a|b` 와 와일드카드 `__이름__` 을 연다 (와일드카드 안에 또 와일드카드가 있으면 5단계까지).
///  [contentOf] 는 와일드카드 이름 → 내용 (없으면 null — 그 자리는 그대로 둔다).
///  순차 와일드카드(`__@이름__`)는 [counters] 를 읽기만 한다 — 올리는 건 [advanceSequentialWildcards].
String processWildcards(
  String prompt, {
  required String? Function(String name) contentOf,
  required Map<String, int> counters,
  Random? random,
}) {
  String result = processPipeOptions(prompt, random: random);
  final RegExp regex = RegExp(r'__(.+?)__');
  int depth = 0;
  // 순차 와일드카드(@) 위치 카운터: 같은 패스 내 등장 순서별 독립
  int seqWildcardPos = 0;
  while (regex.hasMatch(result) && depth < 5) {
    result = result.replaceAllMapped(regex, (match) {
      String wName = match.group(1)!;

      // 순차 와일드카드 문법: @이름 또는 @이름:시작행
      // 예: @Cloth → 줄 순서대로, @Cloth:2 → 2번째 행부터 시작
      bool isSequential = false;
      int startOffset = 0;
      if (wName.startsWith('@')) {
        isSequential = true;
        String body = wName.substring(1); // @ 제거
        // :숫자 (시작 행) 파싱
        final colonIdx = body.lastIndexOf(':');
        if (colonIdx != -1) {
          final numStr = body.substring(colonIdx + 1);
          final parsed = int.tryParse(numStr);
          if (parsed != null && parsed >= 1) {
            startOffset = parsed - 1; // 2번째 행 = 인덱스 1
            body = body.substring(0, colonIdx);
          }
        }
        wName = body;
      }

      final content = contentOf(wName);
      if (content == null) {
        return match.group(0)!;
      }

      List<String> options = content
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      if (options.isEmpty) {
        return match.group(0)!;
      }

      // 순차 와일드카드: 줄 순서대로 (시작 오프셋 적용)
      if (isSequential) {
        // 카운터 키 = "wc@위치:이름" (같은 와일드카드 여러 번 쓰면 위치로 독립)
        final key = "wc@$seqWildcardPos:$wName";
        seqWildcardPos++;
        final counter = counters[key] ?? 0;
        final idx = (counter + startOffset) % options.length;
        // 가중치 문법(N)텍스트)이 있으면 텍스트만 추출
        String selected = options[idx];
        final wm = RegExp(r'^(\d+)\)(.*)$').firstMatch(selected);
        if (wm != null) {
          selected = wm.group(2)!.trim();
        }
        return selected;
      }

      List<Map<String, dynamic>> weightedOptions = [];
      int totalWeight = 0;
      final weightRegex = RegExp(r'^(\d+)\)(.*)$');

      for (String opt in options) {
        int weight = 100;
        String text = opt;
        final m = weightRegex.firstMatch(opt);
        if (m != null) {
          weight = int.tryParse(m.group(1)!) ?? 100;
          text = m.group(2)!.trim();
        }
        if (weight > 0 && text.isNotEmpty) {
          weightedOptions.add({'weight': weight, 'text': text});
          totalWeight += weight;
        }
      }

      if (weightedOptions.isEmpty) {
        return match.group(0)!;
      }

      int randomVal = (random ?? _random).nextInt(totalWeight);
      int currentSum = 0;
      for (var item in weightedOptions) {
        currentSum += item['weight'] as int;
        if (randomVal < currentSum) {
          return item['text'] as String;
        }
      }
      return weightedOptions.last['text'] as String;
    });
    result = processPipeOptions(result, random: random);
    depth++;
  }
  return result;
}

// ============================================================================
// 조건부 트리거: 조건식 (재귀 하강 파서 — 중첩 괄호 지원)
// 문법: expr = or_expr
//        or_expr = and_expr ('|' and_expr)*
//        and_expr = atom ('&' atom)*
//        atom = '!' atom | '(' or_expr ')' | pattern
// 예시: A&(B|C)&D = A 그리고 (B 또는 C) 그리고 D
//
// 조건식을 먼저 나무(CondNode)로 읽고, 그 나무로 판정한다.
//  실행(evaluateCondition)과 라이브러리 목록의 한국어 요약(trigger_rules.dart)이 '같은 파서'를 쓴다 —
//  따로 두면 요약은 A 라고 말하는데 실제로는 B 로 도는 일이 생긴다 (DEVNOTES 6).
//  ⚠️ 읽는 방식은 예전 파서(값을 바로 계산하던 _ConditionParser)와 한 글자도 다르지 않게 —
//     테스트가 예전 파서와 수천 개의 무작위 조건식으로 결과를 맞춰 본다.
// ============================================================================
bool evaluateCondition(String condStr, List<String> tags, String rating) =>
    parseCondition(condStr).node.matches(tags, rating);

/// 조건식을 나무로 읽는다.
///  [complete] 가 false 면 뒤쪽 일부를 읽지 못한 것이다 — 실행은 그 부분을 조용히 버린다
///  (예: `(a)b` 의 b, `artist (x)` 의 `)` 뒤). 라이브러리 목록이 경고로 알려 준다.
({CondNode node, bool complete}) parseCondition(String condStr) {
  final parser = _ConditionParser(condStr);
  final node = parser.parseOrExpr();
  return (node: node, complete: parser.restIsBlank);
}

/// 조건식의 한 마디.
sealed class CondNode {
  const CondNode();

  /// 태그 목록 · 등급(g s q e)이 이 조건에 맞는지
  bool matches(List<String> tags, String rating);
}

/// 태그 무늬 하나(`1girl` · `*skirt` · `long*` · `*cat*`) 또는 등급 글자(`g` `s` `q` `e`)
final class CondPattern extends CondNode {
  final String pattern;

  /// 따옴표로 묶어 적었는지 — `"nahida (genshin impact)"` · `"e"`.
  ///  묶은 것은 늘 태그다 (등급 글자로 읽지 않는다). [pattern] 은 따옴표를 벗긴 글 (앞뒤 * 는 무늬).
  final bool quoted;

  const CondPattern(this.pattern, {this.quoted = false});

  /// 등급 글자인지 (태그가 아니라 그림의 등급을 본다)
  bool get isRating => !quoted && _isRatingLetter(pattern);

  @override
  bool matches(List<String> tags, String rating) =>
      quoted ? tags.any((tag) => _isMatch(tag, pattern)) : _matchAtom(pattern, tags, rating);
}

/// `!A` — A 가 아니면
final class CondNot extends CondNode {
  final CondNode inner;
  const CondNot(this.inner);

  @override
  bool matches(List<String> tags, String rating) => !inner.matches(tags, rating);
}

/// `A&B&…` — 모두 맞으면
final class CondAll extends CondNode {
  final List<CondNode> parts;
  const CondAll(this.parts);

  @override
  bool matches(List<String> tags, String rating) => parts.every((p) => p.matches(tags, rating));
}

/// `A|B|…` — 하나라도 맞으면
final class CondAny extends CondNode {
  final List<CondNode> parts;
  const CondAny(this.parts);

  @override
  bool matches(List<String> tags, String rating) => parts.any((p) => p.matches(tags, rating));
}

/// 빈 자리 — `()` 나 `a&` 의 뒤처럼 아무것도 없는 곳. 늘 거짓 (예전 파서와 같다).
final class CondNothing extends CondNode {
  const CondNothing();

  @override
  bool matches(List<String> tags, String rating) => false;
}

bool _isRatingLetter(String p) => p == 'g' || p == 's' || p == 'q' || p == 'e';

bool _matchAtom(String pattern, List<String> tags, String rating) {
  bool negate = pattern.startsWith('!');
  if (negate) {
    pattern = pattern.substring(1);
  }

  bool matched;
  if (_isRatingLetter(pattern)) {
    matched = (rating.toLowerCase() == pattern.toLowerCase());
  } else {
    matched = tags.any((tag) => _isMatch(tag, pattern));
  }

  return negate ? !matched : matched;
}

bool _isMatch(String tag, String pattern) {
  // 규칙으로 지워진 빈 칸은 어떤 무늬에도 맞지 않는다 — '=x' 처럼 A 가 빈 규칙이 지운 태그를 되살리지 않게
  //  (random 모드는 쉼표 값을 다시 나눌 때 빈 칸이 빠져서, 두 모드의 결과가 달라졌다)
  if (tag.isEmpty) {
    return false;
  }
  if (pattern.startsWith('*') && pattern.endsWith('*') && pattern.length > 2) {
    return tag.contains(pattern.substring(1, pattern.length - 1));
  } else if (pattern.startsWith('*') && pattern.length > 1) {
    return tag.endsWith(pattern.substring(1));
  } else if (pattern.endsWith('*') && pattern.length > 1) {
    return tag.startsWith(pattern.substring(0, pattern.length - 1));
  } else {
    return tag == pattern;
  }
}

// ============================================================================
// 따옴표로 묶기 — "…" · '…'  (3.14.0~)
//  태그 속 기호가 규칙 문법으로 읽히지 않게 묶는다. 조건의 & | ! ( ) · 결과의 = ^ + 를 품은 태그도 그대로 쓸 수 있다.
//    ("nahida (genshin impact)"&!solo):"la+ darknesss"+dress
//  · 묶음은 '낱말 맨 앞'에서만 연다 — 처음 · 기호 바로 뒤 (공백 · * 는 건너뛰고 본다).
//    그래서 girls' frontline 처럼 태그 가운데의 ' 는 그대로 글자다.
//  · 같은 따옴표로 닫아야 묶음이다. 닫는 따옴표가 없으면 그냥 글자 (예전 규칙이 그대로 돈다).
//  · ' 가 든 태그는 " 로, " 가 든 태그는 ' 로 묶는다. 앞뒤 * 는 묶음 바깥에 둔다 (*"la+" = la+ 로 끝나는 태그).
//  · 쉼표는 묶어도 안 된다 — 태그는 쉼표로 나뉘므로 쉼표가 든 태그는 없다.
// ============================================================================
bool _isQuote(String c) => c == '"' || c == "'";

/// 결과에서 낱말을 끊는 글자 (이 글자 바로 뒤가 낱말 맨 앞)
const String _actionDelims = '=^+,';

/// 조건에서 낱말을 끊는 글자
const String _condDelims = '(&|!';

/// [s] 의 따옴표 묶음들 — (여는 자리, 닫는 자리).
///  묶음은 낱말 맨 앞(처음 · [delims] 글자 바로 뒤, 공백 · * 는 건너뛴다)에서만 연다. 안 닫힌 따옴표는 묶음이 아니다.
List<(int, int)> _quoteSpans(String s, String delims) {
  final spans = <(int, int)>[];
  bool termStart = true;
  for (int i = 0; i < s.length; i++) {
    final c = s[i];
    if (termStart && _isQuote(c)) {
      final close = s.indexOf(c, i + 1);
      if (close != -1) {
        spans.add((i, close));
        i = close; // 묶음 안은 건너뛴다
        termStart = false;
        continue;
      }
    }
    if (delims.contains(c)) {
      termStart = true;
    } else if (c != ' ' && c != '*') {
      termStart = false;
    }
  }
  return spans;
}

/// 따옴표 묶음 바깥에서 [ops] 중 하나가 처음 나오는 자리 (없으면 -1).
int _indexOutsideQuotes(String s, String ops, String delims) {
  final masked = _maskQuotes(s, delims);
  for (int i = 0; i < masked.length; i++) {
    if (ops.contains(masked[i])) {
      return i;
    }
  }
  return -1;
}

/// 따옴표 묶음 안의 글자를 '_' 로 가린 글 (길이 · 자리는 그대로) — 묶음 바깥의 기호만 보고 싶을 때
String _maskQuotes(String s, String delims) {
  final spans = _quoteSpans(s, delims);
  if (spans.isEmpty) {
    return s;
  }
  final buf = StringBuffer();
  int last = 0;
  for (final (open, close) in spans) {
    buf
      ..write(s.substring(last, open + 1))
      ..write('_' * (close - open - 1));
    last = close;
  }
  buf.write(s.substring(last));
  return buf.toString();
}

/// 라이브러리 화면의 검사용 — 조건([isCondition]) 또는 결과 글에서 따옴표 묶음 안을 '_' 로 가린다.
///  (묶음을 여는 규칙은 실행과 같다 — 화면이 따로 셈하면 '묶었는데 경고' 같은 어긋남이 생긴다)
String maskTriggerQuotes(String s, {required bool isCondition}) =>
    _maskQuotes(s, isCondition ? _condDelims : _actionDelims);

/// 낱말 하나의 따옴표를 벗긴다 — `"la+ darknesss"` → la+ darknesss,  `*"(x)"` → *(x).
///  통째로 묶인 낱말(앞뒤 * 만 바깥에 둘 수 있다)이 아니면 앞뒤 공백만 걷는다 (따옴표도 글자).
String unquoteTriggerTerm(String term) {
  final s = term.trim();
  int i = 0;
  while (i < s.length && s[i] == '*') {
    i++;
  }
  if (i >= s.length || !_isQuote(s[i])) {
    return s;
  }
  final close = s.indexOf(s[i], i + 1);
  if (close == -1) {
    return s;
  }
  int j = close + 1;
  while (j < s.length && s[j] == '*') {
    j++;
  }
  if (j != s.length) {
    return s;
  }
  return '${s.substring(0, i)}${s.substring(i + 1, close)}${s.substring(close + 1)}';
}

/// 결과의 B 처럼 쉼표로 여러 태그를 적는 자리 — 조각마다 따옴표를 벗긴다. 묶인 조각이 없으면 글 그대로(앞뒤 공백만).
String _unquoteList(String value) {
  final parts = value.split(',');
  if (!parts.any((p) => unquoteTriggerTerm(p) != p.trim())) {
    return value.trim();
  }
  return parts.map(unquoteTriggerTerm).where((p) => p.isNotEmpty).join(', ');
}

/// 결과의 종류 — 실행이 보는 순서 그대로: prefix= → suffix= → ^ → = → +
enum TriggerActionKind {
  /// prefix=B — 긍정 맨 앞에 추가
  prepend,

  /// suffix=B — 긍정 맨 뒤에 추가
  append,

  /// A^B — 맞는 태그 속 글자만 바꾸기
  partial,

  /// A=B — 맞는 태그를 통째로 바꾸기
  replace,

  /// A= — 맞는 태그 지우기
  remove,

  /// A+B — A 에 맞는 첫 태그 바로 뒤에 B 넣기 (B 는 쉼표로 여러 개 — 이미 있는 태그는 건너뛴다)
  insertAfter,

  /// 어느 꼴도 아님 — 실행되지 않는다
  unknown,
}

/// 결과를 (종류, A, B) 로 나눈다 — 실행(두 모드)과 라이브러리 화면(요약 · 검사)이 모두 이것 하나로 자른다.
///  기호(^ = +)는 따옴표 묶음 바깥에서만 본다 — `"=_="=smile` 은 '=_=' 를 smile 로, `smile="^_^"` 는 smile 을 '^_^' 로.
///  A · B 는 따옴표를 벗긴 글 (A 의 앞뒤 * 는 무늬).
///  ⚠️ + 는 ^ · = 가 없을 때만 — 묶지 않은 'la+ darknesss=…' 같은 예전 규칙이 그대로 돌게.
///  ⚠️ 예전엔 실행 두 곳(랜덤 · 생성)과 화면이 따로 잘랐다 — 한 곳만 고치면 요약과 실제가 어긋난다.
({TriggerActionKind kind, String a, String b}) parseTriggerAction(String action) {
  if (action.startsWith('prefix=')) {
    return (kind: TriggerActionKind.prepend, a: '', b: _unquoteList(action.substring(7)));
  }
  if (action.startsWith('suffix=')) {
    return (kind: TriggerActionKind.append, a: '', b: _unquoteList(action.substring(7)));
  }
  for (final (op, kind) in const [
    ('^', TriggerActionKind.partial),
    ('=', TriggerActionKind.replace),
    ('+', TriggerActionKind.insertAfter),
  ]) {
    final at = _indexOutsideQuotes(action, op, _actionDelims);
    if (at == -1) {
      continue;
    }
    final b = _unquoteList(action.substring(at + 1));
    return (
      kind: kind == TriggerActionKind.replace && b.isEmpty ? TriggerActionKind.remove : kind,
      a: unquoteTriggerTerm(action.substring(0, at)),
      b: b,
    );
  }
  return (kind: TriggerActionKind.unknown, a: action.trim(), b: '');
}

// 조건부 트리거 규칙 텍스트 → (조건, 액션) 쌍 목록. 두 적용 함수가 공유하는 파서.
// 실행 엔진은 한 벌이다 — applyConditionalRulesSectioned. 두 모드는 '언제 · 어디에' 만 다르다:
//  - applyConditionalRules (random 모드): 받은 프롬프트를 긍정 자리에 두고 같은 엔진으로 돌린 뒤 태그 목록으로 정리 (겹친 태그 하나로)
//  - applyConditionalRulesSectioned (generate 모드): 선행/긍정/후행 경계 · 사용자 서식 보존, 중복 제거 없음
//  ⚠️ 예전엔 두 함수가 따로 구현돼 있어(그때는 '병합 금지'라고 적어 두었다) 같은 규칙이 모드마다 다르게 돌았다
//     (prefix= 로 넣은 태그를 뒤 규칙이 못 바꿈 · 'A, B' 를 다시 나누지 않음 · prefix= 여러 개의 순서가 거꾸로 등).
//  '#' 로 시작하는 줄은 주석이라 건너뛴다 — 라이브러리 목록의 이름 줄('# 이름')과
//  꺼 둔 규칙('#off (조건):결과')도 주석이라 실행에는 끼지 않는다 (trigger_rules.dart).
List<({String cond, String action})> parseConditionalRules(String rulesText) {
  final List<({String cond, String action})> parsed = [];
  final rules = rulesText
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && !e.startsWith('#'))
      .toList();
  for (final ruleStr in rules) {
    final rule = parseRuleLine(ruleStr);
    if (rule != null) {
      parsed.add(rule);
    }
  }
  return parsed;
}

/// 한 줄이 `(조건):결과` 꼴이면 (조건, 결과) 를, 아니면 null 을 돌려준다.
///  [line] 은 앞뒤 공백을 걷어 낸 줄. 주석('#')인지는 부르는 쪽이 본다.
///  조건 안의 괄호는 짝을 맞춰 건너뛴다 — `((a|b)&c):x=y` 의 조건은 `(a|b)&c`.
///  따옴표로 묶은 태그 속 괄호는 세지 않는다 — `(":)"&smile):x=y` 의 조건은 `":)"&smile`.
///  ( · ) · : · 따옴표는 한 글자짜리라 그 자리에서 자르는 것은 이모지를 쪼개지 않는다.
({String cond, String action})? parseRuleLine(String line) {
  if (!line.startsWith('(')) {
    return null;
  }
  // 매칭되는 닫는 괄호 찾기 (중첩 괄호 지원)
  int depth = 0;
  bool termStart = true; // 낱말 맨 앞인지 — 따옴표 묶음은 여기서만 연다 (조건 파서와 같은 규칙)
  for (int i = 0; i < line.length; i++) {
    final c = line[i];
    if (termStart && depth > 0 && _isQuote(c)) {
      final close = line.indexOf(c, i + 1);
      if (close != -1) {
        i = close;
        termStart = false;
        continue;
      }
    }
    if (c == '(') {
      depth++;
      termStart = true;
    } else if (c == ')') {
      depth--;
      termStart = false;
      if (depth == 0) {
        if (i + 1 < line.length && line[i + 1] == ':') {
          return (cond: line.substring(1, i), action: line.substring(i + 2));
        }
        return null;
      }
    } else if (_condDelims.contains(c)) {
      termStart = true;
    } else if (c != ' ' && c != '*') {
      termStart = false;
    }
  }
  return null;
}

/// 쉼표로 나눈 태그들 (앞뒤 공백 · 빈 칸 뺌) — random 모드가 프롬프트를 읽는 모양
List<String> _splitTags(String prompt) =>
    prompt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

/// random 모드의 결과 모양 — 빈 칸 빼고, 겹친 태그는 하나로, ', ' 로 잇는다
String _joinTags(Iterable<String> tags) => tags.where((t) => t.isNotEmpty).toSet().join(', ');

/// 규칙이 아무것도 바꾸지 않았을 때 [applyConditionalRules] 가 돌려주는 모양.
///  (빈 칸 · 겹친 태그 · 띄어쓰기는 규칙과 상관없이 정리된다 — 테스트 칸이 '바뀐 것 없음'을 가릴 때 쓴다)
String normalizeRandomPrompt(String prompt) => _joinTags(_splitTags(prompt));

// [onHit] — 조건이 맞은 규칙의 번호(parseConditionalRules 순서)를 알려 준다.
//  라이브러리의 테스트 칸이 '걸린 규칙'을 보여 줄 때만 쓴다 (결과에는 영향 없음).
// [prefix] · [suffix] — 선행 · 후행 프롬프트. 조건 판정과 '이미 있는지'만 보고, 바꾼 결과는 버린다
//  (이 모드가 바꾸는 것은 받은 프롬프트 하나다).
//  ⚠️ 예전엔 받은 태그만 봤다. 그런데 받은 태그에서 선행 · 후행에 있는 태그는 미리 빠지므로(cleanSearchTags),
//     선행에 1girl 을 둔 사람의 '(1girl&!solo):prefix=solo' 가 걸리지 않았고, 선행에 solo 가 있어도 또 넣었다.
String applyConditionalRules(
  String prompt,
  String rating,
  String rulesText, {
  void Function(int index)? onHit,
  String prefix = '',
  String suffix = '',
}) {
  if (rulesText.trim().isEmpty) {
    return prompt;
  }
  final r = applyConditionalRulesSectioned(prefix, prompt, suffix, rating, rulesText, onHit: onHit);
  // A= (지우기) · A^B 로 비워진 태그는 빼고, 겹친 태그는 하나로 ('a, , b' 가 아니라 'a, b').
  //  실제 랜덤 프롬프트는 다음 단계(sortNovelAIPrompt)가 어차피 빈 조각을 버리지만,
  //  라이브러리의 테스트 칸은 이 결과를 그대로 보여 주므로 여기서 정리해야 실제와 같아 보인다.
  return normalizeRandomPrompt(r.positive);
}

// 프롬프트 조각 하나. 사용자가 넣은 앞뒤 여백(줄바꿈·들여쓰기)을 따로 들고 다닌다.
//  조건부 규칙은 '내용'만 보고 판단·치환하고, 여백은 그대로 되돌려 준다.
//  이렇게 해야 규칙이 걸리든 안 걸리든 사용자의 줄 구성이 유지된다.
List<({String lead, String core, String trail})> _splitPieces(String input) {
  final out = <({String lead, String core, String trail})>[];
  for (final raw in input.split(',')) {
    final core = raw.trim();
    if (core.isEmpty) {
      continue; // 내용 없는 조각은 버린다
    }
    final start = raw.indexOf(core);
    out.add((
      lead: raw.substring(0, start),
      core: core,
      trail: raw.substring(start + core.length),
    ));
  }
  return out;
}

// 조각들을 원래 여백 그대로 다시 잇는다. 내용이 빈 조각(규칙으로 지워진 것)은 뺀다.
String _joinPieces(List<({String lead, String core, String trail})> pieces) {
  final alive = pieces.where((p) => p.core.isNotEmpty).toList();
  if (alive.isEmpty) {
    return '';
  }
  final buf = <String>[];
  for (int i = 0; i < alive.length; i++) {
    final p = alive[i];
    // 맨 앞 조각의 선행 여백만 없앤다 (프롬프트가 빈 줄로 시작하지 않게)
    buf.add((i == 0 ? '' : p.lead) + p.core + p.trail);
  }
  return buf.join(',').trimRight();
}

// 규칙이 태그를 'A, B' 처럼 쉼표가 든 값으로 바꾸면, 그 조각은 더 이상
// 태그 하나가 아니다. 그대로 두면 다음 규칙이 'A' 를 찾지 못해 건너뛰게 된다.
//  예) (A&!B&...):A=A, B  와  (A&!E&...):A=A, E  를 함께 쓰면
//      앞 규칙이 'A' 를 'A, B' 로 바꿔 버려 뒤 규칙의 조건(A)이 거짓이 됐다.
// 그래서 치환 직후 쉼표가 생긴 조각을 다시 태그 단위로 쪼갠다.
void _resplitPieces(List<({String lead, String core, String trail})> list) {
  for (int i = 0; i < list.length; i++) {
    if (!list[i].core.contains(',')) {
      continue;
    }
    final p = list[i];
    final parts = p.core.split(',').where((e) => e.trim().isNotEmpty).toList();
    if (parts.length <= 1) {
      continue;
    }
    final replacement = <({String lead, String core, String trail})>[];
    for (int k = 0; k < parts.length; k++) {
      replacement.add((
        // 첫 조각만 원래 앞 여백을 물려받고, 나머지는 보통의 ", " 간격을 쓴다
        lead: k == 0 ? p.lead : ' ',
        core: parts[k].trim(),
        trail: k == parts.length - 1 ? p.trail : '',
      ));
    }
    list.replaceRange(i, i + 1, replacement);
    i += replacement.length - 1;
  }
}

/// 넣을 태그들 — [value] 를 쉼표로 나눠, [existing] 에 이미 있는 것 · 값 안에서 겹친 것을 뺀다 (적은 순서 그대로)
List<String> _tagsToAdd(String value, List<String> existing) {
  final out = <String>[];
  for (final raw in value.split(',')) {
    final t = raw.trim();
    if (t.isNotEmpty && !existing.contains(t) && !out.contains(t)) {
      out.add(t);
    }
  }
  return out;
}

// 생성 모드용: 선행+긍정+후행을 합쳐 조건 검사 후, 영역 경계를 보존하며 적용
// - 조건 판정: 전체 합친 태그 기준
// - 교체(^, =): 세 영역 모두 제자리 (앞 규칙이 prefix= · suffix= 로 넣은 태그도 — random 모드와 같다)
// - A+B: A 에 맞는 첫 태그 바로 뒤에 B (그 태그가 있는 영역 안에서)
// - prefix=결과: 긍정 프롬프트 맨 앞에 추가 (선행과 긍정 사이)
// - suffix=결과: 긍정 프롬프트 맨 끝에 추가 (긍정과 후행 사이)
//  넣는 쪽(A+B · prefix= · suffix=)의 B 는 쉼표로 여러 개 — 적은 순서대로, 이미 어딘가에 있는 태그는 건너뛴다.
//  조건을 끝까지 읽지 못한 규칙(괄호 짝이 틀림 등 — 라이브러리에 ⚠)은 돌지 않는다.
//  [onHit] 은 applyConditionalRules 와 같다 (테스트 칸 전용).
({String prefix, String positive, String suffix}) applyConditionalRulesSectioned(
  String prefix,
  String positive,
  String suffix,
  String rating,
  String rulesText, {
  void Function(int index)? onHit,
}) {
  if (rulesText.trim().isEmpty) {
    return (prefix: prefix, positive: positive, suffix: suffix);
  }

  // 여백을 보존한 채 조각으로 나눈다 (줄바꿈이 살아남는 이유)
  final prefixTags = _splitPieces(prefix);
  final positiveTags = _splitPieces(positive);
  final suffixTags = _splitPieces(suffix);
  // 규칙이 실제로 바꾼 구획만 다시 잇는다 — 나머지는 원문 그대로 (다시 이으면 사용자가 쓴 ', ,' 같은 빈 조각이 빠진다)
  final List<bool> touched = [false, false, false]; // 선행 · 긍정 · 후행

  // prefix=로 추가될 태그(긍정 앞)와 suffix=로 추가될 태그(긍정 뒤)
  //  새로 넣는 태그는 원래 서식이 없으므로 ", " 로 붙인다.
  final positiveFront = <({String lead, String core, String trail})>[];
  final positiveBack = <({String lead, String core, String trail})>[];
  // 바꾸기(^ · = · +)가 훑는 조각 묶음 — 보낼 순서 그대로, 그리고 각 묶음이 속한 구획 (0 선행 · 1 긍정 · 2 후행)
  //  ⚠️ 예전엔 prefix= · suffix= 로 넣은 태그(positiveFront · positiveBack)를 빼고 훑어서,
  //     '(1girl):prefix=solo' 다음의 '(solo):solo=' 가 조건은 맞는데 아무것도 못 지웠다 (random 모드는 지웠다).
  final lists = [prefixTags, positiveFront, positiveTags, positiveBack, suffixTags];
  const listSection = [0, 1, 1, 1, 2];

  final rules = parseConditionalRules(rulesText);
  for (int r = 0; r < rules.length; r++) {
    String condStr = rules[r].cond;
    String actionStr = rules[r].action;

    // 1. 조건 판정은 전체 합친 태그(선행+긍정+후행) 기준 — 내용만 본다
    List<String> allTags = [
      ...prefixTags,
      ...positiveFront,
      ...positiveTags,
      ...positiveBack,
      ...suffixTags,
    ].map((p) => p.core).where((e) => e.isNotEmpty).toList();
    //  ⚠️ 끝까지 읽지 못한 조건은 거짓으로 본다. 예전엔 읽은 데까지만 봐서
    //     '(1girl)(solo)' 가 1girl 만 보고 걸렸다 (텍스트로 편집에서 잘못 고친 규칙이 생각보다 넓게 돌았다).
    //     evaluateCondition 은 예전 파서와 판정을 맞춰 보는 기준이라 그대로 두고, 여기서만 거른다.
    final cond = parseCondition(condStr);
    if (!cond.complete || !cond.node.matches(allTags, rating)) {
      continue;
    }
    onHit?.call(r);

    final act = parseTriggerAction(actionStr);
    final a = act.a;
    final b = act.b;
    switch (act.kind) {
      case TriggerActionKind.prepend:
        // 2. 긍정 프롬프트 맨 앞에 추가 (여러 규칙이면 규칙 순서대로)
        //  ⚠️ 예전엔 'prefix=solo, smile' 을 통째로 한 덩어리로 보고 '이미 있나'를 봐서, smile 이 있어도 또 넣었다
        for (final t in _tagsToAdd(b, allTags)) {
          positiveFront.add((lead: ' ', core: t, trail: ''));
        }
      case TriggerActionKind.append:
        // 3. 긍정 프롬프트 맨 끝에 추가
        for (final t in _tagsToAdd(b, allTags)) {
          positiveBack.add((lead: ' ', core: t, trail: ''));
        }
      case TriggerActionKind.partial:
        // A^B: 맞는 태그 속의 A 글자(* 뺀 것)만 B 글자로. A 글자가 없으면 태그를 통째로 B 로
        String literalA = a.replaceAll('*', '');
        String literalB = b.replaceAll('*', '');
        for (int l = 0; l < lists.length; l++) {
          final list = lists[l];
          for (int i = 0; i < list.length; i++) {
            if (_isMatch(list[i].core, a)) {
              // 여백(lead/trail)은 그대로 두고 내용만 바꾼다
              final replaced = literalA.isNotEmpty
                  ? list[i].core.replaceAll(literalA, literalB)
                  : b;
              list[i] = (lead: list[i].lead, core: replaced, trail: list[i].trail);
              touched[listSection[l]] = true;
            }
          }
        }
      case TriggerActionKind.replace:
      case TriggerActionKind.remove:
        for (int l = 0; l < lists.length; l++) {
          final list = lists[l];
          for (int i = 0; i < list.length; i++) {
            if (_isMatch(list[i].core, a)) {
              list[i] = (lead: list[i].lead, core: b, trail: list[i].trail);
              touched[listSection[l]] = true;
            }
          }
        }
      case TriggerActionKind.insertAfter:
        // A+B: A 에 맞는 첫 태그 바로 뒤에 B (여러 개면 적은 순서대로, 이미 있는 태그는 건너뛴다)
        //  (3.14.0 작업 중엔 '바로 앞에' 였다 — 1girl+solo 가 'solo, 1girl' 이 되어 뒤로 바꿨다)
        final adds = _tagsToAdd(b, allTags);
        if (adds.isEmpty) {
          break;
        }
        for (int l = 0; l < lists.length; l++) {
          final list = lists[l];
          final at = list.indexWhere((piece) => _isMatch(piece.core, a));
          if (at == -1) {
            continue;
          }
          final hit = list[at];
          // 원래 태그는 제자리(앞 여백 그대로), 새 태그들은 그 뒤에 보통의 ', ' 간격으로.
          //  원래 태그 뒤의 여백(쉼표 앞 줄바꿈 등)은 마지막 새 태그가 물려받는다 — 묶음째 그 자리에 선다.
          list[at] = (lead: hit.lead, core: hit.core, trail: '');
          list.insertAll(at + 1, [
            for (int k = 0; k < adds.length; k++)
              (lead: ' ', core: adds[k], trail: k == adds.length - 1 ? hit.trail : ''),
          ]);
          touched[listSection[l]] = true;
          break;
        }
      case TriggerActionKind.unknown:
        break;
    }

    // 이번 규칙이 'A, B' 같은 값을 넣었을 수 있다. 다음 규칙이 태그를 제대로
    // 찾을 수 있도록 매 규칙이 끝날 때마다 조각을 다시 태그 단위로 맞춘다.
    for (final list in lists) {
      _resplitPieces(list);
    }
  }

  // 긍정 = [prefix=추가분] + [원래 긍정] + [suffix=추가분]
  //  원래 긍정의 첫 조각은 맨 앞이었으니 앞 여백이 없다. 그 앞에 추가분이 붙으면 'solo,smile' 처럼
  //  쉼표에 바로 붙어 버리므로 보통의 ', ' 간격을 준다. (사용자가 줄바꿈 등을 넣어 둔 경우는 그대로)
  //  규칙으로 내용이 지워진 조각은 이을 때 빠지므로, 내용이 남은 첫 조각을 본다.
  if (positiveFront.isNotEmpty) {
    final i = positiveTags.indexWhere((p) => p.core.isNotEmpty);
    if (i != -1 && positiveTags[i].lead.isEmpty) {
      final p = positiveTags[i];
      positiveTags[i] = (lead: ' ', core: p.core, trail: p.trail);
    }
  }
  final finalPositive = [...positiveFront, ...positiveTags, ...positiveBack];

  final bool positiveTouched = touched[1] || positiveFront.isNotEmpty || positiveBack.isNotEmpty;
  return (
    prefix: touched[0] ? _withEdges(prefix, _joinPieces(prefixTags)) : prefix,
    positive: positiveTouched ? _withEdges(positive, _joinPieces(finalPositive)) : positive,
    suffix: touched[2] ? _withEdges(suffix, _joinPieces(suffixTags)) : suffix,
  );
}

// 구획 앞뒤의 빈 자리(공백 · 쉼표 · 줄바꿈)를 원래대로 돌려 붙인다.
//  구획을 이을 때(NovelAiService.joinPromptSections) 이 빈 자리의 줄바꿈을 보고 줄을 나누는데,
//  조각으로 나눴다 이으면 맨 앞뒤의 빈 조각이 버려져 줄바꿈이 사라졌다.
//  ⚠️ 예전엔 규칙이 하나라도 있으면(걸리지 않아도) 긍정 끝의 줄바꿈이 사라져
//     '문장,⏎' + 'masterpiece' 가 '문장, masterpiece' 로 한 줄에 붙었다. (규칙이 없을 땐 원문 그대로라 괜찮았다)
//  맨 앞의 빈 줄은 잇는 쪽(sanitizePrompt)이 어차피 걷어 내므로 프롬프트가 빈 줄로 시작하지는 않는다.
//  규칙이 바꾸지 않은 구획은 아예 다시 잇지 않는다 (applyConditionalRulesSectioned — 원문 그대로).
String _withEdges(String original, String body) {
  if (body.isEmpty) {
    return body;
  }
  final lead = _edgeLead.firstMatch(original)![0]!;
  if (lead.length == original.length) {
    return body; // 원래 구획이 빈 자리뿐이었다 (prefix= 로 새로 채운 긍정 등)
  }
  final trail = _edgeTrail.firstMatch(original)![0]!;
  return '$lead$body$trail';
}

final RegExp _edgeLead = RegExp(r'^[\s,]*');
final RegExp _edgeTrail = RegExp(r'[\s,]*$');

// 프롬프트 내용에서 레이팅 글자 추출 (조건부 트리거 조건 판정용)
String ratingLetterOf(String source) {
  final lower = source.toLowerCase();
  if (lower.contains("explicit")) {
    return "e";
  }
  if (lower.contains("questionable")) {
    return "q";
  }
  if (lower.contains("sensitive")) {
    return "s";
  }
  return "g";
}

// ============================================================================
// 조건부 트리거 파서 (재귀 하강) — 조건식을 나무(CondNode)로 읽는다. 판정은 나무가 한다.
// ============================================================================
class _ConditionParser {
  final String _input;
  int _pos = 0;

  _ConditionParser(this._input);

  /// 남은 글이 없거나 공백뿐인지 (아니면 실행이 그 부분을 버린다)
  bool get restIsBlank => _input.substring(_pos).trim().isEmpty;

  void _skipSpaces() {
    while (_pos < _input.length && _input[_pos] == ' ') {
      _pos++;
    }
  }

  // or_expr = and_expr ('|' and_expr)*
  CondNode parseOrExpr() {
    final parts = <CondNode>[_parseAndExpr()];
    while (_pos < _input.length) {
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == '|') {
        _pos++;
        parts.add(_parseAndExpr());
      } else {
        break;
      }
    }
    return parts.length == 1 ? parts.first : CondAny(parts);
  }

  // and_expr = atom ('&' atom)*
  CondNode _parseAndExpr() {
    final parts = <CondNode>[_parseAtom()];
    while (_pos < _input.length) {
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == '&') {
        _pos++;
        parts.add(_parseAtom());
      } else {
        break;
      }
    }
    return parts.length == 1 ? parts.first : CondAll(parts);
  }

  // atom = '!' atom | '(' or_expr ')' | pattern
  CondNode _parseAtom() {
    _skipSpaces();
    if (_pos >= _input.length) {
      return const CondNothing();
    }

    // 부정 연산자
    if (_input[_pos] == '!') {
      _pos++;
      return CondNot(_parseAtom());
    }

    // 괄호 그룹
    if (_input[_pos] == '(') {
      _pos++; // '(' 건너뛰기
      final inner = parseOrExpr();
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == ')') {
        _pos++; // ')' 건너뛰기
      }
      return inner;
    }

    // 따옴표로 묶은 태그 — "nahida (genshin impact)" · *"la+" (앞뒤 * 는 바깥에)
    //  닫는 따옴표가 없으면 묶음이 아니다 — 아래에서 예전처럼 글자로 읽는다.
    final quoted = _readQuoted();
    if (quoted != null) {
      return CondPattern(quoted, quoted: true);
    }

    // 패턴 (& | ) 까지 읽기)
    StringBuffer buf = StringBuffer();
    while (_pos < _input.length &&
        _input[_pos] != '&' &&
        _input[_pos] != '|' &&
        _input[_pos] != ')') {
      buf.write(_input[_pos]);
      _pos++;
    }
    String pattern = buf.toString().trim();
    if (pattern.isEmpty) {
      return const CondNothing();
    }

    return CondPattern(pattern);
  }

  /// 지금 자리부터 `*"…"*` 꼴이면 따옴표를 벗긴 무늬를 돌려주고 그 뒤로 옮긴다. 아니면 null (자리 그대로).
  ///  닫는 따옴표 뒤에 다른 글자가 붙어 있으면(`"a"b`) 그 글자도 무늬에 붙인다 (& | ) 까지).
  String? _readQuoted() {
    int i = _pos;
    while (i < _input.length && _input[i] == '*') {
      i++;
    }
    if (i >= _input.length || !_isQuote(_input[i])) {
      return null;
    }
    final close = _input.indexOf(_input[i], i + 1);
    if (close == -1) {
      return null;
    }
    final start = _pos;
    final buf = StringBuffer()
      ..write(_input.substring(_pos, i))
      ..write(_input.substring(i + 1, close));
    _pos = close + 1;
    while (_pos < _input.length &&
        _input[_pos] != '&' &&
        _input[_pos] != '|' &&
        _input[_pos] != ')') {
      buf.write(_input[_pos]);
      _pos++;
    }
    final pattern = buf.toString().trimRight();
    if (pattern.isEmpty) {
      _pos = start; // 빈 묶음("") — 묶음이 아니라 글자로 읽게 되돌린다
      return null;
    }
    return pattern;
  }
}
