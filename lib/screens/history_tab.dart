import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/detail_settings_modal.dart';

// ============================================================================
// 🚀 히스토리 탭 메인 UI
// (중복된 데이터 파싱 기능은 모두 app_state.dart로 깔끔하게 이사갔습니다!)
// ============================================================================
class HistoryTab extends StatefulWidget {
  final ScrollController scrollController;
  const HistoryTab({super.key, required this.scrollController});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  late PageController _pageController;
  late ScrollController _thumbnailScrollController;
  late AppState _appState;

  int _currentIndex = 0;
  int _prevImageCount = 0; // 이전 이미지 개수 추적
  bool _isPromptOpen = false;
  int _selectedPromptTab = 0;
  bool _isAnimating = false;

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppState>();
    _currentIndex = _appState.selectedHistoryIndex >= 0 ? _appState.selectedHistoryIndex : 0;
    _pageController = PageController(initialPage: _currentIndex);

    _thumbnailScrollController = ScrollController(
      initialScrollOffset: _appState.historyThumbnailScrollOffset,
    );

    _thumbnailScrollController.addListener(() {
      _appState.historyThumbnailScrollOffset = _thumbnailScrollController.offset;
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _thumbnailScrollController.dispose();
    super.dispose();
  }

  void _scrollToThumbnail(int index) {
    if (_thumbnailScrollController.hasClients) {
      double itemWidth = 64.0 + 8.0;
      double screenWidth = MediaQuery.of(context).size.width - 32;
      double targetPos = (index * itemWidth) - (screenWidth / 2) + (itemWidth / 2);

      if (targetPos < 0) targetPos = 0;
      if (targetPos > _thumbnailScrollController.position.maxScrollExtent) {
        targetPos = _thumbnailScrollController.position.maxScrollExtent;
      }

      _thumbnailScrollController.animateTo(
        targetPos,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // AppState.historyMetadata를 인덱스로 직접 조회 (hashCode 충돌 없음)
  NaiMetadata? _getMetadataForIndex(int index) {
    final metadata = _appState.historyMetadata;
    if (index < 0 || index >= metadata.length) return null;
    return metadata[index];
  }

  String _getPromptText(NaiMetadata? metadata) {
    if (metadata == null) {
      return "이 이미지에는 저장된 프롬프트 데이터가 없습니다.\n\n(메신저 전송, 이미지 편집 등을 거치면서\n파일 내부의 메타데이터가 삭제된 이미지입니다.)";
    }

    if (_selectedPromptTab == 0) {
      return metadata.positive.isEmpty ? "긍정적 프롬프트가 없습니다." : metadata.positive;
    } else if (_selectedPromptTab == 1) {
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
    } else if (_selectedPromptTab == 2) {
      return metadata.negative.isEmpty ? "부정적 프롬프트가 없습니다." : metadata.negative;
    } else if (_selectedPromptTab == 3) {
      String scheduler = metadata.extraParams['noise_schedule']?.toString() ?? 'native';
      String modelName = metadata.source.isEmpty ? '알 수 없음' : metadata.source;
      String samplerName = metadata.sampler.isEmpty ? '알 수 없음' : metadata.sampler;
      bool varPlus = metadata.extraParams['variety_plus'] == true;

      return '''
🔹 해상도 : ${metadata.width} x ${metadata.height}
🔹 시드 : ${metadata.seed}
🔹 모델 : $modelName
🔹 스텝 : ${metadata.steps}
🔹 샘플러 : $samplerName
🔹 스케줄러 : $scheduler
🔹 CFG Scale : ${metadata.promptGuidance}
🔹 Rescale : ${metadata.promptGuidanceRescale}
🔹 VAR+ : ${varPlus ? 'ON' : 'OFF'}
''';
    }
    return "";
  }

  Widget _buildTabButton(int index, String title, Color color) {
    bool isActive = _selectedPromptTab == index;

    Color activeBoxColor = const Color(0xFF00BFA5);
    if (_selectedPromptTab == 1) {
      activeBoxColor = Colors.deepPurpleAccent;
    } else if (_selectedPromptTab == 2) {
      activeBoxColor = const Color(0xFFFF5252);
    } else if (_selectedPromptTab == 3) {
      activeBoxColor = Colors.amber;
    }

    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedPromptTab = index;
          });
        },
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
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Center(
            child: Text(
              title,
              style: TextStyle(
                color: isActive ? color : Colors.white70,
                fontWeight: FontWeight.bold,
                fontSize: 14,
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final images = state.historyImages;
    final bool isEmpty = images.isEmpty;

    if (state.scrollToThumbnailEnd) {
      state.scrollToThumbnailEnd = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_thumbnailScrollController.hasClients) {
          Future.delayed(const Duration(milliseconds: 50), () {
            if (_thumbnailScrollController.hasClients) {
              _thumbnailScrollController.animateTo(
                _thumbnailScrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });
        }
      });
    }

    // 새 이미지가 추가되었는지 감지 → 마지막 이미지로 강제 이동
    if (images.length != _prevImageCount) {
      _prevImageCount = images.length;
      if (!isEmpty && state.selectedHistoryIndex >= 0) {
        final target = state.selectedHistoryIndex.clamp(0, images.length - 1);
        _currentIndex = target;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Future.delayed(const Duration(milliseconds: 80), () {
            if (!mounted) return;
            if (_pageController.hasClients) {
              _pageController.jumpToPage(target);
            }
            _scrollToThumbnail(target);
            setState(() => _currentIndex = target);
          });
        });
      }
    }

    int displayIndex = isEmpty
        ? 0
        : (_currentIndex >= images.length ? images.length - 1 : _currentIndex);
    NaiMetadata? currentMetadata = isEmpty ? null : _getMetadataForIndex(displayIndex);

    Color currentActiveColor = const Color(0xFF00BFA5);
    if (_selectedPromptTab == 1) {
      currentActiveColor = Colors.deepPurpleAccent;
    } else if (_selectedPromptTab == 2) {
      currentActiveColor = const Color(0xFFFF5252);
    } else if (_selectedPromptTab == 3) {
      currentActiveColor = Colors.amber;
    }

    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 480,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.3)),
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
                          setState(() {
                            _currentIndex = idx;
                          });
                          context.read<AppState>().selectedHistoryIndex = idx;
                          _scrollToThumbnail(idx);
                        },
                        itemCount: images.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.all(4.0),
                            child: GestureDetector(
                              onLongPress: () {
                                showSaveImageModal(context, state, images[index]);
                              },
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(images[index], fit: BoxFit.contain),
                              ),
                            ),
                          );
                        },
                      ),

                      if (displayIndex > 0)
                        Positioned(
                          left: 8,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withValues(alpha: 0.6),
                              border: Border.all(color: Colors.deepPurpleAccent, width: 1.5),
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.arrow_back_ios_new,
                                color: Colors.deepPurpleAccent,
                                size: 24,
                              ),
                              onPressed: _goToPrev,
                            ),
                          ),
                        ),

                      if (displayIndex < images.length - 1)
                        Positioned(
                          right: 8,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withValues(alpha: 0.6),
                              border: Border.all(color: Colors.deepPurpleAccent, width: 1.5),
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.arrow_forward_ios,
                                color: Colors.deepPurpleAccent,
                                size: 24,
                              ),
                              onPressed: () => _goToNext(images.length),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),

          if (!isEmpty) ...[
            SizedBox(
              height: 64,
              child: ListView.builder(
                controller: _thumbnailScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: images.length,
                itemBuilder: (context, index) {
                  bool isSelected = displayIndex == index;
                  return GestureDetector(
                    onTap: () {
                      _pageController.animateToPage(
                        index,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                      );
                    },
                    onLongPress: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: const Color(0xFF1E1E1E),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          title: const Row(
                            children: [
                              Icon(Icons.delete_outline, color: Colors.redAccent),
                              SizedBox(width: 8),
                              Text(
                                "히스토리 삭제",
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          content: const Text(
                            "이 이미지를 히스토리 목록에서 삭제하시겠습니까?\n(기기에 저장된 실제 파일은 삭제되지 않습니다.)",
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text("취소", style: TextStyle(color: Colors.grey)),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                state.deleteHistoryImage(index);
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
                    },
                    child: Container(
                      width: 64,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isSelected ? const Color(0xFF8B5CF6) : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(images[index], fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],

          Stack(
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
                      color: isEmpty ? Colors.grey.withValues(alpha: 0.3) : Colors.deepPurpleAccent,
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
                isEmpty ? "0 / 0" : "${displayIndex + 1} / ${images.length}",
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  onPressed: () => state.importImageToHistory(context),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF8B5CF6), width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  child: const Text(
                    "이미지 불러오기",
                    style: TextStyle(
                      color: Color(0xFF8B5CF6),
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: !_isPromptOpen
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          _buildTabButton(0, "긍정적", const Color(0xFF00BFA5)),
                          _buildTabButton(1, "캐릭터", Colors.deepPurpleAccent),
                          _buildTabButton(2, "부정적", const Color(0xFFFF5252)),
                          _buildTabButton(3, "세팅", Colors.amber),
                        ],
                      ),
                      Container(
                        height: 250,
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E),
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
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
