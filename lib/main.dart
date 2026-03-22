import 'package:flutter/material.dart';
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

class _NovelAiAppState extends State<NovelAiApp> with TickerProviderStateMixin {
  late TabController _tabController;
  late PageController _pageController;
  final ScrollController _historyScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _pageController = PageController(initialPage: 6000);

    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      if (_tabController.index == 1 && _historyScrollController.hasClients) {
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
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pageController.dispose();
    _historyScrollController.dispose();
    super.dispose();
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

    if (state.requestedTabIndex != null) {
      int targetTab = state.requestedTabIndex!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pageController.hasClients) {
          int currentPage = _pageController.page?.round() ?? 6000;
          int currentTab = currentPage % 6;
          int diff = targetTab - currentTab;
          if (diff > 3) {
            diff -= 6;
          } else if (diff < -3) {
            diff += 6;
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

    bool isPromptTab = _tabController.index == 0;
    bool isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    double bottomNavBarHeight = MediaQuery.of(context).padding.bottom;

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
            onTap: (targetTab) {
              state.setI2iScrollDisabled(false); // 🚀 탭 전환 시 강제로 잠금 해제!
              int currentPage = _pageController.page?.round() ?? 6000;
              int currentTab = currentPage % 6;
              int diff = targetTab - currentTab;
              if (diff > 3) {
                diff -= 6;
              } else if (diff < -3) {
                diff += 6;
              }
              _pageController.animateToPage(
                currentPage + diff,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            },
            tabs: const [
              Tab(text: "프롬프트"),
              Tab(text: "히스토리"),
              Tab(text: "i2i"),
              Tab(text: "캐릭터"),
              Tab(text: "와일드카드"),
              Tab(text: "설정"),
            ],
          ),
        ),
        body: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              // 🚀 [해결] i2i 탭이고 스크롤 잠금 상태일 때만 옆으로 넘어가는 걸 차단!
              physics: (_tabController.index == 2 && state.isI2iScrollDisabled)
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              onPageChanged: (index) {
                state.setI2iScrollDisabled(false); // 🚀 스와이프로 탭이 바뀌면 잠금 해제!
                int targetTab = index % 6;
                if (_tabController.index != targetTab) _tabController.animateTo(targetTab);
              },
              itemBuilder: (context, index) {
                int tabIndex = index % 6;
                switch (tabIndex) {
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
