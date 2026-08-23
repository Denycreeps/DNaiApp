import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'models/app_state.dart';
import 'app_theme.dart';
import 'screens/prompt_tab.dart';
import 'screens/history_tab.dart';
import 'screens/i2i_tab.dart';
import 'screens/character_tab.dart';
import 'screens/wildcard_tab.dart';
import 'screens/settings_tab.dart';
import 'widgets/detail_settings_modal.dart';

void main() {
  // ── [디버그] 잡히지 않은 오류를 로그로 남긴다 ──
  //  화면이 튕기거나 흰 화면이 될 때 원인을 확인하기 위한 장치.
  //  문제가 해결되면 지워도 되지만, 남겨두면 앞으로도 도움이 된다.
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    debugPrint('════════ Flutter 오류 ════════');
    debugPrint('${details.exception}');
    debugPrint('${details.stack}');
    debugPrint('══════════════════════════════');
    FlutterError.presentError(details);
  };
  // 위젯 트리 밖(비동기 등)에서 난 오류
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('════════ 처리되지 않은 오류 ════════');
    debugPrint('$error');
    debugPrint('$stack');
    debugPrint('════════════════════════════════════');
    return true; // 앱을 죽이지 않고 계속 진행
  };

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) {
            final appState = AppState();
            // 초기 로딩이 끝나면(성공/실패 무관) 준비 완료 처리 → 로딩 화면 해제
            appState.loadInitialData().whenComplete(appState.markAppReady);
            return appState;
          },
        ),
      ],
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
  bool _updateDialogVisible = false;
  List<int> _visibleTabIndices = [0, 1, 2, 3, 4, 5]; // 현재 화면에 보이는 원본 탭 인덱스들
  DateTime? _lastBackPress; // 두 번 눌러 종료 판정용

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
    // 이미 업데이트 다이얼로그가 떠 있으면 중복 표시 방지
    if (_updateDialogVisible) {
      return;
    }
    _updateDialogVisible = true;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Colors.deepPurpleAccent, size: 24),
            const SizedBox(width: 8),
            Text(
              "v${state.latestVersion} 업데이트",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "v${AppState.currentVersion} → v${state.latestVersion}",
                style: const TextStyle(
                  color: Colors.deepPurpleAccent,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (state.releaseNotePreview.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  "변경 사항",
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121212),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: state.releaseNotePreview
                        .map(
                          (line) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              line,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                height: 1.4,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("닫기", style: TextStyle(color: Colors.grey)),
          ),
          if (state.apkDownloadUrl != null)
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                state.downloadAndInstallUpdate(context);
              },
              icon: const Icon(Icons.download, color: Colors.white, size: 16),
              label: const Text(
                "업데이트",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurpleAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
        ],
      ),
    ).then((_) {
      _updateDialogVisible = false;
    });
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
            child: Image.memory(state.currentImageBytes!, fit: BoxFit.contain),
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

    // 캐릭터/와일드카드 탭은 이미지 미표시
    if (tabIndex == 3 || tabIndex == 4) {
      return SingleChildScrollView(child: Column(children: [content, const SizedBox(height: 80)]));
    }

    return SingleChildScrollView(
      child: Column(
        children: [
          if (tabIndex == 0)
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

    // 초기 로딩 중에는 로딩 화면으로 조작 차단 (프리징/크래시 방지)
    if (!state.isAppReady) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8B5CF6)),
                ),
              ),
              const SizedBox(height: 20),
              // 현재 로딩 단계 표시 (AppState가 단계마다 갱신)
              Text(
                state.loadingStatusMessage,
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    // 업데이트 알림 (앱 실행 후 1회만) — 가드는 AppState 공유 (수동 열기와 중복 방지)
    if (state.hasUpdate && !state.updateDialogShown) {
      state.updateDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _showUpdateDialog(context, state);
      });
    }

    // 활성 탭 리스트 계산 (원본 인덱스 기준)
    // 0=프롬프트, 1=히스토리, 2=i2i, 3=캐릭터, 4=와일드카드, 5=설정
    List<int> newVisibleIndices = [0];
    if (state.historyTabEnabled) {
      newVisibleIndices.add(1);
    }
    if (state.i2iTabEnabled) {
      newVisibleIndices.add(2);
    }
    if (state.characterTabEnabled) {
      newVisibleIndices.add(3);
    }
    if (state.wildcardTabEnabled) {
      newVisibleIndices.add(4);
    }
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
      if (newInitialIndex == -1) {
        newInitialIndex = 0;
      }

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
        if (_tabController!.indexIsChanging) {
          return;
        }
        final origIdx =
            _visibleTabIndices.isNotEmpty && _tabController!.index < _visibleTabIndices.length
            ? _visibleTabIndices[_tabController!.index]
            : -1;
        if (origIdx == 1 && !state.isHistoryGridView) {
          // 컨트롤러를 직접 만지지 않고 요청만 보낸다 (HistoryTab이 처리)
          state.requestHistoryScrollToEnd();
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
        if (!mounted) {
          return;
        }
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        // 1. 히스토리 탭이면 갤러리에게 먼저 위임 (선택 해제 / 상위 폴더 이동)
        if (currentOrigIdx == 1) {
          final handled = state.galleryBackHandler?.call() ?? false;
          if (handled) {
            return;
          }
        }
        // 1-2. i2i 탭이면 릴(핸들) 닫기 위임
        if (currentOrigIdx == 2) {
          final handled = state.i2iBackHandler?.call() ?? false;
          if (handled) {
            return;
          }
        }
        // 2. 두 번 눌러 종료
        final now = DateTime.now();
        final last = _lastBackPress;
        if (last == null || now.difference(last) > const Duration(seconds: 2)) {
          _lastBackPress = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(duration: Duration(seconds: 2), content: Text("한 번 더 누르면 종료됩니다")),
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: 0,
            backgroundColor: const Color(0xFF1E1E1E),
            bottom: TabBar(
              controller: _tabController,
              labelPadding: EdgeInsets.zero,
              indicatorWeight: 3,
              labelColor: AppColors.accent,
              unselectedLabelColor: Colors.grey,
              indicatorColor: AppColors.accent,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5),
              unselectedLabelStyle: const TextStyle(fontSize: 11.5),
              onTap: (targetVisibleTab) {
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
                // 탭 구성(보이는 탭 목록)이 바뀌면 PageView 자체를 새로 만든다.
                // key가 없으면 Flutter가 같은 위젯으로 보고 "옛 탭 개수로 그려둔 페이지"를
                // 그대로 재사용해, 상단 탭 표시와 실제 화면이 어긋나는 문제가 생긴다.
                key: ValueKey('pv_${_visibleTabIndices.join("_")}'),
                controller: _pageController,
                // i2i 탭이거나 좌우 스와이프 비활성화 시 차단
                physics: (currentOrigIdx == 2 || !state.horizontalSwipeEnabled)
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                onPageChanged: (index) {
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
                        PromptTab(onScrollToHistoryEnd: state.requestHistoryScrollToEnd),
                      );
                    case 1:
                      return _buildTabScrollContent(state, 1, const HistoryTab());
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

              // 캐릭터 편집 손잡이: 스크롤 영역 밖(화면 기준)에 두어야
              // 드래그 좌표가 마우스와 정확히 일치하고 창도 화면 기준으로 뜬다
              if (isPromptTab && !isKeyboardOpen) const Positioned.fill(child: CharDrawerHandle()),

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
      ),
    );
  }
}
