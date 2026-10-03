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
import 'widgets/update_dialog.dart';
import 'models/app_tabs.dart';
import 'utils/qwen_tokenizer.dart';

void main() {
  // ── [디버그] 잡히지 않은 오류를 로그로 남긴다 ──
  //  화면이 튕기거나 흰 화면이 될 때 원인을 확인하기 위한 장치.
  //  문제가 해결되면 지워도 되지만, 남겨두면 앞으로도 도움이 된다.
  WidgetsFlutterBinding.ensureInitialized();
  // V5 토큰 카운터용 Qwen 사전을 미리 읽어 둔다.
  //  await 하지 않는다 — 1MB 파싱 때문에 첫 화면이 늦어질 이유가 없고,
  //  끝나기 전에는 QwenTokenizer가 알아서 근사값을 돌려준다.
  QwenTokenizer.ensureLoaded();
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
          scaffoldBackgroundColor: AppColors.background,
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
  // 키보드 내리기를 탭당 한 번만 하기 위한 표시
  int _lastKeyboardHideTab = -1;
  // 직전에 보고 있던 탭. 히스토리를 '떠났는지' 알아내는 데 쓴다.
  AppTab? _lastTab;

  // 키보드가 떠 있는지. build 에서 갱신해 두고 콜백에서는 이 값만 읽는다.
  //  ⚠️ 콜백 안에서 MediaQuery.of(context) 를 부르면 안 된다.
  //     그 호출은 context 를 InheritedWidget 의 '의존자'로 등록하는데,
  //     콜백이 도는 시점에는 그 화면이 이미 사라지는 중일 수 있다.
  //     그러면 정리되지 않은 의존자가 남아
  //     '_dependents.isEmpty: is not true' 단언에 걸려 앱이 죽는다.
  bool _keyboardOpen = false;
  late PageController _pageController;
  List<AppTab> _visibleTabs = AppTab.values.toList(); // 지금 화면에 보이는 탭들 (순서대로)
  DateTime? _lastBackPress; // 두 번 눌러 종료 판정용

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 첫 build 에서 탭 목록이 정해지면 그 탭 번호로 다시 만든다 (아래 build 참고)
    _pageController = PageController();
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
      // 앱이 백그라운드로 가거나 꺼질 때의 마지막 저장.
      //  (업데이트 설치창이 뜰 때, 다른 앱으로 넘어갈 때, 시스템이 앱을 정리할 때)
      final appState = context.read<AppState>();
      // 밀린 히스토리 전체 저장
      appState.fullSaveHistoryIfNeeded();
      // 설정·프롬프트 사전도 한 번 더 — 둘 다 바꿀 때마다 바로 저장하지만,
      //  그 저장이 끝나기 전에 앱이 넘어갔을 수 있어 안전망으로 둔다.
      //  (사전은 임시 파일에 쓴 뒤 이름만 바꾸고, 설정은 안드로이드가 백업 파일을 두고 쓴다
      //   — 어느 쪽이든 도중에 꺼져도 옛 내용이 남는다)
      appState.saveAllSettings();
      appState.savePromptDict();
    }
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

  // 탭을 눌러(또는 다른 곳의 요청으로) 페이지가 넘어가는 중인지 — 이동마다 번호가 는다.
  //  넘어가는 동안 지나치는 페이지로 위쪽 탭 표시를 바꾸지 않는다 (onPageChanged 참고).
  int _tabJumpId = 0;
  bool _tabJumping = false;

  /// 보이는 탭 [target] 번으로 넘긴다.
  ///  · 바로 옆 탭이면 슬라이드, 더 멀면 중간 탭을 지나가지 않고 바로 바꾼다.
  ///  · 탭은 양 끝에서 멈춘다 (끝없이 돌지 않는다).
  ///  ⚠️ 예전엔 양옆으로 끝없이 도는 페이지(6000번부터)였다. 페이지 '번호'마다 탭 화면이
  ///     따로 만들어지고 버려지지 않아, 멀리 돌아가면 같은 탭 화면이 또 생겼다
  ///     (탭 몇 번 누르면 프롬프트·히스토리 화면이 둘씩 — 새로 만드느라 넘어가다 끊겼고,
  ///     i2i 화면이 둘로 갈리면 그려 둔 마스크가 다른 쪽에선 안 보였다).
  ///     먼 탭으로 슬라이드하면 중간 탭들을 전부 스쳐 그리느라 또 끊겼다.
  ///     이제 탭마다 화면은 하나뿐이고, 멀리 갈 땐 스쳐 그리지 않는다.
  ///  ⚠️ 가는 길에 위쪽 탭 표시를 다른 탭으로 돌려세우지 않는다 — 탭 막대의 색 계산이
  ///     0~1 을 넘어가 '프롬프트' 글자가 무지개색으로 번쩍였다 (onPageChanged 참고).
  Future<void> _animateToVisibleTab(int target, int tabCount) async {
    if (target < 0 || target >= tabCount) {
      return;
    }
    final int current = (_pageController.hasClients ? _pageController.page?.round() : null) ?? target;
    // 위쪽 탭은 바로 목적지로 (탭을 눌렀을 때는 탭 막대가 이미 그리로 가는 중이라 그대로 둔다)
    final TabController? tabs = _tabController;
    if (tabs != null && tabs.index != target) {
      tabs.animateTo(target);
    }
    if (current == target || !_pageController.hasClients) {
      return;
    }
    final int jumpId = ++_tabJumpId;
    _tabJumping = true;
    if ((target - current).abs() == 1) {
      await _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _pageController.jumpToPage(target);
    }
    if (!mounted || jumpId != _tabJumpId) {
      return; // 가는 도중 다른 탭을 또 눌렀다 — 그 이동이 이어받는다
    }
    _tabJumping = false;
    // 도착한 페이지와 위쪽 탭이 어긋나 있으면 맞춘다 (가는 도중 손으로 끌었을 때 등)
    if (_pageController.hasClients && _tabController != null) {
      final int landed = _pageController.page?.round() ?? target;
      if (landed >= 0 && landed < _tabController!.length && _tabController!.index != landed) {
        _tabController!.animateTo(landed);
      }
    }
  }

  // 프롬프트 탭 화면은 한 번만 만들어 둔다 — 탭을 옮길 때마다 새로 만들면(콜백을 넘기느라
  //  const 가 아니다) 무거운 프롬프트 화면 전체가 다시 그려진다. 다른 탭은 const 라 괜찮다.
  Widget? _promptTabPage;

  Widget _buildTabScrollContent(AppState state, AppTab tab, Widget content) {
    if (tab == AppTab.history || tab == AppTab.i2i || tab == AppTab.settings) {
      return content;
    }

    // 캐릭터 탭은 내부에서 높이를 스스로 나눠 쓴다(상단 편집 + 하단 Position).
    //  여기서 스크롤로 감싸면 화면에 딱 맞는데도 위아래로 밀려 어색하다.
    if (tab == AppTab.character) {
      return content;
    }

    // 라이브러리 탭은 목록이 길어질 수 있어 스크롤을 유지한다
    if (tab == AppTab.library) {
      return SingleChildScrollView(child: Column(children: [content, const SizedBox(height: 80)]));
    }

    return SingleChildScrollView(
      child: Column(
        children: [
          if (tab == AppTab.prompt)
            Container(
              height: 480,
              width: double.infinity,
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
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
        backgroundColor: AppColors.background,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.purple),
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
        showUpdateDialog(context, state); // 공용 창 (설정탭에서 직접 열 때도 같은 창)
      });
    }

    // 보이는 탭 — 적힌 순서대로, 켜진 것만 (프롬프트·설정은 늘)
    final List<AppTab> newVisibleTabs = [
      for (final t in AppTab.values)
        if (state.isTabShown(t)) t,
    ];

    // TabController 재생성 (활성 탭 수가 바뀌었을 때만)
    if (_tabController == null || _tabController!.length != newVisibleTabs.length) {
      // navigateToTab 요청이 있으면 그 탭으로, 아니면 현재 탭 유지
      AppTab target = AppTab.prompt;
      if (state.requestedTab != null) {
        target = state.requestedTab!;
      } else if (_tabController != null && _visibleTabs.isNotEmpty) {
        final idx = _tabController!.index.clamp(0, _visibleTabs.length - 1);
        target = _visibleTabs[idx];
      }

      final int newTabCount = newVisibleTabs.length;
      int newInitialIndex = newVisibleTabs.indexOf(target);
      if (newInitialIndex == -1) {
        newInitialIndex = 0;
      }

      if (state.requestedTab != null) {
        state.clearNavigation();
      }

      _tabController?.dispose();
      _tabController = TabController(
        length: newTabCount,
        initialIndex: newInitialIndex,
        vsync: this,
      );
      // 지금 보이는 탭을 '직전 탭'으로 잡아 둔다.
      //  (앱을 히스토리 탭에서 시작해도 첫 이동 때 갤러리 닫기가 제대로 동작하게)
      //  ⚠️ _visibleTabs 는 이 아래에서야 새 값으로 바뀌므로 새 목록을 직접 본다
      if (newInitialIndex >= 0 && newInitialIndex < newVisibleTabs.length) {
        _lastTab = newVisibleTabs[newInitialIndex];
      }
      _tabController!.addListener(() {
        // ⚠️ TabController 의 리스너는 애니메이션이 도는 '매 프레임' 불린다.
        //    여기서 키보드를 내리라고 하면 1초에 60번 요청이 나가,
        //    안드로이드 입력기가 요청을 취소·재시도하며 스스로 막힌다.
        //    그래서 탭이 실제로 바뀐 뒤 한 번만 처리한다.
        if (_tabController!.indexIsChanging) {
          return;
        }
        // 키보드를 띄운 채 탭을 옮기면 새 탭이 줄어든 높이로 그려져
        // 레이아웃이 눌린 것처럼 보인다. 입력하던 값은 컨트롤러에 이미
        // 들어 있으므로 키보드를 내려도 잃는 것이 없다.
        //  ⚠️ 키보드가 이미 내려가 있으면 부르지 않는다. 그냥 부르면
        //     안드로이드가 ALREADY_HIDDEN 으로 취소하며 로그만 쌓인다.
        if (_lastKeyboardHideTab != _tabController!.index) {
          _lastKeyboardHideTab = _tabController!.index;
          if (_keyboardOpen) {
            SystemChannels.textInput.invokeMethod('TextInput.hide');
          }
        }
        final AppTab? tab = _tabController!.index < _visibleTabs.length
            ? _visibleTabs[_tabController!.index]
            : null;
        // 히스토리 탭을 막 떠났으면 갤러리 모드를 뒤에서 닫아 둔다.
        //  (다시 들어왔을 때 이미 목록/그리드로 바뀌어 있게 — 들어온 뒤 바꾸면 눈에 보인다)
        if (_lastTab == AppTab.history && tab != AppTab.history) {
          state.resetHistoryGalleryInBackground();
        }
        _lastTab = tab;
        if (tab == AppTab.history && !state.isHistoryGridView) {
          // 컨트롤러를 직접 만지지 않고 요청만 보낸다 (HistoryTab이 처리)
          state.requestHistoryScrollToEnd();
        }
        setState(() {});
      });

      // PageController를 올바른 페이지로 재생성 (old는 프레임 후 dispose)
      final oldPageController = _pageController;
      // 탭 번호가 곧 페이지 번호다 (끝없이 돌지 않는다 — _animateToVisibleTab 참고)
      _pageController = PageController(initialPage: newInitialIndex);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldPageController.dispose();
      });
    }
    _visibleTabs = newVisibleTabs;
    final int tabCount = _visibleTabs.length;

    // 현재 선택된 원본 탭 인덱스
    final int currentVisibleIdx = _tabController!.index.clamp(0, tabCount - 1);
    final AppTab currentTab = _visibleTabs[currentVisibleIdx];

    bool isPromptTab = currentTab == AppTab.prompt;
    bool isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    // 콜백에서 쓰려고 기록해 둔다 (콜백에서 직접 MediaQuery 를 읽으면 안 된다)
    _keyboardOpen = isKeyboardOpen;
    double bottomNavBarHeight = MediaQuery.of(context).padding.bottom;

    if (state.requestedTab != null) {
      final AppTab requested = state.requestedTab!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final int targetVisibleTab = _visibleTabs.indexOf(requested);
        if (targetVisibleTab == -1) {
          state.clearNavigation(); // 꺼진 탭이면 옮기지 않는다
          return;
        }
        if (_pageController.hasClients) {
          _animateToVisibleTab(targetVisibleTab, tabCount);
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
        if (currentTab == AppTab.history) {
          final handled = state.galleryBackHandler?.call() ?? false;
          if (handled) {
            return;
          }
        }
        // 1-2. i2i 탭이면 릴(핸들) 닫기 위임
        if (currentTab == AppTab.i2i) {
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
            backgroundColor: AppColors.surface,
            bottom: TabBar(
              controller: _tabController,
              labelPadding: EdgeInsets.zero,
              indicatorWeight: 3,
              labelColor: AppColors.accent,
              unselectedLabelColor: Colors.grey,
              indicatorColor: AppColors.accent,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5),
              unselectedLabelStyle: const TextStyle(fontSize: 11.5),
              onTap: (targetVisibleTab) => _animateToVisibleTab(targetVisibleTab, tabCount),
              // 탭 이름은 AppTab 에 (라이브러리 = 와일드카드·프롬프트 사전)
              tabs: [for (final t in _visibleTabs) Tab(text: t.label)],
            ),
          ),
          body: Stack(
            children: [
              PageView.builder(
                // 탭 구성(보이는 탭 목록)이 바뀌면 PageView 자체를 새로 만든다.
                // key가 없으면 Flutter가 같은 위젯으로 보고 "옛 탭 개수로 그려둔 페이지"를
                // 그대로 재사용해, 상단 탭 표시와 실제 화면이 어긋나는 문제가 생긴다.
                key: ValueKey('pv_${_visibleTabs.map((t) => t.index).join("_")}'),
                controller: _pageController,
                itemCount: tabCount, // 탭마다 페이지 하나 (양 끝에서 멈춘다)
                // i2i 탭이거나 좌우 스와이프 비활성화 시 차단
                physics: (currentTab == AppTab.i2i || !state.horizontalSwipeEnabled)
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                onPageChanged: (index) {
                  // 스와이프로 넘길 때도 키보드를 내린다.
                  //  (페이지가 실제로 바뀐 순간에만 불리므로 한 번으로 충분하다)
                  if (_keyboardOpen) {
                    SystemChannels.textInput.invokeMethod('TextInput.hide');
                  }
                  // 탭을 눌러 넘어가는 중이면 지나치는 페이지로 탭 표시를 바꾸지 않는다
                  //  (_animateToVisibleTab 이 도착한 뒤 맞춘다 — 무지개색 번쩍임의 원인이었다)
                  if (_tabJumping) {
                    return;
                  }
                  if (index < tabCount && _tabController!.index != index) {
                    _tabController!.animateTo(index);
                  }
                },
                itemBuilder: (context, index) {
                  final AppTab tab = _visibleTabs[index];
                  return _buildTabScrollContent(state, tab, switch (tab) {
                    AppTab.prompt => _promptTabPage ??= PromptTab(
                      onScrollToHistoryEnd: state.requestHistoryScrollToEnd,
                    ),
                    AppTab.history => const HistoryTab(),
                    AppTab.i2i => const I2iTab(),
                    AppTab.character => const CharacterTab(),
                    AppTab.library => const WildcardTab(),
                    AppTab.settings => const SettingsTab(),
                  });
                },
              ),

              // 캐릭터 편집 손잡이: 스크롤 영역 밖(화면 기준)에 두어야
              // 드래그 좌표가 마우스와 정확히 일치하고 창도 화면 기준으로 뜬다
              //
              // ⚠️ 키보드가 떴다고 트리에서 빼면 안 된다.
              //    이 위젯이 캐릭터 프롬프트용 TextEditingController 를 들고 있어서,
              //    빠지는 순간 State.dispose 가 컨트롤러를 버린다.
              //    그런데 캐릭터 프롬프트 입력창(다이얼로그)은 바로 그 컨트롤러를
              //    쓰고 있다 → 입력창이 '버려진 컨트롤러'를 붙든 채 남고,
              //    키보드가 닫히며 위젯이 되살아날 때 앱이 멈춘다(ANR).
              //    그래서 트리에는 항상 두고, 보이기만 감춘다.
              // ⚠️ Stack 의 자식 '개수'가 바뀌지 않게 한다.
              //
              //    조건부로 자식을 넣었다 뺐다 하면 개수가 달라지고, Flutter 는
              //    남은 자식들을 앞에서부터 순서로 다시 맞춘다. 그 과정에서
              //    엉뚱한 요소가 서로 짝지어져 멀쩡한 화면(PageView 전체)이
              //    통째로 해제·재생성되고, 그때 아직 참조가 남은 채로 정리되면
              //    '_dependents.isEmpty' 단언에 걸려 앱이 죽는다.
              //
              //    그래서 항상 자리를 지키게 두고 보이기만 감춘다.
              //    키까지 달아 두면 순서가 흔들려도 같은 요소끼리 짝지어진다.
              Positioned.fill(
                key: const ValueKey('charDrawerHandle'),
                child: Offstage(
                  offstage: !isPromptTab || isKeyboardOpen,
                  child: const CharDrawerHandle(),
                ),
              ),

              Positioned(
                key: const ValueKey('detailSettingsButton'),
                bottom: 16 + bottomNavBarHeight,
                left: 0,
                right: 0,
                child: Offstage(
                  offstage: !isPromptTab || isKeyboardOpen,
                  child: Center(
                    child: SizedBox(
                      height: 38,
                      child: ElevatedButton.icon(
                        onPressed: () => showDetailSettingsModal(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.surfaceButton,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          elevation: 4,
                        ),
                        icon: Icon(Icons.tune, color: AppColors.accent, size: 18),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
