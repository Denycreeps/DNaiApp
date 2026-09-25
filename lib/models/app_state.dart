import 'package:flutter/services.dart' show rootBundle;
// smartMatchTags / kContainsMarker 의 실제 정의는 utils/prompt_utils.dart 에 있다.
// app_state 를 import 하던 기존 호출부가 그대로 쓰도록 이름만 다시 내보낸다.
export '../utils/prompt_utils.dart' show smartMatchTags, kContainsMarker;
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_stream/saf_stream.dart';

import '../novelai_service.dart';
import '../tag_filters.dart';
import '../app_theme.dart';
import 'nai_character.dart';
import 'model_caps.dart';
import 'director_tools.dart';
import 'prompt_dict.dart';
import '../utils/image_codec.dart'; // WebP 굽기·썸네일 규칙 (한곳)
import 'nai_account.dart';
import 'text_controllers.dart';
import 'preset_models.dart';
import 'image_metadata.dart';
import 'nai_presets.dart';
import '../utils/qwen_tokenizer.dart';
import '../widgets/app_toast.dart';
import '../widgets/confirm_dialog.dart';

// i2i 작업 이미지가 바뀔 때 마스킹(_strokes)을 어떻게 처리할지.
// 1회용 소비 신호 대신 이 값을 함께 세팅하여 build 타이밍 문제를 방지한다.
/// Anlas 추정 대상 작업.
///  작업마다 계산 규칙이 달라 AppState.anlasFor 가 여기서 갈라진다.
enum AnlasJob { generate, inpaint, img2img, director, upscale }

enum I2iMaskAction {
  clearMask, // 마스크 초기화 (i2i로 새 이미지 보내기 등)
  keepMask, // 마스크 유지 (릴 결과 채택 등)
  followInpaintSetting, // 인페인트 자동 해제 설정(inpaintAutoClearMask)을 따름
}

// 인페인트 마스크의 한 획. AppState에 보관하여 i2i 탭 위젯이 재생성돼도(PageView가
// 멀리 있는 페이지를 정리하는 경우) 마스크가 사라지지 않도록 한다.
class MaskStroke {
  final List<Offset> points;
  final double size;
  final bool isEraser;
  final bool isCircle;

  MaskStroke({
    required this.points,
    required this.size,
    required this.isEraser,
    required this.isCircle,
  });
}

// ============================================================================
// 스마트 태그 매칭: 공백으로 단어 조각을 구분하여 검색
// "ca t" → cat_tail (ca→cat, t→tail) 매칭, cat_ears 제외
// 단일 단어면 기존 startsWith 동작과 동일
// ============================================================================
// † 접두어 = 보조 매칭 결과 (UI에서 연한 스타일로 구분)
// ============================================================================

// ============================================================================
// 프롬프트 토큰 추정기
// ============================================================================
//  모델마다 토크나이저가 달라 방식을 나눈다 (ModelCaps.tokenizer).
//
//  · T5   (V4/V4.5) : 영문 태그 기준 평균 3.1글자당 1토큰. 글자수 근사로 충분.
//  · Qwen (V5)      : QwenTokenizer가 실제 BPE를 돌려 '정확한' 값을 낸다.
//                     글자수 근사는 영문 4.2 / 일본어 1.0 글자당 1토큰으로
//                     4배 넘게 벌어져 쓸 수 없다.
//                     (사전 로드 전이면 QwenTokenizer가 알아서 근사값을 준다)

// 토큰 수 캐시.
//
// ⚠️ 이게 없으면 앱이 멈춘다.
//    화면에는 토큰 표시가 3곳 있고, 각 표시가 estimateBaseTokens +
//    estimateCharacterTokens 를 부른다. 즉 리빌드 한 번에 BPE 가 6번 돈다.
//    V5(Qwen)는 글자수 나눗셈이 아니라 실제 BPE 병합을 돌리므로,
//    프롬프트가 길면 한 번에 수십만 번의 병합 연산이 된다.
//    입력창을 닫으면 saveAllSettings·refreshUI·setLocal 로 리빌드가 연달아
//    일어나는데, 그때마다 이 계산이 통째로 다시 돌아 메인 스레드가 막혔다.
//
//    같은 문자열은 결과가 항상 같으므로 그대로 재사용한다.
final Map<String, int> _tokenCountCache = {};

int estimateTokenCount(String prompt, {PromptTokenizer tokenizer = PromptTokenizer.t5}) {
  final t = prompt.trim();
  if (t.isEmpty) {
    return 0;
  }
  // T5 는 나눗셈 한 번이라 캐시가 필요 없다
  if (tokenizer == PromptTokenizer.t5) {
    return (t.length / 3.1).round();
  }

  final cached = _tokenCountCache[t];
  if (cached != null) {
    return cached;
  }
  final v = QwenTokenizer.countTokens(t);
  // 프롬프트를 고칠 때마다 새 항목이 쌓이므로 상한을 둔다.
  //  (오래된 것부터 버린다 — Map 은 넣은 순서를 유지한다)
  if (_tokenCountCache.length >= 64) {
    _tokenCountCache.remove(_tokenCountCache.keys.first);
  }
  _tokenCountCache[t] = v;
  return v;
}

/// 현재 선택된 모델이 쓰는 토크나이저
PromptTokenizer _tokenizerOf(AppState state) => modelCapsFor(state.selectedModel).tokenizer;

// 베이스 프롬프트(선행 + 긍정 + 후행 + Quality Tags)의 토큰 수.
//  ⚠️ 부정 프롬프트(UC)는 여기에 더하지 않는다.
//     긍정(베이스+캐릭터)과 부정(UC+캐릭터 UC)은 서로 다른 한도를 쓰기 때문에,
//     합산하면 부정을 길게 쓸수록 긍정 여유가 줄어드는 것처럼 잘못 보인다.
//     (예전 코드는 둘을 더해서 공식 카운터보다 훨씬 큰 값을 표시했다.)
int estimateBaseTokens(AppState state) {
  final combined = [
    state.prefixController.text,
    state.positiveController.text,
    state.suffixController.text,
  ].where((t) => t.trim().isNotEmpty).join(', ');
  final withQuality = state.applyQualityTags(combined);
  return estimateTokenCount(withQuality, tokenizer: _tokenizerOf(state));
}

/// 중첩된 가중치 구간을 NovelAI 가 실제로 해석하는 방식에 맞춰 펼친다.
///
/// NovelAI 의 `::` 는 '스택'이 아니라 '평면'이다.
/// 숫자 없는 `::` 를 만나면 그 앞의 가중치가 **전부** 끝나고 1.0 으로 돌아간다.
/// 즉 아래 두 줄에서 D 는 5.0 이 아니라 1.0 으로 들어간다.
///
/// ```
/// 5.0::A, B, 1.5::C ::, D ::,      ← D 는 1.0 (사람이 기대하는 것과 다름)
/// 5.0::A, B, 1.5::C ::, 5.0::D ::, ← D 를 5.0 으로 두려면 이렇게 써야 한다
/// ```
///
/// 이 함수는 앞 줄을 뒤 줄로 바꿔 준다. 괄호의 짝을 맞추듯 여는 가중치를
/// 스택에 쌓아 두었다가, 구간이 닫히면 바깥 가중치를 다시 열어 준다.
///
/// 건드리지 않는 경우:
///  · 중첩이 없으면 원문 그대로 (스택이 비면 다시 열 것이 없다)
///  · 닫는 `::` 가 남거나 모자라도 무너지지 않는다
///  · `{}` `[]` 같은 다른 강조 문법과는 무관하다
/// 가중치 표시 앞뒤의 쓸모없는 쉼표를 걷어 낸다.
///
/// 선행·긍정·후행을 합칠 때 경계마다 ', ' 가 들어가서, 선행 끝에 연 가중치나
/// 후행 앞에서 닫는 가중치가 엉뚱하게 떨어져 나갔다.
///
///  선행 '1girl, 1.1::'  +  긍정 'shirt, standing'  +  후행 '::, masterpiece'
///   합친 그대로 : 1girl, 1.1::, shirt, standing, ::, masterpiece
///   정리한 뒤   : 1girl, 1.1::shirt, standing::, masterpiece
///
/// 규칙은 두 가지뿐이다.
///  · 여는 표시(1.1::) 바로 뒤의 쉼표를 뺀다 → 가중치가 다음 태그에 바로 붙는다
///  · 닫는 표시(::) 바로 앞의 쉼표를 뺀다   → 앞 태그에 바로 붙어 닫힌다
///  사용자가 직접 띄어 쓴 'test ::' 같은 공백은 건드리지 않는다.
///  '중첩 가중치 펼치기' 설정과 무관하게 항상 적용한다 (합치는 방식의 문제라서).
String tidyWeightMarkers(String input) {
  if (!input.contains('::')) {
    return input;
  }
  return input
      .replaceAllMapped(_weightOpenThenComma, (m) => m.group(1)!)
      .replaceAll(_commaThenWeightClose, '::');
}

final RegExp _weightOpenThenComma = RegExp(r'(-?\d+(?:\.\d+)?\s*::)\s*,\s*');
// 닫는 표시는 숫자가 앞에 붙지 않은 '::' — 쉼표 뒤에 오면 앞에 숫자가 있을 수 없다
final RegExp _commaThenWeightClose = RegExp(r'\s*,\s*::(?!\d)');

String expandNestedWeights(String input) {
  if (!input.contains('::')) {
    return input;
  }

  // 여는 표시(1.5::)와 닫는 표시(::)를 모두 찾는다.
  //  여는 쪽은 숫자가 바로 앞에 붙어 있어야 한다.
  final marker = RegExp(r'(-?\d+(?:\.\d+)?)\s*::|::');

  final buf = StringBuffer();
  final stack = <String>[]; // 열려 있는 가중치들 (바깥 → 안쪽)
  int last = 0;
  bool changed = false;

  for (final m in marker.allMatches(input)) {
    buf.write(input.substring(last, m.start));
    final weight = m.group(1);

    if (weight != null) {
      // 여는 표시 — 원문 그대로 두고 스택에 쌓는다
      buf.write(m.group(0));
      stack.add(weight);
      last = m.end;
      continue;
    }

    // 닫는 표시
    buf.write('::');
    last = m.end;
    if (stack.isNotEmpty) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      continue; // 바깥에 남은 가중치가 없으면 되살릴 것도 없다
    }

    // 바깥 가중치를 다시 연다. 구분자(쉼표·공백·줄바꿈)는 그대로 두고
    // 실제 내용이 시작되는 자리 바로 앞에 끼워 넣는다.
    int p = last;
    while (p < input.length && (input[p] == ',' || _isSpace(input[p]))) {
      p++;
    }
    // 뒤에 내용이 없거나 곧바로 또 닫는다면 넣을 필요가 없다
    if (p >= input.length || input.startsWith('::', p)) {
      continue;
    }
    buf.write(input.substring(last, p));
    buf.write('${stack.last}::');
    last = p;
    changed = true;
  }

  buf.write(input.substring(last));
  return changed ? buf.toString() : input;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

/// 부정 프롬프트(UC 프리셋 포함)의 토큰 수. 긍정과는 별도 한도.
///
/// ⚠️ 현재 어디서도 부르지 않는다 (2026-08 기준).
///    긍정/부정 토큰을 분리하면서 함께 만들었지만, 부정 프롬프트가 한도에
///    닿는 경우가 사실상 없어서 화면에는 표시하지 않기로 했다.
///    "왜 부정은 안 세지?" 라는 의문이 생겼을 때 답이 되도록 남겨 둔다.
///    부정 카운터를 붙이고 싶으면 buildTokenLabel 옆에 이 값을 쓰면 되고,
///    끝내 필요 없다고 판단되면 이 함수째로 지워도 된다.
int estimateNegativeTokens(AppState state) {
  final negative = state.applyUcPreset(state.negativeController.text);
  return estimateTokenCount(negative, tokenizer: _tokenizerOf(state));
}

// 활성 캐릭터 프롬프트만의 토큰 수
int estimateCharacterTokens(AppState state) {
  final parts = <String>[];
  for (final c in state.characters) {
    if (!c.isActive) {
      continue;
    }
    parts.add(c.positive);
  }
  if (parts.isEmpty) {
    return 0;
  }
  return estimateTokenCount(
    parts.where((t) => t.trim().isNotEmpty).join(', '),
    tokenizer: _tokenizerOf(state),
  );
}

// 토큰 표시용 문자열. 캐릭터가 있으면 얼마나 차지하는지 구분해서 보여준다.
//   캐릭터 없음: "256 / 512"
//   캐릭터 있음: "312 (256+56) / 512"
String buildTokenLabel(AppState state, int maxTokens) {
  final base = estimateBaseTokens(state);
  final chars = estimateCharacterTokens(state);
  if (chars == 0) {
    return "$base / $maxTokens";
  }
  return "${base + chars} ($base+$chars) / $maxTokens";
}

// 현재 프롬프트의 총 토큰 수 (선행 + 긍정 + 후행 + 활성 캐릭터).
// NovelAI V4/V4.5는 "base prompt + 모든 character prompts를 합쳐서" ~512 토큰 제한이므로
// 캐릭터 프롬프트도 반드시 합산해야 실제 한도와 맞는다.
//   https://docs.novelai.net/en/image/models/
int estimateTotalTokens(AppState state) {
  return estimateBaseTokens(state) + estimateCharacterTokens(state);
}
// 자동완성 매칭기(smartMatchTags)는 utils/prompt_utils.dart 로 옮겼다.
//  프롬프트탭·확대 입력창·와일드카드탭이 함께 쓰는데 AppState를 전혀 참조하지
//  않아서, 여기 두면 세 화면이 app_state 전체를 끌어와야 했다.
//  기존 호출부가 그대로 동작하도록 파일 상단에서 이름만 다시 내보낸다.

class AppState extends ChangeNotifier {
  // ============================================================================
  // 앱 버전 & 업데이트 체크
  // ============================================================================
  static String currentVersion = "0.0.0"; // pubspec.yaml에서 자동 로드됨
  // GitHub 저장소 주소 (본인 리포로 변경!)
  static const String githubRepo = "Denycreeps/DNaiApp";

  String? latestVersion;
  String? updateUrl;
  String? updateNotes;
  String? apkDownloadUrl; // APK 직접 다운로드 URL
  bool autoCheckUpdate = true; // 기동 시 자동 업데이트 체크
  bool isDownloadingUpdate = false;
  double downloadProgress = 0.0;

  // 업데이트 다이얼로그가 이번 세션에 이미 표시됐는지 (자동 알림/수동 열기 공유 가드).
  // 수동으로 열 때도 이 값을 켜서, main의 자동 알림이 겹쳐 뜨지 않게 한다.
  bool updateDialogShown = false;

  bool get hasUpdate =>
      latestVersion != null && _compareVersions(latestVersion!, currentVersion) > 0;

  /// 릴리즈 노트를 미리보기 형태로 변환
  List<String> get releaseNotePreview {
    if (updateNotes == null || updateNotes!.isEmpty) {
      return [];
    }
    String text = updateNotes!;
    // 1) <br>, </br>, <br/>, <br /> 등 줄바꿈 태그 → 실제 줄바꿈
    text = text.replaceAll(RegExp(r'<\s*/?\s*br\s*/?\s*>', caseSensitive: false), '\n');
    // 2) HTML 주석 <!-- ... --> 제거 (여러 줄 포함)
    text = text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
    // 3) 그 외 모든 HTML 태그 (<...>로 둘러싼 것) 제거
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');
    return text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('![')) // 이미지 라인 제외
        .map((line) {
          // 마크다운 헤더 정리
          line = line.replaceAll(RegExp(r'^#+\s*'), '');
          // 40자 넘으면 자르기
          //  ⚠️ substring은 UTF-16 코드 유닛 기준이라 이모지(서로게이트 페어)
          //     한가운데를 잘라 글자가 깨진다. 릴리즈 노트엔 이모지가 흔하므로
          //     runes(실제 글자) 기준으로 자른다.
          final runes = line.runes.toList();
          if (runes.length > 40) {
            return '${String.fromCharCodes(runes.take(40))}...';
          }
          return line;
        })
        .take(10) // 최대 10줄
        .toList();
  }

  static int _compareVersions(String a, String b) {
    final pa = a.replaceFirst('v', '').split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.replaceFirst('v', '').split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) {
        return va.compareTo(vb);
      }
    }
    return 0;
  }

  Future<void> checkForUpdate() async {
    try {
      // releases/latest는 'commit 날짜' 기준이라 태그를 옛 커밋에 달면 최신을 못 찾음.
      // releases 목록 전체를 받아서 버전 번호로 직접 최댓값을 찾는다.
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$githubRepo/releases?per_page=30'),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final releases = jsonDecode(resp.body) as List? ?? [];
        Map<String, dynamic>? best;
        String bestTag = "";
        for (final r in releases) {
          // draft / prerelease 제외
          if ((r['draft'] as bool?) ?? false) {
            continue;
          }
          if ((r['prerelease'] as bool?) ?? false) {
            continue;
          }
          final tag = r['tag_name']?.toString() ?? "";
          if (tag.isEmpty) {
            continue;
          }
          if (best == null || _compareVersions(tag, bestTag) > 0) {
            best = Map<String, dynamic>.from(r);
            bestTag = tag;
          }
        }

        if (best != null && _compareVersions(bestTag, currentVersion) > 0) {
          latestVersion = bestTag.replaceFirst('v', '');
          updateUrl = best['html_url']?.toString();
          updateNotes = best['body']?.toString();

          // APK 에셋 찾기
          final assets = best['assets'] as List? ?? [];
          for (final asset in assets) {
            final name = asset['name']?.toString() ?? '';
            if (name.endsWith('.apk')) {
              apkDownloadUrl = asset['browser_download_url']?.toString();
              break;
            }
          }
          notifyListeners();
        }
      }
    } catch (_) {
      // 네트워크 실패 시 무시 (업데이트 체크는 부가 기능)
    }
  }

  // ══════════════════════════════════════════════════════════════
  // 업데이트 전 자동 백업
  // ══════════════════════════════════════════════════════════════
  //
  //  평소 업데이트는 앱 데이터를 그대로 두지만, 서명이 바뀌는 등 '지우고 다시 깔아야'
  //  하는 경우엔 설정·프리셋·사전이 모두 사라진다. 그래서 설치 직전에 한 번 떠 둔다.
  //
  //  · 담는 것: 설정·계정·프리셋·와일드카드·캐릭터·프롬프트 사전 + 즐겨찾기 히스토리
  //    (히스토리 전체는 썸네일 만드는 데만 수 초 — 즐겨찾기만 작은 썸네일로)
  //  · 저장 위치: 저장 폴더의 settings/ — 앱을 지워도 남는 곳
  //  · 저장 폴더를 아직 안 정했으면 조용히 건너뛴다 (업데이트를 막지 않는다)
  //  · 자동 백업은 최근 [_autoBackupKeep] 개만 남긴다

  static const int _autoBackupKeep = 3;
  static const String _autoBackupPrefix = 'DNaiApp_autobackup_';

  /// 업데이트 전 백업 중인지 (설정 > 기타 에 상태를 보여 주는 데 쓴다)
  bool isBackingUpBeforeUpdate = false;

  /// 이번에 앱을 켠 뒤 이미 백업해 둔 대상 버전.
  ///  ⚠️ 설치창에서 취소하고 다시 누를 때마다 백업하면, 거의 같은 파일 3개가
  ///     칸을 다 채워 '이전 버전 때 백업'이 밀려난다. 그래서 한 번만 뜬다.
  ///  일부러 저장하지 않는다 — 앱이 꺼졌다 켜지면 상태가 바뀌었을 수 있으니
  ///  그때는 다시 뜨는 게 맞다.
  String? _autoBackupDoneFor;

  /// 업데이트 직전에 지금 상태를 파일로 떠 둔다. 성공하면 보여 줄 경로, 아니면 null.
  ///  ⚠️ 여기서 난 오류는 절대 밖으로 던지지 않는다 — 백업 때문에 업데이트가 막히면 안 된다.
  Future<String?> _autoBackupBeforeUpdate() async {
    if (safRootUri == null || !Platform.isAndroid) {
      return null;
    }
    if (_autoBackupDoneFor != null && _autoBackupDoneFor == latestVersion) {
      return null; // 이번 실행에서 이미 떠 둠 (설치를 취소하고 다시 누른 경우)
    }
    isBackingUpBeforeUpdate = true;
    notifyListeners();
    try {
      final data = await exportSettings(includeHistory: true, favoritesOnly: true);
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp =
          '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
      // 파일 이름은 영문·숫자만 — 저장소·PC 로 옮길 때 깨지지 않게
      final name =
          '$_autoBackupPrefix'
          'v${currentVersion}_to_v${latestVersion ?? 'x'}_$stamp.json';
      final shown = await saveSettingsViaSaf(name, jsonEncode(data));
      if (shown != null) {
        debugPrint('업데이트 전 자동 백업: $shown');
        // 성공했을 때만 기억한다 (실패했으면 다음에 다시 시도해야 한다)
        _autoBackupDoneFor = latestVersion;
        await _pruneAutoBackups();
      }
      return shown;
    } catch (e) {
      debugPrint('업데이트 전 자동 백업 실패(업데이트는 계속): $e');
      return null;
    } finally {
      isBackingUpBeforeUpdate = false;
      notifyListeners();
    }
  }

  /// 설치창을 열기 전에 백업이 끝나기를 기다린다.
  ///  ⚠️ 무한정 기다리지 않는다 — 저장소가 느리거나 멈춰도 업데이트는 진행돼야 한다.
  Future<void> _waitBackup(Future<String?> backup) async {
    try {
      await backup.timeout(const Duration(seconds: 20));
    } catch (_) {
      debugPrint('자동 백업이 늦어 기다리지 않고 설치를 진행합니다.');
    }
  }

  /// 자동 백업을 최근 [_autoBackupKeep] 개만 남기고 지운다.
  ///  (직접 '내보내기' 한 파일은 이름이 달라 건드리지 않는다)
  Future<void> _pruneAutoBackups() async {
    final root = safRootUri;
    if (root == null) {
      return;
    }
    try {
      final dir = await _safUtil.mkdirp(root, _appFolderPath(['settings']));
      final items =
          (await _safUtil.list(
              dir.uri,
            )).where((f) => !f.isDir && f.name.startsWith(_autoBackupPrefix)).toList()
            // 이름 끝에 날짜·시각이 붙어 있어 이름 역순 = 최신순
            ..sort((a, b) => b.name.compareTo(a.name));
      for (final old in items.skip(_autoBackupKeep)) {
        await _safUtil.delete(old.uri, false);
      }
    } catch (e) {
      debugPrint('옛 자동 백업 정리 실패(무시): $e');
    }
  }

  /// 받아 둔 APK 가 그대로 쓸 수 있는 상태인지.
  ///
  /// 다운로드가 중간에 끊긴 파일이 남아 있을 수 있어 크기까지 확인한다.
  /// 크기를 모르면(기록이 없으면) 믿지 않고 다시 받는다 — 깨진 파일을
  /// 설치하려 하면 원인을 알기 어려운 오류가 난다.
  Future<bool> _isUsableApk(File file) async {
    try {
      if (!await file.exists()) {
        return false;
      }
      final prefs = await SharedPreferences.getInstance();
      final expected = prefs.getInt('apkSize_$latestVersion');
      if (expected == null || expected <= 0) {
        return false;
      }
      return await file.length() == expected;
    } catch (_) {
      // 확인에 실패하면 안전하게 다시 받는다
      return false;
    }
  }

  Future<void> _rememberApkSize(String? version, int size) async {
    if (version == null) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('apkSize_$version', size);
    } catch (_) {
      // 기록에 실패해도 이번 설치는 그대로 진행된다 (다음에 다시 받을 뿐)
    }
  }

  /// 지금 쓰는 것 말고 예전에 받아 둔 APK 파일을 지운다.
  ///  수십 MB짜리라 쌓이면 저장 공간을 잡아먹는다.
  Future<void> _cleanupOldApks({String? keep}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final prefs = await SharedPreferences.getInstance();
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('DNaiApp_v') || !name.endsWith('.apk')) {
          continue;
        }
        if (f.path == keep) {
          continue;
        }
        await f.delete();
        // 크기 기록도 같이 정리
        final v = name.substring('DNaiApp_v'.length, name.length - '.apk'.length);
        await prefs.remove('apkSize_$v');
      }
    } catch (e) {
      debugPrint('옛 APK 정리 실패(무시): $e');
    }
  }

  /// 받아 둔 APK 를 설치 화면으로 넘긴다.
  Future<void> _openApk(File file, BuildContext context) async {
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done && context.mounted) {
      showToast(context, "설치 실행에 실패했습니다: ${result.message}");
    }
  }

  Future<void> downloadAndInstallUpdate(BuildContext context) async {
    // 이미 다운로드 중이면 중복 실행 무시 (버튼 연타/중복 호출 방지)
    if (isDownloadingUpdate) {
      return;
    }
    if (apkDownloadUrl == null) {
      if (context.mounted) {
        showToast(context, "다운로드 URL을 찾을 수 없습니다.");
      }
      return;
    }

    // 다운로드가 시작되면 진행률이 보이는 곳(설정 > 기타)으로 옮겨 준다.
    //  받는 동안 아무 표시도 없으면 멈춘 것처럼 보인다.
    navigateToSettings(3);

    // 업데이트 전 자동 백업 — 다운로드와 '나란히' 돌린다.
    //  다운로드가 훨씬 오래 걸리므로 백업 때문에 더 기다리는 일은 거의 없다.
    //  설치창을 열기 직전에만 끝났는지 확인한다 (설치창이 뜨면 앱이 곧 꺼진다).
    final Future<String?> backup = _autoBackupBeforeUpdate();

    isDownloadingUpdate = true;
    downloadProgress = 0.0;
    notifyListeners();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/DNaiApp_v$latestVersion.apk');

      // 이미 받아 둔 파일이 있으면 다시 받지 않는다.
      //  ⚠️ 설치가 취소되는 일이 잦다 (출처 허용을 안 했거나 실수로 뒤로 감).
      //     그때마다 수십 MB를 다시 받는 것은 낭비다.
      //     임시 폴더는 시스템이 언제든 지우므로 문서 폴더에 둔다.
      if (await _isUsableApk(file)) {
        debugPrint('이미 받아 둔 APK 사용: ${file.path}');
        isDownloadingUpdate = false;
        downloadProgress = 1.0;
        notifyListeners();
        await _waitBackup(backup);
        // 파일을 확인하는 사이 화면이 닫혔을 수 있다
        if (!context.mounted) {
          return;
        }
        await _openApk(file, context);
        return;
      }

      // 스트리밍 다운로드 (프로그레스 표시)
      final request = http.Request('GET', Uri.parse(apkDownloadUrl!));
      final response = await http.Client().send(request);
      final contentLength = response.contentLength ?? 0;

      List<int> bytes = [];
      int received = 0;

      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          downloadProgress = received / contentLength;
          notifyListeners();
        }
      }

      await file.writeAsBytes(bytes);
      // 다음에 설치가 취소돼도 다시 받지 않도록 크기를 기록해 둔다
      await _rememberApkSize(latestVersion, bytes.length);
      // 옛 버전 파일은 이제 필요 없다
      await _cleanupOldApks(keep: file.path);

      isDownloadingUpdate = false;
      downloadProgress = 1.0;
      notifyListeners();

      await _waitBackup(backup);
      // 받는 동안 화면이 닫혔을 수 있다 (수십 초가 걸리기도 한다)
      if (!context.mounted) {
        return;
      }
      await _openApk(file, context);
    } catch (e) {
      isDownloadingUpdate = false;
      downloadProgress = 0.0;
      notifyListeners();
      debugPrint("업데이트 다운로드 실패: $e");
      if (context.mounted) {
        showToast(context, "다운로드에 실패했습니다.");
      }
    }
  }

  // ============================================================================

  final TextEditingController positiveController = WeightHighlightController();
  final TextEditingController negativeController = WeightHighlightController();
  final TextEditingController prefixController = WeightHighlightController();
  final TextEditingController suffixController = WeightHighlightController();

  final TextEditingController inpaintPositiveController = TextEditingController();
  final TextEditingController inpaintNegativeController = TextEditingController();
  final TextEditingController inpaintPrefixController = TextEditingController();
  final TextEditingController inpaintSuffixController = TextEditingController();

  final TextEditingController stepsController = TextEditingController(text: "28");
  final TextEditingController cfgScaleController = TextEditingController(text: "6.0");
  final TextEditingController cfgRescaleController = TextEditingController(text: "0.00");
  final TextEditingController seedController = TextEditingController();
  final TextEditingController apiTokenController = TextEditingController();

  final TextEditingController gelbooruApiController = TextEditingController();
  String gelbooruUserId = "";
  String gelbooruApiKey = "";

  final TextEditingController gelbooruIncludeController = TextEditingController();
  final TextEditingController gelbooruExcludeController = TextEditingController();
  final TextEditingController customRemoveController = TextEditingController();
  final TextEditingController customFileNameController = TextEditingController(
    text: "Nai-{yy}{mm}{dd}-{time}",
  );
  final TextEditingController customWidthController = TextEditingController(text: "832");
  final TextEditingController customHeightController = TextEditingController(text: "1216");

  final SyntaxHighlightController conditionalRuleController = SyntaxHighlightController();

  /// AppState가 버려질 때 컨트롤러·타이머를 정리한다.
  ///  ⚠️ 여기 목록은 위에서 선언한 Controller와 1:1로 맞춰야 한다.
  ///     새 컨트롤러를 추가하면 반드시 이 목록에도 넣을 것.
  ///  ※ 앱 수명 = AppState 수명이라 실사용에선 종료 시점에만 불리지만,
  ///     ChangeNotifier 계약상 정리 책임은 이쪽에 있다.
  @override
  void dispose() {
    // 예약된 저장 작업이 남아 있으면 취소 (dispose 이후 notifyListeners 방지)
    _saveSettingsDebounce?.cancel();
    _historySaveDebounce?.cancel();

    for (final c in <TextEditingController>[
      positiveController,
      negativeController,
      prefixController,
      suffixController,
      inpaintPositiveController,
      inpaintNegativeController,
      inpaintPrefixController,
      inpaintSuffixController,
      stepsController,
      cfgScaleController,
      cfgRescaleController,
      seedController,
      apiTokenController,
      gelbooruApiController,
      gelbooruIncludeController,
      gelbooruExcludeController,
      customRemoveController,
      customFileNameController,
      customWidthController,
      customHeightController,
      conditionalRuleController,
      weightRulesController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // 조건부 트리거 작동 시점: "random"(랜덤 프롬프트 생성 시) / "generate"(이미지 생성 시)
  String conditionalTriggerMode = "random";

  bool ratingE = false;
  bool ratingQ = false;
  bool ratingS = false;
  bool ratingG = true;
  bool removeCharacteristics = false;
  bool removeClothes = false;
  // 의상 상태/동작 태그 제거 (unworn, torn, grab 등)
  bool removeClothingEvents = false;
  // 중복 태그 정리: 구체적인 태그가 있으면 그것이 함의하는 상위 태그를 제거
  //   예: "plaid skirt"가 있으면 "skirt"는 중복이므로 삭제 → 토큰 절약
  bool removeImpliedTags = false;

  // 캐릭터 탭에서 선택된 캐릭터를 한 번 더 눌러 ON/OFF 하는 기능
  // (자주 탭하는 사람은 오조작이 잦다는 의견이 있어 끌 수 있게 함)
  bool charRetapToggle = true;

  // 저장 폴더를 '날짜'로만 만든다 (기본 OFF = 실행할 때마다 날짜_시간 폴더)
  bool saveFolderByDateOnly = true;
  bool removeColors = false;
  bool isAutoSave = true;
  // 이미지를 WebP(무손실)로 저장 — 용량 약 26% 절감, 메타데이터는 EXIF로 보존
  bool saveAsWebp = false;
  // WebP 저장 시 손실 압축(품질 95) 사용 — 화질 차이 거의 없이 용량이 크게 줄어든다
  bool webpLossy = false;

  /// 설정(두 스위치)으로 정해지는 저장 형식.
  ///  설정 값 자체(saveAsWebp·webpLossy)는 그대로 두고 여기서 해석만 한다
  ///  → 옛 설정·백업과 그대로 호환된다. 확장자·품질은 image_codec.dart 의 SaveFormat 에 있다.
  SaveFormat get saveFormat =>
      !saveAsWebp ? SaveFormat.png : (webpLossy ? SaveFormat.webpLossy : SaveFormat.webpLossless);
  bool isRandomLocked = false;
  bool isSeedLocked = false;
  double infillStrength = 0.7;
  // img2img: 원본 변형 강도(낮을수록 원본 충실) / 노이즈(새 디테일 추가량)
  double img2imgStrength = 0.5;
  double img2imgNoise = 0.1;
  bool isVariancePlus = false; // VAR+ (Variety+) 모드
  bool horizontalSwipeEnabled = false; // 좌우 스와이프 탭 전환
  // 프롬프트 탭 2번째 UI (합본 미리보기 + 기능 묶음). 기본 OFF — 기존 UI 유지
  // 프롬프트 탭을 개편된 새 레이아웃으로 표시 (기본 OFF = 기존 사용자에게 익숙한 예전 UI)
  bool promptNewLayout = true;

  // ⚠️ [보류] 프롬프트탭 2번째 UI. 설정 화면에서는 숨겨져 있다(settings_tab 참고).
  //  구현은 prompt_tab.dart의 _buildAltLayout 이하에 그대로 살아 있으므로,
  //  디버깅/참고용으로 이 값을 true 로 두면 다시 사용할 수 있다.
  bool promptAltLayout = false;
  // 검색 페이지 수 (API 키 있을 때만 유효). 기본 40, 상한 120.
  int gelbooruSearchPages = 40;
  // [실험] 정렬 축 다양화 (random+score+id 섞기) — 중복 줄이고 표본 확대
  bool diversifySearchSort = false;
  // 프롬프트 탭 캐릭터 편집 서랍 표시 (기본 OFF)
  bool promptCharDrawerEnabled = true;
  // 가중치 규칙: "태그=숫자" 형식으로 프롬프트의 특정 태그에 NovelAI 가중치를 자동 적용
  bool _weightRulesEnabled = false;
  bool get weightRulesEnabled => _weightRulesEnabled;
  set weightRulesEnabled(bool v) {
    _weightRulesEnabled = v;
    WeightRulesController.rulesEnabled = v; // 입력창 강조와 동기화
  }

  final WeightRulesController weightRulesController = WeightRulesController();
  bool historySlideEnabled = false; // 히스토리 이미지 슬라이드 (화살표 + 애니메이션)
  bool randomPromptAlphabetical = false; // 랜덤 프롬프트 나머지 태그 알파벳 순서
  bool ignoreRecommendedOrder = false; // NovelAI 권장 순서(인원/solo/시점 등) 무시
  bool weightHighlight = true; // 가중치 문법 색상 하이라이트 (기본 ON)

  // 배치 생성
  int batchCount = 1; // 1, 2, 3, 4, 0(무한)
  // 순차 생성 <A|B|C> 카운터: 키=위치인덱스, 값=현재 회차
  final Map<String, int> _sequentialCounters = {};
  int batchRemaining = 0; // 남은 생성 수
  bool isBatchMode = false;
  double batchDelay = 0.5; // 연속 생성 딜레이 (초)
  bool autoNextPromptInBatch = false; // 자동생성 중 이미지 1장마다 다음 프롬프트 자동 전환
  // 같은 프롬프트로 N번 반복 후 다음 프롬프트로 (자동 전환이 ON일 때만 의미 있음)
  bool repeatSamePromptEnabled = false;
  int repeatSamePromptCount = 2;
  // 현재 반복 진행 상황 (UI 표시용) — 반복 미사용 시 0
  int currentRepeatIndex = 0; // 현재 몇 번째 반복인지 (1부터)
  int currentRepeatTotal = 0; // 이번 회차의 총 반복 횟수

  // 탭 활성화 상태 (프롬프트/설정은 항상 켜짐)
  bool historyTabEnabled = true;
  // 설정 하위탭별 스크롤 위치. 탭 표시를 토글하면 PageView가 재생성되어
  // 위젯 로컬 ScrollController가 초기화되므로, 위치를 여기 보관해 복원한다.
  final Map<int, double> settingsScrollOffsets = {};

  bool i2iTabEnabled = true;
  // i2i 탭 안에서 각 모드를 보일지 (4개 모두 끄면 i2i 탭 자체가 꺼짐)
  bool i2iModeInpaintEnabled = true;
  bool i2iModeMosaicEnabled = true;
  bool i2iModeImg2imgEnabled = true;
  bool i2iModeUpscaleEnabled = true;

  // 현재 켜져 있는 i2i 모드 목록 (표시 순서 유지)
  List<String> get enabledI2iModes => [
    if (i2iModeInpaintEnabled) 'inpaint',
    if (i2iModeMosaicEnabled) 'mosaic',
    if (i2iModeImg2imgEnabled) 'img2img',
    if (i2iModeUpscaleEnabled) 'upscale',
  ];

  // i2i 모드 하나를 켜고 끈다. 모드가 모두 꺼지면 i2i 탭 자체도 함께 꺼진다.
  // i2i 모드 하나를 켜고 끈다.
  // 모드가 모두 꺼지면 i2i 탭도 함께 꺼지고, 빈 상태에서 모드를 켜면 탭도 되살아난다.
  // 그 외의 경우엔 사용자가 정한 탭 ON/OFF 상태를 건드리지 않는다.
  void setI2iModeEnabled(String mode, bool enabled) {
    final bool wasEmpty = enabledI2iModes.isEmpty;
    switch (mode) {
      case 'inpaint':
        i2iModeInpaintEnabled = enabled;
        break;
      case 'mosaic':
        i2iModeMosaicEnabled = enabled;
        break;
      case 'img2img':
        i2iModeImg2imgEnabled = enabled;
        break;
      case 'upscale':
        i2iModeUpscaleEnabled = enabled;
        break;
    }
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false; // 모드가 하나도 없으면 탭도 끔
    } else if (wasEmpty && enabled) {
      i2iTabEnabled = true; // 전부 꺼졌던 상태에서 모드를 켬 → 탭 부활
    }
    saveAllSettings();
    notifyListeners();
  }

  // 탭 표시 설정에서 i2i 탭을 켜고 끈다.
  // 모드가 전부 꺼진 상태에서 탭을 다시 켜면, 모드도 함께 되살린다.
  void setI2iTabEnabled(bool enabled) {
    i2iTabEnabled = enabled;
    if (enabled && enabledI2iModes.isEmpty) {
      // 켤 모드가 없으면 전부 복구 (그래야 탭이 의미가 있음)
      i2iModeInpaintEnabled = true;
      i2iModeMosaicEnabled = true;
      i2iModeImg2imgEnabled = true;
      i2iModeUpscaleEnabled = true;
    }
    saveAllSettings();
    notifyListeners();
  }

  bool characterTabEnabled = true;
  bool wildcardTabEnabled = true;
  bool useGelbooruApiKey = true;

  // 프롬프트 섹션 순서 (드래그로 재배치 가능)
  List<String> promptSectionOrder = [
    'positive',
    'prefix',
    'suffix',
    'negative',
    'removeChips',
    'customRemove',
    'conditional',
    'weightRules',
  ];

  // 앱에서 지원하는 전체 섹션 (저장된 순서와 대조해 누락/불명 항목 정리)
  static const List<String> _allSections = [
    'positive',
    'prefix',
    'suffix',
    'negative',
    'removeChips',
    'customRemove',
    'conditional',
    'weightRules',
  ];

  List<String> _mergeSectionOrder(List<String> saved) {
    final merged = saved.where(_allSections.contains).toList();
    for (final sec in _allSections) {
      if (!merged.contains(sec)) {
        merged.add(sec); // 새로 추가된 섹션은 뒤에
      }
    }
    return merged;
  }

  // 프롬프트 섹션 접기 상태
  Set<String> collapsedSections = {};

  // 프롬프트 탭에서 숨길 섹션들 (설정 > 프롬프트 창 표시)
  // 전부 숨겨도 프롬프트 탭 자체는 유지된다.
  Set<String> hiddenPromptSections = {};

  // 2번째 UI 전용: 묶음에서 꺼내 메인 화면에 고정할 창들
  // (기존 UI의 hiddenPromptSections와는 별개 — 서로 간섭하지 않게 분리)
  Set<String> pinnedPromptSections = {};

  // 조건부 트리거 문법 가이드 접힘 상태
  bool conditionalGuideCollapsed = false;

  void togglePinnedSection(String sectionId) {
    if (pinnedPromptSections.contains(sectionId)) {
      pinnedPromptSections.remove(sectionId);
    } else {
      pinnedPromptSections.add(sectionId);
    }
    saveAllSettings();
    notifyListeners();
  }

  // i2i 탭 프롬프트 카드 접기 상태 (positive/prefix/suffix/negative)
  // 부정적처럼 한 번 넣고 신경 끄는 항목을 접어둘 수 있게 저장까지 유지한다.
  Set<String> collapsedI2iPrompts = {};

  // 설정 탭에서 접어둔 그룹들 (설정이 많아져 그룹별로 접을 수 있게 함)
  Set<String> collapsedSettingGroups = {};

  /// 앱 액센트 색을 바꾼다.
  ///  themeAccent(저장용 int)와 AppColors.accent(그리기용 Color)를 함께 갱신해
  ///  둘이 어긋나는 사고를 원천 차단한다.
  void setThemeAccent(int argb) {
    themeAccent = argb;
    AppColors.accent = Color(argb);
    saveAllSettings();
    notifyListeners();
  }

  void toggleSettingGroup(String groupId) {
    if (collapsedSettingGroups.contains(groupId)) {
      collapsedSettingGroups.remove(groupId);
    } else {
      collapsedSettingGroups.add(groupId);
    }
    saveAllSettings();
    notifyListeners();
  }

  void toggleI2iPromptCollapsed(String cardId) {
    if (collapsedI2iPrompts.contains(cardId)) {
      collapsedI2iPrompts.remove(cardId);
    } else {
      collapsedI2iPrompts.add(cardId);
    }
    saveAllSettings();
    notifyListeners();
  }

  void setPromptSectionVisible(String sectionId, bool visible) {
    if (visible) {
      hiddenPromptSections.remove(sectionId);
    } else {
      hiddenPromptSections.add(sectionId);
    }
    saveAllSettings();
    notifyListeners();
  }

  String resolutionMode = "수동";
  int currentImageWidth = 0;
  int currentImageHeight = 0;
  String apiToken = "";

  // ── NovelAI 계정(토큰) 여러 개 관리 ──
  //  V5의 시간당 사용 한도 때문에 계정을 번갈아 쓰는 경우가 생겼다.
  //  apiToken은 '지금 선택된 계정의 토큰'을 담는다 → 전송 코드는 그대로 둔다.
  List<NaiAccount> naiAccounts = [];
  int activeAccountIndex = 0;

  NaiAccount? get activeAccount =>
      (activeAccountIndex >= 0 && activeAccountIndex < naiAccounts.length)
      ? naiAccounts[activeAccountIndex]
      : null;

  /// 계정 전환 — 토큰을 갈아끼우고 잔액을 다시 확인한다.
  Future<void> switchAccount(int index) async {
    if (index < 0 || index >= naiAccounts.length) {
      return;
    }
    activeAccountIndex = index;
    apiToken = naiAccounts[index].token;
    apiTokenController.text = apiToken;
    isApiConnected = false; // 조회가 성공해야 연결로 본다
    // ⚠️ 이전 계정의 잔액이 남아 있으면 새 계정 것으로 오해된다 → 먼저 비운다
    currentAnlas = 0;
    v5LimitPercent = null;
    notifyListeners();

    if (apiToken.isEmpty) {
      naiAccounts[index].anlas = -1; // 토큰이 없으면 '미확인'
      await saveAllSettings();
      notifyListeners();
      return;
    }

    // 새 계정의 잔액·한도를 확인
    await fetchAnlas();
    naiAccounts[index].anlas = isApiConnected ? currentAnlas : -1;
    if (modelCapsFor(selectedModel).hasHourlyLimit) {
      await fetchV5Limit();
    }
    await saveAllSettings();
    notifyListeners();
  }

  /// 계정 추가
  Future<void> addAccount(String label, String token) async {
    final wasEmpty = naiAccounts.isEmpty;
    naiAccounts.add(
      NaiAccount(
        label: label.trim().isEmpty ? '계정 ${naiAccounts.length + 1}' : label.trim(),
        token: token.trim(),
      ),
    );
    await saveAllSettings();
    notifyListeners();
    // 첫 계정이면 바로 연결한다 (따로 고를 필요 없이)
    if (wasEmpty) {
      await switchAccount(0);
    }
  }

  /// 계정 수정
  void updateAccount(int index, {String? label, String? token}) {
    if (index < 0 || index >= naiAccounts.length) {
      return;
    }
    final acc = naiAccounts[index];
    if (label != null) {
      acc.label = label.trim();
    }
    if (token != null) {
      final changed = acc.token != token.trim();
      acc.token = token.trim();
      if (changed) {
        acc.anlas = -1; // 토큰이 바뀌었으니 잔액은 다시 확인해야 한다
      }
      if (index == activeAccountIndex) {
        apiToken = acc.token;
        apiTokenController.text = acc.token;
        if (changed) {
          // 잔액이 낡은 채로 남으면 생성 시 '포인트 소모' 경고가 잘못 뜬다
          currentAnlas = 0;
          isApiConnected = false;
          v5LimitPercent = null;
          notifyListeners();
          // 새 토큰으로 즉시 확인
          fetchAnlas().then((_) {
            acc.anlas = isApiConnected ? currentAnlas : -1;
            saveAllSettings();
            notifyListeners();
          });
        }
      }
    }
    saveAllSettings();
    notifyListeners();
  }

  /// 계정 삭제 — 마지막 하나는 남긴다.
  Future<void> removeAccount(int index) async {
    if (naiAccounts.length <= 1 || index < 0 || index >= naiAccounts.length) {
      return;
    }
    final wasActive = index == activeAccountIndex;
    naiAccounts.removeAt(index);

    // 남은 계정 중 어디를 쓸지 정한다
    int next = activeAccountIndex;
    if (next >= naiAccounts.length) {
      next = naiAccounts.length - 1;
    } else if (index < activeAccountIndex) {
      next--;
    }

    // 지운 게 쓰던 계정이면, 사용자가 직접 고른 것과 똑같이 전환한다.
    //  (그래야 Anlas·연결 상태가 제대로 갱신된다)
    if (wasActive) {
      activeAccountIndex = -1; // switchAccount가 '같은 인덱스'로 보고 건너뛰지 않게
      await switchAccount(next);
      return;
    }

    activeAccountIndex = next;
    await saveAllSettings();
    notifyListeners();
  }

  /// 예전 버전(토큰 1개)에서 넘어온 데이터를 계정 목록으로 옮긴다.
  void _migrateSingleToken() {
    if (naiAccounts.isNotEmpty) {
      return;
    }
    // 토큰이 없으면 빈 계정을 만들지 않는다.
    //  목록이 비어 있으면 UI가 '계정을 추가해 주세요'를 보여주고,
    //  첫 계정을 만들면 addAccount가 자동으로 연결한다.
    if (apiToken.trim().isEmpty) {
      return;
    }
    naiAccounts.add(NaiAccount(label: '계정 1', token: apiToken));
    activeAccountIndex = 0;
  }

  bool isApiConnected = false;
  int sessionSaveCount = 0;
  int sessionGenerateCount = 0;
  String? sessionFolderName;

  // 저장 폴더 이름을 결정한다.
  //  - 기본: 앱 실행 세션마다 'yyyyMMdd_HHmmss' (껐다 켤 때마다 새 폴더)
  //  - saveFolderByDateOnly: 'yyyyMMdd' 로 하루에 한 폴더만 사용
  //    (자정을 넘기면 자동으로 다음 날짜 폴더가 만들어진다)
  String _resolveSessionFolder() {
    if (saveFolderByDateOnly) {
      return DateFormat('yyyyMMdd').format(DateTime.now());
    }
    return sessionFolderName ??= DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
  }

  // 갤러리 모드 상태
  String? galleryCurrentPath; // 현재 보고 있는 폴더 (마지막 본 폴더 기억)
  int galleryColumns = 3; // 갤러리 가로 표시 개수 (기본 3)
  double promptEditorFontSize = 16.0; // 프롬프트 확대 입력창 폰트 크기 (기본 16)
  String gallerySortMode = 'name_asc'; // 갤러리 정렬 (name_asc/name_desc, 추후 date_* 등 확장)

  // ===== SAF 저장 폴더 (Phase 1: 선택/해제/로드만, 저장·읽기 연결은 다음 단계) =====

  // 사용자에게 폴더 선택창을 띄워 SAF 트리 URI를 확보 (쓰기 권한 + 영속)
  // 반환: true=선택됨, false=취소/실패
  Future<bool> pickSafRoot() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      // persistablePermission: true → 재시작/재부팅 후에도 권한 유지 (takePersistableUriPermission)
      final dir = await _safUtil.pickDirectory(writePermission: true, persistablePermission: true);
      if (dir == null) {
        return false; // 사용자가 취소
      }
      safRootUri = dir.uri;
      safRootName = dir.name;
      _safSessionDirUri = null; // 루트 바뀌면 세션 캐시 무효화
      _safSessionDirName = null;
      clearSafBrowseLocation();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('safRootUri', dir.uri);
      await prefs.setString('safRootName', dir.name);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('SAF 폴더 선택 실패: $e');
      return false;
    }
  }

  // SAF 폴더 선택 해제 (영속 권한도 반납)
  Future<void> clearSafRoot() async {
    final uri = safRootUri;
    safRootUri = null;
    safRootName = null;
    _safSessionDirUri = null;
    _safSessionDirName = null;
    clearSafBrowseLocation();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('safRootUri');
      await prefs.remove('safRootName');
      if (uri != null && Platform.isAndroid) {
        await _safUtil.releasePersistedPermission(uri);
      }
    } catch (e) {
      debugPrint('SAF 폴더 해제 실패: $e');
    }
    notifyListeners();
  }

  /// SAF 루트 폴더의 settings/ 안에 텍스트 파일을 저장한다.
  ///  설정 백업 전용. 반환은 표시용 경로, SAF 미설정/실패면 null.
  ///
  ///  ⚠️ 왜 SAF를 쓰는가:
  ///     예전에는 getExternalStorageDirectory()(=/Android/data/<패키지>/files)에
  ///     저장했는데, 안드로이드 11(API 30)부터 문서 선택기가 Android/data 안을
  ///     들여다볼 수 없게 막혔다. 그래서 저장은 되는데 '가져오기'에서 폴더 자체가
  ///     보이지 않는 문제가 있었다. SAF 폴더는 사용자가 직접 고른 위치라 안전하다.
  /// 저장 폴더 안에서 '앱 폴더' 아래의 경로 조각.
  ///  사용자가 고른 폴더 이름이 이미 'DNaiApp' 이면 한 단계를 건너뛴다
  ///  (DNaiApp/DNaiApp/… 처럼 겹치지 않게).
  ///  ⚠️ 예전엔 이 판단이 저장·설정·자동 백업 곳곳에 따로 적혀 있었다.
  List<String> _appFolderPath(List<String> sub) {
    final rootIsDnai = (safRootName ?? '').trim().toLowerCase() == 'dnaiapp';
    return rootIsDnai ? sub : ['DNaiApp', ...sub];
  }

  Future<String?> saveSettingsViaSaf(String fileName, String contents) async {
    final root = safRootUri;
    if (root == null || !Platform.isAndroid) {
      return null;
    }
    try {
      final pathParts = _appFolderPath(['settings']);
      final dir = await _safUtil.mkdirp(root, pathParts);
      await _safStream.writeFileBytes(
        dir.uri,
        fileName,
        'application/json',
        Uint8List.fromList(utf8.encode(contents)),
      );
      final shown = _appFolderPath(['settings', fileName]).join('/');
      return '${safRootName ?? 'SAF'}/$shown';
    } catch (e) {
      debugPrint('설정 SAF 저장 실패: $e');
      return null;
    }
  }

  // SAF 루트 폴더에 이미지 1장 저장 (Phase 2: 플랫 — 루트 폴더에 바로)
  // 반환: 성공 시 표시용 문자열, 미설정/실패 시 null
  Future<String?> _saveImageViaSaf(Uint8List bytes, String fileName, String ext) async {
    final root = safRootUri;
    if (root == null || !Platform.isAndroid) {
      return null;
    }
    try {
      // 확장자와 mime이 어긋나면 안드로이드가 확장자를 덧붙인다(예: name.webp.png)
      final mime = mimeForExt(ext);
      final session = _resolveSessionFolder();
      // 루트 폴더명이 이미 'DNaiApp'(대소문자 무시)이면 DNaiApp 중첩 생성 방지
      final pathParts = _appFolderPath([session]);
      // 세션 폴더 확보 (같은 세션이면 캐시 재사용 → mkdirp 반복 호출 방지)
      String dirUri;
      final cachedDir = _safSessionDirUri;
      if (_safSessionDirName == session && cachedDir != null) {
        dirUri = cachedDir;
      } else {
        final dir = await _safUtil.mkdirp(root, pathParts);
        dirUri = dir.uri;
        _safSessionDirName = session;
        _safSessionDirUri = dirUri;
      }
      await _safStream.writeFileBytes(dirUri, '$fileName.$ext', mime, bytes);
      gallerySafRevision++; // 갤러리 자동 갱신 신호 (호출자의 notifyListeners로 전파됨)
      final displayPath = _appFolderPath([session, '$fileName.$ext']).join('/');
      return '${safRootName ?? 'SAF'}/$displayPath';
    } catch (e) {
      debugPrint('SAF 저장 실패: $e');
      return null;
    }
  }

  // SAF 갤러리에서 마지막으로 보던 위치 (탭/모드 전환 후 복원용)
  // 갤러리(SAF/IO)가 등록하는 뒤로가기 핸들러. 처리했으면 true 반환.
  // main의 PopScope가 히스토리 탭일 때 호출 → 상위폴더 이동/선택해제 처리.
  bool Function()? galleryBackHandler;

  // i2i 탭이 등록하는 뒤로가기 핸들러. 릴(핸들)이 열려있으면 닫고 true 반환.
  bool Function()? i2iBackHandler;

  // SAF에 이미지가 저장될 때마다 증가. 갤러리가 이 값 변화를 감지해 자동 갱신한다.
  int gallerySafRevision = 0;

  // 마지막으로 이미지를 저장한 세션 폴더 URI (갤러리 자동 갱신 시 대상 판별용).
  String? get lastSavedSafDirUri => _safSessionDirUri;

  String? safBrowseDirUri;
  String? safBrowseDirName;
  List<String> safBrowseStackUris = [];
  List<String> safBrowseStackNames = [];

  void saveSafBrowseLocation(
    String? dirUri,
    String? dirName,
    List<String> stackUris,
    List<String> stackNames,
  ) {
    safBrowseDirUri = dirUri;
    safBrowseDirName = dirName;
    safBrowseStackUris = List.from(stackUris);
    safBrowseStackNames = List.from(stackNames);
  }

  void clearSafBrowseLocation() {
    safBrowseDirUri = null;
    safBrowseDirName = null;
    safBrowseStackUris = [];
    safBrowseStackNames = [];
  }

  // 현재 폴더의 '이미지 목록만' 빠르게 읽는다 (SAF 조회 1회).
  //  자동 새로고침처럼 하위 폴더가 바뀔 일이 없을 때 쓰면
  //  폴더 수와 무관하게 항상 1회 조회로 끝난다.
  Future<List<({String uri, String name})>> listSafImagesOnly(String dirUri) async {
    final images = <({String uri, String name})>[];
    if (!Platform.isAndroid) {
      return images;
    }
    try {
      final items = await _safUtil.list(dirUri);
      for (final f in items) {
        if (!f.isDir && isImageFileName(f.name)) {
          images.add((uri: f.uri, name: f.name));
        }
      }
      images.sort((a, b) => b.name.compareTo(a.name));
    } catch (e) {
      debugPrint('listSafImagesOnly 실패 ($dirUri): $e');
    }
    return images;
  }

  // SAF 디렉토리 1단계 목록 (하위폴더[개수+미리보기refs 포함] + 이미지). 빈 폴더는 제외.
  // 개수를 세는 김에 미리보기 후보(최신 4장)도 같이 뽑아 폴더당 조회를 1회로 줄인다.
  Future<
    ({
      List<({String uri, String name, int imageCount, List<({String uri, String name})> previews})>
      folders,
      List<({String uri, String name})> images,
    })
  >
  listSafDirDetailed(String dirUri) async {
    final folders =
        <({String uri, String name, int imageCount, List<({String uri, String name})> previews})>[];
    final images = <({String uri, String name})>[];
    if (!Platform.isAndroid) {
      return (folders: folders, images: images);
    }
    try {
      final items = await _safUtil.list(dirUri);
      final subDirs = <({String uri, String name})>[];
      for (final f in items) {
        if (f.isDir) {
          subDirs.add((uri: f.uri, name: f.name));
        } else if (isImageFileName(f.name)) {
          images.add((uri: f.uri, name: f.name));
        }
      }
      // 각 하위폴더 1회 조회 → 직접 이미지 수 + 하위폴더 유무 + 미리보기 refs (빈 폴더 제외)
      // ⚡ 순차로 돌면 폴더 20개일 때 20번을 기다려야 한다(체감 1초 이상).
      //    SAF 조회는 I/O 대기라 병렬로 던지면 거의 1회분 시간에 끝난다.
      //  실패한 폴더는 건너뛰되 나머지 결과는 살린다.
      //  (list()의 원소 타입을 그대로 쓰기 위해 catch에서 null을 돌려준다)
      final inners = await Future.wait(
        subDirs.map((d) async {
          try {
            return await _safUtil.list(d.uri);
          } catch (_) {
            return null;
          }
        }),
      );
      for (int i = 0; i < subDirs.length; i++) {
        final d = subDirs[i];
        int imgCount = 0;
        bool hasSub = false;
        final innerImgs = <({String uri, String name})>[];
        final inner = inners[i];
        if (inner == null) {
          continue; // 조회 실패한 폴더는 건너뛴다
        }
        for (final f in inner) {
          if (f.isDir) {
            hasSub = true;
          } else if (isImageFileName(f.name)) {
            imgCount++;
            innerImgs.add((uri: f.uri, name: f.name));
          }
        }
        if (imgCount > 0 || hasSub) {
          innerImgs.sort((a, b) => b.name.compareTo(a.name)); // 최신순
          folders.add((
            uri: d.uri,
            name: d.name,
            imageCount: imgCount,
            previews: innerImgs.take(4).toList(),
          ));
        }
      }
      folders.sort((a, b) => b.name.compareTo(a.name));
      images.sort((a, b) => b.name.compareTo(a.name));
    } catch (e) {
      debugPrint('listSafDirDetailed 실패 ($dirUri): $e');
    }
    return (folders: folders, images: images);
  }

  // 폴더의 대표 미리보기 이미지 최대 N장 (없으면 하위폴더로 얕게 탐색)
  Future<List<({String uri, String name})>> firstSafImagesIn(
    String dirUri, {
    int max = 4,
    int depth = 0,
  }) async {
    final out = <({String uri, String name})>[];
    if (!Platform.isAndroid || depth > 2) {
      return out;
    }
    try {
      final items = await _safUtil.list(dirUri);
      final imgs = items.where((f) => !f.isDir && isImageFileName(f.name)).toList()
        ..sort((a, b) => b.name.compareTo(a.name));
      for (final im in imgs) {
        out.add((uri: im.uri, name: im.name));
        if (out.length >= max) {
          return out;
        }
      }
      if (out.length < max) {
        final dirs = items.where((f) => f.isDir).toList()..sort((a, b) => b.name.compareTo(a.name));
        for (final d in dirs) {
          final sub = await firstSafImagesIn(d.uri, max: max - out.length, depth: depth + 1);
          out.addAll(sub);
          if (out.length >= max) {
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('firstSafImagesIn 실패 ($dirUri): $e');
    }
    return out;
  }

  // SAF 이미지 1장 삭제
  Future<bool> deleteSafImage(String fileUri) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      await _safUtil.delete(fileUri, false); // isDir=false
      return true;
    } catch (e) {
      debugPrint('deleteSafImage 실패: $e');
      return false;
    }
  }

  // SAF 파일을 다른 폴더로 이동. 권한받은 루트 트리 내부 폴더 간에만 동작.
  //   fileUri: 이동할 파일 URI
  //   fromParentUri: 현재 파일이 든 부모 폴더 URI
  //   toParentUri: 이동 대상 폴더 URI
  // 반환: 성공 시 이동된 파일의 새 URI, 실패 시 null.
  Future<String?> moveSafImage(String fileUri, String fromParentUri, String toParentUri) async {
    if (!Platform.isAndroid) {
      return null;
    }
    // 같은 폴더로의 이동은 무의미 → 그대로 성공 처리(새 uri 없음)
    if (fromParentUri == toParentUri) {
      return fileUri;
    }
    try {
      final moved = await _safUtil.moveTo(
        fileUri,
        false, // isDir=false
        fromParentUri,
        toParentUri,
      );
      return moved.uri;
    } catch (e) {
      debugPrint('moveSafImage 실패: $e');
      return null;
    }
  }

  // SAF 폴더의 하위 폴더 목록만 조회 (이동 대상 선택용).
  // 반환: (uri, name) 리스트. 실패 시 빈 리스트.
  Future<List<({String uri, String name})>> listSafSubFolders(String dirUri) async {
    if (!Platform.isAndroid) {
      return [];
    }
    try {
      final items = await _safUtil.list(dirUri);
      final folders = <({String uri, String name})>[];
      for (final f in items) {
        if (f.isDir) {
          folders.add((uri: f.uri, name: f.name));
        }
      }
      folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return folders;
    } catch (e) {
      debugPrint('listSafSubFolders 실패: $e');
      return [];
    }
  }

  // 앱 전용 폴더(getGalleryBasePath/DNaiApp)의 기존 이미지를 SAF 폴더로 이전.
  // deleteOriginals=true면 복사 성공한 원본을 삭제. 반환: (복사, 실패, 삭제) 수.
  Future<({int copied, int failed, int deleted})> migrateAppFolderToSaf({
    bool deleteOriginals = false,
  }) async {
    int copied = 0;
    int failed = 0;
    int deleted = 0;
    final root = safRootUri;
    if (root == null || !Platform.isAndroid) {
      return (copied: 0, failed: 0, deleted: 0);
    }

    Future<String?> ensureDir(List<String> names) async {
      try {
        if (names.isEmpty) {
          return root; // 루트 자체
        }
        final d = await _safUtil.mkdirp(root, names);
        return d.uri;
      } catch (e) {
        debugPrint('migrate mkdirp 실패 ($names): $e');
        return null;
      }
    }

    Future<void> copyFile(File f, String dirUri) async {
      try {
        final name = f.path.split('/').last;
        // ⚠️ 예전엔 jpg 가 아니면 모두 image/png 로 넘겨, WebP 파일이 '그림.webp.png' 가 됐다
        final mime = mimeForExt(extOf(name));
        final bytes = await f.readAsBytes();
        await _safStream.writeFileBytes(dirUri, name, mime, bytes);
        copied++;
        if (deleteOriginals) {
          try {
            await f.delete();
            deleted++;
          } catch (_) {
            // 원본 삭제 실패는 넘어간다. 복사는 이미 끝났으므로 이전 자체는 성공이고,
            // 여기서 멈추면 남은 파일들까지 못 옮긴다. 실패분은 앱 폴더에 그대로 남는다.
          }
        }
      } catch (e) {
        failed++;
        debugPrint('migrate 복사 실패 (${f.path}): $e');
      }
    }

    try {
      final basePath = await getGalleryBasePath(); // .../DNaiApp
      final baseDir = Directory(basePath);
      if (!await baseDir.exists()) {
        return (copied: 0, failed: 0, deleted: 0);
      }
      final entries = baseDir.listSync();
      for (final entity in entries) {
        if (entity is Directory) {
          // 세션 폴더 → DNaiApp/세션 (루트가 DNaiApp이면 세션만)
          final session = entity.path.split('/').last;
          final dirUri = await ensureDir(_appFolderPath([session]));
          if (dirUri == null) {
            continue;
          }
          for (final f in entity.listSync()) {
            if (f is File && isImageFileName(f.path.split('/').last)) {
              await copyFile(f, dirUri);
            }
          }
        } else if (entity is File && isImageFileName(entity.path.split('/').last)) {
          // 세션 없이 베이스 바로 아래 있는 이미지 → DNaiApp 루트
          final dirUri = await ensureDir(_appFolderPath([]));
          if (dirUri != null) {
            await copyFile(entity, dirUri);
          }
        }
      }
    } catch (e) {
      debugPrint('앱 폴더→SAF 이전 에러: $e');
    }
    return (copied: copied, failed: failed, deleted: deleted);
  }

  // SAF 파일 바이트 읽기
  Future<Uint8List?> readSafImage(String fileUri) async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final bytes = await _safStream.readFileBytes(fileUri);
      return Uint8List.fromList(bytes);
    } catch (e) {
      debugPrint('readSafImage 실패: $e');
      return null;
    }
  }

  // ===== SAF 썸네일 캐시 =====
  // 갤러리 그리드/폴더 미리보기는 원본 대신 작은 썸네일(jpeg)을 사용해
  // 로딩 속도와 메모리를 크게 줄인다. 앱 캐시 폴더에 파일로 저장돼 재실행에도 유지.
  Directory? _safThumbDirCache;

  Future<Directory> _safThumbDir() async {
    final cached = _safThumbDirCache;
    if (cached != null) {
      return cached;
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/saf_thumbs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _safThumbDirCache = dir;
    return dir;
  }

  // URI → 캐시 파일명 키. content URI는 파일명으로 못 쓰니 32비트 FNV-1a를
  // 정방향+역방향 두 번 돌려 64비트 상당으로 충돌 확률을 낮춘다 (결정적).
  String _thumbKeyFor(String uri) {
    int fnv(Iterable<int> units) {
      int h = 0x811c9dc5;
      for (final c in units) {
        h ^= c;
        h = (h * 0x01000193) & 0xFFFFFFFF;
      }
      return h;
    }

    final f = fnv(uri.codeUnits).toRadixString(16);
    final b = fnv(uri.codeUnits.reversed).toRadixString(16);
    return '${f}_$b';
  }

  // 폴백용: 원본 바이트 → 320px JPG (백그라운드 isolate에서 실행해 UI 버벅임 방지)
  static Uint8List? _makeSafThumbIsolate(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return null;
      }
      final resized = decoded.width <= 320 ? decoded : img.copyResize(decoded, width: 320);
      return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    } catch (_) {
      return null;
    }
  }

  // SAF 이미지의 썸네일 바이트 (디스크 캐시 → 네이티브 생성 → 직접 축소 → 실패 시 원본 폴백)
  Future<Uint8List?> readSafThumb(String fileUri) async {
    if (!Platform.isAndroid) {
      return null;
    }
    File? thumbFile;
    try {
      final dir = await _safThumbDir();
      thumbFile = File('${dir.path}/${_thumbKeyFor(fileUri)}.jpg');
      final f = thumbFile;
      if (await f.exists()) {
        return await f.readAsBytes();
      }
      final ok = await _safUtil.saveThumbnailToFile(
        uri: fileUri,
        width: 320,
        height: 320,
        destPath: f.path,
      );
      if (ok && await f.exists()) {
        return await f.readAsBytes();
      }
    } catch (e) {
      debugPrint('readSafThumb 실패: $e');
    }
    // 썸네일 미지원/실패 → 원본을 읽어 직접 축소 (원본 통째 반환은 메모리 낭비라 최후 수단)
    final bytes = await readSafImage(fileUri);
    if (bytes == null) {
      return null;
    }
    try {
      // 네이티브 WebP 가 먼저 (순수 Dart 로 PNG 를 푸는 것보다 훨씬 빠르다), 안 되면 옛 방식
      final thumb = await makeGalleryThumb(bytes) ?? await compute(_makeSafThumbIsolate, bytes);
      if (thumb != null) {
        final f = thumbFile;
        if (f != null) {
          await f.writeAsBytes(thumb); // 다음부턴 디스크 캐시로 즉시
        }
        return thumb;
      }
    } catch (e) {
      debugPrint('썸네일 폴백 축소 실패: $e');
    }
    return bytes; // 축소까지 실패하면 원본이라도 표시
  }

  // 앱 시작 시 저장된 SAF 루트 복원 — 권한이 아직 유효할 때만
  Future<void> _loadSafRoot() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final uri = prefs.getString('safRootUri');
      if (uri == null || uri.isEmpty) {
        return;
      }
      final ok = await _safUtil.hasPersistedPermission(uri);
      if (ok) {
        safRootUri = uri;
        safRootName = prefs.getString('safRootName');
      } else {
        // 권한이 풀림(재부팅/회수/에뮬 초기화) → 캐시 정리
        await prefs.remove('safRootUri');
        await prefs.remove('safRootName');
      }
    } catch (e) {
      debugPrint('SAF 루트 로드 실패: $e');
    }
  }

  // 갤러리 모드 ON/OFF. SAF/앱 전용 폴더로 동작하므로 별도 권한 요청 없음.
  // 반환: 최종 galleryModeEnabled 값
  Future<bool> setGalleryModeEnabled(bool enabled) async {
    galleryModeEnabled = enabled;
    await saveAllSettings();
    notifyListeners();
    return enabled;
  }

  // 갤러리에서 선택 가능한 "위치 목록" (권한 불필요한 경로들).
  // 반환: [(라벨, 경로)] — 앱 외부 저장소 DNaiApp (+ SAF는 별도 처리)
  Future<List<(String, String)>> getGalleryLocations() async {
    final locations = <(String, String)>[];

    // 1. 앱 외부 저장소/DNaiApp (기본)
    final appDir = await getExternalStorageDirectory();
    if (appDir != null) {
      final dir = Directory('${appDir.path}/DNaiApp');
      if (await dir.exists()) {
        locations.add(("앱 저장 폴더", dir.path));
      }
    }

    // 문서 디렉토리 (폴백)
    if (locations.isEmpty) {
      final docDir = await getApplicationDocumentsDirectory();
      locations.add(("기본 폴더", docDir.path));
    }

    return locations;
  }

  // 갤러리 기본 경로 (앱 외부 저장소의 DNaiApp 폴더).
  Future<String> getGalleryBasePath() async {
    final appDir = await getExternalStorageDirectory();
    if (appDir != null) {
      final dir = Directory('${appDir.path}/DNaiApp');
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {
          // 폴더를 못 만들어도 아래에서 경로는 그대로 돌려준다.
          // 실제로 쓸 때 다시 실패하며, 그때 사용자에게 알린다.
        }
      }
      return dir.path;
    }
    final docDir = await getApplicationDocumentsDirectory();
    return docDir.path;
  }

  // ── 모델별 상세환경 기억 ──
  //  모델마다 잘 맞는 설정값이 다르다(예: V4.5는 28스텝, V5는 25스텝).
  //  모델을 바꿀 때 지금 값을 그 모델 앞으로 저장해두고,
  //  새 모델에서 마지막으로 쓰던 값을 되살린다.
  //  기록이 없으면 현재 값을 유지한다(첫 전환에서 값이 튀지 않게).
  Map<String, Map<String, String>> modelSettingProfiles = {};

  Map<String, String> _currentDetailSnapshot() => {
    'steps': stepsController.text,
    'cfg': cfgScaleController.text,
    'rescale': cfgRescaleController.text,
    'sampler': selectedSampler,
    'scheduler': selectedScheduler,
    'resolution': selectedResolution,
    'resolutionMode': resolutionMode,
  };

  void _applyDetailSnapshot(Map<String, String> p) {
    stepsController.text = p['steps'] ?? stepsController.text;
    cfgScaleController.text = p['cfg'] ?? cfgScaleController.text;
    cfgRescaleController.text = p['rescale'] ?? cfgRescaleController.text;
    selectedSampler = p['sampler'] ?? selectedSampler;
    selectedScheduler = p['scheduler'] ?? selectedScheduler;
    selectedResolution = p['resolution'] ?? selectedResolution;
    resolutionMode = p['resolutionMode'] ?? resolutionMode;
  }

  // 모델별 권장 기본값 (그 모델을 처음 쓸 때만 적용된다).
  //  공식 UI 기본값 기준 — V5는 스텝 23 / Guidance 7 / karras.
  static const Map<String, Map<String, String>> _modelDefaults = {
    NaiModels.v5Full: {
      'steps': '23',
      'cfg': '7.0',
      'rescale': '0.00',
      'sampler': 'k_euler_ancestral',
      'scheduler': 'karras',
    },
  };

  /// 모델 교체 — 현재 설정을 이전 모델 앞으로 저장하고, 새 모델의 기록을 불러온다.
  void switchModel(String newModel) {
    if (newModel == selectedModel) {
      return;
    }
    modelSettingProfiles[selectedModel] = _currentDetailSnapshot();
    selectedModel = newModel;
    final saved = modelSettingProfiles[newModel];
    if (saved != null) {
      // 그 모델에서 마지막으로 쓰던 값 복원
      _applyDetailSnapshot(saved);
    } else {
      // 처음 쓰는 모델이면 권장 기본값을 적용한다
      final defaults = _modelDefaults[newModel];
      if (defaults != null) {
        _applyDetailSnapshot(defaults);
      }
    }
    // 스케줄러를 못 고르는 모델(V5)은 karras로 맞춘다
    final caps = modelCapsFor(newModel);
    if (!caps.allowsSchedulerChoice) {
      selectedScheduler = 'karras';
    }
    // ⚠️ 모델마다 캐릭터 상한이 다르다 (V5=32, V4.5=6).
    //    많은 쪽에서 적은 쪽으로 바꾸면 초과분이 그대로 전송돼 오류가 난다.
    //    지우지는 않고 '비활성'으로 돌려 데이터는 보존한다.
    //    (다시 V5로 오면 켜서 쓸 수 있다)
    if (characters.length > caps.maxCharacters) {
      for (int i = caps.maxCharacters; i < characters.length; i++) {
        characters[i].isActive = false;
      }
    }
    // 선택 인덱스가 범위를 벗어나면 되돌린다
    if (selectedCharIndex >= characters.length) {
      selectedCharIndex = characters.isEmpty ? 0 : characters.length - 1;
    }
    saveAllSettings();
    notifyListeners();
  }

  String selectedModel = NaiModels.v45Full;
  String selectedSampler = "k_euler_ancestral";
  String selectedScheduler = "karras";
  String selectedResolution = "832 x 1216";
  double resolutionScale = 1.0; // 1.0, 1.5, 2.0

  // 픽셀/개수 한계 상수 (매직넘버 방지)
  //  - kMegapixelCap: 1024×1024. 자동 모드 상한이자 Opus 무료 생성 기준
  //  - kNaiPixelHardCap: NAI가 허용하는 절대 픽셀 상한
  //    ⚠️ 실제 생성 시 상한은 ModelCaps.maxPixels가 단일 출처다.
  //       이 상수는 모델과 무관한 기본값(=V4.5 기준)으로만 남겨 둔다.
  static const int kMegapixelCap = 1048576;
  static const int kNaiPixelHardCap = 3145728;
  static const int kHistoryCap = 100; // 히스토리 최대 보관 장수
  List<String> customResolutions = []; // 사용자 추가 해상도

  List<NaiCharacter> characters = [NaiCharacter()];

  /// 캐릭터 목록이 '외부에서' 통째로 바뀔 때마다 1씩 오른다.
  ///  (이미지에서 프롬프트 불러오기, 프리셋 적용, 삭제·순서 변경 등)
  ///
  ///  화면이 캐릭터별로 캐시해 둔 입력 컨트롤러는 이 값이 달라졌을 때
  ///  '편집 중이라도' 내용을 다시 맞춰야 한다. 그러지 않으면 옛 텍스트를 든
  ///  컨트롤러가 나중에 모델을 되돌려 버린다.
  int charactersRevision = 0;

  /// 캐릭터 목록을 외부에서 바꾼 뒤 호출한다.
  /// 지금 고른 캐릭터. 목록이 비었으면 null.
  ///
  /// ⚠️ selectedCharIndex 를 그대로 믿고 characters[...] 를 읽으면 안 된다.
  ///    프롬프트 불러오기로 캐릭터가 3개에서 1개로 줄어도 선택 번호는 2로
  ///    남아 있을 수 있고, 그 상태로 읽으면 범위를 벗어난다.
  ///    읽기 전에 이 getter 로 한 번 거르면 어느 화면에서든 안전하다.
  NaiCharacter? get selectedCharacter {
    if (characters.isEmpty) {
      return null;
    }
    if (selectedCharIndex < 0 || selectedCharIndex >= characters.length) {
      // 범위를 벗어나 있었다면 여기서 바로잡아 둔다 (다음 접근부터는 정상)
      selectedCharIndex = characters.length - 1;
    }
    return characters[selectedCharIndex];
  }

  void markCharactersReplaced() {
    charactersRevision++;
    // 목록이 바뀌면 선택 번호부터 바로잡는다.
    //  (여기서 한 번 맞춰 두면 화면들이 각자 검사하지 않아도 된다)
    if (selectedCharIndex >= characters.length) {
      selectedCharIndex = characters.isEmpty ? 0 : characters.length - 1;
    }
    _pruneCharacterUndo();
    notifyListeners();
  }

  /// 지금 없는 캐릭터의 되돌리기 기록을 버린다.
  ///
  /// 캐릭터를 지우거나 프롬프트 불러오기로 통째로 교체하면 옛 기록이 남는다.
  /// 그대로 두면 설정 파일만 계속 불어나고, 우연히 같은 uid 가 생기면
  /// 엉뚱한 내용으로 되돌아갈 수도 있다.
  ///  ⚠️ 목록을 바꾸는 곳마다 따로 지우게 하면 빠뜨리기 쉬우므로,
  ///     '캐릭터가 바뀌었다'는 신호 한 곳에서만 처리한다.
  void _pruneCharacterUndo() {
    if (promptUndoHistory.isEmpty) {
      return;
    }
    final alive = characters.map((c) => c.uid).toSet();
    // 캐릭터 기록의 열쇠는 'char/<uid>/긍정' 형태다
    final dead = promptUndoHistory.keys
        .where((k) => k.startsWith('char/') && !alive.contains(k.split('/')[1]))
        .toList();
    if (dead.isEmpty) {
      return;
    }
    for (final k in dead) {
      promptUndoHistory.remove(k);
    }
    // ⚠️ 여기서 saveAllSettings 를 부르지 않는다.
    //    이 함수를 부르는 쪽(삭제·교체·프리셋 적용)이 모두 곧바로 저장하므로,
    //    여기서 또 부르면 설정 116개를 잇달아 두 번 쓰게 된다.
    //    그 연쇄가 겹치면 화면이 멈춘 것처럼 보인다.
  }

  int selectedCharIndex = 0;
  bool useCharacterPosition = true; // 캐릭터 배치 적용 ON/OFF (그리드 좌표 반영)

  // V5 캐릭터 캔버스 옵션
  bool charCanvasShowGrid = false; // 정렬용 격자선
  bool charCanvasSnap = false; // 0.05 단위로 맞추기

  // Position 캔버스 배경으로 그림을 깔지 여부.
  //  공식처럼 실제 그림을 보면서 캐릭터 위치를 잡을 수 있다.
  //  i2i 작업 이미지가 있으면 그것을, 없으면 최근 생성 결과를 쓴다.
  bool charCanvasShowImage = false;

  // 격자 칸 수 (2~12). 2면 가운데 1줄이 생긴다.
  int charGridCols = 5;
  int charGridRows = 5;

  /// 사용자가 직접 고른 배경 이미지.
  ///  null이면 자동(i2i 작업 이미지 → 없으면 최근 생성물)으로 고른다.
  ///  ⚠️ 메모리에만 두고 저장하지 않는다 (용량이 크고, 켤 때마다 다시 고르면 된다).
  Uint8List? charCanvasPickedImage;

  /// 캔버스 배경으로 쓸 이미지 (없으면 null)
  Uint8List? get charCanvasBackground {
    if (!charCanvasShowImage) {
      return null;
    }
    // 직접 고른 게 있으면 그걸 우선
    if (charCanvasPickedImage != null) {
      return charCanvasPickedImage;
    }
    // 자동 — 히스토리의 가장 최신 결과
    if (historyImages.isNotEmpty) {
      return historyImages.last;
    }
    // 히스토리가 비었으면 i2i 작업 이미지라도
    if (targetI2iImage != null) {
      return targetI2iImage;
    }
    return null;
  }

  /// 배경 이미지를 직접 고른다 (null이면 자동으로 되돌림)
  void setCharCanvasImage(Uint8List? bytes) {
    charCanvasPickedImage = bytes;
    if (bytes != null) {
      charCanvasShowImage = true; // 고르면 자동으로 켠다
    }
    saveAllSettings();
    notifyListeners();
  }

  // 투명 배경 (V5 전용).
  //  켜면 요청에 straight_alpha를 실어 알파 채널이 살아있는 이미지를 받는다.
  //  ⚠️ JPEG는 알파를 담지 못하므로 PNG나 WebP로 저장해야 의미가 있다.
  bool transparentBackground = false;

  // ── 공식 프리셋 (NovelAI 웹과 동일한 자동 태그) ──
  //  Quality Tags: 긍정 프롬프트 '뒤'에 붙는 품질 태그
  //  UC Preset:    부정 프롬프트에 붙는 기본 제외 태그
  //  값은 프리셋 '이름'을 저장한다 (모델이 바뀌어도 같은 이름이면 이어진다).
  String qualityTagsPreset = 'None';
  String ucPreset = 'None';
  bool randomCharacterOrder = false; // 캐릭터 순서 랜덤 (배치 적용과 상호 배타)

  // 배치 적용 ↔ 랜덤 배치는 동시에 켤 수 없다 (둘 다 끄는 건 가능)
  void setUseCharacterPosition(bool v) {
    useCharacterPosition = v;
    if (v) {
      randomCharacterOrder = false;
    }
    saveAllSettings();
    notifyListeners();
  }

  void setRandomCharacterOrder(bool v) {
    randomCharacterOrder = v;
    if (v) {
      useCharacterPosition = false;
    }
    saveAllSettings();
    notifyListeners();
  }

  // Vibe Transfer
  List<Map<String, dynamic>> vibeTransfers =
      []; // [{image: base64, strength: 0.6, infoExtracted: 1.0}]

  // Precise Reference (V4.5 전용)
  List<Map<String, dynamic>> preciseRefs =
      []; // [{image: base64, type: 'character', strength: 1.0, fidelity: 0.5}]
  List<NaiWildcard> wildcards = [
    NaiWildcard(name: "의상", content: "school uniform\nmaid outfit\nbikini"),
  ];
  int selectedWildcardIndex = 0;

  List<NaiPreset> presets = [];

  List<String> gelbooruPrompts = [];
  int currentPromptIndex = 0;
  int gelbooruTotal = 0;
  int gelbooruRemaining = 0;
  bool isGelbooruExpanded = false;
  bool isGelbooruLoading = false;
  // 검색 진행 상황 (실시간 표시용)
  int gelbooruSearchDone = 0;
  int gelbooruSearchTotal = 0;
  // 검색 후 단계 메시지 (분류/필터/캐시 — 페이지 수신 완료 후 표시)
  String gelbooruSearchStage = "";

  final NovelAiService _service = NovelAiService();
  Uint8List? currentImageBytes;
  String? lastErrorMessage;

  bool isLoading = false;
  bool isUpscaleLoading = false;
  bool isInpaintLoading = false;
  String inpaintStatusMessage = ""; // 인페인트 진행 상태 실시간 표시용

  int currentAnlas = 0;

  // ── V5 사용 한도 ──
  //  V5는 시간당 회복되는 사용 한도가 있다.
  //  아직 조회 API가 공개되지 않아 값을 가져올 수 없으므로, 지금은 표시 자리만 잡아둔다.
  //  API가 확인되면 fetchV5Limit()에서 v5LimitPercent를 채우면 UI는 그대로 동작한다.
  //  · null  = 아직 모름 (UI에 "확인중" 표시)
  //  · 0~100 = 남은 비율(%)
  double? v5LimitPercent;
  DateTime? v5LimitCheckedAt;

  /// 한도를 다 써서 Anlas를 소모하는 중인지
  bool v5LimitNegative = false;

  /// 다음 1% 회복까지 남은 초
  int v5LimitNextSec = 0;

  /// V5 사용 한도 조회.
  ///  값은 /user/subscription 응답의 usage 필드에 함께 오므로
  ///  fetchAnlas()가 이미 채운다. 따로 부를 일이 있으면 이 함수를 쓴다.
  Future<void> fetchV5Limit() => fetchAnlas();
  int subscriptionTier = 0;

  List<Uint8List> historyImages = [];
  List<NaiMetadata?> historyMetadata = [];
  List<bool> historyFavorites = [];
  List<String?> historyFilePaths = []; // 자동저장된 파일 경로 추적
  bool historyNeedsFullSave = false; // 인덱스 변경 시 전체 저장 필요 표시
  int selectedHistoryIndex = -1;

  // i2i 스크래치 릴 (인페인트 등 반복 결과 임시 보관, 즐겨찾기만 영속)
  List<I2iResult> i2iResults = [];
  static const int i2iResultsCap = 30; // 릴 전체 보관 상한 (즐겨찾기 포함)
  static const int i2iFavoriteCap = 5; // 즐겨찾기 최대 개수
  double i2iHandleBottom = -1; // i2i 릴 핸들 세로 위치 (-1이면 기본값 사용)
  double promptCharHandleTop = -1; // 프롬프트 탭 캐릭터 편집 손잡이 세로 위치 (-1이면 기본값)
  bool i2iHistoryDisabled = false; // ON이면 릴 끄고 i2i 결과를 메인 히스토리에 저장
  // i2i 히스토리 핸들이 켜져 있을 때의 인페인트 세부 옵션
  // 작업 결과를 곧바로 '작업 이미지'로 바꾸지 않음 (기본 OFF = 바꿈).
  //  이름은 인페인트에서 시작했지만 모자이크·Director 결과에도 함께 적용된다.
  //  설정 키를 바꾸면 기존 사용자 설정이 초기화되므로 이름은 그대로 둔다.
  bool inpaintNoAutoSwitch = false;
  bool inpaintAutoClearMask = false;

  /// i2i 탭에 Director Tool 전환 버튼을 보여 줄지. 기본 ON.
  ///  꺼도 이미 만들어 둔 결과나 설정은 그대로 남는다 — 버튼만 감춘다.
  bool directorToolVisible = true;
  bool galleryModeEnabled = true; // 갤러리 모드(공용 폴더 탐색) 사용 여부 — 기본 ON

  // SAF (Storage Access Framework) — 사용자가 고른 저장 폴더의 트리 URI
  final SafUtil _safUtil = SafUtil();
  final SafStream _safStream = SafStream();
  String? safRootUri; // 선택된 SAF 트리 URI (null = 미선택)
  String? safRootName; // 표시용 폴더명
  String? _safSessionDirUri; // 현재 세션의 SAF 디렉토리 URI 캐시
  String? _safSessionDirName; // 캐시된 세션 이름

  List<NaiMetadata?> i2iHistoryMetadata = [];
  int selectedI2iHistoryIndex = -1;

  Uint8List? targetI2iImage;
  NaiMetadata? targetI2iMetadata;

  List<String> danbooruTags = [];
  // e621 확장: Danbooru에 없는 태그만 (토글 ON 시 검색에 합류)
  List<String> e621Tags = [];
  Set<String> e621TagSet = {}; // 색상 구분용 (e621 전용 태그 빠른 판별)
  List<String> _combinedTags = []; // Danbooru+e621 count순 미리 정렬 (검색용)
  bool e621Enabled = false; // e621 프롬프트 확장 토글

  // ── 영속되는 UI 상태 (펼침/접힘 등) ── 앞으로 이런 상태는 여기에 모아 기억 + 백업 포함
  bool safCardOpen = true; // 설정탭 '저장 폴더(SAF)' 카드 펼침 여부
  bool fileCardOpen = true; // 설정탭 '파일 이름' 카드 펼침 여부

  // 앱 테마 액센트 색 (ARGB int, 기본: deepPurpleAccent). AppColors.accent에 반영됨.
  int themeAccent = 0xFF7C4DFF;

  // 자동완성 검색용 태그 리스트 (e621 토글에 따라 합류)
  List<String> get searchTags {
    if (!e621Enabled || _combinedTags.isEmpty) {
      return danbooruTags;
    }
    return _combinedTags;
  }

  // 해당 태그가 e621 전용 태그인지 (색상 구분용). contains 마커 '* ' 제거 후 판별.
  bool isE621Tag(String rawTag) {
    if (!e621Enabled) {
      return false;
    }
    final clean = rawTag.replaceFirst(RegExp(r'^\* '), '');
    return e621TagSet.contains(clean);
  }

  double historyThumbnailScrollOffset = 0.0;
  bool scrollToThumbnailEnd = false;

  // 히스토리 목록을 맨 아래로 내려달라는 요청 신호.
  //  ⚠️ 예전에는 main이 ScrollController를 만들어 HistoryTab에 넘겼는데,
  //     KeepAlive를 켜면 탭 전환 중 두 인스턴스가 같은 컨트롤러를 붙잡아
  //     'attached to multiple scroll views' 오류로 앱이 멈췄다.
  //     컨트롤러는 HistoryTab이 직접 갖고, 요청만 이 값으로 전달한다.
  int historyScrollToEndRevision = 0;

  /// 와일드카드 탭 안에서 마지막으로 본 쪽 (0 와일드카드 / 1 프롬프트 사전).
  ///  와일드카드 탭은 떠날 때마다 새로 만들어지므로 여기에 기억해 둔다.
  ///  ※ 화면 상태일 뿐 '설정'이 아니라서 백업·복원(5곳 패턴)에는 넣지 않는다.
  ///    앱을 다시 켜도 이어지도록 저장만 따로 한다.
  int wildcardSubTab = 0;

  void setWildcardSubTab(int index) {
    if (wildcardSubTab == index) {
      return;
    }
    wildcardSubTab = index;
    // 화면을 다시 그릴 필요가 없어 notifyListeners 는 부르지 않는다
    SharedPreferences.getInstance().then((p) => p.setInt('wildcardSubTab', index));
  }

  /// 히스토리 탭을 '떠날 때마다' 1씩 오른다.
  ///  히스토리 탭은 이 값이 바뀐 것을 보고 갤러리 모드를 닫아 둔다.
  ///  (갤러리는 가끔 들여다보는 곳이라, 다시 들어오면 목록부터 보이는 게 자연스럽다)
  ///
  ///  ⚠️ '들어올 때' 닫으면 탭이 보이고 나서 0.5초 뒤에 화면이 휙 바뀐다.
  ///     떠날 때 닫아 두면 화면 밖에서 조용히 바뀌어 있어 다시 들어와도 티가 안 난다.
  int historyGalleryResetRevision = 0;

  void resetHistoryGalleryInBackground() {
    historyGalleryResetRevision++;
    notifyListeners();
  }

  void requestHistoryScrollToEnd() {
    historyScrollToEndRevision++;
    notifyListeners();
  }

  bool isHistoryGridView = false;

  int? requestedTabIndex;

  /// 설정 탭 안에서 펼쳐 보여 줄 하위 탭 (0 일반 / 1 저장 / 2 API / 3 기타).
  ///  설정 화면이 이 값을 보고 그 탭으로 옮긴 뒤 스스로 비운다.
  int? requestedSettingsSubTab;

  /// 설정 탭의 [subTab] 을 펼친 채로 설정 화면을 연다.
  void navigateToSettings(int subTab) {
    requestedSettingsSubTab = subTab;
    navigateToTab(5); // 설정 탭
  }

  void consumeSettingsSubTabRequest() {
    requestedSettingsSubTab = null;
  }

  void navigateToTab(int index) {
    requestedTabIndex = index;
    notifyListeners();
  }

  void clearNavigation() {
    requestedTabIndex = null;
  }

  void parseGelbooruApi() {
    String input = gelbooruApiController.text;
    final userIdMatch = RegExp(r'user_id=([^&\s]+)').firstMatch(input);
    final apiKeyMatch = RegExp(r'api_key=([^&\s]+)').firstMatch(input);
    gelbooruUserId = userIdMatch?.group(1) ?? "";
    gelbooruApiKey = apiKeyMatch?.group(1) ?? "";
  }

  // 앱 초기 로딩 완료 여부 (false 동안 로딩 화면으로 조작 차단 → 프리징/크래시 방지)
  bool isAppReady = false;
  // 로딩창에 표시할 현재 단계 (1줄)
  String loadingStatusMessage = "준비 중...";
  void _setLoadingStatus(String msg) {
    loadingStatusMessage = msg;
    notifyListeners();
  }

  void markAppReady() {
    if (isAppReady) {
      return;
    }
    isAppReady = true;
    notifyListeners();
  }

  Future<void> loadInitialData() async {
    // pubspec.yaml의 version을 자동으로 읽어옴
    try {
      final info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
      // 업데이트가 끝나면(= 새 버전으로 켜지면) 받아 둔 설치 파일은 필요 없다.
      //  설치가 취소됐을 때 다시 쓰려고 남겨 두는 것이므로, 설치가 됐으면 지운다.
      unawaited(_cleanupOldApks());
    } catch (_) {
      // 버전을 못 읽으면 초기값("0.0.0")이 남는다.
      // 업데이트 확인이 항상 '새 버전 있음'으로 보일 뿐, 앱 동작에는 지장이 없다.
    }

    // 권한: 파일 접근은 앱 전용 디렉토리 사용 (권한 불필요)
    // 커스텀 경로 저장 시 실패하면 앱 전용 폴더로 자동 대체
    _setLoadingStatus("자동완성 태그 불러오는 중...");
    await _loadTagsFromJson();

    // 이름 필터 사전(에셋)을 로딩창 단계에서 미리 로드
    // → 첫 검색 때 느려지는 대신 앱 시작 시 한 번에 처리.
    // 백업 복구 경로가 아래에서 조기 return할 수 있으므로 반드시 그보다 먼저 수행.
    _setLoadingStatus("이름 필터 사전 불러오는 중...");
    await TagFilters.ensureNamesLoaded();

    _setLoadingStatus("설정 불러오는 중...");
    final prefs = await SharedPreferences.getInstance();

    // SharedPreferences가 비어있으면 백업에서 복구 시도
    final hasSettings = prefs.getString('api_token') != null || prefs.getString('positive') != null;
    if (!hasSettings) {
      final recovered = await tryRecoverFromBackup();
      if (recovered) {
        debugPrint("백업에서 설정 복구 완료");
        // 복구 성공해도 히스토리/레퍼런스는 별도 저장소에서 로드해야 함
        _setLoadingStatus("히스토리 불러오는 중...");
        await _loadHistoryFromLocal();
        await loadReferencesFromLocal();
        notifyListeners();
        return;
      }
    }

    apiToken = prefs.getString('api_token') ?? "";
    // 계정 목록 복원 (없으면 기존 단일 토큰을 옮긴다)
    final accRaw = prefs.getString('naiAccounts');
    if (accRaw != null && accRaw.isNotEmpty) {
      try {
        final list = jsonDecode(accRaw) as List;
        naiAccounts = list
            .map((e) => NaiAccount.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        // 저장된 값이 깨졌거나 형식이 바뀐 경우. 기본값으로 시작한다.
        // (여기서 멈추면 나머지 설정까지 못 읽어 앱이 초기 상태로 보인다)
      }
    }
    activeAccountIndex = prefs.getInt('activeAccountIndex') ?? 0;
    _migrateSingleToken();
    // 선택된 계정의 토큰을 실제 사용 토큰으로 맞춘다
    if (activeAccountIndex >= naiAccounts.length) {
      activeAccountIndex = 0;
    }
    if (naiAccounts.isNotEmpty) {
      apiToken = naiAccounts[activeAccountIndex].token;
    }
    apiTokenController.text = apiToken;
    // 토큰이 있으면 실제 서버에 검증 (Anlas 조회)
    if (apiToken.isNotEmpty) {
      try {
        _setLoadingStatus("API 연결 확인 중...");
        await fetchAnlas();
        // V5 한도도 같은 시점에만 확인한다 (매번 조회하지 않음)
        if (modelCapsFor(selectedModel).hasHourlyLimit) {
          await fetchV5Limit();
        }
        isApiConnected = currentAnlas >= 0;
      } catch (_) {
        isApiConnected = false;
      }
    } else {
      isApiConnected = false;
    }
    customFileNameController.text =
        prefs.getString('custom_file_name') ?? "Nai-{yy}{mm}{dd}-{time}";
    customWidthController.text = prefs.getString('custom_width') ?? "832";
    customHeightController.text = prefs.getString('custom_height') ?? "1216";
    conditionalRuleController.text = prefs.getString('conditional_rules') ?? "";
    conditionalTriggerMode = prefs.getString('conditionalTriggerMode') ?? "random";

    positiveController.text = prefs.getString('positive') ?? "";
    negativeController.text = prefs.getString('negative') ?? "";
    prefixController.text = prefs.getString('prefix') ?? "";
    suffixController.text = prefs.getString('suffix') ?? "";

    inpaintPositiveController.text = prefs.getString('inpaint_pos') ?? "";
    inpaintNegativeController.text = prefs.getString('inpaint_neg') ?? "";
    inpaintPrefixController.text = prefs.getString('inpaint_prefix') ?? "";
    inpaintSuffixController.text = prefs.getString('inpaint_suffix') ?? "";

    stepsController.text = prefs.getString('steps') ?? "28";
    cfgScaleController.text = prefs.getString('cfgScale') ?? "6.0";
    cfgRescaleController.text = prefs.getString('cfgRescale') ?? "0.00";
    seedController.text = prefs.getString('seed') ?? "";
    gelbooruIncludeController.text = prefs.getString('gelbooru_inc') ?? "";
    gelbooruExcludeController.text = prefs.getString('gelbooru_exc') ?? "";

    gelbooruApiController.text = prefs.getString('gelbooru_api_input') ?? "";
    parseGelbooruApi();

    ratingE = prefs.getBool('rating_e') ?? false;
    ratingQ = prefs.getBool('rating_q') ?? false;
    ratingS = prefs.getBool('rating_s') ?? false;
    ratingG = prefs.getBool('rating_g') ?? true;
    removeCharacteristics = prefs.getBool('remove_char_traits') ?? false;
    removeClothes = prefs.getBool('remove_clothes') ?? false;
    removeClothingEvents = prefs.getBool('remove_clothing_events') ?? false;
    removeImpliedTags = prefs.getBool('remove_implied_tags') ?? false;
    charRetapToggle = prefs.getBool('charRetapToggle') ?? true;
    saveFolderByDateOnly = prefs.getBool('saveFolderByDateOnly') ?? true;
    removeColors = prefs.getBool('remove_colors') ?? false;
    customRemoveController.text = prefs.getString('custom_remove') ?? "";
    isAutoSave = prefs.getBool('auto_save') ?? true;
    saveAsWebp = prefs.getBool('saveAsWebp') ?? false;
    webpLossy = prefs.getBool('webpLossy') ?? false;
    isRandomLocked = prefs.getBool('random_lock') ?? false;
    isSeedLocked = prefs.getBool('seedLocked') ?? false;
    directorTool = prefs.getString('directorTool') ?? 'bg-removal';
    wildcardSubTab = (prefs.getInt('wildcardSubTab') ?? 0).clamp(0, 1);
    expandNestedWeightsEnabled = prefs.getBool('expandNestedWeights') ?? true;
    // 프롬프트 되돌리기 기록 (입력창 이름 → 최근 내용 목록)
    final undoRaw = prefs.getString('promptUndoHistory');
    if (undoRaw != null) {
      try {
        promptUndoHistory = (jsonDecode(undoRaw) as Map).map(
          (k, v) => MapEntry(k as String, List<String>.from(v as List)),
        );
      } catch (_) {
        // 형식이 깨졌으면 버린다. 되돌리기 기록은 없어도 앱 동작에 지장이 없다.
      }
    }
    directorToolVisible = prefs.getBool('directorToolVisible') ?? true;
    infillStrength = prefs.getDouble('infillStrength') ?? 0.7;
    img2imgStrength = prefs.getDouble('img2imgStrength') ?? 0.5;
    img2imgNoise = prefs.getDouble('img2imgNoise') ?? 0.1;
    isVariancePlus = prefs.getBool('variancePlus') ?? false;
    horizontalSwipeEnabled = prefs.getBool('horizontalSwipeEnabled') ?? false;
    // 3.9.0 에서 i2i 탭의 예전 배치를 없애며 쓰지 않게 된 설정값을 치운다
    unawaited(prefs.remove('i2iAltLayout'));
    promptAltLayout = prefs.getBool('promptAltLayout') ?? false;
    promptNewLayout = prefs.getBool('promptNewLayout') ?? true;
    gelbooruSearchPages = (prefs.getInt('gelbooruSearchPages') ?? 40).clamp(40, 120);
    diversifySearchSort = prefs.getBool('diversifySearchSort') ?? false;
    promptCharDrawerEnabled = prefs.getBool('promptCharDrawerEnabled') ?? true;
    weightRulesEnabled = prefs.getBool('weightRulesEnabled') ?? false;
    weightRulesController.text = prefs.getString('weightRules') ?? "";
    historySlideEnabled = prefs.getBool('historySlideEnabled') ?? false;
    randomPromptAlphabetical = prefs.getBool('randomPromptAlphabetical') ?? false;
    ignoreRecommendedOrder = prefs.getBool('ignoreRecommendedOrder') ?? false;
    weightHighlight = prefs.getBool('weightHighlight') ?? true;
    e621Enabled = prefs.getBool('e621Enabled') ?? false;
    safCardOpen = prefs.getBool('safCardOpen') ?? true;
    fileCardOpen = prefs.getBool('fileCardOpen') ?? true;
    themeAccent = prefs.getInt('themeAccent') ?? 0xFF7C4DFF;
    AppColors.accent = Color(themeAccent);
    i2iHistoryDisabled = prefs.getBool('i2iHistoryDisabled') ?? false;
    // 옛 설정(inpaintAutoSwitchResult)은 의미가 반대였다. 남아 있으면 뒤집어서 이어받는다.
    final legacyAutoSwitch = prefs.getBool('inpaintAutoSwitchResult');
    inpaintNoAutoSwitch =
        prefs.getBool('inpaintNoAutoSwitch') ??
        (legacyAutoSwitch != null ? !legacyAutoSwitch : false);
    inpaintAutoClearMask = prefs.getBool('inpaintAutoClearMask') ?? false;
    galleryModeEnabled = prefs.getBool('galleryModeEnabled') ?? true;
    galleryCurrentPath = prefs.getString('galleryCurrentPath');
    galleryColumns = prefs.getInt('galleryColumns') ?? 3;
    promptEditorFontSize = prefs.getDouble('promptEditorFontSize') ?? 16.0;
    gallerySortMode = prefs.getString('gallerySortMode') ?? 'name_asc';
    WeightHighlightController.highlightEnabled = weightHighlight;
    batchDelay = prefs.getDouble('batchDelay') ?? 0.5;
    autoNextPromptInBatch = prefs.getBool('autoNextPromptInBatch') ?? false;
    repeatSamePromptEnabled = prefs.getBool('repeatSamePromptEnabled') ?? false;
    repeatSamePromptCount = prefs.getInt('repeatSamePromptCount') ?? 2;
    autoCheckUpdate = prefs.getBool('autoCheckUpdate') ?? true;
    historyTabEnabled = prefs.getBool('historyTabEnabled') ?? true;
    i2iTabEnabled = prefs.getBool('i2iTabEnabled') ?? true;
    i2iModeInpaintEnabled = prefs.getBool('i2iModeInpaintEnabled') ?? true;
    i2iModeMosaicEnabled = prefs.getBool('i2iModeMosaicEnabled') ?? true;
    i2iModeImg2imgEnabled = prefs.getBool('i2iModeImg2imgEnabled') ?? true;
    i2iModeUpscaleEnabled = prefs.getBool('i2iModeUpscaleEnabled') ?? true;
    // 일관성 보정: 모드가 전부 꺼져 있으면 탭도 꺼져 있어야 함 (모순 조합 정리)
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false;
    }
    characterTabEnabled = prefs.getBool('characterTabEnabled') ?? true;
    useCharacterPosition = prefs.getBool('useCharacterPosition') ?? true;
    charCanvasShowGrid = prefs.getBool('charCanvasShowGrid') ?? false;
    charCanvasSnap = prefs.getBool('charCanvasSnap') ?? false;
    charCanvasShowImage = prefs.getBool('charCanvasShowImage') ?? false;
    charGridCols = prefs.getInt('charGridCols') ?? 5;
    charGridRows = prefs.getInt('charGridRows') ?? 5;
    transparentBackground = prefs.getBool('transparentBackground') ?? false;
    qualityTagsPreset = prefs.getString('qualityTagsPreset') ?? 'None';
    ucPreset = prefs.getString('ucPreset') ?? 'None';
    randomCharacterOrder = prefs.getBool('randomCharacterOrder') ?? false;
    if (useCharacterPosition && randomCharacterOrder) {
      randomCharacterOrder = false; // 상호 배타 보정
    }
    wildcardTabEnabled = prefs.getBool('wildcardTabEnabled') ?? true;
    useGelbooruApiKey = prefs.getBool('useGelbooruApiKey') ?? true;
    resolutionMode = prefs.getString('resolutionMode') ?? "수동";
    final sectionOrderJson = prefs.getStringList('promptSectionOrder');
    if (sectionOrderJson != null && sectionOrderJson.isNotEmpty) {
      // 저장된 순서를 쓰되, 새로 생긴 섹션은 뒤에 붙이고 없어진 섹션은 버린다.
      // (길이를 고정하면 섹션이 추가될 때 저장된 순서가 통째로 무시됨)
      promptSectionOrder = _mergeSectionOrder(sectionOrderJson);
    }
    hiddenPromptSections = (prefs.getStringList('hiddenPromptSections') ?? []).toSet();
    pinnedPromptSections = (prefs.getStringList('pinnedPromptSections') ?? []).toSet();
    conditionalGuideCollapsed = prefs.getBool('conditionalGuideCollapsed') ?? false;
    collapsedI2iPrompts = (prefs.getStringList('collapsedI2iPrompts') ?? []).toSet();
    collapsedSettingGroups = (prefs.getStringList('collapsedSettingGroups') ?? []).toSet();
    final collapsedJson = prefs.getStringList('collapsedSections');
    if (collapsedJson != null) {
      collapsedSections = collapsedJson.toSet();
    }
    selectedModel = prefs.getString('model') ?? NaiModels.v45Full;
    final profRaw = prefs.getString('modelSettingProfiles');
    if (profRaw != null && profRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(profRaw) as Map<String, dynamic>;
        modelSettingProfiles = decoded.map(
          (k, v) => MapEntry(k, Map<String, String>.from(v as Map)),
        );
      } catch (_) {
        // 저장된 값이 깨졌거나 형식이 바뀐 경우. 기본값으로 시작한다.
        // (여기서 멈추면 나머지 설정까지 못 읽어 앱이 초기 상태로 보인다)
      }
    }
    // 제거된 테스트 모델이 저장돼 있으면 실제 v4.5로 교정 (드롭다운 크래시 방지)
    if (selectedModel == "nai-diffusion-4-5-full-test") {
      selectedModel = NaiModels.v45Full;
    }
    selectedSampler = prefs.getString('sampler') ?? "k_euler_ancestral";
    // ddim은 V4 계열에서 동작하지 않아 제거됨 — 예전 설정이 남아 있으면 기본값으로
    if (selectedSampler == 'ddim') {
      selectedSampler = "k_euler_ancestral";
    }
    selectedScheduler = prefs.getString('scheduler') ?? "karras";
    selectedResolution = prefs.getString('resolution') ?? "832 x 1216";
    resolutionScale = prefs.getDouble('resolutionScale') ?? 1.0;
    if (resolutionScale != 1.5) {
      resolutionScale = 1.0;
    } // 1.0 또는 1.5만 허용
    customResolutions = prefs.getStringList('customResolutions') ?? [];

    String? charJson = prefs.getString('characters');
    if (charJson != null) {
      List<dynamic> decoded = jsonDecode(charJson);
      characters = decoded.map((e) => NaiCharacter.fromJson(e)).toList();
    }
    if (characters.isEmpty) {
      characters.add(NaiCharacter());
    }
    String? wildcardJson = prefs.getString('wildcards');
    if (wildcardJson != null) {
      List<dynamic> decoded = jsonDecode(wildcardJson);
      wildcards = decoded.map((e) => NaiWildcard.fromJson(e)).toList();
    }
    if (wildcards.isEmpty) {
      wildcards.add(NaiWildcard(name: "의상", content: "school uniform\nmaid outfit\nbikini"));
    }

    // 프리셋: 파일 우선. 없으면 예전 방식(prefs)에서 읽어 파일로 옮긴다.
    await _loadPresets(prefs);
    await _loadPromptDict();

    gelbooruPrompts = prefs.getStringList('gelbooruPrompts') ?? [];
    gelbooruTotal = gelbooruPrompts.length;
    currentPromptIndex = prefs.getInt('currentPromptIndex') ?? 0;
    if (gelbooruTotal > 0) {
      gelbooruRemaining = gelbooruTotal - currentPromptIndex;
    }

    await fetchAnlas();
    // V5 한도도 같은 시점에만 확인한다 (매번 조회하지 않음)
    if (modelCapsFor(selectedModel).hasHourlyLimit) {
      await fetchV5Limit();
    }
    _setLoadingStatus("히스토리 불러오는 중...");
    await _loadHistoryFromLocal();
    await loadReferencesFromLocal();
    await loadI2iFavorites();
    await _loadSafRoot();
    notifyListeners();

    // 업데이트 체크 (조건부, 앱 시작을 블로킹하지 않음)
    if (autoCheckUpdate) {
      checkForUpdate();
    }
  }

  Future<void> _loadTagsFromJson() async {
    Map<String, int> danbooruCounts = {};
    try {
      final String jsonString = await rootBundle.loadString('assets/tags.json');
      final List<dynamic> jsonData = jsonDecode(jsonString);

      jsonData.sort((a, b) => (b['post_count'] ?? 0).compareTo(a['post_count'] ?? 0));
      danbooruTags = jsonData.map((e) => e['tag_name'].toString()).toList();
      for (final e in jsonData) {
        danbooruCounts[e['tag_name'].toString()] = (e['post_count'] ?? 0) as int;
      }
      debugPrint("✅ Danbooru 태그 로딩 완료! 총 ${danbooruTags.length}개");
    } catch (e) {
      debugPrint("❌ Danbooru 태그 파일 읽기 실패: $e");
    }

    // e621 태그 로딩 (Danbooru에 없는 것만 = 세밀한 전용 태그)
    try {
      final danbooruSet = danbooruTags.toSet();
      final String e621String = await rootBundle.loadString('assets/e621_tags.json');
      final List<dynamic> e621Data = jsonDecode(e621String);

      // Danbooru에 이미 있는 태그는 제외 (Danbooru 우선)
      final filtered = e621Data
          .where((e) => !danbooruSet.contains(e['tag_name'].toString()))
          .toList();
      filtered.sort((a, b) => (b['post_count'] ?? 0).compareTo(a['post_count'] ?? 0));

      e621Tags = filtered.map((e) => e['tag_name'].toString()).toList();
      e621TagSet = e621Tags.toSet();

      // 검색용 통합 리스트: Danbooru + e621 전체를 count순으로 미리 정렬
      final Map<String, int> e621Counts = {};
      for (final e in filtered) {
        e621Counts[e['tag_name'].toString()] = (e['post_count'] ?? 0) as int;
      }
      _combinedTags = [...danbooruTags, ...e621Tags];
      _combinedTags.sort((a, b) {
        final ca = danbooruCounts[a] ?? e621Counts[a] ?? 0;
        final cb = danbooruCounts[b] ?? e621Counts[b] ?? 0;
        return cb.compareTo(ca);
      });

      debugPrint("✅ e621 전용 태그 로딩 완료! 총 ${e621Tags.length}개 (중복 제거됨)");
    } catch (e) {
      debugPrint("❌ e621 태그 파일 읽기 실패: $e");
    }
  }

  // ============================================================================
  // 설정 내보내기/가져오기
  // ============================================================================
  /// [favoritesOnly] 면 히스토리 중 즐겨찾기한 것만 담는다.
  ///  (업데이트 전 자동 백업용 — 전체 히스토리는 썸네일 만드는 데만 수 초가 걸린다.
  ///   즐겨찾기는 '어떤 프롬프트였는지'를 남기려는 것이라 썸네일은 작아도 된다)
  Future<Map<String, dynamic>> exportSettings({
    bool includeHistory = true,
    bool favoritesOnly = false,
  }) async {
    // 히스토리 썸네일 생성 → 백그라운드 isolate로 처리
    List<Map<String, dynamic>> historyExport = [];
    if (includeHistory && historyImages.isNotEmpty) {
      // 네 목록은 번호로 짝지어져 있으므로 같은 번호끼리 골라 담는다
      final idx = [
        for (int i = 0; i < historyImages.length; i++)
          if (!favoritesOnly || (i < historyFavorites.length && historyFavorites[i])) i,
      ];
      if (idx.isNotEmpty) {
        // 큰 원본(최근 이미지)은 히스토리 썸네일과 같은 규칙으로 먼저 줄인다.
        //  isolate 안에서는 네이티브 인코더를 못 쓰므로 여기서 처리하고,
        //  isolate 는 이미 작은 것을 그대로 담기만 한다. (실패한 것만 isolate 가 옛 방식으로 줄인다)
        final images = [for (final i in idx) historyImages[i]];
        for (int k = 0; k < images.length; k++) {
          if (images[k].length >= kThumbBytesLimit) {
            images[k] = await makeHistoryThumb(images[k]) ?? images[k];
          }
        }
        historyExport = await compute(_exportHistoryIsolate, {
          'images': images,
          'metadata': [
            for (final i in idx) i < historyMetadata.length ? historyMetadata[i]?.toJson() : null,
          ],
          'favorites': [for (final i in idx) i < historyFavorites.length && historyFavorites[i]],
          'filePaths': [
            for (final i in idx) i < historyFilePaths.length ? historyFilePaths[i] : null,
          ],
        });
      }
    }

    return {
      'version': currentVersion,
      'api_token': apiToken,
      'naiAccounts': naiAccounts.map((e) => e.toJson()).toList(),
      'activeAccountIndex': activeAccountIndex,
      'positive': positiveController.text,
      'negative': negativeController.text,
      'prefix': prefixController.text,
      'suffix': suffixController.text,
      'inpaint_pos': inpaintPositiveController.text,
      'inpaint_neg': inpaintNegativeController.text,
      'inpaint_prefix': inpaintPrefixController.text,
      'inpaint_suffix': inpaintSuffixController.text,
      'steps': stepsController.text,
      'cfgScale': cfgScaleController.text,
      'cfgRescale': cfgRescaleController.text,
      'seed': seedController.text,
      'conditional_rules': conditionalRuleController.text,
      'conditionalTriggerMode': conditionalTriggerMode,
      'gelbooru_inc': gelbooruIncludeController.text,
      'gelbooru_exc': gelbooruExcludeController.text,
      'custom_file_name': customFileNameController.text,
      'custom_width': customWidthController.text,
      'custom_height': customHeightController.text,
      'custom_remove': customRemoveController.text,
      'model': selectedModel,
      'modelSettingProfiles': modelSettingProfiles,
      'sampler': selectedSampler,
      'scheduler': selectedScheduler,
      'resolutionMode': resolutionMode,
      'promptSectionOrder': promptSectionOrder,
      'rating_e': ratingE,
      'rating_q': ratingQ,
      'rating_s': ratingS,
      'rating_g': ratingG,
      'remove_char_traits': removeCharacteristics,
      'remove_clothes': removeClothes,
      'remove_clothing_events': removeClothingEvents,
      'remove_implied_tags': removeImpliedTags,
      'charRetapToggle': charRetapToggle,
      'saveFolderByDateOnly': saveFolderByDateOnly,
      'remove_colors': removeColors,
      'auto_save': isAutoSave,
      'saveAsWebp': saveAsWebp,
      'webpLossy': webpLossy,
      'random_lock': isRandomLocked,
      'seedLocked': isSeedLocked,
      'directorTool': directorTool,
      // 사전은 파일로 따로 저장하지만 백업에는 함께 담는다 (잃으면 복구 불가)
      'promptDict': promptDict.map((e) => e.toJson()).toList(),
      'promptDictCategories': promptDictCategories.map((c) => c.toJson()).toList(),
      'expandNestedWeights': expandNestedWeightsEnabled,
      'promptUndoHistory': promptUndoHistory,
      'directorToolVisible': directorToolVisible,
      'infillStrength': infillStrength,
      'img2imgStrength': img2imgStrength,
      'img2imgNoise': img2imgNoise,
      'variancePlus': isVariancePlus,
      'horizontalSwipeEnabled': horizontalSwipeEnabled,
      'promptAltLayout': promptAltLayout,
      'promptNewLayout': promptNewLayout,
      'gelbooruSearchPages': gelbooruSearchPages,
      'diversifySearchSort': diversifySearchSort,
      'promptCharDrawerEnabled': promptCharDrawerEnabled,
      'weightRulesEnabled': weightRulesEnabled,
      'weightRules': weightRulesController.text,
      'historySlideEnabled': historySlideEnabled,
      'randomPromptAlphabetical': randomPromptAlphabetical,
      'ignoreRecommendedOrder': ignoreRecommendedOrder,
      'weightHighlight': weightHighlight,
      'e621Enabled': e621Enabled,
      'safCardOpen': safCardOpen,
      'fileCardOpen': fileCardOpen,
      'themeAccent': themeAccent,
      // i2i 즐겨찾기 — 사용자가 모아둔 결과물이라 기기를 옮겨도 남아야 한다
      'i2iFavorites': i2iResults.where((r) => r.favorite).map((r) => r.toJson()).toList(),
      'i2iHistoryDisabled': i2iHistoryDisabled,
      'inpaintNoAutoSwitch': inpaintNoAutoSwitch,
      'inpaintAutoClearMask': inpaintAutoClearMask,
      'galleryModeEnabled': galleryModeEnabled,
      'galleryCurrentPath': galleryCurrentPath,
      'galleryColumns': galleryColumns,
      'promptEditorFontSize': promptEditorFontSize,
      'gallerySortMode': gallerySortMode,
      'batchDelay': batchDelay,
      'autoNextPromptInBatch': autoNextPromptInBatch,
      'repeatSamePromptEnabled': repeatSamePromptEnabled,
      'repeatSamePromptCount': repeatSamePromptCount,
      'historyTabEnabled': historyTabEnabled,
      'i2iTabEnabled': i2iTabEnabled,
      'i2iModeInpaintEnabled': i2iModeInpaintEnabled,
      'i2iModeMosaicEnabled': i2iModeMosaicEnabled,
      'i2iModeImg2imgEnabled': i2iModeImg2imgEnabled,
      'i2iModeUpscaleEnabled': i2iModeUpscaleEnabled,
      'characterTabEnabled': characterTabEnabled,
      'useCharacterPosition': useCharacterPosition,
      'charCanvasShowGrid': charCanvasShowGrid,
      'charCanvasSnap': charCanvasSnap,
      'charCanvasShowImage': charCanvasShowImage,
      'charGridCols': charGridCols,
      'charGridRows': charGridRows,
      'transparentBackground': transparentBackground,
      'qualityTagsPreset': qualityTagsPreset,
      'ucPreset': ucPreset,
      'randomCharacterOrder': randomCharacterOrder,
      'wildcardTabEnabled': wildcardTabEnabled,
      'useGelbooruApiKey': useGelbooruApiKey,
      'gelbooru_api_input': gelbooruApiController.text,
      'resolution': selectedResolution,
      'resolutionScale': resolutionScale,
      'customResolutions': customResolutions,
      'autoCheckUpdate': autoCheckUpdate,
      'collapsedSections': collapsedSections.toList(),
      'hiddenPromptSections': hiddenPromptSections.toList(),
      'pinnedPromptSections': pinnedPromptSections.toList(),
      'conditionalGuideCollapsed': conditionalGuideCollapsed,
      'collapsedI2iPrompts': collapsedI2iPrompts.toList(),
      'collapsedSettingGroups': collapsedSettingGroups.toList(),
      'characters': characters.map((c) => c.toJson()).toList(),
      'wildcards': wildcards.map((w) => w.toJson()).toList(),
      'presets': presets.map((p) => p.toJson()).toList(),
      if (includeHistory) 'history': historyExport,
    };
  }

  static List<Map<String, dynamic>> _exportHistoryIsolate(Map<String, dynamic> params) {
    final images = params['images'] as List<Uint8List>;
    final metadata = params['metadata'] as List;
    final favorites = params['favorites'] as List<bool>;
    final filePaths = params['filePaths'] as List<String?>;

    List<Map<String, dynamic>> result = [];
    for (int i = 0; i < images.length; i++) {
      String base64Thumb;
      // 50KB 이하 = 이미 썸네일
      if (images[i].length < kThumbBytesLimit) {
        base64Thumb = base64Encode(images[i]);
      } else {
        try {
          final decoded = img.decodeImage(images[i]);
          if (decoded != null) {
            final thumb = img.copyResize(decoded, width: 200);
            base64Thumb = base64Encode(Uint8List.fromList(img.encodeJpg(thumb, quality: 70)));
          } else {
            base64Thumb = base64Encode(images[i]);
          }
        } catch (_) {
          base64Thumb = base64Encode(images[i]);
        }
      }
      result.add({
        'image': base64Thumb,
        'metadata': i < metadata.length ? metadata[i] : null,
        'favorite': i < favorites.length ? favorites[i] : false,
        'filePath': i < filePaths.length ? filePaths[i] : null,
      });
    }
    return result;
  }

  void importSettings(Map<String, dynamic> data) {
    // API 토큰 복원
    if (data['api_token'] != null && data['api_token'].toString().isNotEmpty) {
      apiToken = data['api_token'];
      if (data['naiAccounts'] != null) {
        try {
          naiAccounts = (data['naiAccounts'] as List)
              .map((e) => NaiAccount.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          activeAccountIndex = data['activeAccountIndex'] ?? 0;
        } catch (_) {
          // 계정 목록이 깨져 있으면 통째로 건너뛴다.
          // 백업 파일이 옛 버전이거나 손상된 경우인데, 여기서 멈추면
          // 나머지 설정까지 복원되지 않는다. 계정은 다시 등록하면 된다.
        }
      }
      _migrateSingleToken();
      apiTokenController.text = apiToken;
      // 토큰만 복원, 연결 상태는 다음 기동 시 검증
      isApiConnected = false;
    }

    positiveController.text = data['positive'] ?? '';
    negativeController.text = data['negative'] ?? '';
    prefixController.text = data['prefix'] ?? '';
    suffixController.text = data['suffix'] ?? '';
    inpaintPositiveController.text = data['inpaint_pos'] ?? '';
    inpaintNegativeController.text = data['inpaint_neg'] ?? '';
    inpaintPrefixController.text = data['inpaint_prefix'] ?? '';
    inpaintSuffixController.text = data['inpaint_suffix'] ?? '';
    stepsController.text = data['steps'] ?? '28';
    cfgScaleController.text = data['cfgScale'] ?? '6.0';
    cfgRescaleController.text = data['cfgRescale'] ?? '0.00';
    seedController.text = data['seed'] ?? '';
    conditionalRuleController.text = data['conditional_rules'] ?? '';
    conditionalTriggerMode = data['conditionalTriggerMode'] ?? 'random';
    gelbooruIncludeController.text = data['gelbooru_inc'] ?? '';
    gelbooruExcludeController.text = data['gelbooru_exc'] ?? '';
    customFileNameController.text = data['custom_file_name'] ?? 'Nai-{yy}{mm}{dd}-{time}';
    customWidthController.text = data['custom_width'] ?? '832';
    customHeightController.text = data['custom_height'] ?? '1216';
    customRemoveController.text = data['custom_remove'] ?? '';
    selectedModel = data['model'] ?? NaiModels.v45Full;
    if (data['modelSettingProfiles'] != null) {
      try {
        modelSettingProfiles = (data['modelSettingProfiles'] as Map).map(
          (k, v) => MapEntry(k as String, Map<String, String>.from(v as Map)),
        );
      } catch (_) {
        // 모델별 기억값은 편의 기능이라 형식이 안 맞으면 버린다.
        // 비워 두면 다음에 모델을 바꿀 때 현재 값으로 다시 채워진다.
      }
    }
    if (selectedModel == "nai-diffusion-4-5-full-test") {
      selectedModel = NaiModels.v45Full;
    }
    selectedSampler = data['sampler'] ?? 'k_euler_ancestral';
    selectedScheduler = data['scheduler'] ?? 'karras';
    resolutionMode = data['resolutionMode'] ?? '수동';
    if (data['promptSectionOrder'] != null) {
      promptSectionOrder = _mergeSectionOrder(List<String>.from(data['promptSectionOrder']));
    }
    ratingE = data['rating_e'] ?? false;
    ratingQ = data['rating_q'] ?? false;
    ratingS = data['rating_s'] ?? false;
    ratingG = data['rating_g'] ?? true;
    removeCharacteristics = data['remove_char_traits'] ?? false;
    removeClothes = data['remove_clothes'] ?? false;
    removeClothingEvents = data['remove_clothing_events'] ?? false;
    removeImpliedTags = data['remove_implied_tags'] ?? false;
    charRetapToggle = data['charRetapToggle'] ?? true;
    saveFolderByDateOnly = data['saveFolderByDateOnly'] ?? true;
    removeColors = data['remove_colors'] ?? false;
    isAutoSave = data['auto_save'] ?? true;
    saveAsWebp = data['saveAsWebp'] ?? false;
    webpLossy = data['webpLossy'] ?? false;
    isRandomLocked = data['random_lock'] ?? false;
    isSeedLocked = data['seedLocked'] ?? false;
    directorTool = data['directorTool'] ?? 'bg-removal';
    if (data['promptDict'] != null) {
      try {
        promptDict = (data['promptDict'] as List).map((e) => PromptDictEntry.fromJson(e)).toList();
        promptDictCategories = ((data['promptDictCategories'] as List?) ?? const [])
            .map((e) => PromptDictCategory.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _dropDanglingCategoryRefs();
        _dictThumbCache.clear(); // 항목이 통째로 바뀌었으니 옛 미리보기 풀이는 버린다
        unawaited(savePromptDict()); // 복원분을 파일에도 반영
        // 복원으로 사라진 항목의 큰 이미지를 치운다 (남은 항목의 이미지는 그대로)
        unawaited(_cleanupDictImages());
      } catch (_) {
        // 옛 백업이거나 형식이 다르면 사전만 건너뛴다
      }
    }
    expandNestedWeightsEnabled = data['expandNestedWeights'] ?? true;
    if (data['promptUndoHistory'] != null) {
      try {
        promptUndoHistory = (data['promptUndoHistory'] as Map).map(
          (k, v) => MapEntry(k as String, List<String>.from(v as List)),
        );
      } catch (_) {
        // 백업이 옛 형식이면 되돌리기 기록만 건너뛴다
      }
    }
    directorToolVisible = data['directorToolVisible'] ?? true;
    infillStrength = (data['infillStrength'] ?? 0.7).toDouble();
    img2imgStrength = (data['img2imgStrength'] ?? 0.5).toDouble();
    img2imgNoise = (data['img2imgNoise'] ?? 0.1).toDouble();
    isVariancePlus = data['variancePlus'] ?? false;
    horizontalSwipeEnabled = data['horizontalSwipeEnabled'] ?? false;
    promptAltLayout = data['promptAltLayout'] ?? false;
    promptNewLayout = data['promptNewLayout'] ?? true;
    gelbooruSearchPages = ((data['gelbooruSearchPages'] ?? 40) as int).clamp(40, 120);
    diversifySearchSort = data['diversifySearchSort'] ?? false;
    promptCharDrawerEnabled = data['promptCharDrawerEnabled'] ?? true;
    weightRulesEnabled = data['weightRulesEnabled'] ?? false;
    weightRulesController.text = data['weightRules'] ?? "";
    historySlideEnabled = data['historySlideEnabled'] ?? false;
    randomPromptAlphabetical = data['randomPromptAlphabetical'] ?? false;
    ignoreRecommendedOrder = data['ignoreRecommendedOrder'] ?? false;
    weightHighlight = data['weightHighlight'] ?? true;
    e621Enabled = data['e621Enabled'] ?? false;
    safCardOpen = data['safCardOpen'] ?? true;
    fileCardOpen = data['fileCardOpen'] ?? true;
    themeAccent = data['themeAccent'] ?? 0xFF7C4DFF;
    AppColors.accent = Color(themeAccent);
    // i2i 즐겨찾기 복원 (형식이 달라도 앱이 멈추지 않게 감싼다)
    if (data['i2iFavorites'] != null) {
      try {
        final list = data['i2iFavorites'] as List;
        i2iResults = list
            .map((e) => I2iResult.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        unawaited(saveI2iFavorites());
      } catch (e) {
        debugPrint('i2i 즐겨찾기 복원 실패: $e');
      }
    }
    i2iHistoryDisabled = data['i2iHistoryDisabled'] ?? false;
    // 옛 백업 호환: inpaintAutoSwitchResult(반대 의미)가 있으면 뒤집어서 적용
    inpaintNoAutoSwitch =
        data['inpaintNoAutoSwitch'] ??
        (data['inpaintAutoSwitchResult'] != null ? !data['inpaintAutoSwitchResult'] : false);
    inpaintAutoClearMask = data['inpaintAutoClearMask'] ?? false;
    galleryModeEnabled = data['galleryModeEnabled'] ?? true;
    galleryCurrentPath = data['galleryCurrentPath'];
    galleryColumns = data['galleryColumns'] ?? 3;
    promptEditorFontSize = (data['promptEditorFontSize'] as num?)?.toDouble() ?? 16.0;
    gallerySortMode = data['gallerySortMode'] ?? 'name_asc';
    WeightHighlightController.highlightEnabled = weightHighlight;
    batchDelay = (data['batchDelay'] ?? 0.5).toDouble();
    autoNextPromptInBatch = data['autoNextPromptInBatch'] ?? false;
    repeatSamePromptEnabled = data['repeatSamePromptEnabled'] ?? false;
    repeatSamePromptCount = data['repeatSamePromptCount'] ?? 2;
    historyTabEnabled = data['historyTabEnabled'] ?? true;
    i2iTabEnabled = data['i2iTabEnabled'] ?? true;
    i2iModeInpaintEnabled = data['i2iModeInpaintEnabled'] ?? true;
    i2iModeMosaicEnabled = data['i2iModeMosaicEnabled'] ?? true;
    i2iModeImg2imgEnabled = data['i2iModeImg2imgEnabled'] ?? true;
    i2iModeUpscaleEnabled = data['i2iModeUpscaleEnabled'] ?? true;
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false; // 모순 조합 정리
    }
    characterTabEnabled = data['characterTabEnabled'] ?? true;
    useCharacterPosition = data['useCharacterPosition'] ?? true;
    charCanvasShowGrid = data['charCanvasShowGrid'] ?? false;
    charCanvasSnap = data['charCanvasSnap'] ?? false;
    charCanvasShowImage = data['charCanvasShowImage'] ?? false;
    charGridCols = data['charGridCols'] ?? 5;
    charGridRows = data['charGridRows'] ?? 5;
    transparentBackground = data['transparentBackground'] ?? false;
    qualityTagsPreset = data['qualityTagsPreset'] ?? 'None';
    ucPreset = data['ucPreset'] ?? 'None';
    randomCharacterOrder = data['randomCharacterOrder'] ?? false;
    if (useCharacterPosition && randomCharacterOrder) {
      randomCharacterOrder = false; // 상호 배타 보정
    }
    // 구버전 백업 호환: vibe/precise가 설정 파일에 있으면 불러옴 (현재는 references.json에 별도 저장)
    bool hadRefs = false;
    if (data['vibeTransfers'] != null) {
      vibeTransfers = (data['vibeTransfers'] as List).map((e) {
        final m = Map<String, dynamic>.from(e);
        if (m['strength'] != null) {
          m['strength'] = (m['strength'] as num).toDouble();
        }
        if (m['infoExtracted'] != null) {
          m['infoExtracted'] = (m['infoExtracted'] as num).toDouble();
        }
        if (m['_encodedInfoExt'] != null) {
          m['_encodedInfoExt'] = (m['_encodedInfoExt'] as num).toDouble();
        }
        return m;
      }).toList();
      hadRefs = true;
    }
    if (data['preciseRefs'] != null) {
      preciseRefs = (data['preciseRefs'] as List).map((e) {
        final m = Map<String, dynamic>.from(e);
        if (m['strength'] != null) {
          m['strength'] = (m['strength'] as num).toDouble();
        }
        if (m['fidelity'] != null) {
          m['fidelity'] = (m['fidelity'] as num).toDouble();
        }
        return m;
      }).toList();
      hadRefs = true;
    }
    if (hadRefs) {
      saveReferencesToLocal();
    }
    wildcardTabEnabled = data['wildcardTabEnabled'] ?? true;
    historyTabEnabled = data['historyTabEnabled'] ?? true;
    i2iTabEnabled = data['i2iTabEnabled'] ?? true;
    i2iModeInpaintEnabled = data['i2iModeInpaintEnabled'] ?? true;
    i2iModeMosaicEnabled = data['i2iModeMosaicEnabled'] ?? true;
    i2iModeImg2imgEnabled = data['i2iModeImg2imgEnabled'] ?? true;
    i2iModeUpscaleEnabled = data['i2iModeUpscaleEnabled'] ?? true;
    if (enabledI2iModes.isEmpty) {
      i2iTabEnabled = false; // 모순 조합 정리
    }
    useGelbooruApiKey = data['useGelbooruApiKey'] ?? true;
    if (data['gelbooru_api_input'] != null) {
      gelbooruApiController.text = data['gelbooru_api_input'];
      parseGelbooruApi();
    }
    if (data['resolution'] != null) {
      selectedResolution = data['resolution'];
    }
    resolutionScale = (data['resolutionScale'] ?? 1.0).toDouble();
    if (resolutionScale != 1.5) {
      resolutionScale = 1.0;
    }
    if (data['customResolutions'] != null) {
      customResolutions = List<String>.from(data['customResolutions']);
    }
    if (data['autoCheckUpdate'] != null) {
      autoCheckUpdate = data['autoCheckUpdate'];
    }
    if (data['hiddenPromptSections'] != null) {
      hiddenPromptSections = Set<String>.from(data['hiddenPromptSections']);
    }
    if (data['pinnedPromptSections'] != null) {
      pinnedPromptSections = Set<String>.from(data['pinnedPromptSections']);
    }
    conditionalGuideCollapsed = data['conditionalGuideCollapsed'] ?? false;
    if (data['collapsedI2iPrompts'] != null) {
      collapsedI2iPrompts = Set<String>.from(data['collapsedI2iPrompts']);
    }
    if (data['collapsedSettingGroups'] != null) {
      collapsedSettingGroups = Set<String>.from(data['collapsedSettingGroups']);
    }
    if (data['collapsedSections'] != null) {
      collapsedSections = Set<String>.from(data['collapsedSections']);
    }

    if (data['characters'] != null) {
      characters = (data['characters'] as List).map((e) => NaiCharacter.fromJson(e)).toList();
      if (characters.isEmpty) {
        characters.add(NaiCharacter());
      }
    }
    if (data['wildcards'] != null) {
      wildcards = (data['wildcards'] as List).map((e) => NaiWildcard.fromJson(e)).toList();
    }
    if (data['presets'] != null) {
      presets = (data['presets'] as List).map((e) => NaiPreset.fromJson(e)).toList();
      unawaited(savePresetsToFile()); // 백업 복원분도 파일에 반영
    }

    // 히스토리 복원 (썸네일 base64 → Uint8List)
    if (data['history'] != null) {
      final historyData = data['history'] as List;
      // 백업으로 히스토리를 통째로 바꾸는 것이므로 막아 둔 저장을 다시 푼다
      _historyLoadFailed = false;
      historyImages.clear();
      historyMetadata.clear();
      historyFavorites.clear();
      historyFilePaths.clear();

      for (final item in historyData) {
        try {
          final imageBase64 = item['image'] as String?;
          if (imageBase64 != null) {
            historyImages.add(base64Decode(imageBase64));
            historyMetadata.add(
              item['metadata'] != null ? NaiMetadata.fromJson(item['metadata']) : null,
            );
            historyFavorites.add(item['favorite'] ?? false);
            historyFilePaths.add(item['filePath'] as String?);
          }
        } catch (_) {
          // 손상된 항목 건너뛰기
        }
      }

      if (historyImages.isNotEmpty) {
        selectedHistoryIndex = historyImages.length - 1;
      }
      _fullSaveHistoryToLocal();
    }

    saveAllSettings();
    notifyListeners();

    // 복원한 토큰으로 곧바로 연결을 확인한다.
    //  이게 없으면 토큰은 들어왔는데 isApiConnected가 false로 남아
    //  "연결되지 않음"이 뜨고, 사용자가 앱을 다시 켜야 정상으로 보였다.
    if (apiToken.trim().isNotEmpty) {
      unawaited(
        fetchAnlas().then((_) {
          // 계정 목록도 함께 되살아났으므로 각 계정 상태를 갱신
          unawaited(refreshAllAccountQuotas(force: true));
        }),
      );
    }
  }

  Future<void> saveAllSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 입력창(controller)이 아니라 실제 사용 중인 토큰을 저장한다.
      //  계정 전환은 apiToken을 바꾸므로 controller가 낡아 있을 수 있다.
      await prefs.setString('api_token', apiToken);
      await prefs.setString('naiAccounts', jsonEncode(naiAccounts.map((e) => e.toJson()).toList()));
      await prefs.setInt('activeAccountIndex', activeAccountIndex);
      await prefs.setString('custom_file_name', customFileNameController.text);
      await prefs.setString('custom_width', customWidthController.text);
      await prefs.setString('custom_height', customHeightController.text);
      await prefs.setString('conditional_rules', conditionalRuleController.text);
      await prefs.setString('conditionalTriggerMode', conditionalTriggerMode);

      await prefs.setString('positive', positiveController.text);
      await prefs.setString('negative', negativeController.text);
      await prefs.setString('prefix', prefixController.text);
      await prefs.setString('suffix', suffixController.text);

      await prefs.setString('inpaint_pos', inpaintPositiveController.text);
      await prefs.setString('inpaint_neg', inpaintNegativeController.text);
      await prefs.setString('inpaint_prefix', inpaintPrefixController.text);
      await prefs.setString('inpaint_suffix', inpaintSuffixController.text);

      await prefs.setString('steps', stepsController.text);
      await prefs.setString('cfgScale', cfgScaleController.text);
      await prefs.setString('cfgRescale', cfgRescaleController.text);
      await prefs.setString('seed', seedController.text);
      await prefs.setString('gelbooru_inc', gelbooruIncludeController.text);
      await prefs.setString('gelbooru_exc', gelbooruExcludeController.text);
      await prefs.setString('gelbooru_api_input', gelbooruApiController.text);
      await prefs.setBool('rating_e', ratingE);
      await prefs.setBool('rating_q', ratingQ);
      await prefs.setBool('rating_s', ratingS);
      await prefs.setBool('rating_g', ratingG);
      await prefs.setBool('remove_char_traits', removeCharacteristics);
      await prefs.setBool('remove_clothes', removeClothes);
      await prefs.setBool('remove_clothing_events', removeClothingEvents);
      await prefs.setBool('remove_implied_tags', removeImpliedTags);
      await prefs.setBool('charRetapToggle', charRetapToggle);
      await prefs.setBool('saveFolderByDateOnly', saveFolderByDateOnly);
      await prefs.setBool('remove_colors', removeColors);
      await prefs.setString('custom_remove', customRemoveController.text);
      await prefs.setBool('auto_save', isAutoSave);
      await prefs.setBool('saveAsWebp', saveAsWebp);
      await prefs.setBool('webpLossy', webpLossy);
      await prefs.setBool('random_lock', isRandomLocked);
      await prefs.setBool('seedLocked', isSeedLocked);
      await prefs.setString('directorTool', directorTool);
      await prefs.setBool('expandNestedWeights', expandNestedWeightsEnabled);
      await prefs.setString('promptUndoHistory', jsonEncode(promptUndoHistory));
      await prefs.setBool('directorToolVisible', directorToolVisible);
      await prefs.setDouble('infillStrength', infillStrength);
      await prefs.setDouble('img2imgStrength', img2imgStrength);
      await prefs.setDouble('img2imgNoise', img2imgNoise);
      await prefs.setBool('variancePlus', isVariancePlus);
      await prefs.setBool('horizontalSwipeEnabled', horizontalSwipeEnabled);
      await prefs.setBool('promptAltLayout', promptAltLayout);
      await prefs.setBool('promptNewLayout', promptNewLayout);
      await prefs.setInt('gelbooruSearchPages', gelbooruSearchPages);
      await prefs.setBool('diversifySearchSort', diversifySearchSort);
      await prefs.setBool('promptCharDrawerEnabled', promptCharDrawerEnabled);
      await prefs.setBool('weightRulesEnabled', weightRulesEnabled);
      await prefs.setString('weightRules', weightRulesController.text);
      await prefs.setBool('historySlideEnabled', historySlideEnabled);
      await prefs.setBool('randomPromptAlphabetical', randomPromptAlphabetical);
      await prefs.setBool('ignoreRecommendedOrder', ignoreRecommendedOrder);
      await prefs.setBool('weightHighlight', weightHighlight);
      await prefs.setBool('e621Enabled', e621Enabled);
      await prefs.setBool('safCardOpen', safCardOpen);
      await prefs.setBool('fileCardOpen', fileCardOpen);
      await prefs.setInt('themeAccent', themeAccent);
      await prefs.setBool('i2iHistoryDisabled', i2iHistoryDisabled);
      await prefs.setBool('inpaintNoAutoSwitch', inpaintNoAutoSwitch);
      await prefs.setBool('inpaintAutoClearMask', inpaintAutoClearMask);
      await prefs.setBool('galleryModeEnabled', galleryModeEnabled);
      if (galleryCurrentPath != null) {
        await prefs.setString('galleryCurrentPath', galleryCurrentPath!);
      }
      await prefs.setInt('galleryColumns', galleryColumns);
      await prefs.setDouble('promptEditorFontSize', promptEditorFontSize);
      await prefs.setString('gallerySortMode', gallerySortMode);
      await prefs.setDouble('batchDelay', batchDelay);
      await prefs.setBool('autoNextPromptInBatch', autoNextPromptInBatch);
      await prefs.setBool('repeatSamePromptEnabled', repeatSamePromptEnabled);
      await prefs.setInt('repeatSamePromptCount', repeatSamePromptCount);
      await prefs.setBool('autoCheckUpdate', autoCheckUpdate);
      await prefs.setBool('historyTabEnabled', historyTabEnabled);
      await prefs.setBool('i2iTabEnabled', i2iTabEnabled);
      await prefs.setBool('i2iModeInpaintEnabled', i2iModeInpaintEnabled);
      await prefs.setBool('i2iModeMosaicEnabled', i2iModeMosaicEnabled);
      await prefs.setBool('i2iModeImg2imgEnabled', i2iModeImg2imgEnabled);
      await prefs.setBool('i2iModeUpscaleEnabled', i2iModeUpscaleEnabled);
      await prefs.setBool('characterTabEnabled', characterTabEnabled);
      await prefs.setBool('useCharacterPosition', useCharacterPosition);
      await prefs.setBool('charCanvasShowGrid', charCanvasShowGrid);
      await prefs.setBool('charCanvasSnap', charCanvasSnap);
      await prefs.setBool('charCanvasShowImage', charCanvasShowImage);
      await prefs.setInt('charGridCols', charGridCols);
      await prefs.setInt('charGridRows', charGridRows);
      await prefs.setBool('transparentBackground', transparentBackground);
      await prefs.setString('qualityTagsPreset', qualityTagsPreset);
      await prefs.setString('ucPreset', ucPreset);
      await prefs.setBool('randomCharacterOrder', randomCharacterOrder);
      await prefs.setBool('wildcardTabEnabled', wildcardTabEnabled);
      await prefs.setStringList('promptSectionOrder', promptSectionOrder);
      await prefs.setStringList('collapsedSections', collapsedSections.toList());
      await prefs.setStringList('hiddenPromptSections', hiddenPromptSections.toList());
      await prefs.setStringList('pinnedPromptSections', pinnedPromptSections.toList());
      await prefs.setBool('conditionalGuideCollapsed', conditionalGuideCollapsed);
      await prefs.setStringList('collapsedI2iPrompts', collapsedI2iPrompts.toList());
      await prefs.setStringList('collapsedSettingGroups', collapsedSettingGroups.toList());
      await prefs.setBool('useGelbooruApiKey', useGelbooruApiKey);
      await prefs.setString('resolutionMode', resolutionMode);
      await prefs.setString('model', selectedModel);
      await prefs.setString('modelSettingProfiles', jsonEncode(modelSettingProfiles));
      await prefs.setString('sampler', selectedSampler);
      await prefs.setString('scheduler', selectedScheduler);
      await prefs.setString('resolution', selectedResolution);
      await prefs.setDouble('resolutionScale', resolutionScale);
      await prefs.setStringList('customResolutions', customResolutions);
      await prefs.setString('characters', jsonEncode(characters.map((e) => e.toJson()).toList()));
      await prefs.setString('wildcards', jsonEncode(wildcards.map((e) => e.toJson()).toList()));
      // 프리셋은 썸네일(base64)을 품고 있어 prefs에 두면 수백 KB가 된다 → 파일로 저장
      unawaited(savePresetsToFile());
      await prefs.setStringList('gelbooruPrompts', gelbooruPrompts);
      await prefs.setInt('currentPromptIndex', currentPromptIndex);

      // 설정 백업 파일 저장 (SharedPreferences 손실 방지)
      await _saveSettingsBackup();
    } catch (e) {
      debugPrint("설정 저장 실패: $e");
    }
  }

  // ============================================================================
  // 설정 백업/복구 (SharedPreferences 손실 방지)
  // ============================================================================
  Future<void> _saveSettingsBackup() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/settings_backup.json');
      // exportSettings에서 히스토리 제외 (용량 절약 + 빠른 저장)
      final data = await exportSettings(includeHistory: false);
      data['backup_time'] = DateTime.now().toIso8601String();
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // 자동 백업 실패는 알리지 않는다.
      // 설정은 이미 SharedPreferences 에 저장돼 있고, 이건 그 사본일 뿐이다.
      // 저장 공간이 부족할 때 매번 알림이 뜨면 오히려 방해가 된다.
    }
  }

  Future<bool> tryRecoverFromBackup() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/settings_backup.json');
      if (!file.existsSync()) {
        // 구버전 호환: 예전 임시 디렉토리 백업도 확인
        final tmpDir = await getTemporaryDirectory();
        final tmpFile = File('${tmpDir.path}/settings_backup.json');
        if (!tmpFile.existsSync()) {
          return false;
        }
        final tmpData = jsonDecode(await tmpFile.readAsString()) as Map<String, dynamic>;
        importSettings(tmpData);
        debugPrint("임시 디렉토리 백업에서 복구 성공");
        return true;
      }

      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // importSettings로 전부 복원 (히스토리는 별도 로컬 저장소에서 복구)
      importSettings(data);
      debugPrint("설정 백업에서 복구 성공 (백업 시간: ${data['backup_time'] ?? '알 수 없음'})");
      return true;
    } catch (e) {
      debugPrint("백업 복구 실패: $e");
      return false;
    }
  }

  void refreshUI() => notifyListeners();

  // ── 공식 프리셋 적용 ──
  //  NovelAI 웹이 자동으로 붙여 주는 태그를 우리도 똑같이 붙인다.
  //  · Quality Tags는 프롬프트 '뒤'에 (공식과 같은 위치)
  //  · UC 프리셋은 부정 프롬프트 '앞'에
  /// 인원수(1girl · 2boys · 1other …)와 solo 를 프롬프트 '맨 앞'으로 옮긴다.
  ///
  /// NovelAI 는 인원수를 모든 프롬프트의 맨 앞에 두기를 권장한다.
  /// 예전엔 그 자리를 지키려고 선행 프롬프트를 계속 고쳐야 했는데,
  /// 이제 긍정·선행·후행 어디에 써도 보낼 때 알아서 맨 앞으로 모은다.
  ///
  ///  'masterpiece, smile, 1girl, solo'  →  '1girl, solo, masterpiece, smile'
  ///
  /// 건드리지 않는 경우:
  ///  · 가중치 구간 안의 태그 (5.0::1girl, smile :: 처럼) — 빼 내면 가중치가 바뀐다
  ///  · 괄호로 강조한 태그 ({1girl}) — 사용자가 일부러 꾸민 것
  ///  · 'NovelAI 권장 순서 무시' 가 켜져 있을 때
  ///
  /// 같은 태그가 여러 번 나오면 하나만 남긴다.
  /// 입력창 내용은 바꾸지 않는다 — 보내는 프롬프트에만 적용된다.
  String _hoistCountTags(String text) {
    if (ignoreRecommendedOrder || text.trim().isEmpty) {
      return text;
    }
    final persons = <String>[];
    final solos = <String>[];
    final seen = <String>{};
    final rest = <String>[];
    // NovelAI 의 가중치는 '평면'이다: N:: 로 열리고 숫자 없는 :: 에서 전부 닫힌다
    bool inWeight = false;
    final marker = RegExp(r'(-?\d+(?:\.\d+)?)\s*::|::');

    for (final piece in text.split(',')) {
      final core = piece.trim();
      final low = core.toLowerCase();
      final plain = core.isNotEmpty && !piece.contains('::') && !core.contains(RegExp(r'[{}\[\]]'));
      final isPerson = _personTag.hasMatch(low) || _multiplePersonTags.contains(low);
      final isSolo = low == 'solo' || low == 'solo focus';

      if (plain && !inWeight && (isPerson || isSolo)) {
        if (seen.add(low)) {
          (isPerson ? persons : solos).add(core);
        }
        // 원래 자리에서는 뺀다 (중복도 함께 사라진다)
      } else {
        rest.add(piece);
      }
      // 이 조각이 가중치 구간을 열거나 닫는지 반영
      for (final m in marker.allMatches(piece)) {
        inWeight = m.group(1) != null;
      }
    }

    if (persons.isEmpty && solos.isEmpty) {
      return text; // 옮길 것이 없으면 원문 그대로 (서식을 건드리지 않는다)
    }
    final head = [...persons, ...solos].join(', ');
    // 앞에서 뺀 자리에 남은 쉼표·공백을 정리한다
    final tail = rest.join(',').replaceFirst(RegExp(r'^[\s,]+'), '');
    return tail.isEmpty ? head : '$head, $tail';
  }

  static final RegExp _personTag = RegExp(r'^\d+\+?\s?(girl|girls|boy|boys|other|others)$');
  static const Set<String> _multiplePersonTags = {
    'multiple girls',
    'multiple boys',
    'multiple others',
  };

  String applyQualityTags(String prompt) {
    final opt = NaiPresets.find(NaiPresets.qualityFor(selectedModel), qualityTagsPreset);
    if (opt.tags.isEmpty) {
      return prompt;
    }
    if (prompt.trim().isEmpty) {
      return opt.tags;
    }
    return '$prompt, ${opt.tags}';
  }

  String applyUcPreset(String negative) {
    final opt = NaiPresets.find(NaiPresets.ucFor(selectedModel), ucPreset);
    if (opt.tags.isEmpty) {
      return negative; // None — 프리셋을 껐으므로 nsfw도 붙이지 않는다
    }

    // 공식은 프리셋 맨 앞에 nsfw를 함께 넣는다.
    //  단, 긍정 프롬프트에 nsfw가 있으면 서로 상쇄되므로 빼 준다.
    final positiveAll = [
      prefixController.text,
      positiveController.text,
      suffixController.text,
      for (final c in characters)
        if (c.isActive) c.positive,
    ].join(', ').toLowerCase();
    final wantsNsfw = RegExp(r'(^|[,\s{[])nsfw($|[,\s}\]])').hasMatch(positiveAll);

    final preset = wantsNsfw ? opt.tags : 'nsfw, ${opt.tags}';
    if (negative.trim().isEmpty) {
      return preset;
    }
    return '$preset, $negative';
  }

  // 설정 저장 디바운스.
  //  saveAllSettings는 prefs에 100여 개를 쓰므로(수십 ms) 타이핑마다 부르면 버벅인다.
  //  입력이 멈춘 뒤 한 번만 저장한다.
  Timer? _saveSettingsDebounce;

  void saveAllSettingsDebounced({int ms = 500}) {
    _saveSettingsDebounce?.cancel();
    _saveSettingsDebounce = Timer(Duration(milliseconds: ms), () {
      saveAllSettings();
    });
  }

  // ============================================================================
  // 프리셋용 설정 스냅샷
  // ============================================================================
  Map<String, dynamic> getSettingsSnapshot() {
    return {
      'steps': stepsController.text,
      'cfg': cfgScaleController.text,
      'cfgRescale': cfgRescaleController.text,
      'seed': seedController.text,
      'sampler': selectedSampler,
      'scheduler': selectedScheduler,
      'model': selectedModel,
      'resolution': selectedResolution,
      'seedLocked': isSeedLocked,
      'variancePlus': isVariancePlus,
      // 공식 프리셋 — 프롬프트 스타일의 일부라 프리셋에 함께 담는다
      'qualityTagsPreset': qualityTagsPreset,
      'ucPreset': ucPreset,
    };
  }

  void applySettingsSnapshot(Map<String, dynamic> s) {
    if (s['steps'] != null) {
      stepsController.text = s['steps'];
    }
    if (s['cfg'] != null) {
      cfgScaleController.text = s['cfg'];
    }
    if (s['cfgRescale'] != null) {
      cfgRescaleController.text = s['cfgRescale'];
    }
    if (s['seed'] != null) {
      seedController.text = s['seed'];
    }
    if (s['sampler'] != null) {
      selectedSampler = s['sampler'];
    }
    if (s['scheduler'] != null) {
      selectedScheduler = s['scheduler'];
    }
    if (s['model'] != null) {
      selectedModel = s['model'];
    }
    if (s['resolution'] != null) {
      selectedResolution = s['resolution'];
    }
    if (s['seedLocked'] != null) {
      isSeedLocked = s['seedLocked'];
    }
    if (s['variancePlus'] != null) {
      isVariancePlus = s['variancePlus'];
    }
    if (s['qualityTagsPreset'] != null) {
      qualityTagsPreset = s['qualityTagsPreset'];
    }
    if (s['ucPreset'] != null) {
      ucPreset = s['ucPreset'];
    }
  }

  void sendToI2i(Uint8List imageBytes, NaiMetadata? metadata) {
    i2iMaskActionOnChange = I2iMaskAction.clearMask; // 보내기는 항상 마스킹 초기화
    targetI2iImage = imageBytes;
    targetI2iMetadata = metadata;
    recordI2iView(imageBytes, metadata, reset: true); // 본 이미지 기록 새로 시작
    // i2i 탭이 꺼져 있으면 자동으로 켜기.
    // setI2iTabEnabled를 거쳐야 "모드가 전부 꺼져 있던 경우 모드 복구"까지 함께 처리된다.
    if (!i2iTabEnabled) {
      setI2iTabEnabled(true);
    }
    // 릴이 켜져 있으면 보낸 원본도 릴에 추가 (작업 후 원본으로 복귀 가능하게).
    // 릴이 꺼져 있으면(=히스토리 모드) 보낸 이미지는 추가하지 않음 (히스토리에 따로 있음).
    if (!i2iHistoryDisabled) {
      addI2iResult(imageBytes, metadata, source: 'origin');
    }
    notifyListeners();
  }

  // {A|B|C} 형식 → ~A, ~B, ~C (OR 검색)
  // *keyword 형식 → 해당 키워드가 포함된 태그들을 OR 검색 (상위 20개)
  String _expandWildcardForSearch(String input) {
    // 1단계: {A|B|C} → ~A, ~B, ~C
    String result = input.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
      final options = match.group(1)!.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty);
      return options.map((o) => '~$o').join(', ');
    });

    // 2단계: *keyword → ~tag1, ~tag2, ... (태그 DB에서 매칭)
    final tags = result.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    List<String> expanded = [];

    for (final tag in tags) {
      if (tag.startsWith('*') && tag.length > 1) {
        final keyword = tag.substring(1).toLowerCase().replaceAll(' ', '_');
        final matches = danbooruTags
            .where((t) => t.contains(keyword))
            .take(20)
            .map((t) => '~${t.replaceAll('_', ' ')}')
            .toList();
        if (matches.isNotEmpty) {
          expanded.addAll(matches);
        } else {
          expanded.add(keyword.replaceAll('_', ' '));
        }
      } else {
        expanded.add(tag);
      }
    }

    return expanded.join(', ');
  }

  // 제외 태그 확장 (~ 없이, 로컬 필터링용)
  List<String> _expandExcludeForSearch(String input) {
    List<String> result = [];

    // {A|B|C} → A, B, C (전부 제외 대상)
    String flattened = input.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
      return match.group(1)!.split('|').map((e) => e.trim()).join(', ');
    });

    final tags = flattened.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    for (final tag in tags) {
      if (tag.startsWith('*') && tag.length > 1) {
        final keyword = tag.substring(1).toLowerCase().replaceAll(' ', '_');
        final matches = danbooruTags
            .where((t) => t.contains(keyword))
            .take(50) // 제외는 넉넉하게 50개
            .toList();
        if (matches.isNotEmpty) {
          result.addAll(matches);
        } else {
          result.add(keyword);
        }
      } else {
        result.add(tag.replaceAll(' ', '_'));
      }
    }

    return result;
  }

  Future<void> handleGelbooruSearch(BuildContext context) async {
    isGelbooruLoading = true;
    gelbooruPrompts.clear();
    gelbooruTotal = 0;
    gelbooruRemaining = 0;
    currentPromptIndex = 0;
    gelbooruSearchDone = 0;
    gelbooruSearchTotal = 0;
    gelbooruSearchStage = "";
    notifyListeners();

    parseGelbooruApi();

    try {
      // 포함: {A|B} → ~A, ~B / *keyword → 매칭 태그 OR
      final expandedInclude = _expandWildcardForSearch(gelbooruIncludeController.text);
      // 제외: 로컬 후처리용 (API 태그 제한 회피 + 정확한 필터링)
      final localExcludeTags = _expandExcludeForSearch(gelbooruExcludeController.text);
      debugPrint("🔍 검색: $expandedInclude / 제외(${localExcludeTags.length}개): $localExcludeTags");

      List<String> results = await _service.fetchDanbooruTags(
        includeTags: expandedInclude,
        excludeTags: '', // API에 제외 태그 안 보냄
        localExcludeTags: localExcludeTags, // 로컬 후처리
        rG: ratingG,
        rS: ratingS,
        rQ: ratingQ,
        rE: ratingE,
        // 의상/특징 제거는 검색 결과엔 적용하지 않음 (원본 보존).
        // '다음 프롬프트'/'다시 불러오기' 시 _processAndSetPrompt에서 토글에 따라 걸러진다.
        removeCharacteristics: false,
        removeClothes: false,
        gelbooruUserId: gelbooruUserId,
        gelbooruApiKey: gelbooruApiKey,
        // API 키가 있을 때만 사용자 지정 페이지 수 적용 (없으면 서비스 기본값 사용)
        maxPagesToFetch: gelbooruApiKey.isNotEmpty ? gelbooruSearchPages : 20,
        diversifySort: diversifySearchSort,
        onProgress: (done, total, found) {
          gelbooruSearchDone = done;
          gelbooruSearchTotal = total;
          // '검색 : N' / '남음 : N'이 검색 중에도 점점 차오르도록 실시간 반영
          // (최종 정확한 값은 검색 완료 시 결과 개수로 다시 확정됨)
          gelbooruTotal = found;
          gelbooruRemaining = found;
          notifyListeners();
        },
        onStage: (stage) {
          gelbooruSearchStage = stage;
          notifyListeners();
        },
      );
      isGelbooruLoading = false;
      gelbooruSearchDone = 0;
      gelbooruSearchTotal = 0;
      gelbooruSearchStage = "";

      if (!context.mounted) {
        return;
      }

      if (results.isNotEmpty) {
        results.shuffle();
        gelbooruPrompts = results;
        gelbooruTotal = results.length;
        gelbooruRemaining = gelbooruTotal;
        saveAllSettings();
      } else {
        _showSearchErrorDialog(
          context,
          "조건에 맞는 결과가 없습니다.",
          "포함 태그: ${gelbooruIncludeController.text}\n\n"
              "가능한 원인:\n"
              "• 태그 조합에 맞는 이미지가 없음\n"
              "• 레이팅 필터가 너무 제한적\n"
              "• 태그 이름 오타 확인",
        );
      }
    } catch (e) {
      isGelbooruLoading = false;
      gelbooruSearchDone = 0;
      gelbooruSearchTotal = 0;
      gelbooruSearchStage = "";
      // 실시간으로 차오르던 카운트도 리셋 (실패 시 실제 프롬프트는 없음)
      gelbooruTotal = 0;
      gelbooruRemaining = 0;
      if (!context.mounted) {
        return;
      }

      String errorMsg = e.toString().replaceFirst('Exception: ', '');
      String title;
      String detail;

      if (errorMsg.contains('__NO_RESULTS__')) {
        // 순수하게 검색 결과 0개 (에러 아님, 검색 범위 문제)
        title = "검색 결과 없음";
        detail =
            "조건에 맞는 이미지를 찾지 못했어요.\n\n"
            "포함 태그: ${gelbooruIncludeController.text}\n\n"
            "💡 검색 범위를 넓혀보세요:\n"
            "• 태그 수를 줄이기 (너무 구체적이면 결과가 적어요)\n"
            "• 레이팅 필터 확인 (G/S/Q/E)\n"
            "• 제외 태그가 너무 많은지 확인\n"
            "• 태그 철자 확인\n\n"
            "조건을 조정한 뒤 다시 검색해주세요.";
      } else if (errorMsg.contains('429') || errorMsg.contains('요청 과다')) {
        title = "요청이 너무 많습니다 (429)";
        detail =
            "짧은 시간에 검색을 너무 많이 했어요.\n\n$errorMsg\n\n"
            "💡 잠시(10~30초) 기다린 뒤 다시 검색해주세요.\n"
            "API 키를 설정하면 한도가 늘어납니다.";
      } else if (errorMsg.contains('시간 초과')) {
        title = "서버 응답 없음";
        detail =
            "Gelbooru 서버가 응답하지 않습니다.\n\n$errorMsg\n\n"
            "가능한 원인:\n"
            "• Gelbooru 서버 점검/장애\n"
            "• 인터넷 연결 불안정\n"
            "• 프록시 서버 문제";
      } else if (errorMsg.contains('서버 오류')) {
        title = "서버 오류";
        detail =
            "Gelbooru 서버에서 오류가 발생했습니다.\n\n$errorMsg\n\n"
            "💡 서버가 불안정할 수 있어요. 잠시 후 다시 시도해주세요.";
      } else if (errorMsg.contains('요청 오류')) {
        title = "요청 오류";
        detail =
            "요청에 문제가 있습니다.\n\n$errorMsg\n\n"
            "가능한 원인:\n"
            "• API 키 오류 (설정 탭에서 확인)\n"
            "• 태그 형식 오류";
      } else if (errorMsg.contains('연결 실패') || errorMsg.contains('SocketException')) {
        title = "연결 실패";
        detail =
            "서버에 연결할 수 없습니다.\n\n$errorMsg\n\n"
            "가능한 원인:\n"
            "• 인터넷 연결 끊김\n"
            "• 방화벽/VPN 차단\n"
            "• 프록시 서버 다운";
      } else {
        title = "검색 실패";
        detail = "알 수 없는 오류가 발생했습니다.\n\n$errorMsg";
      }

      _showSearchErrorDialog(context, title, detail);
    }
    notifyListeners();
  }

  void _showSearchErrorDialog(BuildContext context, String title, String detail) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 24),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            detail,
            style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              "확인",
              style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  String _sortNovelAIPrompt(String prompt) {
    List<String> tags = prompt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    // NovelAI 권장 순서 무시: 그룹 분류 없이 전체 처리
    if (ignoreRecommendedOrder) {
      if (randomPromptAlphabetical) {
        // 알파벳 순서
        tags.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      } else {
        // 랜덤 섞기
        tags.shuffle();
      }
      return tags.join(', ');
    }

    List<String> gPerson = []; // 1. 인원수 (1girl, 2boys)
    List<String> gSolo = []; // 2. solo 계열
    List<String> gFrom = []; // 3. 시점 (from ~)
    List<String> gLooking = []; // 4. 시선 (looking ~)
    List<String> gComposition = []; // 5. 신체 구도/시점
    List<String> gRest = []; // 6. 나머지 (알파벳 정렬 대상)
    List<String> gBackground = []; // 7. 배경

    final personRegex = RegExp(r'^(\d+|\d+\+)\s?(girl|girls|boy|boys)$');

    // 신체 구도/시점 태그 (맨 앞쪽 고정)
    const compositionTags = {
      'full body',
      'upper body',
      'lower body',
      'cowboy shot',
      'portrait',
      'close-up',
      'feet out of frame',
      'wide shot',
      'dutch angle',
      'straight-on',
      'pov',
    };

    for (String tag in tags) {
      String lowerTag = tag.toLowerCase();

      if (personRegex.hasMatch(lowerTag) ||
          lowerTag == 'multiple girls' ||
          lowerTag == 'multiple boys') {
        gPerson.add(tag);
      } else if (lowerTag == 'solo' || lowerTag == 'solo focus') {
        gSolo.add(tag);
      } else if (lowerTag.startsWith('from ')) {
        gFrom.add(tag);
      } else if (lowerTag.startsWith('looking ')) {
        gLooking.add(tag);
      } else if (compositionTags.contains(lowerTag)) {
        gComposition.add(tag);
      } else if (lowerTag.contains('background')) {
        gBackground.add(tag);
      } else {
        gRest.add(tag);
      }
    }

    // 알파벳 순서 옵션이 켜져있으면 나머지 그룹만 정렬 (고정 그룹은 제외)
    if (randomPromptAlphabetical) {
      gRest.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    List<String> sortedTags = [
      ...gPerson,
      ...gSolo,
      ...gFrom,
      ...gLooking,
      ...gComposition,
      ...gRest,
      ...gBackground,
    ];
    return sortedTags.join(', ');
  }

  void _processAndSetPrompt(int targetIndex) {
    if (gelbooruPrompts.isEmpty) {
      return;
    }
    String nextRawData = gelbooruPrompts[targetIndex];
    String tagString = "";
    String rating = "g";

    try {
      Map<String, dynamic> parsed = jsonDecode(nextRawData);
      tagString = parsed['tags'] ?? "";
      currentImageWidth = parsed['width'] ?? 0;
      currentImageHeight = parsed['height'] ?? 0;
      rating = parsed['rating']?.toString() ?? "g";
      // Gelbooru는 "general", "sensitive", "questionable", "explicit" 풀 단어를 반환
      // 조건부 트리거에서 g/s/q/e 단일 문자로 비교하므로 정규화
      if (rating.length > 1) {
        rating = rating.substring(0, 1);
      }
    } catch (e) {
      tagString = nextRawData;
      currentImageWidth = 0;
      currentImageHeight = 0;
      rating = "g";
    }

    tagString = tagString
        .replaceAll('&#39;', "'")
        .replaceAll('&#039;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');

    List<String> rawTags = tagString.split(',').map((e) => e.trim()).toList();
    List<String> customRules = customRemoveController.text
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    List<String> cleanTags = [];

    // 중복(함의) 태그 정리 — 먼저 전체를 훑어 '지울 상위 태그'를 모은다.
    //  예: "plaid skirt"가 있으면 "skirt"를 지운다.
    //  ⚠️ 값이 또 다른 키일 수 있어(american flag skirt → print skirt → skirt)
    //     사슬을 끝까지 따라가야 한다. 계산은 매우 가볍다(0.002ms 수준).
    final Set<String> impliedToRemove = {};
    if (removeImpliedTags) {
      final stack = <String>[];
      for (final t in rawTags) {
        final key = t.replaceAll('_', ' ').toLowerCase();
        if (TagFilters.tagImplications.containsKey(key)) {
          stack.add(key);
        }
      }
      final visited = <String>{};
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        for (final parent in TagFilters.tagImplications[cur] ?? const <String>[]) {
          if (!visited.add(parent)) {
            continue;
          }
          impliedToRemove.add(parent);
          if (TagFilters.tagImplications.containsKey(parent)) {
            stack.add(parent);
          }
        }
      }
      // 여기서 별도 보호는 하지 않는다.
      //  impliedToRemove에는 '다른 태그가 함의하는 상위 태그'만 들어 있으므로,
      //  그 자체가 키여도(american flag skirt → print skirt → skirt) 중복이 맞다.
      //  프롬프트에 단독으로 있는 태그는 애초에 이 집합에 들어오지 않는다.
    }

    for (String t in rawTags) {
      String cleanTag = t.replaceAll('_', ' ');
      if (t.contains('(') || t.contains(')')) {
        continue;
      }
      // 작가/캐릭터/작품 '이름' 백스톱: 검색 단계에서 카테고리 조회가 실패했거나(429/오프라인)
      // 과거에 저장된 프롬프트에 이름이 남아있는 경우를 여기서 최종 차단
      // (정적 사전 + 에셋 사전 + 패턴 안전장치를 isNameTag 하나로 통일)
      final String underscored = cleanTag.replaceAll(' ', '_');
      if (TagFilters.isNameTag(underscored)) {
        continue;
      }
      if (TagFilters.commonGarbage.contains(t) || TagFilters.commonGarbage.contains(cleanTag)) {
        continue;
      }
      if (removeCharacteristics &&
          (TagFilters.characterTraits.contains(t) ||
              TagFilters.characterTraits.contains(cleanTag))) {
        continue;
      }
      if (removeClothes &&
          (TagFilters.clothesTags.contains(t) || TagFilters.clothesTags.contains(cleanTag))) {
        continue;
      }
      // 중복(함의) 태그 — 더 구체적인 태그가 이미 있으므로 이건 지운다
      if (removeImpliedTags && impliedToRemove.contains(cleanTag.toLowerCase())) {
        continue;
      }
      // 의상 상태/동작 (unworn, torn, grab 등) — 의상 제거와 짝으로 쓰면 옷 관련이 깔끔히 정리된다
      if (removeClothingEvents &&
          (TagFilters.clothingEventTags.contains(t) ||
              TagFilters.clothingEventTags.contains(cleanTag))) {
        continue;
      }
      if (removeColors) {
        bool hasColor = false;
        for (final keyword in TagFilters.colorKeywords) {
          if (cleanTag.contains(keyword) || t.contains(keyword)) {
            hasColor = true;
            break;
          }
        }
        if (hasColor) {
          continue;
        }
      }

      bool shouldRemove = false;
      for (String rule in customRules) {
        if (rule.startsWith('*') && rule.endsWith('*') && rule.length > 2) {
          if (t.contains(rule.substring(1, rule.length - 1))) {
            shouldRemove = true;
          }
        } else if (rule.startsWith('*') && rule.length > 1) {
          if (t.endsWith(rule.substring(1))) {
            shouldRemove = true;
          }
        } else if (rule.endsWith('*') && rule.length > 1) {
          if (t.startsWith(rule.substring(0, rule.length - 1))) {
            shouldRemove = true;
          }
        } else {
          if (t == rule || cleanTag == rule) {
            shouldRemove = true;
          }
        }
      }
      if (shouldRemove) {
        continue;
      }
      cleanTags.add(t);
    }

    String prefixText = prefixController.text;
    String suffixText = suffixController.text;
    List<String> fixedTags = "$prefixText,$suffixText"
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();

    List<String> filteredTags = cleanTags
        .where((tag) => !fixedTags.contains(tag.toLowerCase()))
        .toList();

    String combined = filteredTags.join(', ');

    // 조건부 트리거가 "random" 모드일 때만 여기서 적용
    String finalConditioned = conditionalTriggerMode == "random"
        ? _applyConditionalRules(combined, rating)
        : combined;
    String finalSorted = _sortNovelAIPrompt(finalConditioned);

    positiveController.text = finalSorted;
  }

  void handleNextPrompt() {
    if (gelbooruPrompts.isEmpty) {
      return;
    }
    _processAndSetPrompt(currentPromptIndex);
    currentPromptIndex = (currentPromptIndex + 1) % gelbooruPrompts.length;
    gelbooruRemaining = gelbooruPrompts.length - currentPromptIndex;
    if (gelbooruRemaining == 0) {
      gelbooruRemaining = gelbooruPrompts.length;
    }
    saveAllSettings();
    notifyListeners();
  }

  void reloadCurrentPrompt() {
    if (gelbooruPrompts.isEmpty) {
      return;
    }
    int targetIndex = currentPromptIndex - 1;
    if (targetIndex < 0) {
      targetIndex = gelbooruPrompts.length - 1;
    }
    _processAndSetPrompt(targetIndex);
    saveAllSettings();
    notifyListeners();
  }

  // 순차 생성 <A|B|C>: 생성마다 다음 옵션을 순서대로 선택 (중첩 지원)
  // 카운터 키 = "경로/내용해시" → 중첩 시 실제 도달한 <>만 증가, 위치 무관하게 안정적.
  // 중첩 예: <A|<B|C>|D> → A → B → D → A → C → D (각 <> 독립 카운트)

  // 최상위 | 로 분리 (<> 안의 | 은 무시)
  // 최상위 | 로 분리 (<< >> 안의 | 은 무시)
  List<String> _splitTopPipe(String s) {
    final parts = <String>[];
    int depth = 0;
    final buf = StringBuffer();
    int i = 0;
    while (i < s.length) {
      if (i + 1 < s.length && s[i] == '<' && s[i + 1] == '<') {
        depth++;
        buf.write('<<');
        i += 2;
      } else if (i + 1 < s.length && s[i] == '>' && s[i + 1] == '>') {
        depth--;
        buf.write('>>');
        i += 2;
      } else if (s[i] == '|' && depth == 0) {
        parts.add(buf.toString().trim());
        buf.clear();
        i++;
      } else {
        buf.write(s[i]);
        i++;
      }
    }
    if (buf.toString().trim().isNotEmpty) {
      parts.add(buf.toString().trim());
    }
    return parts.where((e) => e.isNotEmpty).toList();
  }

  // 순차 처리 (재귀, 바깥 <<>>부터). path = 카운터 식별 경로.
  String _processSequentialRec(String text, String path) {
    final result = StringBuffer();
    int i = 0;
    int seqIdx = 0;
    while (i < text.length) {
      if (i + 1 < text.length && text[i] == '<' && text[i + 1] == '<') {
        // 매칭되는 >> 찾기 (중첩 깊이 고려)
        int depth = 1;
        int j = i + 2;
        while (j < text.length && depth > 0) {
          if (j + 1 < text.length && text[j] == '<' && text[j + 1] == '<') {
            depth++;
            j += 2;
          } else if (j + 1 < text.length && text[j] == '>' && text[j + 1] == '>') {
            depth--;
            j += 2;
          } else {
            j++;
          }
        }
        // 닫는 >>가 없으면(depth>0) 순차 문법이 아님 → '<'를 그대로 출력하고 진행
        if (depth > 0) {
          result.write(text[i]);
          i++;
          continue;
        }
        final inner = text.substring(i + 2, j - 2);
        final opts = _splitTopPipe(inner);
        if (opts.isEmpty) {
          // 빈 <<>> → 제거
        } else if (opts.length == 1) {
          result.write(_processSequentialRec(opts[0], "$path/$seqIdx"));
        } else {
          // 이 <<>>의 카운터 키 (경로 + 내용)
          final key = "$path/$seqIdx:$inner";
          final idx = _sequentialCounters[key] ?? 0;
          final chosen = opts[idx % opts.length];
          // 선택된 옵션 안에 또 <<>>가 있으면 재귀
          result.write(_processSequentialRec(chosen, key));
        }
        seqIdx++;
        i = j;
      } else {
        result.write(text[i]);
        i++;
      }
    }
    return result.toString();
  }

  String _processSequential(String prompt) {
    return _processSequentialRec(prompt, "");
  }

  // 순차 와일드카드(@) 카운터 전진. 프롬프트의 __@이름__ 등장 순서대로 +1.
  void _advanceSequentialWildcards(String prompt) {
    final regex = RegExp(r'__(@[^_]+?)__');
    int pos = 0;
    for (final m in regex.allMatches(prompt)) {
      String body = m.group(1)!.substring(1); // @ 제거
      // :숫자 제거 (이름만 추출)
      final colonIdx = body.lastIndexOf(':');
      if (colonIdx != -1 && int.tryParse(body.substring(colonIdx + 1)) != null) {
        body = body.substring(0, colonIdx);
      }
      final key = "wc@$pos:$body";
      _sequentialCounters[key] = (_sequentialCounters[key] ?? 0) + 1;
      pos++;
    }
  }

  // 순차 카운터 전진: 이번 생성에서 실제로 "도달한" <<>>만 +1 (중첩 정확성)
  void _advanceSequential(String prompt) {
    final evaluated = <String>[];
    void walk(String text, String path) {
      int i = 0;
      int seqIdx = 0;
      while (i < text.length) {
        if (i + 1 < text.length && text[i] == '<' && text[i + 1] == '<') {
          int depth = 1;
          int j = i + 2;
          while (j < text.length && depth > 0) {
            if (j + 1 < text.length && text[j] == '<' && text[j + 1] == '<') {
              depth++;
              j += 2;
            } else if (j + 1 < text.length && text[j] == '>' && text[j + 1] == '>') {
              depth--;
              j += 2;
            } else {
              j++;
            }
          }
          // 닫는 >>가 없으면 순차 문법이 아님 → 건너뜀
          if (depth > 0) {
            i++;
            continue;
          }
          final inner = text.substring(i + 2, j - 2);
          final opts = _splitTopPipe(inner);
          if (opts.length == 1) {
            walk(opts[0], "$path/$seqIdx");
          } else if (opts.isNotEmpty) {
            final key = "$path/$seqIdx:$inner";
            evaluated.add(key);
            final idx = _sequentialCounters[key] ?? 0;
            walk(opts[idx % opts.length], key);
          }
          seqIdx++;
          i = j;
        } else {
          i++;
        }
      }
    }

    walk(prompt, "");
    for (final k in evaluated) {
      _sequentialCounters[k] = (_sequentialCounters[k] ?? 0) + 1;
    }
  }

  String _processPipeOptions(String prompt) {
    // "a|b|c," → 셋 중 하나를 랜덤 선택. 쉼표 또는 줄끝 앞의 word|word 패턴 처리
    final RegExp pipeRegex = RegExp(r'([\w \t][^\n,|]*(?:\|[^\n,|]+)+)(?=[,\n]|$)');
    return prompt.replaceAllMapped(pipeRegex, (match) {
      final List<String> options = match
          .group(0)!
          .split('|')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (options.length < 2) {
        return match.group(0)!;
      }
      return options[Random().nextInt(options.length)];
    });
  }

  String _processWildcards(String prompt) {
    String result = _processPipeOptions(prompt);
    final RegExp regex = RegExp(r'__(.+?)__');
    int depth = 0;
    // 순차 와일드카드(@) 위치 카운터: 같은 패스 내 등장 순서별 독립
    int seqWildcardPos = 0;
    while (regex.hasMatch(result) && depth < 5) {
      result = result.replaceAllMapped(regex, (match) {
        String wName = match.group(1)!;

        // 순차 와일드카드 문법: @이름 또는 @이름:시작행
        // 예: @Cloth → 줄 순서대로, @Cloth:2 → 2번째 행부터 시작
        bool isSequential = false;
        int startOffset = 0;
        if (wName.startsWith('@')) {
          isSequential = true;
          String body = wName.substring(1); // @ 제거
          // :숫자 (시작 행) 파싱
          final colonIdx = body.lastIndexOf(':');
          if (colonIdx != -1) {
            final numStr = body.substring(colonIdx + 1);
            final parsed = int.tryParse(numStr);
            if (parsed != null && parsed >= 1) {
              startOffset = parsed - 1; // 2번째 행 = 인덱스 1
              body = body.substring(0, colonIdx);
            }
          }
          wName = body;
        }

        var wcList = wildcards.where((e) => e.name == wName);
        if (wcList.isEmpty) {
          return match.group(0)!;
        }

        List<String> options = wcList.first.content
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

        if (options.isEmpty) {
          return match.group(0)!;
        }

        // 순차 와일드카드: 줄 순서대로 (시작 오프셋 적용)
        if (isSequential) {
          // 카운터 키 = "wc@위치:이름" (같은 와일드카드 여러 번 쓰면 위치로 독립)
          final key = "wc@$seqWildcardPos:$wName";
          seqWildcardPos++;
          final counter = _sequentialCounters[key] ?? 0;
          final idx = (counter + startOffset) % options.length;
          // 가중치 문법(N)텍스트)이 있으면 텍스트만 추출
          String selected = options[idx];
          final wm = RegExp(r'^(\d+)\)(.*)$').firstMatch(selected);
          if (wm != null) {
            selected = wm.group(2)!.trim();
          }
          return selected;
        }

        List<Map<String, dynamic>> weightedOptions = [];
        int totalWeight = 0;
        final weightRegex = RegExp(r'^(\d+)\)(.*)$');

        for (String opt in options) {
          int weight = 100;
          String text = opt;
          final m = weightRegex.firstMatch(opt);
          if (m != null) {
            weight = int.tryParse(m.group(1)!) ?? 100;
            text = m.group(2)!.trim();
          }
          if (weight > 0 && text.isNotEmpty) {
            weightedOptions.add({'weight': weight, 'text': text});
            totalWeight += weight;
          }
        }

        if (weightedOptions.isEmpty) {
          return match.group(0)!;
        }

        int randomVal = Random().nextInt(totalWeight);
        int currentSum = 0;
        for (var item in weightedOptions) {
          currentSum += item['weight'] as int;
          if (randomVal < currentSum) {
            return item['text'] as String;
          }
        }
        return weightedOptions.last['text'] as String;
      });
      result = _processPipeOptions(result);
      depth++;
    }
    return result;
  }

  // ============================================================================
  // 조건부 트리거: 재귀 하강 파서 (중첩 괄호 지원)
  // 문법: expr = or_expr
  //        or_expr = and_expr ('|' and_expr)*
  //        and_expr = atom ('&' atom)*
  //        atom = '!' atom | '(' or_expr ')' | pattern
  // 예시: A&(B|C)&D = A 그리고 (B 또는 C) 그리고 D
  // ============================================================================
  bool _evaluateCondition(String condStr, List<String> tags, String rating) {
    final parser = _ConditionParser(condStr, tags, rating, this);
    return parser.parseOrExpr();
  }

  bool _matchAtom(String pattern, List<String> tags, String rating) {
    bool negate = pattern.startsWith('!');
    if (negate) {
      pattern = pattern.substring(1);
    }

    bool matched;
    if (pattern == 'g' || pattern == 's' || pattern == 'q' || pattern == 'e') {
      matched = (rating.toLowerCase() == pattern.toLowerCase());
    } else {
      matched = tags.any((tag) => _isMatch(tag, pattern));
    }

    return negate ? !matched : matched;
  }

  bool _isMatch(String tag, String pattern) {
    if (pattern.startsWith('*') && pattern.endsWith('*') && pattern.length > 2) {
      return tag.contains(pattern.substring(1, pattern.length - 1));
    } else if (pattern.startsWith('*') && pattern.length > 1) {
      return tag.endsWith(pattern.substring(1));
    } else if (pattern.endsWith('*') && pattern.length > 1) {
      return tag.startsWith(pattern.substring(0, pattern.length - 1));
    } else {
      return tag == pattern;
    }
  }

  // 조건부 트리거 규칙 텍스트 → (조건, 액션) 쌍 목록. 두 적용 함수가 공유하는 파서.
  // ⚠️ 적용 함수 2개는 '의도적으로' 별도 구현이다 (병합 금지):
  //  - _applyConditionalRules (random 모드): 단일 프롬프트에 적용, 마지막에 toSet() 중복 제거
  //  - _applyConditionalRulesSectioned (generate 모드): 선행/긍정/후행 경계 보존, 중복 제거 없음
  List<({String cond, String action})> _parseConditionalRules() {
    final List<({String cond, String action})> parsed = [];
    final rules = conditionalRuleController.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('#'))
        .toList();
    for (final ruleStr in rules) {
      if (!ruleStr.startsWith('(')) {
        continue;
      }
      // 매칭되는 닫는 괄호 찾기 (중첩 괄호 지원)
      int depth = 0;
      int sepIdx = -1;
      for (int i = 0; i < ruleStr.length; i++) {
        if (ruleStr[i] == '(') {
          depth++;
        } else if (ruleStr[i] == ')') {
          depth--;
          if (depth == 0) {
            if (i + 1 < ruleStr.length && ruleStr[i + 1] == ':') {
              sepIdx = i;
            }
            break;
          }
        }
      }
      if (sepIdx == -1) {
        continue;
      }
      parsed.add((cond: ruleStr.substring(1, sepIdx), action: ruleStr.substring(sepIdx + 2)));
    }
    return parsed;
  }

  String _applyConditionalRules(String prompt, String rating) {
    if (conditionalRuleController.text.trim().isEmpty) {
      return prompt;
    }
    List<String> tags = prompt.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    for (final rule in _parseConditionalRules()) {
      String condStr = rule.cond;
      String actionStr = rule.action;

      // 재귀 하강 파서로 조건 평가
      bool conditionMet = _evaluateCondition(condStr, tags, rating);

      if (conditionMet) {
        if (actionStr.startsWith('prefix=')) {
          String b = actionStr.substring(7).trim();
          if (!tags.contains(b)) {
            tags.insert(0, b);
          }
        } else if (actionStr.startsWith('suffix=')) {
          String b = actionStr.substring(7).trim();
          if (!tags.contains(b)) {
            tags.add(b);
          }
        } else if (actionStr.contains('^')) {
          int idx = actionStr.indexOf('^');
          String a = actionStr.substring(0, idx).trim();
          String b = actionStr.substring(idx + 1).trim();
          String literalA = a.replaceAll('*', '');
          String literalB = b.replaceAll('*', '');

          for (int i = 0; i < tags.length; i++) {
            if (_isMatch(tags[i], a)) {
              if (literalA.isNotEmpty) {
                tags[i] = tags[i].replaceAll(literalA, literalB);
              } else {
                tags[i] = b;
              }
            }
          }
        } else if (actionStr.contains('=')) {
          int eqIdx = actionStr.indexOf('=');
          String a = actionStr.substring(0, eqIdx).trim();
          String b = actionStr.substring(eqIdx + 1).trim();

          for (int i = 0; i < tags.length; i++) {
            if (_isMatch(tags[i], a)) {
              tags[i] = b;
            }
          }
        }
      }
    }
    return tags.toSet().join(', ');
  }

  // 프롬프트 조각 하나. 사용자가 넣은 앞뒤 여백(줄바꿈·들여쓰기)을 따로 들고 다닌다.
  //  조건부 규칙은 '내용'만 보고 판단·치환하고, 여백은 그대로 되돌려 준다.
  //  이렇게 해야 규칙이 걸리든 안 걸리든 사용자의 줄 구성이 유지된다.
  static List<({String lead, String core, String trail})> _splitPieces(String input) {
    final out = <({String lead, String core, String trail})>[];
    for (final raw in input.split(',')) {
      final core = raw.trim();
      if (core.isEmpty) {
        continue; // 내용 없는 조각은 버린다
      }
      final start = raw.indexOf(core);
      out.add((
        lead: raw.substring(0, start),
        core: core,
        trail: raw.substring(start + core.length),
      ));
    }
    return out;
  }

  // 조각들을 원래 여백 그대로 다시 잇는다. 내용이 빈 조각(규칙으로 지워진 것)은 뺀다.
  static String _joinPieces(List<({String lead, String core, String trail})> pieces) {
    final alive = pieces.where((p) => p.core.isNotEmpty).toList();
    if (alive.isEmpty) {
      return '';
    }
    final buf = <String>[];
    for (int i = 0; i < alive.length; i++) {
      final p = alive[i];
      // 맨 앞 조각의 선행 여백만 없앤다 (프롬프트가 빈 줄로 시작하지 않게)
      buf.add((i == 0 ? '' : p.lead) + p.core + p.trail);
    }
    return buf.join(',').trimRight();
  }

  // 규칙이 태그를 'A, B' 처럼 쉼표가 든 값으로 바꾸면, 그 조각은 더 이상
  // 태그 하나가 아니다. 그대로 두면 다음 규칙이 'A' 를 찾지 못해 건너뛰게 된다.
  //  예) (A&!B&...):A=A, B  와  (A&!E&...):A=A, E  를 함께 쓰면
  //      앞 규칙이 'A' 를 'A, B' 로 바꿔 버려 뒤 규칙의 조건(A)이 거짓이 됐다.
  // 그래서 치환 직후 쉼표가 생긴 조각을 다시 태그 단위로 쪼갠다.
  static void _resplitPieces(List<({String lead, String core, String trail})> list) {
    for (int i = 0; i < list.length; i++) {
      if (!list[i].core.contains(',')) {
        continue;
      }
      final p = list[i];
      final parts = p.core.split(',').where((e) => e.trim().isNotEmpty).toList();
      if (parts.length <= 1) {
        continue;
      }
      final replacement = <({String lead, String core, String trail})>[];
      for (int k = 0; k < parts.length; k++) {
        replacement.add((
          // 첫 조각만 원래 앞 여백을 물려받고, 나머지는 보통의 ", " 간격을 쓴다
          lead: k == 0 ? p.lead : ' ',
          core: parts[k].trim(),
          trail: k == parts.length - 1 ? p.trail : '',
        ));
      }
      list.replaceRange(i, i + 1, replacement);
      i += replacement.length - 1;
    }
  }

  // 생성 모드용: 선행+긍정+후행을 합쳐 조건 검사 후, 영역 경계를 보존하며 적용
  // - 조건 판정: 전체 합친 태그 기준
  // - 교체(^, =): 세 영역 모두 제자리
  // - prefix=결과: 긍정 프롬프트 맨 앞에 추가 (선행과 긍정 사이)
  // - suffix=결과: 긍정 프롬프트 맨 끝에 추가 (긍정과 후행 사이)
  ({String prefix, String positive, String suffix}) _applyConditionalRulesSectioned(
    String prefix,
    String positive,
    String suffix,
    String rating,
  ) {
    if (conditionalRuleController.text.trim().isEmpty) {
      return (prefix: prefix, positive: positive, suffix: suffix);
    }

    // 여백을 보존한 채 조각으로 나눈다 (줄바꿈이 살아남는 이유)
    final prefixTags = _splitPieces(prefix);
    final positiveTags = _splitPieces(positive);
    final suffixTags = _splitPieces(suffix);

    // prefix=로 추가될 태그(긍정 앞)와 suffix=로 추가될 태그(긍정 뒤)
    //  새로 넣는 태그는 원래 서식이 없으므로 ", " 로 붙인다.
    final positiveFront = <({String lead, String core, String trail})>[];
    final positiveBack = <({String lead, String core, String trail})>[];

    for (final rule in _parseConditionalRules()) {
      String condStr = rule.cond;
      String actionStr = rule.action;

      // 1. 조건 판정은 전체 합친 태그(선행+긍정+후행) 기준 — 내용만 본다
      List<String> allTags = [
        ...prefixTags,
        ...positiveFront,
        ...positiveTags,
        ...positiveBack,
        ...suffixTags,
      ].map((p) => p.core).where((e) => e.isNotEmpty).toList();
      bool conditionMet = _evaluateCondition(condStr, allTags, rating);
      if (!conditionMet) {
        continue;
      }

      if (actionStr.startsWith('prefix=')) {
        // 2. 긍정 프롬프트 맨 앞에 추가
        String b = actionStr.substring(7).trim();
        if (!allTags.contains(b) && !positiveFront.any((p) => p.core == b)) {
          positiveFront.add((lead: ' ', core: b, trail: ''));
        }
      } else if (actionStr.startsWith('suffix=')) {
        // 3. 긍정 프롬프트 맨 끝에 추가
        String b = actionStr.substring(7).trim();
        if (!allTags.contains(b) && !positiveBack.any((p) => p.core == b)) {
          positiveBack.add((lead: ' ', core: b, trail: ''));
        }
      } else if (actionStr.contains('^')) {
        int idx = actionStr.indexOf('^');
        String a = actionStr.substring(0, idx).trim();
        String b = actionStr.substring(idx + 1).trim();
        String literalA = a.replaceAll('*', '');
        String literalB = b.replaceAll('*', '');
        for (final list in [prefixTags, positiveTags, suffixTags]) {
          for (int i = 0; i < list.length; i++) {
            if (_isMatch(list[i].core, a)) {
              // 여백(lead/trail)은 그대로 두고 내용만 바꾼다
              final replaced = literalA.isNotEmpty
                  ? list[i].core.replaceAll(literalA, literalB)
                  : b;
              list[i] = (lead: list[i].lead, core: replaced, trail: list[i].trail);
            }
          }
        }
      } else if (actionStr.contains('=')) {
        int eqIdx = actionStr.indexOf('=');
        String a = actionStr.substring(0, eqIdx).trim();
        String b = actionStr.substring(eqIdx + 1).trim();
        for (final list in [prefixTags, positiveTags, suffixTags]) {
          for (int i = 0; i < list.length; i++) {
            if (_isMatch(list[i].core, a)) {
              list[i] = (lead: list[i].lead, core: b, trail: list[i].trail);
            }
          }
        }
      }

      // 이번 규칙이 'A, B' 같은 값을 넣었을 수 있다. 다음 규칙이 태그를 제대로
      // 찾을 수 있도록 매 규칙이 끝날 때마다 조각을 다시 태그 단위로 맞춘다.
      _resplitPieces(prefixTags);
      _resplitPieces(positiveTags);
      _resplitPieces(suffixTags);
    }

    // 긍정 = [prefix=추가분] + [원래 긍정] + [suffix=추가분]
    final finalPositive = [...positiveFront, ...positiveTags, ...positiveBack];

    return (
      prefix: _joinPieces(prefixTags),
      positive: _joinPieces(finalPositive),
      suffix: _joinPieces(suffixTags),
    );
  }

  // 가중치 규칙 적용: 사용자가 "태그=숫자"로 정의한 규칙에 따라
  // 프롬프트 안의 해당 태그를 NovelAI 가중치 문법(숫자::태그 ::)으로 감싼다.
  //  예) 규칙 "sleeping=0.5" → 프롬프트의 sleeping 을 "0.5::sleeping ::" 으로 치환
  //  - 한 줄에 규칙 하나, 줄 맨 앞에 # 이 있으면 그 줄은 건너뜀
  //  - 숫자는 음수/소수/1 이상 모두 허용 (NovelAI V4 numeric emphasis)
  // 프롬프트 내용에서 레이팅 글자 추출 (조건부 트리거 조건 판정용)
  String _ratingLetterOf(String source) {
    final lower = source.toLowerCase();
    if (lower.contains("explicit")) {
      return "e";
    }
    if (lower.contains("questionable")) {
      return "q";
    }
    if (lower.contains("sensitive")) {
      return "s";
    }
    return "g";
  }

  // 최종 프롬프트 미리보기 (2번째 UI 상단 표시용)
  // 생성과 같은 순서로 합치되, 와일드카드는 생성 시마다 바뀌므로 원문(__foo__)을 그대로 남긴다.
  String buildPreviewPrompt() {
    String prefixText = prefixController.text;
    String positiveText = positiveController.text;
    String suffixText = suffixController.text;

    // 조건부 트리거가 generate 모드면 영역별로 적용 (random 모드는 이미 반영돼 있음)
    if (conditionalTriggerMode == "generate") {
      final rating = _ratingLetterOf("$prefixText,$positiveText,$suffixText");
      final sectioned = _applyConditionalRulesSectioned(
        prefixText,
        positiveText,
        suffixText,
        rating,
      );
      prefixText = sectioned.prefix;
      positiveText = sectioned.positive;
      suffixText = sectioned.suffix;
    }

    // 표시용 구분: 선행/긍정/후행 사이에 빈 줄을 넣어 영역을 눈으로 구분한다.
    // (실제 전송은 handleGenerate가 따로 조립하므로 여기 줄바꿈은 화면에만 영향)
    //  각 구획 '안'의 줄바꿈은 sanitizePrompt가 보존하므로 사용자가 짠 줄 구성이 그대로 보인다.
    const sep = "\n\n";
    final parts = [
      _service.sanitizePrompt(prefixText),
      _service.sanitizePrompt(positiveText),
      _service.sanitizePrompt(suffixText),
    ];
    // 비어 있는 영역은 구분선도 만들지 않아 불필요한 여백/콤마가 남지 않게
    final combined = parts.where((e) => e.trim().isNotEmpty).join(",$sep");
    return _applyWeightRules(combined);
  }

  String _applyWeightRules(String prompt) {
    if (!weightRulesEnabled) {
      return prompt;
    }
    // 규칙 구분자: 콤마 또는 줄바꿈 (앞뒤 공백은 자동으로 다듬음)
    final rawRules = weightRulesController.text.split(RegExp(r'[,\n]'));
    String result = prompt;
    for (final rawLine in rawRules) {
      // '#'이 나오면 그 항목의 끝(콤마/줄바꿈)까지는 주석으로 무시한다.
      //  예) "sleeping=0.5 #메모" → "sleeping=0.5" 만 규칙으로 인식
      final hash = rawLine.indexOf('#');
      final line = (hash >= 0 ? rawLine.substring(0, hash) : rawLine).trim();
      if (line.isEmpty) {
        continue;
      }
      final eq = line.lastIndexOf('=');
      if (eq <= 0 || eq == line.length - 1) {
        continue; // '=' 가 없거나 좌/우가 비면 잘못된 규칙
      }
      final tag = line.substring(0, eq).trim();
      final weightStr = line.substring(eq + 1).trim();
      final weight = double.tryParse(weightStr);
      if (tag.isEmpty || weight == null) {
        continue; // 숫자가 아니면 건너뜀
      }
      // 대상 태그를 정확히(콤마/문자열 경계 기준) 찾아 치환.
      final escaped = RegExp.escape(tag);
      // 이미 가중치가 걸려 있으면(예: "1.1::sleeping ::", "1::tag::", "-1::hat ::")
      // 사용자가 직접 지정한 값이므로 규칙을 적용하지 않고 그대로 둔다.
      final alreadyWeighted = RegExp('-?[0-9.]+\\s*::\\s*$escaped\\s*::', caseSensitive: false);
      if (alreadyWeighted.hasMatch(result)) {
        continue;
      }
      // 콤마 또는 문자열 시작/끝으로 둘러싸인 태그를 매칭 (앞뒤 공백 허용)
      final re = RegExp('(^|,)\\s*$escaped\\s*(?=,|\$)', caseSensitive: false);
      result = result.replaceAllMapped(re, (m) {
        final lead = m.group(1) ?? '';
        // 앞이 콤마면 ", "로 정리해 태그 간 간격을 유지 (문자열 시작이면 공백 없음)
        final prefix = lead == ',' ? ', ' : lead;
        return '$prefix$weight::$tag ::';
      });
    }
    return result;
  }

  // FlutterBackground는 최초 1회만 initialize.
  // (매 생성마다 알림 채널을 다시 세팅하면 그만큼 생성 시작이 늦어짐)
  // 이후 생성부터는 enable/disable만 토글한다.
  bool _bgServiceReady = false;
  Future<bool> _enableBackgroundExecution() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      if (!_bgServiceReady) {
        _bgServiceReady = await FlutterBackground.initialize(
          androidConfig: const FlutterBackgroundAndroidConfig(
            notificationTitle: "NovelAI 생성 중",
            notificationText: "백그라운드에서 안전하게 통신 중입니다...",
            notificationImportance: AndroidNotificationImportance.normal,
            notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
          ),
        );
      }
      if (_bgServiceReady) {
        await FlutterBackground.enableBackgroundExecution();
        return true;
      }
    } catch (e) {
      debugPrint("백그라운드 실행 권한이 없거나 오류 발생: $e");
    }
    return false;
  }

  // 생성 중복 실행 방지.
  //  isLoading은 "이미지가 도착한 순간" 먼저 풀어 화면을 빨리 갱신하는데,
  //  그 뒤에도 저장·히스토리 추가·잔액 조회가 남아 있다.
  //  그 틈에 버튼을 다시 누르면 생성이 두 번 돌아 이미지가 하나 더 나온다.
  //  → 후처리까지 모두 끝나야 풀리는 별도 잠금을 둔다. (i2i의 방식과 동일)
  bool _isGenerateProcessing = false;

  /// 생성이 완전히 끝났는지 (후처리 포함). 버튼 비활성 판단에 쓴다.
  bool get isGenerateBusy => _isGenerateProcessing;

  /// 잔액(Anlas)과 V5 시간당 한도를 갱신한다. 기다리지 않는다.
  ///
  /// ⚠️ 일부러 await하지 않는다.
  ///    이 둘은 화면의 숫자만 바꾸는 조회라서 다음 생성과 경합하지 않는다.
  ///    예전에는 생성 직후 이걸 await 하는 바람에 이미지가 이미 화면에 떴는데도
  ///    네트워크 왕복(V5는 2회) 동안 생성 버튼이 계속 잠겨 있었다.
  ///    조회가 끝나면 각 함수가 알아서 notifyListeners()로 숫자를 갱신한다.
  void refreshBalanceInBackground() {
    unawaited(() async {
      try {
        await fetchAnlas();
        if (modelCapsFor(selectedModel).hasHourlyLimit) {
          await fetchV5Limit();
        }
      } catch (e) {
        debugPrint('잔액 조회 실패(무시): $e');
      }
    }());
  }

  Future<void> handleGenerate(BuildContext context, VoidCallback onScrollToHistoryEnd) async {
    if (_isGenerateProcessing) {
      debugPrint('이미 생성 처리 중입니다. 중복 요청을 무시합니다.');
      return;
    }
    if (!isApiConnected) {
      return;
    }
    _isGenerateProcessing = true;
    if (!isSeedLocked || seedController.text.isEmpty) {
      seedController.text = Random().nextInt(4294967296).toString();
    }
    isLoading = true;
    lastErrorMessage = null;
    notifyListeners();
    // 설정 저장은 생성과 병렬로 (95개 키 기록을 생성 시작이 기다릴 필요 없음)
    unawaited(saveAllSettings());
    int width = 832;
    int height = 1216;

    if (resolutionMode == "랜덤") {
      final List<String> randomList = kNaiResolutions;
      String rndRes = randomList[Random().nextInt(randomList.length)];
      List<String> resParts = rndRes.replaceAll(" ", "").split("x");
      width = int.parse(resParts[0]);
      height = int.parse(resParts[1]);
    } else if (resolutionMode == "자동" && currentImageWidth > 0 && currentImageHeight > 0) {
      double maxPixels = kMegapixelCap.toDouble();
      double ratio = currentImageWidth / currentImageHeight;
      double h = sqrt(maxPixels / ratio);
      double w = h * ratio;
      width = (w / 64).round() * 64;
      height = (h / 64).round() * 64;
      while (width * height > kMegapixelCap) {
        if (width > height) {
          width -= 64;
        } else {
          height -= 64;
        }
      }
      if (width < 64) {
        width = 64;
      }
      if (height < 64) {
        height = 64;
      }
    } else if (selectedResolution == "직접 입력" ||
        (resolutionMode == "자동" && currentImageWidth == 0)) {
      width = int.tryParse(customWidthController.text) ?? 832;
      height = int.tryParse(customHeightController.text) ?? 1216;
    } else {
      List<String> resParts = selectedResolution.replaceAll(" ", "").split("x");
      width = int.parse(resParts[0]);
      height = int.parse(resParts[1]);
    }

    // 해상도 배율 적용
    if (resolutionScale != 1.0) {
      width = ((width * resolutionScale) / 64).round() * 64;
      height = ((height * resolutionScale) / 64).round() * 64;
    }

    // 64px 정렬 + 모델별 픽셀 상한 적용 (공용 헬퍼)
    (width, height) = clampResolution(width, height, modelCapsFor(selectedModel).maxPixels);

    // 처리 순서: 와일드카드 개봉 → 조건부 트리거(generate 모드) → 합치기 → sanitize
    String prefixText = prefixController.text;
    String positiveText = positiveController.text;
    String suffixText = suffixController.text;

    // 0. 순차 생성 <A|B|C>: 세 영역을 합친 기준으로 처리 (영역 간 독립 보장)
    //    구분자(\u0001)로 합쳐 처리 후 다시 분리
    const sep = '\u0001';
    final seqInput = "$prefixText$sep$positiveText$sep$suffixText";
    final seqCombined = _processSequential(seqInput);
    final seqParts = seqCombined.split(sep);
    prefixText = seqParts.isNotEmpty ? seqParts[0] : prefixText;
    positiveText = seqParts.length > 1 ? seqParts[1] : positiveText;
    suffixText = seqParts.length > 2 ? seqParts[2] : suffixText;
    _advanceSequential(seqInput); // 도달한 <>만 카운터 +1 (생성 1회 = 1전진)

    // 1. 와일드카드(랜덤 파이프 + __wildcard__) 개봉
    //    순차 와일드카드(@) 위치 일관성을 위해 세 영역을 합쳐서 개봉 후 분리
    final wcInput = "$prefixText$sep$positiveText$sep$suffixText";
    final wcCombined = _processWildcards(wcInput);
    _advanceSequentialWildcards(wcInput); // 개봉 후 순차 와일드카드 @ 카운터 전진
    final wcParts = wcCombined.split(sep);
    prefixText = wcParts.isNotEmpty ? wcParts[0] : prefixText;
    positiveText = wcParts.length > 1 ? wcParts[1] : positiveText;
    suffixText = wcParts.length > 2 ? wcParts[2] : suffixText;

    // 2. 조건부 트리거가 "generate" 모드면 와일드카드 개봉 후 적용
    if (conditionalTriggerMode == "generate") {
      final rating = _ratingLetterOf("$prefixText,$positiveText,$suffixText");
      final sectioned = _applyConditionalRulesSectioned(
        prefixText,
        positiveText,
        suffixText,
        rating,
      );
      prefixText = sectioned.prefix;
      positiveText = sectioned.positive;
      suffixText = sectioned.suffix;
    }

    // 3. 합치기 (와일드카드는 이미 개봉됨)
    //  구획별로 정리한 뒤 ", " 로 잇는다. 구획 '안'의 줄바꿈은 그대로 살아남는다.
    String finalPrompt = _service.joinPromptSections([prefixText, positiveText, suffixText]);
    // 보내기 직전 마무리 — i2i 와 똑같은 단계를 거친다 (_finishPositive 참고)
    finalPrompt = _finishPositive(finalPrompt);
    final String finalNegative = _finishNegative(negativeController.text);

    // 모델 상한을 넘으면 서버가 거부한다 (V4.5=6, V5=32)
    List<Map<String, dynamic>> processedCharacters = characters
        .where((char) => char.isActive)
        .take(modelCapsFor(selectedModel).maxCharacters)
        .map((char) {
          return _characterForSend(char);
        })
        .toList();

    // vibe 인코딩 캐시 갱신 감지용 지문 (생성 후 비교)
    final String vibeSigBefore = _vibeCacheSignature();

    final bool bgInitialized = await _enableBackgroundExecution();

    try {
      // 활성 vibe/정밀 참조 필터는 한 번만 (같은 where를 세 번 돌리지 않도록)
      // 모델이 지원하지 않으면(예: V5) 항목이 담겨 있어도 전송하지 않는다.
      final caps = modelCapsFor(selectedModel);
      final activeVibes = caps.supportsVibe
          ? vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList()
          : <Map<String, dynamic>>[];
      final activePrecise = caps.supportsPrecise
          ? preciseRefs.where((r) => (r['enabled'] as bool?) ?? true).toList()
          : <Map<String, dynamic>>[];

      final result = await _service.generateImage(
        positive: finalPrompt,
        negative: finalNegative,
        token: apiToken,
        model: selectedModel,
        steps: int.tryParse(stepsController.text) ?? 28,
        sampler: selectedSampler,
        scheduler: selectedScheduler,
        width: width,
        height: height,
        cfgScale: double.tryParse(cfgScaleController.text) ?? 6.0,
        cfgRescale: double.tryParse(cfgRescaleController.text) ?? 0.0,
        seed: int.tryParse(seedController.text) ?? 0,
        characters: processedCharacters,
        // 모델이 미지원이면 VAR+는 전송하지 않는다
        variancePlus: isVariancePlus && modelCapsFor(selectedModel).supportsVarietyPlus,
        // 투명 배경 (모델이 지원할 때만)
        transparentBackground: transparentBackground,
        useCharacterPosition: useCharacterPosition,
        randomCharacterOrder: randomCharacterOrder,
        // 정밀 참조가 있으면 vibe 대신 정밀 참조 우선 (기존 동작 그대로, 필터는 위에서 1회)
        vibeTransfers: (activeVibes.isNotEmpty && activePrecise.isEmpty) ? activeVibes : null,
        preciseRefs: activePrecise.isNotEmpty ? activePrecise : null,
      );

      isLoading = false;
      currentImageBytes = result.image ?? currentImageBytes;
      lastErrorMessage = result.error;
      // 이미지가 도착한 즉시 화면에 표시.
      // (이게 없으면 아래 fetchAnlas 네트워크 왕복이 끝나야 갱신돼 수백 ms를 그냥 기다림)
      notifyListeners();

      if (result.image != null) {
        sessionGenerateCount++;
        // 인코딩 캐시가 '실제로' 갱신된 경우에만 저장
        // (매 생성마다 vibe base64 전체를 jsonEncode하면 메인 스레드가 수 MB를 인코딩하게 됨)
        if (_vibeCacheSignature() != vibeSigBefore) {
          saveReferencesToLocal();
        }

        NaiMetadata? parsedMeta = extractNovelAIMetadata(result.image!);
        if (parsedMeta != null) {
          parsedMeta = parsedMeta.copyWithExtra({'variety_plus': isVariancePlus});
        }

        await addImageToHistory(
          image: result.image!,
          metadata: parsedMeta,
          context: context.mounted ? context : null,
        );

        if (!isHistoryGridView) {
          onScrollToHistoryEnd();
        }
      }

      // 잔액·한도 갱신은 기다리지 않는다 (버튼이 그만큼 늦게 풀린다)
      refreshBalanceInBackground();
    } finally {
      if (bgInitialized && Platform.isAndroid) {
        try {
          await FlutterBackground.disableBackgroundExecution();
        } catch (_) {
          // 이미 해제됐거나 권한이 사라진 경우다. 생성은 끝난 뒤라 알릴 필요가 없다.
        }
      }
      // 후처리까지 끝난 지금 잠금을 푼다 (성공/실패 무관)
      _isGenerateProcessing = false;
      isLoading = false;
      notifyListeners();
    }
  }

  // ============================================================================
  // 배치 생성 (연속 생성)
  // ============================================================================
  void cancelBatch() {
    batchRemaining = 0;
    isBatchMode = false;
    currentRepeatIndex = 0;
    currentRepeatTotal = 0;
    notifyListeners();
  }

  Future<void> handleBatchGenerate(BuildContext context, VoidCallback onScrollToHistoryEnd) async {
    if (isLoading || isInpaintLoading || isUpscaleLoading) {
      return;
    }

    final count = batchCount; // 0 = 무한
    batchRemaining = count == 0 ? 999 : count;
    isBatchMode = count > 1 || count == 0;
    notifyListeners();

    // 연속 생성(2개 이상 또는 무한) + 자동 전환 ON이면, 첫 생성 "전에" 다음 프롬프트로 1번 넘긴다.
    // → 이전 배치의 마지막 프롬프트와 겹치는 것을 방지 (예: 이전이 A B C면 다음은 B C D).
    // 1개 생성일 때는 "지금 보는 프롬프트로 1장" 의도를 존중해 넘기지 않는다.
    if (isBatchMode && autoNextPromptInBatch) {
      handleNextPrompt();
    }

    while (batchRemaining > 0) {
      // 탭을 옮겨 프롬프트 탭이 dispose돼도(context unmounted) 자동생성은 계속되어야 한다.
      // → context.mounted로 중단하지 않는다. 중단 조건은 API 끊김 / 남은 수 소진 / 사용자 정지뿐.
      if (!isApiConnected) {
        break;
      } // API 끊기면 중지

      // 같은 프롬프트 반복 생성 횟수 (자동 전환 ON + 반복 ON일 때만 2회 이상)
      final int repeats = (autoNextPromptInBatch && repeatSamePromptEnabled)
          ? repeatSamePromptCount.clamp(1, 99)
          : 1;
      // UI 표시용 (반복이 1회뿐이면 표시하지 않도록 0으로)
      currentRepeatTotal = repeats > 1 ? repeats : 0;

      bool aborted = false;
      for (int r = 0; r < repeats; r++) {
        if (!isApiConnected) {
          aborted = true;
          break;
        }
        currentRepeatIndex = repeats > 1 ? r + 1 : 0;
        notifyListeners();

        // context가 죽어도 handleGenerate 내부에서 (context.mounted ? context : null)로
        // 안전 처리되므로, 여기서는 의도적으로 mounted 가드 없이 넘긴다.
        // ignore: use_build_context_synchronously
        await handleGenerate(context, onScrollToHistoryEnd);

        // 사용자 정지 감지: cancelBatch()가 batchRemaining=0, isBatchMode=false로 만든다.
        // batchRemaining을 보면 유한/무한(batchCount==0) 모두 정확히 잡힌다.
        // (isBatchMode만 보면 무한 생성 시 정지가 감지되지 않아 반복이 계속 돌아버림)
        if (batchRemaining <= 0 || !isBatchMode) {
          aborted = true;
          break;
        }
        // 반복 사이에도 딜레이 (마지막 반복 뒤엔 아래 공통 딜레이가 처리)
        if (r < repeats - 1) {
          notifyListeners();
          await Future.delayed(Duration(milliseconds: (batchDelay * 1000).round()));
          // 딜레이 중에 정지를 눌렀을 수도 있으니 한 번 더 확인
          if (batchRemaining <= 0 || !isBatchMode) {
            aborted = true;
            break;
          }
        }
      }
      if (aborted) {
        break;
      }

      if (count != 0) {
        batchRemaining--;
      }

      // 다음 생성이 남아있을 때만 다음 프롬프트로 전환 (마지막 생성 뒤엔 넘기지 않음).
      // → 넘기면 인덱스가 앞서가서 다음 배치가 겹치게 됨.
      if (batchRemaining <= 0) {
        break;
      }
      if (autoNextPromptInBatch) {
        handleNextPrompt();
      }
      notifyListeners();

      // 다음 생성 전 잠깐 대기 (서버 부하 방지)
      await Future.delayed(Duration(milliseconds: (batchDelay * 1000).round()));
    }

    batchRemaining = 0;
    isBatchMode = false;
    currentRepeatIndex = 0;
    currentRepeatTotal = 0;
    notifyListeners();
  }

  // [추가] 엄격한 뮤텍스 잠금을 위한 변수 선언
  bool _isInpaintProcessing = false;

  // i2i와 인페인트는 흐름이 거의 같다(같은 입력창·같은 뮤텍스·같은 결과 처리).
  //  예전에는 170줄짜리 함수 두 벌이라 한쪽만 고치면 다른 쪽이 어긋나기 쉬웠다.
  //  차이나는 부분(마스크·action·강도·캐릭터 전송)만 매개변수로 받고 하나로 합쳤다.
  Future<void> _runI2iPipeline(
    BuildContext context, {
    required String action, // "img2img" 또는 "infill"
    required String errorTitle,
    required String resultSource,
    Uint8List? maskBytes,
    bool sendCharacters = true,
  }) async {
    // 뮤텍스: 앞선 작업이 진행 중이면 중복 클릭을 무시한다
    if (_isInpaintProcessing) {
      debugPrint('이미 처리 중입니다. 중복 요청을 무시합니다.');
      return;
    }

    if (!isApiConnected) {
      if (context.mounted) {
        showToast(context, "설정 탭에서 API 키를 먼저 연결해주세요.");
      }
      return;
    }
    if (targetI2iImage == null || targetI2iMetadata == null) {
      if (context.mounted) {
        showToast(context, "히스토리 탭에서 이미지를 먼저 선택해주세요.");
      }
      return;
    }

    _isInpaintProcessing = true;
    isInpaintLoading = true;
    inpaintStatusMessage = "연결 중...";
    lastErrorMessage = null;
    notifyListeners();

    bool bgInitialized = false;
    try {
      if (!isSeedLocked || seedController.text.isEmpty) {
        seedController.text = Random().nextInt(4294967296).toString();
      }

      unawaited(saveAllSettings()); // 생성과 병렬 저장

      final int width = targetI2iMetadata!.width;
      final int height = targetI2iMetadata!.height;

      // i2i 탭의 프롬프트 입력란을 그대로 사용 (인페인트와 공유)
      String finalPrompt = _service.joinPromptSections([
        _processWildcards(inpaintPrefixController.text),
        _processWildcards(inpaintPositiveController.text),
        _processWildcards(inpaintSuffixController.text),
      ]);
      // 보내기 직전 마무리 — 생성과 똑같은 단계를 거친다 (_finishPositive 참고)
      finalPrompt = _finishPositive(finalPrompt);
      final String finalNegative = _finishNegative(inpaintNegativeController.text);

      bgInitialized = await _enableBackgroundExecution();

      // 실행 시점의 활성 캐릭터를 그대로 전송 (인페인트는 캐릭터를 보내지 않는다)
      final List<Map<String, dynamic>> processedCharacters = sendCharacters
          ? characters
                .where((char) => char.isActive)
                // 모델 상한을 넘으면 서버가 거부한다 (V4.5=6, V5=32)
                .take(modelCapsFor(selectedModel).maxCharacters)
                .map((char) {
                  return _characterForSend(char);
                })
                .toList()
          : <Map<String, dynamic>>[];

      final result = await _service.generateImage(
        positive: finalPrompt,
        negative: finalNegative,
        token: apiToken,
        model: selectedModel,
        steps: int.tryParse(stepsController.text) ?? 28,
        sampler: selectedSampler,
        scheduler: selectedScheduler,
        width: width,
        height: height,
        cfgScale: double.tryParse(cfgScaleController.text) ?? 6.0,
        cfgRescale: double.tryParse(cfgRescaleController.text) ?? 0.0,
        seed: int.tryParse(seedController.text) ?? 0,
        characters: processedCharacters,
        image: targetI2iImage,
        mask: maskBytes,
        action: action,
        img2imgStrength: img2imgStrength,
        img2imgNoise: img2imgNoise,
        infillStrength: infillStrength,
        // 모델이 미지원이면 VAR+는 전송하지 않는다
        variancePlus: isVariancePlus && modelCapsFor(selectedModel).supportsVarietyPlus,
        // 투명 배경 (모델이 지원할 때만)
        transparentBackground: transparentBackground,
        useCharacterPosition: useCharacterPosition,
        randomCharacterOrder: randomCharacterOrder,
        onStatus: (msg) {
          inpaintStatusMessage = msg;
          notifyListeners();
        },
      );

      lastErrorMessage = result.error;

      if (result.error != null) {
        if (context.mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  Text(
                    errorTitle,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Text(result.error!, style: const TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text("닫기", style: TextStyle(color: AppColors.accent)),
                ),
              ],
            ),
          );
        }
      } else if (result.image != null) {
        final NaiMetadata? parsedMeta = extractNovelAIMetadata(result.image!);

        // ⚠️ 순서 중요: 마스크 처리 방식/이미지 전환을 먼저 정한 뒤 addI2iResult를 호출한다.
        //    addI2iResult가 notifyListeners()를 부르므로, 그 전에 상태가 정해져 있어야
        //    i2i_tab build가 올바르게 판단한다.
        if (!inpaintNoAutoSwitch) {
          // 결과를 작업 이미지로 자동 전환 → 이미지 변경 시 자동 해제 설정을 따라 마스크 처리
          i2iMaskActionOnChange = I2iMaskAction.followInpaintSetting;
          targetI2iImage = result.image!;
          targetI2iMetadata = parsedMeta;
          recordI2iView(result.image!, parsedMeta); // 본 이미지 기록 추가
        } else if (inpaintAutoClearMask) {
          // 자동 전환은 안 하지만 자동 해제는 ON → 이미지는 그대로 두고 마스크만 즉시 해제
          i2iMaskClearRevision++;
        }
        // (자동 전환 OFF + 자동 해제 OFF → 아무것도 안 함, 마스크 유지)

        // 결과는 메인 히스토리 대신 i2i 스크래치 릴로 (여기서 notifyListeners 발생)
        addI2iResult(result.image!, parsedMeta, source: resultSource);
      }

      // 잔액·한도 갱신은 기다리지 않는다 (버튼이 그만큼 늦게 풀린다)
      refreshBalanceInBackground();
    } catch (e) {
      debugPrint('$action 파이프라인 에러: $e');
    } finally {
      // 백그라운드 실행 해제 (켰으면 반드시 끔 — 알림이 남지 않도록)
      if (bgInitialized) {
        try {
          await FlutterBackground.disableBackgroundExecution();
        } catch (e) {
          debugPrint("백그라운드 해제 오류: $e");
        }
      }
      // 성공/실패 여부와 관계없이 반드시 락 해제
      _isInpaintProcessing = false;
      isInpaintLoading = false;
      inpaintStatusMessage = "";
      notifyListeners();
    }
  }

  /// i2i 생성 — 원본 이미지를 참고해 다시 그린다.
  Future<void> handleImg2ImgGenerate(BuildContext context) {
    return _runI2iPipeline(
      context,
      action: "img2img",
      errorTitle: "img2img 생성 오류",
      resultSource: "img2img",
    );
  }

  /// 인페인트 생성 — 마스크로 칠한 부분만 다시 그린다.
  Future<void> handleInpaintGenerate(BuildContext context, Uint8List maskBytes) {
    return _runI2iPipeline(
      context,
      action: "infill",
      errorTitle: "인페인트 생성 오류",
      resultSource: "inpaint",
      maskBytes: maskBytes,
      sendCharacters: false, // 인페인트는 캐릭터를 보내지 않는다
    );
  }

  Future<void> handleUpscaleGenerate(BuildContext context) async {
    if (!isApiConnected) {
      if (!context.mounted) {
        return;
      }
      showToast(context, "설정 탭에서 API 키를 먼저 연결해주세요.");
      return;
    }
    // 새 업스케일러는 크기 정보를 받지 않아, 메타데이터가 없는 그림(밖에서 가져온 그림)도 된다
    if (targetI2iImage == null) {
      if (!context.mounted) {
        return;
      }
      showToast(context, "히스토리 탭에서 이미지를 먼저 선택해주세요.");
      return;
    }

    // ⚠️ 예전엔 여기서 '1024×1024 이하만' 을 막았다. 그건 옛 업스케일러의 제한이었고,
    //    지금의 V5 업스케일러는 공개된 크기 제한이 없다(NovelAI 웹도 막지 않는다).
    //    앱이 옛 기준으로 막으면 오히려 쓸 수 있는 그림을 못 쓰게 되므로,
    //    크기는 서버가 판단하게 두고 거절되면 그 메시지를 그대로 보여 준다.

    final bool proceed = await showConfirmDialog(
      context,
      title: "업스케일 진행",
      message:
          "업스케일(${NovelAiService.upscaleScale}배)을 진행합니다.\n${anlasText(anlasFor(AnlasJob.upscale))}\n\n계속 진행하시겠습니까?",
      confirmLabel: "업스케일 시작",
      icon: Icons.high_quality,
      iconColor: Colors.amber,
      confirmColor: Colors.amber[700],
    );

    if (!proceed) {
      return;
    }

    if (!context.mounted) {
      return;
    }

    isUpscaleLoading = true;
    lastErrorMessage = null;
    notifyListeners();

    try {
      final result = await _service.upscaleImage(image: targetI2iImage!, token: apiToken);

      isUpscaleLoading = false;

      if (result.error != null) {
        if (!context.mounted) {
          return;
        }
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.error_outline, color: Colors.redAccent),
                SizedBox(width: 8),
                Text(
                  "업스케일 오류",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            content: Text(result.error!, style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  "닫기",
                  style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
      } else if (result.image != null) {
        // ⚠️ 배율을 가정하지 않고 결과 그림의 실제 크기를 읽는다.
        //    예전엔 'width * 4' 로 적어서, 배율이 2배로 바뀐 뒤엔 틀린 크기가 기록될 뻔했다.
        final (outW, outH) = await readImageSize(result.image!) ?? (0, 0);
        NaiMetadata? parsedMeta;
        if (targetI2iMetadata != null) {
          parsedMeta = NaiMetadata(
            positive: targetI2iMetadata!.positive,
            negative: targetI2iMetadata!.negative,
            characterPrompts: targetI2iMetadata!.characterPrompts,
            characterUndesiredContents: targetI2iMetadata!.characterUndesiredContents,
            width: outW > 0 ? outW : targetI2iMetadata!.width * NovelAiService.upscaleScale,
            height: outH > 0 ? outH : targetI2iMetadata!.height * NovelAiService.upscaleScale,
            seed: targetI2iMetadata!.seed,
            steps: targetI2iMetadata!.steps,
            sampler: targetI2iMetadata!.sampler,
            promptGuidance: targetI2iMetadata!.promptGuidance,
            promptGuidanceRescale: targetI2iMetadata!.promptGuidanceRescale,
            undesiredContentStrength: targetI2iMetadata!.undesiredContentStrength,
            source: targetI2iMetadata!.source,
            extraParams: targetI2iMetadata!.extraParams,
          );
        } else {
          parsedMeta = extractNovelAIMetadata(result.image!);
        }

        // 업스케일 결과도 i2i 스크래치 릴로
        addI2iResult(result.image!, parsedMeta, source: 'upscale');
      }

      // 잔액·한도 갱신은 기다리지 않는다 (버튼이 그만큼 늦게 풀린다)
      refreshBalanceInBackground();
    } finally {
      isUpscaleLoading = false;
      notifyListeners();
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Director Tools
  // ══════════════════════════════════════════════════════════════

  // ══════════════════════════════════════════════════════════════
  // 프롬프트 되돌리기 기록
  // ══════════════════════════════════════════════════════════════
  //
  // 확대 입력창에서 내용을 통째로 갈아엎기 전의 상태를 입력창별로 남긴다.
  //  예: 그림체 프롬프트를 써 둔 채 "이 작가는 어떻게 그려질까?" 하고
  //      전부 지운 뒤 하나만 시험해 보는 흐름. 예전에는 원래 내용을 직접
  //      복사해 두거나 프리셋에 저장해야 했다.
  //
  // key 는 입력창 이름(title). 최신 기록이 리스트 앞에 온다.
  Map<String, List<String>> promptUndoHistory = {};

  /// 한 입력창이 기억하는 최대 개수.
  static const int kPromptUndoLimit = 3;

  /// [title] 입력창의 현재 내용을 되돌리기 기록에 넣는다.
  ///
  /// 내용이 통째로 바뀌기 '직전'에 부른다. 타이핑마다 부르면 안 된다.
  ///  · 빈 내용은 되돌릴 가치가 없어 넣지 않는다
  ///  · 맨 앞 기록과 같으면 중복이므로 넣지 않는다
  void pushPromptUndo(String title, String text) {
    final t = text.trim();
    if (t.isEmpty) {
      return;
    }
    final list = promptUndoHistory[title] ?? <String>[];
    if (list.isNotEmpty && list.first == text) {
      return;
    }
    list.insert(0, text);
    while (list.length > kPromptUndoLimit) {
      list.removeLast();
    }
    promptUndoHistory[title] = list;
    saveAllSettings();
  }

  /// [title] 입력창의 되돌리기 기록. 최신이 앞.
  List<String> promptUndoList(String title) => promptUndoHistory[title] ?? const [];

  /// 되돌리기 기록을 비운다.
  void clearPromptUndo(String title) {
    promptUndoHistory.remove(title);
    saveAllSettings();
  }

  /// 중첩 가중치를 보내기 직전에 펼칠지. 기본 OFF.
  ///
  /// NovelAI 는 숫자 없는 `::` 를 만나면 앞의 가중치를 전부 끝내 버린다.
  /// 켜 두면 `5.0::A, 1.5::B ::, C ::,` 를
  /// `5.0::A, 1.5::B ::, 5.0::C ::,` 로 바꿔 보낸다.
  ///
  /// 입력한 프롬프트 자체는 건드리지 않는다 — 전송분에만 적용된다.
  bool expandNestedWeightsEnabled = true;

  /// 캐릭터 하나를 '보낼 모양'으로 만든다 (생성·i2i 공통).
  ///  ⚠️ 예전엔 두 경로에 똑같은 17줄이 따로 있어서, 한쪽만 고치면 동작이 갈렸다.
  ///     (임시 프롬프트·중첩 가중치를 넣을 때 실제로 i2i 쪽을 빠뜨린 적이 있다)
  Map<String, dynamic> _characterForSend(NaiCharacter char) {
    final Map<String, dynamic> charJson = char.toJson();
    // 임시 프롬프트는 원본 뒤에 붙인다. char.positive 자체는 건드리지 않는다
    //  — 화면의 원본은 그대로 두고 '이번 전송분'에만 더하는 기능이다.
    if (char.tempActive) {
      charJson['positive'] = [
        char.positive.trim(),
        char.tempPositive.trim(),
      ].where((e) => e.isNotEmpty).join(', ');
    }
    if (charJson.containsKey('positive')) {
      charJson['positive'] = _maybeExpandWeights(
        tidyWeightMarkers(_processWildcards(charJson['positive'].toString())),
      );
    }
    if (charJson.containsKey('negative')) {
      charJson['negative'] = _maybeExpandWeights(
        tidyWeightMarkers(_processWildcards(charJson['negative'].toString())),
      );
    }
    return charJson;
  }

  /// 합친 긍정 프롬프트를 보내기 직전 모양으로 마무리한다 (생성·i2i 공통).
  ///  순서가 중요하다: 가중치 쉼표 정리 → 인원수를 앞으로 → 가중치 규칙 → 품질 태그 → 중첩 가중치 펼치기
  ///  (쉼표 정리가 맨 먼저여야 섹션 경계에 걸친 가중치를 뒤 단계들이 제대로 알아본다)
  String _finishPositive(String joined) => _maybeExpandWeights(
    applyQualityTags(_applyWeightRules(_hoistCountTags(tidyWeightMarkers(joined)))),
  );

  /// 부정 프롬프트를 보내기 직전 모양으로 (생성·i2i 공통).
  String _finishNegative(String raw) => _maybeExpandWeights(
    applyUcPreset(tidyWeightMarkers(_service.sanitizePrompt(_processWildcards(raw)))),
  );

  /// 설정이 켜져 있을 때만 중첩 가중치를 펼친다.
  ///  전송 직전에 한 번만 통과시키면 되므로 조립이 끝난 문자열에 적용한다.
  String _maybeExpandWeights(String text) =>
      expandNestedWeightsEnabled ? expandNestedWeights(text) : text;

  /// 지금 고른 Director 도구 (req_type). 5곳 패턴으로 저장된다.
  String directorTool = 'bg-removal';

  /// 도구가 도는 중인지. 실행 버튼을 잠그는 데 쓴다.
  bool isDirectorLoading = false;

  /// 지금 고른 이미지 기준으로 Director 도구의 예상 Anlas 를 돌려준다.
  ///  0 이면 소모 없음(Opus 무료 범위), -1 이면 계산 불가(너무 큼).
  // 메타데이터가 없는 그림의 크기를 한 번만 재 두는 곳 (그림이 바뀌면 다시 잰다)
  Uint8List? _sizedImage;
  (int, int) _sizedImageWH = (0, 0);

  int directorCostFor(String reqType) {
    int w = targetI2iMetadata?.width ?? 0;
    int h = targetI2iMetadata?.height ?? 0;
    if ((w <= 0 || h <= 0) && targetI2iImage != null) {
      // ⚠️ 이 함수는 Director 칩을 그릴 때마다(칩 4개 × 2번) 불린다.
      //    메타데이터 없는 그림(밖에서 가져온 그림)이면 예전엔 그때마다
      //    그림을 통째로 풀어 리빌드 한 번에 8번씩 디코딩했다.
      //    같은 그림이면 처음 잰 크기를 그대로 쓴다.
      if (!identical(_sizedImage, targetI2iImage)) {
        final decoded = img.decodeImage(targetI2iImage!);
        _sizedImage = targetI2iImage;
        _sizedImageWH = decoded == null ? (0, 0) : (decoded.width, decoded.height);
      }
      (w, h) = _sizedImageWH;
    }
    if (w <= 0 || h <= 0) {
      return 0; // 크기를 모르면 경고를 띄우지 않는다 (실행 단계에서 다시 검사한다)
    }
    return directorToolCost(reqType: reqType, width: w, height: h, tier: subscriptionTier);
  }

  void setDirectorTool(String reqType) {
    directorTool = reqType;
    saveAllSettings();
    notifyListeners();
  }

  /// 선택한 이미지에 Director 도구를 적용한다.
  ///
  /// 결과는 i2i 결과 릴에 쌓인다. 배경 제거는 3장이 한 번에 들어간다.
  Future<void> handleDirectorTool(BuildContext context) async {
    if (isDirectorLoading) {
      return; // 연타 방지 — 느린 도구라 특히 중요하다
    }
    if (apiToken.isEmpty) {
      showToast(context, "설정 탭에서 API 키를 먼저 연결해주세요.");
      return;
    }
    if (targetI2iImage == null) {
      showToast(context, "히스토리 탭에서 이미지를 먼저 선택해주세요.");
      return;
    }

    // 크기는 메타데이터가 있으면 그걸 쓰고, 없으면 이미지에서 직접 읽는다.
    int width = targetI2iMetadata?.width ?? 0;
    int height = targetI2iMetadata?.height ?? 0;
    if (width <= 0 || height <= 0) {
      final decoded = img.decodeImage(targetI2iImage!);
      if (decoded == null) {
        showToast(context, "이미지 크기를 읽지 못했습니다.");
        return;
      }
      width = decoded.width;
      height = decoded.height;
    }

    final tool = directorToolFor(directorTool);
    isDirectorLoading = true;
    lastErrorMessage = null;
    notifyListeners();

    try {
      final result = await _service.runDirectorTool(
        image: targetI2iImage!,
        width: width,
        height: height,
        token: apiToken,
        reqType: tool.reqType,
      );

      if (result.error != null) {
        lastErrorMessage = result.error;
        if (context.mounted) {
          showToast(context, result.error!, length: ToastLength.long);
        }
        return;
      }

      if (result.images.isEmpty) {
        if (context.mounted) {
          showToast(context, "결과를 받지 못했습니다.");
        }
        return;
      }

      // ⚠️ 순서 중요: 이미지 전환을 먼저 정한 뒤 addI2iResult 를 호출한다.
      //    addI2iResult 가 notifyListeners() 를 부르므로,
      //    그 전에 상태가 정해져 있어야 i2i_tab build 가 올바르게 판단한다.
      //    (인페인트 파이프라인과 같은 규칙)
      if (!inpaintNoAutoSwitch) {
        // 결과를 작업 이미지로 자동 전환.
        //  배경 제거는 3장이지만 첫 장(Masked)으로 바꾼다.
        //  나머지는 릴에 남아 있으니 눌러서 바꿔 볼 수 있다.
        final first = result.images.first;
        final firstMeta = extractNovelAIMetadata(first);
        i2iMaskActionOnChange = I2iMaskAction.followInpaintSetting;
        targetI2iImage = first;
        targetI2iMetadata = firstMeta;
        recordI2iView(first, firstMeta); // 본 이미지 기록 추가
      } else if (inpaintAutoClearMask) {
        // 전환은 안 하지만 마스크 자동 해제는 ON → 마스크만 즉시 해제
        i2iMaskClearRevision++;
      }

      // 결과를 릴에 넣는다. 배경 제거는 3장이라 배지에 종류를 붙여 구분한다.
      for (int i = 0; i < result.images.length; i++) {
        final bytes = result.images[i];
        final String badge = (tool.multiResult && i < kBgRemovalVariants.length)
            ? '${tool.badge}-${kBgRemovalVariants[i][0]}' // BG-M / BG-G / BG-B
            : tool.badge;
        addI2iResult(bytes, extractNovelAIMetadata(bytes), source: badge);
      }

      if (context.mounted) {
        showToast(
          context,
          result.images.length > 1
              ? "${tool.label} 완료 — 결과 ${result.images.length}장"
              : "${tool.label} 완료",
        );
      }

      // 도구도 Anlas 를 쓰므로 잔액을 갱신한다 (기다리지는 않는다)
      refreshBalanceInBackground();
    } finally {
      isDirectorLoading = false;
      notifyListeners();
    }
  }

  Future<void> importImageToHistory(BuildContext context) async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        final Uint8List bytes = await image.readAsBytes();
        if (!context.mounted) {
          return;
        }
        await addBytesToHistory(bytes, context); // 불러온 이미지는 저장 경로 없음(null)
      }
    } catch (e) {
      debugPrint("이미지 불러오기 오류: $e");
      if (!context.mounted) {
        return;
      }
      showToast(context, "이미지를 불러오는 데 실패했습니다.");
    }
  }

  // 바이트를 히스토리에 추가하는 핵심 로직 (이미지 불러오기 / 갤러리 추가 공용)
  // 바이트를 히스토리에 추가 (이미지 불러오기 / 갤러리 추가 공용)
  // 핵심 적재는 addImageToHistory를 재사용하고, 메타 파싱·알림·메시지만 담당
  Future<void> addBytesToHistory(
    Uint8List bytes,
    BuildContext context, {
    String? filePath,
    bool showSuccess = true,
  }) async {
    final NaiMetadata? parsedMeta = extractNovelAIMetadata(bytes);
    await addImageToHistory(
      image: bytes,
      metadata: parsedMeta,
      context: context,
      presetFilePath: filePath, // 전달된 실제 경로 사용 (없으면 null)
      skipAutoSave: true, // 불러온/기존 파일은 자동저장 안 함
    );
    notifyListeners();

    if (!showSuccess || !context.mounted) {
      return;
    }
  }

  // 여러 파일을 한 번에 히스토리에 추가 (갤러리 다중 선택용)
  Future<int> addFilesToHistory(List<File> files, BuildContext context) async {
    int added = 0;
    for (final f in files) {
      try {
        final bytes = await f.readAsBytes();
        if (!context.mounted) {
          return added;
        }
        await addBytesToHistory(bytes, context, filePath: f.path, showSuccess: false);
        added++;
      } catch (e) {
        debugPrint("히스토리 일괄 추가 실패 (${f.path}): $e");
      }
    }
    if (context.mounted && added > 0) {}
    return added;
  }

  // ============================================================================
  // 히스토리 일괄 삭제
  // ============================================================================
  bool isHistoryLoading = true; // 히스토리 로드 중 플래그

  // ============================================================================
  // 히스토리 메모리 관리
  // ============================================================================
  static const int _memoryKeepCount = 30; // 최근 N개만 원본 유지

  /// 오래된 이미지를 썸네일로 변환해서 메모리 절약 (백그라운드)
  Future<void> _trimHistoryMemory() async {
    if (historyImages.length <= _memoryKeepCount) {
      return;
    }

    final cutoff = historyImages.length - _memoryKeepCount;
    // 변환할 인덱스와 데이터 수집
    List<int> toConvert = [];
    List<Uint8List> toConvertData = [];
    for (int i = 0; i < cutoff; i++) {
      if (historyImages[i].length < kThumbBytesLimit) {
        continue;
      }
      toConvert.add(i);
      toConvertData.add(historyImages[i]);
    }
    if (toConvertData.isEmpty) {
      return;
    }

    // 네이티브 WebP 로 줄인다 (긴 변 768 — 예전 200px 보다 크게 열어도 알아볼 수 있다).
    //  인코더가 안 되는 기기면 옛 방식(isolate 에서 200px JPEG)으로 대신한다.
    final thumbnails = List<Uint8List>.from(toConvertData);
    final fallbackIdx = <int>[];
    for (int k = 0; k < toConvertData.length; k++) {
      final t = await makeHistoryThumb(toConvertData[k]);
      if (t != null) {
        thumbnails[k] = t;
      } else {
        fallbackIdx.add(k);
      }
    }
    if (fallbackIdx.isNotEmpty) {
      final old = await compute(_trimHistoryIsolate, [
        for (final k in fallbackIdx) toConvertData[k],
      ]);
      for (int n = 0; n < fallbackIdx.length; n++) {
        thumbnails[fallbackIdx[n]] = old[n];
      }
    }

    // 변환하는 동안 사용자가 히스토리를 지웠을 수 있다.
    //  인덱스만 믿으면 엉뚱한 이미지를 썸네일로 덮어쓰게 되므로,
    //  '그 자리에 있던 바로 그 객체'가 아직 있는지 확인하고 바꾼다.
    for (int j = 0; j < toConvert.length; j++) {
      final idx = toConvert[j];
      if (idx >= historyImages.length) {
        continue; // 목록이 짧아졌다
      }
      if (!identical(historyImages[idx], toConvertData[j])) {
        continue; // 다른 이미지가 그 자리를 차지했다
      }
      historyImages[idx] = thumbnails[j];
    }
  }

  static List<Uint8List> _trimHistoryIsolate(List<Uint8List> images) {
    List<Uint8List> results = [];
    for (final bytes in images) {
      try {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          final thumb = img.copyResize(decoded, width: 200);
          results.add(Uint8List.fromList(img.encodeJpg(thumb, quality: 70)));
          continue;
        }
      } catch (_) {
        // 썸네일 변환 실패 시 원본을 그대로 쓴다 (아래 add).
        // 메모리를 줄이지 못할 뿐 이미지는 계속 보인다.
      }
      results.add(bytes);
    }
    return results;
  }

  // ============================================================================
  // 히스토리에 이미지 추가 (공통 헬퍼)
  // ============================================================================
  Future<String?> addImageToHistory({
    required Uint8List image,
    required NaiMetadata? metadata,
    BuildContext? context,
    bool forceSave = false, // true면 isAutoSave 무시하고 저장
    String? presetFilePath, // 이미 디스크에 있는 파일(갤러리 등): 이 경로 사용
    bool skipAutoSave = false, // 불러오기/갤러리 추가: 자동저장 안 함
  }) async {
    if (historyImages.length >= kHistoryCap) {
      _removeOldestNonFavorite();
    }
    historyImages.add(image);
    historyFavorites.add(false);
    historyMetadata.add(metadata);

    String? savedPath;
    if (presetFilePath != null) {
      savedPath = presetFilePath;
    } else if (!skipAutoSave && (forceSave || isAutoSave)) {
      savedPath = await autoSaveImage((context != null && context.mounted) ? context : null, image);
    }
    historyFilePaths.add(savedPath);

    selectedHistoryIndex = historyImages.length - 1;
    scrollToThumbnailEnd = true;
    saveHistoryToLocal();
    // 오래된 이미지를 썸네일로 줄이는 작업. 화면에 이미 뜬 이미지와는 무관하므로
    // 기다리지 않는다 (기다리면 그만큼 생성 버튼이 늦게 풀린다).
    unawaited(_trimHistoryMemory());

    return savedPath;
  }

  // ===== i2i 스크래치 릴 =====
  // 결과를 릴에 추가 (디스크 저장 안 함 — 스크래치)
  // i2iHistoryDisabled가 켜져 있으면 릴 대신 메인 히스토리에 저장 (기존 동작)
  void addI2iResult(Uint8List bytes, NaiMetadata? metadata, {String source = 'inpaint'}) {
    if (i2iHistoryDisabled) {
      addImageToHistory(image: bytes, metadata: metadata, forceSave: true);
      return;
    }
    i2iResults.add(I2iResult(bytes: bytes, metadata: metadata, source: source));
    _trimI2iResults();
    notifyListeners();
  }

  // 비즐겨찾기 결과가 상한을 넘으면 오래된 것부터 제거 (즐겨찾기는 유지)
  void _trimI2iResults() {
    // 전체(즐겨찾기 포함)가 상한을 넘으면 가장 오래된 '비즐겨찾기'부터 제거.
    // 예: 즐겨찾기 4개면 일반 이미지는 26개까지 = 총 30개.
    while (i2iResults.length > i2iResultsCap) {
      final idx = i2iResults.indexWhere((r) => !r.favorite);
      if (idx < 0) {
        break; // 전부 즐겨찾기 (즐겨찾기 상한 5라 실제로는 도달하지 않음)
      }
      i2iResults.removeAt(idx);
    }
  }

  // 즐겨찾기 토글 (영속 저장)
  // 반환: true=토글됨, false=즐겨찾기 한도(i2iFavoriteCap) 초과로 막힘
  bool toggleI2iFavorite(int index) {
    if (index < 0 || index >= i2iResults.length) {
      return true;
    }
    final r = i2iResults[index];
    if (!r.favorite) {
      final favCount = i2iResults.where((x) => x.favorite).length;
      if (favCount >= i2iFavoriteCap) {
        return false; // 한도 초과 — 호출 측에서 안내
      }
    }
    r.favorite = !r.favorite;
    saveI2iFavorites();
    notifyListeners();
    return true;
  }

  // 릴에서 결과 삭제 (내역에서 제거)
  void removeI2iResult(int index) {
    if (index < 0 || index >= i2iResults.length) {
      return;
    }
    final bool wasFav = i2iResults[index].favorite;
    i2iResults.removeAt(index);
    if (wasFav) {
      saveI2iFavorites();
    }
    notifyListeners();
  }

  // ── i2i 마스크 처리 방식 (1회용 소비 신호 대신 "상태 기반"으로 관리) ──
  // targetI2iImage를 바꾸는 쪽이 "왜 바꾸는지"를 함께 세팅하고,
  // i2i_tab은 이미지 변경을 감지하면 이 값을 읽어 마스크를 어떻게 할지 결정한다.
  // enum은 소비하지 않으므로(다음 변경 시 덮어써짐) build 타이밍에 안전하다.
  I2iMaskAction i2iMaskActionOnChange = I2iMaskAction.clearMask;

  // 인페인트 마스크 획 목록. 위젯(i2i_tab)이 아니라 여기 보관하여 탭 재생성에도 유지.
  final List<MaskStroke> i2iMaskStrokes = [];

  // ── i2i "본 이미지" 기록 (직전 이미지 버튼용) ──
  // 이미지가 바뀔 때마다 본 순서를 기록하고, 버튼으로 한 칸씩 거꾸로 걷는다.
  // 새 이미지 전송(마스크 무조건 초기화 타이밍) 시 기록을 리셋하고 새로 시작.
  final List<({Uint8List bytes, NaiMetadata? meta})> _i2iViewHistory = [];
  int _i2iViewCursor = -1; // 현재 보고 있는 기록 위치
  static const int _i2iViewHistoryMax = 30; // 기록 상한 (오래된 것부터 버림)

  // 본 이미지 기록. reset=true면 기록을 비우고 새 세션 시작 (새 이미지 전송/모자이크).
  // 버튼으로 되돌아간 전환은 이 함수를 부르지 않으므로 기록되지 않는다 (계속 거꾸로 걷기 가능).
  void recordI2iView(Uint8List bytes, NaiMetadata? meta, {bool reset = false}) {
    if (reset) {
      _i2iViewHistory.clear();
      _i2iViewCursor = -1;
    }
    // 지금 보고 있는 것과 같은 이미지는 중복 기록하지 않음
    if (_i2iViewCursor >= 0 && identical(_i2iViewHistory[_i2iViewCursor].bytes, bytes)) {
      return;
    }
    // 커서가 중간이면(되돌아간 상태에서 새 전환) 커서 뒤를 잘라냄 — 브라우저 히스토리 방식
    if (_i2iViewCursor < _i2iViewHistory.length - 1) {
      _i2iViewHistory.removeRange(_i2iViewCursor + 1, _i2iViewHistory.length);
    }
    _i2iViewHistory.add((bytes: bytes, meta: meta));
    if (_i2iViewHistory.length > _i2iViewHistoryMax) {
      _i2iViewHistory.removeAt(0);
    }
    _i2iViewCursor = _i2iViewHistory.length - 1;
  }

  // 직전에 본 이미지로 전환 (기록을 한 칸 뒤로). 더 갈 곳이 없으면 false (무반응).
  bool i2iGoBackView() {
    if (_i2iViewCursor <= 0) {
      return false;
    }
    _i2iViewCursor--;
    final entry = _i2iViewHistory[_i2iViewCursor];
    i2iMaskActionOnChange = I2iMaskAction.keepMask; // 비교 용도의 전환 → 마스크 유지
    targetI2iImage = entry.bytes;
    targetI2iMetadata = entry.meta;
    notifyListeners();
    return true;
  }

  // 앞으로(기록을 한 칸 앞으로) — 뒤로 갔던 것을 되돌린다. 최상위면 false (무반응).
  bool i2iGoForwardView() {
    if (_i2iViewCursor < 0 || _i2iViewCursor >= _i2iViewHistory.length - 1) {
      return false;
    }
    _i2iViewCursor++;
    final entry = _i2iViewHistory[_i2iViewCursor];
    i2iMaskActionOnChange = I2iMaskAction.keepMask; // 비교 용도의 전환 → 마스크 유지
    targetI2iImage = entry.bytes;
    targetI2iMetadata = entry.meta;
    notifyListeners();
    return true;
  }

  // 이미지를 바꾸지 않고 "마스크만 즉시 해제"해야 할 때 쓰는 리비전 카운터.
  // (예: 인페인트 자동전환 OFF + 자동해제 ON) 증가시키면 i2i_tab이 1회만 반영.
  int i2iMaskClearRevision = 0;

  // 릴의 결과를 작업 이미지로 채택 (이어서 인페인트 등)
  void useI2iResult(int index) {
    if (index < 0 || index >= i2iResults.length) {
      return;
    }
    i2iMaskActionOnChange = I2iMaskAction.keepMask; // 릴 탭은 마스킹 유지
    targetI2iImage = i2iResults[index].bytes;
    targetI2iMetadata = i2iResults[index].metadata;
    recordI2iView(i2iResults[index].bytes, i2iResults[index].metadata); // 본 이미지 기록 추가
    notifyListeners();
  }

  // 메인 히스토리로 보내기 (디스크 저장 포함)
  Future<void> promoteI2iToHistory(int index, BuildContext context) async {
    if (index < 0 || index >= i2iResults.length) {
      return;
    }
    final r = i2iResults[index];
    await addImageToHistory(
      image: r.bytes,
      metadata: r.metadata,
      context: context.mounted ? context : null,
      forceSave: true,
    );
    if (context.mounted) {}
  }

  // 폴더에 저장 (DNaiApp 갤러리 폴더로)
  Future<void> saveI2iToFolder(int index, BuildContext context) async {
    if (index < 0 || index >= i2iResults.length) {
      return;
    }
    final r = i2iResults[index];
    final path = await autoSaveImage(context.mounted ? context : null, r.bytes);
    if (!context.mounted) {
      return;
    }
    if (path != null) {
      // 어디에 무슨 이름으로 저장됐는지 알려준다 (릴에서 꾹 누르지 않고 저장했을 때 특히 유용)
      final name = path.split(RegExp(r'[/\\]')).last;
      final where = safRootUri != null ? (safRootName ?? '저장 폴더') : 'DNaiApp';
      showToast(context, "💾 $where 에 저장했어요\n$name");
    } else {
      showToast(context, "저장에 실패했습니다.");
    }
  }

  Future<void> saveI2iFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final favs = i2iResults.where((r) => r.favorite).map((r) => r.toJson()).toList();
      await prefs.setString('i2iFavorites', jsonEncode(favs));
    } catch (e) {
      debugPrint("i2i 즐겨찾기 저장 실패: $e");
    }
  }

  Future<void> loadI2iFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      i2iHandleBottom = prefs.getDouble('i2iHandleBottom') ?? -1;
      promptCharHandleTop = prefs.getDouble('promptCharHandleTop') ?? -1;
      final s = prefs.getString('i2iFavorites');
      if (s == null || s.isEmpty) {
        return;
      }
      final list = jsonDecode(s) as List;
      i2iResults = list.map((e) => I2iResult.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (e) {
      debugPrint("i2i 즐겨찾기 로드 실패: $e");
    }
  }

  Future<void> savePromptCharHandleTop(double value) async {
    promptCharHandleTop = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('promptCharHandleTop', value);
    } catch (_) {
      // 손잡이 위치는 화면 편의값이라 저장에 실패해도 무시한다.
      // 이번 실행 중에는 promptCharHandleTop 값이 그대로 쓰인다.
    }
  }

  Future<void> saveI2iHandleBottom(double value) async {
    i2iHandleBottom = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('i2iHandleBottom', value);
    } catch (e) {
      debugPrint("i2i 핸들 위치 저장 실패: $e");
    }
  }

  void deleteAllHistory() {
    // 사용자가 일부러 전부 지웠으니 (불러오기 실패로 막아 둔) 저장을 다시 푼다
    _historyLoadFailed = false;
    historyImages.clear();
    historyMetadata.clear();
    historyFavorites.clear();
    historyFilePaths.clear();
    selectedHistoryIndex = -1;
    _fullSaveHistoryToLocal();
    notifyListeners();
  }

  void deleteNonFavoriteHistory() {
    int i = 0;
    while (i < historyImages.length) {
      if (i >= historyFavorites.length || !historyFavorites[i]) {
        historyImages.removeAt(i);
        if (i < historyMetadata.length) {
          historyMetadata.removeAt(i);
        }
        if (i < historyFavorites.length) {
          historyFavorites.removeAt(i);
        }
        if (i < historyFilePaths.length) {
          historyFilePaths.removeAt(i);
        }
      } else {
        i++;
      }
    }
    if (historyImages.isEmpty) {
      selectedHistoryIndex = -1;
    } else {
      selectedHistoryIndex = selectedHistoryIndex.clamp(0, historyImages.length - 1);
    }
    _fullSaveHistoryToLocal();
    notifyListeners();
  }

  void deleteHistoryByIndices(Set<int> indices) {
    // 큰 인덱스부터 삭제해야 인덱스가 안 밀림
    final sorted = indices.toList()..sort((a, b) => b.compareTo(a));
    for (final idx in sorted) {
      if (idx < 0 || idx >= historyImages.length) {
        continue;
      }
      historyImages.removeAt(idx);
      if (idx < historyMetadata.length) {
        historyMetadata.removeAt(idx);
      }
      if (idx < historyFavorites.length) {
        historyFavorites.removeAt(idx);
      }
      if (idx < historyFilePaths.length) {
        historyFilePaths.removeAt(idx);
      }
    }
    if (historyImages.isEmpty) {
      selectedHistoryIndex = -1;
    } else {
      selectedHistoryIndex = selectedHistoryIndex.clamp(0, historyImages.length - 1);
    }
    _fullSaveHistoryToLocal();
    notifyListeners();
  }

  void toggleHistoryFavorite(int index) {
    if (index < 0 || index >= historyFavorites.length) {
      return;
    }
    historyFavorites[index] = !historyFavorites[index];
    saveHistoryToLocal();
    notifyListeners();
  }

  // ============================================================================
  // 즐겨찾기가 아닌 가장 오래된 이미지 제거 (즐겨찾기 보호)
  // ============================================================================
  void _removeOldestNonFavorite() {
    // 즐겨찾기가 아닌 가장 오래된 인덱스 찾기
    int targetIndex = -1;
    for (int i = 0; i < historyImages.length; i++) {
      if (i >= historyFavorites.length || !historyFavorites[i]) {
        targetIndex = i;
        break;
      }
    }

    // 전부 즐겨찾기면 삭제하지 않음 (100개 초과 허용)
    if (targetIndex == -1) {
      return;
    }

    historyImages.removeAt(targetIndex);
    if (targetIndex < historyMetadata.length) {
      historyMetadata.removeAt(targetIndex);
    }
    if (targetIndex < historyFavorites.length) {
      historyFavorites.removeAt(targetIndex);
    }
    if (targetIndex < historyFilePaths.length) {
      historyFilePaths.removeAt(targetIndex);
    }

    // selectedHistoryIndex 보정
    if (targetIndex <= selectedHistoryIndex) {
      selectedHistoryIndex--;
      if (selectedHistoryIndex < 0) {
        selectedHistoryIndex = 0;
      }
    }
    historyNeedsFullSave = true; // 인덱스가 밀렸으므로 전체 저장 필요
  }

  void deleteHistoryImage(int index) {
    if (index < 0 || index >= historyImages.length) {
      return;
    }

    historyImages.removeAt(index);
    if (index < historyMetadata.length) {
      historyMetadata.removeAt(index);
    }
    if (index < historyFavorites.length) {
      historyFavorites.removeAt(index);
    }
    if (index < historyFilePaths.length) {
      historyFilePaths.removeAt(index);
    }

    if (historyImages.isEmpty) {
      selectedHistoryIndex = -1;
    } else {
      if (index <= selectedHistoryIndex) {
        selectedHistoryIndex--;
      }
      if (selectedHistoryIndex < 0) {
        selectedHistoryIndex = 0;
      }
    }
    _fullSaveHistoryToLocal(); // 인덱스 변경되므로 전체 저장
    historyNeedsFullSave = false;
    notifyListeners();
  }

  // ============================================================================
  // 히스토리 로컬 저장/불러오기 (앱 종료 후에도 유지)
  // ============================================================================
  // ============================================================================
  // 프리셋 파일 저장
  //  썸네일(base64 JPEG)이 포함돼 있어 SharedPreferences에 두기엔 너무 크다.
  //  히스토리와 같은 방식으로 앱 문서 폴더에 JSON 파일로 둔다.
  // ============================================================================
  Future<File> _presetsFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/presets.json');
  }

  // ══════════════════════════════════════════════════════════════
  // 프롬프트 사전
  // ══════════════════════════════════════════════════════════════
  //  미리보기 그림을 품고 있어 SharedPreferences 가 아니라 파일에 둔다.
  //  (프리셋과 같은 이유 — prefs 는 앱 시작 때 통째로 메모리에 올라온다)
  List<PromptDictEntry> promptDict = [];
  List<PromptDictCategory> promptDictCategories = [];

  /// 확대 입력창의 사전 선택 창에서 마지막으로 고른 분류 (앱을 켜 있는 동안만 기억).
  ///  캐릭터 입력창에서 '캐릭터' 분류를 골라 두면 다음에 열 때도 그대로 보인다.
  String dictPickerFilter = kDictFilterAll;

  Future<File> _promptDictFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/prompt_dict.json');
  }

  Future<void> savePromptDict() async {
    try {
      final f = await _promptDictFile();
      // 반쯤 쓰다 꺼져도 옛 내용이 남도록 통째로 바꾼다
      await _writeAtomic(
        f,
        jsonEncode({
          'categories': promptDictCategories.map((c) => c.toJson()).toList(),
          'entries': promptDict.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('프롬프트 사전 저장 실패: $e');
    }
  }

  Future<void> _loadPromptDict() async {
    try {
      final f = await _promptDictFile();
      if (!await f.exists()) {
        return;
      }
      final raw = jsonDecode(await f.readAsString());
      // 옛 형식: 항목 목록만 있었다 (분류 기능 이전)
      if (raw is List) {
        promptDict = raw.map((e) => PromptDictEntry.fromJson(e)).toList();
      } else if (raw is Map) {
        promptDictCategories = ((raw['categories'] as List?) ?? const [])
            .map((e) => PromptDictCategory.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        promptDict = ((raw['entries'] as List?) ?? const [])
            .map((e) => PromptDictEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      _dropDanglingCategoryRefs();
      // 불러오기에 성공했을 때만 주인 없는 큰 이미지를 치운다
      unawaited(_cleanupDictImages());
    } catch (e) {
      debugPrint('프롬프트 사전 불러오기 실패: $e');
      // ⚠️ 빈 목록으로 시작한 채 저장하면 깨진(하지만 살릴 수도 있는) 파일을 덮어쓴다.
      //    그래서 깨진 파일은 이름을 바꿔 따로 보관하고 새로 시작한다.
      //    큰 이미지도 이번엔 치우지 않는다 (나중에 살릴 때 필요할 수 있다).
      try {
        final f = await _promptDictFile();
        if (await f.exists()) {
          await f.rename('${f.path}.broken_${DateTime.now().millisecondsSinceEpoch}');
        }
      } catch (_) {
        // 이름조차 못 바꾸면 그대로 둔다 — 앱 실행을 막지 않는다
      }
      promptDict = [];
      promptDictCategories = [];
    }
  }

  // ── 사전 큰 이미지 ──────────────────────────────────────────────
  //  목록용 작은 썸네일은 prompt_dict.json 안에(base64), 크게 볼 이미지는 파일로 따로 둔다.
  //  ⚠️ 큰 이미지(장당 40~65KB)까지 JSON 에 넣으면 앱을 켤 때마다 수 MB 를 통째로 읽고,
  //     항목 하나 고칠 때마다 통째로 다시 쓰게 된다.
  //  파일 이름은 항목 id — 목록 순서와 무관해 삭제·정렬에 안전하다.
  //  백업에는 넣지 않는다 (업데이트 전 자동 백업을 가볍게). 복원하면 작은 썸네일만 돌아온다.

  Future<Directory> _dictImageDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/prompt_dict_images');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  Future<File> _dictImageFile(String id) async => File('${(await _dictImageDir()).path}/$id.webp');

  /// 큰 이미지를 저장한다 (임시 파일에 쓴 뒤 이름만 바꿔, 도중에 꺼져도 깨진 파일이 남지 않게).
  Future<void> saveDictImage(String id, Uint8List bytes) async {
    try {
      final f = await _dictImageFile(id);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('사전 큰 이미지 저장 실패: $e');
    }
  }

  /// 큰 이미지를 읽는다. 없으면 null (그땐 작은 썸네일로 대신 보여 준다).
  Future<Uint8List?> loadDictImage(String id) async {
    try {
      final f = await _dictImageFile(id);
      return await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteDictImage(String id) async {
    try {
      final f = await _dictImageFile(id);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // 지우지 못해도 다음 정리 때 치워진다
    }
  }

  /// 어느 항목에도 속하지 않는 큰 이미지 파일을 지운다 (항목을 지운 뒤 남은 것, 쓰다 만 .tmp 등).
  Future<void> _cleanupDictImages() async {
    try {
      // ⚠️ 깨진 사전 파일(.broken_*)이 보관돼 있으면 정리하지 않는다.
      //    그 파일을 살렸을 때 필요한 큰 이미지까지 지우게 된다.
      //    (보관 파일을 지우면 다음 실행부터 다시 정리한다)
      final dictFile = await _promptDictFile();
      final hasBroken = dictFile.parent.listSync().whereType<File>().any(
        (f) => f.uri.pathSegments.last.startsWith('prompt_dict.json.broken_'),
      );
      if (hasBroken) {
        return;
      }
      final alive = promptDict.map((e) => e.id).toSet();
      final dir = await _dictImageDir();
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final id = name.endsWith('.webp') ? name.substring(0, name.length - 5) : null;
        if (id == null || !alive.contains(id)) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint('사전 이미지 정리 실패(무시): $e');
    }
  }

  void addPromptDictEntry(PromptDictEntry e) {
    promptDict.insert(0, e); // 새 항목이 맨 위에
    unawaited(savePromptDict());
    notifyListeners();
  }

  void updatePromptDictEntry(PromptDictEntry e) {
    final i = promptDict.indexWhere((x) => x.id == e.id);
    if (i < 0) {
      return;
    }
    promptDict[i] = e;
    unawaited(savePromptDict());
    notifyListeners();
  }

  /// 거르기 값이 아직 유효한가. 지워진 분류를 가리키면 '전체'를 돌려준다.
  ///  (사전 탭 칩 줄과 확대 입력창 선택 창이 함께 쓴다)
  String validDictFilter(String f) {
    if (f == kDictFilterAll || f == kDictFilterNone) {
      return f;
    }
    return promptDictCategories.any((c) => c.id == f) ? f : kDictFilterAll;
  }

  // 사전 미리보기(base64)를 푼 결과. 사전 탭과 입력창 선택 창이 함께 쓴다.
  //  원래 문자열을 함께 들고 있다가 미리보기가 바뀌면 다시 푼다.
  final Map<String, (String, Uint8List?)> _dictThumbCache = {};

  /// 사전 항목의 미리보기 바이트 (없거나 깨졌으면 null).
  Uint8List? dictThumb(PromptDictEntry e) {
    final t = e.thumbnail;
    if (t == null) {
      return null;
    }
    final c = _dictThumbCache[e.id];
    if (c != null && identical(c.$1, t)) {
      return c.$2;
    }
    Uint8List? b;
    try {
      b = base64Decode(t);
    } catch (_) {
      b = null; // 깨진 미리보기는 아이콘으로 대신한다
    }
    _dictThumbCache[e.id] = (t, b);
    return b;
  }

  /// 새 분류. 이름이 비었거나 이미 있으면 null.
  PromptDictCategory? addPromptDictCategory(String name) {
    final n = name.trim();
    if (n.isEmpty || _categoryNameTaken(n)) {
      return null;
    }
    final c = PromptDictCategory(name: n);
    promptDictCategories.add(c);
    unawaited(savePromptDict());
    notifyListeners();
    return c;
  }

  /// 분류 이름 바꾸기. 성공하면 true.
  bool renamePromptDictCategory(String id, String name) {
    final n = name.trim();
    final i = promptDictCategories.indexWhere((x) => x.id == id);
    if (i < 0 || n.isEmpty || _categoryNameTaken(n, exceptId: id)) {
      return false;
    }
    promptDictCategories[i].name = n;
    unawaited(savePromptDict());
    notifyListeners();
    return true;
  }

  /// 분류를 지운다. 안의 항목은 지우지 않고 '미분류'로 돌린다.
  void removePromptDictCategory(String id) {
    promptDictCategories.removeWhere((c) => c.id == id);
    for (final e in promptDict) {
      if (e.categoryId == id) {
        e.categoryId = null;
      }
    }
    dictPickerFilter = validDictFilter(dictPickerFilter);
    unawaited(savePromptDict());
    notifyListeners();
  }

  bool _categoryNameTaken(String name, {String? exceptId}) {
    final low = name.toLowerCase();
    // '전체'·'미분류'는 칩 이름으로 이미 쓰고 있어 헷갈리므로 막는다
    if (low == '전체' || low == '미분류') {
      return true;
    }
    return promptDictCategories.any((c) => c.id != exceptId && c.name.toLowerCase() == low);
  }

  /// 없는 분류를 가리키는 항목은 미분류로 (백업 복원·파일 손상 대비)
  void _dropDanglingCategoryRefs() {
    final ids = promptDictCategories.map((c) => c.id).toSet();
    for (final e in promptDict) {
      if (e.categoryId != null && !ids.contains(e.categoryId)) {
        e.categoryId = null;
      }
    }
  }

  /// [prefix] 로 시작하는 되돌리기 기록 중, 이제 없는 대상의 기록을 지운다.
  ///  예) prefix 'dict/' + 남아 있는 사전 id 들 → 지워진 항목의 기록만 버린다.
  ///  (캐릭터는 uid 가 얽혀 있어 _pruneCharacterUndo 가 따로 맡는다)
  void pruneUndoKeys(String prefix, Iterable<String> alive) {
    final keep = alive.toSet();
    final dead = promptUndoHistory.keys
        .where((k) => k.startsWith(prefix) && !keep.contains(k.substring(prefix.length)))
        .toList();
    for (final k in dead) {
      promptUndoHistory.remove(k);
    }
  }

  /// 되돌리기 기록의 열쇠를 바꾼다 (이름을 바꿔도 기록이 이어지게).
  void renameUndoKey(String from, String to) {
    if (from == to) {
      return;
    }
    final v = promptUndoHistory.remove(from);
    if (v != null) {
      promptUndoHistory[to] = v;
    }
  }

  void removePromptDictEntry(String id) {
    promptDict.removeWhere((x) => x.id == id);
    _dictThumbCache.remove(id);
    unawaited(deleteDictImage(id));
    // 지운 항목의 되돌리기 기록도 버린다 ('dict/new' 는 새 항목용이라 남긴다)
    pruneUndoKeys('dict/', [...promptDict.map((e) => e.id), 'new']);
    unawaited(savePromptDict());
    notifyListeners();
  }

  Future<void> savePresetsToFile() async {
    try {
      final f = await _presetsFile();
      await f.writeAsString(jsonEncode(presets.map((e) => e.toJson()).toList()));
    } catch (e) {
      debugPrint('프리셋 저장 실패: $e');
    }
  }

  /// 프리셋을 읽어 온다.
  ///  1) presets.json 이 있으면 그걸 쓴다.
  ///  2) 없으면 예전에 쓰던 prefs['presets']에서 읽어 파일로 옮기고 prefs는 지운다.
  ///     (앱을 업데이트한 사용자의 기존 프리셋이 사라지지 않게 하기 위함)
  Future<void> _loadPresets(SharedPreferences prefs) async {
    try {
      final f = await _presetsFile();
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString()) as List;
        presets = decoded.map((e) => NaiPreset.fromJson(e)).toList();
        return;
      }
    } catch (e) {
      debugPrint('프리셋 파일 읽기 실패: $e');
    }
    // 구버전 데이터 이관
    final legacy = prefs.getString('presets');
    if (legacy != null) {
      try {
        final decoded = jsonDecode(legacy) as List;
        presets = decoded.map((e) => NaiPreset.fromJson(e)).toList();
        await savePresetsToFile();
        await prefs.remove('presets');
        debugPrint('프리셋 ${presets.length}개를 파일로 이관했습니다');
      } catch (e) {
        debugPrint('프리셋 이관 실패: $e');
      }
    }
  }

  Future<Directory> _getHistoryDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final historyDir = Directory('${appDir.path}/history');
    if (!await historyDir.exists()) {
      await historyDir.create(recursive: true);
    }
    return historyDir;
  }

  // Vibe Transfer / Precise Reference 로컬 저장
  // ============================================================================
  // .naiv4vibe 파일 import/export
  // ============================================================================

  // 간단한 해시 (crypto 의존성 회피, 키 이름용)
  String _simpleHash(String input) {
    int hash = 0;
    for (int i = 0; i < input.length; i++) {
      hash = (hash * 31 + input.codeUnitAt(i)) & 0x7FFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  // 모델명 → naiv4vibe encodings 키
  String _modelToVibeKey(String model) {
    // v5는 Vibe 미지원이라 여기 오지 않아야 하지만, 안전하게 v4.5 키로 폴백
    if (model.contains("5") && !model.contains("4-5") && !model.contains("4.5")) {
      return "v4-5full";
    }
    if (model.contains("4-5") && model.contains("full")) {
      return "v4-5full";
    }
    if (model.contains("4-5") && model.contains("curated")) {
      return "v4-5curated";
    }
    if (model.contains("4") && model.contains("full")) {
      return "v4full";
    }
    if (model.contains("4") && model.contains("curated")) {
      return "v4curated";
    }
    return "v4-5full";
  }

  // 단일 vibe를 .naiv4vibe JSON 문자열로 변환
  String exportVibeToNaiv4(Map<String, dynamic> vibe) {
    final vibeKey = _modelToVibeKey(selectedModel);
    final infoExt = (vibe['infoExtracted'] as double?) ?? 1.0;
    final image = vibe['image'] as String;

    // 인코딩이 있으면 포함
    Map<String, dynamic> encodings = {};
    final encoded = vibe['_encoded'] as String?;
    if (encoded != null) {
      // 임의의 해시 키 생성 (NovelAI는 내부 해시지만, 키 이름은 중요하지 않음)
      final keyHash = _simpleHash("$image$infoExt");
      encodings = {
        vibeKey: {
          keyHash: {
            "encoding": encoded,
            "params": {"information_extracted": infoExt},
          },
        },
      };
    }

    final naiv4 = {
      "identifier": "novelai-vibe-transfer",
      "version": 1,
      "type": "image",
      "image": image,
      "id": _simpleHash(image),
      "encodings": encodings,
      "name": vibe['name'] ?? "vibe",
      "thumbnail": "data:image/jpeg;base64,$image",
      "createdAt": DateTime.now().millisecondsSinceEpoch,
      "importInfo": {
        "model": selectedModel,
        "information_extracted": infoExt,
        "strength": (vibe['strength'] as double?) ?? 0.6,
      },
    };
    return jsonEncode(naiv4);
  }

  // .naiv4vibe / .naiv4vibeBundle JSON 파싱 → vibeTransfers에 추가
  // 반환: 추가된 개수
  int importVibeFromNaiv4(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr);
      List<dynamic> vibesToImport = [];

      if (data['identifier'] == 'novelai-vibe-transfer-bundle') {
        vibesToImport = data['vibes'] as List;
      } else if (data['identifier'] == 'novelai-vibe-transfer') {
        vibesToImport = [data];
      } else {
        return 0;
      }

      int added = 0;
      for (final v in vibesToImport) {
        if (vibeTransfers.length >= 9) {
          break;
        }

        final image = v['image'] as String?;
        if (image == null) {
          continue;
        }

        final importInfo = v['importInfo'] as Map<String, dynamic>?;
        final infoExt = (importInfo?['information_extracted'] as num?)?.toDouble() ?? 1.0;
        final strength = (importInfo?['strength'] as num?)?.toDouble() ?? 0.6;

        // 현재 모델에 맞는 인코딩 추출
        String? encoded;
        final encodings = v['encodings'] as Map<String, dynamic>?;
        if (encodings != null) {
          final vibeKey = _modelToVibeKey(selectedModel);
          final modelEncodings = encodings[vibeKey] as Map<String, dynamic>?;
          if (modelEncodings != null && modelEncodings.isNotEmpty) {
            // 정보추출 값이 일치하는 인코딩 찾기
            for (final entry in modelEncodings.values) {
              final params = entry['params'] as Map<String, dynamic>?;
              final encInfoExt = (params?['information_extracted'] as num?)?.toDouble();
              if (encInfoExt == infoExt) {
                encoded = entry['encoding'] as String?;
                break;
              }
            }
            // 못 찾으면 첫 번째 인코딩 사용
            encoded ??= (modelEncodings.values.first['encoding'] as String?);
          }
        }

        final newVibe = <String, dynamic>{
          'image': image,
          'strength': strength,
          'infoExtracted': infoExt,
        };
        // 인코딩 있으면 캐시에 저장 (Anlas 절약)
        if (encoded != null) {
          newVibe['_encoded'] = encoded;
          newVibe['_encodedInfoExt'] = infoExt;
          newVibe['_encodedModel'] = selectedModel;
        }
        vibeTransfers.add(newVibe);
        added++;
      }

      if (added > 0) {
        saveReferencesToLocal();
        notifyListeners();
      }
      return added;
    } catch (e) {
      debugPrint("naiv4vibe 파싱 실패: $e");
      return -1;
    }
  }

  // Precise Reference import: (이미지 base64, metadata 항목) 리스트를 받아 추가
  // 반환: 추가된 개수
  int addPreciseFromImport(List<Map<String, dynamic>> items) {
    int added = 0;
    for (final item in items) {
      if (preciseRefs.length >= 9) {
        break;
      }
      final image = item['image'] as String?;
      if (image == null) {
        continue;
      }
      preciseRefs.add({
        'image': image,
        'type': (item['type'] as String?) ?? 'character',
        'strength': (item['strength'] as num?)?.toDouble() ?? 1.0,
        'fidelity': (item['fidelity'] as num?)?.toDouble() ?? 0.5,
        'enabled': (item['enabled'] as bool?) ?? true,
      });
      added++;
    }
    if (added > 0) {
      saveReferencesToLocal();
      notifyListeners();
    }
    return added;
  }

  // vibe 인코딩 캐시의 가벼운 지문 (identityHashCode라 O(1), 큰 문자열 해시 안 함)
  // 생성 전후로 비교해서 실제로 캐시가 갱신된 경우에만 디스크 저장을 트리거한다.
  String _vibeCacheSignature() {
    return vibeTransfers
        .map(
          (v) => '${identityHashCode(v['_encoded'])}:${v['_encodedInfoExt']}:${v['_encodedModel']}',
        )
        .join('|');
  }

  Future<void> saveReferencesToLocal() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/references.json');
      final data = {'vibeTransfers': vibeTransfers, 'preciseRefs': preciseRefs};
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint("레퍼런스 저장 실패: $e");
    }
  }

  Future<void> loadReferencesFromLocal() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/references.json');
      if (!await file.exists()) {
        return;
      }
      final data = jsonDecode(await file.readAsString());
      if (data['vibeTransfers'] != null) {
        vibeTransfers = (data['vibeTransfers'] as List).map((e) {
          final m = Map<String, dynamic>.from(e);
          if (m['strength'] != null) {
            m['strength'] = (m['strength'] as num).toDouble();
          }
          if (m['infoExtracted'] != null) {
            m['infoExtracted'] = (m['infoExtracted'] as num).toDouble();
          }
          if (m['_encodedInfoExt'] != null) {
            m['_encodedInfoExt'] = (m['_encodedInfoExt'] as num).toDouble();
          }
          return m;
        }).toList();
      }
      if (data['preciseRefs'] != null) {
        preciseRefs = (data['preciseRefs'] as List).map((e) {
          final m = Map<String, dynamic>.from(e);
          if (m['strength'] != null) {
            m['strength'] = (m['strength'] as num).toDouble();
          }
          if (m['fidelity'] != null) {
            m['fidelity'] = (m['fidelity'] as num).toDouble();
          }
          return m;
        }).toList();
      }
    } catch (e) {
      debugPrint("레퍼런스 불러오기 실패: $e");
    }
  }

  Timer? _historySaveDebounce;

  Future<void> saveHistoryToLocal() async {
    if (_historyLoadFailed) {
      return; // 불러오기에 실패한 기록을 빈 목록으로 덮어쓰지 않는다
    }
    // 빠른 연속 호출 방지 (300ms 디바운스)
    _historySaveDebounce?.cancel();
    _historySaveDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final dir = await _getHistoryDir();
        final int total = historyImages.length;

        // JSON 파일만 매번 갱신 (가볍고 빠름)
        // 반쯤 쓰다 꺼져도 옛 내용이 남도록 통째로 바꾼다
        await _writeAtomic(
          File('${dir.path}/metadata.json'),
          jsonEncode(historyMetadata.map((m) => m?.toJson()).toList()),
        );
        await _writeAtomic(File('${dir.path}/favorites.json'), jsonEncode(historyFavorites));
        await _writeAtomic(File('${dir.path}/paths.json'), jsonEncode(historyFilePaths));

        // 인덱스가 밀린 상태면 이미지 파일은 건너뛰기 (fullSave에서 처리)
        if (!historyNeedsFullSave && total > 0) {
          final lastIdx = total - 1;
          final pngFile = File('${dir.path}/img_$lastIdx.png');
          final thumbFile = File('${dir.path}/thumb_$lastIdx.jpg');
          if (!pngFile.existsSync() && !thumbFile.existsSync()) {
            await pngFile.writeAsBytes(historyImages[lastIdx]);
          }
        }

        debugPrint("✅ 히스토리 증분 저장 완료 ($total개)");
      } catch (e) {
        debugPrint("❌ 히스토리 저장 실패: $e");
      }
    });
  }

  // 앱 백그라운드/종료 시 호출 — 밀린 전체 저장 실행
  Future<void> fullSaveHistoryIfNeeded() async {
    _historySaveDebounce?.cancel();
    if (historyNeedsFullSave) {
      await _fullSaveHistoryToLocal();
      historyNeedsFullSave = false;
    }
  }

  // 전체 재정렬 저장 (삭제 등 인덱스가 바뀌는 작업 후에만 호출)
  Future<void> _fullSaveHistoryToLocal() async {
    if (_historyLoadFailed) {
      return; // 위와 같은 이유
    }
    try {
      final dir = await _getHistoryDir();

      // ⚠️ 예전엔 이미지 파일을 '먼저 전부 지운 뒤' 다시 썼다.
      //    그 사이 앱이 꺼지면(업데이트 설치창 등) 이미지가 대량으로 사라지고,
      //    불러올 때 즐겨찾기가 밀리는 원인이 됐다.
      //    이제 번호마다 '새 파일을 먼저 쓰고' 옛 짝 파일을 지운다.
      //    도중에 꺼져도 잃는 것은 그 한 장뿐이고, 두 파일이 남으면 불러올 때 새 쪽을 고른다.
      final int total = historyImages.length;
      // _trimHistoryMemory 덕에 오래된 이미지는 이미 썸네일 (~10KB)
      final futures = <Future>[];
      for (int i = 0; i < total; i++) {
        // 썸네일은 이제 WebP 인데 파일 이름은 옛 그대로 thumb_i.jpg 를 쓴다.
        //  (불러올 때 확장자가 아니라 내용으로 그림을 읽으므로 문제없고, 옛 기록과도 호환된다)
        final bool isSmall = historyImages[i].length < kThumbBytesLimit;
        final keep = File('${dir.path}/${isSmall ? 'thumb_$i.jpg' : 'img_$i.png'}');
        final other = File('${dir.path}/${isSmall ? 'img_$i.png' : 'thumb_$i.jpg'}');
        futures.add(
          keep.writeAsBytes(historyImages[i], flush: true).then((_) async {
            if (await other.exists()) {
              await other.delete();
            }
          }),
        );
      }
      // 병렬 쓰기
      await Future.wait(futures);

      // 목록이 줄었으면 뒤에 남은 번호의 파일을 치운다
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final m = RegExp(r'^(?:img|thumb)_(\d+)\.(?:png|jpg)$').firstMatch(name);
        if (m != null && int.parse(m.group(1)!) >= total) {
          await f.delete();
        }
      }

      // JSON 은 이미지를 다 쓴 '뒤'에, 통째로 바꾼다 (반쯤 쓴 파일이 남지 않게)
      await _writeAtomic(
        File('${dir.path}/metadata.json'),
        jsonEncode(historyMetadata.map((m) => m?.toJson()).toList()),
      );
      await _writeAtomic(File('${dir.path}/favorites.json'), jsonEncode(historyFavorites));
      await _writeAtomic(File('${dir.path}/paths.json'), jsonEncode(historyFilePaths));

      debugPrint("✅ 히스토리 전체 저장 완료 ($total개)");
    } catch (e) {
      debugPrint("❌ 히스토리 전체 저장 실패: $e");
    }
  }

  /// i 번 히스토리 이미지 파일을 읽는다. 없으면 null.
  ///
  /// 원본(img_i.png)과 썸네일(thumb_i.jpg)이 둘 다 있으면 '더 최근에 쓴 쪽'을 고른다.
  ///  (저장 도중 꺼지면 옛 파일이 남아 있을 수 있다 — 옛 것을 고르면 엉뚱한 그림이 된다)
  Future<Uint8List?> _readHistoryImageFile(Directory dir, int i) async {
    final png = File('${dir.path}/img_$i.png');
    final jpg = File('${dir.path}/thumb_$i.jpg');
    final hasPng = await png.exists();
    final hasJpg = await jpg.exists();
    if (!hasPng && !hasJpg) {
      return null;
    }
    File pick = hasPng ? png : jpg;
    if (hasPng && hasJpg) {
      pick = (await jpg.lastModified()).isAfter(await png.lastModified()) ? jpg : png;
    }
    try {
      return await pick.readAsBytes();
    } catch (_) {
      return null; // 읽다 실패하면 없는 것으로 친다
    }
  }

  /// JSON 목록 파일을 읽는다. 없거나 깨졌으면 빈 목록.
  Future<List> _readJsonList(File f) async {
    try {
      if (!await f.exists()) {
        return const [];
      }
      final v = jsonDecode(await f.readAsString());
      return v is List ? v : const [];
    } catch (_) {
      // 반쯤 쓰다 꺼진 파일일 수 있다 — 앱을 멈추지 않고 빈 값으로 넘어간다
      return const [];
    }
  }

  /// 파일을 '통째로' 바꾼다: 임시 파일에 다 쓴 뒤 이름만 바꾼다.
  ///  ⚠️ 그냥 덮어쓰다 앱이 꺼지면 반쯤 쓴 JSON 이 남아 다음 실행에 읽지 못한다.
  ///     이름 바꾸기는 한 번에 일어나므로 '옛 내용' 아니면 '새 내용'만 남는다.
  Future<void> _writeAtomic(File f, String content) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }

  Future<void> _loadHistoryFromLocal() async {
    isHistoryLoading = true;
    try {
      final dir = await _getHistoryDir();
      final metaFile = File('${dir.path}/metadata.json');
      if (!await metaFile.exists()) {
        isHistoryLoading = false;
        notifyListeners();
        return;
      }

      final metaJson = jsonDecode(await metaFile.readAsString()) as List;

      // 즐겨찾기·경로를 '먼저' 읽어 둔다.
      //  ⚠️ 이 둘은 이미지와 번호로 짝지어져 있다. 예전엔 이미지를 읽다가 파일이
      //     없는 번호를 건너뛰고, 즐겨찾기는 통째로 읽어서 — 파일 하나만 빠져도
      //     그 뒤 즐겨찾기가 전부 한 칸씩 밀렸다. (업데이트 설치창이 앱을 끄는 등
      //     저장 도중에 꺼지면 파일이 빠질 수 있다 → "즐겨찾기가 풀렸다")
      //     이제 이미지를 담을 때 같은 번호의 즐겨찾기·경로를 함께 담는다.
      final List favJson = await _readJsonList(File('${dir.path}/favorites.json'));
      final List pathsJson = await _readJsonList(File('${dir.path}/paths.json'));

      final List<Uint8List> loadedImages = [];
      final List<NaiMetadata?> loadedMeta = [];
      final List<bool> loadedFav = [];
      final List<String?> loadedPaths = [];

      for (int i = 0; i < metaJson.length; i++) {
        final bytes = await _readHistoryImageFile(dir, i);
        if (bytes == null) {
          continue; // 이 번호는 통째로 건너뛴다 (즐겨찾기·경로도 함께)
        }
        // ⚠️ 한 장의 정보가 깨져도 그 한 장만 비우고 계속 읽는다.
        //    예전엔 여기서 예외가 나면 히스토리 전체가 빈 채로 시작했고,
        //    그 상태에서 새로 저장하면 디스크의 기록까지 덮어써 모두 잃었다.
        NaiMetadata? meta;
        try {
          meta = metaJson[i] != null ? NaiMetadata.fromJson(metaJson[i]) : null;
        } catch (_) {
          meta = null; // 프롬프트 정보만 잃고 그림·즐겨찾기는 살린다
        }
        loadedImages.add(bytes);
        loadedMeta.add(meta);
        loadedFav.add(i < favJson.length && favJson[i] == true);
        final p = i < pathsJson.length ? pathsJson[i] : null;
        loadedPaths.add(p is String ? p : null);
      }

      // 네 목록을 한꺼번에 바꾼다 (길이가 항상 같다)
      historyImages = loadedImages;
      historyMetadata = loadedMeta;
      historyFavorites = loadedFav;
      historyFilePaths = loadedPaths;

      if (loadedImages.length != metaJson.length) {
        debugPrint("⚠️ 히스토리 이미지 ${metaJson.length - loadedImages.length}개 누락 — 즐겨찾기는 제자리 유지");
        // 빠진 번호를 정리해 다음 실행부터는 번호가 다시 맞게 한다
        historyNeedsFullSave = true;
        unawaited(fullSaveHistoryIfNeeded());
      }

      if (historyImages.isNotEmpty) {
        selectedHistoryIndex = historyImages.length - 1;
      }
      debugPrint("✅ 히스토리 ${historyImages.length}개 로컬에서 불러오기 완료");
      await _trimHistoryMemory(); // 오래된 이미지 썸네일 변환
      isHistoryLoading = false;
      notifyListeners();
    } catch (e) {
      debugPrint("❌ 히스토리 불러오기 실패: $e");
      // ⚠️ 불러오지 못한 채로 저장하면 디스크의 기록을 빈 목록으로 덮어쓴다.
      //    이번 실행 동안은 히스토리 저장을 멈춰 원본 파일을 지킨다.
      //    (새로 만든 그림은 저장 폴더에는 그대로 저장된다)
      _historyLoadFailed = true;
      isHistoryLoading = false;
      notifyListeners();
    }
  }

  /// 히스토리를 불러오지 못했는지. true 면 히스토리 파일을 건드리지 않는다.
  bool _historyLoadFailed = false;

  // ============================================================================
  // 파일 존재 여부 확인
  // ============================================================================
  // 경로별 존재 여부 캐시.
  //  이 함수는 히스토리 그리드/리스트의 itemBuilder에서 불리므로
  //  스크롤 한 번에 수십~수백 번 호출된다. 매번 디스크를 두드리면
  //  스크롤이 눈에 띄게 끊기므로 결과를 기억해 둔다.
  //  (저장·삭제처럼 파일이 바뀌는 시점에 invalidateFileExistsCache로 비운다)
  final Map<String, bool> _fileExistsCache = {};

  void invalidateFileExistsCache([String? path]) {
    if (path == null) {
      _fileExistsCache.clear();
    } else {
      _fileExistsCache.remove(path);
    }
  }

  bool checkFileExistsSync(int index) {
    if (index < 0 || index >= historyFilePaths.length) {
      return false;
    }
    final path = historyFilePaths[index];
    if (path == null || path.isEmpty) {
      return false;
    }
    final cached = _fileExistsCache[path];
    if (cached != null) {
      return cached;
    }
    final exists = File(path).existsSync();
    _fileExistsCache[path] = exists;
    // 캐시가 무한정 커지지 않게 (히스토리 상한보다 넉넉히)
    if (_fileExistsCache.length > 300) {
      _fileExistsCache.remove(_fileExistsCache.keys.first);
    }
    return exists;
  }

  // ============================================================================
  // 히스토리 이미지가 썸네일(경량)인지 확인
  // ============================================================================
  bool isHistoryThumbnail(int index) {
    if (index < 0 || index >= historyImages.length) {
      return false;
    }
    final bytes = historyImages[index];
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true; // JPEG = 썸네일
    }
    return false; // PNG = 원본
  }

  // ============================================================================
  // 메타데이터로 이미지 재생성 (썸네일만 있는 경우)
  // ============================================================================
  // ============================================================================
  // 메타데이터 표시 모델명 → API 모델 ID 변환
  // (예: "NovelAI Diffusion V4.5 4BDE2A90" → "nai-diffusion-4-5-full")
  // 뒤의 해시는 패치마다 바뀌므로 버전 키워드로 매칭
  // ============================================================================
  String _resolveModelId(String displayName) {
    final lower = displayName.toLowerCase();

    // 이미 API 모델 ID 형식이면 그대로 반환
    if (lower.startsWith('nai-diffusion')) {
      return displayName;
    }

    // 버전 키워드 매칭 (구체적인 것부터 체크)
    // v5 메타데이터가 v4로 오인되지 않도록 v5를 먼저 검사한다.
    if (lower.contains('v5')) {
      return NaiModels.v5Full;
    }
    if (lower.contains('v4.5')) {
      return NaiModels.v45Full;
    }
    if (lower.contains('v4')) {
      return NaiModels.v4Full;
    }
    if (lower.contains('v3')) {
      return NaiModels.v3;
    }

    // 매칭 실패 → 현재 선택된 모델 사용
    return selectedModel;
  }

  Future<void> regenerateFromMetadata(BuildContext context, int index) async {
    if (index < 0 || index >= historyMetadata.length) {
      return;
    }
    final meta = historyMetadata[index];
    if (meta == null) {
      if (context.mounted) {
        showToast(context, "메타데이터가 없어 재생성할 수 없습니다.");
      }
      return;
    }

    if (apiToken.isEmpty) {
      if (context.mounted) {
        showToast(context, "API 토큰이 설정되지 않았습니다.");
      }
      return;
    }

    isLoading = true;
    notifyListeners();

    try {
      List<Map<String, dynamic>> characters = [];
      for (int i = 0; i < meta.characterPrompts.length; i++) {
        characters.add({
          'positive': meta.characterPrompts[i],
          'negative': i < meta.characterUndesiredContents.length
              ? meta.characterUndesiredContents[i]
              : '',
          'gridX': 2,
          'gridY': 2,
        });
      }

      final result = await _service.generateImage(
        positive: meta.positive,
        negative: meta.negative,
        token: apiToken,
        model: meta.source.isNotEmpty ? _resolveModelId(meta.source) : selectedModel,
        steps: meta.steps > 0 ? meta.steps : 28,
        sampler: meta.sampler.isNotEmpty ? meta.sampler : selectedSampler,
        scheduler: meta.extraParams['noise_schedule']?.toString() ?? selectedScheduler,
        width: meta.width > 0 ? meta.width : 832,
        height: meta.height > 0 ? meta.height : 1216,
        cfgScale: meta.promptGuidance > 0 ? meta.promptGuidance : 6.0,
        cfgRescale: meta.promptGuidanceRescale,
        seed: meta.seed,
        characters: characters,
        variancePlus: meta.extraParams['variety_plus'] == true,
      );

      if (result.image != null) {
        historyImages[index] = result.image!;

        String? savedPath;
        if (context.mounted) {
          savedPath = await autoSaveImage(context, result.image!);
        } else {
          savedPath = await autoSaveImage(null, result.image!);
        }
        if (index < historyFilePaths.length) {
          historyFilePaths[index] = savedPath;
          if (savedPath != null) {
            _fileExistsCache[savedPath] = true; // 방금 저장했으므로 존재
          }
        }
        saveHistoryToLocal();
      } else if (result.error != null && context.mounted) {
        showToast(context, "재생성 실패: ${result.error}");
      }
      // 잔액·한도 갱신은 기다리지 않는다 (버튼이 그만큼 늦게 풀린다)
      refreshBalanceInBackground();
    } catch (e) {
      debugPrint("재생성 오류: $e");
      if (context.mounted) {
        showToast(context, "재생성 중 오류가 발생했습니다.");
      }
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  String _getFormattedFileName(String suffix) {
    String format = customFileNameController.text.trim();
    if (format.isEmpty) {
      format = "Nai-{yy}{mm}{dd}-{time}";
    }
    DateTime now = DateTime.now();
    String yy = DateFormat('yyyy').format(now);
    String mm = DateFormat('MM').format(now);
    String dd = DateFormat('dd').format(now);
    String time = DateFormat('HHmmss').format(now);
    String parsed = format
        .replaceAll('{yy}', yy)
        .replaceAll('{mm}', mm)
        .replaceAll('{dd}', dd)
        .replaceAll('{time}', time)
        .replaceAll('{count}', sessionSaveCount.toString().padLeft(3, '0'));
    return suffix.isEmpty ? parsed : "${parsed}_$suffix";
  }

  /// 저장 직전 준비: 설정에 맞춰 형식을 바꾸고 확장자를 정한다.
  ///  ⚠️ 예전엔 자동 저장·수동 저장에 똑같은 코드가 두 벌 있었다. 여기 하나로 모은다.
  Future<(Uint8List, String)> _prepareForSave(Uint8List bytes) async {
    // JPEG(밖에서 가져온 그림)는 건드리지 않는다
    if (isJpeg(bytes)) {
      return (bytes, 'jpg');
    }
    var format = saveFormat;
    // ⚠️ 투명 배경으로 뽑은 그림을 손실 WebP 로 저장하면 알파가 뭉개진다 → 무손실로
    if (format == SaveFormat.webpLossy && transparentBackground) {
      format = SaveFormat.webpLossless;
    }
    if (format.quality == null) {
      return (bytes, format.ext); // 원본 그대로 쓰는 형식
    }
    final converted = await _convertWithMetadata(bytes, format);
    // 실패하면 원본(PNG) 그대로 저장한다
    return converted == null ? (bytes, SaveFormat.png.ext) : (converted, format.ext);
  }

  // PNG 바이트를 [format] 으로 굽고 원본 메타데이터를 옮겨 담는다.
  // 실패하면 null을 반환해 호출부가 원본(PNG)으로 폴백하도록 한다.
  //  ⚠️ 새 저장 형식을 더할 때는 메타데이터를 담는 방법도 정해야 한다
  //     (PNG 는 tEXt 청크, WebP 는 EXIF — 형식마다 다르다).
  Future<Uint8List?> _convertWithMetadata(Uint8List pngBytes, SaveFormat format) async {
    try {
      // 1) 원본 PNG 의 글자 청크를 '전부' 먼저 확보 (변환하면 사라지므로).
      //    Comment(파라미터)만 옮기면 novelai.net/inspect 가 Title·Description·
      //    Software·Source 를 못 보여 준다 — NovelAI 와 같은 모양으로 전부 옮긴다.
      //    생성 파라미터가 없는 그림(모자이크 결과 등)은 메타데이터 없이 굽는다.
      final chunks = extractPngTextChunks(pngBytes);
      final bool hasParams = paramsJsonOf(chunks) != null; // PNG 를 다시 훑지 않는다

      // 2) 굽기 — 품질·방식은 image_codec.dart 의 SaveFormat 이 정한다
      //    ⚠️ 공용 인코더를 쓴다. 플러그인을 직접 부르면 크기 기본값(1920×1080)
      //       때문에 업스케일한 큰 그림(예: 2176×3840)이 저장할 때 조용히 줄어든다.
      final encoded = await encodeForSave(pngBytes, format);
      if (encoded == null) {
        return null;
      }

      // 3) 메타데이터가 있으면 형식에 맞게 이식
      if (!hasParams) {
        return encoded;
      }
      switch (format.ext) {
        case 'webp':
          return injectExifIntoWebp(encoded, buildExifBlock(chunks)) ?? encoded;
        default:
          return encoded; // 이식 방법이 정해지지 않은 형식은 그림만
      }
    } catch (e) {
      debugPrint('${format.ext} 변환 실패(원본 유지): $e');
      return null;
    }
  }

  Future<String?> autoSaveImage(BuildContext? context, Uint8List bytes) async {
    sessionSaveCount++;
    final sessionFolder = _resolveSessionFolder();

    String fileName = _getFormattedFileName("");
    // 설정에 맞춰 형식을 바꾸고 확장자를 정한다 (실패하면 원본 그대로)
    final (saveBytes, ext) = await _prepareForSave(bytes);
    bytes = saveBytes;

    // 0차: SAF 폴더가 지정돼 있으면 그곳에 저장 (MANAGE 권한 불필요)
    if (safRootUri != null) {
      final safPath = await _saveImageViaSaf(bytes, fileName, ext);
      if (safPath != null) {
        return safPath;
      }
      // SAF 저장 실패 시 아래 기존 경로로 폴백
    }

    // 앱 전용 외부 디렉토리 (권한 불필요)
    try {
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        final directory = Directory('${appDir.path}/DNaiApp/$sessionFolder');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File("${directory.path}/$fileName.$ext");
        await file.writeAsBytes(bytes);
        _scanMedia(file.path);
        return file.path;
      }
    } catch (e) {
      debugPrint("앱 디렉토리 저장 실패: $e");
    }

    // 3차 시도: 임시 디렉토리 (최후의 수단)
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File("${tempDir.path}/$fileName.$ext");
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (e) {
      debugPrint("임시 디렉토리 저장 실패: $e");
    }

    return null;
  }

  Future<void> manualSaveImage(BuildContext context, Uint8List bytes) async {
    sessionSaveCount++;
    final sessionFolder = _resolveSessionFolder();

    String fileName = _getFormattedFileName("Manual");
    final messenger = ScaffoldMessenger.of(context); // async gap 전에 캡처
    // 자동 저장과 같은 준비 과정 (형식 변환·확장자 결정, 실패하면 원본 그대로)
    final (saveBytes, ext) = await _prepareForSave(bytes);
    bytes = saveBytes;

    // 0차: SAF 폴더가 지정돼 있으면 그곳에 저장 (MANAGE 권한 불필요)
    if (safRootUri != null) {
      final safPath = await _saveImageViaSaf(bytes, fileName, ext);
      if (safPath != null) {
        notifyListeners();
        return;
      }
      // SAF 저장 실패 시 아래 기존 경로로 폴백
    }

    // 앱 전용 디렉토리 (권한 불필요)
    try {
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        final directory = Directory('${appDir.path}/DNaiApp/$sessionFolder');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        final file = File("${directory.path}/$fileName.$ext");
        await file.writeAsBytes(bytes);
        _scanMedia(file.path);
        notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint("앱 디렉토리 수동 저장 실패: $e");
    }

    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(milliseconds: 2400),
        content: Text("저장에 실패했습니다. 저장 경로를 확인해주세요."),
      ),
    );
    notifyListeners();
  }

  void _scanMedia(String filePath) {
    if (Platform.isAndroid) {
      try {
        MediaScanner.loadMedia(path: filePath);
      } catch (_) {
        // 갤러리 앱에 새 파일을 알리는 작업. 실패해도 파일은 이미 저장돼 있고,
        // 기기가 다음에 스캔할 때 잡힌다.
      }
    }
  }

  /// 계정 목록을 갱신하는 중인지. UI에서 새로고침 스피너를 띄우는 데 쓴다.
  bool isRefreshingAccounts = false;

  /// 등록된 모든 계정의 잔액·할당량을 확인한다.
  ///  계정을 갈아끼우지 않고 각 토큰으로 직접 조회하므로 현재 연결이 끊기지 않는다.
  ///  [force]가 false면 최근에 확인한 계정은 건너뛴다(API 호출 낭비 방지).
  Future<void> refreshAllAccountQuotas({bool force = false, Duration? maxAge}) async {
    if (isRefreshingAccounts || naiAccounts.isEmpty) {
      return;
    }
    final stale = maxAge ?? const Duration(minutes: 5);
    isRefreshingAccounts = true;
    notifyListeners();
    try {
      final now = DateTime.now();
      for (final acc in naiAccounts) {
        if (acc.token.trim().isEmpty) {
          continue;
        }
        if (!force && acc.checkedAtMs > 0) {
          final age = now.difference(DateTime.fromMillisecondsSinceEpoch(acc.checkedAtMs));
          if (age < stale) {
            continue; // 아직 신선하다
          }
        }
        try {
          final r = await _service.fetchUserInfo(acc.token);
          if (r != null) {
            acc.anlas = (r['anlas'] as int?) ?? 0;
            acc.limitPercent = r['usagePercent'] as double?;
            acc.checkedAtMs = DateTime.now().millisecondsSinceEpoch;
            // 지금 쓰고 있는 계정이면 화면 상단 표시값도 같이 맞춘다
            if (identical(acc, activeAccount)) {
              currentAnlas = acc.anlas;
              subscriptionTier = (r['tier'] as int?) ?? subscriptionTier;
              v5LimitPercent = acc.limitPercent;
              v5LimitNegative = r['usageNegative'] == true;
              v5LimitNextSec = (r['usageNextSec'] as int?) ?? 0;
              v5LimitCheckedAt = DateTime.now();
              isApiConnected = true;
            }
          }
        } catch (e) {
          debugPrint('계정 "${acc.label}" 조회 실패: $e');
        }
        notifyListeners(); // 한 계정씩 즉시 반영 (전부 끝날 때까지 기다리지 않게)
      }
      await saveAllSettings();
    } finally {
      isRefreshingAccounts = false;
      notifyListeners();
    }
  }

  Future<void> fetchAnlas() async {
    if (apiToken.isEmpty) {
      // 토큰이 없으면 잔액도 없는 상태로 되돌린다
      currentAnlas = 0;
      isApiConnected = false;
      final empty = activeAccount;
      if (empty != null) {
        empty.anlas = -1;
      }
      notifyListeners();
      return;
    }
    final result = await _service.fetchUserInfo(apiToken);
    if (result != null) {
      currentAnlas = (result['anlas'] as int?) ?? 0;
      subscriptionTier = (result['tier'] as int?) ?? 0;
      isApiConnected = true;
      // V5 사용 한도 (Opus 전용 — 응답에 없으면 null 그대로)
      v5LimitPercent = result['usagePercent'] as double?;
      v5LimitNegative = result['usageNegative'] == true;
      v5LimitNextSec = (result['usageNextSec'] as int?) ?? 0;
      v5LimitCheckedAt = DateTime.now();
      // 계정 목록에도 잔액/한도를 기록해 어느 계정이 여유 있는지 보이게 한다
      final acc = activeAccount;
      if (acc != null) {
        acc.anlas = currentAnlas;
        acc.limitPercent = v5LimitPercent;
        acc.checkedAtMs = DateTime.now().millisecondsSinceEpoch;
      }
      notifyListeners();
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Anlas 추정
  // ══════════════════════════════════════════════════════════════
  //
  // ⚠️ 공식 계산식을 재현하지 못했다.
  //    널리 쓰이는 SDK 의 식(면적 x 스텝 선형)을 그대로 넣어 보면 실제 표시값과
  //    1.5배쯤 어긋나고, 계수를 다시 맞춰 봐도 관측 12개를 동시에 만족하는
  //    값이 존재하지 않았다. 식의 구조 자체가 다른 것으로 보인다.
  //
  //    그래서 공식 앱에서 직접 읽은 값을 표로 넣고, 표에 없는 조건은
  //    가까운 값에서 비례로 추정한다. 어디까지나 '대략' 이므로
  //    화면에도 '약 N Anlas' 로 표시한다.
  //
  //    측정 환경: Opus, 1장, V4.5 (2026-09)
  //    표를 늘리려면 공식 웹에서 생성 버튼의 숫자를 읽어 아래에 추가하면 된다.
  //    (1MP 이하 해상도는 28스텝까지 무료라 0 이 뜬다.
  //     값을 보려면 스텝을 29 이상으로 올리거나 장수를 2로 둘 것)
  static const Map<int, Map<int, int>> _anlasTable = {
    // 1024x1536 (1,572,864px)
    1572864: {23: 39, 24: 41, 25: 42, 26: 44, 27: 45, 28: 45},
    // 1088x1920 (2,088,960px)
    2088960: {23: 51, 24: 54, 25: 56, 26: 57, 27: 59, 28: 60},
  };

  /// 이미지 한 장을 만드는 데 드는 Anlas 추정치. 모르면 -1.
  ///
  /// [strength] 를 주면 인페인트·img2img 로 계산한다.
  ///  (실측 확인: 생성 비용 x 강도, 올림. 최소 2)
  int _estimateSingleAnlas(int width, int height, int steps, {double? strength}) {
    final int pixels = width * height;

    int? base;
    final table = _anlasTable[pixels];
    if (table != null) {
      base = table[steps];
      if (base == null && table.isNotEmpty) {
        // 표에 없는 스텝은 가장 가까운 스텝에서 비례로 늘린다
        final nearest = table.keys.reduce((a, b) => (a - steps).abs() <= (b - steps).abs() ? a : b);
        base = (table[nearest]! * steps / nearest).ceil();
      }
    } else {
      // 면적이 표에 없으면, 표에서 가장 가까운 면적을 찾아 면적 비로 늘린다
      if (_anlasTable.isEmpty) {
        return -1;
      }
      final nearPixels = _anlasTable.keys.reduce(
        (a, b) => (a - pixels).abs() <= (b - pixels).abs() ? a : b,
      );
      final nearTable = _anlasTable[nearPixels]!;
      final nearStep = nearTable.keys.reduce(
        (a, b) => (a - steps).abs() <= (b - steps).abs() ? a : b,
      );
      base = (nearTable[nearStep]! * (pixels / nearPixels) * (steps / nearStep)).ceil();
    }

    if (base == null || base <= 0) {
      return -1;
    }
    if (strength == null) {
      return base;
    }
    final v = (base * strength).ceil();
    return v < 2 ? 2 : v;
  }

  /// 이번에 실행할 작업의 Anlas 추정치를 돌려주는 단일 진입점.
  ///
  ///  · 0  = 소모 없음 (Opus 무료 범위 등)
  ///  · -1 = 추정할 수 없음 (표에 없는 조건)
  ///
  /// 작업마다 계산 규칙이 꽤 다르기 때문에, 여기서는 '어느 계산기를 쓸지'만 고르고
  /// 실제 셈은 각 계산기에 맡긴다. 규칙을 한 함수에 몰아넣으면 조건문이 겹겹이
  /// 쌓여 오히려 고치기 어려워진다.
  ///
  /// 호출부는 이 함수 하나만 부르면 된다. '소모되는가'는 결과가 0인지로 판단한다.
  int anlasFor(AnlasJob job) {
    switch (job) {
      case AnlasJob.generate:
        return _estimateImageJob();
      case AnlasJob.inpaint:
        return _estimateImageJob(strength: infillStrength);
      case AnlasJob.img2img:
        return _estimateImageJob(strength: img2imgStrength);
      case AnlasJob.director:
        return directorCostFor(directorTool);
      case AnlasJob.upscale:
        // V5 업스케일러는 입력 크기·구독 등급과 무관하게 고정 비용이다
        return NovelAiService.upscaleAnlasCost;
    }
  }

  /// 생성·인페인트·img2img 공통 계산.
  ///  [strength] 가 있으면 인페인트 계열(기본 비용 x 강도)로 본다.
  int _estimateImageJob({double? strength}) {
    if (!checkIfAnlasConsumed()) {
      return 0; // 무료 조건이면 굳이 추정하지 않는다
    }
    final (w, h) = _plannedResolution();
    final steps = int.tryParse(stepsController.text) ?? 28;

    int per = _estimateSingleAnlas(w, h, steps, strength: strength);
    if (per < 0) {
      return -1;
    }

    // 배치: 무한(0)은 셀 수 없으므로 1장 기준으로 둔다
    int count = batchCount <= 0 ? 1 : batchCount;
    // Opus 는 28스텝 이하·1MP 이하 한 장을 무료로 만들어 준다
    if (subscriptionTier >= 3 && steps <= 28 && (w * h) <= kMegapixelCap && count > 0) {
      count -= 1;
    }

    final extras = calculateVibeAnlas() + calculatePreciseAnlas();
    return per * count + extras;
  }

  /// 추정치를 화면에 보여 줄 문장으로 바꾼다.
  ///  ⚠️ 공식 계산식을 재현하지 못해 실측 표 기반 추정이다. 그래서 '약' 을 붙인다.
  static String anlasText(int cost) {
    if (cost == 0) {
      return "Anlas가 소모되지 않습니다.";
    }
    if (cost < 0) {
      return "Anlas가 소모됩니다. (소모량은 추정할 수 없습니다)";
    }
    return "약 $cost Anlas가 소모됩니다.";
  }

  /// 지금 설정으로 생성했을 때 실제로 쓰일 해상도.
  ///  비용 추정과 소모 여부 판단이 같은 값을 보도록 한 곳으로 모았다.
  (int, int) _plannedResolution() {
    int width = 832;
    int height = 1216;

    if (resolutionMode == "랜덤") {
      width = 1024;
      height = 1024;
    } else if (resolutionMode == "자동" && currentImageWidth > 0 && currentImageHeight > 0) {
      double maxPixels = kMegapixelCap.toDouble();
      double ratio = currentImageWidth / currentImageHeight;
      double h = sqrt(maxPixels / ratio);
      double w = h * ratio;
      width = (w / 64).round() * 64;
      height = (h / 64).round() * 64;

      while ((width * height) > kMegapixelCap) {
        if (width > height) {
          width -= 64;
        } else {
          height -= 64;
        }
      }
      if (width < 64) {
        width = 64;
      }
      if (height < 64) {
        height = 64;
      }
    } else if (selectedResolution == "직접 입력" ||
        (resolutionMode == "자동" && currentImageWidth == 0)) {
      width = int.tryParse(customWidthController.text) ?? 832;
      height = int.tryParse(customHeightController.text) ?? 1216;
    } else {
      List<String> resParts = selectedResolution.replaceAll(" ", "").split("x");
      width = int.parse(resParts[0]);
      height = int.parse(resParts[1]);
    }

    // 배율 적용
    if (resolutionScale != 1.0) {
      width = ((width * resolutionScale) / 64).round() * 64;
      height = ((height * resolutionScale) / 64).round() * 64;
    }

    // 64px 정렬 + 모델별 픽셀 상한 적용 (공용 헬퍼)
    (width, height) = clampResolution(width, height, modelCapsFor(selectedModel).maxPixels);

    return (width, height);
  }

  bool checkIfAnlasConsumed() {
    final (width, height) = _plannedResolution();

    int steps = int.tryParse(stepsController.text) ?? 28;
    bool isOpus = subscriptionTier >= 3;

    // 모델이 지원하지 않으면 vibe/precise는 전송되지 않으므로 비용 계산에서도 제외
    final capsForCost = modelCapsFor(selectedModel);

    // 활성 Precise Reference는 항상 Anlas 소모
    bool hasPrecise =
        capsForCost.supportsPrecise && preciseRefs.any((r) => (r['enabled'] as bool?) ?? true);
    if (hasPrecise) {
      return true;
    }

    // Vibe Transfer: 활성화된 것만, 인코딩 안 된 것이 있거나 4개 초과면 Anlas 소모
    final activeVibes = capsForCost.supportsVibe
        ? vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList()
        : <Map<String, dynamic>>[];
    if (activeVibes.isNotEmpty) {
      bool hasUnencodedVibe = activeVibes.any((v) => v['_encoded'] == null);
      bool tooManyVibes = activeVibes.length > 4;
      if (hasUnencodedVibe || tooManyVibes) {
        return true;
      }
      // 전부 인코딩됨 + 4개 이하 → 해상도/스텝 기준으로만 판단 (아래로 진행)
    }

    if (isOpus && (width * height) <= kMegapixelCap && steps <= 28) {
      return false;
    }

    return true;
  }

  // Vibe Transfer Anlas 비용 계산 (UI 표시용)
  int calculateVibeAnlas() {
    final activeVibes = vibeTransfers.where((v) => (v['enabled'] as bool?) ?? true).toList();
    if (activeVibes.isEmpty) {
      return 0;
    }
    int cost = 0;
    // 인코딩 안 된 vibe당 2 Anlas
    for (final v in activeVibes) {
      if (v['_encoded'] == null) {
        cost += 2;
      }
    }
    // 4개 초과 시 추가 vibe당 2 Anlas
    if (activeVibes.length > 4) {
      cost += (activeVibes.length - 4) * 2;
    }
    return cost;
  }

  // Precise Reference Anlas 비용 계산 (활성 이미지당 +5 Anlas)
  int calculatePreciseAnlas() {
    final activePrecise = preciseRefs.where((r) => (r['enabled'] as bool?) ?? true).toList();
    return activePrecise.length * 5;
  }

  void selectWildcard(int index) {
    if (index > 0 && index < wildcards.length) {
      final selected = wildcards.removeAt(index);
      wildcards.insert(0, selected);
    }
    selectedWildcardIndex = 0;
    saveAllSettings();
    notifyListeners();
  }

  void deleteWildcard(int index) {
    if (wildcards.isEmpty || index < 0 || index >= wildcards.length) {
      return;
    }

    wildcards.removeAt(index);
    // 지운 와일드카드의 되돌리기 기록도 버린다
    pruneUndoKeys('wildcard/', wildcards.map((w) => w.name));

    if (wildcards.isNotEmpty) {
      selectedWildcardIndex = 0;
    } else {
      wildcards.add(NaiWildcard(name: "새 와일드카드", content: ""));
      selectedWildcardIndex = 0;
    }

    saveAllSettings();
    notifyListeners();
  }
}

// ============================================================================
// 조건부 트리거 파서 (재귀 하강)
// ============================================================================
class _ConditionParser {
  final String _input;
  final List<String> _tags;
  final String _rating;
  final AppState _state;
  int _pos = 0;

  _ConditionParser(this._input, this._tags, this._rating, this._state);

  void _skipSpaces() {
    while (_pos < _input.length && _input[_pos] == ' ') {
      _pos++;
    }
  }

  // or_expr = and_expr ('|' and_expr)*
  bool parseOrExpr() {
    bool result = _parseAndExpr();
    while (_pos < _input.length) {
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == '|') {
        _pos++;
        bool right = _parseAndExpr();
        result = result || right;
      } else {
        break;
      }
    }
    return result;
  }

  // and_expr = atom ('&' atom)*
  bool _parseAndExpr() {
    bool result = _parseAtom();
    while (_pos < _input.length) {
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == '&') {
        _pos++;
        bool right = _parseAtom();
        result = result && right;
      } else {
        break;
      }
    }
    return result;
  }

  // atom = '!' atom | '(' or_expr ')' | pattern
  bool _parseAtom() {
    _skipSpaces();
    if (_pos >= _input.length) {
      return false;
    }

    // 부정 연산자
    if (_input[_pos] == '!') {
      _pos++;
      return !_parseAtom();
    }

    // 괄호 그룹
    if (_input[_pos] == '(') {
      _pos++; // '(' 건너뛰기
      bool result = parseOrExpr();
      _skipSpaces();
      if (_pos < _input.length && _input[_pos] == ')') {
        _pos++; // ')' 건너뛰기
      }
      return result;
    }

    // 패턴 (& | ) 까지 읽기)
    StringBuffer buf = StringBuffer();
    while (_pos < _input.length &&
        _input[_pos] != '&' &&
        _input[_pos] != '|' &&
        _input[_pos] != ')') {
      buf.write(_input[_pos]);
      _pos++;
    }
    String pattern = buf.toString().trim();
    if (pattern.isEmpty) {
      return false;
    }

    return _state._matchAtom(pattern, _tags, _rating);
  }
}
