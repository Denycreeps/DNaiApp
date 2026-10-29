// lib/models/app_state_history.dart
//
// AppState 의 히스토리 쪽 — 넣기 · 지우기 · 즐겨찾기 · 디스크 저장/불러오기 · 썸네일 · 다시 생성 · 다시 뽑기,
// 그리고 히스토리 한 칸(HistoryEntry).
//  · app_state.dart 의 일부(part)라 AppState 의 숨은 값(_service · _writeAtomic …)도 그대로 쓴다.
//  · 값(history · selectedHistoryIndex · 저장 대기 타이머 …)은 AppState 에 그대로 있고,
//    여기에는 그 값을 다루는 메서드만 있다 (확장 — 필드는 확장에 둘 수 없다).
//  · 저장 형식은 DEVNOTES '히스토리 저장 형식 (3.9.0~)' 참고.
//  ⚠️ 여기서는 notifyListeners() 대신 refreshUI() 를 부른다 — notifyListeners 는 AppState 안에서만 쓰게 돼 있다
//     (밖에서 부르면 분석기 경고).
//  ⚠️ AppState 의 static 멤버는 'AppState.' 를 붙여 부른다 (확장 안에서는 생략할 수 없다).
part of 'app_state.dart';

extension AppStateHistory on AppState {
  // ============================================================================
  // 히스토리에 넣기 — 생성 · i2i · 이미지 불러오기 · 갤러리
  // ============================================================================
  Future<String?> addImageToHistory({
    required Uint8List image,
    required NaiMetadata? metadata,
    BuildContext? context,
    bool forceSave = false, // true면 isAutoSave 무시하고 저장
    String? presetFilePath, // 이미 디스크에 있는 파일(갤러리 등): 이 경로 사용
    bool skipAutoSave = false, // 불러오기/갤러리 추가: 자동저장 안 함
    HistoryEntry? keep, // 상한(kHistoryCap)이 찼을 때 이 칸은 지우지 않는다 (다시 생성의 원래 썸네일 칸)
  }) async {
    if (history.length >= AppState.kHistoryCap) {
      _removeOldestNonFavorite(keep: keep);
    }
    // 칸을 먼저 넣고, 저장이 끝나면 '그 칸에' 경로를 적는다.
    //  ⚠️ 예전엔 이미지·즐겨찾기·정보를 먼저 넣고 경로는 저장이 끝난 뒤 '맨 끝에' 붙였다.
    //     그 사이에 다른 추가·정리가 끼거나 저장이 끝나는 순서가 바뀌면 경로가 이웃 칸에 붙었다.
    final entry = HistoryEntry(image: image, metadata: metadata);
    history.add(entry);
    // 넣자마자 화면에 알린다 — 아래 저장(형식 변환 · 저장 폴더 쓰기, 수백 ms)을 기다리는 사이에도
    //  화면이 새 번호로 다시 그려지게.
    //  ⚠️ 예전엔 저장이 끝난 뒤에야 알려, 상한이 찬 채 한 장 빠지고 들어온 그 사이엔 화면의 칸들이 옛 번호를 들고 있었다 —
    //     그때 별을 누르면 옆 칸의 즐겨찾기가 풀리고(나중에 상한 정리로 사라진다), 꾹 눌러 지우면 옆 칸이 지워졌다.
    selectedHistoryIndex = history.length - 1;
    scrollToThumbnailEnd = true;
    refreshUI();

    if (presetFilePath != null) {
      entry.filePath = presetFilePath;
    } else if (!skipAutoSave && (forceSave || isAutoSave)) {
      entry.filePath = await autoSaveImage(
        (context != null && context.mounted) ? context : null,
        image,
      );
    }
    final String? savedPath = entry.filePath;

    saveHistoryToLocal();
    // 오래된 이미지를 썸네일로 줄이는 작업. 화면에 이미 뜬 이미지와는 무관하므로
    // 기다리지 않는다 (기다리면 그만큼 생성 버튼이 늦게 풀린다).
    unawaited(_trimHistoryMemory());

    return savedPath;
  }

  Future<void> importImageToHistory(BuildContext context) async {
    try {
      // 고르며 생긴 캐시 복사본은 읽은 뒤 지운다 (utils/temp_files.dart)
      final Uint8List? bytes = await pickGalleryImageBytes();

      if (bytes != null) {
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

  // 바이트를 히스토리에 추가 (이미지 불러오기 / 갤러리 추가 공용)
  // 핵심 적재는 addImageToHistory를 재사용하고, 메타 파싱·알림·메시지만 담당
  Future<void> addBytesToHistory(
    Uint8List bytes,
    BuildContext context, {
    String? filePath,
    bool showSuccess = true,
  }) async {
    // 글자 칸이 지워진 그림(사이트에 올렸다 받은 것)은 알파 채널까지 본다 (readNovelAIMetadata)
    final NaiMetadata? parsedMeta = await readNovelAIMetadata(bytes);
    await addImageToHistory(
      image: bytes,
      metadata: parsedMeta,
      context: context.mounted ? context : null, // 정보를 읽는 사이 화면이 닫혔을 수 있다
      presetFilePath: filePath, // 전달된 실제 경로 사용 (없으면 null)
      skipAutoSave: true, // 불러온/기존 파일은 자동저장 안 함
    );
    refreshUI();

    if (!showSuccess || !context.mounted) {
      return;
    }
  }

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
    // 변환할 칸과 그 그림 — 번호가 아니라 칸으로 잡는다 (줄이는 사이 상한 정리로 번호가 밀려도 그 칸에 넣게)
    final List<HistoryEntry> toConvert = [];
    final List<Uint8List> toConvertData = [];
    for (int i = 0; i < cutoff; i++) {
      if (history[i].image.length < kThumbBytesLimit) {
        continue;
      }
      toConvert.add(history[i]);
      toConvertData.add(history[i].image);
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

    // 변환하는 동안 칸이 지워졌거나 그림이 바뀌었을 수 있다 — 그 칸에 '그 그림' 이 그대로일 때만 바꾼다.
    //  (지워진 칸이면 바꿔도 아무도 안 본다 — 저장에서도 빠진다)
    //  ⚠️ 예전엔 번호로 찾아, 상한이 찬 채 새 그림이 들어와 번호가 밀리면 줄인 썸네일을 버렸다.
    for (int j = 0; j < toConvert.length; j++) {
      final HistoryEntry e = toConvert[j];
      if (identical(e.image, toConvertData[j])) {
        e.image = thumbnails[j];
      }
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
  // 지우기 · 즐겨찾기
  // ============================================================================
  void deleteAllHistory() {
    // 사용자가 일부러 전부 지웠으니 (불러오기 실패로 막아 둔) 저장을 다시 푼다
    _historyLoadFailed = false;
    history.clear();
    selectedHistoryIndex = -1;
    _fullSaveHistoryToLocal();
    refreshUI();
  }

  void deleteNonFavoriteHistory() {
    history.removeWhere((e) => !e.favorite);
    if (historyImages.isEmpty) {
      selectedHistoryIndex = -1;
    } else {
      selectedHistoryIndex = selectedHistoryIndex.clamp(0, historyImages.length - 1);
    }
    _fullSaveHistoryToLocal();
    refreshUI();
  }

  /// 고른 칸들을 지운다 (그리드 '선택 삭제') — 번호가 아니라 칸(객체)으로.
  ///  ⚠️ 예전엔 번호로 받았다. 고르는 사이 상한이 찬 채 새 그림이 들어오면 맨 앞 칸이 빠져 번호가 하나씩 밀려,
  ///     옆 칸(즐겨찾기도)이 대신 지워졌다.
  void deleteHistoryEntries(Iterable<HistoryEntry> entries) {
    // 먼저 복사한다 — 넘겨받은 것이 그리드의 고른 목록이면, 아래 refreshUI 가 그 목록을 고친다 (없어진 칸 빼기)
    final Set<HistoryEntry> gone = entries.toSet(); // HistoryEntry 는 == 를 바꾸지 않아 '같은 객체' 로 찾는다
    // 보고 있던 그림 — 앞쪽 칸이 지워져도 그 그림을 계속 가리키게 (지워졌으면 가까운 칸으로)
    final HistoryEntry? viewing = selectedHistoryIndex >= 0 && selectedHistoryIndex < history.length
        ? history[selectedHistoryIndex]
        : null;
    history.removeWhere(gone.contains);
    final int stillThere = viewing == null ? -1 : history.indexOf(viewing);
    if (stillThere >= 0) {
      selectedHistoryIndex = stillThere;
    }
    if (historyImages.isEmpty) {
      selectedHistoryIndex = -1;
    } else {
      selectedHistoryIndex = selectedHistoryIndex.clamp(0, historyImages.length - 1);
    }
    _fullSaveHistoryToLocal();
    refreshUI();
  }

  /// 즐겨찾기 켜고 끄기 — 번호가 아니라 칸(객체)으로 (그리드의 별).
  ///  ⚠️ 예전엔 번호로 받아, 상한이 찬 채 새 그림이 들어와 번호가 밀린 사이에 누르면 옆 칸의 별이 바뀌었다.
  void toggleHistoryFavorite(HistoryEntry entry) {
    if (!history.contains(entry)) {
      return; // 그 사이 지워진 칸
    }
    entry.favorite = !entry.favorite;
    saveHistoryToLocal();
    refreshUI();
  }

  // ============================================================================
  // 즐겨찾기가 아닌 가장 오래된 이미지 제거 (즐겨찾기 보호)
  // ============================================================================
  void _removeOldestNonFavorite({HistoryEntry? keep}) {
    // 즐겨찾기가 아닌 가장 오래된 인덱스 찾기 ([keep] 칸은 건너뛴다)
    final int targetIndex = history.indexWhere((e) => !e.favorite && !identical(e, keep));

    // 전부 즐겨찾기면 삭제하지 않음 (상한 초과 허용)
    if (targetIndex == -1) {
      return;
    }

    history.removeAt(targetIndex);

    // selectedHistoryIndex 보정
    if (targetIndex <= selectedHistoryIndex) {
      selectedHistoryIndex--;
      if (selectedHistoryIndex < 0) {
        selectedHistoryIndex = 0;
      }
    }
  }

  void deleteHistoryImage(int index) {
    if (index < 0 || index >= history.length) {
      return;
    }

    history.removeAt(index);

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
    _fullSaveHistoryToLocal();
    refreshUI();
  }

  // ============================================================================
  // 히스토리 로컬 저장/불러오기 (앱 종료 후에도 유지)
  // ============================================================================
  Future<Directory> _getHistoryDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final historyDir = Directory('${appDir.path}/history');
    if (!await historyDir.exists()) {
      await historyDir.create(recursive: true);
    }
    return historyDir;
  }

  // ── 히스토리 디스크 저장 ──────────────────────────────────────────
  //  history.json : [{id, metadata, favorite, filePath}, …] — 칸의 순서와 정보 (한 파일이라 늘 서로 맞다)
  //  h_<id>.img   : 칸마다 그림 한 장 — 이름이 번호가 아니라 고유 이름이라 번호가 밀려도 그대로다
  //
  //  ⚠️ 예전엔 그림 파일 이름이 번호(img_0.png …)였고 정보도 json 세 개로 나뉘어 있었다.
  //     100장이 차면 새 그림마다 번호가 전부 밀려 그림 100장을 다시 써야 했는데, 그 큰 저장은
  //     앱이 백그라운드로 갈 때만 했다. 그 전에 앱이 끝나면(IDE 정지·강제 종료·오류) 정보는 새
  //     번호, 그림은 옛 번호로 남아 — 다시 켜면 최근 그림이 사라지고 즐겨찾기가 엉뚱한 그림에 붙었다.
  //
  //  쓰는 순서: ① 아직 안 쓴 그림 → ② history.json 통째로 바꾸기 → ③ 이제 안 쓰는 파일 치우기.
  //   어디서 끊겨도 history.json 은 '이미 다 써진 그림'만 가리킨다.

  // 칸을 바꿀 때마다 부른다 — 짧게 모아서(300ms) 한 번에 쓴다
  Future<void> saveHistoryToLocal() async {
    if (_historyLoadFailed) {
      return; // 불러오기에 실패한 기록을 빈 목록으로 덮어쓰지 않는다
    }
    _historySaveDebounce?.cancel();
    _historySaveDebounce = Timer(const Duration(milliseconds: 300), () {
      _fullSaveHistoryToLocal();
    });
  }

  // 앱이 백그라운드로 가거나 꺼질 때 (main.dart) — 기다리던 저장을 지금 바로 한다
  Future<void> fullSaveHistoryIfNeeded() async {
    final bool pending = _historySaveDebounce?.isActive ?? false;
    _historySaveDebounce?.cancel();
    if (pending || history.any((e) => !e.imageSaved)) {
      await _fullSaveHistoryToLocal();
    }
  }

  /// 지금 히스토리를 디스크에 쓴다. 앞선 쓰기가 끝난 뒤 차례로 — 두 쓰기가 겹치지 않게.
  Future<void> _fullSaveHistoryToLocal() {
    final next = _historyWriteChain.then((_) => _writeHistoryToDisk());
    // 앞선 쓰기가 오류로 끝나도 줄이 막히지 않게 (쓰기 자체는 안에서 오류를 잡는다)
    _historyWriteChain = next.catchError((_) {});
    return next;
  }

  Future<void> _writeHistoryToDisk() async {
    if (_historyLoadFailed) {
      return; // 위와 같은 이유
    }
    try {
      final dir = await _getHistoryDir();
      // 쓰는 도중에 목록이 바뀌어도 이번 저장은 '이 순간' 기준 (바뀐 건 다음 저장이 맡는다)
      final entries = List<HistoryEntry>.of(history);

      // ① 아직 안 쓴 그림 — 새 칸, 썸네일로 줄어든 칸, 다시 생성한 칸
      for (final e in entries) {
        if (e.imageSaved) {
          continue;
        }
        final bytes = e.image;
        await _writeBytesAtomic(File('${dir.path}/h_${e.id}.img'), bytes);
        if (identical(e.image, bytes)) {
          e.imageSaved = true; // 쓰는 사이 또 바뀌었으면 다음 저장에서 다시
        }
      }

      // ② 순서와 정보 — 한 파일을 통째로 바꾼다 (반쯤 쓴 파일이 남지 않게)
      await _writeAtomic(
        File('${dir.path}/history.json'),
        jsonEncode([
          for (final e in entries)
            {
              'id': e.id,
              'metadata': e.metadata?.toJson(),
              'favorite': e.favorite,
              'filePath': e.filePath,
            },
        ]),
      );

      // ③ 이제 안 쓰는 파일 — 지운 칸의 그림, 예전 형식(번호 이름·json 세 개), 남은 임시 파일.
      //  history.json 을 다 쓴 '뒤'라서, 지우는 파일을 가리키는 기록은 이미 없다.
      final keep = {for (final e in entries) 'h_${e.id}.img'};
      final legacy = RegExp(r'^(?:img|thumb)_\d+\.(?:png|jpg)$');
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        final stale =
            (name.startsWith('h_') && name.endsWith('.img') && !keep.contains(name)) ||
            legacy.hasMatch(name) ||
            name == 'metadata.json' ||
            name == 'favorites.json' ||
            name == 'paths.json' ||
            name.endsWith('.tmp');
        if (stale) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      debugPrint("✅ 히스토리 저장 (${entries.length}개)");
    } catch (e) {
      debugPrint("❌ 히스토리 저장 실패: $e");
    }
  }

  Future<void> _loadHistoryFromLocal() async {
    isHistoryLoading = true;
    try {
      final dir = await _getHistoryDir();
      final v2 = File('${dir.path}/history.json');
      if (await v2.exists()) {
        history = await _readHistoryV2(dir, v2);
      } else {
        final metaFile = File('${dir.path}/metadata.json');
        if (!await metaFile.exists()) {
          isHistoryLoading = false;
          refreshUI();
          return;
        }
        history = await _readHistoryLegacy(dir, metaFile);
        // 예전 형식(번호 이름) → 새 형식으로 옮긴다.
        //  새 이름으로 그림을 다 쓰고 history.json 을 쓴 '뒤에만' 옛 파일을 지우므로,
        //  도중에 꺼지면 다음에 다시 예전 형식에서 옮긴다 (그 사이 만든 새 파일은 그때 치워진다).
        if (history.isNotEmpty) {
          unawaited(_fullSaveHistoryToLocal());
        }
      }

      if (history.isNotEmpty) {
        selectedHistoryIndex = history.length - 1;
      }
      debugPrint("✅ 히스토리 ${history.length}개 로컬에서 불러오기 완료");
      await _trimHistoryMemory(); // 오래된 이미지 썸네일 변환
      isHistoryLoading = false;
      refreshUI();
    } catch (e) {
      debugPrint("❌ 히스토리 불러오기 실패: $e");
      // ⚠️ 불러오지 못한 채로 저장하면 디스크의 기록을 빈 목록으로 덮어쓴다.
      //    이번 실행 동안은 히스토리 저장을 멈춰 원본 파일을 지킨다.
      //    (새로 만든 그림은 저장 폴더에는 그대로 저장된다)
      _historyLoadFailed = true;
      isHistoryLoading = false;
      refreshUI();
    }
  }

  /// 새 형식 (`history.json` + `h_<id>.img`) 읽기.
  ///  그림 파일이 없는 칸은 그 칸만 빠진다 — 이름으로 찾으니 다른 칸과 어긋나지 않는다.
  Future<List<HistoryEntry>> _readHistoryV2(Directory dir, File json) async {
    final list = jsonDecode(await json.readAsString()) as List;
    final out = <HistoryEntry>[];
    for (final item in list) {
      if (item is! Map) {
        continue;
      }
      final id = item['id'];
      if (id is! String) {
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await File('${dir.path}/h_$id.img').readAsBytes();
      } catch (_) {
        continue; // 그림이 없으면 그 칸만 빠진다
      }
      // ⚠️ 한 장의 정보가 깨져도 그 한 장만 비우고 계속 읽는다
      NaiMetadata? meta;
      try {
        meta = item['metadata'] != null ? NaiMetadata.fromJson(item['metadata']) : null;
      } catch (_) {
        meta = null;
      }
      final p = item['filePath'];
      out.add(
        HistoryEntry(
          id: id,
          image: bytes,
          metadata: meta,
          favorite: item['favorite'] == true,
          filePath: p is String ? p : null,
          imageSaved: true, // 방금 디스크에서 읽었으니 그대로다
        ),
      );
    }
    return out;
  }

  /// 예전 형식 (metadata.json·favorites.json·paths.json + img_번호.png / thumb_번호.jpg) 읽기.
  Future<List<HistoryEntry>> _readHistoryLegacy(Directory dir, File metaFile) async {
    final metaJson = jsonDecode(await metaFile.readAsString()) as List;

    final List favJson = await _readJsonList(File('${dir.path}/favorites.json'));
    final List pathsJson = await _readJsonList(File('${dir.path}/paths.json'));

    final List<HistoryEntry> loaded = [];

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
      final p = i < pathsJson.length ? pathsJson[i] : null;
      loaded.add(
        HistoryEntry(
          image: bytes,
          metadata: meta,
          favorite: i < favJson.length && favJson[i] == true,
          filePath: p is String ? p : null,
          // 새 형식 파일(h_<id>.img)은 아직 없다 → 저장할 때 쓴다
        ),
      );
    }

    if (loaded.length != metaJson.length) {
      debugPrint("⚠️ 히스토리 이미지 ${metaJson.length - loaded.length}개 누락 (예전 형식)");
    }
    return loaded;
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

  // ============================================================================
  // 파일 존재 여부 · 썸네일 · 다시 생성
  // ============================================================================
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
    // 캐시가 무한정 커지지 않게 (히스토리 상한보다 넉넉히 — 상한과 같으면 꽉 찬 히스토리에서 계속 밀어내고 다시 확인한다)
    if (_fileExistsCache.length > AppState.kHistoryCap * 2) {
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
    // 앱이 줄여 둔 그림인지 — 줄일 때(_trimHistoryMemory)와 같은 기준을 쓴다.
    //  ⚠️ 예전엔 'JPEG 면 썸네일' 이었다. 그런데 썸네일은 이제 WebP 라 알아보지 못했고,
    //     밖에서 가져온 JPEG 원본은 썸네일로 잘못 봤다 (꾹 누르면 '새로 생성' 창이 떴다).
    return historyImages[index].length < kThumbBytesLimit;
  }

  /// 원본이 없어 '다시 생성'만 할 수 있는 칸인지 — 썸네일만 남았고, 파일도 없고,
  ///  다시 만들 그림 정보(메타데이터)가 있을 때. 정보가 없으면(밖에서 가져온 그림) 보통 메뉴를 쓴다.
  bool historyNeedsRegenerate(int index) =>
      isHistoryThumbnail(index) &&
      !checkFileExistsSync(index) &&
      index < historyMetadata.length &&
      historyMetadata[index] != null;

  // ============================================================================
  // 메타데이터로 이미지 재생성 (썸네일만 있는 경우)
  //  메타데이터 표시 모델명 → API 모델 ID 변환
  // (예: "NovelAI Diffusion V4.5 4BDE2A90" → "nai-diffusion-4-5-full")
  // 뒤의 해시는 패치마다 바뀌므로 버전 키워드로 매칭. 모르는 이름이면 null.
  // ============================================================================
  String? _resolveModelId(String displayName) {
    final lower = displayName.toLowerCase();

    // 이미 API 모델 ID 형식이면 그대로 반환
    if (lower.startsWith('nai-diffusion')) {
      return displayName;
    }

    // V5 Full Medium 은 이름에 버전이 없을 수 있어 해시로 먼저 본다 (모델은 V5 Full — Medium 은 다시 생성할 때 따로 켠다)
    if (isMediumEffortSource(displayName)) {
      return NaiModels.v5Full;
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
    // V3 그림은 'Stable Diffusion XL <해시>' 로 적힌다 (모델 이름에 v3 가 없다). 퍼리 V3 는 해시로 가른다.
    if (lower.contains('stable diffusion xl')) {
      return lower.contains('9cc2f394') ? NaiModels.furryV3 : NaiModels.v3;
    }

    // 매칭 실패 — 부른 쪽이 정한다 (다시 생성 창은 사용자에게 고르게 한다)
    return null;
  }

  /// [index] 칸 그림을 만든 모델 (API 모델 ID). 그림 정보에 모델 이름이 없거나 모르는 이름이면 null.
  ///  다시 생성 창이 '원본 모델로 생성' 을 보여 주거나, 모르면 고르게 하는 데 쓴다.
  String? historySourceModel(int index) {
    if (index < 0 || index >= history.length) {
      return null;
    }
    final String source = history[index].metadata?.source ?? '';
    return source.isEmpty ? null : _resolveModelId(source);
  }

  /// 썸네일만 남은 칸을 그 칸의 메타데이터로 '새로' 생성한다 — 보통 생성과 똑같이.
  ///  · 프롬프트탭으로 옮겨 생성 버튼에 '생성 중...' 을 띄운다 (생성 · 배치와 같은 잠금 — 겹치지 않게).
  ///  · 새 그림은 프롬프트탭 이미지 자리에 띄우고, 히스토리 맨 뒤에 새 칸으로 넣는다
  ///    (자동 저장도 보통 생성과 같이 '자동 저장' 설정을 따른다).
  ///  · 누른 썸네일 칸은 그대로 둔다 (상한이 차 있어도 그 칸은 밀려나지 않는다 — 다른 오래된 칸이 빠진다).
  ///  · 모델은 [model] (다시 생성 창에서 고른 것) → 그림 정보의 모델 → 지금 고른 모델 순.
  ///    ⚠️ 예전엔 그림 정보에 모델 이름이 없으면 말없이 지금 고른 모델로 생성했다 —
  ///       V4.5 로 만든 그림이 V5 로 다시 만들어져 전혀 다른 그림이 나왔다.
  ///  · [newSeed] 가 true 면 시드만 새로 (다시 생성 창의 '새 시드로' — 같은 설정의 다른 그림).
  ///  ⚠️ 예전엔 히스토리 화면에 머문 채 뒤에서 조용히 생성해 새 그림이 그 썸네일 칸을 덮어썼다 —
  ///     생성되는지 알기 어려웠고, 원래 칸(썸네일)이 사라졌다.
  Future<void> regenerateFromMetadata(
    BuildContext context,
    int index, {
    String? model,
    bool newSeed = false,
  }) async {
    if (index < 0 || index >= history.length) {
      return;
    }
    // 번호가 아니라 칸과 정보를 먼저 잡아 둔다 — 기다리는 사이 번호가 밀리거나 칸이 지워져도 상관없다
    //  (원래 칸은 건드리지 않는다. 상한이 차 있어도 새 그림 때문에 이 칸이 밀려나지 않게 keep 으로 넘긴다)
    final HistoryEntry source = history[index];
    final NaiMetadata? meta = source.metadata;
    if (meta == null) {
      if (context.mounted) {
        showToast(context, "메타데이터가 없어 재생성할 수 없습니다.");
      }
      return;
    }
    await _generateFromMetadata(context, meta, model: model, newSeed: newSeed, keep: source);
  }

  /// 같은 설정으로 다시 뽑기 — 그림 정보 그대로, 시드만 새로 한 장 (이미지 옵션 메뉴).
  ///  [sameSeed] 면 시드까지 그대로 — 같은 모델이면 거의 같은 그림이 나온다
  ///  (썸네일만 남은 그림을 원본 크기로 되살리거나, 원본 파일을 잃었을 때).
  ///  [keep] 은 그 그림의 히스토리 칸 (있으면 — 상한이 차 있어도 그 칸은 밀려나지 않게).
  ///  Anlas 가 들거나 원본 모델을 몰라 지금 고른 모델로 만들 때만 먼저 묻는다 (생성 버튼과 같이 — 무료면 바로).
  ///  ⚠️ 그림 정보에 없는 것(바이브 · 정밀 참조 · i2i 원본)은 넣지 않는다 — 서버가 그림에 적지 않는다.
  Future<void> rerollFromMetadata(
    BuildContext context,
    NaiMetadata meta, {
    HistoryEntry? keep,
    bool sameSeed = false,
  }) => _generateFromMetadata(context, meta, newSeed: !sameSeed, keep: keep, confirm: true);

  /// [image] 를 담은 히스토리 칸 (바이트 '객체' 가 같은 칸 — 내용을 비교하지 않는다). 없으면 null.
  ///  프롬프트탭의 지금 그림은 히스토리의 새 칸과 같은 객체다 (addImageToHistory 가 받은 그대로 담는다).
  ///  그 칸의 그림 정보에는 앱이 따로 붙인 표시(VAR+)까지 있어, 바이트에서 다시 읽는 것보다 정확하다.
  ///  (썸네일로 줄어든 칸은 객체가 바뀌어 찾지 못한다 — 그땐 null)
  HistoryEntry? historyEntryOf(Uint8List image) {
    for (int i = history.length - 1; i >= 0; i--) {
      if (identical(history[i].image, image)) {
        return history[i];
      }
    }
    return null;
  }

  /// 그림 정보대로 한 장 만들 때의 Anlas 추정 (0 = 소모 없음 · -1 = 추정할 수 없음).
  ///  생성 버튼의 추정(anlasFor)과 같은 규칙 — 다만 크기 · 스텝은 지금 설정이 아니라 그림 정보에서 읽고,
  ///  바이브 · 정밀 참조는 보내지 않으므로 넣지 않는다.
  ///  [model] 은 생성할 모델 (V5 는 무료 한도가 바닥났으면 무료가 아니다 — _opusFreeSize).
  int anlasForMetadata(NaiMetadata meta, {String? model}) {
    final (int w, int h, int steps) = _metaJobSize(meta);
    return _opusFreeSize(w, h, steps, model: model) ? 0 : _estimateSingleAnlas(w, h, steps);
  }

  // 그림 정보의 크기 · 스텝 — 비어 있으면(0) 기본값. 생성 요청과 비용 추정이 같은 값을 쓰게 한 곳에.
  (int, int, int) _metaJobSize(NaiMetadata meta) => (
    meta.width > 0 ? meta.width : kDefaultWidth,
    meta.height > 0 ? meta.height : kDefaultHeight,
    meta.steps > 0 ? meta.steps : 28,
  );

  // 그림 정보로 새로 생성하는 공용 길 — 다시 생성(썸네일 칸) · 다시 뽑기(새 시드)가 같이 쓴다.
  //  [model] 은 고른 모델 (없으면 그림 정보의 모델 → 지금 고른 모델), [keep] 은 밀려나지 않게 지킬 칸,
  //  [confirm] 이면 시작 전에 묻는다 (_confirmReroll — 다시 생성은 창 자체가 확인이라 묻지 않는다).
  Future<void> _generateFromMetadata(
    BuildContext context,
    NaiMetadata meta, {
    String? model,
    required bool newSeed,
    HistoryEntry? keep,
    bool confirm = false,
  }) async {
    if (apiToken.isEmpty) {
      if (context.mounted) {
        showToast(context, "API 토큰이 설정되지 않았습니다.");
      }
      return;
    }

    // 생성 버튼이 막히는 조건과 같다 — 생성 · 배치 · i2i 작업과 겹치지 않게
    bool busy() => isLoading || isGenerateBusy || isBatchMode || isInpaintLoading || isUpscaleLoading;
    void busyToast() {
      if (context.mounted) {
        showToast(context, "지금 하던 생성이 끝난 뒤에 다시 눌러 주세요.");
      }
    }

    // 창(저장 폴더 · 확인)을 띄우기 전에 한 번 — 어차피 못 하는 걸 묻지 않게
    if (busy()) {
      busyToast();
      return;
    }

    // 생성한 그림은 저장 폴더에만 둔다 — 없으면 고르게 하고, 안 고르면 생성하지 않는다 (ensureSaveFolder)
    if (!await ensureSaveFolder(context) || !context.mounted) {
      return;
    }

    final String? sourceModel = meta.source.isNotEmpty ? _resolveModelId(meta.source) : null;
    final String genModel = model ?? sourceModel ?? selectedModel;
    if (confirm) {
      final bool modelKnown = model != null || sourceModel != null;
      if (!await _confirmReroll(context, meta, genModel, modelKnown, newSeed) ||
          !context.mounted) {
        return;
      }
    }

    // 창을 기다리는 사이 다른 생성이 시작됐을 수 있으니 한 번 더
    if (busy()) {
      busyToast();
      return;
    }

    // 보통 생성처럼 — 프롬프트탭으로 가서 '생성 중' 을 띄운다
    navigateToTab(AppTab.prompt);
    _isGenerateProcessing = true;
    isLoading = true;
    lastErrorMessage = null;
    refreshUI();
    _notifyStart(1); // 생성 진행 · 완료 알림 (짝은 아래 finally 의 _notifyEnd)
    final Uint8List? before = currentImageBytes; // 이번에 새 그림이 왔는지 보려고

    // 잠금을 건 '바로 다음'부터 전부 감싼다 — 무슨 일이 있어도 잠금이 풀리게 (handleGenerate 와 같은 이유)
    try {
      // 앱이 뒤로 가도 끊기지 않게 (보통 생성과 같다 — 짝은 아래 finally)
      await _holdBackground();

      // 캐릭터는 원본 위치 그대로 (posX/posY — 자유 좌표). 위치 정보가 없으면 가운데.
      //  ⚠️ 예전엔 위치를 버리고 전부 가운데(그리드 2,2)로 보냈다 — 여럿이면 구도가 원본과 달라졌다.
      final List<Map<String, dynamic>> characters = [];
      for (int i = 0; i < meta.characterPrompts.length; i++) {
        final List<double>? c = i < meta.characterCenters.length && meta.characterCenters[i].length >= 2
            ? meta.characterCenters[i]
            : null;
        characters.add({
          'positive': meta.characterPrompts[i],
          'negative': i < meta.characterUndesiredContents.length
              ? meta.characterUndesiredContents[i]
              : '',
          'gridX': 2,
          'gridY': 2,
          if (c != null) 'posX': c[0],
          if (c != null) 'posY': c[1],
        });
      }
      // 원본이 위치를 썼는지 (그림 정보에 있으면 — 2026-10 이전에 읽은 칸은 없어 지금 설정을 따른다)
      final Object? useCoords = meta.extraParams['use_coords'];

      final bool variancePlus = meta.extraParams['variety_plus'] == true;
      final (int width, int height, int steps) = _metaJobSize(meta);
      final result = await _service.generateImage(
        positive: meta.positive,
        negative: meta.negative,
        token: apiToken,
        model: genModel,
        steps: steps,
        sampler: meta.sampler.isNotEmpty ? meta.sampler : selectedSampler,
        // 원본의 스케줄러로 — 단, 잠긴 모델이면 고정값
        scheduler: schedulerFor(genModel, meta.extraParams['noise_schedule']?.toString()),
        width: width,
        height: height,
        cfgScale: meta.promptGuidance > 0 ? meta.promptGuidance : 6.0,
        cfgRescale: meta.promptGuidanceRescale,
        // 새 시드는 보통 생성의 '랜덤 시드' 와 같은 범위
        seed: newSeed ? Random().nextInt(4294967296) : meta.seed,
        characters: characters,
        variancePlus: variancePlus,
        // 원본이 V5 Full Medium 이면 Medium 으로 (지금 Effort 설정과 무관 — 원본을 따른다)
        mediumEffort: genModel == NaiModels.v5Full && isMediumEffortSource(meta.source),
        useCharacterPosition: useCoords is bool ? useCoords : useCharacterPosition,
        onPreview: _previewSink, // 생성 과정 미리보기 (보통 생성과 같다)
        onPreviewReset: _clearPreview,
      );

      _notifyTick();
      // 그림이 오면 바로 프롬프트탭 이미지 자리에 (보통 생성과 같다 — 오류도 그 자리에 빨간 글씨로)
      isLoading = false;
      currentImageBytes = result.image ?? currentImageBytes;
      lastErrorMessage = result.error;
      _clearPreview(); // 미리보기를 걷고 완성 그림으로
      refreshUI();

      final Uint8List? image = result.image;
      if (image != null) {
        sessionGenerateCount++;
        // 새 그림의 정보 + 앱이 따로 붙이는 표시(VAR+)는 원래 칸에서 이어 준다
        final NaiMetadata? newMeta = extractNovelAIMetadata(
          image,
        )?.copyWithExtra({'variety_plus': variancePlus});
        await addImageToHistory(
          image: image,
          metadata: newMeta,
          context: context.mounted ? context : null,
          keep: keep,
        );
        if (!isHistoryGridView) {
          requestHistoryScrollToEnd(); // 히스토리 목록도 새 칸이 보이게
        }
      }
      // 잔액·한도 갱신은 기다리지 않는다 (버튼이 그만큼 늦게 풀린다)
      refreshBalanceInBackground();
    } catch (e, st) {
      debugPrint("재생성 오류: $e\n$st");
      // 그림이 이미 왔으면(그 뒤 저장 · 히스토리 단계의 오류) 그 그림을 가리지 않는다 (보통 생성과 같다)
      if (identical(currentImageBytes, before)) {
        lastErrorMessage = "재생성 중 오류가 났어요.\n$e";
      }
    } finally {
      _clearPreview(); // 오류로 끝나도 미리보기가 남지 않게
      await _releaseBackground();
      _isGenerateProcessing = false;
      isLoading = false;
      _notifyEnd();
      refreshUI();
    }
  }

  // 다시 뽑기 전 확인 — Anlas 가 들거나, 원본 모델을 몰라 지금 고른 모델로 만들 때만 묻는다.
  //  둘 다 아니면 묻지 않고 바로 true (생성 버튼도 무료면 묻지 않는다).
  //  [newSeed] 가 false 면 '같은 시드로' — 글과 아이콘만 다르다 (확인 조건은 같다).
  Future<bool> _confirmReroll(
    BuildContext context,
    NaiMetadata meta,
    String genModel,
    bool modelKnown,
    bool newSeed,
  ) async {
    final int cost = anlasForMetadata(meta, model: genModel);
    // Anlas 확인 창을 껐으면(skipAnlasConfirm) 비용 때문에는 묻지 않는다 — 모델을 몰라서 묻는 건 그대로
    if ((cost == 0 || skipAnlasConfirm) && modelKnown) {
      return true;
    }
    final String modelName = modelCapsFor(genModel).displayName;
    return showConfirmDialog(
      context,
      title: newSeed ? "같은 설정으로 다시 뽑기" : "같은 시드로 다시 만들기",
      message: [
        newSeed
            ? "이 이미지의 설정 그대로 시드만 바꿔 한 장 만듭니다."
            // 모델이 바뀌면 같은 시드여도 다른 그림이다 — 그땐 '거의 같은 그림' 이라고 하지 않는다
            : "이 이미지의 설정과 시드(${meta.seed}) 그대로 한 장 만듭니다."
                  "${modelKnown ? '\n같은 모델이라 거의 같은 그림이 나와요.' : ''}",
        modelKnown ? "모델: $modelName" : "원본 모델을 알 수 없어 지금 고른 모델($modelName)로 만듭니다.",
        AppState.anlasText(cost),
      ].join("\n"),
      confirmLabel: "생성하기",
      icon: newSeed ? Icons.casino_outlined : Icons.push_pin_outlined,
      iconColor: AppColors.amber,
      confirmColor: AppColors.purple,
    );
  }
}

/// 히스토리 한 칸 — 이미지와 그 정보를 한 덩어리로.
class HistoryEntry {
  /// 고유 이름 — 디스크의 그림 파일 이름(`h_<id>.img`)에 쓴다. 번호가 밀려도 바뀌지 않는다.
  final String id;

  Uint8List _image;

  /// 이미지. 오래된 칸은 메모리를 아끼려 썸네일로 바뀐다 (_trimHistoryMemory).
  ///  바꾸면 '아직 안 씀' 이 되어 다음 저장에서 이 칸의 파일만 다시 쓴다.
  Uint8List get image => _image;
  set image(Uint8List value) {
    _image = value;
    imageSaved = false;
  }

  NaiMetadata? metadata;
  bool favorite;

  /// 자동 저장된 파일 경로 (저장 안 했거나 아직 저장 중이면 null)
  String? filePath;

  /// 디스크의 그림 파일이 지금 [image] 와 같은지 (메모리에서만 쓰는 표시)
  bool imageSaved;

  HistoryEntry({
    String? id,
    required Uint8List image,
    this.metadata,
    this.favorite = false,
    this.filePath,
    this.imageSaved = false,
  }) : id = id ?? _newHistoryId(),
       _image = image;
}

int _historyIdSeq = 0;

/// 히스토리 칸의 고유 이름 — 만든 시각(µs) + 순번. 같은 순간에 여러 칸이 생겨도 겹치지 않는다.
String _newHistoryId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${(_historyIdSeq++).toRadixString(36)}';

/// [AppState.history] 의 한 필드만 들여다보는 목록 (historyImages 등).
///  읽기와 '한 칸 바꾸기'는 그 칸의 필드를 읽고 쓴다.
///  넣고 빼기는 막는다 — 칸은 history 로만 넣고 빼야 네 필드가 어긋나지 않는다.
///  ([history] 가 통째로 바뀌어도 늘 최신을 보도록 목록 대신 목록을 돌려주는 함수를 받는다)
class _HistoryField<T> extends ListBase<T> {
  final List<HistoryEntry> Function() _entries;
  final T Function(HistoryEntry) _get;
  final void Function(HistoryEntry, T) _set;

  _HistoryField(this._entries, this._get, this._set);

  @override
  int get length => _entries().length;

  @override
  set length(int newLength) => throw UnsupportedError('히스토리 칸은 AppState.history 로만 넣고 뺀다');

  @override
  T operator [](int index) => _get(_entries()[index]);

  @override
  void operator []=(int index, T value) => _set(_entries()[index], value);
}
