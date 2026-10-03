import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui; // 이미지 헤더만 읽어 해상도를 얻는다
import 'package:flutter/material.dart';
import '../models/app_state.dart';
import '../models/app_tabs.dart';
import '../models/image_metadata.dart';
import 'preset_save_dialog.dart';
import '../models/nai_character.dart';
import 'detail_settings_modal.dart';
import '../app_theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/app_toast.dart';
import '../utils/image_codec.dart'; // 그림 확장자 목록 (앱 전체 공용)

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
/// 새로고침 원·빈 폴더 바탕에 쓰는 어두운 회색
const Color _kGalleryDim = Color(0xFF2A2A2A);

class GalleryItem {
  /// 다이얼로그 제목 등에 쓰는 표시 이름 (파일명)
  final String name;

  /// 이미지 바이트를 읽어온다. 실패하면 null.
  final Future<Uint8List?> Function() readBytes;

  /// 삭제 기능 (SAF 경로에만 있음). null이면 메뉴에서 숨긴다.
  final Future<void> Function()? onDelete;

  /// 다른 폴더로 이동 (SAF 경로에만 있음). null이면 메뉴에서 숨긴다.
  final VoidCallback? onMove;

  /// 휴지통에서 되돌리기 (휴지통 보기에서만). 있으면 꾹 메뉴가 휴지통 메뉴(되돌리기·영구 삭제)로 바뀐다.
  final Future<void> Function()? onRestore;

  /// 실제 파일 경로 (파일 경로에만 있음).
  /// 히스토리에 추가할 때 원본 위치를 기록하는 용도이며, SAF는 경로가 없어 null.
  final String? filePath;

  const GalleryItem({
    required this.name,
    required this.readBytes,
    this.onDelete,
    this.onMove,
    this.onRestore,
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

  /// 이미지 하나를 '히스토리 목록에 추가' 한 뒤 불린다 — 히스토리탭이 목록 모드로 바꿔 보여 준다.
  final VoidCallback? onAddedToHistory;

  const GalleryView({super.key, required this.state, this.onAddedToHistory});

  @override
  State<GalleryView> createState() => GalleryViewState();
}

class GalleryViewState extends State<GalleryView> {
  String? _currentPath;
  String _basePath = "";
  bool _loading = true;
  List<_FolderInfo> _folders = [];
  List<File> _images = [];
  // 다중 선택 (SAF·파일 공용). 선택한 이미지의 id — 파일은 경로, SAF 는 uri.
  //  모드나 폴더를 바꾸면 폴더를 새로 읽으며 비우므로 두 종류가 섞이지 않는다.
  //  ⚠️ 예전엔 _selectMode/_selected 와 _selectMode/_selected 두 벌이었다.
  bool _selectMode = false;
  final Set<String> _selected = {};

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

  // 둘러보는 저장 폴더 칸 — null 이면 저장 중인 칸.
  //  '변경'에서 다른 칸을 고르면 저장 칸은 그대로 두고 그 칸을 둘러본다
  //  (이동하기 중에 다른 저장 폴더로 옮기러 가도 저장 위치가 바뀌지 않게).
  int? _browseSlot;
  int get _viewSlot => _browseSlot ?? widget.state.activeSafSlot;
  String? get _rootUri => widget.state.safSlotUris[_viewSlot];
  String? get _rootName => widget.state.safSlotNames[_viewSlot];

  // 휴지통 보기 — '변경'에서 휴지통을 고르면 켜진다 (_openTrash).
  //  켜져 있으면 위쪽 줄·선택 툴바·꾹 메뉴가 휴지통용([되돌리기]·[영구 삭제]·[비우기])으로 바뀐다.
  bool _trashMode = false;
  Map<String, int> _trashDeletedAt = {}; // 휴지통 그림 이름 → 버린 시각(ms) — 남은 날 표시용

  // 이동 대기 상태: 값이 있으면 "이동 모드" — 갤러리를 돌아다니다 원하는 폴더에서 확정
  List<({String uri, String name})>? _pendingMoveRefs; // 이동할 파일들 (null이면 이동 모드 아님)
  String? _pendingMoveFromParent; // 이동할 파일들의 원본 폴더 URI

  // SAF 그리드 스크롤 컨트롤러 (자동 새로고침 시 위치 복원용)
  final ScrollController _safGridScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.state.galleryBackHandler = handleBackButton; // 뒤로가기 위임 등록
    _lastSafRevision = widget.state.gallerySafRevision;
    _lastSafRootRevision = widget.state.safRootRevision;
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
  // 저장 폴더가 바뀐 횟수 (AppState.safRootRevision) — 바뀌면 새 폴더로 다시 연다
  int _lastSafRootRevision = 0;

  void _onAppStateChanged() {
    if (!mounted) {
      return;
    }
    if (widget.state.safRootRevision != _lastSafRootRevision) {
      _lastSafRootRevision = widget.state.safRootRevision;
      _lastSafRevision = widget.state.gallerySafRevision;
      _reopenForNewSafRoot();
      return;
    }
    if (widget.state.gallerySafRevision == _lastSafRevision) {
      return; // SAF 저장과 무관한 알림은 무시
    }
    if (widget.state.safRootUri == null) {
      return;
    }
    if (!_safMode) {
      // 앱 폴더(일반 모드)를 보는 중 — SAF 를 다시 읽지 않는다.
      //  ⚠️ 예전엔 여기서 SAF 폴더를 다시 읽다가 화면이 제멋대로 SAF 로 바뀌었다
      //     (폴더를 읽는 _loadSafDir 이 SAF 모드를 켠다). SAF 로 돌아오면 새로 읽는다.
      _lastSafRevision = widget.state.gallerySafRevision;
      return;
    }
    if (_selectMode) {
      return; // 선택 중이면 갱신 보류 (선택이 끝난 뒤 다음 알림에서 갱신)
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

  /// 저장 폴더가 바뀌었을 때(설정에서 전환·지정·해제) 저장 중인 폴더의 맨 위부터 다시 연다.
  ///  ⚠️ 이게 없으면 갤러리를 켜 둔 채 설정에서 폴더를 바꿨을 때 옛 폴더가 계속 보인다
  ///     (히스토리 탭은 살아 있는 채로 남아 갤러리를 새로 만들지 않는다).
  void _reopenForNewSafRoot() {
    // 선택·이동 대기는 옛 폴더의 파일이라 버린다
    _selectMode = false;
    _selected.clear();
    _pendingMoveRefs = null;
    _pendingMoveFromParent = null;
    _safStack.clear();
    _safDirUri = null;
    _safFolderPreview.clear();
    _safPreviewFutures.clear();
    _safThumbFutures.clear();
    _browseSlot = null; // 저장 중인 칸부터 다시
    _trashMode = false;
    _trashDeletedAt = {};
    if (widget.state.safRootUri != null) {
      _loadSafRootDir();
    } else {
      // 저장 폴더를 모두 해제 — 앱 전용 폴더로 돌아간다
      setState(() => _safMode = false);
      _init();
    }
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
      // 기다리는 사이 앱 폴더로 옮겨 갔으면 하지 않는다 (위와 같은 이유)
      if (!mounted || !_safMode || _selectMode || _loading) {
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
      if (mounted &&
          _safMode &&
          !_selectMode &&
          widget.state.gallerySafRevision != _lastSafRevision) {
        _scheduleSafAutoRefresh();
      }
    });
  }

  // main의 PopScope가 호출 (히스토리 탭에서 뒤로가기 시).
  // 선택 모드 해제 / 상위 폴더 이동을 처리했으면 true.
  bool handleBackButton() {
    // 1. 선택 모드면 해제 우선
    if (_selectMode) {
      _exitSelect();
      return true;
    }
    // 휴지통을 보는 중이면 나간다 (지금 저장 중인 폴더로)
    if (_trashMode) {
      _exitTrash();
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
    // 3. IO 상위 폴더 (조건은 위로 가기 버튼과 같은 _canGoUp)
    if (!_safMode && _canGoUp) {
      _goUp();
      return true;
    }
    return false;
  }

  Future<void> _init() async {
    // SAF 저장 폴더가 지정돼 있으면 SAF 모드로 시작 (MANAGE 권한 불필요)
    if (widget.state.safRootUri != null) {
      // 늘 지금 저장 중인 폴더부터 연다.
      //  마지막으로 보던 곳이 저장 중인 폴더 안이면 그 자리를 되살리고,
      //  '변경'으로 다른 저장 폴더를 보다가 닫았으면(safBrowseSlot 있음) 저장 중인 폴더의 맨 위부터.
      //  ⚠️ 예전엔 다른 저장 폴더를 보던 자리까지 되살려, 다시 열면 그 폴더가 먼저 보였다.
      _browseSlot = null;
      final lastUri =
          widget.state.safBrowseSlot == null ? widget.state.safBrowseDirUri : null;
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
          if (isImageFileName(lower)) {
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
        _selected.clear();
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
          if (isImageFileName(l)) {
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

  /// 이름순 정렬 — 대소문자 무시, 정렬 모드(gallerySortMode)가 name_desc 면 거꾸로. SAF·파일 공용.
  ///  ⚠️ 예전엔 이 비교를 폴더·이미지 × SAF·파일로 네 번 복사해 두었다.
  void _sortByName<T>(List<T> list, String Function(T) nameOf) {
    final bool desc = widget.state.gallerySortMode == 'name_desc';
    list.sort((a, b) {
      final c = nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase());
      return desc ? -c : c;
    });
  }

  // 파일 폴더·이미지 정렬
  void _sortLists(List<_FolderInfo> folders, List<File> images) {
    _sortByName(folders, (f) => _baseName(f.dir.path));
    _sortByName(images, (f) => _baseName(f.path));
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
    final uri = _rootUri;
    if (uri == null) {
      return;
    }
    _trashMode = false; // 맨 위로 가면 휴지통 보기는 끝난다
    _trashDeletedAt = {};
    _safStack.clear();
    _safDirUri = null;
    await _loadSafDir(uri, _rootName ?? 'SAF');
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
    //  ⚠️ refs 가 바뀌었으면 '그려 둔 썸네일'도 버려야 한다.
    //     _safPreviewFutures 는 한 번 만든 Future 를 계속 재사용하므로,
    //     refs 만 새로 넣어 봐야 화면에는 옛 그림이 그대로 나온다.
    //     (이미지를 다른 폴더로 옮긴 뒤 위로 올라갔을 때 썸네일이 안 바뀌던 원인)
    for (final f in res.folders) {
      if (f.previews.isEmpty) {
        continue;
      }
      final before = _safFolderPreview[f.uri];
      final changed =
          before == null || before.length != f.previews.length || !_sameRefs(before, f.previews);
      _safFolderPreview[f.uri] = f.previews;
      if (changed) {
        _safPreviewFutures.remove(f.uri);
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
      _selectMode = false;
      _selected.clear();
    });
    // 휴지통은 기억하지 않는다 — 다시 열었을 때 휴지통이 '보통 폴더'처럼 열리면 안 된다
    if (!_trashMode) {
      _persistSafBrowse();
    }
  }

  // 현재 탐색 위치를 앱 상태에 기억 (탭/모드 전환 후 복원용)
  void _persistSafBrowse() {
    widget.state.saveSafBrowseLocation(
      _safDirUri,
      _safDirName,
      _safStack.map((e) => e.uri).toList(),
      _safStack.map((e) => e.name).toList(),
      slot: _browseSlot,
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

  /// 지금 보고 있는 폴더의 이미지 목록만 다시 읽는다.
  ///
  /// 폴더 타일과 다른 폴더의 썸네일 캐시는 건드리지 않는다.
  /// 이동·삭제처럼 '지금 폴더의 내용이 바뀐 것이 확실할 때' 쓴다.
  ///  (생성 후 자동 새로고침은 저장 위치를 따져야 하므로 _refreshSafImagesOnly 를 쓴다)
  Future<void> _reloadCurrentSafImages() async {
    final d = _safDirUri;
    if (d == null) {
      // 최상위에서는 목록이 폴더와 섞여 있어 전체를 다시 읽는다
      await _reloadSafDir(keepThumbs: true, silent: true);
      return;
    }
    final imgs = await widget.state.listSafImagesOnly(d);
    if (!mounted || _safDirUri != d) {
      return; // 그 사이 다른 폴더로 옮겨 갔으면 버린다
    }
    setState(() {
      _safImages = imgs;
      _sortSafLists();
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

  // SAF 폴더·이미지 정렬
  void _sortSafLists() {
    _sortByName(_safFolders, (f) => f.name);
    _sortByName(_safImages, (f) => f.name);
  }

  // 두 미리보기 목록이 같은 파일들인지 (순서까지 같아야 같은 것으로 본다)
  static bool _sameRefs(List<({String uri, String name})> a, List<({String uri, String name})> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i].uri != b[i].uri) {
        return false;
      }
    }
    return true;
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

  /// 경로의 마지막 조각 (폴더 이름이든 파일 이름이든).
  ///  (예전 이름은 _folderName 이었는데 파일 이름에도 쓰였고, 같은 일을 하는 _ioFileName 이 따로 있었다)
  String _baseName(String path) {
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
    crumbs.add((name: _baseName(_basePath), path: _basePath));
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

  // 위치 선택 시트 ('변경') — 저장 폴더 한 칸이 한 줄, 그 줄 오른쪽 끝이 그 폴더의 휴지통 버튼.
  //  ⚠️ 예전엔 휴지통도 한 줄씩 따로 있어(폴더1 · 폴더2 · 휴지통1 · 휴지통2) 줄 수가 두 배였고,
  //     어느 휴지통이 어느 폴더 것인지 한눈에 이어지지 않았다.
  //  지금 보고 있는 폴더 이름 옆에는 ✓, 휴지통을 보고 있으면 그 휴지통 버튼이 강조된다.
  //  아래 '기타'(앱 저장 폴더)는 그림이 있을 때만 보인다.
  Future<void> _showLocationPicker() async {
    final locations = await widget.state.getGalleryLocations();
    if (!mounted) {
      return;
    }
    // 휴지통 장수는 시트를 먼저 띄운 뒤 채운다 (저장 폴더를 읽어야 해서 조금 걸릴 수 있다).
    //  여기서 한 번만 만든다 — 시트 안에서 만들면 다시 그릴 때마다 새로 센다.
    final trashCounts = <int, Future<int>>{
      for (int i = 0; i < AppState.kSafSlotCount; i++)
        if (widget.state.safSlotUris[i] != null)
          i: widget.state.countSafTrash(widget.state.safSlotUris[i]!),
    };
    final filledSlots = trashCounts.keys.toList()..sort();
    // 앱 저장 폴더는 그림이 있을 때만 — 비어 있으면 볼 게 없다.
    //  단 저장 폴더를 안 정해 지금 이 폴더를 보고 있으면 비어 있어도 보인다 (✓ 가 붙을 자리).
    final others = [
      for (final loc in locations)
        if (loc.images > 0 || !_safMode) loc,
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                "폴더 위치 선택",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            // 저장 폴더 (지정된 칸만). 줄을 누르면 그 칸을 둘러본다.
            //  저장 칸은 바꾸지 않는다 (전환은 설정에서) — 이동하기 중이면 이동도 그대로 이어진다.
            //  ⚠️ 예전엔 여기서 저장 칸까지 전환해, 갤러리 상태를 새로 열며 이동하기가 풀렸다.
            if (filledSlots.isNotEmpty) _pickerSectionLabel("저장 폴더"),
            for (int k = 0; k < filledSlots.length; k++) ...[
              if (k > 0) const Divider(height: 1, indent: 60, endIndent: 16, color: Colors.white10),
              _pickerSlotRow(
                slot: filledSlots[k],
                trashCount: trashCounts[filledSlots[k]]!,
                onOpen: () {
                  Navigator.pop(ctx);
                  final int i = filledSlots[k];
                  _browseSlot = i == widget.state.activeSafSlot ? null : i;
                  _loadSafRootDir();
                },
                // 휴지통 — 지운 그림을 보고, 되돌리거나 완전히 지운다
                onTrash: () {
                  Navigator.pop(ctx);
                  _openTrash(filledSlots[k]);
                },
              ),
            ],
            if (others.isNotEmpty) ...[
              if (filledSlots.isNotEmpty) ...[
                const SizedBox(height: 6),
                const Divider(height: 1, color: Colors.white12),
              ],
              _pickerSectionLabel("기타"),
              for (final loc in others)
                _pickerOtherRow(
                  loc,
                  onOpen: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _safMode = false; // IO 위치 선택 시 SAF 모드 해제
                      _trashMode = false;
                    });
                    _basePath = loc.path; // 위치 바꾸면 base도 갱신
                    _loadFolder(loc.path);
                  },
                ),
            ],
            // 볼 곳이 하나도 없을 때 (저장 폴더 미지정 + 앱 저장 폴더에 그림 없음)
            if (filledSlots.isEmpty && others.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 28, 24, 16),
                child: Text(
                  "볼 수 있는 폴더가 없어요.\n설정의 '저장 폴더'에서 폴더를 골라 주세요.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// '변경' 목록의 작은 제목 ('저장 폴더' · '기타')
  Widget _pickerSectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
    child: Text(text, style: const TextStyle(color: Colors.white38, fontSize: 12)),
  );

  /// '변경' 목록의 저장 폴더 한 줄 — 줄을 누르면 그 폴더, 오른쪽 버튼은 그 폴더의 휴지통.
  Widget _pickerSlotRow({
    required int slot,
    required Future<int> trashCount,
    required VoidCallback onOpen,
    required VoidCallback onTrash,
  }) {
    final bool saving = slot == widget.state.activeSafSlot; // 새 그림이 저장되는 칸
    final bool viewing = _safMode && _viewSlot == slot; // 지금 이 칸(또는 그 휴지통)을 보는 중
    final bool viewingFolder = viewing && !_trashMode;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(
          children: [
            Icon(
              Icons.folder_special,
              size: 26,
              color: saving ? AppColors.teal : Colors.white38,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.state.safSlotNames[slot] ?? "저장 폴더 ${slot + 1}",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (viewingFolder) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.check, size: 16, color: AppColors.accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    saving ? "저장 폴더 ${slot + 1} · 지금 여기에 저장" : "저장 폴더 ${slot + 1}",
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _pickerTrashButton(trashCount, highlighted: viewing && _trashMode, onTap: onTrash),
          ],
        ),
      ),
    );
  }

  /// 저장 폴더 줄 오른쪽의 휴지통 버튼 — 아이콘 + 든 장수 (비어 있으면 아이콘만).
  ///  [highlighted] 면 지금 이 휴지통을 보고 있다는 뜻으로 강조색 테두리.
  Widget _pickerTrashButton(
    Future<int> count, {
    required bool highlighted,
    required VoidCallback onTap,
  }) {
    final Color color = highlighted ? AppColors.accent : Colors.white60;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          // 손가락으로 누르기 넉넉한 크기 (장수가 없어도 너무 작아지지 않게)
          constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: highlighted ? AppColors.accent : Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.delete_outline, size: 18, color: color),
              FutureBuilder<int>(
                future: count,
                builder: (_, snap) {
                  final int n = snap.data ?? 0;
                  if (n <= 0) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      "$n",
                      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// '변경' 목록의 '기타' 한 줄 (앱 저장 폴더 — 저장 폴더를 정하기 전 등에 앱 안에 저장된 그림)
  Widget _pickerOtherRow(
    ({String label, String path, int images}) loc, {
    required VoidCallback onOpen,
  }) {
    final bool viewing = !_safMode; // 저장 폴더가 아닌 곳을 보는 중 = 이 폴더
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        child: Row(
          children: [
            const Icon(Icons.folder_special, size: 26, color: AppColors.amber),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          loc.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (viewing) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.check, size: 16, color: AppColors.accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    loc.images > 0 ? "앱 안에 저장된 그림 ${loc.images}장" : "비어 있음",
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final columns = widget.state.galleryColumns.clamp(1, 8);
    // 화면 뼈대는 SAF·파일 공용. 다른 건 위쪽 줄·새로고침·칸 종류·(SAF 만) 이동 바.
    //  ⚠️ 예전엔 _buildSafView 가 이 뼈대를 통째로 따로 갖고 있어, 아래 시스템 바 여백 같은
    //     수정이 SAF 쪽에만 들어가 있었다.
    final bool saf = _safMode;
    final int folderCount = saf ? _safFolders.length : _folders.length;
    final int imageCount = saf ? _safImages.length : _images.length;
    final int total = folderCount + imageCount;
    // 제스처 네비게이션 바 등 하단 시스템 UI 높이만큼 여백 확보 (마지막 줄이 가리지 않게)
    final double bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 선택 모드면 선택 툴바, 아니면 위쪽 줄 (파일: 경로 줄 / SAF: 폴더 이름 + 새로고침)
        SizedBox(
          height: 40,
          child: _selectMode ? _buildSelectionToolbar() : (saf ? _safPathBar(total) : _ioPathBar()),
        ),
        const Divider(height: 1, color: Colors.white12),
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: AppColors.accent))
              : RefreshIndicator(
                  color: AppColors.accent,
                  backgroundColor: _kGalleryDim,
                  // 선택 모드 중에는 새로고침 무시 (제스처 충돌 방지)
                  onRefresh: () async {
                    if (_selectMode || _loading) {
                      return;
                    }
                    await (saf ? _reloadSafDir() : _reloadIoDir());
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
                          // SAF 는 자동 새로고침 뒤 스크롤 위치를 되돌리려고 컨트롤러를 쓴다
                          controller: saf ? _safGridScroll : null,
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
                            if (index < folderCount) {
                              return saf
                                  ? _buildSafFolderTile(_safFolders[index], columns)
                                  : _buildFolderTile(_folders[index], columns);
                            }
                            final imgIndex = index - folderCount;
                            return saf
                                ? _buildSafImageTile(_safImages[imgIndex], imgIndex)
                                : _buildImageTile(_images[imgIndex], imgIndex);
                          },
                        ),
                ),
        ),
        // 이동 대기 바 (이동은 SAF 에만 있다)
        // 휴지통 안으로는 옮기지 않는다 (이동 대기는 휴지통을 나가면 다시 보인다)
        if (saf && _pendingMoveRefs != null && !_trashMode) _buildMoveBar(bottomInset),
      ],
    );
  }

  // 파일 모드 위쪽 줄 — 위로 가기 + 경로 줄(누르면 그 폴더로) + 이미지 수
  Widget _ioPathBar() {
    return Row(
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
        Text("${_images.length}", style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const SizedBox(width: 8),
      ],
    );
  }

  // SAF 모드 위쪽 줄 — 위로 가기 + 현재 폴더 이름 + 새로고침 + 항목 수
  Widget _safPathBar(int total) {
    if (_trashMode) {
      return _trashPathBar(total);
    }
    return Row(
      children: [
        if (_safStack.isNotEmpty)
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
            _safDirName.isNotEmpty ? _safDirName : (_rootName ?? "SAF 폴더"),
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
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
    );
  }

  // 휴지통 보기의 위쪽 줄: [←] 휴지통 · 폴더 이름 … N일 보관 [비우기]
  Widget _trashPathBar(int total) {
    return Row(
      children: [
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36),
          icon: const Icon(Icons.arrow_back, size: 18, color: Colors.white70),
          onPressed: _exitTrash,
        ),
        const Icon(Icons.delete_outline, size: 16, color: Colors.white54),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            "휴지통 · ${_rootName ?? '저장 폴더'}",
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          "${widget.state.trashKeepDays}일 보관",
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        TextButton(
          onPressed: total > 0 ? _emptyTrash : null,
          child: Text(
            "비우기",
            style: TextStyle(
              color: total > 0 ? Colors.redAccent : Colors.white24,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  // 외부(history_tab)에서 폴더 위치 선택을 호출할 수 있게 공개 메서드
  void openLocationPicker() => _showLocationPicker();

  /// 다른 저장 폴더(또는 앱 폴더)를 보는 중이면 지금 저장 중인 폴더의 맨 위로 돌아간다.
  ///  히스토리 탭을 떠날 때 부른다 ('마지막 보기 유지'로 갤러리가 닫히지 않을 때) —
  ///  다시 들어오면 늘 지금 폴더가 먼저 보이게. 저장 중인 폴더 안을 보던 중이면 그대로 둔다.
  ///  이동 대기는 그대로 이어진다 (_loadSafRootDir 는 이동 대기를 건드리지 않는다).
  void showActiveFolder() {
    if (!mounted || widget.state.safRootUri == null) {
      return;
    }
    if (_safMode && _browseSlot == null && !_trashMode) {
      return;
    }
    _browseSlot = null;
    _loadSafRootDir(); // 휴지통 보기도 여기서 끝난다
  }

  // 현재 폴더명 (history_tab 버튼 라벨용)
  String get currentFolderLabel => _safMode
      ? (_safDirName.isNotEmpty ? _safDirName : (_rootName ?? "SAF"))
      : (_currentPath == null ? "폴더" : _baseName(_currentPath!));

  // 이동 대기 하단 바: 현재 폴더로 이동 확정 / 취소
  Widget _buildMoveBar(double bottomInset) {
    final refs = _pendingMoveRefs;
    final from = _pendingMoveFromParent;
    if (refs == null) {
      return const SizedBox.shrink();
    }
    final here = _safDirUri ?? _rootUri;
    final bool sameFolder = here != null && here == from;
    // 폴더 로딩 중엔 현재 위치 판정이 부정확 → 버튼 비활성화 (전환 중 오클릭 방지)
    final bool canMoveHere = !sameFolder && !_loading;
    final String hereName = _safDirName.isNotEmpty
        ? _safDirName
        : (_rootName ?? "루트");
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

  // SAF 폴더 칸 — 미리보기는 SAF 에서 읽고(메모이즈), 모양은 _folderTile
  Widget _buildSafFolderTile(
    ({String uri, String name, int imageCount, List<({String uri, String name})> previews}) folder,
    int columns,
  ) {
    return _folderTile(
      name: folder.name,
      count: folder.imageCount,
      columns: columns,
      onTap: () => _loadSafDir(folder.uri, folder.name, push: true),
      preview: FutureBuilder<List<Uint8List>>(
        future: _safPreviewFutures.putIfAbsent(folder.uri, () => _loadFolderPreviews(folder.uri)),
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Container(color: Colors.white10);
          }
          final imgs = snap.data ?? const [];
          return imgs.isEmpty ? _emptyFolderPreview : _mosaicLayout(imgs, _safThumb);
        },
      ),
    );
  }

  /// 그리드의 폴더 칸 (SAF·파일 공용) — 미리보기 + 아래 이름 줄(폴더 아이콘·이름·장수) + 호박색 테두리.
  ///  ⚠️ 예전엔 SAF 칸과 파일 칸이 모양까지 따로라, 같은 폴더도 모드에 따라 달라 보였다.
  ///     SAF 쪽 모양으로 맞췄다.
  Widget _folderTile({
    required String name,
    required int count,
    required int columns,
    required Widget preview,
    required VoidCallback onTap,
  }) {
    // 열이 많을수록(칸이 작을수록) 테두리를 얇게 → 묻히지 않게
    final double borderW = (3.0 - (columns - 2) * 0.5).clamp(0.8, 3.0);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.85), width: borderW),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Stack(
            fit: StackFit.expand,
            children: [
              preview,
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Row(
                    children: [
                      const Icon(Icons.folder, size: 13, color: AppColors.amber),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (count > 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          "$count",
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

  /// 미리보기할 그림이 없는 폴더
  static const Widget _emptyFolderPreview = ColoredBox(
    color: _kGalleryDim,
    child: Icon(Icons.folder, color: Colors.white24, size: 40),
  );

  // SAF 이미지 칸 — 그림만 SAF 썸네일에서 읽고(캐시·메모이즈), 나머지는 _imageTile
  Widget _buildSafImageTile(({String uri, String name}) item, int index) {
    final cached = _safThumbCache[item.uri];
    Widget memory(Uint8List bytes) =>
        Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 300, gaplessPlayback: true);
    return _imageTile(
      id: item.uri,
      onOpen: () => _openSafViewer(index),
      badge: _trashMode ? _trashBadge(item.name) : null,
      image: cached != null
          ? memory(cached)
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
                  return _brokenImage;
                }
                _safThumbCache[item.uri] = bytes;
                _trimSafBytesCache(_safThumbCache, max: 400);
                return memory(bytes);
              },
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

  // ── IO/SAF 공용 뷰어용 페이지 본문 ──
  Widget _ioViewerPage(int i) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4,
      child: Center(child: Image.file(_images[i], fit: BoxFit.contain)),
    );
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

  // SAF 이미지 뷰어
  void _openSafViewer(int index) {
    if (_safViewerFutures.length > 12) {
      _safViewerFutures.clear(); // 완료된 Future가 원본 바이트를 계속 붙들지 않게 주기 정리
    }
    _openViewer(
      countNow: () => _safImages.length,
      start: index,
      nameOf: (i) => _safImages[i].name,
      pageOf: _safViewerPage,
      // 화면에 띄우려고 읽는 바이트를 그대로 쓴다 (같은 Future 라 두 번 읽지 않는다)
      bytesOf: (i) {
        final uri = _safImages[i].uri;
        return _safViewerFutures.putIfAbsent(uri, () => _loadFullSafBytes(uri));
      },
      itemOf: (i, close) => _safItem(_safImages[i], close),
    );
  }

  /// SAF 이미지 하나를 목록과 캐시에서 뺀다 (삭제·이동 뒤).
  ///  ⚠️ 예전엔 이 다섯 줄이 삭제·선택 삭제·이동 세 곳에 복사돼 있었다.
  void _forgetSafImage(String uri) {
    _safImages.removeWhere((e) => e.uri == uri);
    _safBytesCache.remove(uri);
    _safThumbCache.remove(uri);
    _safThumbFutures.remove(uri);
    _safViewerFutures.remove(uri);
  }

  List<({String uri, String name})> _safSelectedRefs() {
    return _safImages.where((e) => _selected.contains(e.uri)).toList();
  }

  // 선택 모드 상단 툴바 공통 (IO/SAF): [취소] [n장 선택됨] … [ⓘ] [이동] [삭제]
  //  [이동] 은 그 기능이 있는 경로(SAF)에서만 — onMove 가 null 이면 숨긴다.
  //  휴지통 보기에서는 [취소] [n장 선택됨] … [되돌리기] [영구 삭제] — onInfo 가 null 이면 ⓘ 를 숨긴다.
  Widget _selectionToolbarShared({
    required int count,
    required VoidCallback onCancel,
    required VoidCallback? onInfo,
    VoidCallback? onMove,
    VoidCallback? onRestore,
    String deleteLabel = "삭제",
    // 삭제는 확인 다이얼로그를 띄우느라 비동기다.
    //  onTap 은 결과를 기다리지 않으므로 Future 를 그대로 넘겨도 된다.
    required Future<void> Function()? onDelete,
  }) {
    final bool hasSel = count > 0;
    // 이동은 이동하기 대기 바·크게 보기 메뉴와 같은 파란색
    const Color moveColor = Color(0xFF42A5F5);
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
        // 남는 폭을 모두 차지해 버튼들을 오른쪽으로 민다 (예전 Spacer 역할).
        //  버튼이 하나 늘어 좁은 화면에서 넘치지 않게 — 넘치면 글자를 줄인다
        Expanded(
          child: Text(
            "$count장 선택됨",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
        if (onInfo != null)
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
        if (onMove != null) ...[
          const SizedBox(width: 8),
          _toolbarPill(
            icon: Icons.drive_file_move_outline,
            label: "이동",
            color: moveColor,
            enabled: hasSel,
            onTap: onMove,
          ),
        ],
        if (onRestore != null) ...[
          const SizedBox(width: 8),
          _toolbarPill(
            icon: Icons.restore_from_trash_outlined,
            label: "되돌리기",
            color: AppColors.teal,
            enabled: hasSel,
            onTap: onRestore,
          ),
        ],
        const SizedBox(width: 8),
        _toolbarPill(
          icon: Icons.delete_outline,
          label: deleteLabel,
          color: Colors.redAccent,
          enabled: hasSel && onDelete != null,
          onTap: onDelete == null ? null : () => onDelete(),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  // 선택 툴바의 둥근 버튼 — 고른 게 없으면 회색으로 잠긴다 ([이동]·[되돌리기]·[삭제] 공용)
  //  ⚠️ 예전엔 [이동]·[삭제] 가 똑같은 모양을 각자 서른 줄씩 갖고 있었다.
  Widget _toolbarPill({
    required IconData icon,
    required String label,
    required Color color,
    required bool enabled,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: enabled ? color.withValues(alpha: 0.2) : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: enabled ? color : Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: enabled ? color : Colors.white38),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: enabled ? color : Colors.white38,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ⓘ 메뉴 (SAF/파일 공용)
  //  1장이면 전체 메뉴를 그대로 열고, 여러 장이면 일괄 작업만 보여준다.
  //  ⚠️ 이동·삭제는 여기 없다 — 선택 툴바에 [이동]·[삭제] 버튼이 따로 있다.
  void _showBatchSelectionMenu({
    required int count,
    required GalleryItem Function() singleItem,
    required VoidCallback onAddAll,
  }) {
    if (count == 0) {
      return;
    }
    if (count == 1) {
      // 단일 선택은 일반 메뉴와 동일하게 (fromSelection=true → 이동·삭제 숨김)
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
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 선택된 항목들 (지금 모드의 폴더 목록 기준)
  List<GalleryItem> _selectedItems() => _safMode
      ? _safSelectedRefs().map(_safItem).toList()
      : _selectedFiles().map(_fileItem).toList();

  // ⓘ 선택 메뉴 (SAF·파일 공용). 이동은 툴바의 [이동] 버튼으로.
  void _showSelectionMenu() {
    final items = _selectedItems();
    _showBatchSelectionMenu(
      count: items.length,
      singleItem: () => items.first,
      onAddAll: () => _batchAddToHistory(items),
    );
  }

  // 이미지 꾹 메뉴 (SAF/파일 공용)
  //  항목 구성은 같고, 이동/삭제는 그 기능이 있는 경로(SAF)에서만 보인다.
  //  fromSelection: 선택모드 툴바(ⓘ)에서 호출된 경우 true.
  //    → 선택모드엔 이미 [이동]·[삭제] 버튼이 있으므로 둘 다 숨긴다.
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
            // 휴지통의 그림: [되돌리기] · EXIF 확인 · [영구 삭제] 만
            if (item.onRestore != null)
              ListTile(
                leading: const Icon(Icons.restore_from_trash_outlined, color: AppColors.teal),
                title: const Text("되돌리기", style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  item.onRestore!();
                },
              ),
            if (item.onRestore == null) ...[
              ListTile(
                leading: const Icon(Icons.add_photo_alternate_outlined, color: AppColors.purple),
                title: const Text("히스토리 목록에 추가", style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  // 추가했으면 히스토리 목록으로 가서 방금 넣은 이미지를 보여 준다.
                  //  크게 보기에서 열었으면 뷰어부터 닫는다 (뒤 화면만 바뀌면 어색하다).
                  if (await _addToHistory(item)) {
                    closeViewer?.call();
                    widget.onAddedToHistory?.call();
                  }
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
            ],
            ListTile(
              leading: const Icon(Icons.info_outline, color: AppColors.amber),
              title: const Text("EXIF 확인", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _showExif(item);
              },
            ),
            // 이동하기: 크게 보기 메뉴에서만 (그 기능이 있는 경로 = SAF 에서만)
            //  선택모드에선 툴바의 [이동] 버튼을 쓴다 (ⓘ 메뉴에서는 뺐다).
            //  뷰어부터 닫는다 — 이동 대기는 갤러리 화면에서 폴더를 골라야 하고,
            //  하위 폴더가 없으면 위 폴더로 올라가는 것도 [이동] 버튼과 같다 (_safMoveRefs).
            if (closeViewer != null && item.onMove != null)
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline, color: Color(0xFF42A5F5)),
                title: const Text("이동하기", style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  // 위 조건(closeViewer != null)으로 이미 null 이 아니다 — '?.' 는 필요 없다
                  closeViewer();
                  item.onMove!();
                },
              ),
            // 삭제: 선택모드가 아닐 때만 (휴지통의 그림이면 '영구 삭제')
            if (!fromSelection && item.onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: Text(
                  item.onRestore != null ? "영구 삭제" : "삭제",
                  style: const TextStyle(color: Colors.redAccent),
                ),
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
  //  돌려주는 값: 추가했으면 true.
  Future<bool> _addToHistory(GalleryItem item) async {
    try {
      final bytes = await item.readBytes();
      if (bytes == null || !mounted) {
        return false;
      }
      await widget.state.addBytesToHistory(bytes, context, filePath: item.filePath);
      return true;
    } catch (e) {
      debugPrint("히스토리 추가 실패: $e");
      if (mounted) {
        showToast(context, "이미지를 불러오는 데 실패했습니다.");
      }
      return false;
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
      widget.state.navigateToTab(AppTab.i2i);
      showToast(context, "이미지를 i2i 탭으로 보냈습니다! 👉");
    } catch (e) {
      debugPrint("i2i 전송 실패: $e");
    }
  }

  // ── GalleryItem 팩토리 ──
  // SAF 항목 / 파일 항목을 공용 어댑터로 감싼다.
  // closeViewer: 뷰어에서 열었다면 삭제 후 뷰어도 닫아야 한다
  GalleryItem _safItem(({String uri, String name}) item, [VoidCallback? closeViewer]) {
    if (_trashMode) {
      // 휴지통의 그림: 되돌리기·영구 삭제만 (이동·다른 작업 없음)
      return GalleryItem(
        name: item.name,
        readBytes: () => widget.state.readSafImage(item.uri),
        onDelete: () => _purgeTrashRefs([item], closeViewer),
        onRestore: () => _restoreTrashRefs([item], closeViewer),
      );
    }
    return GalleryItem(
      name: item.name,
      readBytes: () => widget.state.readSafImage(item.uri),
      onDelete: () async => _confirmDeleteSafImage(item, closeViewer),
      onMove: () => _safMoveRefs([item]),
    );
  }

  GalleryItem _fileItem(File img) {
    return GalleryItem(
      name: _baseName(img.path),
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
        showToast(context, "이 이미지에는 저장된 프롬프트 데이터가 없습니다.");
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
        showToast(context, "이 이미지에서 프롬프트 정보를 찾지 못했습니다.");
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
              const Icon(Icons.info_outline, color: AppColors.amber, size: 20),
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

  Future<void> _confirmDeleteSafImage(
    ({String uri, String name}) item, [
    VoidCallback? onDeleted,
  ]) async {
    // 설정이 켜져 있으면 휴지통으로 (_deleteSelected 와 같은 규칙)
    final String? root = _rootUri;
    final bool toTrash = widget.state.trashEnabled && root != null;
    final confirmed = await showConfirmDialog(
      context,
      title: toTrash ? "휴지통으로 보내기" : "이미지 삭제",
      message: toTrash
          ? "${item.name}\n휴지통으로 보낼까요? (${widget.state.trashKeepDays}일 뒤 자동으로 지워져요)"
          : "${item.name}\n이 이미지를 삭제할까요?",
      confirmLabel: toTrash ? "보내기" : "삭제",
      icon: Icons.delete_outline,
    );
    if (!confirmed || !mounted) {
      return;
    }
    // root 는 toTrash 안에서 이미 null 이 아님이 확인된다 (Dart 가 toTrash 를 통해 알아본다)
    final bool ok = toTrash
        ? (await widget.state.trashSafImages(
            [item],
            fromDirUri: _safDirUri ?? root,
            rootUri: root,
          )).isNotEmpty
        : await widget.state.deleteSafImage(item.uri);
    if (!mounted) {
      return;
    }
    if (ok) {
      onDeleted?.call(); // 뷰어에서 삭제 시 뷰어 닫기 (지운 목록 계속 넘기다 깨짐 방지)
      setState(() {
        _forgetSafImage(item.uri);
      });
      _showBriefSnack(toTrash ? "휴지통으로 보냈어요" : "삭제 완료");
    } else {
      _showBriefSnack("삭제 실패");
    }
  }

  // ===== SAF 이미지 이동 (인플레이스 방식) =====
  // 이동할 파일들을 "대기 상태"에 올려두고, 갤러리를 평소처럼 탐색하다
  // 원하는 폴더에서 하단 바의 "여기로 이동"으로 확정한다.
  void _safMoveRefs(List<({String uri, String name})> refs) {
    if (refs.isEmpty) {
      return;
    }
    final rootUri = _rootUri;
    if (rootUri == null) {
      return;
    }
    setState(() {
      _pendingMoveRefs = List.of(refs);
      _pendingMoveFromParent = _safDirUri ?? rootUri;
      // 선택모드는 종료 (이동 모드로 전환)
      _selectMode = false;
      _selected.clear();
    });
    // 지금 폴더에 하위 폴더가 없으면 여기선 옮길 곳이 없다 (원래 폴더라 '여기로'도 꺼져 있다).
    //  → 바로 위 폴더로 올라가 옆 폴더들을 보여 준다. 맨 위 폴더면 올라갈 곳이 없으니 그대로.
    if (_safFolders.isEmpty && _safStack.isNotEmpty) {
      _safGoUp();
    }
  }

  // 이동 대기 취소
  void _cancelPendingMove() {
    setState(() {
      _pendingMoveRefs = null;
      _pendingMoveFromParent = null;
    });
  }

  // ===== 휴지통 보기 =====

  /// [slot] 저장 폴더의 휴지통을 연다 ('변경' 목록에서). 기한이 지난 그림은 열 때 먼저 지워진다.
  Future<void> _openTrash(int slot) async {
    // 둘러보는 칸은 휴지통을 연 뒤에 바꾼다 — 열지 못했을 때 화면(지금 폴더)과 칸이 어긋나지 않게
    final String? root = widget.state.safSlotUris[slot];
    if (root == null) {
      return;
    }
    setState(() {
      _loading = true;
      _selectMode = false;
      _selected.clear();
    });
    final info = await widget.state.openSafTrash(root);
    if (!mounted) {
      return;
    }
    if (info == null) {
      setState(() => _loading = false);
      _showBriefSnack("휴지통을 열지 못했어요");
      return;
    }
    _browseSlot = slot == widget.state.activeSafSlot ? null : slot;
    _trashMode = true;
    _trashDeletedAt = info.deletedAt;
    _safStack.clear();
    await _loadSafDir(info.dirUri, "휴지통");
  }

  /// 휴지통에서 나가 지금 저장 중인 폴더의 맨 위로
  void _exitTrash() {
    _browseSlot = null;
    _loadSafRootDir(); // 휴지통 보기를 끈다
  }

  /// 휴지통 그림의 '남은 날' 표시 (자동으로 지워지기까지)
  Widget? _trashBadge(String name) {
    final int? t = _trashDeletedAt[name];
    if (t == null) {
      return null;
    }
    final int left = widget.state.trashDaysLeft(t);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        left <= 0 ? "곧 삭제" : "$left일",
        style: TextStyle(
          color: left <= 2 ? Colors.redAccent : Colors.white70,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 휴지통에서 되돌리기 (원래 폴더로). [onDone] 은 뷰어에서 불렀을 때 뷰어를 닫는다.
  Future<void> _restoreTrashRefs(
    List<({String uri, String name})> refs, [
    VoidCallback? onDone,
  ]) async {
    final String? root = _rootUri;
    if (root == null || refs.isEmpty) {
      return;
    }
    final done = await widget.state.restoreSafTrash(refs, rootUri: root);
    if (!mounted) {
      return;
    }
    if (done.isNotEmpty) {
      onDone?.call();
    }
    setState(() {
      for (final uri in done) {
        _forgetSafImage(uri);
      }
      _selectMode = false;
      _selected.clear();
    });
    _showBriefSnack(done.isEmpty ? "되돌리지 못했어요" : "${done.length}장을 되돌렸어요");
  }

  /// 휴지통에서 완전히 지우기 (확인 후)
  Future<void> _purgeTrashRefs(
    List<({String uri, String name})> refs, [
    VoidCallback? onDone,
  ]) async {
    final String? root = _rootUri;
    if (root == null || refs.isEmpty) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: "영구 삭제",
      message: refs.length == 1
          ? "${refs.first.name}\n완전히 지웁니다. 되돌릴 수 없어요."
          : "${refs.length}장을 완전히 지웁니다. 되돌릴 수 없어요.",
      confirmLabel: "영구 삭제",
      icon: Icons.delete_forever_outlined,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final done = await widget.state.deleteSafTrash(refs, rootUri: root);
    if (!mounted) {
      return;
    }
    if (done.isNotEmpty) {
      onDone?.call();
    }
    setState(() {
      for (final uri in done) {
        _forgetSafImage(uri);
      }
      _selectMode = false;
      _selected.clear();
    });
    _showBriefSnack(done.isEmpty ? "지우지 못했어요" : "${done.length}장을 완전히 지웠어요");
  }

  /// 휴지통 비우기 — 지금 보이는 휴지통의 그림을 모두 완전히 지운다 (확인 후)
  Future<void> _emptyTrash() async {
    final String? root = _rootUri;
    final refs = List.of(_safImages);
    if (root == null || refs.isEmpty) {
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: "휴지통 비우기",
      message: "휴지통의 ${refs.length}장을 모두 완전히 지웁니다. 되돌릴 수 없어요.",
      confirmLabel: "비우기",
      icon: Icons.delete_forever_outlined,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final done = await widget.state.deleteSafTrash(refs, rootUri: root);
    if (!mounted) {
      return;
    }
    setState(() {
      for (final uri in done) {
        _forgetSafImage(uri);
      }
      _selectMode = false;
      _selected.clear();
    });
    _showBriefSnack("휴지통을 비웠어요 (${done.length}장)");
  }

  // 짧게 뜨는 스낵바 (삭제/이동 등 — 하단 버튼을 덜 가리도록 짧고 floating)
  void _showBriefSnack(String msg) {
    if (!mounted) {
      return;
    }
    // 연속으로 뜨는 알림이라 이전 것을 먼저 지운다 (겹침 방지)
    ScaffoldMessenger.of(context).clearSnackBars();
    showToast(context, msg, length: ToastLength.short, floating: true, small: true);
  }

  // 현재 보고 있는 폴더로 이동 확정
  Future<void> _confirmPendingMoveHere() async {
    final refs = _pendingMoveRefs;
    final from = _pendingMoveFromParent;
    if (refs == null || from == null) {
      return;
    }
    final toParent = _safDirUri ?? _rootUri;
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
      // 이름도 넘긴다 — 다른 저장 폴더 칸으로 갈 땐 복사 후 삭제로 옮긴다 (moveSafImage)
      final newUri = await widget.state.moveSafImage(ref.uri, fromParent, toParent, name: ref.name);
      if (newUri != null) {
        moved++;
        // 이동된 파일은 목록/캐시에서 제거 (더 이상 원본 폴더에 없음)
        _forgetSafImage(ref.uri);
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {}); // 목록에서 제거된 것 즉시 반영
    _showBriefSnack("$moved장 이동");
    if (moved == 0) {
      return;
    }

    // 이동은 '두 폴더'를 바꾼다. 양쪽을 모두 챙겨야 한다.
    //  ⚠️ 예전에는 대상 폴더 타일만 갱신해서 이런 문제가 있었다.
    //     · 대상 폴더를 보고 있으면 옮긴 이미지가 안 보였다 (목록을 안 읽음)
    //     · 위로 올라가면 두 폴더의 썸네일이 옛 그림 그대로였다
    //  전체 재조회는 하지 않는다. 바뀐 두 폴더만 정확히 다시 읽는다.

    // ① 지금 보고 있는 폴더가 '대상 폴더'라면 그 목록을 다시 읽는다.
    //    (출발 폴더를 보고 있었다면 위에서 이미 빼 두었으므로 그대로 둔다)
    if (_safDirUri == toParent) {
      // ⚠️ _refreshSafImagesOnly 를 쓰면 안 된다.
      //    그 함수는 '이미지 생성 후 저장' 용이라 "최근 저장된 폴더"
      //    (lastSavedSafDirUri) 를 먼저 보고, 그게 지금 폴더와 다르면
      //    지금 폴더는 다시 읽지 않고 돌아가 버린다.
      //    이동은 저장과 무관하므로 그 판단이 엉뚱하게 걸려
      //    옮긴 이미지가 보이지 않았다.
      await _reloadCurrentSafImages();
      if (!mounted) {
        return;
      }
    }

    // ② 폴더 타일의 개수·미리보기를 양쪽 다 갱신한다.
    //    미리보기 캐시를 먼저 비워야 새 그림을 읽는다.
    for (final uri in {fromParent, toParent}) {
      _safFolderPreview.remove(uri);
      _safPreviewFutures.remove(uri);
      final idx = _safFolders.indexWhere((f) => f.uri == uri);
      if (idx >= 0) {
        await _refreshOneSafFolder(idx, uri);
        if (!mounted) {
          return;
        }
      }
    }
  }

  // 파일 폴더 칸 — 미리보기는 이미 읽어 둔 파일들, 모양은 _folderTile
  Widget _buildFolderTile(_FolderInfo info, int columns) {
    return _folderTile(
      name: _baseName(info.dir.path),
      count: info.imageCount,
      columns: columns,
      onTap: () => _loadFolder(info.dir.path),
      preview: info.previews.isNotEmpty
          ? _mosaicLayout(info.previews, _thumb)
          : _emptyFolderPreview,
    );
  }

  Widget _thumb(File f) {
    return Image.file(
      f,
      fit: BoxFit.cover,
      cacheWidth: 200,
      errorBuilder: (ctx, err, st) => Container(color: Colors.white10),
    );
  }

  // 파일 이미지 칸 — 그림만 파일에서 읽고, 나머지는 _imageTile
  Widget _buildImageTile(File img, int imgIndex) {
    return _imageTile(
      id: img.path,
      onOpen: () => _openImageViewer(imgIndex),
      image: Image.file(
        img,
        fit: BoxFit.cover,
        cacheWidth: 300,
        errorBuilder: (ctx, err, st) => _brokenImage,
      ),
    );
  }

  /// 그리드의 이미지 칸 (SAF·파일 공용). 그림은 [image] 로 받고,
  ///  누르기(열기/선택)·길게 누르기(선택 시작)·선택 표시는 여기서 한다.
  ///  ⚠️ 예전엔 SAF 칸과 파일 칸이 이 부분을 각자 복사해 갖고 있었다.
  //  [badge] 가 있으면 오른쪽 아래에 붙인다 (휴지통의 '남은 날' — 선택 중엔 숨긴다).
  Widget _imageTile({
    required String id,
    required Widget image,
    required VoidCallback onOpen,
    Widget? badge,
  }) {
    final bool selected = _selected.contains(id);
    return GestureDetector(
      onTap: () => _selectMode ? _toggleSelect(id) : onOpen(),
      onLongPress: () => _selectMode ? _toggleSelect(id) : _enterSelect(id),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: image),
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
          if (badge != null && !_selectMode) Positioned(right: 4, bottom: 4, child: badge),
        ],
      ),
    );
  }

  /// 그림을 읽지 못했을 때 (SAF·파일 공용)
  static final Widget _brokenImage = Container(
    color: Colors.white10,
    child: const Icon(Icons.broken_image, color: Colors.white24),
  );

  // ── 다중 선택 (SAF·파일 공용) ── id: 파일은 경로, SAF 는 uri
  void _enterSelect(String id) {
    setState(() {
      _selectMode = true;
      _selected
        ..clear()
        ..add(id);
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
        if (_selected.isEmpty) {
          _selectMode = false;
        }
      } else {
        _selected.add(id);
      }
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  // 선택 모드 상단 툴바: [취소] [n장 선택됨] ... [ⓘ 메뉴] [이동] [삭제]
  Widget _buildSelectionToolbar() {
    return SizedBox(
      height: 40,
      child: _trashMode
          // 휴지통: [되돌리기] [영구 삭제] 만 (ⓘ·이동 없음)
          ? _selectionToolbarShared(
              count: _selected.length,
              onCancel: _exitSelect,
              onInfo: null,
              onRestore: () => _restoreTrashRefs(_safSelectedRefs()),
              deleteLabel: "영구 삭제",
              onDelete: () => _purgeTrashRefs(_safSelectedRefs()),
            )
          : _selectionToolbarShared(
              count: _selected.length,
              onCancel: _exitSelect,
              onInfo: _showSelectionMenu,
              // 이동은 SAF 에서만 (앱 폴더는 이동 기능이 없다)
              onMove: _safMode ? () => _safMoveRefs(_safSelectedRefs()) : null,
              onDelete: _deleteSelected,
            ),
    );
  }

  // 선택된 파일 목록 (현재 폴더 _images 기준)
  List<File> _selectedFiles() {
    return _images.where((f) => _selected.contains(f.path)).toList();
  }

  // 여러 장을 히스토리에 추가 (SAF·파일 공용)
  //  ⚠️ 예전엔 두 벌이라, 파일 쪽은 끝나고 아무 안내도 없었다.
  Future<void> _batchAddToHistory(List<GalleryItem> items) async {
    int added = 0;
    for (final item in items) {
      try {
        final bytes = await item.readBytes();
        if (bytes == null) {
          continue;
        }
        if (!mounted) {
          return;
        }
        await widget.state.addBytesToHistory(
          bytes,
          context,
          filePath: item.filePath,
          showSuccess: false,
        );
        added++;
      } catch (e) {
        debugPrint("히스토리 일괄 추가 실패 (${item.name}): $e");
      }
    }
    if (!mounted) {
      return;
    }
    _exitSelect();
    showToast(context, "$added장을 히스토리에 추가했습니다.");
  }

  // 선택 이미지 삭제 (SAF·파일 공용) — 기기에서 영구 삭제
  //  ⚠️ 예전엔 두 벌이라 끝난 뒤 안내가 달랐다 (토스트 / 짧은 알림).
  Future<void> _deleteSelected() async {
    final files = _safMode ? const <File>[] : _selectedFiles();
    final refs = _safMode ? _safSelectedRefs() : const <({String uri, String name})>[];
    final int count = files.length + refs.length;
    if (count == 0) {
      return;
    }
    // 저장 폴더(SAF)의 그림은 설정에 따라 휴지통으로 — 앱 폴더의 그림은 늘 바로 지운다
    final String? root = _rootUri;
    final bool toTrash = refs.isNotEmpty && widget.state.trashEnabled && root != null;
    final confirmed = await showConfirmDialog(
      context,
      title: toTrash ? "휴지통으로 보내기" : "이미지 삭제",
      message: toTrash
          ? "$count장을 휴지통으로 보냅니다.\n${widget.state.trashKeepDays}일 뒤 자동으로 지워져요."
          : "$count장의 이미지를 기기에서 영구 삭제합니다.\n이 작업은 되돌릴 수 없습니다.",
      confirmLabel: toTrash ? "보내기" : "삭제",
      icon: Icons.delete_outline,
    );
    if (!confirmed) {
      return;
    }
    int deleted = 0;
    // root 는 toTrash 안에서 이미 null 이 아님이 확인된다 (Dart 가 toTrash 를 통해 알아본다)
    if (toTrash) {
      final done = await widget.state.trashSafImages(
        refs,
        fromDirUri: _safDirUri ?? root,
        rootUri: root,
      );
      for (final uri in done) {
        _forgetSafImage(uri);
      }
      deleted = done.length;
    } else {
      for (final ref in refs) {
        if (await widget.state.deleteSafImage(ref.uri)) {
          deleted++;
          _forgetSafImage(ref.uri);
        }
      }
    }
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
    if (files.isNotEmpty && _currentPath != null) {
      await _loadFolder(_currentPath!);
    }
    if (mounted) {
      showToast(context, toTrash ? "$deleted장을 휴지통으로 보냈습니다." : "$deleted장을 삭제했습니다.");
    }
  }

  // 파일 이미지 뷰어 (좌우 스와이프로 이전/다음)
  void _openImageViewer(int startIndex) {
    _openViewer(
      countNow: () => _images.length,
      start: startIndex,
      nameOf: (i) => _baseName(_images[i].path),
      pageOf: _ioViewerPage,
      bytesOf: (i) => _images[i].readAsBytes(),
      itemOf: (i, close) => _fileItem(_images[i]),
    );
  }

  /// 공용 뷰어(_GalleryImageViewer)를 연다 (SAF·파일 공용).
  ///  [countNow] 는 '지금' 개수 — 뷰어에서 지우면 목록이 줄어들어, 여는 순간의 개수로는 부족하다.
  ///  ⚠️ 예전엔 SAF·파일이 이 여는 코드를 각자 갖고 있었고, 정보 줄 오류 처리도 파일 쪽에만 있었다.
  void _openViewer({
    required int Function() countNow,
    required int start,
    required String Function(int) nameOf,
    required Widget Function(int) pageOf,
    required Future<Uint8List?> Function(int) bytesOf,
    required GalleryItem Function(int, VoidCallback) itemOf,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => _GalleryImageViewer(
        itemCount: countNow(),
        startIndex: start,
        nameOf: nameOf,
        pageOf: pageOf,
        infoOf: (i) async {
          if (i >= countNow()) {
            return null;
          }
          try {
            // ⚠️ await 를 붙여야 한다. 없으면 _readImageInfo 안에서 난 오류가
            //    try 를 빠져나간 뒤에 터져 catch 가 잡지 못한다.
            final bytes = await bytesOf(i);
            return bytes == null ? null : await _readImageInfo(bytes);
          } catch (_) {
            return null; // 파일이 사라졌으면 정보 줄만 비운다
          }
        },
        onLongPress: (i, close) => _showGalleryImageMenu(itemOf(i, close), close),
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
/// 뷰어 상단에 보여 줄 이미지 정보.
typedef _ImageInfo = ({int width, int height, int bytes});

/// 이미지의 해상도와 용량을 읽는다.
///
/// 해상도는 [ui.ImageDescriptor] 로 '헤더만' 읽어서 얻는다.
///  ⚠️ 이미지를 통째로 디코딩(img.decodeImage 등)하면 1MB짜리도 수백 ms가 걸려
///     넘길 때마다 화면이 멈칫한다. 헤더에는 가로·세로가 적혀 있어 그것만 보면 된다.
Future<_ImageInfo?> _readImageInfo(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? desc;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    desc = await ui.ImageDescriptor.encoded(buffer);
    return (width: desc.width, height: desc.height, bytes: bytes.length);
  } catch (_) {
    // 형식을 못 알아보면 용량만이라도 보여 준다
    return (width: 0, height: 0, bytes: bytes.length);
  } finally {
    desc?.dispose();
    buffer?.dispose();
  }
}

/// 1,468,006 → "1.4MB", 830,000 → "811KB"
String _formatBytes(int b) {
  if (b >= 1024 * 1024) {
    return "${(b / (1024 * 1024)).toStringAsFixed(1)}MB";
  }
  if (b >= 1024) {
    return "${(b / 1024).round()}KB";
  }
  return "${b}B";
}

class _GalleryImageViewer extends StatefulWidget {
  final int itemCount;
  final int startIndex;
  final String Function(int index) nameOf;
  final Widget Function(int index) pageOf;
  final void Function(int index, VoidCallback closeViewer)? onLongPress;
  // 상단에 해상도·용량을 보여 주기 위한 정보. 없으면 그 줄을 생략한다.
  final Future<_ImageInfo?> Function(int index)? infoOf;
  const _GalleryImageViewer({
    required this.itemCount,
    required this.startIndex,
    required this.nameOf,
    required this.pageOf,
    this.onLongPress,
    this.infoOf,
  });

  @override
  State<_GalleryImageViewer> createState() => _GalleryImageViewerState();
}

class _GalleryImageViewerState extends State<_GalleryImageViewer> {
  late PageController _pageController;
  late int _index;
  // 넘길 때마다 다시 읽지 않도록 페이지별로 한 번만 계산해 둔다
  final Map<int, Future<_ImageInfo?>> _infoCache = {};

  Future<_ImageInfo?>? _infoFor(int i) {
    final f = widget.infoOf;
    if (f == null) {
      return null;
    }
    return _infoCache.putIfAbsent(i, () => f(i));
  }

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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.nameOf(_index),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // 해상도 · 용량 (이름과 같은 크기, 조금 흐리게)
                        if (_infoFor(_index) != null)
                          FutureBuilder<_ImageInfo?>(
                            // 키가 없으면 넘길 때 이전 페이지 값이 잠깐 남는다
                            key: ValueKey(_index),
                            future: _infoFor(_index),
                            builder: (ctx, snap) {
                              final info = snap.data;
                              final String text;
                              if (info == null) {
                                text = snap.connectionState == ConnectionState.done ? "" : "…";
                              } else if (info.width > 0) {
                                text = "${info.width}×${info.height}   ${_formatBytes(info.bytes)}";
                              } else {
                                text = _formatBytes(info.bytes);
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  text,
                                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                                ),
                              );
                            },
                          ),
                      ],
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
