import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/detail_settings_modal.dart';

class MaskStroke {
  final List<Offset> points;
  final double size;
  final bool isEraser;
  final bool isCircle;

  MaskStroke({
    required this.points,
    required this.size,
    required this.isEraser,
    required this.isCircle,
  });
}

class I2iTab extends StatefulWidget {
  const I2iTab({super.key});

  @override
  State<I2iTab> createState() => _I2iTabState();
}

class _I2iTabState extends State<I2iTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String _currentTool = 'pencil';

  double _brushSize = 20.0;
  double _eraserSize = 20.0;
  final bool _isCircleBrush = true;
  Color _maskColor = Colors.lightGreenAccent; // 마스크 표시 색상

  static const List<Color> _maskColorPresets = [
    Colors.lightGreenAccent,
    Colors.redAccent,
    Colors.blueAccent,
    Colors.orangeAccent,
    Colors.purpleAccent,
    Colors.cyanAccent,
    Colors.pinkAccent,
    Colors.yellowAccent,
  ];

  final List<MaskStroke> _strokes = [];
  MaskStroke? _currentStroke;

  final TransformationController _transformController = TransformationController();
  final GlobalKey _canvasKey = GlobalKey();

  Uint8List? _lastI2iImage; // 이전 i2i 이미지 추적 (마스크 자동 초기화용)

  void _selectTool(String tool) {
    if (_currentTool == tool) {
      if (tool == 'pencil' || tool == 'eraser') {
        _showSizeDialog(tool);
      }
    } else if (tool == 'zoom') {
      setState(() {
        _currentTool = _currentTool == 'zoom_in' ? 'zoom_out' : 'zoom_in';
      });
    } else {
      setState(() {
        _currentTool = tool;
      });
    }
  }

  void _showSizeDialog(String tool) {
    double tempSize = tool == 'pencil' ? _brushSize : _eraserSize;
    String title = tool == 'pencil' ? "브러시 크기" : "지우개 크기";

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: Text(
              title,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: tempSize,
                  min: 5.0,
                  max: 100.0,
                  activeColor: Colors.deepPurpleAccent,
                  onChanged: (val) {
                    setModalState(() => tempSize = val);
                  },
                ),
                Text("${tempSize.toInt()} px", style: const TextStyle(color: Colors.white)),
              ],
            ),
            actionsAlignment: MainAxisAlignment.spaceBetween,
            actions: [
              TextButton.icon(
                onPressed: () {
                  setState(() => _strokes.clear());
                  Navigator.pop(ctx);
                },
                icon: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 18),
                label: const Text(
                  "전체 지우기",
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (tool == 'pencil') {
                      _brushSize = tempSize;
                    } else {
                      _eraserSize = tempSize;
                    }
                  });
                  Navigator.pop(ctx);
                },
                child: const Text(
                  "확인",
                  style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showMaskColorDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          "마스크 색상",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _maskColorPresets.map((color) {
            final isSelected = color == _maskColor;
            return GestureDetector(
              onTap: () {
                setState(() => _maskColor = color);
                Navigator.pop(ctx);
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? Colors.white : Colors.white24,
                    width: isSelected ? 3 : 1.5,
                  ),
                ),
                child: isSelected ? const Icon(Icons.check, color: Colors.black87, size: 22) : null,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  void _onPanStart(DragStartDetails details) {
    if (_currentTool != 'pencil' && _currentTool != 'eraser') {
      return;
    }
    final ctx = _canvasKey.currentContext;
    if (ctx == null) return;

    RenderBox renderBox = ctx.findRenderObject() as RenderBox;
    Offset localPosition = renderBox.globalToLocal(details.globalPosition);

    setState(() {
      _currentStroke = MaskStroke(
        points: [localPosition],
        size: _currentTool == 'pencil' ? _brushSize : _eraserSize,
        isEraser: _currentTool == 'eraser',
        isCircle: _isCircleBrush,
      );
      _strokes.add(_currentStroke!);
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_currentTool != 'pencil' && _currentTool != 'eraser') {
      return;
    }
    if (_currentStroke == null || _canvasKey.currentContext == null) {
      return;
    }

    RenderBox renderBox = _canvasKey.currentContext!.findRenderObject() as RenderBox;
    Offset localPosition = renderBox.globalToLocal(details.globalPosition);

    setState(() {
      _currentStroke!.points.add(localPosition);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_currentTool != 'pencil' && _currentTool != 'eraser') {
      return;
    }
    _currentStroke = null;
  }

  void _onZoomTap(TapDownDetails details) {
    if (!_currentTool.startsWith('zoom')) {
      return;
    }

    final double currentScale = _transformController.value.getMaxScaleOnAxis();
    double newScale = _currentTool == 'zoom_in' ? currentScale * 1.5 : currentScale / 1.5;

    if (newScale < 1.0) {
      newScale = 1.0;
    }
    if (newScale > 10.0) {
      newScale = 10.0;
    }

    double relativeScale = newScale / currentScale;
    Offset tapPosition = details.localPosition;

    Matrix4 matrix = _transformController.value.clone();

    matrix.multiply(Matrix4.translationValues(tapPosition.dx, tapPosition.dy, 0.0));
    matrix.multiply(Matrix4.diagonal3Values(relativeScale, relativeScale, 1.0));
    matrix.multiply(Matrix4.translationValues(-tapPosition.dx, -tapPosition.dy, 0.0));

    setState(() {
      _transformController.value = matrix;
    });
  }

  Future<Uint8List?> _captureMask(int originalWidth, int originalHeight) async {
    final renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;

    // 🚀 [수정] V4.5 풀 해상도 마스크 생성
    final int maskW = originalWidth;
    final int maskH = originalHeight;

    final grid = List.generate(maskH, (_) => List.filled(maskW, false));

    final double scaleX = originalWidth / renderBox.size.width;
    final double scaleY = originalHeight / renderBox.size.height;

    for (var stroke in _strokes) {
      final r = stroke.size * scaleX / 2;
      final scaled = stroke.points.map((p) => Offset(p.dx * scaleX, p.dy * scaleY)).toList();

      for (int i = 0; i < scaled.length; i++) {
        _markGridCircle(grid, maskW, maskH, scaled[i], r, stroke.isEraser);
        if (i > 0) {
          _markGridSegment(grid, maskW, maskH, scaled[i - 1], scaled[i], r, stroke.isEraser);
        }
      }
    }

    // 🚀 [핵심 변경] 수동 PNG 빌더 대신 raw 픽셀 배열로 전달
    // 헤더: width(4바이트) + height(4바이트) + raw pixels(1바이트/픽셀)
    // _processMaskForInfill에서 image 패키지로 올바른 PNG 생성
    final raw = Uint8List(8 + maskW * maskH);
    final header = ByteData.view(raw.buffer);
    header.setUint32(0, maskW);
    header.setUint32(4, maskH);
    int idx = 8;
    for (int y = 0; y < maskH; y++) {
      for (int x = 0; x < maskW; x++) {
        raw[idx++] = grid[y][x] ? 255 : 0;
      }
    }
    return raw;
  }

  /// 🚀 [수정] 원형 브러시가 닿는 픽셀들을 직접 마킹 (V4.5 풀 해상도 방식)
  void _markGridCircle(
    List<List<bool>> grid,
    int gw,
    int gh,
    Offset center,
    double r,
    bool isEraser,
  ) {
    final int cx = center.dx.floor();
    final int cy = center.dy.floor();
    final int rPx = r.ceil() + 1;
    for (int py = (cy - rPx).clamp(0, gh - 1); py <= (cy + rPx).clamp(0, gh - 1); py++) {
      for (int px = (cx - rPx).clamp(0, gw - 1); px <= (cx + rPx).clamp(0, gw - 1); px++) {
        final dx = (px + 0.5) - center.dx;
        final dy = (py + 0.5) - center.dy;
        if (dx * dx + dy * dy <= r * r) {
          grid[py][px] = !isEraser;
        }
      }
    }
  }

  /// 🚀 [수정] 두 점 사이 선분이 닿는 픽셀들을 마킹 (V4.5 풀 해상도 방식)
  void _markGridSegment(
    List<List<bool>> grid,
    int gw,
    int gh,
    Offset a,
    Offset b,
    double r,
    bool isEraser,
  ) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = sqrt(dx * dx + dy * dy);
    if (len < 1e-10) return;
    // 픽셀 단위 보간: 반지름의 절반 간격으로 원을 찍어 빈틈 방지
    final steps = (len / max(r * 0.5, 1.0)).ceil();
    for (int s = 1; s <= steps; s++) {
      final t = s / steps;
      _markGridCircle(grid, gw, gh, Offset(a.dx + dx * t, a.dy + dy * t), r, isEraser);
    }
  }

  Widget _buildToolIcon(String toolId, IconData icon, String tooltip) {
    bool isSelected =
        _currentTool == toolId || (_currentTool.startsWith('zoom') && toolId == 'zoom');

    IconData displayIcon = icon;
    if (toolId == 'zoom') {
      displayIcon = _currentTool == 'zoom_out' ? Icons.zoom_out : Icons.zoom_in;
    }

    String? sizeText;
    if (toolId == 'pencil') {
      sizeText = "${_brushSize.toInt()}";
    }
    if (toolId == 'eraser') {
      sizeText = "${_eraserSize.toInt()}";
    }

    double iconSize = sizeText != null ? 18 : 22;
    if (toolId == 'zoom') {
      iconSize = 28;
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => _selectTool(toolId),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 52,
          height: 46,
          decoration: BoxDecoration(
            color: isSelected ? Colors.deepPurpleAccent.withValues(alpha: 0.3) : Colors.transparent,
            border: Border.all(
              color: isSelected ? Colors.deepPurpleAccent : Colors.white24,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(displayIcon, color: isSelected ? Colors.white : Colors.white54, size: iconSize),
              if (sizeText != null) ...[
                const SizedBox(height: 2),
                Text(
                  sizeText,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 강도 버튼 — 연필/지우개와 동일한 스타일, 탭하면 슬라이더 다이얼로그 표시
  Widget _buildStrengthButton(AppState state) {
    return Tooltip(
      message: "인페인트 강도 (한 번 더 누르면 변경)",
      child: InkWell(
        onTap: () => _showStrengthDialog(state),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 52,
          height: 46,
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: Colors.white24, width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                "강도",
                style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                state.infillStrength.toStringAsFixed(2),
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showStrengthDialog(AppState state) {
    double tempStrength = state.infillStrength;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text(
              "인페인트 강도",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: tempStrength,
                  min: 0.1,
                  max: 1.0,
                  divisions: 18,
                  activeColor: Colors.deepPurpleAccent,
                  onChanged: (val) {
                    setModalState(() => tempStrength = double.parse(val.toStringAsFixed(2)));
                  },
                ),
                Text(tempStrength.toStringAsFixed(2), style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 8),
                const Text(
                  "0.1 = 원본 유지  /  1.0 = 완전 재생성",
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("취소", style: TextStyle(color: Colors.grey)),
              ),
              TextButton(
                onPressed: () {
                  state.infillStrength = tempStrength;
                  state.saveAllSettings();
                  state.refreshUI();
                  Navigator.pop(ctx);
                },
                child: const Text(
                  "확인",
                  style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showPromptEditDialog(
    BuildContext context,
    AppState state,
    String title,
    IconData icon,
    Color color,
    TextEditingController controller,
  ) {
    FocusNode focusNode = FocusNode();
    final String initialText = controller.text;

    showDialog(
      context: context,
      builder: (ctx) {
        List<String> suggestions = [];

        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            focusNode.addListener(() {
              if (!focusNode.hasFocus) {
                Future.delayed(const Duration(milliseconds: 150), () {
                  if (ctx.mounted) {
                    setModalState(() {
                      suggestions.clear();
                    });
                  }
                });
              }
            });

            void onTextChanged() {
              String text = controller.text;
              int cursor = controller.selection.baseOffset;
              if (cursor < 0) {
                cursor = text.length;
              }

              String beforeCursor = text.substring(0, cursor);

              int lastComma = beforeCursor.lastIndexOf(',');
              int lastColon = beforeCursor.lastIndexOf(':');
              int lastNewline = beforeCursor.lastIndexOf('\n');
              int lastParen = beforeCursor.lastIndexOf(')');
              int lastDelimiter = max(lastComma, max(lastColon, max(lastNewline, lastParen)));

              String currentWord = lastDelimiter == -1
                  ? beforeCursor
                  : beforeCursor.substring(lastDelimiter + 1);

              currentWord = currentWord.trimLeft();

              if (currentWord.isEmpty) {
                setModalState(() {
                  suggestions = [];
                });
                return;
              }

              if (currentWord.startsWith('__')) {
                String searchWord = currentWord.replaceAll('__', '').toLowerCase();
                List<String> matches = state.wildcards
                    .where((w) => w.name.toLowerCase().startsWith(searchWord))
                    .map((w) => "__${w.name}__")
                    .take(15)
                    .toList();

                setModalState(() {
                  suggestions = matches;
                });
                return;
              }

              List<String> matches = state.danbooruTags
                  .where((t) => t.toLowerCase().startsWith(currentWord.toLowerCase()))
                  .take(15)
                  .toList();

              setModalState(() {
                suggestions = matches;
              });
            }

            void insertTag(String tag) {
              String text = controller.text;
              int cursor = controller.selection.baseOffset;
              if (cursor < 0) {
                cursor = text.length;
              }

              String beforeCursor = text.substring(0, cursor);
              String afterCursor = text.substring(cursor);

              int lastComma = beforeCursor.lastIndexOf(',');
              int lastColon = beforeCursor.lastIndexOf(':');
              int lastNewline = beforeCursor.lastIndexOf('\n');
              int lastParen = beforeCursor.lastIndexOf(')');
              int lastDelimiter = max(lastComma, max(lastColon, max(lastNewline, lastParen)));

              String newBefore;

              if (lastDelimiter == -1) {
                newBefore = "$tag, ";
              } else {
                String delimiterStr = beforeCursor.substring(lastDelimiter, lastDelimiter + 1);
                if (delimiterStr == ':') {
                  newBefore = "${beforeCursor.substring(0, lastDelimiter)}:$tag, ";
                } else if (delimiterStr == '\n') {
                  newBefore = "${beforeCursor.substring(0, lastDelimiter)}\n$tag, ";
                } else if (delimiterStr == ')') {
                  newBefore = "${beforeCursor.substring(0, lastDelimiter)}) $tag, ";
                } else {
                  newBefore = "${beforeCursor.substring(0, lastDelimiter)}, $tag, ";
                }
              }

              controller.value = TextEditingValue(
                text: newBefore + afterCursor,
                selection: TextSelection.collapsed(offset: newBefore.length),
              );

              setModalState(() {
                suggestions.clear();
              });
              state.saveAllSettings();
              state.refreshUI();
            }

            return Dialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(icon, color: color, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    Container(
                      height: 250,
                      decoration: BoxDecoration(
                        border: Border.all(color: color.withValues(alpha: 0.5)),
                        borderRadius: BorderRadius.circular(12),
                        color: const Color(0xFF121212),
                      ),
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        onChanged: (_) {
                          onTextChanged();
                          state.saveAllSettings();
                          state.refreshUI();
                        },
                        maxLines: null,
                        expands: true,
                        style: const TextStyle(color: Colors.white, height: 1.5),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: suggestions.isNotEmpty ? 40 : 0,
                      child: suggestions.isNotEmpty
                          ? ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: suggestions.length,
                              itemBuilder: (context, index) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8.0),
                                  child: ActionChip(
                                    label: Text(
                                      suggestions[index],
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    backgroundColor: color.withValues(alpha: 0.2),
                                    side: BorderSide(color: color, width: 1.5),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    onPressed: () => insertTag(suggestions[index]),
                                  ),
                                );
                              },
                            )
                          : const SizedBox.shrink(),
                    ),

                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          onPressed: () {
                            controller.clear();
                            setModalState(() {
                              suggestions.clear();
                            });
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: color),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Icon(Icons.delete_sweep, color: color, size: 20),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () {
                            controller.text = initialText;
                            setModalState(() {
                              suggestions.clear();
                            });
                            state.saveAllSettings();
                            state.refreshUI();
                          },
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: color),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Icon(Icons.restore, color: color, size: 20),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: color,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text(
                            "닫기",
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) => focusNode.dispose());
  }

  Widget _buildPromptCard(
    BuildContext context,
    AppState state, {
    required String title,
    required IconData icon,
    required Color color,
    required TextEditingController controller,
    String hint = "",
  }) {
    return GestureDetector(
      onTap: () => _showPromptEditDialog(context, state, title, icon, color, controller),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: color, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        title,
                        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  Icon(Icons.edit, color: color, size: 16),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                controller.text.isEmpty ? hint : controller.text,
                style: TextStyle(
                  color: controller.text.isEmpty ? Colors.white30 : Colors.white,
                  height: 1.5,
                  fontSize: 14,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScrollToggleArea(Widget child, bool disableScroll, AppState state) {
    return Listener(
      onPointerDown: (_) {
        if (_localScrollDisabled != disableScroll) {
          setState(() {
            _localScrollDisabled = disableScroll;
          });
          state.setI2iScrollDisabled(disableScroll);
        }
      },
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }

  bool _localScrollDisabled = false;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();

    // 새 이미지가 i2i로 전송되면 마스크 자동 초기화
    if (state.targetI2iImage != null && state.targetI2iImage != _lastI2iImage) {
      _lastI2iImage = state.targetI2iImage;
      if (_strokes.isNotEmpty) {
        _strokes.clear();
        _transformController.value = Matrix4.identity();
      }
    }

    bool isPanTool = _currentTool == 'pan';
    bool canDraw = _currentTool == 'pencil' || _currentTool == 'eraser';

    double aspect = 832 / 1216;
    if (state.targetI2iMetadata != null &&
        state.targetI2iMetadata!.width > 0 &&
        state.targetI2iMetadata!.height > 0) {
      aspect = state.targetI2iMetadata!.width / state.targetI2iMetadata!.height;
    }

    return SingleChildScrollView(
      physics: _localScrollDisabled
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildScrollToggleArea(
            Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: state.isInpaintLoading
                            ? null
                            : () async {
                                if (state.targetI2iImage == null ||
                                    state.targetI2iMetadata == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("히스토리에서 먼저 이미지를 선택해주세요!")),
                                  );
                                  return;
                                }
                                if (_strokes.isEmpty) {
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showSnackBar(const SnackBar(content: Text("마스크를 그려주세요! 🖍️")));
                                  return;
                                }
                                final maskBytes = await _captureMask(
                                  state.targetI2iMetadata!.width,
                                  state.targetI2iMetadata!.height,
                                );
                                if (maskBytes != null && context.mounted) {
                                  state.handleInpaintGenerate(context, maskBytes);
                                }
                              },
                        icon: state.isInpaintLoading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.format_paint, color: Colors.white, size: 18),
                        label: Text(
                          state.isInpaintLoading ? "생성중..." : "인페인트",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00BFA5),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 🚀 [수정] 업스케일 전용 로딩 상태(isUpscaleLoading)를 사용합니다!
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: state.isUpscaleLoading
                            ? null
                            : () {
                                if (state.targetI2iImage == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("히스토리에서 먼저 이미지를 선택해주세요!")),
                                  );
                                  return;
                                }
                                state.handleUpscaleGenerate(context);
                              },
                        icon: state.isUpscaleLoading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.high_quality, color: Colors.white, size: 18),
                        label: Text(
                          state.isUpscaleLoading ? "처리중..." : "업스케일",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber[700],
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
            true, // 버튼 영역도 스크롤 비활성 (캔버스와 같은 영역)
            state,
          ),

          _buildScrollToggleArea(
            Column(
              children: [
                Container(
                  height: 480,
                  decoration: BoxDecoration(
                    color: const Color(0xFF121212),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.deepPurpleAccent.withValues(alpha: 0.5),
                      width: 2,
                    ),
                  ),
                  child: state.targetI2iImage != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: InteractiveViewer(
                            transformationController: _transformController,
                            panEnabled: isPanTool,
                            scaleEnabled: isPanTool || _currentTool.startsWith('zoom'),
                            boundaryMargin: const EdgeInsets.all(double.infinity),
                            minScale: 1.0,
                            maxScale: 10.0,
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: aspect,
                                child: ClipRect(
                                  child: Stack(
                                    key: _canvasKey,
                                    fit: StackFit.expand,
                                    children: [
                                      Image.memory(state.targetI2iImage!, fit: BoxFit.fill),
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onPanStart: canDraw ? _onPanStart : null,
                                        onPanUpdate: canDraw ? _onPanUpdate : null,
                                        onPanEnd: canDraw ? _onPanEnd : null,
                                        onTapDown: _currentTool.startsWith('zoom')
                                            ? _onZoomTap
                                            : null,
                                        child: CustomPaint(
                                          painter: MaskPainter(
                                            strokes: _strokes,
                                            maskColor: _maskColor,
                                          ),
                                          size: Size.infinite,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      : const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.image_search, size: 48, color: Colors.white24),
                              SizedBox(height: 16),
                              Text(
                                "생성된 이미지를 꾹 눌러\n'이미지 수정하기'를 선택하세요.",
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white30),
                              ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 12),

                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildToolIcon('pencil', Icons.edit, "연필 (한 번 더 누르면 크기 변경)"),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: "마스크 색상 변경",
                        child: InkWell(
                          onTap: _showMaskColorDialog,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 52,
                            height: 46,
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              border: Border.all(color: Colors.white24, width: 1.5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: _maskColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white54, width: 1.5),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildToolIcon('eraser', Icons.cleaning_services, "지우개 (한 번 더 누르면 크기 변경)"),
                      const SizedBox(width: 8),
                      _buildToolIcon('zoom', Icons.zoom_in, "돋보기 (누를 때마다 확대/축소 변경)"),
                      const SizedBox(width: 8),
                      _buildToolIcon('pan', Icons.pan_tool, "손 (화면 이동)"),
                      const SizedBox(width: 8),
                      _buildStrengthButton(state),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
            true,
            state,
          ),

          _buildScrollToggleArea(
            Column(
              children: [
                _buildPromptCard(
                  context,
                  state,
                  title: "긍정적 프롬프트 (Inpaint 전용)",
                  icon: Icons.add_circle_outline,
                  color: const Color(0xFF00BFA5),
                  controller: state.inpaintPositiveController,
                  hint: "태그를 입력하세요...",
                ),
                const SizedBox(height: 12),
                _buildPromptCard(
                  context,
                  state,
                  title: "선행 프롬프트 (Inpaint 전용)",
                  icon: Icons.arrow_right_alt,
                  color: const Color(0xFF29B6F6),
                  controller: state.inpaintPrefixController,
                  hint: "1girl, solo...",
                ),
                const SizedBox(height: 12),
                _buildPromptCard(
                  context,
                  state,
                  title: "후행 프롬프트 (Inpaint 전용)",
                  icon: Icons.keyboard_double_arrow_right,
                  color: const Color(0xFFFFA000),
                  controller: state.inpaintSuffixController,
                  hint: "고정으로 맨 뒤에 들어갈 태그...",
                ),
                const SizedBox(height: 16),
                _buildPromptCard(
                  context,
                  state,
                  title: "부정적 프롬프트 (Inpaint 전용)",
                  icon: Icons.remove_circle_outline,
                  color: const Color(0xFFFF5252),
                  controller: state.inpaintNegativeController,
                  hint: "text, logo...",
                ),
                const SizedBox(height: 16),

                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          state.inpaintPositiveController.text = state.positiveController.text;
                          state.inpaintPrefixController.text = state.prefixController.text;
                          state.inpaintSuffixController.text = state.suffixController.text;
                          state.inpaintNegativeController.text = state.negativeController.text;
                        });
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text("프롬프트 탭의 값을 가져왔습니다!")));
                      },
                      icon: const Icon(Icons.content_copy, color: Colors.white70, size: 18),
                      label: const Text(
                        "프롬값 가져오기",
                        style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => showDetailSettingsModal(context),
                      icon: const Icon(Icons.tune, color: Colors.white70, size: 18),
                      label: const Text(
                        "상세 환경",
                        style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 80),
              ],
            ),
            false,
            state,
          ),
        ],
      ),
    );
  }
}

class MaskPainter extends CustomPainter {
  final List<MaskStroke> strokes;
  final Color maskColor;

  MaskPainter({required this.strokes, required this.maskColor});

  @override
  void paint(Canvas canvas, Size size) {
    final layerPaint = Paint()..color = Colors.white.withValues(alpha: 0.5);
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), layerPaint);

    for (var stroke in strokes) {
      final paint = Paint()..style = PaintingStyle.fill;

      if (stroke.isEraser) {
        paint.blendMode = BlendMode.clear;
        paint.color = Colors.transparent;
      } else {
        paint.color = maskColor;
        paint.blendMode = BlendMode.srcOver;
      }

      final r = stroke.size / 2;
      for (int i = 0; i < stroke.points.length; i++) {
        canvas.drawCircle(stroke.points[i], r, paint);
        if (i > 0) {
          final a = stroke.points[i - 1];
          final b = stroke.points[i];
          final dx = b.dx - a.dx;
          final dy = b.dy - a.dy;
          final lenSq = dx * dx + dy * dy;
          if (lenSq < 1e-10) continue;
          final scale = r / sqrt(lenSq);
          final nx = -dy * scale;
          final ny = dx * scale;
          final path = Path()
            ..moveTo(a.dx - nx, a.dy - ny)
            ..lineTo(b.dx - nx, b.dy - ny)
            ..lineTo(b.dx + nx, b.dy + ny)
            ..lineTo(a.dx + nx, a.dy + ny)
            ..close();
          canvas.drawPath(path, paint);
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
