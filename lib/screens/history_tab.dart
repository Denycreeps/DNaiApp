import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/history_search.dart'; // 히스토리 검색 (프롬프트로 거르기)
import '../models/image_metadata.dart';
import '../models/model_caps.dart'; // 다시 생성 창의 모델 고르기
import '../widgets/detail_settings_modal.dart';
import '../widgets/gallery_view.dart';
import '../app_theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/app_toast.dart';
import '../widgets/tag_search_field.dart'; // 검색칸 (갤러리 검색과 같은 모양)
import '../utils/ui_safety.dart'; // hideKeyboardIfShown (DEVNOTES 4)
import '../utils/temp_files.dart'; // 그림 고르기 (캐시 복사본은 읽고 바로 지운다)

// ============================================================================
// 히스토리 탭 메인 UI
// (중복된 데이터 파싱 기능은 모두 app_state.dart로 깔끔하게 이사갔습니다!)
// ============================================================================
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> with AutomaticKeepAliveClientMixin {
  // 탭 전환 시 상태를 유지해 재방문이 즉시 이뤄지게 한다
  @override
  bool get wantKeepAlive => true;

  late PageController _pageController;

  // 새 이미지 추가 등으로 특정 페이지로 강제 이동하는 중임을 표시한다.
  // PageView가 리스트 길이 변화로 스스로 onPageChanged를 발생시켜
  // 목표 위치를 덮어쓰는 것을 막는다.
  int? _pendingJumpTarget;
  late ScrollController _thumbnailScrollController;

  // 목록 스크롤 컨트롤러는 이 탭이 직접 소유한다.
  //  main이 만들어 넘기던 것을 여기로 옮겼다. (탭 전환 중 두 인스턴스가
  //  같은 컨트롤러를 붙잡아 'attached to multiple scroll views'로 멈추던 문제)
  final ScrollController _listScrollController = ScrollController();
  int _lastScrollToEndRevision = 0;
  int _lastEnterRevision = 0;
  late AppState _appState;

  int _currentIndex = 0;
  int _prevImageCount = 0;
  // 목록의 맨 끝 칸 — 장수와 함께 '새 그림이 들어왔나' 를 본다 (⑤).
  //  ⚠️ 장수만 보면 상한이 찬 뒤엔 한 장 빠지고 한 장 들어와 장수가 그대로라 새 그림을 못 알아챈다.
  HistoryEntry? _prevLastEntry;
  bool _isPromptOpen = false;
  _InfoTab _infoTab = _InfoTab.positive; // 정보 칸에서 보고 있는 탭
  bool _isAnimating = false;
  bool _showFavoritesOnly = false;
  bool _wasGridView = false;
  bool _isSelectMode = false;
  bool _isGalleryMode = false; // 갤러리 모드 (폴더 탐색)
  // 갤러리 검색칸이 열려 있는지 — 갤러리 줄의 🔍 색을 맞추려고. 쓰는 쪽은 GalleryView (열고 닫을 때),
  //  갤러리에 들어갈 때만 여기서 false 로 맞춘다 (새 GalleryView 는 닫힌 채로 시작한다).
  final ValueNotifier<bool> _gallerySearchOpen = ValueNotifier<bool>(false);
  final GlobalKey<GalleryViewState> _galleryKey = GlobalKey<GalleryViewState>();
  // 그리드에서 고른 칸 — 번호가 아니라 칸(객체)으로 든다.
  //  ⚠️ 예전엔 번호로 들었다. 고르는 사이 상한이 찬 채 새 그림이 들어오면 맨 앞 칸이 빠져 번호가 하나씩 밀려,
  //     '선택 삭제' 가 옆 칸(즐겨찾기도)을 지웠다 (DEVNOTES 5).
  final Set<HistoryEntry> _selected = {};

  // ── 히스토리 검색 (models/history_search.dart) ──
  //  그리드에서 거르고, 결과를 누르면 목록에서 그 그림을 연다 (목록은 늘 전체 — 번호가 섞이지 않게).
  //  검색어는 저장하지 않는다 (이 탭이 살아 있는 동안만).
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  HistoryQuery _query = parseHistoryQuery('');
  // 그림 정보 → 찾을 글. 정보는 바뀌지 않으므로 한 번만 만든다 (정보를 통째로 바꾸면 새 열쇠라 새로 만든다)
  final Expando<String> _searchTextCache = Expando<String>();

  bool get _isSearching => !isEmptyQuery(_query);

  // 검색칸을 열어 두었는지 (돋보기). 닫으면 검색어도 지운다 — 안 보이는 검색어가 그리드를 거르고 있지 않게.
  //  그래서 검색 중(_isSearching)이면 늘 열려 있다.
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppState>();
    _currentIndex = _appState.selectedHistoryIndex >= 0 ? _appState.selectedHistoryIndex : 0;
    _pageController = PageController(initialPage: _currentIndex);
    // 탭 재생성 시 기존 이미지들을 "새로 추가된 것"으로 오인해
    // 불필요한 점프/스크롤이 발동하지 않도록 현재 개수를 기준선으로 잡는다.
    _prevImageCount = _appState.historyImages.length;
    _prevLastEntry = _appState.history.isEmpty ? null : _appState.history.last;

    _thumbnailScrollController = _newThumbController(_appState.historyThumbnailScrollOffset);
    _wasGridView = _appState.isHistoryGridView;
    // '히스토리 탭 마지막 보기 유지'가 켜져 있으면 마지막 보기로 시작 (앱을 다시 켰을 때도)
    _isGalleryMode =
        _appState.historyKeepLastView &&
        _appState.historyLastWasGallery &&
        _appState.galleryModeEnabled;
    // 만들어지기 전에 쌓인 '탭 떠남' 신호로 방금 연 갤러리를 닫지 않게 기준을 맞춘다
    _lastEnterRevision = _appState.historyGalleryResetRevision;

    // 앱 상태가 보내는 '사건'은 리스너에서 처리한다 (build 에서 엿보지 않는다).
    _appState.addListener(_onAppStateChanged);
    //  탭이 만들어지기 '전에' 온 요청(예: 이 탭으로 오면서 보낸 '맨 아래로')도 놓치지 않게,
    //  첫 프레임 뒤에 한 번 확인한다. (예전 build 방식은 첫 그리기 때 처리됐다)
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAppStateChanged());

    // 앱을 완전히 껐다 켜면 저장된 썸네일 스크롤 위치가 없어(0) 맨 왼쪽에 머무는데,
    // 선택된 이미지는 최신(맨 오른쪽)이라 서로 어긋난다.
    // → 저장된 위치가 없을 때만 첫 프레임 뒤 선택 항목으로 즉시 맞춰준다.
    if (_appState.historyThumbnailScrollOffset == 0 && _currentIndex > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToThumbnail(_currentIndex, animate: false);
        }
      });
    }
  }

  @override
  void dispose() {
    _appState.removeListener(_onAppStateChanged);
    _pageController.dispose();
    _thumbnailScrollController.dispose();
    _listScrollController.dispose();
    _searchController.dispose();
    _gallerySearchOpen.dispose();
    // FocusNode 는 한 프레임 뒤에 버린다 (DEVNOTES 4)
    final FocusNode focus = _searchFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) => focus.dispose());
    super.dispose();
  }

  // ── 히스토리 검색 ───────────────────────────────────────────────
  String _searchTextOf(NaiMetadata? meta) =>
      meta == null ? '' : (_searchTextCache[meta] ??= historySearchText(meta));

  /// 그리드에 보일 칸들 (실제 번호, 최신 먼저) — 즐겨찾기 · 검색을 함께 건다
  List<int> _visibleIndices(AppState state) {
    final history = state.history;
    return [
      for (int i = history.length - 1; i >= 0; i--)
        if ((!_showFavoritesOnly || history[i].favorite) &&
            (!_isSearching || historyMatches(_searchTextOf(history[i].metadata), _query)))
          i,
    ];
  }

  /// 키보드만 내린다 — 포커스는 건드리지 않는다 (DEVNOTES 4 · utils/ui_safety.dart)
  void _hideKeyboard() => hideKeyboardIfShown(_searchFocus);

  /// 검색어를 바꾼다. [fromTyping] — 사용자가 칸에 친 것 (지우기 버튼은 false).
  void _setQuery(String text, {bool fromTyping = true}) {
    setState(() {
      _query = parseHistoryQuery(text);
      // 고르기 중이면 화면에서 사라진 칸은 고른 것에서 뺀다 — 안 보이는 그림이 '선택 삭제' 로 지워지지 않게
      if (_isSelectMode) {
        final List<HistoryEntry> all = _appState.history;
        final Set<HistoryEntry> shown = {for (final i in _visibleIndices(_appState)) all[i]};
        _selected.retainWhere(shown.contains);
        if (_selected.isEmpty) {
          _isSelectMode = false;
        }
      }
    });
    // 목록 보기에서 치면 결과(그리드)로 간다 — 목록은 거르지 않는다.
    //  검색어가 비게 쳐도 간다 (안 가면 목록의 검색칸이 치는 도중에 사라진다)
    if (fromTyping && !_appState.isHistoryGridView) {
      _appState.isHistoryGridView = true;
      _appState.refreshUI();
    }
  }

  /// 검색칸을 연다 — 칸이 그려진 뒤 커서를 둔다 (돋보기를 눌렀으니 바로 칠 수 있게)
  ///  막 생긴 칸으로 포커스를 '넣는' 것이라 DEVNOTES 4 (포커스를 빼지 않는다) 와 부딪히지 않는다.
  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen && !_searchFocus.hasFocus) {
        _searchFocus.requestFocus();
      }
    });
  }

  /// 검색칸을 닫는다 — 검색어도 지운다. 칸이 사라지기 전에 키보드부터 내린다 (포커스는 건드리지 않는다).
  void _closeSearch() {
    _hideKeyboard();
    _searchController.clear();
    _setQuery('', fromTyping: false);
    setState(() => _searchOpen = false);
  }

  /// 검색칸 — 돋보기로 열면 그리드에, 목록에서는 검색 중일 때만 보인다 (결과로 돌아갈 수 있게)
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TagSearchField(
        controller: _searchController,
        focusNode: _searchFocus,
        active: _isSearching,
        onChanged: _setQuery,
        // 검색 키 — 키보드만 내린다
        onSearchKey: _hideKeyboard,
        onClear: () {
          // 목록 보기에서 지우면 검색칸이 사라진다 — 키보드부터 내린다
          if (!_appState.isHistoryGridView) {
            _hideKeyboard();
          }
          _searchController.clear();
          _setQuery('', fromTyping: false);
        },
      ),
    );
  }

  // ── 도구 줄 ─────────────────────────────────────────────────────
  /// 도구 줄의 알약 버튼.
  ///  [color] 가 있으면 '켜진' 모양 — 그 색을 옅게 깐 바탕([fill]) + 그 색 테두리.
  ///  없으면 기본 모양 — 어두운 바탕 + 흐린 테두리.
  ///  [label] 이 없으면 아이콘만 (가로 여백이 조금 좁다), [icon] 이 없으면 글자만.
  ///  ⚠️ 예전엔 이 모양 코드를 버튼마다 복사해서 도구 줄 하나가 270줄이었다.
  Widget _pill({
    IconData? icon,
    String? label,
    Color? color,
    double fill = 0.15,
    double? borderWidth, // 기본: 켜지면 1.5, 아니면 1.0
    Color? iconColor, // 기본: color, 없으면 흐린 흰색
    Color labelColor = Colors.white,
    double iconSize = 18,
    double gap = 6,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(horizontal: label != null ? 12 : 10, vertical: 8),
        decoration: BoxDecoration(
          color: color != null ? color.withValues(alpha: fill) : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: color ?? Colors.white24,
            width: borderWidth ?? (color != null ? 1.5 : 1.0),
          ),
        ),
        // 글자만인 알약도 아이콘 알약과 높이가 같게 (아이콘 높이만큼은 늘 차지한다)
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: iconSize),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(icon, size: iconSize, color: iconColor ?? color ?? Colors.white54),
              if (icon != null && label != null) SizedBox(width: gap),
              if (label != null)
                Text(
                  label,
                  style: TextStyle(color: labelColor, fontSize: 13, fontWeight: FontWeight.bold),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 목록/그리드 위의 도구 줄. 선택 모드(그리드)면 [취소 · n장 선택됨 · 삭제],
  ///  아니면 [목록/그리드 · 갤러리 · n장 · 검색 · (그리드면) 즐겨찾기 · 삭제 · 불러오기].
  ///  ⚠️ 폭이 빠듯하다 — 목록/그리드 · 갤러리는 글자만, 오른쪽은 아이콘만 둔다 (남는 자리는 장수가 쓴다).
  Widget _buildToolbar(
    BuildContext context,
    AppState state,
    int count,
    bool isGridView, {
    int? shown, // 그리드에서 거르는 중이면 보이는 장수 ("12/340장")
  }) {
    const countStyle = TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.bold);
    final bool hasSelection = _selected.isNotEmpty;
    return SizedBox(
      height: 40,
      child: _isSelectMode && isGridView
          // ===== 선택 모드 =====
          ? Row(
              children: [
                _pill(
                  icon: Icons.close,
                  label: "취소",
                  iconSize: 16,
                  gap: 4,
                  labelColor: Colors.white54,
                  onTap: () => setState(() {
                    _isSelectMode = false;
                    _selected.clear();
                  }),
                ),
                const SizedBox(width: 8),
                Text(
                  "${_selected.length}장 선택됨",
                  style: countStyle.copyWith(color: Colors.white),
                ),
                const Spacer(),
                // 선택 삭제 — 고른 게 있을 때만 빨갛게 켜진다
                _pill(
                  icon: Icons.delete_outline,
                  label: "삭제",
                  color: hasSelection ? Colors.redAccent : null,
                  fill: 0.2,
                  borderWidth: 1.0,
                  iconColor: hasSelection ? Colors.redAccent : Colors.white38,
                  labelColor: hasSelection ? Colors.redAccent : Colors.white38,
                  gap: 4,
                  onTap: !hasSelection
                      ? null
                      : () async {
                          final ok = await showConfirmDialog(
                            context,
                            title: "선택 삭제",
                            message:
                                "${_selected.length}장의 이미지를 히스토리에서 삭제하시겠습니까?\n(실제 파일은 삭제되지 않습니다.)",
                            confirmLabel: "삭제",
                            icon: Icons.delete_outline,
                          );
                          if (!ok || !mounted) {
                            return;
                          }
                          // 칸(객체)으로 지운다 — 확인 창이 떠 있는 사이 번호가 밀려도 고른 그대로
                          state.deleteHistoryEntries(_selected);
                          setState(() {
                            _isSelectMode = false;
                            _selected.clear();
                          });
                        },
                ),
              ],
            )
          // ===== 일반 모드 =====
          : Row(
              children: [
                // 목록 ↔ 그리드 (하나의 토글) — 글자만 (자리를 아끼려 아이콘을 뺐다)
                _pill(
                  label: isGridView ? "리스트" : "그리드",
                  color: AppColors.accent,
                  onTap: () {
                    if (isGridView) {
                      _hideKeyboard(); // 큰 그림이 키보드에 가리지 않게
                      setState(() {
                        _isSelectMode = false;
                        _selected.clear();
                      });
                      state.isHistoryGridView = false;
                    } else {
                      state.isHistoryGridView = true;
                    }
                    state.refreshUI();
                  },
                ),
                if (state.galleryModeEnabled) ...[
                  const SizedBox(width: 8),
                  // 갤러리 (폴더 탐색 모드) — 글자만
                  _pill(
                    label: "갤러리",
                    color: AppColors.amber,
                    fill: 0.12,
                    onTap: () {
                      _hideKeyboard(); // 검색칸이 사라지기 전에 키보드부터
                      _gallerySearchOpen.value = false; // 새 갤러리는 검색칸이 닫힌 채로 시작한다
                      setState(() {
                        _isGalleryMode = true;
                        state.setHistoryLastWasGallery(true);
                        _isSelectMode = false;
                        _selected.clear();
                      });
                    },
                  ),
                ],
                // 장수 — 남는 자리에 오른쪽으로. 좁으면 글자를 줄인다 ('12/340장' 처럼 길어져도 줄이 넘치지 않게)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(shown == null ? "$count장" : "$shown/$count장", style: countStyle),
                    ),
                  ),
                ),
                // 목록 보기의 검색 — 그리드로 가서 검색칸을 연다 (검색 중이면 목록에도 검색칸이 보여 필요 없다)
                if (!isGridView && !_isSearching && count > 0) ...[
                  const SizedBox(width: 8),
                  _pill(
                    icon: Icons.search,
                    onTap: () {
                      state.isHistoryGridView = true;
                      state.refreshUI();
                      _openSearch();
                    },
                  ),
                ],
                if (isGridView) ...[
                  // 검색칸 열기/닫기 — 열려 있으면 강조색 (닫으면 검색어도 지운다)
                  if (count > 0) ...[
                    const SizedBox(width: 8),
                    _pill(
                      icon: Icons.search,
                      color: _searchOpen ? AppColors.accent : null,
                      fill: 0.2,
                      onTap: _searchOpen ? _closeSearch : _openSearch,
                    ),
                  ],
                  const SizedBox(width: 8),
                  // 즐겨찾기만 보기
                  _pill(
                    icon: _showFavoritesOnly ? Icons.star : Icons.star_border,
                    color: _showFavoritesOnly ? AppColors.amber : null,
                    fill: 0.2,
                    onTap: () => setState(() => _showFavoritesOnly = !_showFavoritesOnly),
                  ),
                  // 삭제 (불러오기 앞)
                  if (count > 0) ...[
                    const SizedBox(width: 8),
                    _pill(
                      icon: Icons.delete_outline,
                      onTap: () => _showBulkDeleteSheet(context, state),
                    ),
                  ],
                  // 불러오기 (맨 오른쪽) — 아이콘만. 기본 모양 (검색 · 즐겨찾기 · 삭제와 같은 회색 — 켜고 끄는 버튼이 아니라서)
                  const SizedBox(width: 8),
                  Tooltip(
                    message: "이미지 불러오기",
                    child: _pill(
                      icon: Icons.add_photo_alternate_outlined,
                      onTap: () => state.importImageToHistory(context),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  // ── 앱 상태가 보낸 '사건' 처리 ────────────────────────────────────
  //  갤러리 닫기·맨 아래로·썸네일 끝으로·그리드→목록 전환·새 이미지 감지.
  //  ⚠️ 예전엔 build 안에서 번호(…Revision)를 엿보며 처리해, 그리는 도중에 상태를
  //     열다섯 번 바꿨다(컨트롤러를 버리고 새로 만드는 것까지). 이제 앱 상태가 바뀔 때만
  //     여기서 한 번 처리하고, 화면은 그리기만 한다.
  void _onAppStateChanged() {
    if (!mounted) {
      return;
    }
    final state = _appState;
    final images = state.historyImages;
    final bool isGridView = state.isHistoryGridView;
    bool changed = false;

    // ⓪ 고르는 중이면 그 사이 없어진 칸(상한 정리 · 가져오기 · 전부 지우기)은 고른 것에서 뺀다 — 'n장 선택됨' 이 맞게
    if (_isSelectMode && _selected.isNotEmpty) {
      final Set<HistoryEntry> live = state.history.toSet();
      final int before = _selected.length;
      _selected.retainWhere(live.contains);
      if (_selected.length != before) {
        if (_selected.isEmpty) {
          _isSelectMode = false;
        }
        changed = true;
      }
    }

    // ① 탭을 떠날 때 보낸 신호 — 화면 밖에 있는 동안 갤러리를 닫아 둔다
    //  (이 탭은 KeepAlive 라 화면 밖에서도 살아 있다 → 돌아오면 이미 목록/그리드)
    if (state.historyGalleryResetRevision != _lastEnterRevision) {
      _lastEnterRevision = state.historyGalleryResetRevision;
      if (_isGalleryMode) {
        if (state.historyKeepLastView) {
          // 마지막 보기 유지 — 갤러리는 그대로 두고, 다른 저장 폴더를 보던 중이면 지금 폴더로 돌려 둔다
          _galleryKey.currentState?.showActiveFolder();
        } else {
          _leaveGallery();
          changed = true;
        }
      }
    }

    // ② main 이나 프롬프트 탭에서 온 "히스토리 맨 아래로" 요청 (번호가 늘 때마다 한 번)
    if (state.historyScrollToEndRevision != _lastScrollToEndRevision) {
      _lastScrollToEndRevision = state.historyScrollToEndRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_listScrollController.hasClients) {
          return;
        }
        _listScrollController.animateTo(
          _listScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }

    // ③ 썸네일 줄을 끝으로 (목록 모드일 때만)
    if (!isGridView && state.scrollToThumbnailEnd) {
      state.scrollToThumbnailEnd = false; // 리스너라 여기서 바로 내려도 된다 (build 가 아니다)
      // 썸네일 줄이 다 그려진 뒤에 끝으로 스크롤 (지연 대신 프레임 콜백 2번)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_thumbnailScrollController.hasClients) {
            return;
          }
          _thumbnailScrollController.animateTo(
            _thumbnailScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        });
      });
    }

    // ④ 그리드 → 목록 전환: 컨트롤러를 올바른 위치로 새로 만든다 (깜빡임·스르륵 방지).
    //  이 순간 화면은 아직 그리드라 옛 컨트롤러는 어디에도 붙어 있지 않다 → 바로 버려도 된다.
    if (_wasGridView && !isGridView && images.isNotEmpty) {
      final syncTarget = state.selectedHistoryIndex >= 0
          ? state.selectedHistoryIndex.clamp(0, images.length - 1)
          : _currentIndex.clamp(0, images.length - 1);
      _startListAt(syncTarget);
      changed = true;
    }
    _wasGridView = isGridView;

    // ⑤ 새 이미지가 추가됐으면 선택된(보통 마지막) 이미지로 이동 (목록 모드일 때만)
    //  ⚠️ 장수만 보면 상한이 찬 뒤엔 새 그림을 못 알아챈다 (한 장 빠지고 한 장 들어와 장수가 그대로) —
    //     큰 그림이 그 번호에 머문 채 내용만 이웃 그림으로 밀려 보였다. 맨 끝 칸이 바뀌었는지도 본다.
    final HistoryEntry? last = state.history.isEmpty ? null : state.history.last;
    if (!isGridView && (images.length != _prevImageCount || !identical(last, _prevLastEntry))) {
      _prevImageCount = images.length;
      _prevLastEntry = last;
      if (images.isNotEmpty && state.selectedHistoryIndex >= 0 && _isGalleryMode) {
        // 갤러리를 보는 중 — 목록 화면이 없어 옮길 수 없다. 번호만 맞춰 두고, 갤러리를 닫을 때 그 자리에서 시작한다
        //  (_leaveGallery). ⚠️ 예전엔 여기서도 '옮기는 중' 표시(_pendingJumpTarget)를 세우고 목록이 붙기를 기다렸다.
        //  갤러리에서 여러 장을 넣으면 기다림이 끝내 포기된 채 표시만 남아, 목록에서 다른 그림을 눌러도 onPageChanged 가
        //  무시돼 선택 테두리 · 정보가 맨 끝 그림에 멈춰 있었다 (그 번호를 다시 누를 때까지).
        _currentIndex = state.selectedHistoryIndex.clamp(0, images.length - 1);
        _pendingJumpTarget = null;
        changed = true;
      } else if (images.isNotEmpty && state.selectedHistoryIndex >= 0) {
        final target = state.selectedHistoryIndex.clamp(0, images.length - 1);
        _currentIndex = target;
        _pendingJumpTarget = target;
        changed = true;
        // 목록이 새로 그려진 뒤에 이동해야 정확하다.
        //  PageView 가 붙을 때까지 프레임 단위로 확인한다 (고정 지연은 기기마다 부족하거나 낭비).
        void jumpWhenReady([int tries = 0]) {
          if (!mounted) {
            return;
          }
          if (!_pageController.hasClients) {
            if (tries < 10) {
              WidgetsBinding.instance.addPostFrameCallback((_) => jumpWhenReady(tries + 1));
            } else if (_pendingJumpTarget == target) {
              _pendingJumpTarget = null; // 끝내 못 옮겼다 — 표시를 남기면 이후 넘기기가 전부 무시된다
            }
            return;
          }
          _pageController.jumpToPage(target);
          _scrollToThumbnail(target);
          setState(() => _currentIndex = target);
          _pendingJumpTarget = null; // 이동 완료 — 이후 스와이프는 정상 처리
        }

        WidgetsBinding.instance.addPostFrameCallback((_) => jumpWhenReady());
      }
    }

    if (changed) {
      setState(() {});
    }
  }

  /// 목록 화면(큰 이미지·썸네일 줄)이 [target] 번 이미지에서 시작하게 컨트롤러를 새로 만든다.
  ///  ⚠️ 목록 화면이 화면에 없을 때만 부른다 (그리드·갤러리에서 돌아올 때) —
  ///     옛 컨트롤러가 어디에도 붙어 있지 않아 바로 버려도 된다.
  void _startListAt(int target) {
    _currentIndex = target;
    _pendingJumpTarget = null; // 새 컨트롤러가 이 자리에서 시작한다 — 옮기는 중인 것은 없다
    _pageController.dispose();
    _pageController = PageController(initialPage: target);
    final double offset = _thumbCenterOffset(target, _appState.historyImages.length) ?? 0;
    _thumbnailScrollController.dispose();
    _thumbnailScrollController = _newThumbController(offset);
    _appState.historyThumbnailScrollOffset = offset;
  }

  /// 갤러리에서 '히스토리 목록에 추가' 한 뒤 — 갤러리를 닫고 목록 모드로, 방금 넣은 이미지를 보여 준다.
  ///  (추가하면 AppState 가 그 이미지를 이미 선택해 둔다)
  void _showAddedInList() {
    if (!mounted) {
      return;
    }
    final state = _appState;
    final images = state.historyImages;
    if (images.isEmpty) {
      return;
    }
    setState(() {
      _leaveGallery(); // 방금 넣은 그림(AppState 가 이미 골라 둠)에서 시작
      _isSelectMode = false;
      _selected.clear();
      // 그리드→목록(④)이 한 번 더 움직이지 않게
      _wasGridView = false;
    });
    state.isHistoryGridView = false;
    state.refreshUI();
  }

  /// 갤러리를 닫는다 — 목록 화면이 고른 그림(갤러리에서 넣은 그림 포함)에서 다시 시작하게. setState 안에서 부른다.
  ///  갤러리를 보는 동안 목록 화면은 없었다 → 컨트롤러를 그 자리로 새로 만든다 (_startListAt).
  ///  ⚠️ 예전엔 '히스토리' 버튼으로 닫으면 표시만 바꿔, 갤러리에서 넣은 그림 · 옮기던 표시가 목록에 반영되지 않았다.
  void _leaveGallery() {
    _isGalleryMode = false;
    _appState.setHistoryLastWasGallery(false);
    final images = _appState.historyImages;
    if (images.isEmpty) {
      return;
    }
    final int sel = _appState.selectedHistoryIndex;
    _startListAt((sel >= 0 ? sel : _currentIndex).clamp(0, images.length - 1));
    // 새 이미지 감지(⑤)가 한 번 더 움직이지 않게 기준을 맞춘다
    _prevImageCount = images.length;
    _prevLastEntry = _appState.history.last;
  }

  // ── 썸네일 줄 ─────────────────────────────────────────────────
  //  최근 [_kThumbCount] 장만 보여 준다. 칸 하나 = 그림 [_kThumbSize] + 간격 [_kThumbGap].
  //  ⚠️ 예전엔 이 숫자들(30, 64, 8)과 '가운데 맞춤' 계산이 세 곳에 따로 적혀 있었다.
  static const int _kThumbCount = 30;
  static const double _kThumbSize = 64.0;
  static const double _kThumbGap = 8.0;
  static const double _kThumbExtent = _kThumbSize + _kThumbGap;

  /// 썸네일 줄의 첫 칸이 전체 히스토리에서 몇 번째인지
  int _thumbStart(int total) => total > _kThumbCount ? total - _kThumbCount : 0;

  /// [index] 번 이미지 썸네일이 화면 가운데 오는 스크롤 위치 (0 이상). 줄에 없으면 null.
  double? _thumbCenterOffset(int index, int total) {
    final int i = index - _thumbStart(total);
    if (i < 0) {
      return null;
    }
    final double screenWidth = MediaQuery.of(context).size.width - 32;
    final double pos = (i * _kThumbExtent) - (screenWidth / 2) + (_kThumbExtent / 2);
    return pos < 0 ? 0 : pos;
  }

  /// 썸네일 줄 스크롤 컨트롤러 — 스크롤할 때마다 위치를 AppState 에 기억한다.
  ///  ⚠️ 새로 만들 때는 반드시 이 함수로. 예전엔 그리드→목록 전환에서 리스너 없이
  ///     새로 만들어, 그 뒤로 썸네일 위치가 저장되지 않았다.
  ScrollController _newThumbController(double offset) {
    final c = ScrollController(initialScrollOffset: offset);
    c.addListener(() => _appState.historyThumbnailScrollOffset = c.offset);
    return c;
  }

  void _scrollToThumbnail(int index, {bool animate = true}) {
    if (_thumbnailScrollController.hasClients) {
      // 범위 밖(최근 줄에 없는 이미지)이면 스크롤하지 않음
      double? targetPos = _thumbCenterOffset(index, _appState.historyImages.length);
      if (targetPos == null) {
        return;
      }
      if (targetPos > _thumbnailScrollController.position.maxScrollExtent) {
        targetPos = _thumbnailScrollController.position.maxScrollExtent;
      }

      if (!animate) {
        _thumbnailScrollController.jumpTo(targetPos); // 앱 시작 직후엔 즉시 위치
        return;
      }

      _thumbnailScrollController.animateTo(
        targetPos,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // 디코드 크기 계산 — 화면에 보이는 크기만큼만 메모리에 올린다.
  //  Image.memory는 기본적으로 원본 해상도로 디코드하는데,
  //  832×1216 한 장이 RGBA로 약 4MB라 썸네일 수십 장이면 수백 MB가 된다.
  int _gridThumbCacheWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    final logical = (mq.size.width - 24) / 4; // 4열 그리드 한 칸 폭
    return (logical * mq.devicePixelRatio).round().clamp(120, 720);
  }

  int _stripThumbCacheWidth(BuildContext context) {
    // 썸네일 줄 높이 64 기준
    final ratio = MediaQuery.of(context).devicePixelRatio;
    return (64 * ratio).round().clamp(96, 320);
  }

  NaiMetadata? _getMetadataForIndex(int index) {
    final metadata = _appState.historyMetadata;
    if (index < 0 || index >= metadata.length) {
      return null;
    }
    return metadata[index];
  }

  String _getPromptText(NaiMetadata? metadata) {
    if (metadata == null) {
      return "이 이미지에는 저장된 프롬프트 데이터가 없습니다.\n\n(메신저 전송, 이미지 편집 등을 거치면서\n파일 내부의 메타데이터가 삭제된 이미지입니다.)";
    }

    if (_infoTab == _InfoTab.positive) {
      return metadata.positive.isEmpty ? "긍정적 프롬프트가 없습니다." : metadata.positive;
    } else if (_infoTab == _InfoTab.character) {
      if (metadata.characterPrompts.isEmpty) {
        return "캐릭터 프롬프트가 없습니다.";
      }
      List<String> lines = [];
      for (int i = 0; i < metadata.characterPrompts.length; i++) {
        String pos = metadata.characterPrompts[i];
        String neg = "";
        if (i < metadata.characterUndesiredContents.length) {
          neg = metadata.characterUndesiredContents[i];
        }
        lines.add("C${i + 1}.\nPositive : $pos\nNegative : $neg");
      }
      return lines.join('\n\n\n');
    } else if (_infoTab == _InfoTab.negative) {
      return metadata.negative.isEmpty ? "부정적 프롬프트가 없습니다." : metadata.negative;
    }
    return metadata.settingsText(); // _InfoTab.settings
  }

  Widget _buildTabButton(_InfoTab tab) {
    final bool isActive = _infoTab == tab;
    final Color color = tab.color;
    // 아래 선은 '지금 고른 탭' 색으로 이어진다 (고른 탭 밑만 비어 칸과 이어져 보인다)
    final Color activeBoxColor = _infoTab.color;

    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _infoTab = tab;
          });
        },
        // borderRadius는 네 변 색이 다른 Border와 함께 쓸 수 없음(렌더링 예외 발생)
        // → 둥근 모서리는 ClipRRect로 처리하고 decoration에서는 radius 제거
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: isActive ? color.withValues(alpha: 0.15) : Colors.transparent,
              border: Border(
                top: BorderSide(color: isActive ? color : color.withValues(alpha: 0.6), width: 2),
                left: BorderSide(color: isActive ? color : color.withValues(alpha: 0.3), width: 2),
                right: BorderSide(color: isActive ? color : color.withValues(alpha: 0.3), width: 2),
                bottom: BorderSide(color: isActive ? Colors.transparent : activeBoxColor, width: 2),
              ),
            ),
            child: Center(
              child: Text(
                tab.label,
                style: TextStyle(
                  color: isActive ? color : Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _goToPrev() async {
    if (_isAnimating || _currentIndex <= 0) {
      return;
    }
    _isAnimating = true;
    await _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    _isAnimating = false;
  }

  void _goToNext(int total) async {
    if (_isAnimating || _currentIndex >= total - 1) {
      return;
    }
    _isAnimating = true;
    await _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    _isAnimating = false;
  }

  // 그리드 → 리스트 전환하며 해당 이미지로 이동
  void _switchToListAtIndex(AppState state, int index) {
    // 칸을 잡아 둔다 — 다음 프레임 전에 새 그림이 들어와 상한 정리로 번호가 밀려도 누른 그림으로 간다 (DEVNOTES 5)
    final HistoryEntry? entry = index >= 0 && index < state.history.length ? state.history[index] : null;
    setState(() {
      _currentIndex = index;
      state.isHistoryGridView = false;
    });
    state.selectedHistoryIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final int now = entry == null ? index : state.history.indexOf(entry);
      if (now < 0) {
        return; // 그 사이 지워졌다
      }
      if (_pageController.hasClients) {
        _pageController.jumpToPage(now);
      }
      _scrollToThumbnail(now);
      // 번호가 밀렸으면 '지금 보는 번호' 도 맞춘다 (위 setState 때 적은 건 옛 번호)
      if (_currentIndex != now || state.selectedHistoryIndex != now) {
        setState(() => _currentIndex = now);
        state.selectedHistoryIndex = now;
      }
    });
  }

  Future<void> _showDeleteDialog(BuildContext context, AppState state, int index) async {
    if (index < 0 || index >= state.history.length) {
      return;
    }
    // 번호가 아니라 칸을 잡아 둔다 — 확인 창이 떠 있는 사이 생성이 끝나 상한 정리가 일어나면 번호가 밀린다
    //  (예전엔 그때 옆 칸 — 즐겨찾기여도 — 이 지워졌다. DEVNOTES 5)
    final HistoryEntry entry = state.history[index];
    final ok = await showConfirmDialog(
      context,
      title: "히스토리 삭제",
      message: "이 이미지를 히스토리 목록에서 삭제하시겠습니까?\n(기기에 저장된 실제 파일은 삭제되지 않습니다.)",
      confirmLabel: "삭제",
      icon: Icons.delete_outline,
    );
    if (!ok) {
      return;
    }
    final int i = state.history.indexOf(entry); // 지금 번호 (그 사이 지워졌으면 -1)
    if (i >= 0) {
      state.deleteHistoryImage(i);
    }
  }

  // ============================================================================
  // 재생성 다이얼로그 (썸네일 + 파일 없을 때)
  // ============================================================================
  void _showRegenerateDialog(BuildContext context, AppState state, int index) {
    // 번호가 아니라 '칸' 을 잡아 둔다 — 창이 떠 있는 사이 생성이 끝나 상한(300장) 정리가 일어나면
    //  번호가 하나씩 밀려, 누를 때의 번호로는 엉뚱한 칸을 다시 생성하거나 지운다.
    final HistoryEntry entry = state.history[index];
    // 누르는 순간의 번호 (칸이 이미 지워졌으면 -1)
    int currentIndex() => state.history.indexOf(entry);
    // 원본 모델 — 그림 정보에 있으면 그대로 쓰고, 없으면 사용자가 고른다.
    //  ⚠️ 예전엔 모르면 말없이 지금 고른 모델로 생성해, V4.5 그림이 V5 로 다시 만들어졌다.
    final String? sourceModel = state.historySourceModel(index);
    // 모델 이름은 있는데 알아보지 못한 경우 그 이름을 보여 준다 (아주 옛 모델 등)
    final String rawSource = entry.metadata?.source ?? '';
    String chosenModel = sourceModel ?? state.selectedModel;
    bool newSeed = false; // '새 시드로' — 같은 설정의 다른 그림 (꺼 두면 원본 시드 그대로)
    // 'NAI Diffusion V4.5 Full' → 'V4.5 Full' (칩에 들어가게)
    String shortName(String id) =>
        modelCapsFor(id).displayName.replaceFirst(RegExp(r'^(NAI Diffusion|NovelAI)\s+'), '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // 가로 화면 · 큰 글씨에서도 넘치지 않게 (내용에 세로 Expanded 없음 — 새 시드 줄의 Expanded 는 가로)
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.refresh, color: AppColors.accent),
            SizedBox(width: 8),
            Text(
              "해당 이미지를 새로 생성",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        // 보통 생성처럼 프롬프트탭으로 넘어가 생성하고, 새 그림은 히스토리 끝에 새 칸으로 들어간다 (이 칸은 그대로)
        //  모델 칩만 다시 그리면 되므로 StatefulBuilder 는 내용에만 — '새로 생성' 버튼은 누를 때 chosenModel 을 읽는다
        content: StatefulBuilder(
          builder: (_, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "메타데이터로 이미지를 새로 생성합니다.\n(Anlas가 소모될 수 있습니다.)",
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 14),
              if (sourceModel != null)
                Text(
                  "모델: ${modelCapsFor(sourceModel).displayName} (원본 그대로)",
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                )
              else ...[
                Text(
                  rawSource.isEmpty
                      ? "원본 모델 정보가 없어요. 어떤 모델로 만들까요?"
                      : "원본 모델($rawSource)을 알아보지 못했어요. 어떤 모델로 만들까요?",
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final id in kSelectableModels)
                      ChoiceChip(
                        label: Text(shortName(id)),
                        selected: chosenModel == id,
                        onSelected: (_) => setDialogState(() => chosenModel = id),
                        showCheckmark: false,
                        labelStyle: TextStyle(
                          color: chosenModel == id ? Colors.white : Colors.white60,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        backgroundColor: AppColors.surface,
                        selectedColor: AppColors.accent.withValues(alpha: 0.35),
                        side: BorderSide(
                          color: chosenModel == id ? AppColors.accent : Colors.white24,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              // 시드 — 원본 그대로(같은 그림을 다시) / 새로(같은 설정의 다른 그림)
              InkWell(
                onTap: () => setDialogState(() => newSeed = !newSeed),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "새 시드로",
                              style: TextStyle(color: Colors.white, fontSize: 14),
                            ),
                            // 켜고 끌 때 글을 바꾸지 않는다 — 창 폭이 글 길이를 따라가(IntrinsicWidth) 누를 때마다 출렁인다
                            const Text(
                              "끄면 원본 시드 그대로 · 켜면 다른 그림",
                              style: TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: newSeed,
                        onChanged: (v) => setDialogState(() => newSeed = v),
                        activeThumbColor: AppColors.accent,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("취소", style: TextStyle(color: Colors.grey)),
          ),
          // 삭제도 할 수 있게
          OutlinedButton(
            onPressed: () {
              Navigator.pop(ctx);
              final int i = currentIndex();
              if (i >= 0) {
                state.deleteHistoryImage(i);
              }
            },
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent)),
            child: const Text("삭제", style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              final int i = currentIndex();
              if (i >= 0) {
                state.regenerateFromMetadata(context, i, model: chosenModel, newSeed: newSeed);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text(
              "새로 생성",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================================
  // 일괄 삭제 바텀시트
  // ============================================================================
  void _showBulkDeleteSheet(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (modalContext) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(modalContext).padding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "히스토리 삭제",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
                title: const Text("전부 삭제", style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  "히스토리의 모든 이미지를 삭제합니다. (실제 파일은 유지)",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () async {
                  Navigator.pop(modalContext);
                  final ok = await showConfirmDialog(
                    context,
                    title: "정말 삭제하시겠습니까?",
                    message: "히스토리의 모든 이미지가 삭제됩니다.\n이 작업은 되돌릴 수 없습니다.",
                    confirmLabel: "전부 삭제",
                    icon: Icons.warning_amber_rounded,
                    iconColor: AppColors.amber,
                  );
                  if (ok) {
                    state.deleteAllHistory();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.star_border, color: AppColors.amber),
                title: const Text("즐겨찾기 제외 삭제", style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  "즐겨찾기 이미지만 남기고 나머지를 삭제합니다. (실제 파일은 유지)",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(modalContext);
                  state.deleteNonFavoriteHistory();
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  // ============================================================================
  // 그리드 뷰
  // ============================================================================
  // 갤러리 정렬 버튼 (현재: 이름순 오름/내림 토글. 추후 정렬 종류 추가 예정)
  Widget _buildSortButton(AppState state) {
    final bool asc = state.gallerySortMode != 'name_desc';
    return GestureDetector(
      onTap: () {
        setState(() {
          state.gallerySortMode = asc ? 'name_desc' : 'name_asc';
        });
        state.saveAllSettings();
        _galleryKey.currentState?.applySort();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("이름순", style: TextStyle(color: Colors.white, fontSize: 13)),
            Icon(
              asc ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              size: 20,
              color: const Color(0xFF5DCAA5),
            ),
          ],
        ),
      ),
    );
  }

  // 갤러리 열 개수 조정 (1~8)
  Widget _buildColumnAdjust(AppState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () {
              if (state.galleryColumns > 1) {
                setState(() => state.galleryColumns--);
                state.saveAllSettings();
              }
            },
            child: const Icon(Icons.remove, size: 18, color: Colors.white70),
          ),
          const SizedBox(width: 14),
          GestureDetector(
            onTap: () {
              if (state.galleryColumns < 8) {
                setState(() => state.galleryColumns++);
                state.saveAllSettings();
              }
            },
            child: const Icon(Icons.add, size: 18, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  // 그리드 (슬리버 — 보이는 칸만 만든다. 위 build 의 CustomScrollView 설명)
  Widget _buildGridSliver(AppState state, List images, List<int> displayIndices) {
    if (images.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 80),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.image_not_supported_outlined, size: 48, color: Colors.white24),
                SizedBox(height: 16),
                Text("저장된 히스토리 이미지가 없습니다.", style: TextStyle(color: Colors.white30)),
              ],
            ),
          ),
        ),
      );
    }

    // [displayIndices] — 즐겨찾기 · 검색으로 거른 실제 번호 (최신 먼저, _visibleIndices)
    if (displayIndices.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 80),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isSearching ? Icons.search_off : Icons.star_border,
                  size: 48,
                  color: Colors.white24,
                ),
                const SizedBox(height: 16),
                Text(
                  _isSearching
                      ? (_showFavoritesOnly ? "즐겨찾기 중에 검색에 맞는 이미지가 없습니다." : "검색에 맞는 이미지가 없습니다.")
                      : "즐겨찾기한 이미지가 없습니다.",
                  style: const TextStyle(color: Colors.white30),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      // 칸 하나 — 화면에 들어올 때 만든다
      delegate: SliverChildBuilderDelegate((context, index) {
        final realIndex = displayIndices[index];
        // 칸은 화면에 들어올 때 만든다 — 그린 뒤 목록이 줄었을 수 있다 (다음 그리기에서 맞춰진다)
        if (realIndex >= state.history.length) {
          return const SizedBox.shrink();
        }
        // 고르기 · 별 · 열기는 칸(객체)으로 — 번호는 새 그림이 들어오며 밀릴 수 있다 (위 _selected)
        final HistoryEntry entry = state.history[realIndex];
        final isFav = realIndex < state.historyFavorites.length
            ? state.historyFavorites[realIndex]
            : false;
        final bool isThumbnail = state.isHistoryThumbnail(realIndex);
        final bool fileExists = state.checkFileExistsSync(realIndex);

        return GestureDetector(
          onTap: () {
            if (_isSelectMode) {
              // 선택 모드: 체크 토글
              setState(() {
                if (_selected.contains(entry)) {
                  _selected.remove(entry);
                  if (_selected.isEmpty) {
                    _isSelectMode = false;
                  }
                } else {
                  _selected.add(entry);
                }
              });
            } else {
              _hideKeyboard(); // 검색하다 누른 경우 — 큰 그림이 키보드에 가리지 않게
              // 누르는 순간의 번호로 (그린 뒤 새 그림이 들어와 번호가 밀렸을 수 있다)
              final int i = state.history.indexOf(entry);
              if (i >= 0) {
                _switchToListAtIndex(state, i);
              }
            }
          },
          onLongPress: () {
            if (!_isSelectMode) {
              // 선택 모드 진입
              setState(() {
                _isSelectMode = true;
                _selected.clear();
                _selected.add(entry);
              });
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _isSelectMode && _selected.contains(entry)
                          ? Colors.redAccent
                          : isFav
                          ? AppColors.amber.withValues(alpha: 0.5)
                          : AppColors.accent.withValues(alpha: 0.2),
                      width: _isSelectMode && _selected.contains(entry)
                          ? 2.5
                          : (isFav ? 1.5 : 1),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    // 원본(약 832×1216)을 그대로 디코드하면 한 장에 4MB가 든다.
                    // 4열 그리드는 화면폭/4 크기로만 보이므로 그만큼만 디코드한다.
                    child: Image.memory(
                      images[realIndex],
                      fit: BoxFit.cover,
                      cacheWidth: _gridThumbCacheWidth(context),
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
              // ✅ 선택 모드: 체크마크 (왼쪽 위)
              if (_isSelectMode)
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: _selected.contains(entry)
                          ? Colors.redAccent
                          : Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _selected.contains(entry)
                            ? Colors.redAccent
                            : Colors.white38,
                        width: 1.5,
                      ),
                    ),
                    child: _selected.contains(entry)
                        ? const Icon(Icons.check, color: Colors.white, size: 16)
                        : null,
                  ),
                ),
              // ⭐ 별 아이콘 (오른쪽 위) — 선택 모드가 아닐 때만
              if (!_isSelectMode)
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => state.toggleHistoryFavorite(entry), // 칸으로 — 번호는 밀릴 수 있다
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        color: isFav ? AppColors.amber : Colors.white54,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              // 📁 파일 존재 여부 표시 (왼쪽 아래)
              if (isThumbnail && !_isSelectMode)
                Positioned(
                  bottom: 4,
                  left: 4,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      fileExists ? Icons.save_alt : Icons.cloud_off,
                      color: fileExists ? Colors.tealAccent : Colors.white38,
                      size: 14,
                    ),
                  ),
                ),
            ],
          ),
        );
      }, childCount: displayIndices.length),
    );
  }

  // ============================================================================
  // 리스트 뷰 (기존 UI)
  // ============================================================================
  Widget _buildListView(
    AppState state,
    List images,
    bool isEmpty,
    int displayIndex,
    NaiMetadata? currentMetadata,
    Color currentActiveColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 큰 이미지 넘기기 (좌우 스와이프·이전/다음·겹쳐 보이는 버튼들)
        _buildImagePager(state, images, isEmpty, displayIndex),
        const SizedBox(height: 12),
        // 썸네일 줄 (최근 _kThumbCount 장)
        if (!isEmpty) ..._buildThumbStrip(state, images, displayIndex),
        // 불러오기 두 갈래 — 히스토리에 추가 / 프롬프트만 가져오기
        _buildLoadActions(state, images, isEmpty, displayIndex),
        const SizedBox(height: 16),

        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: !_isPromptOpen
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [for (final t in _InfoTab.values) _buildTabButton(t)]),
                    Container(
                      height: 250,
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        border: Border(
                          left: BorderSide(color: currentActiveColor, width: 2),
                          right: BorderSide(color: currentActiveColor, width: 2),
                          bottom: BorderSide(color: currentActiveColor, width: 2),
                        ),
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _getPromptText(currentMetadata),
                          style: const TextStyle(color: Colors.white, height: 1.6, fontSize: 14),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  // 큰 이미지 넘기기 (좌우 스와이프·이전/다음·겹쳐 보이는 버튼들)
  Widget _buildImagePager(AppState state, List images, bool isEmpty, int displayIndex) {
    return Container(
      height: 480,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
      ),
      child: isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.image_not_supported_outlined, size: 48, color: Colors.white24),
                  SizedBox(height: 16),
                  Text("저장된 히스토리 이미지가 없습니다.", style: TextStyle(color: Colors.white30)),
                ],
              ),
            )
          : Stack(
              alignment: Alignment.center,
              children: [
                PageView.builder(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (idx) {
                    // 새 이미지 추가로 강제 이동 중일 때는 PageView가 내부적으로
                    // 발생시키는 onPageChanged가 목표 위치를 덮어쓰지 않게 무시한다.
                    if (_pendingJumpTarget != null && idx != _pendingJumpTarget) {
                      return;
                    }
                    _pendingJumpTarget = null;
                    setState(() {
                      _currentIndex = idx;
                    });
                    context.read<AppState>().selectedHistoryIndex = idx;
                    _scrollToThumbnail(idx);
                  },
                  itemCount: images.length,
                  itemBuilder: (context, index) {
                    final bool isThumbnail = state.isHistoryThumbnail(index);
                    final bool fileExists = state.checkFileExistsSync(index);
                    return Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: GestureDetector(
                        onLongPress: () {
                          // 원본이 없고 다시 만들 정보만 있을 때만 '새로 생성' (밖에서 가져온 그림은 보통 메뉴)
                          if (state.historyNeedsRegenerate(index)) {
                            _showRegenerateDialog(context, state, index);
                          } else {
                            final String? filePath = index < state.historyFilePaths.length
                                ? state.historyFilePaths[index]
                                : null;
                            showSaveImageModal(
                              context,
                              state,
                              images[index],
                              savedFilePath: filePath,
                              // 이 칸의 그림 정보로 (썸네일 칸도 프롬프트 불러오기 · 다시 뽑기가 된다)
                              historyEntry: index < state.history.length ? state.history[index] : null,
                            );
                          }
                        },
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(images[index], fit: BoxFit.contain),
                              ),
                            ),
                            // 썸네일 표시 (리스트 모드)
                            if (isThumbnail)
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        fileExists ? Icons.save_alt : Icons.cloud_off,
                                        color: fileExists ? Colors.tealAccent : Colors.white38,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        fileExists ? "저장됨" : "썸네일",
                                        style: TextStyle(
                                          color: fileExists ? Colors.tealAccent : Colors.white38,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                if (displayIndex > 0 && _appState.historySlideEnabled)
                  Positioned(
                    left: 8,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.6),
                        border: Border.all(color: AppColors.accent, width: 1.5),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.arrow_back_ios_new, color: AppColors.accent, size: 24),
                        onPressed: _goToPrev,
                      ),
                    ),
                  ),

                if (displayIndex < images.length - 1 && _appState.historySlideEnabled)
                  Positioned(
                    right: 8,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.6),
                        border: Border.all(color: AppColors.accent, width: 1.5),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.arrow_forward_ios, color: AppColors.accent, size: 24),
                        onPressed: () => _goToNext(images.length),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  // 썸네일 줄 (최근 _kThumbCount 장)
  List<Widget> _buildThumbStrip(AppState state, List images, int displayIndex) {
    return [
      SizedBox(
        height: _kThumbSize,
        child: Builder(
          builder: (context) {
            // 최신 _kThumbCount 개만 표시
            final int thumbStart = _thumbStart(images.length);
            final int thumbCount = images.length - thumbStart;

            return ListView.builder(
              controller: _thumbnailScrollController,
              scrollDirection: Axis.horizontal,
              itemCount: thumbCount,
              itemBuilder: (context, index) {
                final int realIndex = thumbStart + index;
                bool isSelected = displayIndex == realIndex;
                return GestureDetector(
                  onTap: () {
                    if (_appState.historySlideEnabled) {
                      _pageController.animateToPage(
                        realIndex,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                      );
                    } else {
                      _pageController.jumpToPage(realIndex);
                    }
                  },
                  onLongPress: () {
                    if (state.historyNeedsRegenerate(realIndex)) {
                      _showRegenerateDialog(context, state, realIndex);
                    } else {
                      _showDeleteDialog(context, state, realIndex);
                    }
                  },
                  child: Container(
                    width: _kThumbSize,
                    margin: const EdgeInsets.only(right: _kThumbGap),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected ? AppColors.purple : Colors.white12,
                        width: isSelected ? 3.5 : 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: AppColors.purple.withValues(alpha: 0.6),
                                blurRadius: 8,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: ColorFiltered(
                        colorFilter: isSelected
                            ? const ColorFilter.mode(Colors.transparent, BlendMode.multiply)
                            : ColorFilter.mode(
                                Colors.black.withValues(alpha: 0.35),
                                BlendMode.darken,
                              ),
                        // 64px 높이로만 보이므로 작게 디코드 (원본 한 장이 약 4MB)
                        child: Image.memory(
                          images[realIndex],
                          fit: BoxFit.cover,
                          cacheWidth: _stripThumbCacheWidth(context),
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      const SizedBox(height: 12),
    ];
  }

  // 불러오기 두 갈래 — 히스토리에 추가 / 프롬프트만 가져오기
  Widget _buildLoadActions(AppState state, List images, bool isEmpty, int displayIndex) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: isEmpty
                ? null
                : () {
                    setState(() {
                      _isPromptOpen = !_isPromptOpen;
                    });
                  },
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                color: isEmpty ? Colors.grey.withValues(alpha: 0.3) : AppColors.accent,
                width: 1.5,
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "프롬프트 확인",
                  style: TextStyle(
                    color: isEmpty ? Colors.grey : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _isPromptOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: isEmpty ? Colors.grey : Colors.white,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        Text(
          isEmpty ? "0 / 0" : "${images.length - displayIndex} / ${images.length}",
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
        // 불러오기 두 갈래: 히스토리에 추가 / 프롬프트만 가져오기
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: () => _importPromptOnly(context, state),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.teal, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    "프롬프트",
                    maxLines: 1,
                    style: TextStyle(
                      color: AppColors.teal,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton(
                onPressed: () => state.importImageToHistory(context),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.purple, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    "히스토리",
                    maxLines: 1,
                    style: TextStyle(
                      color: AppColors.purple,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ============================================================================
  // build
  // ============================================================================
  // 이미지를 골라 '프롬프트만' 불러온다 (히스토리에 추가하지 않음).
  // 갤러리 꾹 메뉴의 '프롬프트 불러오기'와 같은 다이얼로그를 띄운다.
  Future<void> _importPromptOnly(BuildContext context, AppState state) async {
    try {
      final bytes = await pickGalleryImageBytes();
      if (bytes == null || !context.mounted) {
        return;
      }
      final meta = await readNovelAIMetadata(bytes); // 알파 채널까지 (사이트를 거친 그림)
      if (!context.mounted) {
        return;
      }
      if (meta == null) {
        showToast(context, "이 이미지에서 프롬프트 정보를 찾지 못했습니다.");
        return;
      }
      showLoadPromptDialog(context, state, meta);
    } catch (e) {
      debugPrint("프롬프트 불러오기 오류: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive 필수 호출
    final state = context.watch<AppState>();
    final images = state.historyImages;
    final bool isEmpty = images.isEmpty;
    final bool isGridView = state.isHistoryGridView;

    // 히스토리 로딩 중이면 로딩 표시
    if (state.isHistoryLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppColors.accent),
            SizedBox(height: 16),
            Text("히스토리 로딩 중...", style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    // 갤러리 모드: 폴더 탐색 뷰
    if (_isGalleryMode) {
      return Column(
        children: [
          // 상단 바: 히스토리로 돌아가기 + 폴더 선택 버튼
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // 왼쪽 묶음 — 폭이 모자라면 통째로 조금 줄인다 (줄이 넘치지 않게 · 오른쪽 🔍 [- +] 는 그대로)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _pill(
                            icon: Icons.arrow_back,
                            label: "히스토리",
                            color: AppColors.accent,
                            onTap: () => setState(_leaveGallery),
                          ),
                          const SizedBox(width: 8),
                          // 폴더 변경 버튼 (작게: 바로 아래 경로가 보이므로 "변경"만)
                          _pill(
                            icon: Icons.folder_open,
                            label: "변경",
                            iconSize: 16,
                            iconColor: AppColors.amber,
                            onTap: () => _galleryKey.currentState?.openLocationPicker(),
                          ),
                          const SizedBox(width: 8),
                          // 정렬 버튼 (이름순 오름/내림 토글)
                          _buildSortButton(state),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 검색 — 지금 폴더와 그 아래 폴더 전부에서 (열고 닫기는 GalleryView 가, 색은 _gallerySearchOpen 으로)
                ValueListenableBuilder<bool>(
                  valueListenable: _gallerySearchOpen,
                  builder: (_, open, _) => _pill(
                    icon: Icons.search,
                    color: open ? AppColors.accent : null,
                    fill: 0.2,
                    onTap: () => _galleryKey.currentState?.toggleSearch(),
                  ),
                ),
                const SizedBox(width: 8),
                // 열 개수 조정
                _buildColumnAdjust(state),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          // 갤러리 본문
          Expanded(
            child: GalleryView(
              key: _galleryKey,
              state: state,
              onAddedToHistory: _showAddedInList,
              searchOpen: _gallerySearchOpen,
            ),
          ),
        ],
      );
    }

    // (맨 아래로·썸네일 끝으로·그리드→목록·새 이미지 같은 '사건'은 _onAppStateChanged 가 처리한다)

    int displayIndex = isEmpty
        ? 0
        : (_currentIndex >= images.length ? images.length - 1 : _currentIndex);
    NaiMetadata? currentMetadata = isEmpty ? null : _getMetadataForIndex(displayIndex);

    final Color currentActiveColor = _infoTab.color;

    // 그리드에 보일 칸 (즐겨찾기 · 검색). 거르는 중이면 도구 줄에 '보이는 수/전체' 를 쓴다
    final List<int>? visible = isGridView ? _visibleIndices(state) : null;
    final bool filtering = isGridView && !isEmpty && (_showFavoritesOnly || _isSearching);

    // ⚠️ 그리드는 SliverGrid 로 — 화면에 보이는 칸(과 그 언저리)만 만들고 그림을 푼다.
    //    예전엔 SingleChildScrollView 안의 shrinkWrap GridView 라 칸을 '전부' 한꺼번에 만들어 그림을 다 풀어 두었다
    //    (300장이면 풀린 그림만 100MB 남짓 · 앱 상태가 바뀔 때마다 300칸을 다시 만듦).
    //    목록 모드는 예전과 같은 한 덩어리 (SliverToBoxAdapter — 폭이 꽉 차는 것도 예전 stretch 와 같다).
    return CustomScrollView(
      controller: _listScrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 리스트/그리드 도구 줄 (고정 높이로 모드 전환 시 버튼 움직임 방지)
                _buildToolbar(
                  context,
                  state,
                  images.length,
                  isGridView,
                  shown: filtering ? visible!.length : null,
                ),
                const SizedBox(height: 12),
                // 검색칸 — 그리드에서는 돋보기로 열었을 때, 목록에서는 검색 중일 때만 (히스토리가 비었으면 숨긴다)
                if (!isEmpty && (_isSearching || (_searchOpen && isGridView))) _buildSearchBar(),
              ],
            ),
          ),
        ),
        // 메인 컨텐츠 — 아래 여백 56 = 예전 끝의 SizedBox(40) + 바깥 여백 16
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 56),
          sliver: isGridView
              ? _buildGridSliver(state, images, visible!)
              : SliverToBoxAdapter(
                  child: _buildListView(
                    state,
                    images,
                    isEmpty,
                    displayIndex,
                    currentMetadata,
                    currentActiveColor,
                  ),
                ),
        ),
      ],
    );
  }
}

/// 히스토리 정보 칸의 탭 — 이름·색을 한 곳에서.
///  ⚠️ 예전엔 0~3 숫자로 구분하고 '몇 번이면 무슨 색' 규칙이 세 곳에 따로 있었다.
enum _InfoTab {
  positive("긍정적"),
  character("캐릭터"),
  negative("부정적"),
  settings("세팅");

  const _InfoTab(this.label);

  final String label;

  /// 탭 색. 캐릭터는 강조색을 따라간다 (기본 강조색이 보라다).
  Color get color => switch (this) {
    _InfoTab.positive => AppColors.teal,
    _InfoTab.character => AppColors.accent,
    _InfoTab.negative => AppColors.red,
    _InfoTab.settings => AppColors.amber,
  };
}
