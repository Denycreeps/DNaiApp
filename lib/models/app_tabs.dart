// lib/models/app_tabs.dart
//
// 앱의 탭 — 순서와 이름을 한 곳에서.
//  ⚠️ 예전엔 탭을 0~5 숫자로 불러서, navigateToTab(2) 가 i2i 인지·5 가 설정인지
//     읽는 사람이 외워야 했고 탭 이름 목록도 main.dart 안에 따로 있었다.
//  적힌 순서가 곧 화면의 탭 순서다 (켜진 탭만 보인다 — AppState.isTabShown).
enum AppTab {
  prompt('프롬프트'),
  history('히스토리'),
  i2i('i2i'),
  character('캐릭터'),
  // 와일드카드·프롬프트 사전을 함께 담는다 (화면 파일 이름은 옛 그대로 wildcard_tab.dart)
  library('라이브러리'),
  settings('설정');

  const AppTab(this.label);

  /// 탭 줄에 보이는 이름
  final String label;
}
