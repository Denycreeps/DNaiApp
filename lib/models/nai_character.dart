// lib/models/nai_character.dart
class NaiCharacter {
  /// 이 캐릭터를 가리키는 고유 값. 목록에서의 '몇 번째'와 무관하다.
  ///
  /// ⚠️ 되돌리기 기록을 인덱스(char0, char1…)로 묶으면 안 된다.
  ///    캐릭터를 지우면 뒤 캐릭터가 앞 번호를 물려받아 남의 기록을 쓰게 되고,
  ///    프롬프트 불러오기로 전체가 교체돼도 옛 기록이 그대로 붙는다.
  ///    이 값으로 묶으면 삭제·순서변경·전체교체에 전부 안전하다.
  final String uid;

  String name;
  String positive;
  String negative;

  /// 5x5 그리드 좌표 (V4/V4.5용). 0~4
  int gridX;
  int gridY;

  /// 자유 좌표 (V5용). 0.0 ~ 1.0
  ///  V5는 캔버스 어디든 찍을 수 있어 그리드로 표현할 수 없다.
  ///  null이면 아직 자유 좌표를 쓴 적이 없다는 뜻이며, gridX/Y에서 환산해 쓴다.
  double? posX;
  double? posY;

  bool isActive; // 캐릭터 활성화(ON/OFF) 상태 저장

  /// 마커·칩 색 (ARGB). null이면 번호에 따른 기본 팔레트를 쓴다.
  int? colorArgb;

  /// 이번 생성에만 덧붙일 프롬프트.
  ///
  /// 원본 [positive] 를 건드리지 않고 "이번엔 이것도 넣어 보자" 를 시험하는 칸이다.
  /// 전송할 때 [positive] 뒤에 이어 붙는다.
  ///  · 프롬프트탭의 캐릭터 편집에서만 보인다 (캐릭터탭에는 없다)
  ///  · 설정 저장·백업에는 들어가지만 프리셋에는 들어가지 않는다
  ///    (프리셋은 '완성된 구성'이라 임시 메모가 섞이면 곤란하다)
  String tempPositive;

  /// 임시 프롬프트를 이번 생성에 쓸지.
  ///  내용은 그대로 두고 잠깐 빼 보고 싶을 때 끈다.
  ///  (지웠다 다시 쓰는 수고를 덜기 위함 — 가중치 규칙의 ON/OFF 와 같은 역할)
  bool tempEnabled;

  NaiCharacter({
    String? uid,
    this.name = "",
    this.positive = "",
    this.negative = "",
    this.gridX = 2,
    this.gridY = 2,
    this.posX,
    this.posY,
    this.isActive = true, // 기본값은 무조건 ON(true)
    this.colorArgb,
    this.tempPositive = "",
    this.tempEnabled = true,
  }) : uid = uid ?? _newUid();

  /// 이번 생성에 임시 프롬프트가 실제로 붙는가.
  ///  (내용이 있고 켜져 있어야 한다 — 전송·표시가 같은 판단을 쓰도록 한곳에 둔다)
  bool get tempActive => tempEnabled && tempPositive.trim().isNotEmpty;

  /// 겹치지 않는 값이면 충분하다 (시각 + 증가 번호).
  static int _uidSeq = 0;
  static String _newUid() => '${DateTime.now().microsecondsSinceEpoch}_${_uidSeq++}';

  /// 실제 전송에 쓸 좌표 (0.0~1.0).
  ///  자유 좌표가 있으면 그대로, 없으면 그리드에서 환산한다.
  double get centerX => posX ?? (gridX * 0.2 + 0.1);
  double get centerY => posY ?? (gridY * 0.2 + 0.1);

  /// 자유 좌표를 설정하면서 그리드도 가장 가까운 칸으로 맞춰 둔다.
  ///  (V4.5로 되돌아가도 대략 같은 위치를 유지하기 위함)
  void setPosition(double x, double y) {
    posX = x.clamp(0.0, 1.0);
    posY = y.clamp(0.0, 1.0);
    gridX = ((posX! - 0.1) / 0.2).round().clamp(0, 4);
    gridY = ((posY! - 0.1) / 0.2).round().clamp(0, 4);
  }

  /// [forPreset] 이면 프리셋에 담기지 않아야 할 항목을 뺀다.
  ///  (임시 프롬프트, 그리고 캐릭터를 특정하는 uid)
  Map<String, dynamic> toJson({bool forPreset = false}) => {
    if (!forPreset) 'uid': uid,
    if (!forPreset) 'tempPositive': tempPositive,
    if (!forPreset) 'tempEnabled': tempEnabled,
    'name': name,
    'positive': positive,
    'negative': negative,
    'gridX': gridX,
    'gridY': gridY,
    'posX': posX,
    'posY': posY,
    'isActive': isActive,
    'colorArgb': colorArgb,
  };

  factory NaiCharacter.fromJson(Map<String, dynamic> json) => NaiCharacter(
    // 옛 저장본에는 uid 가 없다. 그 경우 새로 만들어 준다
    //  (그 캐릭터의 되돌리기 기록은 한 번 비지만, 잘못된 기록이 붙는 것보다 낫다)
    uid: json['uid'] as String?,
    tempPositive: json['tempPositive'] ?? "",
    tempEnabled: json['tempEnabled'] ?? true,
    name: json['name'] ?? "",
    positive: json['positive'] ?? "",
    negative: json['negative'] ?? "",
    gridX: json['gridX'] ?? 2,
    gridY: json['gridY'] ?? 2,
    posX: (json['posX'] as num?)?.toDouble(),
    posY: (json['posY'] as num?)?.toDouble(),
    isActive: json['isActive'] ?? true,
    colorArgb: json['colorArgb'] as int?,
  );
}
