import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'models/app_state.dart';
import 'screens/prompt_tab.dart';
import 'screens/history_tab.dart';
import 'screens/i2i_tab.dart';
import 'screens/character_tab.dart';
import 'screens/wildcard_tab.dart';
import 'screens/settings_tab.dart';
import 'widgets/detail_settings_modal.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => AppState()..loadInitialData())],
      child: MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          primarySwatch: Colors.deepPurple,
          scaffoldBackgroundColor: const Color(0xFF121212),
          useMaterial3: true,
          fontFamily: 'Pretendard',
        ),
        home: const NovelAiApp(),
        debugShowCheckedModeBanner: false,
      ),
    ),
  );
}

class NovelAiApp extends StatefulWidget {
  const NovelAiApp({super.key});
  @override
  State<NovelAiApp> createState() => _NovelAiAppState();
}

class _NovelAiAppState extends State<NovelAiApp>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  TabController? _tabController;
  late PageController _pageController;
  final ScrollController _historyScrollController = ScrollController();
  bool _updateDialogShown = false;
  List<int> _visibleTabIndices = [0, 1, 2, 3, 4, 5]; // 현재 화면에 보이는 원본 탭 인덱스들

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(initialPage: 6000);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController?.dispose();
    _pageController.dispose();
    _historyScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      // 앱이 백그라운드/종료될 때 밀린 히스토리 전체 저장 실행
      final appState = context.read<AppState>();
      appState.fullSaveHistoryIfNeeded();
    }
  }

  void _showUpdateDialog(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.system_update, color: Colors.deepPurpleAccent),
            SizedBox(width: 8),
            Text(
              "새 버전이 있어요!",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "v${AppState.currentVersion} → v${state.latestVersion}",
              style: const TextStyle(
                color: Colors.deepPurpleAccent,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (state.updateNotes != null && state.updateNotes!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF121212),
                  borderRadius: BorderRadius.circular(8),
                ),
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(
                    state.updateNotes!,
                    style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("나중에", style: TextStyle(color: Colors.grey)),
          ),
          if (state.updateUrl != null)
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: state.updateUrl!));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text("다운로드 링크가 클립보드에 복사되었습니다!")));
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text("링크 복사", style: TextStyle(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurpleAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImageArea(AppState state) {
    if (state.lastErrorMessage != null) {
      return Center(
        child: Text(
          state.lastErrorMessage!,
          style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
      );
    }
    return state.currentImageBytes != null
        ? GestureDetector(
            onLongPress: () => showSaveImageModal(context, state, state.currentImageBytes!),
            child: InteractiveViewer(
              child: Image.memory(state.currentImageBytes!, fit: BoxFit.contain),
            ),
          )
        : const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.image_not_supported_outlined, size: 48, color: Colors.white24),
                SizedBox(height: 16),
                Text("프롬프트를 입력하고 생성 버튼을 누르세요.", style: TextStyle(color: Colors.white30)),
              ],
            ),
          );
  }

  Widget _buildTabScrollContent(AppState state, int tabIndex, Widget content) {
    if (tabIndex == 1 || tabIndex == 2 || tabIndex == 5) {
      return content;
    }

    bool shouldShowImage = false;
    if (tabIndex == 0) {
      shouldShowImage = true;
    } else {
      shouldShowImage = state.showImageInOtherTabs;
    }

    return SingleChildScrollView(
      child: Column(
        children: [
          if (shouldShowImage)
            Container(
              height: 480,
              width: double.infinity,
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.3)),
              ),
              child: _buildImageArea(state),
            ),
          content,
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // 업데이트 알림 (앱 실행 후 1회만)
    if (state.hasUpdate && !_updateDialogShown) {
      _updateDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showUpdateDialog(context, state);
      });
    }

    // 활성 탭 리스트 계산 (원본 인덱스 기준)
    // 0=프롬프트, 1=히스토리, 2=i2i, 3=캐릭터, 4=와일드카드, 5=설정
    List<int> newVisibleIndices = [0];
    if (state.historyTabEnabled) newVisibleIndices.add(1);
    if (state.i2iTabEnabled) newVisibleIndices.add(2);
    if (state.characterTabEnabled) newVisibleIndices.add(3);
    if (state.wildcardTabEnabled) newVisibleIndices.add(4);
    newVisibleIndices.add(5); // 설정은 항상

    // TabController 재생성 (활성 탭 수가 바뀌었을 때만)
    if (_tabController == null || _tabController!.length != newVisibleIndices.length) {
      // navigateToTab 요청이 있으면 그 탭으로, 아니면 현재 탭 유지
      int targetOrigIdx = 0;
      if (state.requestedTabIndex != null) {
        targetOrigIdx = state.requestedTabIndex!;
      } else if (_tabController != null && _visibleTabIndices.isNotEmpty) {
        final idx = _tabController!.index.clamp(0, _visibleTabIndices.length - 1);
        targetOrigIdx = _visibleTabIndices[idx];
      }

      final int newTabCount = newVisibleIndices.length;
      int newInitialIndex = newVisibleIndices.indexOf(targetOrigIdx);
      if (newInitialIndex == -1) newInitialIndex = 0;

      if (state.requestedTabIndex != null) {
        state.clearNavigation();
      }

      _tabController?.dispose();
      _tabController = TabController(
        length: newTabCount,
        initialIndex: newInitialIndex,
        vsync: this,
      );
      _tabController!.addListener(() {
        if (_tabController!.indexIsChanging) return;
        final origIdx =
            _visibleTabIndices.isNotEmpty && _tabController!.index < _visibleTabIndices.length
            ? _visibleTabIndices[_tabController!.index]
            : -1;
        if (origIdx == 1 && _historyScrollController.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _historyScrollController.animateTo(
              _historyScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          });
        }
        setState(() {});
      });

      // PageController를 올바른 페이지로 재생성 (old는 프레임 후 dispose)
      final oldPageController = _pageController;
      final int targetPage = newTabCount * 1000 + newInitialIndex;
      _pageController = PageController(initialPage: targetPage);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldPageController.dispose();
      });
    }
    _visibleTabIndices = newVisibleIndices;
    final int tabCount = _visibleTabIndices.length;

    // 현재 선택된 원본 탭 인덱스
    final int currentVisibleIdx = _tabController!.index.clamp(0, tabCount - 1);
    final int currentOrigIdx = _visibleTabIndices[currentVisibleIdx];

    bool isPromptTab = currentOrigIdx == 0;
    bool isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    double bottomNavBarHeight = MediaQuery.of(context).padding.bottom;

    if (state.requestedTabIndex != null) {
      int targetOrigTab = state.requestedTabIndex!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        int targetVisibleTab = _visibleTabIndices.indexOf(targetOrigTab);
        if (targetVisibleTab == -1) {
          state.clearNavigation();
          return;
        }
        if (_pageController.hasClients) {
          int currentPage = _pageController.page?.round() ?? 6000;
          int currentTab = currentPage % tabCount;
          int diff = targetVisibleTab - currentTab;
          if (diff > tabCount ~/ 2) {
            diff -= tabCount;
          } else if (diff < -(tabCount ~/ 2)) {
            diff += tabCount;
          }
          _pageController.animateToPage(
            currentPage + diff,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        state.clearNavigation();
      });
    }

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 0,
          backgroundColor: const Color(0xFF1E1E1E),
          bottom: TabBar(
            controller: _tabController,
            labelPadding: EdgeInsets.zero,
            indicatorWeight: 3,
            labelColor: Colors.deepPurpleAccent,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.deepPurpleAccent,
            labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5),
            unselectedLabelStyle: const TextStyle(fontSize: 11.5),
            onTap: (targetVisibleTab) {
              state.setI2iScrollDisabled(false);
              int currentPage = _pageController.page?.round() ?? 6000;
              int currentTab = currentPage % tabCount;
              int diff = targetVisibleTab - currentTab;
              if (diff > tabCount ~/ 2) {
                diff -= tabCount;
              } else if (diff < -(tabCount ~/ 2)) {
                diff += tabCount;
              }
              _pageController.animateToPage(
                currentPage + diff,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            },
            tabs: _visibleTabIndices.map((origIdx) {
              const labels = ["프롬프트", "히스토리", "i2i", "캐릭터", "와일드카드", "설정"];
              return Tab(text: labels[origIdx]);
            }).toList(),
          ),
        ),
        body: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              // i2i 탭에서는 좌우 스크롤 항상 차단
              physics: (currentOrigIdx == 2)
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              onPageChanged: (index) {
                state.setI2iScrollDisabled(false);
                int targetVisibleTab = index % tabCount;
                if (_tabController!.index != targetVisibleTab) {
                  _tabController!.animateTo(targetVisibleTab);
                }
              },
              itemBuilder: (context, index) {
                int visibleIdx = index % tabCount;
                int origIdx = _visibleTabIndices[visibleIdx];
                switch (origIdx) {
                  case 0:
                    return _buildTabScrollContent(
                      state,
                      0,
                      PromptTab(
                        onScrollToHistoryEnd: () {
                          if (_historyScrollController.hasClients) {
                            _historyScrollController.animateTo(
                              _historyScrollController.position.maxScrollExtent,
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut,
                            );
                          }
                        },
                      ),
                    );
                  case 1:
                    return _buildTabScrollContent(
                      state,
                      1,
                      HistoryTab(scrollController: _historyScrollController),
                    );
                  case 2:
                    return _buildTabScrollContent(state, 2, const I2iTab());
                  case 3:
                    return _buildTabScrollContent(state, 3, const CharacterTab());
                  case 4:
                    return _buildTabScrollContent(state, 4, const WildcardTab());
                  case 5:
                    return _buildTabScrollContent(state, 5, const SettingsTab());
                  default:
                    return const SizedBox();
                }
              },
            ),

            if (isPromptTab && !isKeyboardOpen)
              Positioned(
                bottom: 16 + bottomNavBarHeight,
                left: 0,
                right: 0,
                child: Center(
                  child: SizedBox(
                    height: 38,
                    child: ElevatedButton.icon(
                      onPressed: () => showDetailSettingsModal(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2A2A35),
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        elevation: 4,
                      ),
                      icon: const Icon(Icons.tune, color: Colors.deepPurpleAccent, size: 18),
                      label: const Text(
                        "상세 환경",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
