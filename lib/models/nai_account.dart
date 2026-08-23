// lib/models/nai_account.dart

/// NovelAI 계정 하나.
///
/// V5부터 시간당 사용 한도가 생겨 계정을 여러 개 쓰는 경우가 늘었다.
/// 토큰을 여러 개 보관해 두고 필요할 때 갈아끼우기 위한 모델이다.
class NaiAccount {
  /// 사용자가 알아보기 위한 이름 ("본계정", "부계정" 등)
  String label;

  /// NovelAI persistent token
  String token;

  /// 마지막으로 확인한 Anlas. 목록에서 어느 계정이 여유 있는지 보여주는 용도.
  ///  -1 이면 아직 확인한 적 없음.
  int anlas;

  NaiAccount({required this.label, required this.token, this.anlas = -1});

  Map<String, dynamic> toJson() => {'label': label, 'token': token, 'anlas': anlas};

  factory NaiAccount.fromJson(Map<String, dynamic> json) => NaiAccount(
    label: json['label'] ?? '',
    token: json['token'] ?? '',
    anlas: json['anlas'] ?? -1,
  );

  /// 토큰 뒷자리만 보여준다 (전체 노출 방지)
  String get maskedToken {
    if (token.length <= 8) {
      return '••••';
    }
    return '••••${token.substring(token.length - 4)}';
  }
}
