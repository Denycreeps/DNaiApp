// lib/models/nai_character.dart
class NaiCharacter {
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

  NaiCharacter({
    this.name = "",
    this.positive = "",
    this.negative = "",
    this.gridX = 2,
    this.gridY = 2,
    this.posX,
    this.posY,
    this.isActive = true, // 기본값은 무조건 ON(true)
  });

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

  Map<String, dynamic> toJson() => {
    'name': name,
    'positive': positive,
    'negative': negative,
    'gridX': gridX,
    'gridY': gridY,
    'posX': posX,
    'posY': posY,
    'isActive': isActive,
  };

  factory NaiCharacter.fromJson(Map<String, dynamic> json) => NaiCharacter(
    name: json['name'] ?? "",
    positive: json['positive'] ?? "",
    negative: json['negative'] ?? "",
    gridX: json['gridX'] ?? 2,
    gridY: json['gridY'] ?? 2,
    posX: (json['posX'] as num?)?.toDouble(),
    posY: (json['posY'] as num?)?.toDouble(),
    isActive: json['isActive'] ?? true,
  );
}
