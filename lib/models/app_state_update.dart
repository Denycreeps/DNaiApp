// lib/models/app_state_update.dart
//
// AppState 의 앱 업데이트 쪽 — 새 버전 확인 · 릴리즈 노트 미리보기 · APK 내려받기/설치 ·
// 업데이트 전 자동 백업 · 받아 둔 APK 정리.
//  · app_state.dart 의 일부(part)라 AppState 의 숨은 값(_safUtil · exportSettings …)도 그대로 쓴다.
//  · 값(latestVersion · downloadProgress · isBackingUpBeforeUpdate · _autoBackupDoneFor …)과
//    static(currentVersion · githubRepo)은 AppState 에 그대로 있고, 여기에는 메서드만 있다
//    (확장 — 필드는 확장에 둘 수 없다. 값을 바꾸지 않는 static 상수 · 함수는 확장에 둘 수 있어 함께 옮겼다).
//  ⚠️ 여기서는 notifyListeners() 대신 refreshUI() 를 부른다 — notifyListeners 는 AppState 안에서만 부를 수 있다.
//  ⚠️ AppState 의 static 멤버는 'AppState.' 를 붙여 부른다 (확장 안에서는 생략할 수 없다).
part of 'app_state.dart';

extension AppStateUpdate on AppState {
  bool get hasUpdate =>
      latestVersion != null && _compareVersions(latestVersion!, AppState.currentVersion) > 0;

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
            Uri.parse('https://api.github.com/repos/${AppState.githubRepo}/releases?per_page=30'),
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

        if (best != null && _compareVersions(bestTag, AppState.currentVersion) > 0) {
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
          refreshUI();
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
  //  · 담는 것: 설정·계정·프리셋·와일드카드·캐릭터·프롬프트 사전(크게 볼 이미지까지)
  //    + 히스토리 전체 (작은 썸네일로)
  //    (3.9 까지는 즐겨찾기 히스토리만, 사전은 작은 썸네일만 담았다.
  //     그걸로 되살려 보니 히스토리는 거의 비어 있고 사전 그림은 흐려서 쓸 수가 없었다.
  //     히스토리 썸네일은 대부분 이미 작게 들고 있어 전체를 담아도 몇 초 안 걸린다)
  //  · 저장 위치: 저장 폴더의 settings/ — 앱을 지워도 남는 곳
  //  · 저장 폴더를 아직 안 정했으면 조용히 건너뛴다 (업데이트를 막지 않는다)
  //  · 자동 백업은 최근 [_autoBackupKeep] 개만 남긴다

  static const int _autoBackupKeep = 3;
  static const String _autoBackupPrefix = 'DNaiApp_autobackup_';

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
    refreshUI();
    try {
      final data = await exportSettings(includeHistory: true);
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp =
          '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
      // 파일 이름은 영문·숫자만 — 저장소·PC 로 옮길 때 깨지지 않게
      final name =
          '$_autoBackupPrefix'
          'v${AppState.currentVersion}_to_v${latestVersion ?? 'x'}_$stamp.json';
      // 히스토리·사전 그림까지 들어가 수십 MB 가 될 수 있다 — JSON 만들기는 화면 밖에서
      final shown = await saveSettingsViaSaf(name, await AppState.encodeSettingsJson(data));
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
      refreshUI();
    }
  }

  /// 설치창을 열기 전에 백업이 끝나기를 기다린다.
  ///  ⚠️ 무한정 기다리지 않는다 — 저장소가 느리거나 멈춰도 업데이트는 진행돼야 한다.
  ///  3.10 부터 백업에 히스토리 전체·사전 큰 이미지가 들어가 예전(20초)보다 넉넉히 기다린다.
  ///  (그래도 넘기면 설치가 시작되며 앱이 꺼진다 — 쓰던 백업은 임시 이름이라 '깨진 백업'으로 남지 않는다)
  Future<void> _waitBackup(Future<String?> backup) async {
    try {
      await backup.timeout(const Duration(seconds: 60));
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
      final dir = await _safUtil.mkdirp(root, ['settings']);
      final all = await _safUtil.list(dir.uri);
      // 쓰다 만 임시 파일(앱이 쓰는 도중에 꺼진 것)을 치운다. 막 쓰고 있는 것일 수 있어 10분 지난 것만.
      final int now = DateTime.now().millisecondsSinceEpoch;
      for (final f in all) {
        if (!f.isDir &&
            f.name.startsWith(AppState._kSafWritingPrefix) &&
            now - f.lastModified > 10 * 60 * 1000) {
          try {
            await _safUtil.delete(f.uri, false);
          } catch (_) {
            // 못 지워도 숨김 파일이라 눈에 띄지 않는다 — 다음 정리 때 다시 해 본다
          }
        }
      }
      // 최신순 — 이름 끝의 '_날짜_시각'(yyyymmdd_hhmm)으로 정한다.
      //  ⚠️ 예전엔 이름 전체를 글자순으로 거꾸로 세웠다. 이름이 버전으로 시작해서
      //     글자로는 'v3.10…' 이 'v3.9…' 보다 앞이라(1 < 9), 3.10 으로 넘어온 뒤엔
      //     막 만든 백업이 '가장 오래된 것'으로 보여 곧바로 지워질 수 있었다.
      //  (같은 이름이 있어 '이름 (1).json' 이 돼도 날짜·시각은 그대로 찾는다)
      final stampOf = RegExp(r'_(\d{8})_(\d{4})');
      int stamp(String name) {
        RegExpMatch? last;
        for (final m in stampOf.allMatches(name)) {
          last = m; // 이름에 버전 등 다른 숫자가 있어도 '맨 끝' 날짜·시각을 쓴다
        }
        return last == null ? 0 : int.parse('${last[1]}${last[2]}');
      }

      final items = all.where((f) => !f.isDir && f.name.startsWith(_autoBackupPrefix)).toList()
        ..sort((a, b) {
          final c = stamp(b.name).compareTo(stamp(a.name));
          return c != 0 ? c : b.lastModified.compareTo(a.lastModified);
        });
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
      if (await file.length() != expected) {
        return false;
      }
      // 크기 기록만으론 부족하다 — 3.10 이전엔 끊긴 파일의 크기도 그대로 기록했다.
      //  APK 모양까지 맞아야 쓴다 (아니면 다시 받는다)
      return await _looksLikeCompleteApk(file);
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
        // 받다 만 임시 파일(.apk.part)은 언제나 치운다 — 받는 도중엔 이 정리가 돌지 않는다
        //  (앱을 켤 때 · 다 받은 뒤에만 돈다). 수십 MB 라 남겨 두면 공간만 먹는다.
        if (name.startsWith('DNaiApp_v') && name.endsWith('.apk.part')) {
          await f.delete();
          continue;
        }
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

  /// APK 를 [url] 에서 받아 [file] 로 둔다. 반환: 받은 크기. 실패하면 예외 (부른 쪽이 '실패'를 알린다).
  ///
  ///  ⚠️ 예전 방식의 문제 (받다가 끊기거나 서버가 이상한 답을 줄 때):
  ///   · 받은 내용을 List of int 에 모았다 — 숫자 하나가 4~8바이트라 APK 크기의 몇 배를 메모리에
  ///     올렸다. 메모리가 적은 폰에서는 받다가 앱이 꺼질 수 있었다. → 받는 대로 파일에 흘려 쓴다.
  ///   · 응답 코드를 안 봐서 404 같은 오류 페이지도 APK 로 저장했다.
  ///   · 받은 크기를 안 봐서 중간에 끊긴 파일이 '다 받은 파일'로 기억됐다. 그 뒤로는 다시 받지 않아
  ///     설치창이 매번 '파싱 오류'를 냈다 (다음 버전이 나올 때까지).
  ///   · 시간 제한이 없어 받다가 멈추면 '다운로드 중'으로 굳어 다시 누를 수도 없었다.
  ///  → 임시 파일(.part)에 받고, 응답 코드·크기·APK 모양이 맞을 때만 진짜 이름으로 바꾼다.
  Future<int> _downloadApkTo(File file, String url) async {
    final part = File('${file.path}.part');
    final client = http.Client();
    IOSink? sink;
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('APK 응답 코드 ${response.statusCode}');
      }
      final int expected = response.contentLength ?? 0;
      sink = part.openWrite();
      int received = 0;
      // 30초 동안 한 조각도 오지 않으면 멈춘 것으로 본다 (전체 시간이 아니라 '조각 사이' 간격)
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        if (expected > 0) {
          downloadProgress = received / expected;
          refreshUI();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received == 0 || (expected > 0 && received != expected)) {
        throw HttpException('APK 크기가 맞지 않음 ($received / $expected)');
      }
      if (!await _looksLikeCompleteApk(part)) {
        throw const HttpException('받은 파일이 APK 모양이 아님');
      }
      await part.rename(file.path); // 같은 이름의 옛 파일이 있으면 바꿔 끼운다
      return received;
    } catch (_) {
      // 쓰다 만 임시 파일은 지운다 (다음에 처음부터 다시 받는다)
      try {
        await sink?.close();
      } catch (_) {
        // 이미 닫혔거나 닫다 실패 — 아래에서 파일째 지운다
      }
      try {
        if (await part.exists()) {
          await part.delete();
        }
      } catch (_) {
        // 못 지운 임시 파일은 진짜 APK 로 쓰이지 않는다 (.part 이름이라)
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  /// APK(=ZIP) 파일이 끝까지 온전해 보이는지 — 앞머리가 'PK 3 4', 끝쪽에 'PK 5 6'(목록 끝 표시).
  ///  오류 페이지(HTML)나 중간에 끊긴 파일을 거른다. 확인하다 실패해도 false.
  static Future<bool> _looksLikeCompleteApk(File f) async {
    RandomAccessFile? raf;
    try {
      raf = await f.open();
      final int len = await raf.length();
      if (len < 22) {
        return false;
      }
      final head = await raf.read(4);
      if (head.length < 4 ||
          head[0] != 0x50 ||
          head[1] != 0x4B ||
          head[2] != 0x03 ||
          head[3] != 0x04) {
        return false;
      }
      // 목록 끝 표시는 22바이트 + 주석(최대 64KB) 안쪽, 파일 맨 끝에 있다
      final int tailLen = len < 65557 ? len : 65557;
      await raf.setPosition(len - tailLen);
      final tail = await raf.read(tailLen);
      for (int i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
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
    refreshUI();

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
        refreshUI();
        await _waitBackup(backup);
        // 파일을 확인하는 사이 화면이 닫혔을 수 있다
        if (!context.mounted) {
          return;
        }
        await _openApk(file, context);
        return;
      }

      // 스트리밍 다운로드 (프로그레스 표시) — 끝까지 제대로 받았을 때만 file 이 생긴다
      final int size = await _downloadApkTo(file, apkDownloadUrl!);
      // 다음에 설치가 취소돼도 다시 받지 않도록 크기를 기록해 둔다
      await _rememberApkSize(latestVersion, size);
      // 옛 버전 파일은 이제 필요 없다
      await _cleanupOldApks(keep: file.path);

      isDownloadingUpdate = false;
      downloadProgress = 1.0;
      refreshUI();

      await _waitBackup(backup);
      // 받는 동안 화면이 닫혔을 수 있다 (수십 초가 걸리기도 한다)
      if (!context.mounted) {
        return;
      }
      await _openApk(file, context);
    } catch (e) {
      isDownloadingUpdate = false;
      downloadProgress = 0.0;
      refreshUI();
      debugPrint("업데이트 다운로드 실패: $e");
      if (context.mounted) {
        showToast(context, "다운로드에 실패했습니다.");
      }
    }
  }
}
