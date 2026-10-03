// lib/models/prompt_dict.dart
//
// 프롬프트 사전 — 프롬프트와 미리보기 그림을 한 줄씩 모아 두는 목록.
//
// 프리셋과 무엇이 다른가:
//  · 프리셋은 '생성 설정 한 벌'(모델·스텝·해상도·캐릭터 …)을 통째로 담는다.
//  · 사전은 '프롬프트 조각 하나'만 담는다. 특정 캐릭터 묘사나
//    작가 태그를 시험한 결과처럼, 나중에 꺼내 붙이려고 모아 두는 용도다.
//
// 저장 위치:
//  ⚠️ 미리보기 그림(base64)을 품고 있어 SharedPreferences 에 두면 안 된다.
//     프리셋이 같은 이유로 파일(presets.json)로 옮겨 갔다.
//     이 목록도 앱 문서 폴더의 prompt_dict.json 에 따로 저장한다.

class PromptDictEntry {
  /// 목록에서의 위치와 무관한 고유 값 (순서를 바꿔도 가리키는 대상이 같다)
  final String id;

  /// 목록에 보이는 이름. 비어 있으면 프롬프트 앞부분을 대신 보여 준다.
  String title;

  /// 저장해 둔 프롬프트 본문
  String prompt;

  /// 미리보기 그림 (가로 200px 안팎의 JPEG, base64). 없으면 null.
  String? thumbnail;

  /// 만든 시각 (epoch ms) — 정렬·표시용
  final int createdAt;

  /// 속한 분류의 id. null 이면 '미분류'.
  ///  (분류를 지우면 그 안의 항목은 null 로 돌아간다 — 항목은 지우지 않는다)
  String? categoryId;

  PromptDictEntry({
    String? id,
    this.title = '',
    this.prompt = '',
    this.thumbnail,
    int? createdAt,
    this.categoryId,
  }) : id = id ?? '${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
       createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  static int _seq = 0;

  /// 목록에 보여 줄 이름. 제목이 없으면 프롬프트의 첫 태그.
  String get displayTitle {
    final t = title.trim();
    return t.isNotEmpty ? t : autoTitle(prompt);
  }

  /// 이름을 비워 두고 저장할 때 대신 쓸 이름 — 프롬프트의 '첫 태그'.
  ///
  ///  'miku, blue hair, '          → 'miku'
  ///  '1.2::artist:wlop ::, rain'   → 'artist:wlop'   (가중치 표기는 뺀다)
  ///  '{{hatsune miku}}, twintails'→ 'hatsune miku'  (강조 괄호도 뺀다)
  ///
  ///  ( ) 는 남긴다 — 'artist:test (theta)' 처럼 태그 이름의 일부일 수 있다.
  static String autoTitle(String prompt) {
    for (final raw in prompt.split(RegExp(r'[,\n]'))) {
      var t = raw.trim();
      if (t.isEmpty) {
        continue;
      }
      final cleaned = t
          .replaceAll(RegExp(r'-?\d+(\.\d+)?::'), '')
          .replaceAll('::', '')
          .replaceAll(RegExp(r'[{}\[\]]'), '')
          .trim();
      if (cleaned.isNotEmpty) {
        t = cleaned;
      }
      // ⚠️ substring 대신 runes 로 자른다 (이모지가 반쪽으로 잘려 깨지는 것 방지)
      final r = t.runes.toList();
      return r.length <= 40 ? t : '${String.fromCharCodes(r.take(40))}…';
    }
    return '(비어 있음)';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'prompt': prompt,
    if (thumbnail != null) 'thumbnail': thumbnail,
    'createdAt': createdAt,
    if (categoryId != null) 'categoryId': categoryId,
  };

  factory PromptDictEntry.fromJson(Map<String, dynamic> json) => PromptDictEntry(
    id: json['id'] as String?,
    title: json['title'] ?? '',
    prompt: json['prompt'] ?? '',
    thumbnail: json['thumbnail'] as String?,
    createdAt: json['createdAt'] as int?,
    categoryId: json['categoryId'] as String?,
  );
}

/// 사전 분류 (작가 · 캐릭터 · 의상 …). 사용자가 직접 만든다.
///
/// 항목 하나는 분류 하나에만 속한다 (폴더처럼).
/// 태그처럼 여러 개를 붙이게 하면 고르는 화면과 거르는 규칙이 훨씬 복잡해진다.
class PromptDictCategory {
  final String id;
  String name;

  PromptDictCategory({String? id, required this.name})
    : id = id ?? 'cat_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  // 같은 순간에 두 개를 만들어도 id 가 겹치지 않게 (항목 id 와 같은 방식)
  static int _seq = 0;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory PromptDictCategory.fromJson(Map<String, dynamic> json) =>
      PromptDictCategory(id: json['id'] as String?, name: json['name'] ?? '');
}

/// 거르기 값: 전체 / 미분류 / (그 밖엔 분류 id)
///  분류 id 와 겹치지 않도록 밑줄로 감싼다.
const String kDictFilterAll = '__all__';
const String kDictFilterNone = '__none__';

/// [e] 가 [filter] 에 들어가는가.
bool dictEntryMatches(PromptDictEntry e, String filter) {
  if (filter == kDictFilterAll) {
    return true;
  }
  if (filter == kDictFilterNone) {
    return e.categoryId == null;
  }
  return e.categoryId == filter;
}

/// [base] 뒤에 [add] 를 쉼표로 이어 붙인다.
///  사전 탭의 '추가'와 확대 입력창의 📖 '추가'가 함께 쓴다 (규칙이 갈리지 않게 한 곳에).
String appendPromptPiece(String base, String add) {
  final b = base.trimRight();
  if (b.isEmpty) {
    return add;
  }
  if (b.endsWith(',')) {
    return '$b $add';
  }
  return '$b, $add';
}

/// [text] 의 [cursor] 자리에 [piece] 를 태그 하나로 끼워 넣는다.
/// 돌려주는 값: (결과 글자, 넣은 태그 바로 뒤 위치 — 커서를 여기 두면 연달아 넣어도 순서대로 쌓인다)
///
///  · 커서가 없거나(-1) 뒤에 공백뿐이면 [appendPromptPiece] 와 같다 (맨 끝에 붙이기).
///  · 단어 한가운데('sh|irt')면 그 태그 끝으로 옮겨서 넣는다 — 태그를 쪼개지 않게.
///  · 앞뒤 쉼표·띄어쓰기는 알아서 맞추고, 줄바꿈은 쉼표처럼 구분자로 본다.
///
///   'skirt, shirt,| pants' + test → 'skirt, shirt, test, pants'
///
///  ⚠️ substring 으로 자르지만 안전하다 — 자르는 자리가 입력창 커서(항상 글자 경계)이거나
///     쉼표·줄바꿈 같은 ASCII 구분자 옆뿐이라, 이모지를 반으로 가를 일이 없다.
(String, int) insertPromptPieceAt(String text, int cursor, String piece) {
  if (cursor < 0 || cursor > text.length || text.substring(cursor).trim().isEmpty) {
    final out = appendPromptPiece(text, piece);
    return (out, out.length);
  }
  bool isSep(String ch) => ch == ',' || ch == '\n';
  int c = cursor;
  // 단어 한가운데면 그 태그의 끝(다음 구분자)으로
  if (c > 0 && !isSep(text[c - 1]) && text[c - 1] != ' ' && !isSep(text[c])) {
    while (c < text.length && !isSep(text[c])) {
      c++;
    }
  }
  final before = text.substring(0, c).replaceFirst(RegExp(r' +$'), '');
  final after = text.substring(c).replaceFirst(RegExp(r'^ +'), '');
  final String left;
  if (before.trim().isEmpty) {
    left = piece;
  } else if (before.endsWith('\n')) {
    left = '$before$piece';
  } else if (before.endsWith(',')) {
    left = '$before $piece';
  } else {
    left = '$before, $piece';
  }
  final String out;
  if (after.isEmpty) {
    out = left;
  } else if (isSep(after[0])) {
    out = '$left$after';
  } else {
    out = '$left, $after';
  }
  return (out, left.length);
}

/// 프롬프트탭 '긍정적 프롬프트' 입력창의 되돌리기 열쇠.
///  ⚠️ 사전 탭에서 '추가'할 때도 이 열쇠로 기록을 남겨, 프롬프트탭 입력창의
///     ↺ 로 되돌릴 수 있게 한다. 두 곳이 글자 하나라도 다르면 연결이 조용히 끊긴다.
const String kPositiveUndoKey = 'prompt/긍정적 프롬프트';
