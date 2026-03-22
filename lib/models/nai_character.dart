// lib/models/nai_character.dart
class NaiCharacter {
  String name;
  String positive;
  String negative;
  int gridX;
  int gridY;
  bool isActive; // 🚀 [추가] 캐릭터 활성화(ON/OFF) 상태 저장!

  NaiCharacter({
    this.name = "",
    this.positive = "",
    this.negative = "",
    this.gridX = 2,
    this.gridY = 2,
    this.isActive = true, // 🚀 기본값은 무조건 ON(true)
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'positive': positive,
    'negative': negative,
    'gridX': gridX,
    'gridY': gridY,
    'isActive': isActive, // 🚀 저장할 때 같이 저장
  };

  factory NaiCharacter.fromJson(Map<String, dynamic> json) => NaiCharacter(
    name: json['name'] ?? "",
    positive: json['positive'] ?? "",
    negative: json['negative'] ?? "",
    gridX: json['gridX'] ?? 2,
    gridY: json['gridY'] ?? 2,
    isActive: json['isActive'] ?? true, // 🚀 불러올 때 같이 불러오기 (없으면 기본값 true)
  );
}
