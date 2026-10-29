// lib/models/history_search.dart
//
// 히스토리 검색 — 그림 정보의 프롬프트로 히스토리를 거른다 (화면과 무관한 순수 함수 · test/history_search_test.dart).
//  · 찾는 곳: 긍정 프롬프트 + 캐릭터 프롬프트 (부정은 넣지 않는다 — 'glasses' 를 찾았는데 부정에 glasses 를 넣은 그림이 나오면 헷갈린다)
//  · 검색어: 쉼표로 나눈다. 전부 들어 있어야 맞는다. 앞에 '-' 를 붙이면 그게 들어간 그림은 뺀다.
//      예) "maid, smile, -glasses"
//  · 글자 맞추기: 대소문자 · '_' 와 띄어쓰기 · 띄어쓰기 여러 개를 같게 본다 (blue_eyes = Blue Eyes).
//    태그 '일부' 만 맞아도 찾는다 (maid → maid headdress 도). 빼기도 마찬가지 (-glasses → sunglasses 도 빠진다).
import 'image_metadata.dart';

/// 검색어를 나눈 것 — 꼭 들어갈 것들 · 빠질 것들 (둘 다 [normalizeForSearch] 를 거친 글자)
typedef HistoryQuery = ({List<String> include, List<String> exclude});

/// 비교용 글자 — 소문자, '_' → 띄어쓰기, 띄어쓰기 여러 개 → 하나, 앞뒤 공백 없음
String normalizeForSearch(String s) =>
    s.toLowerCase().replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// 검색칸의 글을 나눈다. 빈 칸 · '-' 만 있는 칸은 버린다.
HistoryQuery parseHistoryQuery(String input) {
  final include = <String>[];
  final exclude = <String>[];
  for (final raw in input.split(',')) {
    final String term = raw.trim();
    if (term.startsWith('-')) {
      final String t = normalizeForSearch(term.replaceFirst('-', ''));
      if (t.isNotEmpty) {
        exclude.add(t);
      }
    } else {
      final String t = normalizeForSearch(term);
      if (t.isNotEmpty) {
        include.add(t);
      }
    }
  }
  return (include: include, exclude: exclude);
}

/// 검색어가 비었는지 (아무것도 거르지 않는다)
bool isEmptyQuery(HistoryQuery q) => q.include.isEmpty && q.exclude.isEmpty;

/// 그림 정보에서 찾을 글 — 긍정 + 캐릭터 프롬프트를 비교용 글자로. 정보가 없으면 빈 글.
String historySearchText(NaiMetadata? meta) {
  if (meta == null) {
    return '';
  }
  return normalizeForSearch([meta.positive, ...meta.characterPrompts].join(', '));
}

/// [text]([historySearchText] 결과)가 검색어에 맞는지.
///  그림 정보가 없는 칸(text 가 빈 글)은 '꼭 들어갈 것' 이 있으면 맞지 않고, 빼기만 있으면 맞는다.
bool historyMatches(String text, HistoryQuery q) {
  for (final t in q.include) {
    if (!text.contains(t)) {
      return false;
    }
  }
  for (final t in q.exclude) {
    if (text.contains(t)) {
      return false;
    }
  }
  return true;
}
