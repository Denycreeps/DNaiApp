import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/app_state.dart';
import '../models/image_metadata.dart';
import 'preset_save_dialog.dart';
import '../models/nai_character.dart';
import 'detail_settings_modal.dart';
import '../app_theme.dart';

// 갤러리 뷰: 폴더를 탐색하고 이미지를 실제 갤러리 앱처럼 보여준다.
// - 폴더 우선 표시 (상단), 그 아래 이미지
// - 폴더 카드: 안의 이미지 2x2 모자이크 미리보기 + 폴더명 + 장수 (비면 폴더 아이콘)
// - 기본 3열 그리드 (galleryColumns로 조정)
// - 마지막 본 폴더 기억 (galleryCurrentPath)
// - 정렬: gallerySortMode (name_asc/name_desc), applySort()로 재정렬
// - 상단 breadcrumb 경로 (각 칩 탭으로 상위 점프)
// - 위치 선택 (앱 폴더 / 커스텀 저장 경로, 권한 불필요)
// - 이미지 뷰어 좌우 스와이프로 이전/다음

// 폴더 1개의 미리보기 정보 (썸네일 + 장수)
// ══════════════════════════════════════════════════════════════════════
// 갤러리 이미지 어댑터
//  갤러리는 두 가지 경로로 이미지를 다룬다.
//    · SAF  : 안드로이드 문서 URI (state.readSafImage 로 읽음)
//    · 파일 : 앱이 직접 접근하는 File (readAsBytes 로 읽음)
//  이 둘의 차이는 "바이트를 어떻게 읽나"와 "표시할 이름" 뿐이라서,
//  그 부분만 이 클래스로 감싸면 꾹 메뉴와 핸들러를 하나로 쓸 수 있다.
//  (예전에는 _safXxx / _xxx 로 짝이 나뉘어 한쪽만 고쳐지는 일이 있었다.)
// ══════════════════════════════════════════════════════════════════════
class GalleryItem {
  /// 다이얼로그 제목 등에 쓰는 표시 이름 (파일명)
  final String name;

  /// 이미지 바이트를 읽어온다. 실패하면 null.
  final Future<Uint8List?> Function() readBytes;

  /// 삭제 기능 (SAF 경로에만 있음). null이면 메뉴에서 숨긴다.
  final Future<void> Function()? onDelete;

  /// 다른 폴더로 이동 (SAF 경로에만 있음). null이면 메뉴에서 숨긴다.
  final VoidCallback? onMove;

  /// 실제 파일 경로 (파일 경로에만 있음).
  /// 히스토리에 추가할 때 원본 위치를 기록하는 용도이며, SAF는 경로가 없어 null.
  final String? filePath;

  const GalleryItem({
    required this.name,
    required this.readBytes,
    this.onDelete,
    this.onMove,
    this.filePath,
  });
}

class _FolderInfo {
  final Directory dir;
  final List<File> previews; // 미리보기용 (최대 4장)
  final int imageCount; // 폴더 내 이미지 총 개수
  final bool hasSubfolders; // 하위 폴더 존재 여부 (빈 폴더 숨김 판단용)
  _FolderInfo({
    required this.dir,
    required this.previews,
    required this.imageCount,
    required this.hasSubfolders,
  });
}

class GalleryView extends StatefulWidget {
  final AppState state;
  const GalleryView({super.key, required this.state});

  @override
  State<GalleryView> createState() => GalleryViewState();
}

class GalleryViewState extends State<GalleryView> {
  String? _currentPath;
  String _basePath = "";
  bool _loading = true;
  List<_FolderInfo> _folders = [];
  List<File> _images = [];
  bool _selectMode = false; // 다중 선택 모드
  final Set<String> _selectedPaths = {}; // 선택된 이미지 경로

  // SAF 모드 (저장 폴더가 SAF일 때 폴더 탐색)
  bool _safMode = false;
  String? _safDirUri; // 현재 보고 있는 SAF 디렉토리 URI
  String _safDirName = ''; // 현재 디렉토리 표시명
  List<({String uri, String name, int imageCount, List<({String uri, String name})> previews})>
  _safFolders = [];
  List<({String uri, String name})> _safImages = [];
  final List<({String uri, String name})> _safStack = []; // 상위로 가기용 경로 스택
  final Map<String, Uint8List> _safBytesCache = {}; // 원본 바이트 캐시 (뷰어 전용)
  // 그리드/미리보기용 썸네일 캐시 (~수십KB/장이라 넉넉히 보관 가능)
  final Map<String, Uint8List> _safThumbCache = {};
  final Map<String, Future<Uint8List?>> _safThumbFutures = {}; // 타일 깜빡임 방지 메모이즈
  // 뷰어(원본) 로드 Future 메모이즈 — 페이지 전환 rebuild 시 재요청·깜빡임 방지
  final Map<String, Future<Uint8List?>> _safViewerFutures = {};
  final Map<String, List<({String uri, String name})>> _safFolderPreview =
      {}; // 폴더 uri -> 미리보기 refs(최대4)
  // build마다 새 Future를 만들면 FutureBuilder가 매번 placeholder부터 시작해 깜빡이므로 메모이즈
  final Map<String, Future<List<Uint8List>>> _safPreviewFutures = {};
  bool _safSelectMode = false; // SAF 다중 선택 모드
  final Set<String> _safSelected = {}; // 선택된 SAF 이미지 uri

  // 이동 대기 상태: 값이 있으면 "이동 모드" — 갤러리를 돌아다니다 원하는 폴더에서 확정
  List<({String uri, String name})>? _pendingMoveRefs; // 이동할 파일들 (null이면 이동 모드 아님)
  String? _pendingMoveFromParent; // 이동할 파일들의 원본 폴더 URI

  // SAF 그리드 스크롤 컨트롤러 (자동 새로고침 시 위치 복원용)
  final ScrollController _safGridScroll = ScrollController();

  static const Set<String> _imageExts = {'.png', '.jpg', '.jpeg', '.webp', '.gif'};

  @override
  void initState() {
    super.initState();
    widget.state.galleryBackHandler = handleBackButton; // 뒤로가기 위임 등록
    _lastSafRevision = widget.state.gallerySafRevision;
    widget.state.addListener(_onAppStateChanged); // SAF 저장 감지 → 자동 갱신
    _init();
  }

  @override
  void dispose() {
    if (widget.state.galleryBackHandler == handleBackButton) {
      widget.state.galleryBackHandler = null;
    }
    widget.state.removeListener(_onAppStateChanged);
    _safGridScroll.dispose();
    super.dispose();
  }

  // SAF에 새 이미지가 저장되면(gallerySafRevision 증가) 현재 SAF 폴더를 자동 갱신.
  // 저장은 대개 다른 탭에서 일어나므로, 리스너로 받아 백그라운드로 갱신해둔다.
  int _lastSafRevision = 0;
  bool _safAutoRefreshScheduled = false;

  void _onAppStateChanged() {
    if (!mounted) {
      return;
    }
    if (widget.state.gallerySafRevision == _lastSafRevision) {
      return; // SAF 저장과 무관한 알림은 무시
    }
    if (widget.state.safRootUri == null || _safSelectMode) {
      return; // SAF 뷰가 아니거나 선택 중이면 갱신 보류
    }
    // 이미지가 저장된 폴더가 "지금 보는 폴더" 또는 "그 하위"일 때만 갱신.
    // - 같은 폴더: 새 이미지가 목록에 바로 보여야 함
    // - 상위 폴더: 하위(저장) 폴더의 미리보기 모자이크가 바뀌므로 갱신이 맞음
    // - 무관한 다른 폴더: 갱신하면 스크롤만 날리므로 스킵
    final savedDir = widget.state.lastSavedSafDirUri;
    final viewingDir = _safDirUri; // null이면 루트 (모든 저장이 하위 → 항상 갱신)
    if (savedDir != null && viewingDir != null && !_isSameOrDescendant(savedDir, viewingDir)) {
      // 갱신은 안 하되, revision은 따라잡아 두어 다음 알림부터 정상 판별
      _lastSafRevision = widget.state.gallerySafRevision;
      return;
    }
    _scheduleSafAutoRefresh();
  }

  // saved가 parent와 같거나 그 하위 폴더인지 (SAF document uri prefix 기준)
  bool _isSameOrDescendant(String saved, String parent) {
    if (saved == parent) {
      return true;
    }
    // 하위면 parent uri로 시작하고, 바로 뒤에 경로 구분자(%2F 또는 /)가 온다
    if (saved.startsWith(parent)) {
      final rest = saved.substring(parent.length);
      return rest.startsWith('%2F') || rest.startsWith('/');
    }
    return false;
  }

  // 자동 새로고침 최소 간격.
  //  연속 생성 중에는 저장 알림이 계속 오는데, 그때마다 목록을 다시 읽으면
  //  썸네일이 로딩될 틈이 없다. 최소 이 간격을 두고 한 번씩만 갱신한다.
  static const Duration _autoRefreshMinGap = Duration(milliseconds: 1500);
  DateTime? _lastAutoRefreshAt;

  void _scheduleSafAutoRefresh() {
    if (_safAutoRefreshScheduled) {
      return; // 같은 프레임의 연속 저장 알림을 하나로 합침
    }
    // 직전 갱신에서 얼마 지나지 않았으면 잠시 뒤에 한 번만 (몰아치는 저장 흡수)
    final last = _lastAutoRefreshAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < _autoRefreshMinGap) {
        _safAutoRefreshScheduled = true;
        Future.delayed(_autoRefreshMinGap - elapsed, () {
          _safAutoRefreshScheduled = false;
          if (mounted) {
            _scheduleSafAutoRefresh();
          }
        });
        return;
      }
    }
    _safAutoRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _safAutoRefreshScheduled = false;
      _lastAutoRefreshAt = DateTime.now();
      if (!mounted || _safSelectMode || _loading) {
        return;
      }
      _lastSafRevision = widget.state.gallerySafRevision;
      // 갱신 전 스크롤 위치와 개수 저장 → 갱신 후 복원 (맨 위로 튀는 것 방지)
      final double prevOffset = _safGridScroll.hasClients ? _safGridScroll.offset : 0.0;
      final int prevCount = _safImages.length;
      // 자동 갱신은 '현재 폴더의 이미지 목록'만 다시 읽는다.
      //  하위 폴더는 생성 중에 바뀌지 않으므로 다시 조회할 이유가 없다.
      //  (전체 조회는 하위 폴더 수만큼 SAF 호출이 늘어 체감이 크게 느려진다)
      await _refreshSafImagesOnly();
      if (mounted && prevOffset > 0) {
        // ⚠️ setState 직후에는 아직 새 목록이 그려지지 않아 maxScrollExtent가 옛 값이다.
        //    한 프레임 뒤에 복원해야 늘어난 목록 기준으로 정확히 맞는다.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_safGridScroll.hasClients) {
            return;
          }
          // 최신순 정렬이면 새 이미지가 '맨 앞'에 들어와 보던 항목이 아래로 밀린다.
          // 늘어난 줄 수만큼 오프셋을 더해 같은 이미지를 계속 보게 한다.
          double adjusted = prevOffset;
          final int added = _safImages.length - prevCount;
          if (added > 0 && widget.state.gallerySortMode == 'name_desc') {
            final int columns = widget.state.galleryColumns.clamp(1, 8);
            final int addedRows = (added + columns - 1) ~/ columns;
            // 타일은 정사각형(childAspectRatio: 1) + 세로 간격 6
            final double gridWidth = _safGridScroll.position.viewportDimension > 0
                ? MediaQuery.of(context).size.width -
                      16 // 좌우 padding 8+8
                : 0;
            if (gridWidth > 0) {
              final double tile = (gridWidth - 6 * (columns - 1)) / columns;
              adjusted += addedRows * (tile + 6);
            }
          }
          final double target = adjusted.clamp(0.0, _safGridScroll.position.maxScrollExtent);
          if ((_safGridScroll.offset - target).abs() > 1.0) {
            _safGridScroll.jumpTo(target);
          }
        });
      }
      // 갱신 도중 저장이 더 있었으면 한 번 더 (배치 생성 누락 방지)
      if (mounted && !_safSelectMode && widget.state.gallerySafRevision != _lastSafRevision) {
        _scheduleSafAutoRefresh();
      }
    });
  }

  // main의 PopScope가 호출 (히스토리 탭에서 뒤로가기 시).
  // 선택 모드 해제 / 상위 폴더 이동을 처리했으면 true.
  bool handleBackButton() {
    // 1. 선택 모드면 해제 우선
    if (_safSelectMode) {
      _safExitSelect();
      return true;
    }
    if (_selectMode) {
      _exitSelect();
      return true;
    }
    // 이동 모드 중 최상위(더 올라갈 폴더 없음)에서 뒤로가기 → 이동 취소
    if (_pendingMoveRefs != null && _safMode && _safStack.isEmpty) {
      _cancelPendingMove();
      return true;
    }
    // 2. SAF 상위 폴더
    if (_safMode && _safStack.isNotEmpty) {
      _safGoUp();
      return true;
    }
    // 3. IO 상위 폴더
    if (!_safMode) {
      final cur = _currentPath;
      if (cur != null && cur != _basePath && cur.startsWith(_basePath)) {
        _goUp();
        return true;
      }
    }
    return false;
  }

  Future<void> _init() async {
    // SAF 저장 폴더가 지정돼 있으면 SAF 모드로 시작 (MANAGE 권한 불필요)
    if (widget.state.safRootUri != null) {
      // 마지막으로 보던 폴더가 있으면 복원, 없으면 루트부터
      final lastUri = widget.state.safBrowseDirUri;
      if (lastUri != null) {
        _safStack
          ..clear()
          ..addAll(
            List.generate(
              widget.state.safBrowseStackUris.length,
              (i) => (
                uri: widget.state.safBrowseStackUris[i],
                name: i < widget.state.safBrowseStackNames.length
                    ? widget.state.safBrowseStackNames[i]
                    : '폴더',
              ),
            ),
          );
        await _loadSafDir(lastUri, widget.state.safBrowseDirName ?? 'SAF');
      } else {
        await _loadSafRootDir();
      }
      return;
    }
    // SAF 미설정: 앱 전용 폴더 등 접근 가능한 경로로 동작 (MANAGE 권한 불필요)
    final base = await widget.state.getGalleryBasePath();
    _basePath = base;
    String startPath = widget.state.galleryCurrentPath ?? base;
    if (!await Directory(startPath).exists()) {
      startPath = base;
    }
    await _loadFolder(startPath);
  }

  Future<void> _loadFolder(String path) async {
    setState(() => _loading = true);
    final dir = Directory(path);
    final folders = <_FolderInfo>[];
    final images = <File>[];

    try {
      final entries = await dir.list().toList();
      for (final e in entries) {
        if (e is Directory) {
          final info = _scanFolderPreview(e);
          // 이미지도 하위 폴더도 없는 빈 폴더는 숨김 (파일 관리 기능 아님)
          if (info.imageCount > 0 || info.hasSubfolders) {
            folders.add(info);
          }
        } else if (e is File) {
          final lower = e.path.toLowerCase();
          if (_imageExts.any((ext) => lower.endsWith(ext))) {
            images.add(e);
          }
        }
      }
      _sortLists(folders, images);
    } catch (e) {
      debugPrint("갤러리 폴더 로드 실패: $e");
    }

    widget.state.galleryCurrentPath = path;
    widget.state.saveAllSettings();

    if (mounted) {
      setState(() {
        _currentPath = path;
        _folders = folders;
        _images = images;
        _loading = false;
        _selectMode = false;
        _selectedPaths.clear();
      });
    }
  }

  // 폴더 안의 이미지를 훑어 미리보기 썸네일(최대 4장, 최신순)과 총 장수를 구한다.
  _FolderInfo _scanFolderPreview(Directory folder) {
    final inner = <File>[];
    bool hasSub = false;
    try {
      for (final f in folder.listSync()) {
        if (f is File) {
          final l = f.path.toLowerCase();
          if (_imageExts.any((ext) => l.endsWith(ext))) {
            inner.add(f);
          }
        } else if (f is Directory) {
          hasSub = true;
        }
      }
      inner.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    } catch (e) {
      debugPrint("폴더 미리보기 스캔 실패 (${folder.path}): $e");
    }
    return _FolderInfo(
      dir: folder,
      previews: inner.take(4).toList(),
      imageCount: inner.length,
      hasSubfolders: hasSub,
    );
  }

  // 현재 정렬 모드(gallerySortMode)에 따라 폴더/이미지 리스트를 정렬한다.
  void _sortLists(List<_FolderInfo> folders, List<File> images) {
    final bool desc = widget.state.gallerySortMode == 'name_desc';
    folders.sort((a, b) {
      final c = _folderName(
        a.dir.path,
      ).toLowerCase().compareTo(_folderName(b.dir.path).toLowerCase());
      return desc ? -c : c;
    });
    images.sort((a, b) {
      final c = _folderName(a.path).toLowerCase().compareTo(_folderName(b.path).toLowerCase());
      return desc ? -c : c;
    });
  }

  // 외부(history_tab 정렬 버튼)에서 호출: 디스크 재로드 없이 메모리상에서만 재정렬
  void applySort() {
    if (!mounted) {
      return;
    }
    setState(() {
      if (_safMode) {
        _sortSafLists();
      } else {
        _sortLists(_folders, _images);
      }
    });
  }

  // SAF 루트부터 탐색 시작
  Future<void> _loadSafRootDir() async {
    final uri = widget.state.safRootUri;
    if (uri == null) {
      return;
    }
    _safStack.clear();
    _safDirUri = null;
    await _loadSafDir(uri, widget.state.safRootName ?? 'SAF');
  }

  // 특정 SAF 디렉토리 로드. push=true면 현재 위치를 스택에 쌓고 들어감.
  //  silent: true 면 로딩 스피너를 띄우지 않는다.
  //    자동 갱신 때 그리드가 사라졌다 나타나면 ScrollController가 분리되어
  //    스크롤 위치를 완전히 잃어버린다(맨 위로 튐).
  Future<void> _loadSafDir(
    String uri,
    String name, {
    bool push = false,
    bool silent = false,
  }) async {
    if (!silent) {
      setState(() => _loading = true);
    }
    final cur = _safDirUri;
    if (push && cur != null) {
      _safStack.add((uri: cur, name: _safDirName));
    }
    final res = await widget.state.listSafDirDetailed(uri);
    if (!mounted) {
      return;
    }
    // 목록 조회에서 딸려온 미리보기 refs를 사전 시딩 → 폴더별 재조회 생략
    for (final f in res.folders) {
      if (f.previews.isNotEmpty) {
        _safFolderPreview[f.uri] = f.previews;
      }
    }
    // ⚠️ 같은 폴더를 다시 읽는 경우(자동 새로고침)에는 진행 중인 썸네일 로딩을
    //    버리면 안 된다. 버리면 처음부터 다시 읽게 되어, 생성 속도가 로딩보다
    //    빠를 때 영원히 완료되지 않는다(화면에 아무것도 안 보임).
    //    폴더가 실제로 바뀔 때만 정리한다.
    if (_safDirUri != uri) {
      _safThumbFutures.clear();
    }
    setState(() {
      _safMode = true;
      _safDirUri = uri;
      _safDirName = name;
      _safFolders = res.folders;
      _safImages = res.images;
      _sortSafLists();
      _loading = false;
      _safSelectMode = false;
      _safSelected.clear();
    });
    _persistSafBrowse();
  }

  // 현재 탐색 위치를 앱 상태에 기억 (탭/모드 전환 후 복원용)
  void _persistSafBrowse() {
    widget.state.saveSafBrowseLocation(
      _safDirUri,
      _safDirName,
      _safStack.map((e) => e.uri).toList(),
      _safStack.map((e) => e.name).toList(),
    );
  }

  // 상위 폴더로
  Future<void> _safGoUp() async {
    if (_safStack.isEmpty) {
      return;
    }
    final parent = _safStack.removeLast();
    await _loadSafDir(parent.uri, parent.name);
  }

  // 자동 갱신용 경량 새로고침: 현재 폴더의 이미지 목록만 교체한다.
  //  · 하위 폴더/미리보기는 건드리지 않음 → SAF 조회 1회로 끝
  //  · 썸네일 로딩(_safThumbFutures)도 유지 → 진행 중인 로딩이 끊기지 않음
  //  · 로딩 스피너를 띄우지 않음 → 그리드가 사라지지 않아 스크롤 위치 보존
  // 하위 폴더 하나만 다시 읽어 개수·미리보기를 갱신한다 (SAF 조회 1회).
  //  나머지 폴더의 캐시는 그대로라 썸네일이 다시 로드되지 않는다.
  Future<void> _refreshOneSafFolder(int index, String folderUri) async {
    final imgs = await widget.state.listSafImagesOnly(folderUri);
    if (!mounted || index >= _safFolders.length) {
      return;
    }
    final old = _safFolders[index];
    if (old.uri != folderUri) {
      return; // 그 사이 목록이 바뀌었으면 건너뛴다
    }
    final previews = imgs.take(4).toList();
    setState(() {
      _safFolders[index] = (
        uri: old.uri,
        name: old.name,
        imageCount: imgs.length,
        previews: previews,
      );
      // 이 폴더의 미리보기만 새로 시딩 (다른 폴더 캐시는 유지)
      _safFolderPreview[folderUri] = previews;
      _safPreviewFutures.remove(folderUri);
    });
  }

  Future<void> _refreshSafImagesOnly() async {
    final d = _safDirUri;
    if (d == null) {
      await _reloadSafDir(keepThumbs: true, silent: true);
      return;
    }
    // 새 이미지가 '지금 보고 있는 폴더'에 저장됐는지 확인한다.
    final savedDir = widget.state.lastSavedSafDirUri;
    if (savedDir != null && savedDir != d) {
      // 다른 폴더에 저장됐다 — 지금 화면에 그 폴더 타일이 있으면 '그것만' 갱신한다.
      //  전체를 다시 읽으면 나머지 폴더의 미리보기 캐시까지 날아가 썸네일이
      //  전부 다시 로드된다(상위 폴더에서 볼 때 특히 체감이 크다).
      final idx = _safFolders.indexWhere((f) => f.uri == savedDir);
      if (idx >= 0) {
        await _refreshOneSafFolder(idx, savedDir);
        return;
      }
      // 목록에 없는 폴더다. 현재 폴더 '바로 아래'에 새로 생긴 경우라면
      // 목록 자체가 달라졌으니 전체를 다시 읽어야 한다.
      // 전혀 무관한 폴더(형제·다른 가지)라면 화면에 영향이 없으므로 넘어간다.
      if (_isSameOrDescendant(savedDir, d)) {
        await _reloadSafDir(keepThumbs: true, silent: true);
      }
      return;
    }
    final imgs = await widget.state.listSafImagesOnly(d);
    if (!mounted) {
      return;
    }
    setState(() {
      _safImages = imgs;
      _sortSafLists();
    });
  }

  // 현재 디렉토리 새로고침
  //  keepThumbs: 진행 중인 썸네일 로딩을 유지할지.
  //    자동 새로고침(생성 중)에는 true — 매번 버리면 로딩이 끝나지 않는다.
  //    당겨서 새로고침 등 사용자가 명시적으로 요청하면 false로 전부 다시 읽는다.
  Future<void> _reloadSafDir({bool keepThumbs = false, bool silent = false}) async {
    // 폴더 미리보기는 내용이 바뀌었을 수 있으니 갱신
    _safFolderPreview.clear();
    _safPreviewFutures.clear();
    if (!keepThumbs) {
      _safThumbFutures.clear();
    }
    final d = _safDirUri;
    if (d != null) {
      await _loadSafDir(d, _safDirName, silent: silent);
    } else {
      await _loadSafRootDir();
    }
  }

  // IO 모드 현재 디렉토리 새로고침 (당겨서 새로고침용)
  Future<void> _reloadIoDir() async {
    final p = _currentPath;
    if (p != null) {
      await _loadFolder(p);
    }
  }

  // SAF 폴더/이미지 정렬 (gallerySortMode 기준)
  void _sortSafLists() {
    final bool desc = widget.state.gallerySortMode == 'name_desc';
    _safFolders.sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return desc ? -c : c;
    });
    _safImages.sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return desc ? -c : c;
    });
  }

  // 폴더 미리보기 이미지들(최대 4장) — 썸네일 로드 (refs + thumb 캐시)
  Future<List<Uint8List>> _loadFolderPreviews(String folderUri) async {
    List<({String uri, String name})>? refs;
    if (_safFolderPreview.containsKey(folderUri)) {
      refs = _safFolderPreview[folderUri];
    } else {
      // 목록 조회 때 refs를 못 얻은 경우(직접 이미지 없는 폴더)만 얕은 재귀 탐색
      refs = await widget.state.firstSafImagesIn(folderUri, max: 4);
      _safFolderPreview[folderUri] = refs;
    }
    final out = <Uint8List>[];
    if (refs == null) {
      return out;
    }
    for (final ref in refs) {
      final cached = _safThumbCache[ref.uri];
      if (cached != null) {
        out.add(cached);
      } else {
        final bytes = await widget.state.readSafThumb(ref.uri);
        if (bytes != null) {
          _safThumbCache[ref.uri] = bytes;
          _trimSafBytesCache(_safThumbCache, max: 400);
          out.add(bytes);
        }
      }
    }
    return out;
  }

  String _folderName(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isNotEmpty ? parts.last : path;
  }

  bool get _canGoUp {
    if (_currentPath == null) {
      return false;
    }
    return _currentPath != _basePath && _currentPath!.startsWith(_basePath);
  }

  void _goUp() {
    if (!_canGoUp) {
      return;
    }
    final parent = Directory(_currentPath!).parent.path;
    _loadFolder(parent);
  }

  // breadcrumb: base 이후의 경로 조각들을 칩으로
  List<({String name, String path})> _breadcrumbs() {
    final crumbs = <({String name, String path})>[];
    if (_currentPath == null) {
      return crumbs;
    }
    // base를 첫 칩으로
    crumbs.add((name: _folderName(_basePath), path: _basePath));
    if (_currentPath == _basePath) {
      return crumbs;
    }
    if (!_currentPath!.startsWith(_basePath)) {
      return crumbs;
    }
    final rel = _currentPath!
        .substring(_basePath.length)
        .split(Platform.pathSeparator)
        .where((e) => e.isNotEmpty);
    String acc = _basePath;
    for (final part in rel) {
      acc = "$acc${Platform.pathSeparator}$part";
      crumbs.add((name: part, path: acc));
    }
    return crumbs;
  }

  // 위치 선택 시트 (앱 폴더 / 커스텀 경로)
  Future<void> _showLocationPicker() async {
    final locations = await widget.state.getGalleryLocations();
    if (!mounted) {
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                "폴더 위치 선택",
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            // SAF 저장 폴더 (지정돼 있으면 최상단)
            if (widget.state.safRootUri != null)
              ListTile(
                leading: const Icon(Icons.folder_special, color: AppColors.teal),
                title: Text(
                  widget.state.safRootName ?? "SAF 폴더",
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: const Text(
                  "SAF 저장 폴더",
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _loadSafRootDir();
                },
              ),
            ...locations.map(
              (loc) => ListTile(
                leading: const Icon(Icons.folder_special, color: Color(0xFFFFC107)),
                title: Text(loc.$1, style: const TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: Text(
                  loc.$2,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _safMode = false); // IO 위치 선택 시 SAF 모드 해제
                  _basePath = loc.$2; // 위치 바꾸면 base도 갱신
                  _loadFolder(loc.$2);
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final columns = widget.state.galleryColumns.clamp(1, 8);

    // SAF 모드: 저장 폴더(SAF)의 이미지를 플랫하게 표시 (권한 불필요)
    if (_safMode) {
      return _buildSafView(columns);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 선택 모드면 선택 툴바, 아니면 breadcrumb 경로 바
        if (_selectMode)
          _buildSelectionToolbar()
        else
          // breadcrumb 경로 바
          SizedBox(
            height: 40,
            child: Row(
              children: [
                if (_canGoUp)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36),
                    icon: const Icon(Icons.arrow_upward, size: 18, color: Colors.white70),
                    onPressed: _goUp,
                  ),
                Expanded(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _breadcrumbs().length,
                    separatorBuilder: (_, _) => const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2),
                      child: Icon(Icons.chevron_right, size: 16, color: Colors.white24),
                    ),
                    itemBuilder: (ctx, i) {
                      final crumbs = _breadcrumbs();
                      final c = crumbs[i];
                      final isLast = i == crumbs.length - 1;
                      return Center(
                        child: GestureDetector(
                          onTap: isLast ? null : () => _loadFolder(c.path),
                          child: Text(
                            c.name,
                            style: TextStyle(
                              color: isLast ? Colors.white : AppColors.accent,
                              fontSize: 13,
                              fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Text(
                  "${_images.length}",
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        const Divider(height: 1, color: Colors.white12),
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: AppColors.accent))
              : RefreshIndicator(
                  color: AppColors.accent,
                  backgroundColor: const Color(0xFF2A2A2A),
                  // 선택 모드 중에는 새로고침 무시 (제스처 충돌 방지)
                  onRefresh: () async {
                    if (_selectMode || _loading) {
                      return;
                    }
                    await _reloadIoDir();
                  },
                  child: (_folders.isEmpty && _images.isEmpty)
                      // 빈 폴더여도 당겨서 새로고침 가능하도록 스크롤 가능한 뷰로 감쌈
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            Center(
                              child: Text(
                                "이 폴더는 비어있어요",
                                style: TextStyle(color: Colors.white38, fontSize: 14),
                              ),
                            ),
                          ],
                        )
                      : GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(8),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                            childAspectRatio: 1,
                          ),
                          itemCount: _folders.length + _images.length,
                          itemBuilder: (ctx, index) {
                            if (index < _folders.length) {
                              return _buildFolderTile(_folders[index]);
                            }
                            final imgIndex = index - _folders.length;
                            return _buildImageTile(_images[imgIndex], imgIndex);
                          },
                        ),
                ),
        ),
      ],
    );
  }

  // 외부(history_tab)에서 폴더 위치 선택을 호출할 수 있게 공개 메서드
  void openLocationPicker() => _showLocationPicker();

  // 현재 폴더명 (history_tab 버튼 라벨용)
  String get currentFolderLabel => _safMode
      ? (_safDirName.isNotEmpty ? _safDirName : (widget.state.safRootName ?? "SAF"))
      : (_currentPath == null ? "폴더" : _folderName(_currentPath!));

  // ===== SAF 모드 뷰 =====
  Widget _buildSafView(int columns) {
    final canGoUp = _safStack.isNotEmpty;
    final total = _safFolders.length + _safImages.length;
    // 제스처 네비게이션 바 등 하단 시스템 UI 높이만큼 여백 확보
    final double bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 40,
          child: _safSelectMode
              ? _buildSafSelectionToolbar()
              : Row(
                  children: [
                    if (canGoUp)
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36),
                        icon: const Icon(Icons.arrow_upward, size: 18, color: Colors.white70),
                        onPressed: _safGoUp,
                      )
                    else
                      const SizedBox(width: 12),
                    const Icon(Icons.folder_special, size: 16, color: AppColors.teal),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _safDirName.isNotEmpty
                            ? _safDirName
                            : (widget.state.safRootName ?? "SAF 폴더"),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36),
                      icon: const Icon(Icons.refresh, size: 18, color: Colors.white70),
                      onPressed: _reloadSafDir,
                    ),
                    Text("$total", style: const TextStyle(color: Colors.white38, fontSize: 12)),
                    const SizedBox(width: 8),
                  ],
                ),
        ),
        const Divider(height: 1, color: Colors.white12),
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: AppColors.accent))
              : RefreshIndicator(
                  color: AppColors.accent,
                  backgroundColor: const Color(0xFF2A2A2A),
                  // 선택 모드 중에는 새로고침 무시 (제스처 충돌 방지)
                  onRefresh: () async {
                    if (_safSelectMode || _loading) {
                      return;
                    }
                    await _reloadSafDir();
                  },
                  child: total == 0
                      // 빈 폴더여도 당겨서 새로고침 가능하도록 스크롤 가능한 뷰로 감쌈
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            Center(
                              child: Text(
                                "이 폴더는 비어있어요",
                                style: TextStyle(color: Colors.white38, fontSize: 14),
                              ),
                            ),
                          ],
                        )
                      : GridView.builder(
                          controller: _safGridScroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + bottomInset),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                            childAspectRatio: 1,
                          ),
                          itemCount: total,
                          itemBuilder: (ctx, index) {
                            // 폴더 먼저, 그 다음 이미지
                            if (index < _safFolders.length) {
                              return _buildSafFolderTile(_safFolders[index], columns);
                            }
                            final imgIndex = index - _safFolders.length;
                            return _buildSafImageTile(_safImages[imgIndex], imgIndex);
                          },
                        ),
                ),
        ),
        // 이동 대기 바 (이동 모드일 때만)
        if (_pendingMoveRefs != null) _buildMoveBar(bottomInset),
      ],
    );
  }

  // 이동 대기 하단 바: 현재 폴더로 이동 확정 / 취소
  Widget _buildMoveBar(double bottomInset) {
    final refs = _pendingMoveRefs;
    final from = _pendingMoveFromParent;
    if (refs == null) {
      return const SizedBox.shrink();
    }
    final here = _safDirUri ?? widget.state.safRootUri;
    final bool sameFolder = here != null && here == from;
    // 폴더 로딩 중엔 현재 위치 판정이 부정확 → 버튼 비활성화 (전환 중 오클릭 방지)
    final bool canMoveHere = !sameFolder && !_loading;
    final String hereName = _safDirName.isNotEmpty
        ? _safDirName
        : (widget.state.safRootName ?? "루트");
    return Container(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          const Icon(Icons.drive_file_move_outline, color: Color(0xFF42A5F5), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              sameFolder
                  ? "${refs.length}장 이동 중 · 다른 폴더로 이동하세요"
                  : "${refs.length}장을 '$hereName'(으)로",
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: _cancelPendingMove,
            child: const Text("취소", style: TextStyle(color: Colors.white54)),
          ),
          const SizedBox(width: 4),
          ElevatedButton(
            onPressed: canMoveHere ? _confirmPendingMoveHere : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF42A5F5),
              disabledBackgroundColor: Colors.white12,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text(
              "여기로 이동",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // SAF 폴더 타일 (미리보기 + 폴더명 + 이미지 개수 오버레이 + 테두리)
  Widget _buildSafFolderTile(
    ({String uri, String name, int imageCount, List<({String uri, String name})> previews}) folder,
    int columns,
  ) {
    // 열이 많을수록(타일이 작을수록) 테두리를 얇게 → 묻히지 않게
    final double borderW = (3.0 - (columns - 2) * 0.5).clamp(0.8, 3.0);
    return GestureDetector(
      onTap: () => _loadSafDir(folder.uri, folder.name, push: true),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFFFFC107).withValues(alpha: 0.85),
            width: borderW,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<List<Uint8List>>(
                future: _safPreviewFutures.putIfAbsent(
                  folder.uri,
                  () => _loadFolderPreviews(folder.uri),
                ),
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return Container(color: Colors.white10);
                  }
                  final imgs = snap.data ?? const [];
                  if (imgs.isEmpty) {
                    return Container(
                      color: const Color(0xFF2A2A2A),
                      child: const Icon(Icons.folder, color: Colors.white24, size: 40),
                    );
                  }
                  return _buildSafMosaic(imgs);
                },
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Row(
                    children: [
                      const Icon(Icons.folder, size: 13, color: Color(0xFFFFC107)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          folder.name,
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (folder.imageCount > 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          "${folder.imageCount}",
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSafImageTile(({String uri, String name}) item, int index) {
    final cached = _safThumbCache[item.uri];
    final bool selected = _safSelected.contains(item.uri);
    return GestureDetector(
      onTap: () {
        if (_safSelectMode) {
          _safToggleSelect(item.uri);
        } else {
          _openSafViewer(index);
        }
      },
      onLongPress: () {
        if (_safSelectMode) {
          _safToggleSelect(item.uri);
        } else {
          _safEnterSelect(item.uri);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: cached != null
                ? Image.memory(cached, fit: BoxFit.cover, cacheWidth: 300, gaplessPlayback: true)
                : FutureBuilder<Uint8List?>(
                    future: _safThumbFutures.putIfAbsent(
                      item.uri,
                      () => widget.state.readSafThumb(item.uri),
                    ),
                    builder: (ctx, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return Container(color: Colors.white10);
                      }
                      final bytes = snap.data;
                      if (bytes == null) {
                        return Container(
                          color: Colors.white10,
                          child: const Icon(Icons.broken_image, color: Colors.white24),
                        );
                      }
                      _safThumbCache[item.uri] = bytes;
                      _trimSafBytesCache(_safThumbCache, max: 400);
                      return Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        cacheWidth: 300,
                        gaplessPlayback: true,
                      );
                    },
                  ),
          ),
          if (_safSelectMode)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? Colors.redAccent : Colors.transparent,
                  width: selected ? 2.5 : 1,
                ),
                color: selected ? Colors.redAccent.withValues(alpha: 0.18) : Colors.transparent,
              ),
            ),
          if (_safSelectMode)
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? Colors.redAccent : Colors.black.withValues(alpha: 0.4),
                  border: Border.all(
                    color: selected ? Colors.redAccent : Colors.white38,
                    width: 1.5,
                  ),
                ),
                child: selected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
              ),
            ),
        ],
      ),
    );
  }

  // SAF 폴더 미리보기 모자이크 (최대 4장, 메모리 바이트)
  Widget _safThumb(Uint8List bytes) {
    return Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 200, gaplessPlayback: true);
  }

  // 폴더 미리보기 모자이크 공통 레이아웃 (IO/SAF 공용): 1장=꽉, 2장=좌우, 3~4장=2x2
  Widget _mosaicLayout<T>(List<T> items, Widget Function(T) thumbOf) {
    if (items.length == 1) {
      return thumbOf(items[0]);
    }
    if (items.length == 2) {
      return Row(
        children: [
          Expanded(child: thumbOf(items[0])),
          const SizedBox(width: 1.5),
          Expanded(child: thumbOf(items[1])),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: thumbOf(items[0])),
              const SizedBox(width: 1.5),
              Expanded(child: thumbOf(items[1])),
            ],
          ),
        ),
        const SizedBox(height: 1.5),
        Expanded(
          child: Row(
            children: [
              Expanded(child: thumbOf(items[2])),
              const SizedBox(width: 1.5),
              Expanded(
                child: items.length >= 4 ? thumbOf(items[3]) : Container(color: Colors.white10),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSafMosaic(List<Uint8List> imgs) {
    return _mosaicLayout(imgs, _safThumb);
  }

  // ── IO/SAF 공용 뷰어용 페이지 본문 ──
  Widget _ioViewerPage(int i) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4,
      child: Center(child: Image.file(_images[i], fit: BoxFit.contain)),
    );
  }

  String _ioFileName(File f) {
    final parts = f.path.split(Platform.pathSeparator);
    return parts.isNotEmpty ? parts.last : f.path;
  }

  Future<Uint8List?> _loadFullSafBytes(String uri) async {
    final cached = _safBytesCache[uri];
    if (cached != null) {
      return cached;
    }
    final bytes = await widget.state.readSafImage(uri);
    if (bytes != null) {
      _safBytesCache[uri] = bytes;
      _trimSafBytesCache(_safBytesCache, max: 20); // 원본은 커서 소량만 메모리 유지
    }
    return bytes;
  }

  Widget _safViewerPage(int i) {
    final item = _safImages[i];
    return FutureBuilder<Uint8List?>(
      future: _safViewerFutures.putIfAbsent(item.uri, () => _loadFullSafBytes(item.uri)),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(child: CircularProgressIndicator(color: AppColors.accent));
        }
        final bytes = snap.data;
        if (bytes == null) {
          return const Center(child: Icon(Icons.broken_image, color: Colors.white38, size: 48));
        }
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
        );
      },
    );
  }

  void _openSafViewer(int index) {
    if (_safViewerFutures.length > 12) {
      _safViewerFutures.clear(); // 완료된 Future가 원본 바이트를 계속 붙들지 않게 주기 정리
    }
    showDialog(
      context: context,
      builder: (ctx) => _GalleryImageViewer(
        itemCount: _safImages.length,
        startIndex: index,
        nameOf: (i) => _safImages[i].name,
        pageOf: _safViewerPage,
        onLongPress: (i, close) => _showGalleryImageMenu(_safItem(_safImages[i], close), close),
      ),
    );
  }

  void _safEnterSelect(String uri) {
    setState(() {
      _safSelectMode = true;
      _safSelected
        ..clear()
        ..add(uri);
    });
  }

  void _safToggleSelect(String uri) {
    setState(() {
      if (_safSelected.contains(uri)) {
        _safSelected.remove(uri);
        if (_safSelected.isEmpty) {
          _safSelectMode = false;
        }
      } else {
        _safSelected.add(uri);
      }
    });
  }

  void _safExitSelect() {
    setState(() {
      _safSelectMode = false;
      _safSelected.clear();
    });
  }

  List<({String uri, String name})> _safSelectedRefs() {
    return _safImages.where((e) => _safSelected.contains(e.uri)).toList();
  }

  // 선택 모드 상단 툴바 공통 (IO/SAF): [취소] [n장 선택됨] … [ⓘ] [삭제]
  Widget _selectionToolbarShared({
    required int count,
    required VoidCallback onCancel,
    required VoidCallback? onInfo,
    required VoidCallback? onDelete,
  }) {
    final bool hasSel = count > 0;
    return Row(
      children: [
        GestureDetector(
          onTap: onCancel,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.close, size: 16, color: Colors.white54),
                SizedBox(width: 4),
                Text(
                  "취소",
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          "$count장 선택됨",
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        GestureDetector(
          onTap: hasSel ? onInfo : null,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: hasSel ? Colors.white54 : Colors.white24),
            ),
            child: Icon(
              Icons.info_outline,
              size: 18,
              color: hasSel ? Colors.white : Colors.white38,
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: hasSel ? onDelete : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: hasSel ? Colors.redAccent.withValues(alpha: 0.2) : AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: hasSel ? Colors.redAccent : Colors.white24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: hasSel ? Colors.redAccent : Colors.white38,
                ),
                const SizedBox(width: 4),
                Text(
                  "삭제",
                  style: TextStyle(
                    color: hasSel ? Colors.redAccent : Colors.white38,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildSafSelectionToolbar() {
    return _selectionToolbarShared(
      count: _safSelected.length,
      onCancel: _safExitSelect,
      onInfo: _safShowSelectionMenu,
      onDelete: _safDeleteSelected,
    );
  }

  // ⓘ 메뉴 (SAF/파일 공용)
  //  1장이면 전체 메뉴를 그대로 열고, 여러 장이면 일괄 작업만 보여준다.
  //  이동하기는 그 기능이 있는 경로(SAF)에서만 노출된다.
  void _showBatchSelectionMenu({
    required int count,
    required GalleryItem Function() singleItem,
    required VoidCallback onAddAll,
    VoidCallback? onMoveAll,
  }) {
    if (count == 0) {
      return;
    }
    if (count == 1) {
      // 단일 선택은 일반 메뉴와 동일하게 (fromSelection=true → 삭제 숨김/이동 노출)
      _showGalleryImageMenu(singleItem(), null, true);
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                "$count장 선택됨",
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined, color: AppColors.purple),
              title: Text("히스토리 목록에 추가 ($count장)", style: const TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                onAddAll();
              },
            ),
            if (onMoveAll != null)
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline, color: Color(0xFF42A5F5)),
                title: Text("이동하기 ($count장)", style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  onMoveAll();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ⓘ (SAF): 선택한 항목들로 공용 메뉴를 연다
  void _safShowSelectionMenu() {
    final refs = _safSelectedRefs();
    _showBatchSelectionMenu(
      count: refs.length,
      singleItem: () => _safItem(refs.first),
      onAddAll: () => _safBatchAddToHistory(refs),
      onMoveAll: () => _safMoveRefs(refs),
    );
  }

  // ⓘ (파일): 파일 경로엔 이동 기능이 없어 onMoveAll을 넘기지 않는다
  void _showSelectionMenu() {
    final files = _selectedFiles();
    _showBatchSelectionMenu(
      count: files.length,
      singleItem: () => _fileItem(files.first),
      onAddAll: () => _batchAddToHistory(files),
    );
  }

  Future<void> _safBatchAddToHistory(List<({String uri, String name})> refs) async {
    int added = 0;
    for (final ref in refs) {
      final bytes = await widget.state.readSafImage(ref.uri);
      if (bytes == null) {
        continue;
      }
      if (!mounted) {
        return;
      }
      await widget.state.addBytesToHistory(bytes, context, showSuccess: false);
      added++;
    }
    if (!mounted) {
      return;
    }
    _safExitSelect();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$added장을 히스토리에 추가했습니다.")));
  }

  void _safDeleteSelected() {
    final refs = _safSelectedRefs();
    if (refs.isEmpty) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.redAccent),
            SizedBox(width: 8),
            Text(
              "이미지 삭제",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          "${refs.length}장의 이미지를 기기에서 영구 삭제합니다.\n이 작업은 되돌릴 수 없습니다.",
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              int deleted = 0;
              for (final ref in refs) {
                final ok = await widget.state.deleteSafImage(ref.uri);
                if (ok) {
                  deleted++;
                  _safImages.removeWhere((e) => e.uri == ref.uri);
                  _safBytesCache.remove(ref.uri);
                  _safThumbCache.remove(ref.uri);
                  _safThumbFutures.remove(ref.uri);
                  _safViewerFutures.remove(ref.uri);
                }
              }
              if (!mounted) {
                return;
              }
              _safExitSelect();
              _showBriefSnack("$deleted장 삭제");
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text(
              "삭제",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // 이미지 꾹 메뉴 (SAF/파일 공용)
  //  항목 구성은 같고, 이동/삭제는 그 기능이 있는 경로(SAF)에서만 보인다.
  //  fromSelection: 선택모드 툴바(ⓘ)에서 호출된 경우 true.
  //    → 선택모드엔 이미 삭제 버튼이 있으므로 "삭제"는 숨기고 "이동하기"를 노출.
  void _showGalleryImageMenu(
    GalleryItem item, [
    VoidCallback? closeViewer,
    bool fromSelection = false,
  ]) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                item.name,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            ListTile(
              leading: const Icon(Icons.add_photo_alternate_outlined, color: AppColors.purple),
              title: const Text("히스토리 목록에 추가", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _addToHistory(item);
              },
            ),
            ListTile(
              leading: Icon(Icons.brush, color: AppColors.accent),
              title: const Text("이미지 수정하기 (i2i)", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                closeViewer?.call(); // 뷰어에서 왔으면 닫고 탭 이동
                _sendToI2i(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_add_outlined, color: AppColors.teal),
              title: const Text("프리셋에 프롬프트 저장", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _saveToPreset(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined, color: AppColors.purple),
              title: const Text("프롬프트 불러오기", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                closeViewer?.call(); // 뷰어에서 왔으면 닫고 프롬프트 탭으로
                _loadPromptFrom(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline, color: Color(0xFFFFC107)),
              title: const Text("EXIF 확인", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _showExif(item);
              },
            ),
            // 이동하기: 선택모드 메뉴에서만 (그 기능이 있는 경로에서만)
            if (fromSelection && item.onMove != null)
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline, color: Color(0xFF42A5F5)),
                title: const Text("이동하기", style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  item.onMove!();
                },
              ),
            // 삭제: 선택모드가 아닐 때만
            if (!fromSelection && item.onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text("삭제", style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  item.onDelete!();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // 히스토리에 추가 (SAF/파일 공용)
  //  filePath는 파일 경로일 때만 있다(원본 위치 기록용). SAF는 null.
  Future<void> _addToHistory(GalleryItem item) async {
    try {
      final bytes = await item.readBytes();
      if (bytes == null || !mounted) {
        return;
      }
      await widget.state.addBytesToHistory(bytes, context, filePath: item.filePath);
    } catch (e) {
      debugPrint("히스토리 추가 실패: $e");
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("이미지를 불러오는 데 실패했습니다.")));
    }
  }

  // i2i 탭으로 보내기 (SAF/파일 공용)
  Future<void> _sendToI2i(GalleryItem item) async {
    try {
      final bytes = await item.readBytes();
      if (bytes == null || !mounted) {
        return;
      }
      final meta = extractNovelAIMetadata(bytes);
      widget.state.sendToI2i(bytes, meta);
      widget.state.navigateToTab(2);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(milliseconds: 2400),
          content: Text("이미지를 i2i 탭으로 보냈습니다! 👉"),
        ),
      );
    } catch (e) {
      debugPrint("i2i 전송 실패: $e");
    }
  }

  // ── GalleryItem 팩토리 ──
  // SAF 항목 / 파일 항목을 공용 어댑터로 감싼다.
  // closeViewer: 뷰어에서 열었다면 삭제 후 뷰어도 닫아야 한다
  GalleryItem _safItem(({String uri, String name}) item, [VoidCallback? closeViewer]) {
    return GalleryItem(
      name: item.name,
      readBytes: () => widget.state.readSafImage(item.uri),
      onDelete: () async => _confirmDeleteSafImage(item, closeViewer),
      onMove: () => _safMoveRefs([item]),
    );
  }

  GalleryItem _fileItem(File img) {
    return GalleryItem(
      name: _folderName(img.path),
      readBytes: () async => img.readAsBytes(),
      filePath: img.path,
    );
  }

  // 프리셋에 프롬프트 저장 (SAF/파일 공용)
  Future<void> _saveToPreset(GalleryItem item) async {
    try {
      final bytes = await item.readBytes();
      if (bytes == null || !mounted) {
        return;
      }
      final meta = extractNovelAIMetadata(bytes);
      if (meta == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("이 이미지에는 저장된 프롬프트 데이터가 없습니다.")));
        return;
      }
      // 메타데이터의 캐릭터 프롬프트를 NaiCharacter 목록으로 변환
      final chars = <NaiCharacter>[];
      for (int i = 0; i < meta.characterPrompts.length; i++) {
        final neg = i < meta.characterUndesiredContents.length
            ? meta.characterUndesiredContents[i]
            : "";
        chars.add(
          NaiCharacter(
            name: "C${i + 1}",
            positive: meta.characterPrompts[i],
            negative: neg,
            isActive: true,
          ),
        );
      }
      // 이미지엔 선행/후행·설정 스냅샷 개념이 없으므로 해당 칩은 비활성화
      showPresetSaveDialog(
        context,
        widget.state,
        positive: meta.positive,
        negative: meta.negative,
        characters: chars,
        allowPrefixSuffix: false,
        allowSettings: false,
      );
    } catch (e) {
      debugPrint("프리셋 저장 실패: $e");
    }
  }

  // 프롬프트 불러오기 (SAF 경로) — 히스토리 꾹 메뉴와 동일한 다이얼로그
  // 프롬프트 불러오기 (SAF/파일 공용) — 히스토리 꾹 메뉴와 동일한 다이얼로그
  Future<void> _loadPromptFrom(GalleryItem item) async {
    try {
      final bytes = await item.readBytes();
      if (bytes == null || !mounted) {
        return;
      }
      final meta = extractNovelAIMetadata(bytes);
      if (meta == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(milliseconds: 2400),
            content: Text("이 이미지에서 프롬프트 정보를 찾지 못했습니다."),
          ),
        );
        return;
      }
      showLoadPromptDialog(context, widget.state, meta);
    } catch (e) {
      debugPrint("프롬프트 불러오기 실패: $e");
    }
  }

  // EXIF(메타데이터) 확인 다이얼로그 (SAF/파일 공용, 히스토리에 추가하지 않음)
  Future<void> _showExif(GalleryItem item) async {
    try {
      final bytes = await item.readBytes();
      if (bytes == null || !mounted) {
        return;
      }
      final meta = extractNovelAIMetadata(bytes);
      final text = buildExifSummary(meta);
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Row(
            children: [
              const Icon(Icons.info_outline, color: Color(0xFFFFC107), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("닫기", style: TextStyle(color: AppColors.accent)),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint("EXIF 확인 실패: $e");
    }
  }

  void _confirmDeleteSafImage(({String uri, String name}) item, [VoidCallback? onDeleted]) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.redAccent),
            SizedBox(width: 8),
            Text("이미지 삭제", style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Text(
          "${item.name}\n이 이미지를 삭제할까요?",
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await widget.state.deleteSafImage(item.uri);
              if (!mounted) {
                return;
              }
              if (ok) {
                onDeleted?.call(); // 뷰어에서 삭제 시 뷰어 닫기 (지운 목록 계속 넘기다 깨짐 방지)
                setState(() {
                  _safImages.removeWhere((e) => e.uri == item.uri);
                  _safBytesCache.remove(item.uri);
                  _safThumbCache.remove(item.uri);
                  _safThumbFutures.remove(item.uri);
                  _safViewerFutures.remove(item.uri);
                });
                _showBriefSnack("삭제 완료");
              } else {
                _showBriefSnack("삭제 실패");
              }
            },
            child: const Text("삭제", style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  // ===== SAF 이미지 이동 (인플레이스 방식) =====
  // 이동할 파일들을 "대기 상태"에 올려두고, 갤러리를 평소처럼 탐색하다
  // 원하는 폴더에서 하단 바의 "여기로 이동"으로 확정한다.
  void _safMoveRefs(List<({String uri, String name})> refs) {
    if (refs.isEmpty) {
      return;
    }
    final rootUri = widget.state.safRootUri;
    if (rootUri == null) {
      return;
    }
    setState(() {
      _pendingMoveRefs = List.of(refs);
      _pendingMoveFromParent = _safDirUri ?? rootUri;
      // 선택모드는 종료 (이동 모드로 전환)
      _safSelectMode = false;
      _safSelected.clear();
    });
  }

  // 이동 대기 취소
  void _cancelPendingMove() {
    setState(() {
      _pendingMoveRefs = null;
      _pendingMoveFromParent = null;
    });
  }

  // 짧게 뜨는 스낵바 (삭제/이동 등 — 하단 버튼을 덜 가리도록 짧고 floating)
  void _showBriefSnack(String msg) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars() // 이전 것 즉시 제거 → 겹침 방지
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 12)),
          duration: const Duration(milliseconds: 900),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(8),
        ),
      );
  }

  // 현재 보고 있는 폴더로 이동 확정
  Future<void> _confirmPendingMoveHere() async {
    final refs = _pendingMoveRefs;
    final from = _pendingMoveFromParent;
    if (refs == null || from == null) {
      return;
    }
    final toParent = _safDirUri ?? widget.state.safRootUri;
    if (toParent == null) {
      return;
    }
    if (toParent == from) {
      _showBriefSnack("같은 폴더예요");
      return;
    }
    await _executeSafMove(refs, from, toParent);
    if (!mounted) {
      return;
    }
    _cancelPendingMove();
  }

  // 실제 이동 실행 + 캐시 정리 + 새로고침
  Future<void> _executeSafMove(
    List<({String uri, String name})> refs,
    String fromParent,
    String toParent,
  ) async {
    int moved = 0;
    for (final ref in refs) {
      final newUri = await widget.state.moveSafImage(ref.uri, fromParent, toParent);
      if (newUri != null) {
        moved++;
        // 이동된 파일은 목록/캐시에서 제거 (더 이상 원본 폴더에 없음)
        _safImages.removeWhere((e) => e.uri == ref.uri);
        _safBytesCache.remove(ref.uri);
        _safThumbCache.remove(ref.uri);
        _safThumbFutures.remove(ref.uri);
        _safViewerFutures.remove(ref.uri);
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {}); // 목록에서 제거된 것 즉시 반영
    _showBriefSnack("$moved장 이동");
    // 이동한 이미지는 위에서 목록·캐시에서 이미 뺐으므로 현재 폴더는 그대로 두면 된다.
    // 대상 폴더 타일이 화면에 있으면 개수·미리보기가 바뀌었으니 '그 타일만' 갱신한다.
    //  (전체 재조회를 하면 나머지 폴더 썸네일까지 전부 다시 로드된다)
    final destIdx = _safFolders.indexWhere((f) => f.uri == toParent);
    if (destIdx >= 0) {
      await _refreshOneSafFolder(destIdx, toParent);
    }
  }

  Widget _buildFolderTile(_FolderInfo info) {
    final name = _folderName(info.dir.path);
    final bool hasPreview = info.previews.isNotEmpty;
    return GestureDetector(
      onTap: () => _loadFolder(info.dir.path),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 미리보기 모자이크 (없으면 폴더 아이콘)
              if (hasPreview)
                _buildMosaic(info.previews)
              else
                const Center(child: Icon(Icons.folder, size: 40, color: Color(0xFFFFC107))),
              // 하단 라벨 바: 폴더 아이콘 + 폴더명 + 장수 배지
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Row(
                    children: [
                      const Icon(Icons.folder, size: 13, color: Color(0xFFFFC107)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          "${info.imageCount}",
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 폴더 미리보기 모자이크: 1장=꽉, 2장=좌우, 3~4장=2x2
  Widget _buildMosaic(List<File> imgs) {
    return _mosaicLayout(imgs, _thumb);
  }

  Widget _thumb(File f) {
    return Image.file(
      f,
      fit: BoxFit.cover,
      cacheWidth: 200,
      errorBuilder: (ctx, err, st) => Container(color: Colors.white10),
    );
  }

  Widget _buildImageTile(File img, int imgIndex) {
    final bool selected = _selectedPaths.contains(img.path);
    return GestureDetector(
      onTap: () {
        if (_selectMode) {
          _toggleSelect(img);
        } else {
          _openImageViewer(imgIndex);
        }
      },
      onLongPress: () {
        if (!_selectMode) {
          _enterSelect(img);
        } else {
          _toggleSelect(img);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              img,
              fit: BoxFit.cover,
              cacheWidth: 300,
              errorBuilder: (ctx, err, st) => Container(
                color: Colors.white10,
                child: const Icon(Icons.broken_image, color: Colors.white24),
              ),
            ),
          ),
          // 선택 모드: 빨강 테두리 + 좌상단 원형 체크 (히스토리 그리드와 동일)
          if (_selectMode)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? Colors.redAccent : Colors.transparent,
                  width: selected ? 2.5 : 1,
                ),
                color: selected ? Colors.redAccent.withValues(alpha: 0.18) : Colors.transparent,
              ),
            ),
          if (_selectMode)
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: selected ? Colors.redAccent : Colors.black.withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? Colors.redAccent : Colors.white38,
                    width: 1.5,
                  ),
                ),
                child: selected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
              ),
            ),
        ],
      ),
    );
  }

  void _enterSelect(File img) {
    setState(() {
      _selectMode = true;
      _selectedPaths
        ..clear()
        ..add(img.path);
    });
  }

  void _toggleSelect(File img) {
    setState(() {
      if (_selectedPaths.contains(img.path)) {
        _selectedPaths.remove(img.path);
        if (_selectedPaths.isEmpty) {
          _selectMode = false;
        }
      } else {
        _selectedPaths.add(img.path);
      }
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selectedPaths.clear();
    });
  }

  // 선택 모드 상단 툴바: [취소] [n장 선택됨] ... [ⓘ 메뉴] [삭제]
  Widget _buildSelectionToolbar() {
    return SizedBox(
      height: 40,
      child: _selectionToolbarShared(
        count: _selectedPaths.length,
        onCancel: _exitSelect,
        onInfo: _showSelectionMenu,
        onDelete: _deleteSelected,
      ),
    );
  }

  // 선택된 파일 목록 (현재 폴더 _images 기준)
  List<File> _selectedFiles() {
    return _images.where((f) => _selectedPaths.contains(f.path)).toList();
  }

  // 다중 히스토리 추가
  Future<void> _batchAddToHistory(List<File> files) async {
    await widget.state.addFilesToHistory(files, context);
    if (!mounted) {
      return;
    }
    _exitSelect();
  }

  // 선택 이미지 삭제 (실제 파일 삭제 → 폴더 새로고침)
  void _deleteSelected() {
    final files = _selectedFiles();
    if (files.isEmpty) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.redAccent),
            SizedBox(width: 8),
            Text(
              "이미지 삭제",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          "${files.length}장의 이미지를 기기에서 영구 삭제합니다.\n이 작업은 되돌릴 수 없습니다.",
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              int deleted = 0;
              for (final f in files) {
                try {
                  await f.delete();
                  // 히스토리의 '파일 있음' 표시가 낡지 않도록 캐시에서 지운다
                  widget.state.invalidateFileExistsCache(f.path);
                  deleted++;
                } catch (e) {
                  debugPrint("파일 삭제 실패 (${f.path}): $e");
                }
              }
              if (!mounted) {
                return;
              }
              _exitSelect();
              if (_currentPath != null) {
                await _loadFolder(_currentPath!);
              }
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text("$deleted장을 삭제했습니다.")));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text(
              "삭제",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // 이미지 뷰어: 좌우 스와이프로 이전/다음 이미지
  void _openImageViewer(int startIndex) {
    showDialog(
      context: context,
      builder: (ctx) => _GalleryImageViewer(
        itemCount: _images.length,
        startIndex: startIndex,
        nameOf: (i) => _ioFileName(_images[i]),
        pageOf: _ioViewerPage,
        onLongPress: (i, close) => _showGalleryImageMenu(_fileItem(_images[i]), close),
      ),
    );
  }

  // 히스토리 목록에 추가 (히스토리 탭 '이미지 불러오기'와 동일 로직 재사용)

  // i2i 탭으로 보내기 (detail_settings_modal '이미지 수정하기 (i2i)'와 동일 시퀀스)

  // 프리셋에 프롬프트 저장 (프롬프트탭과 동일한 공용 다이얼로그, 소스는 이미지 메타데이터)

  // EXIF(메타데이터) 확인 다이얼로그 (히스토리에 추가하지 않음)
  // 프롬프트 불러오기 — 히스토리 꾹 메뉴와 동일한 다이얼로그
}

// 좌우 스와이프 가능한 이미지 뷰어
// SAF 바이트 캐시 상한 관리 — 원본 전체 바이트라 무한정 쌓이면 메모리 폭발(OOM) 위험.
// Dart Map은 삽입 순서를 유지하므로 가장 오래된 항목부터 퇴출한다.
void _trimSafBytesCache(Map<String, Uint8List> cache, {int max = 120}) {
  while (cache.length > max) {
    cache.remove(cache.keys.first);
  }
}

// IO/SAF 공용 이미지 뷰어 — 좌우 스와이프 + 상단바(파일명·순번·닫기) + 꾹 눌러 메뉴
class _GalleryImageViewer extends StatefulWidget {
  final int itemCount;
  final int startIndex;
  final String Function(int index) nameOf;
  final Widget Function(int index) pageOf;
  final void Function(int index, VoidCallback closeViewer)? onLongPress;
  const _GalleryImageViewer({
    required this.itemCount,
    required this.startIndex,
    required this.nameOf,
    required this.pageOf,
    this.onLongPress,
  });

  @override
  State<_GalleryImageViewer> createState() => _GalleryImageViewerState();
}

class _GalleryImageViewerState extends State<_GalleryImageViewer> {
  late PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    _pageController = PageController(initialPage: widget.startIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(8),
      child: Stack(
        children: [
          // 좌우 스와이프로 이전/다음
          PageView.builder(
            controller: _pageController,
            itemCount: widget.itemCount,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (ctx, i) {
              final page = widget.pageOf(i);
              final cb = widget.onLongPress;
              if (cb == null) {
                return page;
              }
              return GestureDetector(
                onLongPress: () => cb(i, () {
                  if (Navigator.canPop(context)) {
                    Navigator.pop(context);
                  }
                }),
                child: page,
              );
            },
          ),
          // 상단 바: 파일명 + 순번 + 닫기
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: Colors.black54,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.nameOf(_index),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "${_index + 1}/${widget.itemCount}",
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
