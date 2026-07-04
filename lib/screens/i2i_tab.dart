import 'dart:math';
import '../utils/prompt_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
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

class _I2iTabState extends State<I2iTab>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  // 결과 추가 시 핸들 반짝 효과
  late final AnimationController _glowController;
  int _lastResultCount = 0;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  }

  @override
  void dispose() {
    _glowController.dispose();
    _reelScroll.dispose();
    super.dispose();
  }

  String _currentTool = 'pencil';

  double _brushSize = 20.0;
  double _eraserSize = 20.0;
  final bool _isCircleBrush = true;
  Color _maskColor = Colors.lightGreenAccent;

  // 모자이크 설정
  String _mosaicType = 'pixel'; // 'pixel' or 'blur'
  double _mosaicStrength = 5.0; // 2~50
  bool _isMosaicProcessing = false;

  // i2i 모드: 'inpaint', 'mosaic', 'upscale'
  String _i2iMode = 'inpaint';

  // 캔버스/프롬프트 뷰 토글
  bool _showCanvasView = true;

  // i2i 결과 릴 슬라이드 패널
  bool _reelOpen = false;
  static const double _reelPanelWidth = 116;
  double? _handleBottomOverride; // 드래그 중 임시 위치

  // 시스템 네비게이션 바 높이 (한 번만 계산)
  double? _systemBottomPadding;

  // 모자이크 미리보기
  Uint8List? _mosaicPreviewImage;
  bool _isPreviewLoading = false;

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
  final ScrollController _reelScroll = ScrollController(); // i2i 결과 릴 스크롤(위치 힌트용)
  final GlobalKey _canvasKey = GlobalKey();

  Uint8List? _lastI2iImage; // 이전 i2i 이미지 추적 (마스크 자동 초기화용)

  // ============================================================================
  // 모자이크 타입 헬퍼
  // ============================================================================
  Color _getMosaicTypeColor() {
    switch (_mosaicType) {
      case 'pixel':
        return Colors.deepPurpleAccent;
      case 'blur':
        return Colors.blueAccent;
      case 'line':
        return Colors.grey;
      default:
        return Colors.deepPurpleAccent;
    }
  }

  String _getMosaicTypeLabel() {
    switch (_mosaicType) {
      case 'pixel':
        return '픽셀';
      case 'blur':
        return '블러';
      case 'line':
        return '검정';
      default:
        return '픽셀';
    }
  }

  // ============================================================================
  // i2i 모드 UI 헬퍼
  // ============================================================================
  Widget _buildModeChip(String mode, String label, IconData icon, Color color) {
    final isActive = _i2iMode == mode;
    return GestureDetector(
      onTap: () => setState(() {
        _i2iMode = mode;
        _mosaicPreviewImage = null;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? color.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isActive ? color : Colors.white38),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? color : Colors.white38,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getExecuteColor() {
    switch (_i2iMode) {
      case 'inpaint':
        return const Color(0xFF00BFA5);
      case 'mosaic':
        return Colors.deepPurpleAccent;
      case 'upscale':
        return Colors.amber[700]!;
      default:
        return const Color(0xFF00BFA5);
    }
  }

  String _getExecuteLabel(AppState state) {
    final bool anyLoading = state.isLoading || state.isInpaintLoading || state.isUpscaleLoading;
    if (anyLoading) return "생성중...";
    switch (_i2iMode) {
      case 'inpaint':
        return "인페인트 실행";
      case 'mosaic':
        return _isMosaicProcessing ? "처리중..." : "모자이크 적용";
      case 'upscale':
        return "업스케일 실행";
      default:
        return "실행";
    }
  }

  Widget _getExecuteIcon(AppState state) {
    bool isLoading =
        state.isLoading ||
        state.isInpaintLoading ||
        state.isUpscaleLoading ||
        (_i2iMode == 'mosaic' && _isMosaicProcessing);
    if (isLoading) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    }
    switch (_i2iMode) {
      case 'inpaint':
        return const Icon(Icons.format_paint, color: Colors.white, size: 18);
      case 'mosaic':
        return const Icon(Icons.grid_on, color: Colors.white, size: 18);
      case 'upscale':
        return const Icon(Icons.high_quality, color: Colors.white, size: 18);
      default:
        return const Icon(Icons.play_arrow, color: Colors.white, size: 18);
    }
  }

  VoidCallback? _getExecuteOnPressed(AppState state, BuildContext context) {
    // 어떤 생성이든 진행 중이면 전부 비활성화
    if (state.isLoading || state.isInpaintLoading || state.isUpscaleLoading) return null;

    switch (_i2iMode) {
      case 'inpaint':
        return () async {
          if (state.targetI2iImage == null || state.targetI2iMetadata == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(milliseconds: 2400),
                content: Text("히스토리에서 먼저 이미지를 선택해주세요!"),
              ),
            );
            return;
          }
          if (_strokes.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(milliseconds: 2400),
                content: Text("마스크를 그려주세요! 🖍️"),
              ),
            );
            return;
          }
          final maskBytes = await _captureMask(
            state.targetI2iMetadata!.width,
            state.targetI2iMetadata!.height,
          );
          if (maskBytes != null && context.mounted) {
            state.handleInpaintGenerate(context, maskBytes);
          }
        };
      case 'mosaic':
        if (_isMosaicProcessing) return null;
        return () => _applyMosaic(state);
      case 'upscale':
        return () {
          if (state.targetI2iImage == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(milliseconds: 2400),
                content: Text("히스토리에서 먼저 이미지를 선택해주세요!"),
              ),
            );
            return;
          }
          state.handleUpscaleGenerate(context);
        };
      default:
        return null;
    }
  }

  void _selectTool(String tool) {
    if (_currentTool == tool) {
      if (tool == 'pencil' || tool == 'eraser') {
        _showSizeDialog(tool);
      } else if (tool == 'pan') {
        // 손 도구를 다시 누름 + 현재 배율이 100%(초기 배율)면 이미지를 정 가운데로 정렬
        final scale = _transformController.value.getMaxScaleOnAxis();
        if (scale <= 1.01) {
          setState(() {
            _transformController.value = Matrix4.identity();
          });
        }
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
    String title = tool == 'pencil' ? "브러시 설정" : "지우개 크기";

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
                // 브러시일 때만 색상 선택 (4개씩 2줄)
                if (tool == 'pencil') ...[
                  const SizedBox(height: 16),
                  const Text("마스크 색상", style: TextStyle(color: Colors.white54, fontSize: 13)),
                  const SizedBox(height: 8),
                  for (int row = 0; row < 2; row++) ...[
                    if (row > 0) const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (int col = 0; col < 4; col++) ...[
                          if (col > 0) const SizedBox(width: 10),
                          Builder(
                            builder: (context) {
                              final color = _maskColorPresets[row * 4 + col];
                              final isSelected = color == _maskColor;
                              return GestureDetector(
                                onTap: () {
                                  setState(() => _maskColor = color);
                                  setModalState(() {});
                                },
                                child: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isSelected ? Colors.white : Colors.transparent,
                                      width: 2.5,
                                    ),
                                  ),
                                  child: isSelected
                                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                                      : null,
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ],
            ),
            actionsAlignment: tool == 'eraser'
                ? MainAxisAlignment.spaceBetween
                : MainAxisAlignment.end,
            actions: [
              if (tool == 'eraser')
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

  void _onPanStart(DragStartDetails details) {
    // 업스케일 모드는 마스킹 불필요 — 입력 무시
    if (_i2iMode == 'upscale') {
      return;
    }
    if (_currentTool != 'pencil' && _currentTool != 'eraser') {
      return;
    }
    final ctx = _canvasKey.currentContext;
    if (ctx == null) return;

    RenderBox renderBox = ctx.findRenderObject() as RenderBox;
    Offset localPosition = renderBox.globalToLocal(details.globalPosition);

    setState(() {
      _mosaicPreviewImage = null; // 새 마스크 → 미리보기 초기화
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
    // 업스케일 모드는 마스킹 불필요 — 입력 무시
    if (_i2iMode == 'upscale') {
      return;
    }
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

    // V4.5 풀 해상도 마스크
    final int maskW = originalWidth;
    final int maskH = originalHeight;
    final double scaleX = originalWidth / renderBox.size.width;
    final double scaleY = originalHeight / renderBox.size.height;

    // 메인 스레드: 스트로크를 마스크 좌표로 변환해 직렬화 (가벼움)
    final strokeData = _strokes.map((stroke) {
      final r = stroke.size * scaleX / 2;
      final pts = <double>[];
      for (final p in stroke.points) {
        pts.add(p.dx * scaleX);
        pts.add(p.dy * scaleY);
      }
      return _MaskStrokeData(pts, r, stroke.isEraser);
    }).toList();

    // 무거운 grid 빌드 + raw 생성(~수백만 회 루프)은 백그라운드 isolate에서
    // (UI 스레드 멈춤 방지 — 인페인트 시작 시 렉의 원인이었음)
    return compute(_buildMaskRaw, _MaskBuildParams(maskW, maskH, strokeData));
  }

  // ============================================================================
  // 모자이크 처리 — 백그라운드 isolate에서 실행 (UI 멈춤 방지)
  // ============================================================================
  Future<void> _applyMosaic(AppState state) async {
    if (state.targetI2iImage == null) return;
    if (_strokes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(duration: const Duration(milliseconds: 2400), content: Text("마스크를 그려주세요! 🖍️")),
        );
      }
      return;
    }

    setState(() => _isMosaicProcessing = true);

    try {
      final renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null) return;

      // 디코드 + 마스크 빌드 + 모자이크 전부 백그라운드 isolate에서 (UI 멈춤 방지)
      final pngBytes = await compute(_processMosaicIsolate, {
        'imageBytes': state.targetI2iImage!,
        'strokes': _strokes
            .map(
              (s) => {
                'pts': [
                  for (final p in s.points) ...[p.dx, p.dy],
                ],
                'size': s.size,
                'isEraser': s.isEraser,
              },
            )
            .toList(),
        'renderW': renderBox.size.width,
        'renderH': renderBox.size.height,
        'type': _mosaicType,
        'strength': _mosaicStrength.round(),
      });

      if (pngBytes != null) {
        state.targetI2iImage = pngBytes;
        _strokes.clear();

        // 모자이크 결과는 메인 히스토리 대신 i2i 스크래치 릴로
        state.addI2iResult(pngBytes, null);

        state.refreshUI();
      }
    } catch (e) {
      debugPrint("모자이크 처리 실패: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 2400),
            content: Text("모자이크 처리 중 오류가 발생했습니다."),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isMosaicProcessing = false);
    }
  }

  // 백그라운드 isolate에서 실행되는 정적 함수
  // (디코드 + 마스크 grid/flatMask 빌드 + 모자이크 전부 여기서 — UI 스레드 안 막음)
  static Uint8List? _processMosaicIsolate(Map<String, dynamic> params) {
    final imageBytes = params['imageBytes'] as Uint8List;
    final strokes = params['strokes'] as List;
    final double renderW = (params['renderW'] as num).toDouble();
    final double renderH = (params['renderH'] as num).toDouble();
    final String type = params['type'];
    final int strength = params['strength'];

    final original = img.decodeImage(imageBytes);
    if (original == null) return null;
    final int w = original.width;
    final int h = original.height;

    // 마스크 그리드 빌드 (isolate 내부)
    final double scaleX = w / renderW;
    final double scaleY = h / renderH;
    final grid = List.generate(h, (_) => List.filled(w, false));
    for (final s in strokes) {
      final m = s as Map;
      final pts = (m['pts'] as List).cast<double>();
      final double size = (m['size'] as num).toDouble();
      final bool isEraser = m['isEraser'] == true;
      final r = size * scaleX / 2;
      final n = pts.length ~/ 2;
      for (int i = 0; i < n; i++) {
        final x = pts[i * 2] * scaleX;
        final y = pts[i * 2 + 1] * scaleY;
        _maskMarkCircle(grid, w, h, x, y, r, isEraser);
        if (i > 0) {
          _maskMarkSegment(
            grid,
            w,
            h,
            pts[(i - 1) * 2] * scaleX,
            pts[(i - 1) * 2 + 1] * scaleY,
            x,
            y,
            r,
            isEraser,
          );
        }
      }
    }
    final flatMask = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (grid[y][x]) flatMask[y * w + x] = 1;
      }
    }

    final result = img.Image.from(original);

    if (type == 'pixel') {
      final int blockSize = strength.clamp(2, 50);
      for (int by = 0; by < h; by += blockSize) {
        for (int bx = 0; bx < w; bx += blockSize) {
          bool hasMask = false;
          for (int py = by; py < min(by + blockSize, h); py++) {
            for (int px = bx; px < min(bx + blockSize, w); px++) {
              if (flatMask[py * w + px] == 1) {
                hasMask = true;
                break;
              }
            }
            if (hasMask) break;
          }
          if (!hasMask) continue;

          int sumR = 0, sumG = 0, sumB = 0, count = 0;
          for (int py = by; py < min(by + blockSize, h); py++) {
            for (int px = bx; px < min(bx + blockSize, w); px++) {
              final p = original.getPixel(px, py);
              sumR += p.r.toInt();
              sumG += p.g.toInt();
              sumB += p.b.toInt();
              count++;
            }
          }
          if (count == 0) continue;
          final avgR = sumR ~/ count, avgG = sumG ~/ count, avgB = sumB ~/ count;

          for (int py = by; py < min(by + blockSize, h); py++) {
            for (int px = bx; px < min(bx + blockSize, w); px++) {
              if (flatMask[py * w + px] == 1) result.setPixelRgb(px, py, avgR, avgG, avgB);
            }
          }
        }
      }
    } else if (type == 'blur') {
      final int radius = strength.clamp(2, 50);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          if (flatMask[y * w + x] != 1) continue;
          int sumR = 0, sumG = 0, sumB = 0, count = 0;
          for (int ky = -radius; ky <= radius; ky++) {
            for (int kx = -radius; kx <= radius; kx++) {
              final px = (x + kx).clamp(0, w - 1);
              final py = (y + ky).clamp(0, h - 1);
              final p = original.getPixel(px, py);
              sumR += p.r.toInt();
              sumG += p.g.toInt();
              sumB += p.b.toInt();
              count++;
            }
          }
          result.setPixelRgb(x, y, sumR ~/ count, sumG ~/ count, sumB ~/ count);
        }
      }
    } else if (type == 'line') {
      final double opacity = (strength / 50.0).clamp(0.0, 1.0);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          if (flatMask[y * w + x] != 1) continue;
          final p = original.getPixel(x, y);
          result.setPixelRgb(
            x,
            y,
            (p.r.toInt() * (1 - opacity)).round(),
            (p.g.toInt() * (1 - opacity)).round(),
            (p.b.toInt() * (1 - opacity)).round(),
          );
        }
      }
    }

    return Uint8List.fromList(img.encodeJpg(result, quality: 95));
  }

  // 모자이크 미리보기 (축소 이미지로 빠르게 처리)
  Future<void> _generateMosaicPreview(AppState state) async {
    if (state.targetI2iImage == null || _strokes.isEmpty) {
      setState(() => _mosaicPreviewImage = null);
      return;
    }

    setState(() => _isPreviewLoading = true);

    try {
      final renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null) return;

      // 디코드 + 마스크 빌드 + 모자이크 전부 백그라운드 isolate에서 (UI 멈춤 방지)
      final previewBytes = await compute(_processMosaicIsolate, {
        'imageBytes': state.targetI2iImage!,
        'strokes': _strokes
            .map(
              (s) => {
                'pts': [
                  for (final p in s.points) ...[p.dx, p.dy],
                ],
                'size': s.size,
                'isEraser': s.isEraser,
              },
            )
            .toList(),
        'renderW': renderBox.size.width,
        'renderH': renderBox.size.height,
        'type': _mosaicType,
        'strength': _mosaicStrength.round(),
      });

      if (mounted) {
        setState(() {
          _mosaicPreviewImage = previewBytes;
          _isPreviewLoading = false;
        });
      }
    } catch (e) {
      debugPrint("미리보기 생성 실패: $e");
      if (mounted) setState(() => _isPreviewLoading = false);
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

    double iconSize = sizeText != null ? 16 : 20;
    if (toolId == 'zoom') {
      iconSize = 24;
    }

    // 인페인트 모드는 여유있으니 원래 크기
    final bool compact = _i2iMode == 'mosaic';
    final double btnW = compact ? 44 : 52;
    final double btnH = compact ? 40 : 46;
    if (!compact) {
      iconSize = sizeText != null ? 18 : 22;
      if (toolId == 'zoom') iconSize = 28;
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => _selectTool(toolId),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: btnW,
          height: btnH,
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
      message: "인페인트 강도",
      child: InkWell(
        onTap: _showStrengthDialog,
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
              const SizedBox(height: 1),
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

  Widget _buildMosaicStrengthButton() {
    return Tooltip(
      message: "모자이크 강도",
      child: InkWell(
        onTap: () {
          showDialog(
            context: context,
            builder: (ctx) => StatefulBuilder(
              builder: (ctx, setDialogState) => AlertDialog(
                backgroundColor: const Color(0xFF1E1E1E),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: const Text(
                  "모자이크 강도",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "${_mosaicStrength.round()}",
                      style: const TextStyle(
                        color: Colors.deepPurpleAccent,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Slider(
                      value: _mosaicStrength,
                      min: 2,
                      max: 50,
                      activeColor: Colors.deepPurpleAccent,
                      onChanged: (v) {
                        setDialogState(() {});
                        setState(() => _mosaicStrength = v);
                      },
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("확인", style: TextStyle(color: Colors.deepPurpleAccent)),
                  ),
                ],
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 44,
          height: 40,
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
                style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold),
              ),
              Text(
                "${_mosaicStrength.round()}",
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showStrengthDialog() {
    final state = context.read<AppState>();
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
              int lastParen = max(
                beforeCursor.lastIndexOf(')'),
                max(
                  beforeCursor.lastIndexOf('('),
                  max(beforeCursor.lastIndexOf('{'), beforeCursor.lastIndexOf('|')),
                ),
              );
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

              List<String> matches = smartMatchTags(state.searchTags, currentWord);

              setModalState(() {
                suggestions = matches;
              });
            }

            void insertTag(String rawTag) {
              PromptUtils.applyTagToController(controller, rawTag);

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
                        const SizedBox(width: 6),
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
                                final raw = suggestions[index];
                                final isContains = raw.startsWith(kContainsMarker);
                                final display = PromptUtils.displayTag(raw);
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8.0),
                                  child: ActionChip(
                                    label: Text(
                                      display,
                                      style: TextStyle(
                                        color: state.isE621Tag(raw)
                                            ? const Color(0xFF3B9EFF)
                                            : (isContains ? Colors.white54 : Colors.white),
                                        fontWeight: isContains
                                            ? FontWeight.normal
                                            : FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    backgroundColor: color.withValues(
                                      alpha: isContains ? 0.08 : 0.2,
                                    ),
                                    side: BorderSide(
                                      color: color.withValues(alpha: isContains ? 0.3 : 1.0),
                                      width: isContains ? 0.5 : 1.5,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    onPressed: () => insertTag(raw),
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

  // i2i 스크래치 릴 (최신이 왼쪽)
  // 본문 위에 오른쪽 슬라이드 패널 + 트리거 핸들을 오버레이
  Widget _withReelOverlay(AppState state, Widget body) {
    // 결과가 늘어나면 핸들 반짝 (프레임 이후 트리거)
    final int resultCount = state.i2iResults.length;
    if (resultCount > _lastResultCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _glowController.forward(from: 0);
          // 새 결과는 맨 아래(최신)이므로 릴을 맨 아래로 스크롤해 최신이 보이게
          if (_reelScroll.hasClients) {
            _reelScroll.animateTo(
              _reelScroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        }
      });
    }
    _lastResultCount = resultCount;

    // i2i 히스토리 비활성화 시: 릴/핸들 없이 본문만 (결과는 메인 히스토리로)
    if (state.i2iHistoryDisabled) {
      return body;
    }
    // 시스템 네비바 + 하단 '프롬프트 보기' 버튼 위로 핸들을 띄운다
    final mq = MediaQuery.of(context);
    final double defaultBottom = mq.viewPadding.bottom + 84;
    final double minBottom = mq.viewPadding.bottom + 8;
    final double maxBottom = mq.size.height - 160; // 위쪽 여백 확보
    // 우선순위: 드래그 중 임시값 > 저장값 > 기본값
    final double rawBottom =
        _handleBottomOverride ??
        (state.i2iHandleBottom >= 0 ? state.i2iHandleBottom : defaultBottom);
    final double handleBottom = rawBottom.clamp(minBottom, maxBottom);
    return Stack(
      children: [
        Positioned.fill(child: body),
        // 패널 열렸을 때 바깥 영역 탭하면 닫기
        if (_reelOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _reelOpen = false),
              child: Container(color: Colors.black54),
            ),
          ),
        // 오른쪽 슬라이드 패널
        AnimatedPositioned(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          top: 0,
          bottom: 0,
          right: _reelOpen ? 0 : -_reelPanelWidth,
          width: _reelPanelWidth,
          child: _buildReelPanel(state),
        ),
        // 트리거 핸들 (항상 보임, 오른쪽 아래) — 닫혀 있을 때만
        if (!_reelOpen)
          Positioned(
            right: 0,
            bottom: handleBottom,
            child: GestureDetector(
              onTap: () {
                setState(() => _reelOpen = true);
                // 열 때 최신(맨 아래)이 보이도록 점프
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _reelScroll.hasClients) {
                    _reelScroll.jumpTo(_reelScroll.position.maxScrollExtent);
                  }
                });
              },
              onVerticalDragUpdate: (d) {
                final base = _handleBottomOverride ?? handleBottom;
                setState(() {
                  _handleBottomOverride = (base - d.delta.dy).clamp(minBottom, maxBottom);
                });
              },
              onVerticalDragEnd: (_) {
                final v = _handleBottomOverride;
                if (v != null) {
                  state.saveI2iHandleBottom(v);
                  _handleBottomOverride = null;
                }
              },
              child: AnimatedBuilder(
                animation: _glowController,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 드래그 힌트
                    Container(
                      width: 18,
                      height: 3,
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: Colors.white54,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const Icon(Icons.collections, color: Colors.white, size: 20),
                    const SizedBox(height: 3),
                    Text(
                      "${state.i2iResults.length}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                builder: (context, child) {
                  final v = _glowController.value;
                  // 0→1→0 삼각 펄스 (양 끝은 글로우 없음)
                  final double pulse = v <= 0 ? 0.0 : (v < 0.5 ? v * 2 : (1 - v) * 2);
                  return Transform.scale(
                    scale: 1 + 0.14 * pulse,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      decoration: BoxDecoration(
                        color: Colors.deepPurpleAccent,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(14),
                          bottomLeft: Radius.circular(14),
                        ),
                        boxShadow: pulse > 0
                            ? [
                                BoxShadow(
                                  color: Colors.deepPurpleAccent.withValues(alpha: 0.85 * pulse),
                                  blurRadius: 22 * pulse,
                                  spreadRadius: 2 * pulse,
                                ),
                              ]
                            : null,
                      ),
                      child: child,
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  // i2i 결과 슬라이드 패널 (세로 목록, 최신 먼저)
  Widget _buildReelPanel(AppState state) {
    final results = state.i2iResults;
    return Material(
      color: const Color(0xFF161616),
      elevation: 12,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 6, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "i2i 결과",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _reelOpen = false),
                    child: const Icon(Icons.close, color: Colors.white54, size: 20),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: results.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          "아직 결과가 없어요.\n인페인트/모자이크/\n업스케일을 실행하면\n여기에 쌓여요.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5),
                        ),
                      ),
                    )
                  : Scrollbar(
                      controller: _reelScroll,
                      thumbVisibility: true,
                      thickness: 3,
                      radius: const Radius.circular(3),
                      child: ListView.separated(
                        controller: _reelScroll,
                        padding: const EdgeInsets.all(8),
                        itemCount: results.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (ctx, i) {
                          final realIndex = i; // 오래된 것이 위, 최신이 맨 아래
                          final r = results[realIndex];
                          final bool isCurrent = identical(r.bytes, state.targetI2iImage);
                          return GestureDetector(
                            onTap: () {
                              state.useI2iResult(realIndex);
                              setState(() => _reelOpen = false);
                            },
                            onLongPress: () => _showI2iResultMenu(state, realIndex),
                            child: Stack(
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isCurrent ? Colors.deepPurpleAccent : Colors.white12,
                                      width: isCurrent ? 2 : 1,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(7),
                                    child: AspectRatio(
                                      aspectRatio: 1,
                                      child: Image.memory(
                                        r.bytes,
                                        fit: BoxFit.cover,
                                        cacheWidth: 200,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: GestureDetector(
                                    onTap: () {
                                      final ok = state.toggleI2iFavorite(realIndex);
                                      if (!ok && mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            duration: const Duration(milliseconds: 1800),
                                            content: Text(
                                              "즐겨찾기는 최대 ${AppState.i2iFavoriteCap}개까지예요",
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.4),
                                        borderRadius: const BorderRadius.only(
                                          topRight: Radius.circular(7),
                                          bottomLeft: Radius.circular(7),
                                        ),
                                      ),
                                      child: Icon(
                                        r.favorite ? Icons.star : Icons.star_border,
                                        size: 16,
                                        color: r.favorite ? Colors.amber : Colors.white70,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // i2i 결과 꾹 누르기 메뉴
  void _showI2iResultMenu(AppState state, int index) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.history, color: Color(0xFF8B5CF6)),
              title: const Text("히스토리로 보내기", style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                await state.promoteI2iToHistory(index, context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.save_alt, color: Color(0xFF00BFA5)),
              title: const Text("폴더에 저장하기", style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                await state.saveI2iToFolder(index, context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text("내역에서 삭제", style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(ctx);
                state.removeI2iResult(index);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();

    // i2i 작업 이미지가 바뀌면 상태 갱신 (모드는 유지)
    if (state.targetI2iImage != null && state.targetI2iImage != _lastI2iImage) {
      _lastI2iImage = state.targetI2iImage;
      _mosaicPreviewImage = null; // 이전 이미지 기준 미리보기는 무효
      _isPreviewLoading = false;
      if (state.i2iPreserveMaskOnNextChange) {
        // 릴에서 결과를 눌러 이미지만 바꾼 경우 → 마스킹·확대상태 유지 (결과 비교 편의)
        state.i2iPreserveMaskOnNextChange = false; // 1회용 신호 소비
      } else {
        // i2i로 새 이미지를 보낸 경우 → 전체 초기화
        _strokes.clear();
        _transformController.value = Matrix4.identity(); // 확대/이동 초기화
      }
    }

    // 인페인트 자동 마스크 해제: 이미지 전환 여부와 무관하게 결과가 나온 즉시 마스크만 해제
    // (자동 전환 OFF일 때도 인페인트 순간 바로 지워지도록 — 확대상태는 그대로 둠)
    if (state.i2iRequestMaskClear) {
      state.i2iRequestMaskClear = false; // 1회용 신호 소비
      _strokes.clear();
    }

    bool canDraw =
        (_i2iMode != 'upscale') && (_currentTool == 'pencil' || _currentTool == 'eraser');

    if (_showCanvasView) {
      // ===== 캔버스 뷰 (풀 스크린, 스크롤 없음) =====
      return _withReelOverlay(
        state,
        LayoutBuilder(
          builder: (context, constraints) {
            // 시스템 네비게이션 바 높이 캐싱 (최초 1회)
            _systemBottomPadding ??= MediaQuery.of(context).viewPadding.bottom;
            final bottomPad = _systemBottomPadding!;

            final toolbarHeight = _i2iMode == 'upscale' ? 0.0 : 58.0; // 46(버튼) + 12(간격)
            final canvasHeight =
                constraints.maxHeight - 60 - 12 - toolbarHeight - 44 - bottomPad - 32;
            // 60=모드+실행 / 12=간격 / toolbarHeight / 44=토글버튼 / bottomPad=네비바 / 32=패딩

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildModeChip(
                              'inpaint',
                              '인페인트',
                              Icons.format_paint,
                              const Color(0xFF00BFA5),
                            ),
                            _buildModeChip(
                              'mosaic',
                              '모자이크',
                              Icons.grid_on,
                              Colors.deepPurpleAccent,
                            ),
                            _buildModeChip(
                              'upscale',
                              '업스케일',
                              Icons.high_quality,
                              Colors.amber[700]!,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _getExecuteOnPressed(state, context),
                          icon: _getExecuteIcon(state),
                          label: Text(
                            _getExecuteLabel(state),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                (state.isLoading ||
                                    state.isInpaintLoading ||
                                    state.isUpscaleLoading)
                                ? Colors.grey[700]
                                : _getExecuteColor(),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 캔버스 (남은 공간 채우기)
                  Container(
                    height: canvasHeight.clamp(200, 800),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: state.isInpaintLoading ? Colors.amber : Colors.white24,
                        width: state.isInpaintLoading ? 2 : 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: state.targetI2iImage == null
                          ? const Center(
                              child: Text(
                                "히스토리에서 이미지를 선택하세요.",
                                style: TextStyle(color: Colors.white30),
                              ),
                            )
                          : Center(
                              child: InteractiveViewer(
                                transformationController: _transformController,
                                panEnabled:
                                    _currentTool == 'pan' ||
                                    _currentTool == 'zoom_in' ||
                                    _currentTool == 'zoom_out',
                                scaleEnabled: false,
                                child: AspectRatio(
                                  aspectRatio:
                                      (state.targetI2iMetadata?.width ?? 832) /
                                      (state.targetI2iMetadata?.height ?? 1216),
                                  child: GestureDetector(
                                    onPanStart: canDraw ? _onPanStart : null,
                                    onPanUpdate: canDraw ? _onPanUpdate : null,
                                    onPanEnd: canDraw ? _onPanEnd : null,
                                    onTapDown:
                                        (_currentTool == 'zoom_in' || _currentTool == 'zoom_out')
                                        ? _onZoomTap
                                        : null,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.memory(
                                          _mosaicPreviewImage != null && _i2iMode == 'mosaic'
                                              ? _mosaicPreviewImage!
                                              : state.targetI2iImage!,
                                          fit: BoxFit.fill,
                                        ),
                                        Positioned.fill(
                                          child: CustomPaint(
                                            key: _canvasKey,
                                            painter: MaskPainter(
                                              strokes:
                                                  (_i2iMode == 'upscale' ||
                                                      (_mosaicPreviewImage != null &&
                                                          _i2iMode == 'mosaic'))
                                                  ? []
                                                  : _strokes,
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
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 도구 버튼 (업스케일 모드에서는 숨김) — 고정 높이
                  if (_i2iMode != 'upscale') ...[
                    SizedBox(
                      height: 46,
                      child: Center(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _buildToolIcon('pencil', Icons.edit, "연필 (한 번 더 누르면 크기/색상 변경)"),
                              SizedBox(width: _i2iMode == 'mosaic' ? 6 : 8),
                              _buildToolIcon(
                                'eraser',
                                Icons.cleaning_services,
                                "지우개 (한 번 더 누르면 크기 변경)",
                              ),
                              SizedBox(width: _i2iMode == 'mosaic' ? 6 : 8),
                              _buildToolIcon('zoom', Icons.zoom_in, "돋보기"),
                              SizedBox(width: _i2iMode == 'mosaic' ? 6 : 8),
                              _buildToolIcon('pan', Icons.pan_tool, "손 (화면 이동)"),
                              if (_i2iMode == 'inpaint') ...[
                                const SizedBox(width: 8),
                                _buildStrengthButton(state),
                              ],
                              if (_i2iMode == 'mosaic') ...[
                                const SizedBox(width: 6),
                                _buildMosaicStrengthButton(),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: () => setState(() {
                                    if (_mosaicType == 'pixel') {
                                      _mosaicType = 'blur';
                                    } else if (_mosaicType == 'blur') {
                                      _mosaicType = 'line';
                                    } else {
                                      _mosaicType = 'pixel';
                                    }
                                  }),
                                  child: Container(
                                    width: 44,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: _getMosaicTypeColor().withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: _getMosaicTypeColor(), width: 1.5),
                                    ),
                                    child: Center(
                                      child: Text(
                                        _getMosaicTypeLabel(),
                                        style: TextStyle(
                                          color: _getMosaicTypeColor(),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: "모자이크 미리보기",
                                  child: InkWell(
                                    onTap: _isPreviewLoading
                                        ? null
                                        : () {
                                            if (_mosaicPreviewImage != null) {
                                              setState(() => _mosaicPreviewImage = null);
                                            } else {
                                              _generateMosaicPreview(state);
                                            }
                                          },
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: _mosaicPreviewImage != null
                                            ? Colors.deepPurpleAccent.withValues(alpha: 0.2)
                                            : Colors.transparent,
                                        border: Border.all(
                                          color: _mosaicPreviewImage != null
                                              ? Colors.deepPurpleAccent
                                              : Colors.white24,
                                          width: 1.5,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: _isPreviewLoading
                                          ? const Padding(
                                              padding: EdgeInsets.all(10),
                                              child: CircularProgressIndicator(
                                                color: Colors.deepPurpleAccent,
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : Icon(
                                              _mosaicPreviewImage != null
                                                  ? Icons.visibility
                                                  : Icons.visibility_outlined,
                                              color: _mosaicPreviewImage != null
                                                  ? Colors.deepPurpleAccent
                                                  : Colors.white54,
                                              size: 18,
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ), // Center
                    ), // SizedBox
                    const SizedBox(height: 12),
                  ],
                  // 프롬프트 보기 토글 (전 모드)
                  GestureDetector(
                    onTap: () => setState(() => _showCanvasView = false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      margin: EdgeInsets.only(bottom: bottomPad),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.expand_more, color: Colors.white54, size: 20),
                          SizedBox(width: 4),
                          Text(
                            "프롬프트 보기",
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
                ],
              ),
            );
          },
        ),
      );
    }

    // ===== 프롬프트 뷰 (스크롤 가능) =====
    return _withReelOverlay(
      state,
      SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: () => setState(() => _showCanvasView = true),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.expand_less, color: Colors.white54, size: 20),
                    SizedBox(width: 4),
                    Text(
                      "캔버스 보기",
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
            _buildPromptCard(
              context,
              state,
              title: "긍정적 프롬프트 (Inpaint 전용)",
              icon: Icons.add_circle_outline,
              color: const Color(0xFF00BFA5),
              controller: state.inpaintPositiveController,
              hint: "프롬프트를 입력하세요...",
            ),
            const SizedBox(height: 12),
            _buildPromptCard(
              context,
              state,
              title: "선행 프롬프트 (Inpaint 전용)",
              icon: Icons.arrow_right_alt,
              color: const Color(0xFF29B6F6),
              controller: state.inpaintPrefixController,
              hint: "프롬프트를 입력하세요...",
            ),
            const SizedBox(height: 12),
            _buildPromptCard(
              context,
              state,
              title: "후행 프롬프트 (Inpaint 전용)",
              icon: Icons.keyboard_double_arrow_right,
              color: const Color(0xFFFFA000),
              controller: state.inpaintSuffixController,
              hint: "프롬프트를 입력하세요...",
            ),
            const SizedBox(height: 16),
            _buildPromptCard(
              context,
              state,
              title: "부정적 프롬프트 (Inpaint 전용)",
              icon: Icons.remove_circle_outline,
              color: const Color(0xFFFF5252),
              controller: state.inpaintNegativeController,
              hint: "프롬프트를 입력하세요...",
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(milliseconds: 2400),
                        content: Text("프롬프트 탭의 값을 가져왔습니다!"),
                      ),
                    );
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
      ),
    );
  }
}

// ============================================================================
// 인페인트 마스크 빌드 — 백그라운드 isolate(compute)에서 실행해 UI 멈춤 방지
// ============================================================================
class _MaskStrokeData {
  final List<double> pts; // 마스크 좌표로 스케일된 [x0,y0,x1,y1,...]
  final double radius;
  final bool isEraser;
  const _MaskStrokeData(this.pts, this.radius, this.isEraser);
}

class _MaskBuildParams {
  final int maskW;
  final int maskH;
  final List<_MaskStrokeData> strokes;
  const _MaskBuildParams(this.maskW, this.maskH, this.strokes);
}

// grid 빌드 + raw 픽셀 배열(헤더 8바이트 + 1바이트/픽셀) 생성
Uint8List _buildMaskRaw(_MaskBuildParams p) {
  final int maskW = p.maskW;
  final int maskH = p.maskH;
  final grid = List.generate(maskH, (_) => List.filled(maskW, false));

  for (final s in p.strokes) {
    final pts = s.pts;
    final r = s.radius;
    final n = pts.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final x = pts[i * 2];
      final y = pts[i * 2 + 1];
      _maskMarkCircle(grid, maskW, maskH, x, y, r, s.isEraser);
      if (i > 0) {
        _maskMarkSegment(
          grid,
          maskW,
          maskH,
          pts[(i - 1) * 2],
          pts[(i - 1) * 2 + 1],
          x,
          y,
          r,
          s.isEraser,
        );
      }
    }
  }

  final raw = Uint8List(8 + maskW * maskH);
  final header = ByteData.view(raw.buffer);
  header.setUint32(0, maskW);
  header.setUint32(4, maskH);
  int idx = 8;
  for (int y = 0; y < maskH; y++) {
    final row = grid[y];
    for (int x = 0; x < maskW; x++) {
      raw[idx++] = row[x] ? 255 : 0;
    }
  }
  return raw;
}

// 원형 브러시가 닿는 픽셀 마킹 (인페인트/모자이크 isolate 공용)
void _maskMarkCircle(
  List<List<bool>> grid,
  int gw,
  int gh,
  double cxF,
  double cyF,
  double r,
  bool isEraser,
) {
  final int cx = cxF.floor();
  final int cy = cyF.floor();
  final int rPx = r.ceil() + 1;
  for (int py = (cy - rPx).clamp(0, gh - 1); py <= (cy + rPx).clamp(0, gh - 1); py++) {
    for (int px = (cx - rPx).clamp(0, gw - 1); px <= (cx + rPx).clamp(0, gw - 1); px++) {
      final dx = (px + 0.5) - cxF;
      final dy = (py + 0.5) - cyF;
      if (dx * dx + dy * dy <= r * r) {
        grid[py][px] = !isEraser;
      }
    }
  }
}

// 두 점 사이 선분 마킹 (반지름 절반 간격으로 원을 찍어 빈틈 방지)
void _maskMarkSegment(
  List<List<bool>> grid,
  int gw,
  int gh,
  double ax,
  double ay,
  double bx,
  double by,
  double r,
  bool isEraser,
) {
  final dx = bx - ax;
  final dy = by - ay;
  final len = sqrt(dx * dx + dy * dy);
  if (len < 1e-10) return;
  final steps = (len / max(r * 0.5, 1.0)).ceil();
  for (int s = 1; s <= steps; s++) {
    final t = s / steps;
    _maskMarkCircle(grid, gw, gh, ax + dx * t, ay + dy * t, r, isEraser);
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
