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
  int _prevImageCount = 0;
  bool _isPromptOpen = false;
  int _selectedPromptTab = 0;
  bool _isAnimating = false;
  bool _showFavoritesOnly = false;
  bool _wasGridView = false;
  bool _isSelectMode = false;
  final Set<int> _selectedIndices = {};

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

      // 썸네일 바는 최신 30개만 표시하므로 오프셋 보정
      final int total = _appState.historyImages.length;
      final int thumbStart = (total > 30) ? total - 30 : 0;
      final int thumbIndex = index - thumbStart;

      // 범위 밖이면 스크롤하지 않음
      if (thumbIndex < 0) return;

      double targetPos = (thumbIndex * itemWidth) - (screenWidth / 2) + (itemWidth / 2);

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
    if (_isAnimating || _currentIndex <= 0) return;
    _isAnimating = true;
    await _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    _isAnimating = false;
  }

  void _goToNext(int total) async {
    if (_isAnimating || _currentIndex >= total - 1) return;
    _isAnimating = true;
    await _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    _isAnimating = false;
  }

  // 그리드 → 리스트 전환하며 해당 이미지로 이동
  void _switchToListAtIndex(AppState state, int index) {
    setState(() {
      _currentIndex = index;
      state.isHistoryGridView = false;
    });
    state.selectedHistoryIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(index);
      }
      _scrollToThumbnail(index);
    });
  }

  void _showDeleteDialog(BuildContext context, AppState state, int index) {
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
  }

  // ============================================================================
  // 재생성 다이얼로그 (썸네일 + 파일 없을 때)
  // ============================================================================
  void _showRegenerateDialog(BuildContext context, AppState state, int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.refresh, color: Colors.deepPurpleAccent),
            SizedBox(width: 8),
            Text(
              "해당 이미지를 새로 생성",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: const Text(
          "메타데이터를 서버로 보내 새로 생성합니다.\n(Anlas가 소모될 수 있습니다.)",
          style: TextStyle(color: Colors.white70, fontSize: 14),
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
              state.deleteHistoryImage(index);
            },
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent)),
            child: const Text("삭제", style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              state.regenerateFromMetadata(context, index);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurpleAccent),
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
      backgroundColor: const Color(0xFF1E1E1E),
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
                onTap: () {
                  Navigator.pop(modalContext);
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF1E1E1E),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: const Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.amber),
                          SizedBox(width: 8),
                          Text(
                            "정말 삭제하시겠습니까?",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      content: const Text(
                        "히스토리의 모든 이미지가 삭제됩니다.\n이 작업은 되돌릴 수 없습니다.",
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
                            state.deleteAllHistory();
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                          child: const Text(
                            "전부 삭제",
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.star_border, color: Colors.amber),
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
  Widget _buildGridView(AppState state, List images) {
    if (images.isEmpty) {
      return const Center(
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
      );
    }

    // 즐겨찾기 필터 적용: 실제 인덱스 목록 (역순)
    List<int> displayIndices = [];
    for (int i = images.length - 1; i >= 0; i--) {
      if (_showFavoritesOnly) {
        if (i < state.historyFavorites.length && state.historyFavorites[i]) {
          displayIndices.add(i);
        }
      } else {
        displayIndices.add(i);
      }
    }

    if (_showFavoritesOnly && displayIndices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.star_border, size: 48, color: Colors.white24),
              SizedBox(height: 16),
              Text("즐겨찾기한 이미지가 없습니다.", style: TextStyle(color: Colors.white30)),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: displayIndices.length,
      itemBuilder: (context, index) {
        final realIndex = displayIndices[index];
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
                if (_selectedIndices.contains(realIndex)) {
                  _selectedIndices.remove(realIndex);
                  if (_selectedIndices.isEmpty) _isSelectMode = false;
                } else {
                  _selectedIndices.add(realIndex);
                }
              });
            } else {
              _switchToListAtIndex(state, realIndex);
            }
          },
          onLongPress: () {
            if (!_isSelectMode) {
              // 선택 모드 진입
              setState(() {
                _isSelectMode = true;
                _selectedIndices.clear();
                _selectedIndices.add(realIndex);
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
                      color: _isSelectMode && _selectedIndices.contains(realIndex)
                          ? Colors.redAccent
                          : isFav
                          ? Colors.amber.withValues(alpha: 0.5)
                          : Colors.deepPurpleAccent.withValues(alpha: 0.2),
                      width: _isSelectMode && _selectedIndices.contains(realIndex)
                          ? 2.5
                          : (isFav ? 1.5 : 1),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Image.memory(images[realIndex], fit: BoxFit.cover),
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
                      color: _selectedIndices.contains(realIndex)
                          ? Colors.redAccent
                          : Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _selectedIndices.contains(realIndex)
                            ? Colors.redAccent
                            : Colors.white38,
                        width: 1.5,
                      ),
                    ),
                    child: _selectedIndices.contains(realIndex)
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
                    onTap: () => state.toggleHistoryFavorite(realIndex),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        color: isFav ? Colors.amber : Colors.white54,
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
      },
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
                        final bool isThumbnail = state.isHistoryThumbnail(index);
                        final bool fileExists = state.checkFileExistsSync(index);
                        return Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: GestureDetector(
                            onLongPress: () {
                              if (isThumbnail && !fileExists) {
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
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
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
                                              color: fileExists
                                                  ? Colors.tealAccent
                                                  : Colors.white38,
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
            child: Builder(
              builder: (context) {
                // 최신 30개만 표시
                final int thumbStart = (images.length > 30) ? images.length - 30 : 0;
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
                        _pageController.animateToPage(
                          realIndex,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      },
                      onLongPress: () {
                        final bool isThumbnail = state.isHistoryThumbnail(realIndex);
                        final bool fileExists = state.checkFileExistsSync(realIndex);
                        if (isThumbnail && !fileExists) {
                          _showRegenerateDialog(context, state, realIndex);
                        } else {
                          _showDeleteDialog(context, state, realIndex);
                        }
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
                          child: Image.memory(images[realIndex], fit: BoxFit.cover),
                        ),
                      ),
                    );
                  },
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
      ],
    );
  }

  // ============================================================================
  // build
  // ============================================================================
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final images = state.historyImages;
    final bool isEmpty = images.isEmpty;
    final bool isGridView = state.isHistoryGridView;

    if (!isGridView && state.scrollToThumbnailEnd) {
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

    // 그리드 → 리스트 전환 시 PageController를 올바른 위치로 재생성 (깜빡임 방지)
    if (_wasGridView && !isGridView && !isEmpty) {
      final syncTarget = state.selectedHistoryIndex >= 0
          ? state.selectedHistoryIndex.clamp(0, images.length - 1)
          : _currentIndex.clamp(0, images.length - 1);
      _currentIndex = syncTarget;
      _pageController.dispose();
      _pageController = PageController(initialPage: syncTarget);

      // 썸네일 스크롤도 올바른 위치로 재생성 (스르륵 움직임 방지)
      final double itemWidth = 64.0 + 8.0;
      final double screenWidth = MediaQuery.of(context).size.width - 32;
      final int thumbStart = (images.length > 30) ? images.length - 30 : 0;
      final int thumbIndex = syncTarget - thumbStart;
      double targetOffset = (thumbIndex * itemWidth) - (screenWidth / 2) + (itemWidth / 2);
      if (targetOffset < 0) targetOffset = 0;

      _thumbnailScrollController.dispose();
      _thumbnailScrollController = ScrollController(initialScrollOffset: targetOffset);
      _appState.historyThumbnailScrollOffset = targetOffset;
    }
    _wasGridView = isGridView;

    // 새 이미지가 추가되었는지 감지 → 마지막 이미지로 강제 이동
    if (!isGridView && images.length != _prevImageCount) {
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
          // 리스트/그리드 토글 바
          if (_isSelectMode && isGridView)
            // ===== 선택 모드 툴바 =====
            Row(
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _isSelectMode = false;
                      _selectedIndices.clear();
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.close, size: 18, color: Colors.white54),
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
                  "${_selectedIndices.length}장 선택됨",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // 선택 삭제 버튼
                GestureDetector(
                  onTap: _selectedIndices.isEmpty
                      ? null
                      : () {
                          showDialog(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: const Color(0xFF1E1E1E),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              title: const Row(
                                children: [
                                  Icon(Icons.delete_outline, color: Colors.redAccent),
                                  SizedBox(width: 8),
                                  Text(
                                    "선택 삭제",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              content: Text(
                                "${_selectedIndices.length}장의 이미지를 히스토리에서 삭제하시겠습니까?\n(실제 파일은 삭제되지 않습니다.)",
                                style: const TextStyle(color: Colors.white70, fontSize: 14),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text("취소", style: TextStyle(color: Colors.grey)),
                                ),
                                ElevatedButton(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    state.deleteHistoryByIndices(_selectedIndices);
                                    setState(() {
                                      _isSelectMode = false;
                                      _selectedIndices.clear();
                                    });
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.redAccent,
                                  ),
                                  child: const Text(
                                    "삭제",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: _selectedIndices.isEmpty
                          ? const Color(0xFF1E1E1E)
                          : Colors.redAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _selectedIndices.isEmpty ? Colors.white24 : Colors.redAccent,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: _selectedIndices.isEmpty ? Colors.white38 : Colors.redAccent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          "삭제",
                          style: TextStyle(
                            color: _selectedIndices.isEmpty ? Colors.white38 : Colors.redAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          else
            // ===== 일반 모드 툴바 =====
            Row(
              children: [
                _buildViewToggle(
                  icon: Icons.view_carousel_outlined,
                  label: "리스트",
                  isActive: !isGridView,
                  onTap: () {
                    setState(() {
                      _isSelectMode = false;
                      _selectedIndices.clear();
                    });
                    state.isHistoryGridView = false;
                    state.refreshUI();
                  },
                ),
                const SizedBox(width: 8),
                _buildViewToggle(
                  icon: Icons.grid_view_rounded,
                  label: "그리드",
                  isActive: isGridView,
                  onTap: () {
                    state.isHistoryGridView = true;
                    state.refreshUI();
                  },
                ),
                const Spacer(),
                Text(
                  "${images.length}장",
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (isGridView) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _showFavoritesOnly = !_showFavoritesOnly;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: _showFavoritesOnly
                            ? Colors.amber.withValues(alpha: 0.2)
                            : const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _showFavoritesOnly ? Colors.amber : Colors.white24,
                          width: _showFavoritesOnly ? 1.5 : 1.0,
                        ),
                      ),
                      child: Icon(
                        _showFavoritesOnly ? Icons.star : Icons.star_border,
                        size: 18,
                        color: _showFavoritesOnly ? Colors.amber : Colors.white54,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => state.importImageToHistory(context),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF8B5CF6), width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    child: const Text(
                      "불러오기",
                      style: TextStyle(
                        color: Color(0xFF8B5CF6),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (images.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _showBulkDeleteSheet(context, state),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Icon(Icons.delete_outline, size: 18, color: Colors.white54),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          const SizedBox(height: 12),

          // 메인 컨텐츠
          if (isGridView)
            _buildGridView(state, images)
          else
            _buildListView(
              state,
              images,
              isEmpty,
              displayIndex,
              currentMetadata,
              currentActiveColor,
            ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildViewToggle({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.deepPurpleAccent.withValues(alpha: 0.25)
              : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? Colors.deepPurpleAccent : Colors.white24,
            width: isActive ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: isActive ? Colors.deepPurpleAccent : Colors.white54),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.white54,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
