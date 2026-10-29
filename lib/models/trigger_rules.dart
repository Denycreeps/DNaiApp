// lib/models/trigger_rules.dart
//
// 조건부 트리거 '목록' — 라이브러리 탭이 규칙 글을 한 칸짜리 항목들로 다룰 때 쓰는 순수 함수.
//
//  저장은 예전 그대로 규칙 글 하나다 (AppState.conditionalRuleController — 설정 키 conditional_rules).
//  실행(prompt_pipeline.dart 의 applyConditionalRules…)은 이 파일을 모르고 글만 읽는다.
//  목록이 덧붙이는 표시는 '#' 주석이라 실행 결과는 바뀌지 않는다:
//   · '#off' 를 붙인 규칙      → 꺼 둔 규칙          #off (cat*):cat*^dog*
//     (예전처럼 '#' 만 붙여 막아 둔 '#(조건):결과' 도 꺼 둔 규칙으로 읽는다)
//   · 그 밖의 주석 줄          → 메모 칸 (구역 제목 · 설명 등)
//   · 규칙 모양이 아닌 줄      → '실행 안 되는 줄' 칸 (지우지 않고 보여 준다)
//  규칙에 이름은 없다 — 목록은 조건 · 결과 요약으로 보여 준다.
//   (잠깐 '규칙 바로 윗줄의 주석 = 이름' 이었다가 뺐다. 그런 줄은 이제 그냥 메모 칸이다)
//
//  읽고(parseTriggerLibrary) 다시 쓰면(serializeTriggerLibrary) 내용은 그대로다.
//  바뀌는 것은 겉모양뿐 — 줄 앞뒤 공백, 연달은 빈 줄은 한 줄로, 맨 앞뒤 빈 줄.
//  (test/trigger_rules_test.dart 가 지킨다)
import 'prompt_pipeline.dart';

// 결과 자르기는 실행 엔진의 것을 그대로 쓴다 (화면과 실행이 같은 칼로 자르게 — DEVNOTES 6)
export 'prompt_pipeline.dart' show TriggerActionKind, parseTriggerAction, unquoteTriggerTerm, maskTriggerQuotes;

/// 조건부 트리거 글 전체를 고치는 확대 입력창의 되돌리기 열쇠.
///  ⚠️ 예전 프롬프트탭 입력창의 열쇠('prompt/' + 그 칸 제목)와 같아야 그때 기록이 이어진다.
const String kConditionalUndoKey = 'prompt/조건부 트리거 작성 (줄바꿈 구분)';

/// 규칙을 끌 때 앞에 붙이는 표시. '#' 로 시작하니 실행은 주석으로 보고 건너뛴다.
const String kTriggerOffMarker = '#off ';

// ============================================================================
// 목록의 칸
// ============================================================================

/// 목록의 한 칸 — 규칙([TriggerRule]) 또는 규칙이 아닌 줄([TriggerNote]).
///  ⚠️ 화면은 칸을 '객체'로 붙잡는다 (DEVNOTES 5) — 편집을 마칠 때 그 객체가 아직 목록에 있는지 본다.
sealed class TriggerItem {
  /// 이 칸 앞에 빈 줄이 있었는지 — 글로 볼 때 사용자가 띄워 둔 모양을 지킨다. 새 칸은 띄운다.
  bool gapBefore;

  TriggerItem({required this.gapBefore});

  /// 이 칸을 글로 (여러 줄 메모는 여러 줄)
  String toText();
}

/// 규칙 하나 — `(조건):결과`
final class TriggerRule extends TriggerItem {
  bool enabled;
  String cond;
  String action;

  /// 꺼 둘 때 앞에 붙이는 표시 — 읽은 모양 그대로 ('#off ' · 예전에 막아 둔 줄은 '#')
  String offMarker;

  TriggerRule({
    this.enabled = true,
    required this.cond,
    required this.action,
    this.offMarker = kTriggerOffMarker,
    super.gapBefore = true,
  });

  /// 실행이 읽는 그 한 줄
  String get ruleLine => '($cond):$action';

  @override
  String toText() => enabled ? ruleLine : '$offMarker$ruleLine';
}

/// 규칙이 아닌 줄들 — '#' 메모, 또는 규칙 모양이 아니라 실행되지 않는 줄
final class TriggerNote extends TriggerItem {
  /// 원문 줄 (앞뒤 공백만 걷어 냄)
  final List<String> lines;

  /// true = 실행되지 않는 줄 (한 줄짜리), false = '#' 메모
  final bool broken;

  TriggerNote(this.lines, {this.broken = false, super.gapBefore = true});

  @override
  String toText() => lines.join('\n');

  /// 화면에 보일 글 — 메모는 줄 앞의 '#' 을 뗀다
  String get displayText =>
      broken ? toText() : lines.map((l) => l.replaceFirst(_commentHead, '')).join('\n');
}

// ============================================================================
// 글 ↔ 목록
// ============================================================================

final RegExp _offHead = RegExp(r'^#off\s*', caseSensitive: false);
final RegExp _commentHead = RegExp(r'^#+\s*');

/// 꺼 둔 규칙 줄이면 (머리, 조건, 결과) — '#off (조건):결과' 또는 예전 방식 '#(조건):결과'.
///  '# (…' 처럼 # 뒤를 띄운 줄은 보통 설명 주석이라 규칙으로 보지 않는다.
({String marker, String cond, String action})? _disabledRule(String line) {
  final off = _offHead.firstMatch(line);
  if (off != null) {
    final r = parseRuleLine(line.substring(off.end));
    if (r != null) {
      return (marker: off[0]!, cond: r.cond, action: r.action);
    }
  }
  if (line.startsWith('#(')) {
    final r = parseRuleLine(line.substring(1));
    if (r != null) {
      return (marker: '#', cond: r.cond, action: r.action);
    }
  }
  return null;
}

/// 규칙 글 → 목록. 어떤 줄도 버리지 않는다 (빈 줄은 다음 칸의 [TriggerItem.gapBefore] 로).
List<TriggerItem> parseTriggerLibrary(String text) {
  final items = <TriggerItem>[];
  // 이어지는 주석 줄들 — 빈 줄 · 규칙 · 다른 줄을 만나면 메모 한 칸이 된다
  final pending = <String>[];
  bool pendingGap = false; // 그 주석 묶음 앞에 빈 줄이 있었나
  bool gap = false; // 지난 줄이 빈 줄이었나

  void flushNotes() {
    if (pending.isEmpty) {
      return;
    }
    items.add(TriggerNote(List.of(pending), gapBefore: pendingGap));
    pending.clear();
  }

  void addRule(String cond, String action, {required bool enabled, String marker = kTriggerOffMarker}) {
    flushNotes(); // 바로 위 주석은 메모 칸으로 (이 규칙은 그 바로 아래 — 빈 줄 없이)
    items.add(
      TriggerRule(
        enabled: enabled,
        cond: cond,
        action: action,
        offMarker: marker,
        gapBefore: gap,
      ),
    );
  }

  for (final raw in text.split('\n')) {
    final t = raw.trim();
    if (t.isEmpty) {
      flushNotes();
      gap = true;
      continue;
    }
    if (t.startsWith('#')) {
      final off = _disabledRule(t);
      if (off != null) {
        addRule(off.cond, off.action, enabled: false, marker: off.marker);
      } else {
        if (pending.isEmpty) {
          pendingGap = gap;
        }
        pending.add(t);
      }
      gap = false;
      continue;
    }
    final rule = parseRuleLine(t);
    if (rule != null) {
      addRule(rule.cond, rule.action, enabled: true);
    } else {
      flushNotes();
      items.add(TriggerNote([t], broken: true, gapBefore: gap));
    }
    gap = false;
  }
  flushNotes();
  return items;
}

/// 목록 → 규칙 글 (저장 · 실행되는 모양).
String serializeTriggerLibrary(List<TriggerItem> items) {
  final buf = StringBuffer();
  TriggerItem? prev;
  for (final it in items) {
    if (prev != null) {
      buf.write(_needsGap(prev, it) ? '\n\n' : '\n');
    }
    buf.write(it.toText());
    prev = it;
  }
  return buf.toString();
}

/// 두 칸 사이를 빈 줄로 띄울지.
///  메모 두 칸을 붙여 쓰면 다시 읽을 때 한 칸으로 합쳐진다 — 그럴 땐 사용자가 붙여 두었어도 띄운다.
bool _needsGap(TriggerItem prev, TriggerItem next) {
  if (next.gapBefore) {
    return true;
  }
  return prev is TriggerNote && !prev.broken && next is TriggerNote && !next.broken;
}

/// 입력칸의 글을 한 줄로 (줄바꿈이 들어가면 다음 줄이 따로 읽힌다)
String triggerOneLine(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

// ============================================================================
// 사람 말로 — 목록 칸 · 입력칸 아래 미리보기
// ============================================================================

/// 조건을 사람 말로. 끝까지 읽지 못한 조건은 원문 그대로 (무엇이 문제인지는 [conditionProblem]).
///  예) `1girl&!solo` → '1girl 있음 그리고 solo 없음',  `e|q` → '등급 e/q',  `*skirt` → '…skirt 있음'
///  & 는 '그리고', | 는 '또는' — 묶음은 ( ) 로 (화면은 괄호를 조금 굵게 그린다)
String describeCondition(String cond) {
  final r = parseCondition(cond);
  if (!r.complete || r.node is CondNothing) {
    return cond.trim();
  }
  return _sayCond(r.node);
}

String _sayCond(CondNode n) => switch (n) {
  CondPattern(isRating: true, :final pattern) => '등급 $pattern',
  final CondPattern p => '${_sayTag(p)} 있음',
  CondNot(inner: CondPattern(isRating: true, :final pattern)) => '등급 $pattern 아님',
  CondNot(inner: final CondPattern p) => '${_sayTag(p)} 없음',
  CondNot(:final inner) => '(${_sayCond(inner)}) 아님',
  CondAll(:final parts) => _flatAll(parts)
      .map((x) => x is CondAny ? '(${_sayCond(x)})' : _sayCond(x))
      .join(' 그리고 '),
  CondAny(:final parts) => _sayAny(_flatAny(parts)),
  CondNothing() => '(빈 자리)',
};

/// 태그 하나 — 따옴표로 묶어 적은 것은 따옴표째 ("nahida (genshin impact)") — 태그 속 괄호를 묶음 괄호로 오해하지 않게
String _sayTag(CondPattern p) => p.quoted ? '"${sayTagPattern(p.pattern)}"' : sayTagPattern(p.pattern);

/// `a|b|c` — 등급만이면 '등급 e/q', 태그만이면 'a 또는 b 있음'
String _sayAny(List<CondNode> parts) {
  if (parts.every((x) => x is CondPattern && x.isRating)) {
    return '등급 ${parts.map((x) => (x as CondPattern).pattern).join('/')}';
  }
  if (parts.every((x) => x is CondPattern && !x.isRating)) {
    return '${parts.map((x) => _sayTag(x as CondPattern)).join(' 또는 ')} 있음';
  }
  return parts.map((x) => x is CondAll ? '(${_sayCond(x)})' : _sayCond(x)).join(' 또는 ');
}

/// 같은 종류가 겹친 것((a&b)&c · (a|b)|c)을 한 줄로 편다 — 뜻은 같고 읽기 쉽다
List<CondNode> _flatAll(List<CondNode> parts) => [
  for (final p in parts)
    if (p is CondAll) ..._flatAll(p.parts) else p,
];

List<CondNode> _flatAny(List<CondNode> parts) => [
  for (final p in parts)
    if (p is CondAny) ..._flatAny(p.parts) else p,
];

/// 태그 무늬를 사람 말로 — `*` 자리를 '…' 로 (실행의 _isMatch 와 같은 순서로 본다)
///  `*skirt*` → '…skirt…' (포함),  `*skirt` → '…skirt' (끝),  `long*` → 'long…' (시작)
String sayTagPattern(String p) {
  if (p.startsWith('*') && p.endsWith('*') && p.length > 2) {
    return '…${p.substring(1, p.length - 1)}…';
  }
  if (p.startsWith('*') && p.length > 1) {
    return '…${p.substring(1)}';
  }
  if (p.endsWith('*') && p.length > 1) {
    return '${p.substring(0, p.length - 1)}…';
  }
  return p;
}

/// 조건에 쓸 수 없는 글자 — 쉼표. 태그는 쉼표로 나뉘므로 쉼표가 든 태그는 없다 (늘 거짓이 된다).
///  (< > : ; 같은 기호는 그 자체로 태그가 있어서 막지 않는다 — '>_<' · ':3')
///  입력칸은 이 글자를 아예 받지 않고, 글로 적은 규칙은 [conditionProblem] 이 알려 준다.
final RegExp kTriggerCondForbidden = RegExp(r'[,，]');

/// 조건의 문제 (없으면 null) — 한 줄로 짧게 (목록 칸 · 입력칸 아래에 그대로 보인다).
///  규칙 입력칸은 이게 있으면 저장하지 않는다. 기호는 ! & | 순서로 적는다.
String? conditionProblem(String cond) {
  if (cond.trim().isEmpty) {
    return "조건이 비어 있어요";
  }
  if (kTriggerCondForbidden.hasMatch(cond)) {
    return "조건에는 쉼표(,)를 쓸 수 없어요";
  }
  if (_condMemo.hasMatch(maskTriggerQuotes(cond, isCondition: true))) {
    return _memoProblem;
  }
  final r = parseCondition(cond);
  if (!r.complete) {
    // 이 규칙은 돌지 않는다 (실행이 끝까지 읽지 못한 조건은 거짓으로 본다) —
    //  괄호 짝이 틀렸거나, 태그 이름 속 ( ) 를 묶지 않고 썼을 때
    return "괄호 짝 · 기호 자리 확인 (기호 든 태그는 \"…\")";
  }
  if (_hasNothing(r.node)) {
    return "! & | 앞뒤가 비어 있어요";
  }
  return null;
}

bool _hasNothing(CondNode n) => switch (n) {
  CondNothing() => true,
  CondPattern() => false,
  CondNot(:final inner) => _hasNothing(inner),
  CondAll(:final parts) || CondAny(:final parts) => parts.any(_hasNothing),
};

/// 결과를 사람 말로 — (무엇을, 어떻게).  예) `skirt=pants` → ('바꾸기', 'skirt → pants')
({String verb, String detail}) describeAction(String action) {
  final p = parseTriggerAction(action);
  if (p.kind == TriggerActionKind.prepend) {
    return (verb: "긍정 앞에 추가", detail: p.b);
  }
  if (p.kind == TriggerActionKind.append) {
    return (verb: "긍정 뒤에 추가", detail: p.b);
  }
  if (p.kind == TriggerActionKind.remove) {
    return (verb: "지우기", detail: sayTagPattern(p.a));
  }
  if (p.kind == TriggerActionKind.replace) {
    return (verb: "바꾸기", detail: "${sayTagPattern(p.a)} → ${p.b}");
  }
  if (p.kind == TriggerActionKind.insertAfter) {
    return (verb: "끼워 넣기", detail: "${sayTagPattern(p.a)} 뒤에 ${p.b}");
  }
  if (p.kind == TriggerActionKind.unknown) {
    return (verb: "알 수 없음", detail: action.trim());
  }
  // 일부 바꾸기 — 실행: 맞는 태그 속의 A 글자(* 뺀 것)를 B 글자(* 뺀 것)로.
  //  A 글자가 없으면 태그를 통째로 B 로 (B 그대로, * 포함).
  final litA = p.a.replaceAll('*', '');
  final litB = p.b.replaceAll('*', '');
  if (litA.isEmpty) {
    return (verb: "바꾸기", detail: "${sayTagPattern(p.a)} → ${p.b}");
  }
  if (!p.a.contains('*')) {
    // 무늬가 없으면 태그 전체가 A 글자다 — 결국 통째로 바꾸기
    return litB.isEmpty ? (verb: "지우기", detail: p.a) : (verb: "바꾸기", detail: "${p.a} → $litB");
  }
  return litB.isEmpty
      ? (verb: "일부 지우기", detail: "${sayTagPattern(p.a)} 안의 $litA")
      : (verb: "일부 바꾸기", detail: "${sayTagPattern(p.a)} 안의 $litA → $litB");
}

/// A 자리가 비었을 때 — 잊었거나, '=_==x' 처럼 기호로 시작하는 태그를 묶지 않아 기호에서 잘렸거나
const String _emptyA = "앞 태그가 비었어요 (기호로 시작하면 \"…\")";

/// 줄 끝에 '# 메모' 를 붙였을 때 — 규칙 줄의 # 는 메모가 아니라 글자다 (조건이면 그 태그를 못 찾고, 결과면 그대로 들어간다).
///  '#' 로 시작하는 태그(#compass)는 기호 바로 뒤라 괜찮다 — 글자 뒤에 띄우고 # 가 올 때만 본다. 묶음 안은 보지 않는다.
///  ⚠️ 예전 가중치 규칙은 줄 끝 # 메모를 받아 줬다 — 그 버릇대로 적으면 'c #메모' 가 프롬프트에 들어갔다.
const String _memoProblem = "줄 끝 # 메모는 안 돼요 (글자로 들어가요)";
final RegExp _condMemo = RegExp(r'[^\s&|!(]\s+#');
final RegExp _actionMemo = RegExp(r'[^\s=^+,]\s+#');

/// 결과의 문제 (없으면 null) — 한 줄로 짧게. 규칙 입력칸은 이게 있으면 저장하지 않는다.
String? actionProblem(String action) {
  if (_actionMemo.hasMatch(maskTriggerQuotes(action, isCondition: false))) {
    return _memoProblem;
  }
  final p = parseTriggerAction(action);
  if (p.kind == TriggerActionKind.unknown) {
    return "결과 꼴이 아니에요 (A=B · A^B · A+B …)";
  }
  if (p.kind == TriggerActionKind.prepend || p.kind == TriggerActionKind.append) {
    return p.b.isEmpty ? "추가할 내용이 비어 있어요" : null;
  }
  if (p.kind == TriggerActionKind.insertAfter) {
    if (p.a.isEmpty) {
      return _emptyA;
    }
    return p.b.isEmpty ? "+ 뒤에 넣을 내용을 적어 주세요" : null;
  }
  if (p.a.isEmpty) {
    return _emptyA;
  }
  final lower = p.a.toLowerCase();
  if (lower == 'prefix' || lower == 'suffix') {
    return "prefix= · suffix= 는 소문자로 붙여 써요";
  }
  return null;
}

/// 규칙 입력칸에서 저장을 막는 문제 (없으면 null). [cond] · [action] 은 한 줄로 다듬은 것.
String? ruleInputProblem(String cond, String action) {
  if (cond.isEmpty) {
    return "조건을 적어 주세요";
  }
  if (action.isEmpty) {
    return "결과를 적어 주세요";
  }
  // 글로 썼다 다시 읽어도 같은 규칙이어야 한다 — 조건의 괄호 짝이 틀리면 엉뚱한 곳에서 잘린다
  final back = parseRuleLine('($cond):$action');
  if (back == null || back.cond != cond || back.action != action) {
    return "조건의 괄호나 따옴표 짝이 안 맞아요";
  }
  return conditionProblem(cond) ?? actionProblem(action);
}

/// 규칙 한 줄 요약 — '등급 q/e → 긍정 앞에 추가 · nsfw' (프롬프트탭 칸 · 삭제 확인 · 테스트 칸)
String triggerRuleSummary(TriggerRule r) {
  final act = describeAction(r.action);
  return '${describeCondition(r.cond)} → ${act.verb} · ${act.detail}';
}

// ============================================================================
// 입력칸 자동완성 — 조건 · 결과 칸 전용
//  프롬프트 칸의 자동완성(PromptUtils.buildCompletedText)은 태그 뒤에 ', ' 를 붙여 조건 문법을 깨뜨린다.
//  여기서는 지금 적고 있는 태그만 바꿔 끼우고, 아무것도 덧붙이지 않는다.
// ============================================================================

/// 조건 칸에서 태그를 끊는 글자 — ! & | ( )
const String _condDelimiters = '&|!()';

/// 결과 칸에서 태그를 끊는 글자 — = ^ + ,  (A=B · A^B · A+B · 'B, C')
const String _actionDelimiters = '=^+,';

final RegExp _leadStars = RegExp(r'^\**');
final RegExp _tailStars = RegExp(r'\**$');
final RegExp _actionOperator = RegExp(r'[=^+]');

bool _isQuoteChar(String c) => c == '"' || c == "'";

/// 결과 칸의 낱말 후보 (자동완성) — 태그가 아니라 문법이다
const List<String> kTriggerActionKeywords = ['prefix=', 'suffix='];

/// 자동완성 후보가 태그가 아니라 낱말(prefix= · suffix=)인지.
///  ⚠️ '= 로 끝나면 낱말'로 보면 '=_=' 같은 태그를 낱말로 넣는다.
bool isTriggerKeyword(String s) => kTriggerActionKeywords.contains(s);

/// 이 태그를 그 칸에 넣을 때 따옴표로 묶어야 하는지 — 그 칸의 문법 기호가 들었거나, 따옴표로 시작하거나,
///  (조건 칸) 등급 글자 하나(g s q e)라서 태그로 읽히지 않을 때.
bool triggerTagNeedsQuote(String tag, {required bool isCondition}) {
  if (tag.isNotEmpty && _isQuoteChar(tag[0])) {
    return true;
  }
  if (isCondition) {
    return tag.contains(RegExp(r'[&|!()]')) || const ['g', 's', 'q', 'e'].contains(tag.toLowerCase());
  }
  return tag.contains(_actionOperator);
}

/// 커서 자리에서 '지금 적고 있는 태그' — 자동완성 후보를 찾고, 고른 후보로 바꿔 넣을 때 쓴다.
///  [start]~[end] 는 바꿔 넣을 자리 (커서 뒤에 이어진 글자까지 — 단어 가운데서 골라도 단어째 바뀐다),
///  [query] 는 후보를 찾을 글 (커서 앞까지, * · 따옴표는 뺀다), [lead] · [tail] 은 앞뒤의 * (고른 태그에 다시 붙인다),
///  [quote] 는 그 낱말을 묶은 따옴표 ('' = 안 묶음).
///  따옴표 묶음 안의 구분 글자에서는 끊지 않는다 (실행과 같은 규칙 — 낱말 맨 앞에서만 연다).
///  적는 중이라 닫는 따옴표가 아직 없으면 글 끝까지 묶음으로 본다 ('"la+ dar' 를 적는 중 → la+ dar 로 찾는다).
///  찾을 글이 비면 null.  구분 글자 · 따옴표 · * 는 한 글자라 그 자리에서 잘라도 이모지를 쪼개지 않는다.
({int start, int end, String lead, String tail, String query, String quote})? triggerWordAt(
  String text,
  int cursor, {
  required bool isCondition,
}) {
  final delims = isCondition ? _condDelimiters : _actionDelimiters;
  if (cursor < 0 || cursor > text.length) {
    cursor = text.length;
  }
  // 낱말 나누기 — (시작, 끝, 여는 따옴표 자리 · 없으면 -1, 닫는 따옴표 자리 · 없으면 -1)
  final spans = <({int s, int e, int open, int close})>[];
  int s = 0;
  int open = -1;
  int close = -1;
  bool termStart = true;
  for (int i = 0; i < text.length; i++) {
    final c = text[i];
    if (termStart && _isQuoteChar(c)) {
      open = i;
      close = text.indexOf(c, i + 1);
      if (close == -1) {
        break; // 닫기 전 — 글 끝까지 묶음
      }
      i = close;
      termStart = false;
      continue;
    }
    if (delims.contains(c)) {
      spans.add((s: s, e: i, open: open, close: close));
      s = i + 1;
      open = -1;
      close = -1;
      termStart = true;
    } else if (c != ' ' && c != '*') {
      termStart = false;
    }
  }
  spans.add((s: s, e: text.length, open: open, close: close));
  final span = spans.firstWhere((x) => x.s <= cursor && cursor <= x.e, orElse: () => spans.last);

  int start = span.s;
  while (start < cursor && text[start] == ' ') {
    start++;
  }
  int end = span.e;
  while (end > cursor && text[end - 1] == ' ') {
    end--;
  }
  final whole = text.substring(start, end);
  final lead = _leadStars.firstMatch(whole)![0]!;
  if (span.open != -1) {
    // 따옴표로 묶은 낱말 — 찾을 글은 따옴표 안 (커서까지)
    final innerEnd = span.close == -1 ? end : span.close;
    if (cursor <= span.open) {
      return null;
    }
    final query = text.substring(span.open + 1, cursor < innerEnd ? cursor : innerEnd).replaceAll('*', '').trim();
    if (query.isEmpty) {
      return null;
    }
    final after = span.close == -1 ? '' : text.substring(span.close + 1, end);
    return (
      start: start,
      end: end,
      lead: lead,
      tail: _tailStars.firstMatch(after)![0]!,
      query: query,
      quote: text[span.open],
    );
  }
  final rest = whole.substring(lead.length);
  final tail = rest.isEmpty ? '' : _tailStars.firstMatch(rest)![0]!;
  final query = text.substring(start, cursor).replaceAll('*', '').trim();
  if (query.isEmpty) {
    return null;
  }
  return (start: start, end: end, lead: lead, tail: tail, query: query, quote: '');
}

/// 자동완성 후보 [tag] 를 커서 자리의 태그 대신 넣는다 → (새 글, 새 커서 자리).
///  앞뒤의 * 는 그대로 살리고(무늬 유지), 쉼표 · 공백은 덧붙이지 않는다.
///  그 칸의 기호가 든 태그(조건 칸의 'nahida (genshin impact)' · 결과 칸의 'la+ darknesss')나
///  이미 따옴표로 묶어 적던 낱말은 따옴표로 묶어 넣는다 — 묶는 따옴표는 적던 것, 없으면 " (태그에 " 가 있으면 ').
///  결과 칸에서 쉼표 바로 뒤면 한 칸 띄운다 ('a,b' → 'a, b').
///  'prefix=' · 'suffix=' 낱말은 * · 따옴표 없이 그대로 넣는다 (커서는 = 뒤 — 이어서 B 를 적는다).
({String text, int cursor}) applyTriggerSuggestion(
  String text,
  int cursor,
  String tag, {
  required bool isCondition,
}) {
  final w = triggerWordAt(text, cursor, isCondition: isCondition);
  if (w == null) {
    return (text: text, cursor: cursor.clamp(0, text.length));
  }
  String head = text.substring(0, w.start);
  if (!isCondition && head.endsWith(',')) {
    head = '$head ';
  }
  String insert;
  if (isTriggerKeyword(tag)) {
    insert = tag;
  } else if (w.quote.isNotEmpty || triggerTagNeedsQuote(tag, isCondition: isCondition)) {
    final q = w.quote.isNotEmpty && !tag.contains(w.quote) ? w.quote : (tag.contains('"') ? "'" : '"');
    insert = '${w.lead}$q$tag$q${w.tail}';
  } else {
    insert = '${w.lead}$tag${w.tail}';
  }
  return (text: '$head$insert${text.substring(w.end)}', cursor: head.length + insert.length);
}

/// 결과 칸 맨 앞(= · ^ · + 를 적기 전)에서 보여 줄 낱말 후보 — 'pr' → prefix=, 'su' → suffix=
///  ⚠️ 예전엔 + 뒤에서도 보여서, 'smile+pr' 에서 고르면 'smile+prefix=' 가 되어
///     'smile+prefix' 태그를 지우는 엉뚱한 규칙이 됐다.
List<String> triggerActionKeywords(String textBeforeCursor, String query) {
  if (_actionOperator.hasMatch(textBeforeCursor)) {
    return const [];
  }
  final q = query.toLowerCase();
  return [
    for (final k in kTriggerActionKeywords)
      if (k.startsWith(q)) k,
  ];
}

// ============================================================================
// 테스트 칸
// ============================================================================

/// 예시 프롬프트에 지금 목록(켜진 규칙만)을 실제 실행과 똑같이 적용해 본다.
///  [sectioned] = '이미지 생성 시' 모드 (예시는 긍정 프롬프트 자리에 둔다).
///  [hits] = 조건이 맞은 규칙들 (적용 순서대로).
///  [changed] = 규칙이 실제로 바꾼 것이 있는지. 랜덤 프롬프트 모드는 규칙과 상관없이 띄어쓰기 · 빈 칸 · 겹친 태그를
///  정리하므로(normalizeRandomPrompt) 그 정리만 된 것은 '바뀐 것 없음'으로 본다.
///  ⚠️ 예전엔 결과를 예시와 글자 그대로 비교해서, 줄바꿈이 든 긍정 프롬프트를 가져오면 아무 규칙도 안 걸려도 '바뀜'으로 보였다.
({String result, List<TriggerRule> hits, bool changed}) runTriggerTest(
  List<TriggerItem> items,
  String sample,
  String rating, {
  required bool sectioned,
}) {
  final text = serializeTriggerLibrary(items);
  final enabled = [
    for (final it in items)
      if (it is TriggerRule && it.enabled) it,
  ];
  final hitAt = <int>[];
  final result = sectioned
      ? applyConditionalRulesSectioned('', sample, '', rating, text, onHit: hitAt.add).positive
      : applyConditionalRules(sample, rating, text, onHit: hitAt.add);
  // 실행이 읽은 규칙 수가 목록과 다르면 번호를 맞출 수 없다 — 엉뚱한 칸을 가리키지 않게 비운다
  final sameCount = parseConditionalRules(text).length == enabled.length;
  final changed = sectioned
      ? result != sample
      : result != sample && result != normalizeRandomPrompt(sample);
  return (
    result: result,
    hits: sameCount ? [for (final i in hitAt) enabled[i]] : <TriggerRule>[],
    changed: changed,
  );
}
