// lib/models/prompt_search.dart
//
// 프롬프트 검색(Gelbooru)의 글자 처리 — 순수 함수들.
//  · 검색어 펼치기: {A|B} · *키워드 → 검색 묶음들(SearchPlan) / 받은 뒤 거를 제외 태그
//  · 받은 목록 한 칸 풀기: JSON(태그 · 크기 · 등급 · 캐릭터 표시) 또는 아주 예전의 그냥 글자
//  · 받은 태그 다듬기: 이름 · 잡동사니 · 설정에 따른 특징/의상/색/중복 · 개별 제거 규칙 · 선행/후행과 겹치는 것
//
// 예전엔 AppState 안에 있었다 (_expandWildcardForSearch · _processAndSetPrompt).
//  화면 · 저장소와 무관해서 여기로 옮겼고, 테스트로 묶는다 (test/prompt_search_test.dart).
//  검색을 돌리고 결과를 보관하는 쪽(상태)은 app_state_search.dart.
import 'dart:convert';
import 'dart:math';

import '../tag_filters.dart';

// ============================================================================
// 검색어 펼치기
// ============================================================================
//  포함 칸은 프롬프트의 {A|B} 와 같은 '틀' 로 읽는다 — 고를 수 있는 모든 조합 하나하나가 검색 묶음 하나다.
//   · {A|B}               → A 또는 B                         (묶음 2개: [A] · [B])
//   · {A|B}, {C|D}        → (A 또는 B) 그리고 (C 또는 D)      (묶음 4개: AC · AD · BC · BD)
//   · {red|blue} hair     → red hair 또는 blue hair            (글자 안에 끼워 넣기)
//   · {cat ears, tail|dog ears} → (cat ears 와 tail) 또는 dog ears  (보기 하나에 태그 여럿)
//   · {a|{b|c}}           → a · b · c 중 하나                  (겹친 괄호)
//   · *keyword            → 태그 사전에서 그 글자가 든 태그 중 하나 (앞에서 20개)
//   · ~A, ~B (예전 방식)  → {A|B} 와 같다
//  ⚠️ 예전엔 {} 를 전부 ~태그로 바꿔 한 줄로 이었다. 그래서 {A|B}, {C|D} 가 'A·B·C·D 중 아무거나' 로 풀렸고,
//     {red|blue} hair 는 red · blue_hair 로, {cat ears, tail|dog ears} 는 tail 을 모든 묶음에 붙였고,
//     겹친 괄호는 '{b' · 'c}' 같은 깨진 태그를 그대로 보냈다.
//  조합 수는 곱으로 커진다 — 받을 페이지 수보다 많으면 보기가 많은 조각부터 겔부루의 '또는 묶음' {a ~ b ~ c} 으로
//  합쳐 검색 수를 줄인다 (SearchPlan.queries). 그래도 넘치면(합칠 수 없는 조각뿐) 고르게 골라 그만큼만 검색한다.

/// 포함 칸 *keyword 가 펼쳐지는 태그 수 (예전과 같다)
const int kSearchKeywordMatches = 20;

/// 제외 칸 *keyword 가 펼쳐지는 태그 수 — 제외는 넉넉하게
const int kExcludeKeywordMatches = 50;

/// 겔부루 '또는 묶음' {a ~ b ~ …} 하나에 넣는 태그 수 상한 (검색어가 너무 길어지지 않게)
const int kSearchOrGroupMax = 20;

/// 맨 바깥 쉼표 조각 하나를 보기로 다 펼쳐 둘 때의 상한 — 넘으면 합치기 없이 고르기만 한다
const int _kFactorEnumerateMax = 2000;

/// 틀의 한 조각 — 글자 · 이어 붙이기 · 고르기
abstract class _Tpl {
  /// 이 조각이 만들 수 있는 글 수 (아주 크면 [_kHuge] 에서 멈춘다)
  int get count;

  /// [index] (0 ~ count-1) 번째 글을 [out] 에 쓴다 — count 가 [_kHuge] 보다 작을 때만 정확하다
  void emit(int index, StringBuffer out);

  /// 보기마다 (조합 수에 비례해) 하나씩 무작위로 골라 [out] 에 쓴다 — 조합이 아주 많을 때
  void emitRandom(Random r, StringBuffer out);
}

/// 조합 수 상한 — 넘으면 '아주 많다' 로만 센다 (곱이 넘치지 않게). SearchPlan.combinations 가 이 값이면 '셀 수 없이 많음'.
const int kSearchCombinationCap = 1 << 50;
const int _kHuge = kSearchCombinationCap;

int _mulSat(int a, int b) => (a == 0 || b == 0) ? 0 : (a > _kHuge ~/ b ? _kHuge : a * b);
int _addSat(int a, int b) => min(_kHuge, a + b);

class _Lit extends _Tpl {
  _Lit(this.text);
  final String text;

  @override
  int get count => 1;

  @override
  void emit(int index, StringBuffer out) => out.write(text);

  @override
  void emitRandom(Random r, StringBuffer out) => out.write(text);
}

class _Seq extends _Tpl {
  _Seq(this.parts) : count = parts.fold(1, (c, p) => _mulSat(c, p.count));
  final List<_Tpl> parts;

  @override
  final int count;

  @override
  void emit(int index, StringBuffer out) {
    // 섞인 진법 — 조각마다 자기 자리의 숫자를 꺼낸다
    int rest = index;
    for (final p in parts) {
      final int c = p.count;
      p.emit(rest % c, out);
      rest ~/= c;
    }
  }

  @override
  void emitRandom(Random r, StringBuffer out) {
    for (final p in parts) {
      p.emitRandom(r, out);
    }
  }
}

class _Choice extends _Tpl {
  _Choice(this.options) : count = options.fold(0, (c, o) => _addSat(c, o.count));
  final List<_Tpl> options;

  @override
  final int count;

  @override
  void emit(int index, StringBuffer out) {
    int rest = index;
    for (final o in options) {
      if (rest < o.count) {
        o.emit(rest, out);
        return;
      }
      rest -= o.count;
    }
  }

  @override
  void emitRandom(Random r, StringBuffer out) {
    // 조합이 많은 보기를 그만큼 자주 — 모든 조합이 고르게 뽑히게
    int pick = r.nextInt(max(1, min(count, 1 << 31)));
    for (final o in options) {
      final int c = min(o.count, 1 << 31);
      if (pick < c) {
        o.emitRandom(r, out);
        return;
      }
      pick -= c;
    }
    options.last.emitRandom(r, out);
  }
}

/// [s] 의 [open] 자리 '{' 에 짝이 되는 '}' 가 있는지
bool _hasClose(String s, int open) {
  int depth = 0;
  for (int i = open; i < s.length; i++) {
    final String ch = s[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return true;
      }
    }
  }
  return false;
}

/// 글 → 틀. 짝 없는 괄호 · 괄호 밖의 '|' 는 글자 그대로 둔다 (자르는 곳은 늘 ASCII 기호라 이모지가 안 깨진다).
_Tpl _parseTemplate(String s) {
  int i = 0;
  _Tpl seq(bool inChoice) {
    final parts = <_Tpl>[];
    final lit = StringBuffer();
    void flush() {
      if (lit.isNotEmpty) {
        parts.add(_Lit(lit.toString()));
        lit.clear();
      }
    }

    while (i < s.length) {
      final String ch = s[i];
      if (inChoice && (ch == '|' || ch == '}')) {
        break;
      }
      if (ch == '{' && _hasClose(s, i)) {
        flush();
        i++; // '{'
        final options = <_Tpl>[seq(true)];
        while (i < s.length && s[i] == '|') {
          i++;
          options.add(seq(true));
        }
        i++; // '}' (_hasClose 가 있다고 확인했다)
        parts.add(_Choice(options));
        continue;
      }
      lit.write(ch);
      i++;
    }
    flush();
    return parts.length == 1 ? parts.first : _Seq(parts);
  }

  return seq(false);
}

/// 쉼표로 나누되 괄호 안의 쉼표는 나누지 않는다
List<String> _splitTopLevel(String s) {
  final out = <String>[];
  int depth = 0;
  int from = 0;
  for (int i = 0; i < s.length; i++) {
    final String ch = s[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}' && depth > 0) {
      depth--;
    } else if (ch == ',' && depth == 0) {
      out.add(s.substring(from, i));
      from = i + 1;
    }
  }
  out.add(s.substring(from));
  return out;
}

/// *keyword → {사전 태그1|사전 태그2|…} (사전에 없으면 키워드 글자 그대로).
///  쉼표 · '{' · '|' 바로 뒤(또는 맨 앞)의 * 만 본다. 괄호 · '|' · 쉼표가 든 사전 태그는 틀을 깨므로 뺀다.
final RegExp _keywordToken = RegExp(r'(^|[,{|])(\s*)\*([^,{}|]*[^,{}|\s])');
final RegExp _templateChars = RegExp(r'[,{}|]');

String _expandKeywords(String input, List<String> tagDb, int limit) {
  return input.replaceAllMapped(_keywordToken, (m) {
    final String keyword = m.group(3)!.trim().toLowerCase().replaceAll(_spaces, '_');
    final matches = tagDb
        .where((t) => t.contains(keyword) && !t.contains(_templateChars))
        .take(limit)
        .map((t) => t.replaceAll('_', ' '))
        .toList();
    final String body = matches.isEmpty ? keyword.replaceAll('_', ' ') : '{${matches.join('|')}}';
    return '${m.group(1)}${m.group(2)}$body';
  });
}

/// 띄어쓰기 한 칸 이상 (태그 안의 띄어쓰기 → _ 한 개)
final RegExp _spaces = RegExp(r'\s+');

/// 글 하나 → 태그 목록 (쉼표로 나눠 다듬고, 띄어쓰기는 _ 로, 소문자로, 같은 태그는 한 번만)
List<String> _tagsOf(String text, {bool stripTilde = false}) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in text.split(',')) {
    String t = raw.trim();
    if (stripTilde) {
      while (t.startsWith('~')) {
        t = t.substring(1).trim(); // ~ 는 ASCII 한 글자 — 앞에서 떼어도 이모지가 안 깨진다
      }
    }
    // 띄어쓰기가 여러 칸이어도 _ 하나로 — 예전엔 'long  hair' 가 long__hair 가 돼 결과가 0 이었다
    t = t.replaceAll(_spaces, '_');
    // 태그 이름은 모두 소문자다 — 폰 키보드가 첫 글자를 대문자로 바꿔도(Long_hair) 사전 · 검색과 맞게.
    //  ⚠️ 예전엔 대문자가 그대로 남아 사전 순위를 못 찾았다 → '또는 묶음' 으로 못 합쳐 일부 조합만 검색했다.
    //  ':' 가 든 것(user:이름 · md5: 같은 메타 검색)은 값이 대소문자를 탈 수 있어 그대로 둔다.
    if (!t.contains(':')) {
      t = t.toLowerCase();
    }
    if (t.isNotEmpty && seen.add(t)) {
      out.add(t);
    }
  }
  return out;
}

/// 포함 칸을 푼 검색 계획 — 고를 수 있는 조합 하나하나가 검색 묶음이다.
class SearchPlan {
  SearchPlan._(this._tpl, this._factors, this._rank);
  final _Tpl _tpl;

  /// 맨 바깥 쉼표 조각들 (서로 '그리고') — 조각마다 보기들, 보기 하나 = 태그들. 너무 커서 못 펼쳤으면 null.
  final List<List<List<String>>>? _factors;

  /// 한 태그짜리 보기의 사전 순위 (0 = 그림이 가장 많은 태그). 사전에 없는 태그는 없다.
  final Map<String, int> _rank;

  /// 포함 칸에 적은 태그 전부 (밑줄 모양 · 소문자) — 보기 하나하나 · *키워드가 펼쳐진 것까지.
  ///  빼기(-) · 메타(:) · 와일드카드 · 또는 묶음 기호가 든 것은 뺀다 (태그 이름이 아니다).
  ///  받은 태그에서 이것들은 '검색한 태그' 로 표시해, 잡동사니 목록 · 특징/의상 제거 같은 자동 정리에서 지킨다.
  Set<String> get searchedTags => {
    for (final t in _allTagsOf(_tpl, stripTilde: true))
      if (_orSafe(t)) t,
  };

  /// 전체 조합 수 ([kSearchCombinationCap] 을 넘으면 그 값에서 멈춘다)
  int get combinations {
    final f = _factors;
    if (f == null) {
      return _tpl.count;
    }
    return f.fold(1, (c, alts) => _mulSat(c, alts.length));
  }

  /// 검색 묶음들 — 묶음 하나 = 함께 찾을 태그들 (띄어쓰기는 _). 같은 묶음은 한 번만.
  ///  조합이 [maxGroups] 이하면 전부, 넘으면 고르게 [maxGroups] 개를 고른다 (검색할 때마다 다르게).
  List<List<String>> pick(int maxGroups, [Random? random]) {
    final int limit = max(1, maxGroups);
    final out = <List<String>>[];
    final keys = <String>{};
    void add(String text) {
      final tags = _tagsOf(text, stripTilde: true);
      if (keys.add(([...tags]..sort()).join(' '))) {
        out.add(tags);
      }
    }

    final int total = _tpl.count;
    if (total <= limit) {
      for (int i = 0; i < total; i++) {
        final b = StringBuffer();
        _tpl.emit(i, b);
        add(b.toString());
      }
      return out;
    }
    final Random r = random ?? Random();
    if (total <= 200000) {
      // 번호를 겹치지 않게 뽑는다 — 고른 조합이 정확히 고르게 퍼진다
      final picked = <int>{};
      while (picked.length < limit) {
        picked.add(r.nextInt(total));
      }
      for (final i in picked) {
        final b = StringBuffer();
        _tpl.emit(i, b);
        add(b.toString());
      }
      return out;
    }
    // 아주 많으면 보기마다 무작위로 — 같은 조합이 또 나오면 다시 (넉넉히 시도하고 멈춘다)
    for (int tries = 0; out.length < limit && tries < limit * 20; tries++) {
      final b = StringBuffer();
      _tpl.emitRandom(r, b);
      add(b.toString());
    }
    return out;
  }

  /// 보낼 검색 묶음들 — 받을 페이지 수 [budget] 안에서 되도록 많은 조합을 담는다.
  ///  · 조합이 [budget] 이하면 조합마다 하나 ([pick] 과 같다 — 보기마다 고르게 나와 가장 좋다).
  ///  · 넘으면 보기가 가장 많은 조각부터 조금씩 겔부루의 '또는 묶음' `{a ~ b ~ c}` 으로 합쳐 묶음 수를 줄인다
  ///    → 묶음 수가 [budget] 이하가 되면 **모든 조합**이 검색에 들어간다.
  ///    한 묶음에는 사전 순위가 비슷한 태그끼리 넣는다 — 흔한 태그가 드문 태그를 덮지 않게.
  ///  · 합칠 수 있는 조각: 보기가 모두 태그 하나이고, 그 태그가 태그 사전에 있으며(겔부루의 '또는' 은
  ///    다른 이름(별칭)을 못 알아듣는다), 빼기(-) · 메타(:) · 와일드카드(*) 가 아닌 것.
  ///    합칠 조각이 모자라 그래도 넘치면, 그만큼만 고르게 골라 검색한다.
  ///  [covered] = 검색에 들어간 조합 수 (모두면 [combinations] 와 같다).
  ({List<List<String>> groups, int covered}) queries(int budget, [Random? random]) {
    final int limit = max(1, budget);
    final factors = _factors;
    final int total = combinations;
    if (factors == null || total <= limit) {
      final g = pick(limit, random);
      return (groups: g, covered: total <= limit ? total : g.length);
    }
    final Random r = random ?? Random();

    // 보기가 하나뿐인 조각은 모든 묶음에 붙는 태그, 둘 이상이면 고를 조각
    final fixed = <String>[];
    final choices = <List<List<String>>>[];
    for (final alts in factors) {
      if (alts.length == 1) {
        fixed.addAll(alts.first);
      } else {
        choices.add(alts);
      }
    }
    bool mergeable(List<List<String>> alts) =>
        alts.every((a) => a.length == 1 && _rank.containsKey(a.first) && _orSafe(a.first));

    // 조각마다 칸 수 — 처음엔 보기 하나에 한 칸. 넘치는 동안 합칠 수 있는 조각 중 칸이 가장 많은 것을 한 칸씩 줄인다
    //  (반씩 줄이면 48 조합 · 페이지 40 이 24 묶음까지 줄어 고르기가 덜 된다 — 한 칸씩이면 36 묶음).
    final List<int> k = [for (final c in choices) c.length];
    int product() => k.fold(1, (p, x) => _mulSat(p, x));
    while (product() > limit) {
      int best = -1;
      for (int i = 0; i < choices.length; i++) {
        if (k[i] <= 1 || !mergeable(choices[i])) {
          continue;
        }
        final int next = k[i] - 1;
        if ((choices[i].length + next - 1) ~/ next > kSearchOrGroupMax) {
          continue; // 한 칸이 너무 커진다
        }
        if (best < 0 || k[i] > k[best]) {
          best = i;
        }
      }
      if (best < 0) {
        break; // 더 합칠 수 없다 — 아래에서 고른다
      }
      k[best]--;
    }

    // 칸 만들기 — 칸 하나 = 묶음에 들어갈 태그들 · 담는 보기 수
    final List<List<({List<String> tags, int size})>> cells = [];
    for (int i = 0; i < choices.length; i++) {
      final alts = choices[i];
      if (k[i] == alts.length) {
        cells.add([for (final a in alts) (tags: a, size: 1)]);
        continue;
      }
      // 사전 순위로 줄 세워 차례로 자른다 — 그림 수가 비슷한 태그끼리 한 칸 (칸 크기는 많아야 1 차이)
      final sorted = [for (final a in alts) a.first]..sort((x, y) => _rank[x]!.compareTo(_rank[y]!));
      final row = <({List<String> tags, int size})>[];
      for (int b = 0; b < k[i]; b++) {
        final part = sorted.sublist(b * sorted.length ~/ k[i], (b + 1) * sorted.length ~/ k[i]);
        row.add((tags: part.length == 1 ? part : ['{${part.join(' ~ ')}}'], size: part.length));
      }
      cells.add(row);
    }

    // 칸 조합 = 검색 묶음. 많으면 겹치지 않게 고른다.
    final int q = product();
    final groups = <List<String>>[];
    int covered = 0;
    void addCombo(List<int> choice) {
      final seen = <String>{};
      final tags = <String>[];
      int size = 1;
      for (final t in fixed) {
        if (seen.add(t)) {
          tags.add(t);
        }
      }
      for (int i = 0; i < choice.length; i++) {
        final cell = cells[i][choice[i]];
        size = _mulSat(size, cell.size);
        for (final t in cell.tags) {
          if (seen.add(t)) {
            tags.add(t);
          }
        }
      }
      groups.add(tags);
      covered = _addSat(covered, size);
    }

    // 섞인 진법 — 번호 → 조각마다 몇 번째 칸
    List<int> decode(int index) {
      int rest = index;
      final out = <int>[];
      for (final n in k) {
        out.add(rest % n);
        rest ~/= n;
      }
      return out;
    }

    if (q <= limit) {
      for (int i = 0; i < q; i++) {
        addCombo(decode(i));
      }
    } else if (q <= 200000) {
      final picked = <int>{};
      while (picked.length < limit) {
        picked.add(r.nextInt(q));
      }
      for (final i in picked) {
        addCombo(decode(i));
      }
    } else {
      final picked = <String>{};
      for (int tries = 0; picked.length < limit && tries < limit * 20; tries++) {
        final choice = [for (final n in k) r.nextInt(min(n, 1 << 31))];
        if (picked.add(choice.join(','))) {
          addCombo(choice);
        }
      }
    }
    return (groups: groups, covered: covered);
  }
}

/// 겔부루 '또는 묶음' 에 넣어도 되는 태그인지 — 빼기 · 메타 · 와일드카드 · 묶음 기호가 없는 것
bool _orSafe(String tag) => tag.isNotEmpty && !tag.startsWith('-') && !tag.contains(_notInOrGroup);
final RegExp _notInOrGroup = RegExp(r'[:*~{}\s]');

/// 포함 칸 → 검색 계획. [tagDb] 는 *keyword 를 펼칠 태그 사전 (밑줄 모양).
SearchPlan parseSearchInclude(String input, List<String> tagDb) {
  final String text = _expandKeywords(input, tagDb, kSearchKeywordMatches);
  // 예전 방식 ~A, ~B — 맨 바깥(괄호 밖)의 ~태그들은 함께 하나의 {A|B} 로 모은다
  final keep = <String>[];
  final legacyOr = <String>[];
  for (final token in _splitTopLevel(text)) {
    final String t = token.trim();
    if (t.startsWith('~') && !t.contains('{')) {
      legacyOr.add(t.substring(1).trim());
    } else {
      keep.add(token);
    }
  }
  final String joined = [
    ...keep,
    if (legacyOr.isNotEmpty) '{${legacyOr.join('|')}}',
  ].join(',');

  // 맨 바깥 쉼표 조각마다 보기를 펼쳐 둔다 (조각끼리는 '그리고' — 괄호 안 쉼표는 조각을 나누지 않으므로 서로 묶이지 않는다).
  //  조합이 많을 때 '또는 묶음' 으로 합치는 데 쓴다 (SearchPlan.queries).
  final factorList = <List<List<String>>>[];
  bool tooBig = false;
  for (final token in _splitTopLevel(joined)) {
    final t = _parseTemplate(token);
    if (t.count > _kFactorEnumerateMax) {
      tooBig = true; // 너무 크다 — 합치기 없이 고르기만
      break;
    }
    final alts = <List<String>>[];
    final keys = <String>{};
    for (int i = 0; i < t.count; i++) {
      final b = StringBuffer();
      t.emit(i, b);
      final tags = _tagsOf(b.toString(), stripTilde: true);
      if (keys.add(([...tags]..sort()).join(' '))) {
        alts.add(tags);
      }
    }
    factorList.add(alts);
  }
  final List<List<List<String>>>? factors = tooBig ? null : factorList;

  // 한 태그짜리 보기의 사전 순위 — 태그 사전은 그림 수 많은 순이다 (AppState._loadTagsFromJson)
  final need = <String>{
    for (final alts in factors ?? const <List<List<String>>>[])
      if (alts.length > 1)
        for (final a in alts)
          if (a.length == 1) a.first,
  };
  final rank = <String, int>{};
  for (int i = 0; i < tagDb.length && rank.length < need.length; i++) {
    if (need.contains(tagDb[i])) {
      rank.putIfAbsent(tagDb[i], () => i);
    }
  }
  return SearchPlan._(_parseTemplate(joined), factors, rank);
}

/// 제외 칸 → 받은 뒤 거를 태그들 (밑줄 모양). {A|B} 는 둘 다, {red|blue} hair 는 red_hair · blue_hair,
///  *keyword 는 사전에서 그 글자가 든 태그 50개 (사전에 없으면 키워드 그대로).
List<String> expandExcludeForSearch(String input, List<String> tagDb) =>
    _allTagsOf(_parseTemplate(_expandKeywords(input, tagDb, kExcludeKeywordMatches)));

/// 틀에서 나올 수 있는 태그 전부 (밑줄 모양 · 처음 나온 순서 · 한 번씩).
///  제외 칸 펼치기(expandExcludeForSearch)와 포함 칸의 '검색한 태그'(SearchPlan.searchedTags)가 같이 쓴다.
List<String> _allTagsOf(_Tpl tpl, {bool stripTilde = false}) {
  final seen = <String>{};
  final out = <String>[];
  void addAll(String text) {
    for (final t in _tagsOf(text, stripTilde: stripTilde)) {
      if (seen.add(t)) {
        out.add(t);
      }
    }
  }

  // 펼친 글 전부에 나오는 태그 — 조합이 너무 많으면 괄호마다 보기를 쉼표로 늘어놓는다
  //  (괄호 옆에 글자를 붙인 {red|blue} hair 같은 모양은 이때만 덜 정확하다)
  const int enumerateLimit = 2000;
  if (tpl.count <= enumerateLimit) {
    for (int i = 0; i < tpl.count; i++) {
      final b = StringBuffer();
      tpl.emit(i, b);
      addAll(b.toString());
    }
  } else {
    addAll(_flatten(tpl));
  }
  return out;
}

/// 틀의 고르기를 모두 '보기를 쉼표로 늘어놓기' 로 바꾼 글
String _flatten(_Tpl t) {
  if (t is _Lit) {
    return t.text;
  }
  if (t is _Seq) {
    return t.parts.map(_flatten).join();
  }
  if (t is _Choice) {
    return t.options.map(_flatten).join(',');
  }
  return '';
}

// ============================================================================
// 받은 목록 한 칸
// ============================================================================
/// 검색 목록 한 칸을 푼 것.
///  [chars] 는 검색 단계가 캐릭터(분류 4)로 확인해 표시해 둔 태그 (소문자). 예전 목록엔 없다.
///  [kept] 는 사용자가 포함 칸에 적어 '찾은' 태그 (소문자 · 띄어쓰기) — 자동 정리 스위치가 지우지 않는다.
///   예전 목록(3.15.0 전)엔 없다 → 예전처럼 스위치대로 정리된다.
///  [legacy] 는 JSON 이 아닌 아주 예전 형식 — 괄호 태그가 이름인지 확인할 방법이 없다.
typedef SearchEntry = ({
  String tags,
  int width,
  int height,
  String rating,
  Set<String> chars,
  Set<String> kept,
  bool legacy,
});

/// 목록 한 칸(JSON 글자, 또는 아주 예전의 그냥 글자)을 푼다.
///  등급은 한 글자(g/s/q/e)로, 태그 · 캐릭터 표시의 HTML 문자(`&#039;` 등)는 원래 글자로.
SearchEntry parseSearchEntry(String raw) {
  String tagString = "";
  int width = 0;
  int height = 0;
  String rating = "g";
  // 검색 단계가 표시해 둔 캐릭터 태그 (예전에 저장된 목록엔 없다 → 빈 목록)
  List<String> charList = const [];
  // 검색 단계가 표시해 둔 '검색한 태그' (마찬가지로 예전 목록엔 없다)
  List<String> keptList = const [];
  // 아주 예전 형식(JSON 이 아닌 그냥 글자) — 괄호 태그를 확인할 방법이 없다
  bool legacyFormat = false;

  try {
    Map<String, dynamic> parsed = jsonDecode(raw);
    tagString = parsed['tags'] ?? "";
    width = parsed['width'] ?? 0;
    height = parsed['height'] ?? 0;
    rating = parsed['rating']?.toString() ?? "g";
    final chars = parsed['chars'];
    if (chars is List) {
      charList = chars.map((e) => e.toString()).toList();
    }
    final kept = parsed['kept'];
    if (kept is List) {
      keptList = kept.map((e) => e.toString()).toList();
    }
    // Gelbooru는 "general", "sensitive", "questionable", "explicit" 풀 단어를 반환
    // 조건부 트리거에서 g/s/q/e 단일 문자로 비교하므로 정규화
    if (rating.length > 1) {
      rating = rating.substring(0, 1);
    }
  } catch (e) {
    tagString = raw;
    width = 0;
    height = 0;
    rating = "g";
    charList = const [];
    keptList = const [];
    legacyFormat = true;
  }

  // 겔부루가 태그 속 기호를 HTML 문자로 보내 온다 — 원래 글자로 되돌린다.
  //  캐릭터 표시도 같은 규칙으로 되돌려야 태그와 정확히 맞는다 (예: &#039; 가 든 이름).
  return (
    tags: unescapeGelbooruHtml(tagString),
    width: width,
    height: height,
    rating: rating,
    chars: charList.map((c) => unescapeGelbooruHtml(c).trim().toLowerCase()).toSet(),
    kept: keptList.map((c) => unescapeGelbooruHtml(c).trim().toLowerCase()).toSet(),
    legacy: legacyFormat,
  );
}

/// 겔부루가 태그 속 기호를 HTML 문자로 보내 온 것(`jack-o&#039;-lantern` · `&gt;_&lt;`)을 원래 글자로.
///  목록 한 칸 풀기(parseSearchEntry)와 검색 단계의 제외 태그 비교(NovelAiService)가 같이 쓴다.
String unescapeGelbooruHtml(String x) => !x.contains('&')
    ? x // 거의 모든 태그 — 수천 장 × 수십 태그를 돌 때 바로 돌려준다
    : x
          .replaceAll('&#39;', "'")
          .replaceAll('&#039;', "'")
          .replaceAll('&quot;', '"')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');

// ============================================================================
// 받은 태그 다듬기
// ============================================================================
/// 태그 다듬기 설정 (설정 > 프롬프트 검색의 스위치들 + 개별 제거 프롬프트 + 선행/후행 프롬프트)
typedef SearchCleanOptions = ({
  bool removeCharacterTags,
  bool removeCharacteristics,
  bool removeClothes,
  bool removeImpliedTags,
  bool removeClothingEvents,
  bool removeColors,
  String customRemove,
  String prefix,
  String suffix,
});

/// 검색 문법 찌꺼기 태그 — `-loli`, `~smile` 처럼 빼기(-) · 또는(~) 기호로 시작하는 '가짜 태그'.
///  Danbooru 는 이런 이름의 태그를 아예 만들 수 없다 (검색 문법과 겹쳐서). 그런데 Gelbooru 엔
///  이런 태그가 붙은 그림이 가끔 섞여 있다 — 태그를 지우려고 적은 '-태그' 나, 검색어를 통째로
///  붙여 넣은 것이 그대로 새 태그로 남은 것으로 보인다.
///  그냥 두면 '일반 태그' 처럼 통과해 프롬프트에 들어가고, NovelAI 는 기호를 무시하고
///  뒤 낱말(loli)을 읽어 버린다 → 받은 태그에서 반드시 빼야 한다.
///  돌려주는 값은 기호를 뗀 '원래 가리키던 태그' (소문자, 밑줄 · 띄어쓰기는 들어온 그대로).
///  찌꺼기가 아니면 null. '-_-' 같은 이모티콘 태그는 기호 다음이 글자 · 숫자가 아니라서 살린다.
String? searchSyntaxJunkTarget(String tag) {
  final t = tag.trim();
  // 거의 모든 태그는 첫 글자에서 끝난다 — 수천 장 × 수십 태그를 도니 정규식 전에 거른다
  if (!t.startsWith('-') && !t.startsWith('~')) {
    return null;
  }
  return _searchJunk.firstMatch(t.toLowerCase())?.group(1);
}

// 앞의 기호 묶음(-, ~, 섞여도) + 글자 · 숫자로 시작하는 나머지 (일본어 등 다른 글자도 글자로 본다)
final RegExp _searchJunk = RegExp(r'^[-~]+([\p{L}\p{N}][\s\S]*)$', unicode: true);

/// 받은 태그를 다듬어 남길 것만 (원래 순서 그대로). 정렬 · 조건부 규칙은 부르는 쪽에서.
///  선행 · 후행 프롬프트에 이미 있는 태그도 뺀다 (보낼 때 두 번 들어가지 않게).
///  검색한 태그(entry.kept)는 자동 정리 스위치에서 지킨다 — 개별 제거 · 선행/후행 겹침만 적용된다.
///
/// 세 단계로 거른다.
///  ① 태그 하나씩 — 찌꺼기 · 캐릭터 · 이름/괄호/잡동사니 · 특징 · 의상 · 의상 상태 · 색 · 개별 제거
///  ② 중복(함의) — ① 에서 '남은' 태그와 선행 · 후행이 함의하는 상위 태그
///  ③ 선행 · 후행에 이미 있는 태그
///  ⚠️ 예전엔 중복 정리를 거르기 '전' 태그로 정해서, 더 구체적인 태그가 다른 스위치로 지워져도 상위 태그까지 지웠다
///     (색상 제거 + 중복 정리: plaid skirt 는 색으로, skirt 는 중복으로 빠져 치마가 통째로 사라졌다, 2026-10).
List<String> cleanSearchTags(SearchEntry entry, SearchCleanOptions o) {
  final Set<String> charTags = entry.chars;
  final bool legacyFormat = entry.legacy;
  final List<String> rawTags = entry.tags.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  // 개별 제거 규칙 — 쉼표 · 줄바꿈으로 나눈다. 비교는 태그와 같은 모양으로 (_plainTag — 밑줄 · 대소문자 · 가중치 무시).
  //  ⚠️ 예전엔 소문자로만 바꿔, long_hair 처럼 밑줄로 적으면 'long hair' 를 못 지웠다.
  final List<String> customRules = [
    for (final r in o.customRemove.split(_listSeparators))
      if (_plainTag(r).isNotEmpty) _plainTag(r),
  ];
  // 선행 · 후행 프롬프트의 태그 (같은 모양으로) — 줄바꿈 · 가중치({1girl} · 1.2::masterpiece::)가 있어도 알아본다.
  //  ⚠️ 예전엔 쉼표로만 나누고 글자 그대로 비교해, 줄을 바꿔 적었거나 가중치를 준 태그는 받은 태그에 또 들어갔다.
  final Set<String> fixedKeys = {
    for (final f in "${o.prefix},${o.suffix}".split(_listSeparators))
      if (_plainTag(f).isNotEmpty) _plainTag(f),
  };

  // ① 태그 하나씩
  //  guarded = 캐릭터 · 검색한 태그 — ② 중복 정리에서도 지킨다 (예전과 같다)
  final survivors = <({String tag, String key, bool guarded})>[];
  for (final String t in rawTags) {
    // 검색 문법 찌꺼기(-loli 등) — 예전에 받아 둔 목록에도 섞여 있을 수 있어 여기서도 뺀다.
    //  캐릭터 표시 · 스위치와 상관없이 언제나 뺀다 (태그가 아니므로).
    if (searchSyntaxJunkTarget(t) != null) {
      continue;
    }
    final String key = _plainTag(t); // 띄어쓰기 · 소문자 — 사전 목록 · 규칙과 비교하는 모양
    // ★ 캐릭터 통과증 — 검색 단계에서 카테고리 4(캐릭터)로 확인돼 표시된 태그.
    //   '캐릭터 제거' 가 켜져 있으면 여기서 지우고, 꺼져 있으면 아래 자동 검사
    //   (괄호·이름·특징·의상·색 …)를 건너뛰고 그대로 통과한다.
    //   사용자가 직접 적은 '개별 제거 프롬프트'는 캐릭터에도 그대로 적용된다.
    final String lower = t.toLowerCase();
    final bool isChar = charTags.contains(lower);
    // ★ 검색한 태그 — 포함 칸에 적어 '찾은' 태그는 자동 정리 스위치(캐릭터 · 특징 · 의상 · 의상 상태 · 색 · 중복)가
    //   지우지 않는다. 찾은 태그가 결과에 없으면 검색한 보람이 없다 (예: 특징 제거를 켜 두고 large breasts 를 찾으면
    //   예전엔 결과에서 large breasts 가 빠졌다). 직접 적은 '개별 제거 프롬프트' 와 선행 · 후행 겹침은 그대로 적용한다.
    final bool isKept = entry.kept.contains(lower);
    if (isChar && o.removeCharacterTags && !isKept) {
      continue;
    }
    if (!isChar && !isKept) {
      // 괄호 든 태그: 새 목록은 검색 단계에서 '일반 태그'로 확인된 것만 괄호째 들어 있다
      //  (shrug (clothing) 등 — 살린다). 예전 목록은 \( 로 저장돼 있고 확인된 적이
      //  없으므로, 이름 꼬리표일 수 있어 예전처럼 버린다.
      final bool escapedParen = t.contains(r'\(') || t.contains(r'\)');
      final bool anyParen = t.contains('(') || t.contains(')');
      if (escapedParen || (legacyFormat && anyParen)) {
        continue;
      }
      // 작가/캐릭터/작품 '이름' 백스톱: 검색 단계에서 카테고리 조회가 실패했거나(429/오프라인)
      // 과거에 저장된 프롬프트에 이름이 남아있는 경우를 여기서 최종 차단
      // (정적 사전 + 에셋 사전 + 패턴 안전장치를 isNameTag 하나로 통일)
      final String underscored = key.replaceAll(' ', '_');
      // 목록에 띄어쓰기·밑줄 어느 모양으로 적혀 있어도 알아보게 둘 다 비교한다
      //  (예전엔 띄어쓰기 모양만 비교해서 'shrug_(clothing)' 처럼 적힌 항목을 놓칠 수 있었다)
      bool inList(Iterable<String> list) => list.contains(key) || list.contains(underscored);
      if (TagFilters.isNameTag(underscored)) {
        continue;
      }
      if (inList(TagFilters.commonGarbage)) {
        continue;
      }
      if (o.removeCharacteristics && inList(TagFilters.characterTraits)) {
        continue;
      }
      if (o.removeClothes && inList(TagFilters.clothesTags)) {
        continue;
      }
      // 의상 상태/동작 (unworn, torn, grab 등) — 의상 제거와 짝으로 쓰면 옷 관련이 깔끔히 정리된다
      if (o.removeClothingEvents && inList(TagFilters.clothingEventTags)) {
        continue;
      }
      // 색 — 색 낱말이 '낱말로' 들어 있을 때만 (_hasColorWord). dark · dark elf · rainbow 같은 예외는 남긴다.
      //  ⚠️ 예전엔 글자 일부로 찾아 'red' 가 든 covered nipples · censored · collared shirt · scared 까지 지웠다.
      if (o.removeColors && !TagFilters.colorExceptions.contains(key) && _hasColorWord(key)) {
        continue;
      }
    }
    if (customRules.any((rule) => _matchesRemoveRule(key, rule))) {
      continue;
    }
    survivors.add((tag: t, key: key, guarded: isChar || isKept));
  }

  // ② 중복(함의) — 남은 태그와 선행 · 후행이 함의하는 상위 태그를 뺀다 (예: plaid skirt 가 남아 있으면 skirt).
  final Set<String> impliedToRemove = o.removeImpliedTags
      ? impliedParentsOf([for (final s in survivors) s.key, ...fixedKeys])
      : const <String>{};

  // ③ 선행 · 후행에 이미 있는 태그 빼기
  return [
    for (final s in survivors)
      if (!(impliedToRemove.contains(s.key) && !s.guarded) && !fixedKeys.contains(s.key)) s.tag,
  ];
}

/// [present] (띄어쓰기 · 소문자) 가 함의하는 상위 태그 전부 — 사슬을 끝까지 따라간다.
///  예: american flag skirt → print skirt → skirt. 계산은 매우 가볍다(0.002ms 수준).
///  여기엔 '다른 태그가 함의하는' 태그만 들어 있으므로, 그 자체가 키여도 중복이 맞다.
///  프롬프트에 단독으로 있는 태그는 애초에 이 집합에 들어오지 않는다.
Set<String> impliedParentsOf(Iterable<String> present) {
  final Set<String> out = {};
  final List<String> stack = [
    for (final k in present)
      if (TagFilters.tagImplications.containsKey(k)) k,
  ];
  while (stack.isNotEmpty) {
    final String cur = stack.removeLast();
    for (final parent in TagFilters.tagImplications[cur] ?? const <String>[]) {
      if (out.add(parent) && TagFilters.tagImplications.containsKey(parent)) {
        stack.add(parent);
      }
    }
  }
  return out;
}

/// 목록 칸(개별 제거 · 선행 · 후행)을 나누는 기호 — 쉼표 · 줄바꿈
final RegExp _listSeparators = RegExp(r'[,\n]');

/// 가중치 표시 — 'N::' (여는 것) · '::' (닫는 것)
final RegExp _weightMarks = RegExp(r'-?\d+(?:\.\d+)?\s*::|::');

/// 강조 괄호 { } [ ]
final RegExp _emphasisBrackets = RegExp(r'[{}\[\]]');

/// 태그를 비교하는 모양 — 소문자 · 밑줄은 띄어쓰기 · 가중치 표시와 강조 괄호를 떼고 · 띄어쓰기는 한 칸.
///  받은 태그 · 개별 제거 규칙 · 선행 · 후행이 모두 이 모양으로 만난다.
String _plainTag(String s) => s
    .toLowerCase()
    .replaceAll(_weightMarks, '')
    .replaceAll(_emphasisBrackets, '')
    .replaceAll('_', ' ')
    .replaceAll(_spaces, ' ')
    .trim();

/// 개별 제거 규칙 하나 — *뒤 (끝이 같음) · 앞* (시작이 같음) · *가운데* (들어 있음) · 그 밖엔 정확히 같음.
///  [key] · [rule] 은 둘 다 _plainTag 모양. '*' 하나 · '**' 는 아무것도 지우지 않는다 (예전과 같다).
bool _matchesRemoveRule(String key, String rule) {
  if (rule.length > 2 && rule.startsWith('*') && rule.endsWith('*')) {
    return key.contains(rule.substring(1, rule.length - 1));
  }
  if (rule.length > 1 && rule.startsWith('*')) {
    final String end = rule.substring(1);
    return !end.contains('*') && key.endsWith(end);
  }
  if (rule.length > 1 && rule.endsWith('*')) {
    final String start = rule.substring(0, rule.length - 1);
    return !start.contains('*') && key.startsWith(start);
  }
  return key == rule;
}

/// 색 낱말 (TagFilters.colorKeywords) 을 낱말로 나눠 둔 것 — 'light green' · 'two-tone' 은 두 낱말
final List<List<String>> _colorKeywordWords = [
  for (final k in TagFilters.colorKeywords) _wordsOf(k),
];

/// 낱말로 나누기 — 띄어쓰기 · 밑줄 · 하이픈 (dark-skinned → dark · skinned)
List<String> _wordsOf(String s) => s.split(_wordSeparators).where((w) => w.isNotEmpty).toList();
final RegExp _wordSeparators = RegExp(r'[\s_\-]+');

/// 태그([key] — 띄어쓰기 · 소문자)에 색 낱말이 '낱말 그대로, 이어서' 들어 있는지.
///  red ribbon · white shirt · two-tone hair · dark-skinned female · light green hair → 참
///  covered nipples · censored · collared shirt · scared · footprints · goldfish → 거짓 (글자 일부일 뿐)
bool _hasColorWord(String key) {
  final List<String> words = _wordsOf(key);
  for (final kw in _colorKeywordWords) {
    for (int i = 0; i + kw.length <= words.length; i++) {
      bool same = true;
      for (int j = 0; j < kw.length; j++) {
        if (words[i + j] != kw[j]) {
          same = false;
          break;
        }
      }
      if (same) {
        return true;
      }
    }
  }
  return false;
}
