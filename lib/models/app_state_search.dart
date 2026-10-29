// lib/models/app_state_search.dart
//
// AppState 의 프롬프트 검색(Gelbooru) 쪽 — 검색 돌리기 · 받은 목록 보관(파일) · 다음/다시 불러오기 ·
// 본인 API 키 읽기.
//  · app_state.dart 의 일부(part)라 AppState 의 숨은 값(_service · _holdBackground …)도 그대로 쓴다.
//  · 값(gelbooruPrompts · currentPromptIndex · 검색 설정 …)은 AppState 에 그대로 있고,
//    여기에는 그 값을 다루는 메서드만 있다 (확장 — 필드는 확장에 둘 수 없다).
//  · 글자 처리(검색어 펼치기 · 받은 태그 다듬기)는 순수 함수라 prompt_search.dart 에 따로 있다 (테스트 있음).
//  ⚠️ 여기서는 notifyListeners() 대신 refreshUI() 를 부른다 — notifyListeners 는 AppState 안에서만 부를 수 있다.
part of 'app_state.dart';

extension AppStateSearch on AppState {
  void parseGelbooruApi() {
    String input = gelbooruApiController.text;
    final userIdMatch = RegExp(r'user_id=([^&\s]+)').firstMatch(input);
    final apiKeyMatch = RegExp(r'api_key=([^&\s]+)').firstMatch(input);
    gelbooruUserId = userIdMatch?.group(1) ?? "";
    gelbooruApiKey = apiKeyMatch?.group(1) ?? "";
  }

  // ── 프롬프트 검색 목록(gelbooruPrompts) 보관 ──
  //  예전엔 SharedPreferences 에 통째로 넣었다. 결과가 많으면(최대 1만 2천 개, 수 MB):
  //   · 안드로이드 설정 파일(XML)은 값 '하나' 만 바뀌어도 전체를 다시 쓴다
  //     → '다음 프롬프트' 로 순번만 바뀌어도 (배치 생성이면 한 장마다) 수 MB 를 다시 썼다.
  //   · 앱을 내릴 때 안드로이드가 밀린 설정 쓰기를 화면 쪽에서 기다린다 → 클수록 멈칫·ANR 위험.
  //   · 앱을 켤 때 이 수 MB 를 통째로 읽어야 다른 설정도 읽혔다.
  //  → 목록은 파일에 따로 두고 바뀔 때(검색 성공)만 쓴다. 설정에는 순번(currentPromptIndex)만 남는다.
  static const String _kLegacyPromptsKey = 'gelbooruPrompts'; // 예전 버전이 설정에 쓰던 이름

  Future<File> _gelbooruPromptsFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/gelbooru_prompts.json');

  /// 목록 → JSON 바이트 (수 MB 라 다른 isolate 에서).
  ///  ⚠️ static 이어야 한다 — 안에서 만드는 함수가 AppState(this)를 붙잡으면 isolate 로 못 보낸다.
  static Future<Uint8List> _encodePromptList(List<String> list) =>
      Isolate.run(() => utf8.encode(jsonEncode(list)));

  /// 목록 파일을 읽어 푼다 (다른 isolate 에서). 형식이 틀리면 예외.
  static Future<List<String>> _decodePromptListFile(String path) => Isolate.run(() async {
    final v = jsonDecode(await File(path).readAsString());
    if (v is! List) {
      throw const FormatException('검색 목록 파일이 아님');
    }
    return [for (final e in v) if (e is String) e];
  });

  /// 지금 검색 목록을 파일에 쓴다. 반환: 썼는지.
  ///  쓰고 나면 예전 버전이 설정에 남긴 사본을 지운다 (설정 파일이 다시 가벼워진다).
  Future<bool> _saveGelbooruPromptsFile() async {
    final int seq = ++_promptsSaveSeq;
    final List<String> snapshot = gelbooruPrompts; // 쓰는 사이 새 검색이 목록을 바꿔도 이 모습으로
    try {
      final f = await _gelbooruPromptsFile();
      final bytes = await _encodePromptList(snapshot);
      if (seq != _promptsSaveSeq) {
        return true; // 그 사이 더 새 목록 저장이 시작됐다 — 그쪽이 쓴다 (옛 목록이 나중에 덮지 않게)
      }
      await _writeBytesAtomic(f, bytes);
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_kLegacyPromptsKey)) {
        await prefs.remove(_kLegacyPromptsKey);
      }
      return true;
    } catch (e) {
      debugPrint('검색 목록 저장 실패: $e');
      return false;
    }
  }

  /// 앱을 켤 때 검색 목록을 불러온다.
  ///  ① 예전 버전이 설정에 둔 목록이 (비어 있지 않게) 남아 있으면 그걸 쓰고 파일로 옮긴다.
  ///     (파일보다 이쪽을 믿는다: 남아 있다는 건 '옮기다 꺼졌다'(내용 같음) 거나
  ///      '옛 버전으로 내렸다 다시 올렸다'(이쪽이 더 새것) 둘 중 하나라서)
  ///     설정 쪽 사본은 파일 쓰기가 '성공한 뒤에만' 지운다.
  ///  ② 아니면 파일에서 읽는다. 깨졌으면 이름을 바꿔 남기고 빈 목록으로 시작한다.
  Future<void> _loadGelbooruPrompts(SharedPreferences prefs) async {
    _gelbooruPromptsLoaded = true; // 읽기를 '마쳤다' (성공·파일 없음·깨짐 모두)
    final List<String>? legacy = prefs.getStringList(_kLegacyPromptsKey);
    if (legacy != null && legacy.isNotEmpty) {
      gelbooruPrompts = legacy;
      if (await _saveGelbooruPromptsFile()) {
        debugPrint('검색 목록 ${legacy.length}개를 설정에서 파일로 옮겼습니다');
      }
      return;
    }
    if (legacy != null) {
      try {
        await prefs.remove(_kLegacyPromptsKey); // 빈 사본 — 남겨 둘 이유가 없다
      } catch (_) {
        // 못 지워도 그만이다 (다음 검색 저장 때 다시 지운다) — 앱 켜기를 막지 않는다
      }
    }
    try {
      final f = await _gelbooruPromptsFile();
      if (!await f.exists()) {
        gelbooruPrompts = [];
        return;
      }
      try {
        gelbooruPrompts = await _decodePromptListFile(f.path);
      } on FormatException catch (e) {
        // 내용이 깨졌다 — 다음 검색이 덮어쓰기 전에 따로 남겨 둔다 (프리셋·사전과 같은 방식)
        debugPrint('검색 목록 파일이 깨짐 (빈 목록으로 시작): $e');
        gelbooruPrompts = [];
        await f.rename('${f.path}.broken_${DateTime.now().millisecondsSinceEpoch}');
      }
    } catch (e) {
      // 읽기 자체가 잠깐 실패했다 (메모리 부족 등) — 파일은 멀쩡할 수 있으니 건드리지 않는다.
      //  이번 실행만 빈 목록이고, 다음에 켤 때 다시 읽힌다 (그 전에 새로 검색하면 그 결과가 맞다).
      debugPrint('검색 목록 파일 읽기 실패: $e');
    }
  }

  /// 검색 목록·순번에 맞춰 '다음 (P : N)' 숫자를 다시 맞춘다 (handleNextPrompt 와 같은 규칙)
  void _syncPromptCounters() {
    // 목록(파일)과 순번(설정)은 따로 저장된다 — 둘 사이에서 앱이 꺼지면 순번이 목록보다 클 수 있다.
    //  그대로 두면 '다음' 을 누르는 순간 범위 오류가 난다 → 처음부터.
    if (currentPromptIndex < 0 || currentPromptIndex >= gelbooruPrompts.length) {
      currentPromptIndex = 0;
    }
    gelbooruTotal = gelbooruPrompts.length;
    final int left = gelbooruTotal - currentPromptIndex;
    gelbooruRemaining = gelbooruTotal == 0 ? 0 : (left <= 0 ? gelbooruTotal : left);
  }

  Future<void> handleGelbooruSearch(BuildContext context) async {
    // 버튼은 검색 중 꺼지지만, 화면이 다시 그려지기 전에 두 번 눌리면 둘 다 들어올 수 있다
    if (isGelbooruLoading) {
      return;
    }
    // 레이팅을 하나도 안 골랐으면 모든 그림을 빼는 검색이라 결과가 늘 0 이다 — 요청을 보내기 전에 알려 준다
    //  (예전엔 묶음마다 첫 페이지를 다 받고 나서야 '검색 결과 없음' 이 떠, 원인이 레이팅인 줄 몰랐다)
    if (!ratingG && !ratingS && !ratingQ && !ratingE) {
      showToast(context, "레이팅(G · S · Q · E)을 하나 이상 켜 주세요");
      return;
    }
    // ⚠️ 예전 목록은 새 결과가 '성공적으로' 올 때까지 지우지 않는다.
    //  예전엔 시작하자마자 지워서, 검색 중 앱을 내리면(화면 꺼짐·다른 앱) 그 순간의 자동 저장이
    //  '빈 목록' 을 기록했다 → 검색이 실패하거나 앱이 꺼지면 예전 목록이 영영 사라졌다.
    //  지우지 않으니 검색하는 동안에도 '다음 프롬프트'·배치 생성이 예전 목록으로 계속 돈다.
    isGelbooruLoading = true;
    gelbooruSearchDone = 0;
    gelbooruSearchTotal = 0;
    gelbooruSearchFound = 0;
    gelbooruSearchStage = "";
    refreshUI();

    // 페이지를 수십 번 받는 동안 앱을 내려도 시스템이 앱을 얼리지 않게 붙잡는다.
    //  (안 붙잡으면 몇 초 뒤 얼었다가, 돌아왔을 때 요청들이 시간 초과로 끝나 '서버 응답 없음' 이 떴다)
    //  기다리지 않는다 — 처음 켤 때 권한 창이 떠도 검색은 바로 시작한다. 짝은 아래 finally.
    unawaited(_holdBackground());

    List<String>? found;
    Object? error;
    (int, int)? sampledCombos; // 조합이 많아 일부만 검색에 담았으면 (담은 수, 전체 수)
    try {
      parseGelbooruApi();
      // 포함: {A|B} 조합 하나하나가 검색 묶음 · *keyword → 사전에서 그 글자가 든 태그 중 하나 (prompt_search.dart)
      final plan = parseSearchInclude(gelbooruIncludeController.text, danbooruTags);
      // 제외: 로컬 후처리용 (API 태그 제한 회피 + 정확한 필터링)
      final localExcludeTags = expandExcludeForSearch(gelbooruExcludeController.text, danbooruTags);
      debugPrint("🔍 검색: 조합 ${plan.combinations}개 / 제외(${localExcludeTags.length}개): $localExcludeTags");

      found = await _service.fetchDanbooruTags(
        plan: plan,
        localExcludeTags: localExcludeTags, // 제외 태그는 받은 뒤에 거른다
        rG: ratingG,
        rS: ratingS,
        rQ: ratingQ,
        rE: ratingE,
        // 의상/특징 제거는 여기서 하지 않는다 (원본 보존).
        //  '다음 프롬프트'/'다시 불러오기' 때 _processAndSetPrompt 가 스위치를 보고 거른다.
        gelbooruUserId: gelbooruUserId,
        gelbooruApiKey: gelbooruApiKey,
        // API 키가 있을 때만 사용자 지정 페이지 수 적용 (null = 서비스 기본값 — 키가 없으면 15)
        maxPagesToFetch: gelbooruApiKey.isNotEmpty ? gelbooruSearchPages : null,
        onProgress: (done, total, foundCount) {
          gelbooruSearchDone = done;
          gelbooruSearchTotal = total;
          gelbooruSearchFound = foundCount; // 검색 버튼에 실시간으로 차오른다
          refreshUI();
        },
        onStage: (stage) {
          gelbooruSearchStage = stage;
          refreshUI();
        },
        onCombos: (searched, total) => sampledCombos = (searched, total),
      );
    } catch (e) {
      error = e;
    } finally {
      isGelbooruLoading = false;
      gelbooruSearchDone = 0;
      gelbooruSearchTotal = 0;
      gelbooruSearchFound = 0;
      gelbooruSearchStage = "";
      unawaited(_releaseBackground());
    }

    // 결과는 화면(context)과 상관없이 반영한다.
    //  ⚠️ 예전엔 화면이 사라졌으면(검색 중 탭 구성을 바꿔 화면이 새로 만들어지는 등) 여기서 그냥 돌아가
    //     다 받아 온 결과를 버렸고, 화면 갱신(notifyListeners)도 안 해서 검색 버튼이 꺼진 채 남았다.
    final List<String>? results = found;
    if (results != null && results.isNotEmpty) {
      results.shuffle();
      gelbooruPrompts = results;
      currentPromptIndex = 0;
      _syncPromptCounters();
      saveAllSettings(); // 순번(0)
      unawaited(_saveGelbooruPromptsFile()); // 목록 — 바뀌는 건 이때뿐
    }
    refreshUI();

    // 아래는 알림 창뿐이라 화면이 있어야 한다
    if (!context.mounted) {
      return;
    }
    if (error == null) {
      // {A|B} 조합이 너무 많아(합칠 수 없는 조각들) 일부만 검색에 담았으면 알려 준다 (다시 검색하면 다른 조합을 고른다)
      final (int, int)? sc = sampledCombos;
      if (sc != null && results != null && results.isNotEmpty) {
        final String all = sc.$2 >= kSearchCombinationCap ? "아주 많아서" : "${sc.$2}가지라";
        showToast(context, "조합이 $all 그중 ${sc.$1}가지만 골라 검색했어요 (다시 검색하면 다른 조합)");
      }
      if (results == null || results.isEmpty) {
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
      return;
    }
    // 실패 — 원인별로 안내한다 (예전 목록은 그대로 남아 있다)
    final String errorMsg = error.toString().replaceFirst('Exception: ', '');
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

  void _processAndSetPrompt(int targetIndex) {
    if (gelbooruPrompts.isEmpty) {
      return;
    }
    if (targetIndex < 0 || targetIndex >= gelbooruPrompts.length) {
      targetIndex = 0; // 순번이 목록 밖 (저장 도중 꺼짐 등) — 오류 대신 처음부터
    }
    // 한 칸 풀기 · 태그 다듬기는 순수 함수 (prompt_search.dart)
    final entry = parseSearchEntry(gelbooruPrompts[targetIndex]);
    currentImageWidth = entry.width;
    currentImageHeight = entry.height;
    final List<String> filteredTags = cleanSearchTags(entry, (
      removeCharacterTags: removeCharacterTags,
      removeCharacteristics: removeCharacteristics,
      removeClothes: removeClothes,
      removeImpliedTags: removeImpliedTags,
      removeClothingEvents: removeClothingEvents,
      removeColors: removeColors,
      customRemove: customRemoveController.text,
      prefix: prefixController.text,
      suffix: suffixController.text,
    ));

    String combined = filteredTags.join(', ');

    // 조건부 트리거가 "random" 모드일 때만 여기서 적용
    //  조건은 선행 · 후행 프롬프트까지 합쳐서 본다 — 받은 태그에서 선행 · 후행에 있는 태그는 위에서 빠지므로
    //  (cleanSearchTags), 받은 태그만 보면 선행의 1girl 을 못 보고 선행의 solo 를 또 넣었다. 바꾸는 것은 받은 태그뿐.
    String finalConditioned = conditionalTriggerMode == "random"
        ? applyConditionalRules(
            combined,
            entry.rating,
            conditionalRuleController.text,
            prefix: prefixController.text,
            suffix: suffixController.text,
          )
        : combined;
    String finalSorted = sortNovelAIPrompt(
      finalConditioned,
      ignoreRecommendedOrder: ignoreRecommendedOrder,
      alphabetical: randomPromptAlphabetical,
    );

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
    refreshUI();
  }

  /// 다음 버튼 꾹 — 바로 앞에 불렀던 프롬프트를 다시 불러온다. 순번을 한 칸 되돌린다 → 남은 수 +1
  ///  (예: 363개 중 3개를 불러 'P : 360' 이면, 꾹 → 두 번째 것을 다시 · 'P : 361').
  ///  지금 보이는 것은 [currentPromptIndex] - 1 번이라 그 앞인 - 2 번을 연다. 다음 버튼은 그 다음 것부터 이어 간다.
  ///  돌아갈 곳이 없으면 false — 목록의 첫 프롬프트를 보고 있을 때(순번 1), 아직 안 불렀을 때(0).
  ///  (끝까지 불러 처음으로 넘어간 순간도 순번이 0 이라 그때는 한 번 못 돌아간다 — '처음' 과 구별할 값이 없다)
  bool handlePrevPrompt() {
    final int n = gelbooruPrompts.length;
    if (n == 0 || currentPromptIndex < 2 || currentPromptIndex > n) {
      return false;
    }
    currentPromptIndex -= 1;
    _processAndSetPrompt(currentPromptIndex - 1);
    gelbooruRemaining = n - currentPromptIndex; // handleNextPrompt 와 같은 규칙 (1 이상이다)
    saveAllSettings();
    refreshUI();
    return true;
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
    refreshUI();
  }
}
