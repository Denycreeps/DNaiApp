import 'dart:math';
import '../utils/prompt_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import '../models/app_state.dart';
import '../widgets/detail_settings_modal.dart';

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
    // 릴(핸들)이 열려있을 때 뒤로가기 → 닫기
    // (I2iTab은 생성자 주입이 아니라 Provider에서 state를 얻으므로 context.read 사용)
    final state = context.read<AppState>();
    _appStateRef = state;
    _myBackHandler = () {
      if (_reelOpen) {
        setState(() => _reelOpen = false);
        return true;
      }
      return false;
    };
    state.i2iBackHandler = _myBackHandler;
    // 마스크 처리는 build가 아니라 리스너에서 (탭 가시성과 무관하게 즉시 1회 처리 — 지연/재실행 방지)
    _lastI2iImage = state.targetI2iImage; // 현재 이미지를 기준선으로 (초기 오탐 방지)
    _lastMaskClearRevision = state.i2iMaskClearRevision;
    // 탭이 재생성돼도(PageView가 페이지 정리) 기존 릴 결과를 "새 결과"로 오인해
    // 핸들이 깜빡이지 않도록, 현재 결과 개수를 기준선으로 잡아둔다.
    _lastResultCount = state.i2iResults.length;
    state.addListener(_handleI2iMaskChanges);
  }

  // app_state 변화 시 마스크 처리 (build 밖에서 실행 → 탭 전환 rebuild에 안 휩쓸림)
  void _handleI2iMaskChanges() {
    if (!mounted) {
      return;
    }
    final state = _appStateRef;
    if (state == null) {
      return;
    }
    bool changed = false;

    // ① 작업 이미지가 바뀐 경우: 지정된 마스크 처리 방식에 따라
    if (state.targetI2iImage != null && state.targetI2iImage != _lastI2iImage) {
      _lastI2iImage = state.targetI2iImage;
      _mosaicPreviewImage = null;
      _isPreviewLoading = false;

      bool clearMask;
      switch (state.i2iMaskActionOnChange) {
        case I2iMaskAction.keepMask:
          clearMask = false;
          break;
        case I2iMaskAction.followInpaintSetting:
          clearMask = state.inpaintAutoClearMask;
          break;
        case I2iMaskAction.clearMask:
          clearMask = true;
          break;
      }
      if (clearMask) {
        _strokes.clear();
        changed = true;
      }
      if (state.i2iMaskActionOnChange == I2iMaskAction.clearMask) {
        _transformController.value = Matrix4.identity();
      }
    }

    // ② 이미지는 그대로 두고 마스크만 즉시 해제 (자동 전환 OFF + 자동 해제 ON)
    if (state.i2iMaskClearRevision != _lastMaskClearRevision) {
      _lastMaskClearRevision = state.i2iMaskClearRevision;
      _strokes.clear();
      changed = true;
    }

    if (changed) {
      setState(() {}); // 캔버스(CustomPaint) 갱신
    }
  }

  // dispose 시점엔 context 접근이 불안정하므로 initState에서 참조를 저장해 둔다.
  AppState? _appStateRef;
  // 뒤로가기 핸들러 클로저 (dispose 시 identity 비교용 — PageView가 같은 탭을
  // 잠깐 두 인스턴스로 만들 때, 옛 인스턴스가 새 인스턴스의 핸들러를 지우지 않도록)
  late final bool Function() _myBackHandler;

  @override
  void dispose() {
    if (_appStateRef != null) {
      _appStateRef!.removeListener(_handleI2iMaskChanges);
      // 내 핸들러가 아직 등록돼 있을 때만 해제 (새 인스턴스가 이미 덮어썼으면 건드리지 않음)
      if (identical(_appStateRef!.i2iBackHandler, _myBackHandler)) {
        _appStateRef!.i2iBackHandler = null;
      }
    }
    _glowController.dispose();
    _reelScroll.dispose();
    super.dispose();
  }

  String _currentTool = 'pencil';

  bool _maskVisible = true; // 마스킹(스트로크) 표시 ON/OFF — 눈알 버튼으로 토글

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

  // 마스크 획은 AppState에 보관 → i2i 탭이 PageView에서 재생성돼도 유지된다.
  List<MaskStroke> get _strokes => _appStateRef?.i2iMaskStrokes ?? _fallbackStrokes;
  final List<MaskStroke> _fallbackStrokes = []; // _appStateRef 준비 전 안전용
  MaskStroke? _currentStroke;

  final TransformationController _transformController = TransformationController();
  final ScrollController _reelScroll = ScrollController(); // i2i 결과 릴 스크롤(위치 힌트용)
  final GlobalKey _canvasKey = GlobalKey();

  Uint8List? _lastI2iImage; // 이전 i2i 이미지 추적 (마스크 자동 초기화용)
  int _lastMaskClearRevision = 0; // 마지막으로 반영한 마스크 즉시 해제 리비전

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
        // 마스킹이 필요한 모드(인페인트/모자이크)는 연필로 시작하고,
        // 그리기가 없는 모드(img2img/업스케일)는 손으로 전환한다.
        if (mode == 'inpaint' || mode == 'mosaic') {
          if (_currentTool != 'pencil' && _currentTool != 'eraser') {
            _currentTool = 'pencil';
          }
        } else if (_currentTool == 'pencil' || _currentTool == 'eraser') {
          _currentTool = 'pan';
        }
      }),
      child: Container(
        // Expanded 안에 들어가므로 주어진 칸을 꽉 채운다 (개수와 무관하게 균등 분배)
        // 높이 22 + 마진 1.5 = 행당 25 → 2줄이어도 고정 영역(56) 안에 정확히 수납
        height: 22,
        margin: const EdgeInsets.all(1.5),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: isActive ? color.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: isActive ? color : Colors.white38),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive ? color : Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 툴바 버튼 구성 (기본 배치: 한 줄 합침 / 대체 배치: 2줄 분리) ──

  // 공통 도구: 연필/지우개(마스킹 모드만) + 돋보기/손
  List<Widget> _commonToolWidgets() {
    return [
      // 그리기 도구는 마스킹이 필요한 모드에서만 (img2img는 불필요)
      if (_i2iMode != 'img2img') ...[
        _buildToolIcon('pencil', Icons.edit, "연필 (한 번 더 누르면 크기/색상 변경)"),
        const SizedBox(width: 6),
        _buildToolIcon('eraser', Icons.cleaning_services, "지우개 (한 번 더 누르면 크기 변경)"),
        const SizedBox(width: 6),
      ],
      _buildToolIcon('zoom', Icons.zoom_in, "돋보기"),
      const SizedBox(width: 6),
      _buildToolIcon('pan', Icons.pan_tool, "손 (화면 이동)"),
    ];
  }

  // 모드 전용 도구 (강도/노이즈/픽셀/미리보기/직전이미지/마스킹표시 등)
  List<Widget> _modeToolWidgets(AppState state) {
    return [
      // img2img 전용: 강도/노이즈 + 직전 이미지
      if (_i2iMode == 'img2img') ...[
        _buildImg2ImgParamButton(state, isNoise: false),
        const SizedBox(width: 6),
        _buildImg2ImgParamButton(state, isNoise: true),
        const SizedBox(width: 6),
        _buildToolIcon(
          'view_back',
          Icons.undo,
          "탭: 직전 이미지 · 꾹: 앞으로",
          selectedOverride: false,
          onTapOverride: () {
            _appStateRef?.i2iGoBackView();
          },
          onLongPressOverride: () {
            _appStateRef?.i2iGoForwardView();
          },
        ),
      ],
      if (_i2iMode == 'inpaint') ...[
        _buildStrengthButton(state),
        const SizedBox(width: 6),
        // 직전에 본 이미지로 전환 (탭=뒤로, 꾹=앞으로)
        _buildToolIcon(
          'view_back',
          Icons.undo,
          "탭: 직전 이미지 · 꾹: 앞으로",
          selectedOverride: false,
          onTapOverride: () {
            _appStateRef?.i2iGoBackView();
          },
          onLongPressOverride: () {
            _appStateRef?.i2iGoForwardView();
          },
        ),
        const SizedBox(width: 6),
        // 마스킹 표시 ON/OFF — 옆 툴 버튼과 완전히 동일한 위젯 사용
        _buildToolIcon(
          'mask_visible',
          _maskVisible ? Icons.visibility : Icons.visibility_off,
          "마스킹 표시 켜기/끄기",
          selectedOverride: _maskVisible,
          onTapOverride: () {
            setState(() => _maskVisible = !_maskVisible);
          },
        ),
      ],
      if (_i2iMode == 'mosaic') ...[
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
              width: 44,
              height: 40,
              decoration: BoxDecoration(
                color: _mosaicPreviewImage != null
                    ? Colors.deepPurpleAccent.withValues(alpha: 0.2)
                    : Colors.transparent,
                border: Border.all(
                  color: _mosaicPreviewImage != null ? Colors.deepPurpleAccent : Colors.white24,
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
                      _mosaicPreviewImage != null ? Icons.visibility : Icons.visibility_outlined,
                      color: _mosaicPreviewImage != null ? Colors.deepPurpleAccent : Colors.white54,
                      size: 18,
                    ),
            ),
          ),
        ),
      ],
    ];
  }

  // 기본 배치용: 공통 + 모드 도구를 한 줄로 합침
  List<Widget> _classicToolbarChildren(AppState state) {
    final modeBtns = _modeToolWidgets(state);
    return [
      ..._commonToolWidgets(),
      if (modeBtns.isNotEmpty) const SizedBox(width: 6),
      ...modeBtns,
    ];
  }

  // 실행 버튼 (두 배치가 크기만 다르게 공유)
  Widget _buildExecuteButton(AppState state, {required double width, required double height}) {
    return SizedBox(
      width: width,
      height: height,
      child: ElevatedButton.icon(
        onPressed: _getExecuteOnPressed(state, context),
        icon: _getExecuteIcon(state),
        label: Text(
          _getExecuteLabel(state),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: (state.isLoading || state.isInpaintLoading || state.isUpscaleLoading)
              ? Colors.grey[700]
              : _getExecuteColor(),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  // 대체 배치 하단: 툴 2줄(좌) + 실행 버튼(우하단)
  Widget _buildAltBottomBar(AppState state) {
    // 업스케일은 도구가 없으므로 실행 버튼만 우측 정렬
    if (_i2iMode == 'upscale') {
      return Row(children: [const Spacer(), _buildExecuteButton(state, width: 140, height: 56)]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: _commonToolWidgets()),
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: _modeToolWidgets(state)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // 툴 2줄 높이(40+6+40=86)에 맞춘 큼직한 실행 버튼 — 우측 하단
        _buildExecuteButton(state, width: 132, height: 86),
      ],
    );
  }

  // 켜져 있는 모드를 배치한다. 칩들은 주어진 폭을 균등하게 나눠 가지므로
  // 모드 개수가 몇 개든 전체 영역(과 실행 버튼)의 크기는 변하지 않는다.
  //  4개 → 2×2 / 3개 → 가로 3개 / 2개 → 가로 2개 / 1개 → 크게 1개
  List<Widget> _buildModeChipRows(AppState state, {bool singleRow = false}) {
    const specs = [
      ('inpaint', '인페인트', Icons.format_paint, Color(0xFF00BFA5)),
      ('mosaic', '모자이크', Icons.grid_on, Colors.deepPurpleAccent),
      ('img2img', 'img2img', Icons.auto_fix_high, Color(0xFF3B82F6)),
      ('upscale', '업스케일', Icons.high_quality, Color(0xFFFFA000)),
    ];
    final enabled = state.enabledI2iModes;
    final active = [
      for (final s in specs)
        if (enabled.contains(s.$1)) s,
    ];
    if (active.isEmpty) {
      return [];
    }

    Widget chip((String, String, IconData, Color) s) =>
        Expanded(child: _buildModeChip(s.$1, s.$2, s.$3, s.$4));

    if (singleRow) {
      // 대체 배치: 켜진 모드 전부를 가로 한 줄로
      return [
        Row(children: [for (final s in active) chip(s)]),
      ];
    }

    if (active.length == 4) {
      // 2×2 (두 줄)
      return [
        Row(children: [chip(active[0]), chip(active[1])]),
        Row(children: [chip(active[2]), chip(active[3])]),
      ];
    }
    // 1~3개는 한 줄에 균등 분배
    return [
      Row(children: [for (final s in active) chip(s)]),
    ];
  }

  Color _getExecuteColor() {
    switch (_i2iMode) {
      case 'inpaint':
        return const Color(0xFF00BFA5);
      case 'mosaic':
        return Colors.deepPurpleAccent;
      case 'upscale':
        return Colors.amber[700]!;
      case 'img2img':
        return const Color(0xFF3B82F6); // 파랑
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
      case 'img2img':
        return "img2img 실행";
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
      case 'img2img':
        return const Icon(Icons.auto_fix_high, color: Colors.white, size: 18);
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
      case 'img2img':
        return () {
          if (state.targetI2iImage == null || state.targetI2iMetadata == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(milliseconds: 2400),
                content: Text("히스토리에서 먼저 이미지를 선택해주세요!"),
              ),
            );
            return;
          }
          state.handleImg2ImgGenerate(context);
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
        // 손 도구를 다시 누르면 배율 100% + 정 가운데로 한 번에 초기화
        setState(() {
          _transformController.value = Matrix4.identity();
        });
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
    // 업스케일/img2img 모드는 마스킹 불필요 — 입력 무시
    if (_i2iMode == 'upscale' || _i2iMode == 'img2img') {
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
      _maskVisible = true; // 칠하거나 지우면 마스킹 자동 표시
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
    // 업스케일/img2img 모드는 마스킹 불필요 — 입력 무시
    if (_i2iMode == 'upscale' || _i2iMode == 'img2img') {
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
        state.i2iMaskActionOnChange = I2iMaskAction.clearMask; // 모자이크 결과 → 마스크 초기화
        state.targetI2iImage = pngBytes;
        state.recordI2iView(pngBytes, null, reset: true); // 본 이미지 기록 새로 시작
        _strokes.clear();

        // 모자이크 결과는 메인 히스토리 대신 i2i 스크래치 릴로
        state.addI2iResult(pngBytes, null, source: 'mosaic');

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

  Widget _buildToolIcon(
    String toolId,
    IconData icon,
    String tooltip, {
    bool? selectedOverride, // 강조 여부 직접 지정 (null이면 _currentTool 기준)
    VoidCallback? onTapOverride, // 탭 동작 직접 지정 (null이면 _selectTool)
    VoidCallback? onLongPressOverride, // 꾹 누르기 동작 (선택)
  }) {
    bool isSelected =
        selectedOverride ??
        (_currentTool == toolId || (_currentTool.startsWith('zoom') && toolId == 'zoom'));

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

    // 인페인트/모자이크 공통 규격 (모자이크 기준 44×40으로 통일)
    const double btnW = 44;
    const double btnH = 40;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTapOverride ?? () => _selectTool(toolId),
        onLongPress: onLongPressOverride,
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

  // img2img 파라미터 버튼 (강도/노이즈) — 인페인트 강도 버튼과 동일 규격
  Widget _buildImg2ImgParamButton(AppState state, {required bool isNoise}) {
    final double value = isNoise ? state.img2imgNoise : state.img2imgStrength;
    final String label = isNoise ? "노이즈" : "강도";
    return Tooltip(
      message: isNoise ? "img2img 노이즈 (새 디테일 추가량)" : "img2img 강도 (원본 변형 정도)",
      child: InkWell(
        onTap: () => _showImg2ImgParamDialog(isNoise: isNoise),
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
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                value.toStringAsFixed(2),
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

  void _showImg2ImgParamDialog({required bool isNoise}) {
    final state = context.read<AppState>();
    double temp = isNoise ? state.img2imgNoise : state.img2imgStrength;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: Text(
              isNoise ? "img2img 노이즈" : "img2img 강도",
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: temp,
                  min: 0.0,
                  max: 1.0,
                  divisions: 20,
                  activeColor: const Color(0xFF3B82F6),
                  onChanged: (val) {
                    setModalState(() => temp = double.parse(val.toStringAsFixed(2)));
                  },
                ),
                Text(temp.toStringAsFixed(2), style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 8),
                Text(
                  isNoise ? "낮음 = 원본 디테일 유지  /  높음 = 새 디테일 추가" : "낮음 = 원본에 충실  /  높음 = 창의적 재해석",
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                  textAlign: TextAlign.center,
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
                  setState(() {
                    if (isNoise) {
                      state.img2imgNoise = temp;
                    } else {
                      state.img2imgStrength = temp;
                    }
                  });
                  state.saveAllSettings();
                  state.refreshUI();
                  Navigator.pop(ctx);
                },
                child: const Text("적용", style: TextStyle(color: Color(0xFF3B82F6))),
              ),
            ],
          );
        },
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
              insetPadding: PromptUtils.promptEditorDialogInsets,
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
                        style: PromptUtils.promptEditorTextStyle(state.promptEditorFontSize),
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
                                      color: isCurrent
                                          ? const Color(0xFF00E5FF) // 선택: 밝은 시안 (어두운 릴에서 확 띔)
                                          : Colors.white12,
                                      width: isCurrent ? 3.5 : 1,
                                    ),
                                    boxShadow: isCurrent
                                        ? [
                                            BoxShadow(
                                              color: const Color(0xFF00E5FF).withValues(alpha: 0.6),
                                              blurRadius: 8,
                                              spreadRadius: 1,
                                            ),
                                          ]
                                        : null,
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
                                // 생성 방식 배지 (i2i로 보낸 원본은 표시하지 않음)
                                if (r.source != 'origin')
                                  Positioned(
                                    bottom: 0,
                                    left: 0,
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                        // 밝은 이미지 위에서도 확실히 보이도록 진한 배경 + 색 테두리
                                        color: Colors.black.withValues(alpha: 0.75),
                                        borderRadius: const BorderRadius.only(
                                          bottomLeft: Radius.circular(7),
                                          topRight: Radius.circular(7),
                                        ),
                                        border: Border.all(
                                          color: _sourceColor(r.source).withValues(alpha: 0.9),
                                          width: 1,
                                        ),
                                      ),
                                      child: Icon(
                                        _sourceIcon(r.source),
                                        size: 13,
                                        color: _sourceColor(r.source),
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

  // 릴 배지: 어떤 모드로 만들어진 결과인지 (모드 칩과 같은 색/아이콘)
  IconData _sourceIcon(String source) {
    switch (source) {
      case 'mosaic':
        return Icons.grid_on;
      case 'upscale':
        return Icons.high_quality;
      case 'img2img':
        return Icons.auto_fix_high;
      case 'origin':
        return Icons.image_outlined; // i2i로 보낸 원본
      case 'inpaint':
      default:
        return Icons.format_paint;
    }
  }

  Color _sourceColor(String source) {
    switch (source) {
      case 'mosaic':
        return Colors.deepPurpleAccent;
      case 'upscale':
        return Colors.amber[700]!;
      case 'img2img':
        return const Color(0xFF3B82F6);
      case 'origin':
        return Colors.white60;
      case 'inpaint':
      default:
        return const Color(0xFF00BFA5);
    }
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

    // ※ 마스크 처리(_strokes 초기화 등)는 _handleI2iMaskChanges 리스너에서 담당한다.
    //   build에서 하면 탭 전환 등으로 인한 rebuild에 휩쓸려 엉뚱하게 마스크가 지워질 수 있음.

    // 설정에서 현재 모드를 꺼버린 경우, 켜져 있는 첫 모드로 자동 전환
    final enabledModes = state.enabledI2iModes;
    if (enabledModes.isNotEmpty && !enabledModes.contains(_i2iMode)) {
      _i2iMode = enabledModes.first;
    }

    bool canDraw =
        (_i2iMode != 'upscale' && _i2iMode != 'img2img') &&
        (_currentTool == 'pencil' || _currentTool == 'eraser');

    if (_showCanvasView) {
      // ===== 캔버스 뷰 (풀 스크린, 스크롤 없음) =====
      return _withReelOverlay(
        state,
        LayoutBuilder(
          builder: (context, _) {
            // 시스템 네비게이션 바 높이 캐싱 (최초 1회)
            _systemBottomPadding ??= MediaQuery.of(context).viewPadding.bottom;
            final bottomPad = _systemBottomPadding!;

            // 캔버스는 Expanded로 남는 공간을 자동으로 차지하므로 높이 계산이 필요 없다.
            // (모드 칩 줄 수가 바뀌어도 UI가 밀리지 않음)

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!state.i2iAltLayout)
                    // ── 기본 배치: [모드 칩 2×2 | 실행 버튼] 고정 높이 56 ──
                    // (칩이 1줄이든 2줄이든 캔버스 시작 위치가 같도록 높이 고정)
                    SizedBox(
                      height: 56,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Center(
                              child: Container(
                                // 높이 예산: 테두리2 + 패딩4 + (칩22+마진3)×2줄 = 정확히 56
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1E1E),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: _buildModeChipRows(state),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildExecuteButton(state, width: 140, height: 56),
                        ],
                      ),
                    )
                  else
                    // ── 대체 배치: 모드 칩 가로 1줄 (실행 버튼은 하단 우측으로 이동) ──
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: _buildModeChipRows(state, singleRow: true),
                      ),
                    ),
                  const SizedBox(height: 12),
                  // 캔버스: 남는 공간을 그대로 차지 (모드 칩이 1줄이든 2줄이든 자동으로 맞음)
                  // → 높이를 직접 계산하면 실제 위젯 높이와 어긋나 UI가 밀리는 문제가 생김
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF121212),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: state.isInpaintLoading ? Colors.amber : Colors.white24,
                          // 두께는 항상 동일: 로딩 때 1→2로 바뀌면 캔버스 내부가 2px 줄어
                          // 이미지가 재배치되며 마스크가 어긋나 보인다 (색만 바꾼다)
                          width: 2,
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
                                                        _i2iMode == 'img2img' ||
                                                        !_maskVisible ||
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
                  ),
                  const SizedBox(height: 12),
                  if (!state.i2iAltLayout) ...[
                    // ── 기본 배치: 툴바 한 줄 (업스케일 모드에서는 숨김) ──
                    if (_i2iMode != 'upscale') ...[
                      SizedBox(
                        height: 46,
                        child: Center(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(children: _classicToolbarChildren(state)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ] else ...[
                    // ── 대체 배치: 툴 2줄(좌) + 실행 버튼(우하단) ──
                    _buildAltBottomBar(state),
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
