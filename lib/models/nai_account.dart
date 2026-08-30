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

  /// 마지막으로 확인한 V5 시간당 할당량(남은 %). null이면 아직 모름/해당 없음.
  ///  Opus 구독에만 존재하는 값이라, 하위 티어 계정은 계속 null이다.
  double? limitPercent;

  /// 위 두 값을 마지막으로 확인한 시각(epoch ms). 0이면 확인한 적 없음.
  ///  "5분 전 확인" 같은 표시에 쓴다 — 숫자만 보면 언제 값인지 알 수 없어서.
  int checkedAtMs;

  NaiAccount({
    required this.label,
    required this.token,
    this.anlas = -1,
    this.limitPercent,
    this.checkedAtMs = 0,
  });

  Map<String, dynamic> toJson() => {
    'label': label,
    'token': token,
    'anlas': anlas,
    if (limitPercent != null) 'limitPercent': limitPercent,
    'checkedAtMs': checkedAtMs,
  };

  factory NaiAccount.fromJson(Map<String, dynamic> json) => NaiAccount(
    label: json['label'] ?? '',
    token: json['token'] ?? '',
    anlas: json['anlas'] ?? -1,
    limitPercent: (json['limitPercent'] as num?)?.toDouble(),
    checkedAtMs: json['checkedAtMs'] ?? 0,
  );

  /// 마지막 확인 시각을 사람이 읽기 좋게. 확인한 적 없으면 null.
  String? get checkedAgo {
    if (checkedAtMs <= 0) {
      return null;
    }
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(checkedAtMs));
    if (d.inMinutes < 1) {
      return '방금';
    }
    if (d.inMinutes < 60) {
      return '${d.inMinutes}분 전';
    }
    if (d.inHours < 24) {
      return '${d.inHours}시간 전';
    }
    return '${d.inDays}일 전';
  }

  /// 토큰 뒷자리만 보여준다 (전체 노출 방지)
  String get maskedToken {
    if (token.length <= 8) {
      return '••••';
    }
    return '••••${token.substring(token.length - 4)}';
  }
}
