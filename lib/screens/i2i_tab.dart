import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;
import '../models/app_state.dart';
import '../models/preset_models.dart' show I2iResult; // 릴 결과 — 메뉴가 결과(객체)를 받는다
import '../widgets/detail_settings_modal.dart';
import '../models/i2i_modes.dart';
import '../models/outpaint.dart'; // 확장 — 판 위 자리 · 마스크 · 판 짜기 (순수 계산)
import '../models/focus_inpaint.dart'; // 부분 인페인트 — 상자 · 계획 · 잘라 키우기 (순수 계산)
import 'prompt_edit_dialog.dart';
import '../models/model_caps.dart';
import '../models/director_tools.dart';
import '../widgets/confirm_dialog.dart';
import '../app_theme.dart';
import '../widgets/app_toast.dart';

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
      // 비교 보기가 떠 있으면 닫기 (보일 때만 — 캔버스 화면 · 그림이 있을 때. 안 보이는데 뒤로가기를 먹지 않게)
      if (_compareView && _showCanvasView && _appStateRef?.targetI2iImage != null) {
        _setCompareView(false);
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
    _fixModeIfDisabled(state);
  }

  /// 지금 모드가 설정에서 꺼졌으면 켜진 첫 모드로 바꾼다. 바꿨으면 true.
  ///  ⚠️ 예전엔 build 안에서 바꿨다 — 화면을 그리는 도중에 상태를 바꾸는 건
  ///     Flutter 가 권하지 않는 방식이라, 시작할 때와 설정이 바뀔 때(리스너) 확인한다.
  bool _fixModeIfDisabled(AppState state) {
    final enabled = state.enabledI2iModes;
    if (enabled.isEmpty || enabled.contains(_i2iMode)) {
      return false;
    }
    _i2iMode = enabled.first;
    return true;
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
      // 확장의 자리는 그림마다 — 새 그림은 처음 자리부터 (옛 그림을 붙잡고 있지 않게 비운다)
      _movePlacement = null;
      _movePlacementImage = null;
      _movePlacementKey = null;
      _moveGestureStart = null;
      _moveCrop = null; // 자르기도 그림마다
      _moveCropImage = null;
      _cropDrag = null;
      // 부분 인페인트 상자 — 같은 크기의 그림이면 그대로 둔다 (결과를 받아 같은 곳을 또 다듬기 쉽게), 크기가 다르면 비운다
      _focusDrag = null;
      _focusMulti = false;
      if (_focusBox != null && _focusBoxSize != state.i2iImageSize) {
        _focusBox = null;
        _focusBoxSize = null;
        if (_currentTool == 'focus') {
          _currentTool = 'pencil';
        }
        changed = true;
      }

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
        // 새로 보냈거나 확장의 결과(판 크기의 새 그림)가 들어왔다 — 확장을 끈다 (할 일을 마쳤다)
        //  결과는 바로 붓으로 이어서 칠할 수 있다. 릴에서 고른 그림(마스크 유지)은 켜 둔 채 처음 자리로.
        if (_moveMode) {
          _moveMode = false;
          changed = true;
        }
      }
      // 새로 보냈으면 비교 보기를 닫는다 — 기준(=보낸 원본)과 지금이 같은 그림이라 볼 게 없고 캔버스만 가린다.
      //  ('지우기' + '지금 = 기준' 은 보낼 때뿐이다. 모자이크도 지우기지만 결과가 새 그림이라 비교는 열어 둔다)
      if (_compareView &&
          state.i2iMaskActionOnChange == I2iMaskAction.clearMask &&
          identical(state.targetI2iImage, state.i2iCompareBase)) {
        _compareView = false;
        _comparePeek = false;
        changed = true;
      }
    }

    // ② 이미지는 그대로 두고 마스크만 즉시 해제 (자동 전환 OFF + 자동 해제 ON)
    if (state.i2iMaskClearRevision != _lastMaskClearRevision) {
      _lastMaskClearRevision = state.i2iMaskClearRevision;
      _strokes.clear();
      changed = true;
    }

    // ③ 설정에서 지금 모드를 껐으면 켜진 첫 모드로
    if (_fixModeIfDisabled(state)) {
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
    _compareTransform.dispose();
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

  // 지금 i2i 모드 (이름·아이콘·색은 I2iMode 에)
  I2iMode _i2iMode = I2iMode.inpaint;

  /// Director Tools 화면인지. true면 모드 칩 자리에 도구 목록이 대신 들어간다.
  ///  일반 모드(_i2iMode)와는 별개로 관리한다 — 돌아왔을 때 쓰던 모드가 그대로 남게.
  bool _directorMode = false;

  // 캔버스/프롬프트 뷰 토글
  bool _showCanvasView = true;

  // 비교 보기 — 기준 그림(보낸 원본 · 📌 고정한 그림)과 지금 그림을 나란히 (_buildCompareView)
  bool _compareView = false;
  bool _comparePeek = false; // '지금' 칸을 꾹 누르는 동안 그 자리에 기준 그림을
  // 두 칸이 하나를 같이 쓴다 → 한쪽을 확대 · 이동하면 다른 쪽도 똑같이 움직인다
  final TransformationController _compareTransform = TransformationController();

  // i2i 결과 릴 슬라이드 패널
  bool _reelOpen = false;
  static const double _reelPanelWidth = 116;
  double? _handleBottomOverride; // 드래그 중 임시 위치

  // 시스템 네비게이션 바 높이 (한 번만 계산)
  double? _systemBottomPadding;

  // 모자이크 미리보기
  Uint8List? _mosaicPreviewImage;
  bool _isPreviewLoading = false;

  // ── 확장 (인페인트 — 판 위로 그림을 옮기고 돌려 빈칸 채우기, lib/models/outpaint.dart) ──
  bool _moveMode = false; // 켜 둔 상태 (실제로는 인페인트에서만 — _moving)
  OutpaintPlacement? _movePlacement; // 옮겨 둔 자리 (null = 처음 자리)
  Uint8List? _movePlacementImage; // 그 자리를 잡은 그림 — 그림이 바뀌면 처음 자리로
  (int, int, int, int)? _movePlacementKey; // 그때의 (그림 가로, 세로, 판 가로, 세로) — 판 크기가 바뀌어도 처음 자리로
  OutpaintPlacement? _moveGestureStart; // 손가락을 댄 순간의 자리
  Offset _moveFocalStart = Offset.zero; // 그때의 손가락 가운데 (판 픽셀)
  int _outpaintOverlap = kOutpaintOverlapDefault; // 경계 — 그림 가장자리 안쪽으로 같이 다시 그릴 폭 (판 픽셀)
  bool _isOutpaintComposing = false; // 판을 짜는 중 (보내기 전 잠깐 — 실행 버튼을 잠근다)
  // 자르기 (확장 안에서 — 그림의 남길 곳만 판에 놓는다, outpaint.dart '자르기')
  bool _cropEditing = false; // 모서리 손잡이를 보이고 자르는 중 ('자르기' 버튼)
  OutpaintRect? _moveCrop; // 남길 곳 (그림 픽셀, 자르기 전 전체 기준) — null = 자르지 않음
  Uint8List? _moveCropImage; // 그 자르기를 한 그림 — 그림이 바뀌면 자르지 않은 것으로
  // 끄는 중인 손잡이와 손가락을 댄 순간의 자른 곳 · 자리 · 손가락(그림 픽셀) — 끄는 동안 이 값으로 계산해 그림이 제자리에 있다
  ({OutpaintCropHandle handle, OutpaintRect crop, OutpaintPlacement placement, double u, double v})?
  _cropDrag;

  /// 지금 확장 화면인지 — 인페인트에서만 (다른 모드 · Director 로 가면 꺼진 것처럼, 돌아오면 그대로)
  bool get _moving => _moveMode && _i2iMode == I2iMode.inpaint && !_directorMode;

  // ── 부분 인페인트 (공식 Focused Inpainting — 상자 부분만 크게 다시 그린다, lib/models/focus_inpaint.dart) ──
  //  상자가 있으면 켜진 것 — 실행이 부분 인페인트로 간다. '부분' 도구일 때 손가락으로 상자를 그리고 옮기고 늘인다.
  //  상자는 그림 픽셀로 들고 있다 (화면 크기 · 확대와 상관없게).
  OutpaintRect? _focusBox;
  (int, int)? _focusBoxSize; // 상자를 잡은 그림의 크기 — 크기가 다른 그림이 오면 비운다 (같은 크기면 결과에도 이어 쓴다)
  // 끄는 중 — 손잡이(null = 새로 그리기) · 손가락을 댄 순간의 상자 · 그때의 손가락 (그림 픽셀)
  ({OutpaintCropHandle? handle, OutpaintRect start, double u, double v})? _focusDrag;
  bool _focusMulti = false; // 이번 손가락 묶음에 두 손가락을 썼다 — 다 뗄 때까지 '옮기기' (_onFocusScaleStart)
  bool _isFocusComposing = false; // 마스크 · 잘라 키우기 준비 중 (실행 버튼 잠금)

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
        return AppColors.accent;
      case 'blur':
        return Colors.blueAccent;
      case 'line':
        return Colors.grey;
      default:
        return AppColors.accent;
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
  Widget _buildModeChip(I2iMode mode) {
    final label = mode.label;
    final icon = mode.icon;
    final color = mode.color;
    final isActive = _i2iMode == mode;
    return GestureDetector(
      onTap: () => setState(() {
        _i2iMode = mode;
        _mosaicPreviewImage = null;
        // 마스킹이 필요한 모드(인페인트/모자이크)는 연필로 시작하고,
        // 그리기가 없는 모드(img2img/업스케일)는 손으로 전환한다.
        if (mode.usesMask) {
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

  // ── 툴바 버튼 구성 (공통 도구 줄 + 모드 도구 줄, 두 줄) ──

  // 공통 도구: 연필/지우개(마스킹 모드만) + 돋보기/손
  List<Widget> _commonToolWidgets() {
    return [
      // 그리기 도구는 마스킹이 필요한 모드에서만
      //  (img2img·Director 는 이미지 전체를 그대로 보내므로 마스크가 없다)
      if (_i2iMode != I2iMode.img2img && !_directorMode) ...[
        _buildToolIcon('pencil', Icons.edit, "연필 (한 번 더 누르면 크기/색상 변경)"),
        const SizedBox(width: 6),
        _buildToolIcon('eraser', Icons.cleaning_services, "지우개 (한 번 더 누르면 크기 변경)"),
        const SizedBox(width: 6),
      ],
      _buildToolIcon('zoom', Icons.zoom_in, "돋보기"),
      const SizedBox(width: 6),
      _buildToolIcon('pan', Icons.pan_tool, "손 (화면 이동)"),
      // 부분 인페인트 — 손 오른쪽 (인페인트에서만)
      if (_i2iMode == I2iMode.inpaint && !_directorMode) ...[
        const SizedBox(width: 6),
        _buildFocusButton(),
      ],
    ];
  }

  // ============================================================================
  // 부분 인페인트 — 상자 부분만 잘라 약 1MP 로 키워 인페인트하고, 다시 그린 곳만 원본에 붙인다 (focus_inpaint.dart)
  //  · '부분' 탭: 부분 도구 (상자가 없으면 칠한 곳 둘레로 잡는다) · 한 번 더: 맥락 폭 · 꾹: 끄기
  //  · 상자 안에 칠한 곳만 다시 그린다 — 안 칠했으면 상자 안 전체 (공식과 같다). 빨간 띠(맥락)는 다시 그리지 않는다.
  //  · 결과는 원래 크기 그림 — 인페인트처럼 작업 그림 · 릴로. 같은 크기의 그림이면 상자는 남는다.
  // ============================================================================

  /// 지금 그림의 상자 — 상자를 잡은 그림과 크기가 같을 때만 (아니면 null = 꺼짐)
  OutpaintRect? _focusBoxFor(AppState state) {
    final OutpaintRect? b = _focusBox;
    return (b != null && state.targetI2iImage != null && _focusBoxSize == state.i2iImageSize) ? b : null;
  }

  // '부분' 버튼 (손 오른쪽) — 켜져 있으면 아이콘이 채워지고 맥락 폭이 보인다 (연필의 굵기처럼)
  //  탭: 켜기 · 상자 조절(부분 도구로) / 부분 도구일 때 한 번 더: 끄기 · 꾹: 맥락 폭 창.
  //  (처음엔 탭 한 번 더 = 맥락 폭 · 꾹 = 끄기였다 — 써 보니 끄기를 더 자주 써서 바꿨다. 누를 때마다 뜨던 안내 토스트도 뺐다)
  Widget _buildFocusButton() {
    return _buildToolIcon(
      'focus',
      Icons.center_focus_weak,
      "부분 인페인트 — 탭: 켜기 · 한 번 더: 끄기 · 꾹: 맥락 폭",
      onTapOverride: () {
        final AppState? st = _appStateRef;
        if (st != null) {
          _onFocusTap(st);
        }
      },
      onLongPressOverride: () {
        final AppState? st = _appStateRef;
        if (st != null) {
          _showFocusContextDialog(st);
        }
      },
    );
  }

  void _onFocusTap(AppState state) {
    // 부분 도구로 상자를 다루던 중에 한 번 더 — 끈다
    //  (붓으로 칠하던 중이면 먼저 부분 도구로 돌아온다 — 상자를 고치려고 누르는 경우가 많다)
    if (_currentTool == 'focus' && _focusBoxFor(state) != null) {
      _clearFocus();
      return;
    }
    final (int, int)? size = state.i2iImageSize;
    if (state.targetI2iImage == null || size == null) {
      showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
      return;
    }
    final bool fresh = _focusBoxFor(state) == null;
    setState(() {
      _currentTool = 'focus';
      _focusDrag = null;
      if (fresh) {
        // 칠한 곳이 있으면 그 둘레로 (맥락 띠 밖에 들게), 없으면 가운데에
        _focusBox = focusBoxAround(
          _paintedBoundsInImage(size),
          size.$1,
          size.$2,
          context: state.focusInpaintContext,
          targetPixels: state.focusTargetPixels,
        );
        _focusBoxSize = size;
      }
    });
  }

  // 부분 인페인트 끄기 (부분 도구에서 '부분' 한 번 더 · 맥락 창의 '부분 끄기') — 상자를 비우고 붓으로
  void _clearFocus() {
    setState(() {
      _focusBox = null;
      _focusBoxSize = null;
      _focusDrag = null;
      _focusMulti = false;
      if (_currentTool == 'focus') {
        _currentTool = 'pencil';
      }
    });
  }

  // 맥락 폭 ('부분' 꾹) — 공식 'Minimum Context Area'. 꺼져 있어도 열린다 (값은 설정에 남는다)
  void _showFocusContextDialog(AppState state) {
    final bool on = _focusBoxFor(state) != null;
    double temp = state.focusInpaintContext.toDouble();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text(
              "부분 인페인트 — 맥락 폭",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: temp,
                  min: 0,
                  max: kFocusContextMax.toDouble(),
                  divisions: kFocusContextMax ~/ kFocusContextStep,
                  activeColor: AppColors.accent,
                  onChanged: (v) => setModalState(() => temp = v),
                ),
                Text("${temp.round()} px", style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 8),
                const Text(
                  "상자 안쪽의 빨간 띠는 다시 그리지 않고 둘레를 보는 데만 써요.\n"
                  "넓을수록 주변과 잘 이어지고, 다시 그리는 곳은 좁아져요.\n"
                  "(크게 키운 판 기준 · 그림 끝에 닿은 쪽은 띠가 없어요)",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            actionsAlignment: on ? MainAxisAlignment.spaceBetween : MainAxisAlignment.end,
            actions: [
              if (on)
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _clearFocus();
                  },
                  icon: const Icon(Icons.close, color: Colors.redAccent, size: 18),
                  label: const Text(
                    "부분 끄기",
                    style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                  ),
                ),
              TextButton(
                onPressed: () {
                  state.focusInpaintContext = temp.round();
                  state.saveAndRefresh();
                  Navigator.pop(ctx);
                },
                child: Text(
                  "확인",
                  style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 칠한 곳의 바깥 상자 (그림 픽셀, 붓 굵기까지) — '부분' 을 켤 때 상자를 그 둘레로 잡으려고.
  ///  칠한 게 없거나 반전이 있으면(반전은 그림 전체가 칠해질 수 있다) null.
  OutpaintRect? _paintedBoundsInImage((int, int) size) {
    final renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize || renderBox.size.width <= 0 || renderBox.size.height <= 0) {
      return null;
    }
    if (_strokes.any((s) => s.isInvert)) {
      return null;
    }
    double x0 = double.infinity;
    double y0 = double.infinity;
    double x1 = double.negativeInfinity;
    double y1 = double.negativeInfinity;
    for (final s in _strokes) {
      if (s.isEraser) {
        continue;
      }
      final double r = s.size / 2;
      for (final p in s.points) {
        x0 = min(x0, p.dx - r);
        y0 = min(y0, p.dy - r);
        x1 = max(x1, p.dx + r);
        y1 = max(y1, p.dy + r);
      }
    }
    if (!x0.isFinite || !y0.isFinite || !x1.isFinite || !y1.isFinite) {
      return null;
    }
    final double kx = size.$1 / renderBox.size.width;
    final double ky = size.$2 / renderBox.size.height;
    return OutpaintRect((x0 * kx).floor(), (y0 * ky).floor(), (x1 * kx).ceil(), (y1 * ky).ceil());
  }

  /// 화면 위 한 점 → 그림 픽셀 (화면 캔버스 기준 — 확대는 globalToLocal 이 되돌린다). [k] = 그림 픽셀 ÷ 캔버스 픽셀.
  ({double u, double v, double k})? _canvasToImage(Offset global, (int, int) size) {
    final renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize || renderBox.size.width <= 0 || renderBox.size.height <= 0) {
      return null;
    }
    final Offset local = renderBox.globalToLocal(global);
    final double k = size.$1 / renderBox.size.width;
    return (u: local.dx * k, v: local.dy * size.$2 / renderBox.size.height, k: k);
  }

  // '부분' 도구로 손가락을 대면 (onScale* — 손가락 수를 알아야 해서 pan 대신)
  //  · 한 손가락: 상자의 모서리 · 변 · 안이면 그것을 끌고, 밖이면 상자를 새로 그린다
  //  · 두 손가락: 어디를 짚든 상자를 통째로 옮긴다 — 상자가 작으면 손가락 하나로는 안을 짚기 어렵다 (손잡이가 덮는다)
  //  ⚠️ 손가락 수가 바뀌면 onScaleEnd → onScaleStart 가 다시 불린다. 두 손가락을 쓴 묶음은 다 뗄 때까지 '옮기기' 로 둔다
  //     (안 그러면 한 손가락을 먼저 떼는 순간 남은 손가락 자리에서 상자를 새로 그리기 시작했다).
  void _onFocusScaleStart(ScaleStartDetails d) {
    final AppState? state = _appStateRef;
    final (int, int)? size = state?.i2iImageSize;
    if (state == null || size == null || state.targetI2iImage == null) {
      return;
    }
    final pt = _canvasToImage(d.focalPoint, size);
    if (pt == null) {
      return;
    }
    if (d.pointerCount >= 2) {
      _focusMulti = true;
    }
    final OutpaintRect? box = _focusBoxFor(state);
    OutpaintCropHandle? handle;
    if (box != null && _focusMulti) {
      handle = OutpaintCropHandle.move;
    } else if (box != null) {
      // 손가락이 닿는 범위 — 화면 28픽셀 (확대해 보고 있으면 그만큼 그림에선 좁다).
      //  상자가 작으면 변 길이의 1/4 까지만 — 손잡이가 상자 안을 다 덮어 옮길 곳이 없어지지 않게
      final double zoom = _transformController.value.getMaxScaleOnAxis();
      final double radius = min(28 * pt.k / (zoom > 0 ? zoom : 1), min(box.width, box.height) / 4);
      handle = hitOutpaintCrop(box, pt.u, pt.v, radius);
    }
    _focusDrag = (handle: handle, start: box ?? const OutpaintRect(0, 0, 0, 0), u: pt.u, v: pt.v);
  }

  void _onFocusScaleUpdate(ScaleUpdateDetails d) {
    final drag = _focusDrag;
    final (int, int)? size = _appStateRef?.i2iImageSize;
    if (drag == null || size == null) {
      return;
    }
    final pt = _canvasToImage(d.focalPoint, size);
    if (pt == null) {
      return;
    }
    final OutpaintCropHandle? h = drag.handle;
    final OutpaintRect next = h == null
        ? focusBoxFromPoints(drag.u, drag.v, pt.u, pt.v, size.$1, size.$2)
        : dragFocusBox(drag.start, h, pt.u - drag.u, pt.v - drag.v, size.$1, size.$2);
    if (next == _focusBox) {
      return;
    }
    setState(() {
      _focusBox = next;
      _focusBoxSize = size;
    });
  }

  void _onFocusScaleEnd(ScaleEndDetails d) {
    _focusDrag = null;
    if (d.pointerCount == 0) {
      _focusMulti = false; // 손가락을 다 뗐다 — 다음엔 다시 한 손가락 규칙으로
    }
  }

  /// 부분 인페인트 마스크 — 잘라 키운 판(보낼 크기)에 획을 옮겨 칠하고, 다시 그릴 곳 밖은 지운다 (_buildFocusMaskRaw).
  Future<({Uint8List raw, bool painted})?> _captureFocusMask(FocusPlan plan) async {
    final renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize || renderBox.size.width <= 0 || renderBox.size.height <= 0) {
      return null;
    }
    // 캔버스 픽셀 → 그림 픽셀 → 잘라 키운 판 픽셀
    final double kx = plan.imageW / renderBox.size.width;
    final double ky = plan.imageH / renderBox.size.height;
    final double sx = plan.scaleX;
    final double sy = plan.scaleY;
    final int ox = plan.crop.x0;
    final int oy = plan.crop.y0;
    final strokeData = _strokes.map((stroke) {
      final pts = <double>[];
      for (final p in stroke.points) {
        pts.add((p.dx * kx - ox) * sx);
        pts.add((p.dy * ky - oy) * sy);
      }
      return _MaskStrokeData(pts, stroke.size * kx * sx / 2, stroke.isEraser, stroke.isInvert);
    }).toList();
    return compute(_buildFocusMaskRaw, _FocusMaskParams(plan.sendW, plan.sendH, strokeData, plan.interior));
  }

  /// 부분 인페인트 실행 — 상자 부분의 마스크를 만들고(칠한 곳 · 비었으면 상자 안 전체), 잘라 키워 보낸다.
  ///  결과는 AppState 가 줄여 원본의 다시 그린 칸에만 붙인다 (handleFocusInpaintGenerate).
  Future<void> _runFocusInpaint(AppState state) async {
    // 누른 순간의 그림 · 계획으로 — 확인 창 · 준비 사이에 그림이 바뀌어도 이 그림에 (DEVNOTES 5)
    final Uint8List? image = state.targetI2iImage;
    final OutpaintRect? box = _focusBoxFor(state);
    final FocusPlan? plan = box == null ? null : state.focusPlanFor(box);
    if (image == null || plan == null) {
      showToast(context, image == null ? "히스토리에서 먼저 이미지를 선택해주세요!" : "이미지 크기를 읽지 못했습니다.");
      return;
    }
    setState(() => _isFocusComposing = true);
    try {
      final mask = await _captureFocusMask(plan);
      if (!mounted) {
        return;
      }
      if (mask == null) {
        showToast(context, "마스크를 만들지 못했어요.");
        return;
      }
      // 칠한 곳이 상자 밖에만 있다 — 상자 안 전체를 다시 그릴지 묻는다
      //  (아무것도 안 칠했으면 묻지 않고 상자 안 전체 — 공식과 같다)
      if (!mask.painted && _strokes.any((s) => !s.isEraser)) {
        final bool whole = await showConfirmDialog(
          context,
          title: "상자 안에 칠한 곳이 없어요",
          message:
              "칠한 곳이 상자 밖에만 있어요.\n\n"
              "상자 안 전체(빨간 띠 안쪽)를 다시 그릴까요?\n"
              "(상자 밖에 칠한 곳은 이번엔 쓰지 않아요)",
          confirmLabel: "상자 안 전체",
          icon: Icons.center_focus_strong,
          iconColor: AppColors.teal,
          destructive: false,
          confirmColor: AppColors.teal,
        );
        if (!whole || !mounted) {
          return;
        }
      }
      if (!await _confirmAnlas(state, AnlasJob.inpaint, "부분 인페인트", cost: state.focusAnlas(plan))) {
        return;
      }
      if (!mounted) {
        return;
      }
      Uint8List? crop;
      try {
        crop = await compute(composeFocusCrop, (image: image, plan: plan));
      } catch (e) {
        debugPrint("부분 인페인트 잘라 키우기 실패: $e");
        crop = null;
      }
      if (!mounted) {
        return;
      }
      if (crop == null) {
        showToast(context, "그림을 읽지 못했어요.");
        return;
      }
      await state.handleFocusInpaintGenerate(
        context,
        original: image,
        crop: crop,
        mask: mask.raw,
        plan: plan,
      );
    } finally {
      if (mounted) {
        setState(() => _isFocusComposing = false);
      }
    }
  }

  // 최근 결과를 바로 폴더에 저장 (릴에서 꾹 누르지 않아도 되게)
  // 모드 도구 줄의 마지막에 배치해 두 줄이 4개씩 나란히 오도록 한다.
  Widget _saveResultButton() {
    return _buildToolIcon(
      'save_result',
      Icons.save_alt,
      "최근 결과 저장",
      selectedOverride: false,
      onTapOverride: () {
        final st = _appStateRef;
        if (st == null || st.i2iResults.isEmpty) {
          showToast(context, "저장할 결과가 없습니다.");
          return;
        }
        // 릴의 마지막 항목이 가장 최근 결과
        st.saveI2iToFolder(st.i2iResults.last, context);
      },
    );
  }

  // 모드 전용 도구 (강도/노이즈/픽셀/미리보기/직전이미지/마스킹표시 등)
  List<Widget> _modeToolWidgets(AppState state) {
    return [
      // img2img 전용: 강도/노이즈 + 직전 이미지
      if (_i2iMode == I2iMode.img2img) ...[
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
      // Director 화면에서는 도구를 칩으로 고르므로 툴바에 따로 둘 게 없다.
      //  직전 이미지 되돌리기만 남긴다.
      if (_directorMode) ...[
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
      if (!_directorMode && _i2iMode == I2iMode.inpaint) ...[
        // 확장 중엔 강도 대신 회전 (확장은 늘 강도 1 — kOutpaintStrength)
        _moving ? _buildRotateButton(state) : _buildStrengthButton(state),
        const SizedBox(width: 6),
        // 직전에 본 이미지로 전환 (탭=뒤로, 꾹=앞으로) — 확장 중엔 그 자리에 자르기
        _moving
            ? _buildCropButton(state)
            : _buildToolIcon(
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
          _moving ? "새로 그릴 곳 표시 켜기/끄기" : "마스킹 표시 켜기/끄기",
          selectedOverride: _maskVisible,
          onTapOverride: () {
            setState(() => _maskVisible = !_maskVisible);
          },
        ),
      ],
      if (_i2iMode == I2iMode.mosaic) ...[
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
                    ? AppColors.accent.withValues(alpha: 0.2)
                    : Colors.transparent,
                border: Border.all(
                  color: _mosaicPreviewImage != null ? AppColors.accent : Colors.white24,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _isPreviewLoading
                  ? Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2),
                    )
                  : Icon(
                      _mosaicPreviewImage != null ? Icons.visibility : Icons.visibility_outlined,
                      color: _mosaicPreviewImage != null ? AppColors.accent : Colors.white54,
                      size: 18,
                    ),
            ),
          ),
        ),
      ],
      // 모드 도구 줄 마지막에 저장 버튼 (두 줄이 4개씩 맞춰지도록)
      const SizedBox(width: 6),
      _saveResultButton(),
    ];
  }

  // 실행 버튼 (두 배치가 크기만 다르게 공유)
  Widget _buildExecuteButton(AppState state, {required double width, required double height}) {
    final bool busy =
        state.isLoading ||
        state.isInpaintLoading ||
        state.isUpscaleLoading ||
        state.isDirectorLoading;
    // Anlas 확인 창을 껐으면 Anlas 가 드는 실행에 빨간 테두리 (AppState.anlasMarked — 창 대신 알린다)
    final bool marked = !busy && state.anlasMarked(_executeCost(state));
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
          backgroundColor: busy ? Colors.grey[700] : _getExecuteColor(),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: marked ? const BorderSide(color: AppColors.red, width: 2.5) : null,
        ),
      ),
    );
  }

  /// 지금 실행 버튼이 쓸 Anlas 추정 — 빨간 테두리(AppState.anlasMarked)용. 확인 창(_confirmAnlas)과 같은 값을 본다.
  ///  그림이 없으면 0 (누르면 '먼저 고르라' 고만 한다). 모자이크는 기기에서 하므로 0.
  int _executeCost(AppState state) {
    if (state.targetI2iImage == null) {
      return 0;
    }
    if (_directorMode) {
      return state.anlasFor(AnlasJob.director);
    }
    switch (_i2iMode) {
      case I2iMode.inpaint:
        if (_moving) {
          return state.outpaintAnlas;
        }
        // 부분 인페인트는 보낼 크기(약 1MP)로 — 큰 그림이어도 Opus 는 대개 무료
        final OutpaintRect? focusBox = _focusBoxFor(state);
        final FocusPlan? focus = focusBox == null ? null : state.focusPlanFor(focusBox);
        return focus != null ? state.focusAnlas(focus) : state.anlasFor(AnlasJob.inpaint);
      case I2iMode.img2img:
        return state.anlasFor(AnlasJob.img2img);
      case I2iMode.upscale:
        return state.anlasFor(AnlasJob.upscale);
      case I2iMode.mosaic:
        return 0;
    }
  }

  // 하단: 도구 2줄(왼쪽) + 실행 버튼(오른쪽)
  Widget _buildBottomBar(AppState state) {
    // 업스케일은 그리는 도구가 필요 없어 '저장'만 왼쪽에 둔다 (다른 모드와 같은 자리)
    if (_i2iMode == I2iMode.upscale) {
      return Row(
        children: [
          _saveResultButton(),
          const Spacer(),
          _buildExecuteButton(state, width: 140, height: 56),
        ],
      );
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
                // 확장 중엔 붓 · 돋보기 · 손 대신 자리 도구 (손가락으로 바로 옮기므로)
                child: Row(children: _moving ? _moveToolWidgets(state) : _commonToolWidgets()),
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
        //  폭 122 — 인페인트 첫 줄이 다섯 칸(… 손 · 부분)이 되며 132 에선 마지막 칸이 살짝 가려졌다 (도구 칸은 그대로 두고 여기만 줄였다)
        _buildExecuteButton(state, width: 122, height: 86),
      ],
    );
  }

  // 켜져 있는 모드를 배치한다. 칩들은 주어진 폭을 균등하게 나눠 가지므로
  // 모드 개수가 몇 개든 전체 영역(과 실행 버튼)의 크기는 변하지 않는다.
  List<Widget> _buildModeChipRows(AppState state) {
    // 모델이 지원하지 않는 모드는 아예 내보내지 않는다.
    //  (지금 쓰는 V4/V4.5/V5는 셋 다 지원하므로 화면 변화는 없다.
    //   미지원 모델이 추가될 때 이 한 곳만 보면 되도록 캡으로 연결해 둔다.)
    final caps = modelCapsFor(state.selectedModel);
    // 이름·아이콘·색·지원 여부는 I2iMode 한 곳에 있다 (lib/models/i2i_modes.dart)
    final active = [
      for (final m in state.enabledI2iModes)
        if (m.supportedBy(caps)) m,
    ];
    if (active.isEmpty) {
      return [];
    }
    // 켜진 모드 전부를 가로 한 줄로
    return [
      Row(children: [for (final m in active) Expanded(child: _buildModeChip(m))]),
    ];
  }

  Color _getExecuteColor() => _i2iMode.color;

  String _getExecuteLabel(AppState state) {
    final bool anyLoading =
        state.isLoading ||
        state.isInpaintLoading ||
        state.isUpscaleLoading ||
        state.isDirectorLoading;
    if (anyLoading) return "생성중...";
    if (_directorMode) {
      return "${directorToolFor(state.directorTool).label} 실행";
    }
    // 모자이크만 '적용', 나머지는 '<이름> 실행'
    if (_i2iMode == I2iMode.mosaic) {
      return _isMosaicProcessing ? "처리중..." : "모자이크 적용";
    }
    if (_moving) {
      return _isOutpaintComposing ? "준비중..." : "확장 실행";
    }
    if (_i2iMode == I2iMode.inpaint && _focusBoxFor(state) != null) {
      return _isFocusComposing ? "준비중..." : "부분 인페인트";
    }
    return "${_i2iMode.label} 실행";
  }

  Widget _getExecuteIcon(AppState state) {
    bool isLoading =
        state.isLoading ||
        state.isInpaintLoading ||
        state.isUpscaleLoading ||
        state.isDirectorLoading ||
        (_i2iMode == I2iMode.mosaic && _isMosaicProcessing) ||
        (_moving && _isOutpaintComposing) ||
        (_i2iMode == I2iMode.inpaint && _isFocusComposing);
    if (isLoading) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    }
    final bool focusing = !_moving && _i2iMode == I2iMode.inpaint && _focusBoxFor(state) != null;
    return Icon(
      _moving ? Icons.zoom_out_map : (focusing ? Icons.center_focus_strong : _i2iMode.icon),
      color: Colors.white,
      size: 18,
    );
  }

  /// 작업 실행 전 Anlas 안내. 진행해도 되면 true.
  ///  소모가 없으면(0) 묻지 않고 바로 통과시킨다.
  ///  비용 계산과 문구 만들기는 모두 AppState 가 담당한다.
  /// 실행 전 확인 — 저장 폴더(없으면 고르게) → Anlas 비용. 둘 다 통과해야 true.
  ///  [cost] 를 주면 [job] 대신 그 값으로 안내한다 (확장 — 판 크기 · 강도 1 로 센다).
  Future<bool> _confirmAnlas(
    AppState state,
    AnlasJob job,
    String label, {
    String? extra,
    int? cost,
  }) async {
    // 생성한 그림은 저장 폴더에만 둔다 (AppState.ensureSaveFolder) — 비용 확인보다 먼저
    if (!await state.ensureSaveFolder(context) || !mounted) {
      return false;
    }
    final c = cost ?? state.anlasFor(job);
    // 확인 창을 껐으면(설정 — skipAnlasConfirm) 묻지 않는다 — 실행 버튼의 빨간 테두리가 대신 알린다
    if (c == 0 || state.skipAnlasConfirm) {
      return true;
    }
    final body = [
      "$label을(를) 실행합니다.",
      AppState.anlasText(c),
      // null-aware 원소 — extra 가 null 이면 이 줄은 목록에서 빠진다
      ?extra,
      "",
      "계속 진행할까요?",
    ].join("\n");
    return showConfirmDialog(
      context,
      title: "포인트 소모 안내",
      message: body,
      confirmLabel: "실행",
      icon: Icons.warning_amber_rounded,
      iconColor: AppColors.amber,
      confirmColor: AppColors.purple,
    );
  }

  VoidCallback? _getExecuteOnPressed(AppState state, BuildContext context) {
    // Director 화면은 _i2iMode 와 무관하게 도구를 실행한다
    if (_directorMode) {
      if (state.isDirectorLoading) {
        return null; // 도는 중엔 잠근다 (배경 제거는 느려서 연타하기 쉽다)
      }
      return () async {
        if (state.targetI2iImage == null) {
          showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
          return;
        }
        final tool = directorToolFor(state.directorTool);
        final ok = await _confirmAnlas(
          state,
          AnlasJob.director,
          tool.label,
          extra: tool.multiResult ? "결과가 3장 만들어져 비용이 더 큽니다." : null,
        );
        // ⚠️ mounted(State) 가 아니라 context.mounted 로 검사해야 한다.
        //    이 context 는 build 에서 받은 파라미터이기 때문이다.
        if (!ok || !context.mounted) {
          return;
        }
        state.handleDirectorTool(context);
      };
    }
    // 어떤 생성이든 진행 중이면 전부 비활성화
    if (state.isLoading ||
        state.isInpaintLoading ||
        state.isUpscaleLoading ||
        state.isDirectorLoading) {
      return null;
    }

    switch (_i2iMode) {
      case I2iMode.inpaint:
        // 확장 — 판을 짜서 빈칸을 채운다 (_runOutpaint)
        if (_moving) {
          return _isOutpaintComposing ? null : () => _runOutpaint(state);
        }
        // 부분 인페인트 — 상자가 있으면 (_runFocusInpaint)
        if (_focusBoxFor(state) != null) {
          return _isFocusComposing ? null : () => _runFocusInpaint(state);
        }
        return () async {
          if (state.targetI2iImage == null) {
            showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
            return;
          }
          // 보낼 크기 — 그림 정보가 없는 그림(밖에서 가져온 그림)도 여기서 정해진다
          //  ⚠️ 예전엔 그림 정보가 없으면 '히스토리에서 선택하라'며 막았다.
          if (state.i2iSendPlan == null) {
            showToast(context, "이미지 크기를 읽지 못했습니다.");
            return;
          }
          if (_strokes.isEmpty) {
            showToast(context, "마스크를 그려주세요! 🖍️");
            return;
          }
          if (!await _confirmAnlas(state, AnlasJob.inpaint, "인페인트")) {
            return;
          }
          if (!context.mounted) {
            return;
          }
          // 마스크도 보낼 그림과 똑같이 — 보낼 크기 판에, 그림 자리(왼쪽 위 w×h)에만 칠한다.
          //  (파이프라인이 같은 계획으로 그림을 채워 보내므로 칠한 자리가 정확히 겹친다)
          final plan = state.i2iSendPlan;
          if (plan == null) {
            return;
          }
          final maskBytes = await _captureMask(plan.sendW, plan.sendH, plan.w, plan.h);
          if (maskBytes != null && context.mounted) {
            state.handleInpaintGenerate(context, maskBytes);
          }
        };
      case I2iMode.mosaic:
        if (_isMosaicProcessing) return null;
        return () => _applyMosaic(state);
      case I2iMode.upscale:
        return () async {
          if (state.targetI2iImage == null) {
            showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
            return;
          }
          // 저장 폴더 먼저 (비용 확인 창은 handleUpscaleGenerate 안에서 뜬다)
          if (!await state.ensureSaveFolder(context) || !context.mounted) {
            return;
          }
          state.handleUpscaleGenerate(context);
        };
      case I2iMode.img2img:
        return () async {
          if (state.targetI2iImage == null) {
            showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
            return;
          }
          if (state.i2iSendSize == null) {
            showToast(context, "이미지 크기를 읽지 못했습니다.");
            return;
          }
          if (!await _confirmAnlas(state, AnlasJob.img2img, I2iMode.img2img.label)) {
            return;
          }
          if (!context.mounted) {
            return;
          }
          state.handleImg2ImgGenerate(context);
        };
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
            backgroundColor: AppColors.surface,
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
                  activeColor: AppColors.accent,
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
            // 왼쪽: 지우개는 '전체 지우기', 브러시는 '마스킹 반전' · 오른쪽: 확인
            actionsAlignment: MainAxisAlignment.spaceBetween,
            actions: [
              if (tool == 'pencil')
                TextButton.icon(
                  onPressed: () {
                    _invertMask();
                    Navigator.pop(ctx);
                  },
                  icon: Icon(Icons.invert_colors, color: _maskColor, size: 18),
                  label: Text(
                    "마스킹 반전",
                    style: TextStyle(color: _maskColor, fontWeight: FontWeight.bold),
                  ),
                ),
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
                child: Text(
                  "확인",
                  style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // 마스킹 반전 (브러시 설정 창) — 칠한 곳 ↔ 안 칠한 곳 (그림 전체 기준).
  //  획을 고치지 않고 '뒤집기' 표시를 하나 더한다 (MaskStroke.invert) — 화면 · 보내는 마스크 · 모자이크가 같은 순서로 따른다.
  //  아무것도 안 칠했으면 그림 전체가 칠해진다. 바로 앞도 반전이면 둘이 상쇄되니 그것을 빼기만 한다.
  void _invertMask() {
    setState(() {
      if (_strokes.isNotEmpty && _strokes.last.isInvert) {
        _strokes.removeLast();
      } else {
        _strokes.add(MaskStroke.invert());
      }
      _maskVisible = true; // 뒤집은 결과가 보이게
      _mosaicPreviewImage = null; // 마스크가 바뀌었다 → 미리보기 초기화
    });
  }

  void _onPanStart(DragStartDetails details) {
    // 업스케일/img2img 모드는 마스킹 불필요 — 입력 무시
    if (!_i2iMode.usesMask) {
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
    if (!_i2iMode.usesMask) {
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

  /// 마스크를 [maskW]×[maskH](보낼 크기) 판에 만든다. 화면의 그림은 판의 왼쪽 위
  ///  [imageW]×[imageH] 자리에 대응한다 — 나머지(채워 보내는 오른쪽·아래)는 칠하지 않는다.
  Future<Uint8List?> _captureMask(int maskW, int maskH, int imageW, int imageH) async {
    final renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;

    // V4.5 풀 해상도 마스크 — 화면 좌표 → 그림 좌표
    final double scaleX = imageW / renderBox.size.width;
    final double scaleY = imageH / renderBox.size.height;

    // 메인 스레드: 스트로크를 마스크 좌표로 변환해 직렬화 (가벼움)
    final strokeData = _strokes.map((stroke) {
      final r = stroke.size * scaleX / 2;
      final pts = <double>[];
      for (final p in stroke.points) {
        pts.add(p.dx * scaleX);
        pts.add(p.dy * scaleY);
      }
      return _MaskStrokeData(pts, r, stroke.isEraser, stroke.isInvert);
    }).toList();

    // 무거운 grid 빌드 + raw 생성(~수백만 회 루프)은 백그라운드 isolate에서
    // (UI 스레드 멈춤 방지 — 인페인트 시작 시 렉의 원인이었음)
    return compute(_buildMaskRaw, _MaskBuildParams(maskW, maskH, strokeData, imageW, imageH));
  }

  // ============================================================================
  // 확장 — 지금 그림을 판(상세 환경의 해상도) 위로 옮기고 키우고 줄이고 돌린 뒤,
  //  빈칸을 인페인트로 채운다 (사실상 아웃페인트 — NovelAI 웹의 '캔버스 크기 바꾸기'와 같은 방식).
  //  · 자리 · 마스크 · 판 짜기 계산은 전부 lib/models/outpaint.dart (화면과 보내기가 같은 값을 쓴다)
  //  · 붓으로 칠해 둔 마스크는 쓰지 않고 그대로 둔다 — 끄면 다시 보인다 (빈칸 + 경계가 저절로 마스크)
  //  · 비교 보기와는 하나만 켜진다 (_toggleMoveMode · _setCompareView)
  // ============================================================================

  /// 확장에 필요한 것 — 그림이 없거나 크기를 못 읽으면 null.
  ///  [iw] · [ih] 는 '자른 그림' 의 크기 (자리 계산은 전부 이것으로), [fw] · [fh] 는 자르기 전 그림 전체, [crop] 은 남길 곳.
  _MoveInputs? _moveInputs(AppState state) {
    final Uint8List? image = state.targetI2iImage;
    final (int, int)? size = state.i2iImageSize;
    if (image == null || size == null || size.$1 <= 0 || size.$2 <= 0) {
      return null;
    }
    final (int cw, int ch) = state.outpaintCanvasSize;
    final OutpaintRect crop = _cropFor(image, size.$1, size.$2);
    return (
      image: image,
      iw: crop.width,
      ih: crop.height,
      fw: size.$1,
      fh: size.$2,
      crop: crop,
      cw: cw,
      ch: ch,
    );
  }

  /// 지금 쓸 자른 곳 — 같은 그림에서 잘라 둔 곳이 그림 안이면 그것, 아니면 그림 전체
  OutpaintRect _cropFor(Uint8List image, int fw, int fh) {
    final OutpaintRect? c = _moveCrop;
    if (c != null &&
        identical(_moveCropImage, image) &&
        !c.isEmpty &&
        c.x0 >= 0 &&
        c.y0 >= 0 &&
        c.x1 <= fw &&
        c.y1 <= fh) {
      return c;
    }
    return outpaintFullCrop(fw, fh);
  }

  /// 자른 곳을 [crop] 으로 — 그림은 판에서 제자리에 둔다 ([from] 은 그때의 자리, [fromCrop] 은 그때의 자른 곳).
  ///  [clamp] 면 범위 안으로도 (다 끈 뒤 · 취소 — 끄는 동안엔 그림이 튀지 않게 하지 않는다).
  void _setCrop(
    _MoveInputs m,
    OutpaintPlacement from,
    OutpaintRect fromCrop,
    OutpaintRect crop, {
    bool clamp = false,
  }) {
    OutpaintPlacement p = outpaintRecenterForCrop(from, fromCrop, crop);
    if (clamp) {
      p = clampOutpaintPlacement(p, crop.width, crop.height, m.cw, m.ch);
    }
    setState(() {
      _moveCrop = crop;
      _moveCropImage = m.image;
      _movePlacement = p;
      _movePlacementImage = m.image;
      _movePlacementKey = (crop.width, crop.height, m.cw, m.ch);
    });
  }

  // 자르기 켜기 · 끝내기 (확장 중 '자르기' 버튼 탭). 끝낼 때 자리를 범위 안으로.
  void _toggleCropEditing(AppState state) {
    final m = _moveInputs(state);
    if (m == null) {
      showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
      return;
    }
    if (_cropEditing) {
      final p = _placementFor(m.image, m.iw, m.ih, m.cw, m.ch);
      _setPlacement(
        clampOutpaintPlacement(p, m.iw, m.ih, m.cw, m.ch),
        m.image,
        m.iw,
        m.ih,
        m.cw,
        m.ch,
      );
    }
    setState(() {
      _cropEditing = !_cropEditing;
      _cropDrag = null;
    });
  }

  // 자르기 취소 (확장 중 '자르기' 꾹) — 그림 전체로, 그림은 제자리에서 다시 넓어진다
  void _resetCrop(AppState state) {
    final m = _moveInputs(state);
    if (m == null) {
      return;
    }
    if (m.iw == m.fw && m.ih == m.fh) {
      showToast(context, "자른 곳이 없어요.");
      return;
    }
    final p = _placementFor(m.image, m.iw, m.ih, m.cw, m.ch);
    _setCrop(m, p, m.crop, outpaintFullCrop(m.fw, m.fh), clamp: true); // 그림이 다시 넓어져 보이므로 알리지 않는다
  }

  // 확장 중 '직전 이미지' 자리의 자르기 — 탭: 모서리 손잡이로 남길 곳 고르기 / 끝내기 · 꾹: 자르기 취소
  //  (확장 중엔 그림을 바꿀 일이 드물어 그 자리를 빌린다 — 확장을 끄면 '직전 이미지' 가 돌아온다)
  Widget _buildCropButton(AppState state) {
    return _buildToolIcon(
      'move_crop',
      Icons.crop,
      "자르기 — 탭: 모서리 · 변을 끌어 남길 곳 고르기 / 끝내기 · 꾹: 자르기 취소",
      selectedOverride: _cropEditing,
      onTapOverride: () => _toggleCropEditing(state),
      onLongPressOverride: () => _resetCrop(state),
    );
  }

  /// 지금 쓸 자리 — 같은 그림 · 같은 판 크기에서 옮겨 둔 자리가 있으면 그것, 아니면 처음 자리.
  ///  (그리기 중에 불려도 되게 값만 읽는다 — 바꾸는 건 _setPlacement)
  OutpaintPlacement _placementFor(Uint8List image, int iw, int ih, int cw, int ch) {
    final OutpaintPlacement? p = _movePlacement;
    if (p != null && identical(_movePlacementImage, image) && _movePlacementKey == (iw, ih, cw, ch)) {
      return p;
    }
    return outpaintInitial(iw, ih, cw, ch);
  }

  void _setPlacement(OutpaintPlacement p, Uint8List image, int iw, int ih, int cw, int ch) {
    setState(() {
      _movePlacement = p;
      _movePlacementImage = image;
      _movePlacementKey = (iw, ih, cw, ch);
    });
  }

  /// 지금 자리를 [change] 로 바꾼다 (맞춤 · 원래 크기 · 90° 돌리기 버튼)
  void _changePlacement(
    AppState state,
    OutpaintPlacement Function(OutpaintPlacement p, int iw, int ih, int cw, int ch) change,
  ) {
    final m = _moveInputs(state);
    if (m == null) {
      showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
      return;
    }
    final p = _placementFor(m.image, m.iw, m.ih, m.cw, m.ch);
    _setPlacement(change(p, m.iw, m.ih, m.cw, m.ch), m.image, m.iw, m.ih, m.cw, m.ch);
  }

  // 확장 켜기 · 끄기 (캔버스 맨 아래 줄의 '확장'). 켜면 비교 보기는 닫는다 — 둘 중 하나만.
  void _toggleMoveMode(AppState state) {
    if (!_moveMode && state.targetI2iImage == null) {
      showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
      return;
    }
    setState(() {
      _moveMode = !_moveMode;
      _moveGestureStart = null;
      _cropEditing = false; // 다시 켜면 자르기 손잡이 없이 (자른 곳은 그대로 남는다)
      _cropDrag = null;
      if (_moveMode) {
        _compareView = false;
        _comparePeek = false;
      }
    });
  }

  // 확장 중 첫 줄 도구 — 맞춤 · 원래 크기 · 상세(판 크기) · 경계
  List<Widget> _moveToolWidgets(AppState state) {
    return [
      // 맞춤 · 원래 크기는 돌려 둔 각도를 그대로 두고 크기 · 자리만 (반듯하게는 두 번 탭)
      _buildToolIcon(
        'move_fit',
        Icons.fit_screen,
        "맞춤 (그림 전체가 판에 들어가게 · 가운데)",
        selectedOverride: false,
        onTapOverride: () => _changePlacement(
          state,
          (p, iw, ih, cw, ch) => outpaintFit(iw, ih, cw, ch, angle: p.angle),
        ),
      ),
      const SizedBox(width: 6),
      _valueButton(
        tooltip: "원래 크기 (그림 픽셀 그대로 · 가운데)",
        label: "원래",
        value: "1:1",
        onTap: () => _changePlacement(
          state,
          (p, iw, ih, cw, ch) => outpaintOriginal(iw, ih, cw, ch, angle: p.angle),
        ),
      ),
      const SizedBox(width: 6),
      // 판 크기는 상세 환경의 해상도 × 배율 — 여기서 바로 바꾼다 (닫으면 판이 따라 바뀐다)
      _valueButton(
        tooltip: "상세 환경 — 판 크기(해상도 · 배율) 바꾸기",
        label: "상세",
        onTap: () => showDetailSettingsModal(context),
      ),
      const SizedBox(width: 6),
      // 경계 — 누를 때마다 0 → 8 → 16 → 32 → 64 px. 새로 그릴 곳을 바로 보여 줘 그림 테두리 띠가 바뀌는 게 보인다
      _valueButton(
        tooltip: "경계 — 그림 가장자리 안쪽도 이만큼 같이 다시 그려 이음매를 감춘다 (누를 때마다 바뀜)",
        label: "경계",
        value: "$_outpaintOverlap",
        onTap: () => setState(() {
          _outpaintOverlap = nextOutpaintOverlap(_outpaintOverlap);
          _maskVisible = true;
        }),
        valueSize: 9,
      ),
    ];
  }

  // 확장 중 강도 자리의 회전 버튼 — 탭: 시계 방향 90° · 꾹: 반듯하게(0°). 두 손가락으로 비틀어도 돈다.
  Widget _buildRotateButton(AppState state) {
    final m = _moveInputs(state);
    final int deg = m == null
        ? 0
        : outpaintAngleDegrees(_placementFor(m.image, m.iw, m.ih, m.cw, m.ch).angle);
    return _valueButton(
      tooltip: "회전 — 탭: 90° 돌리기 · 꾹: 반듯하게 (두 손가락으로 비틀어도 돌아요)",
      label: "회전",
      value: "$deg°",
      onTap: () => _changePlacement(state, rotateOutpaintPlacement90),
      onLongPress: () => _changePlacement(
        state,
        (p, iw, ih, cw, ch) => clampOutpaintPlacement(
          OutpaintPlacement(cx: p.cx, cy: p.cy, scale: p.scale),
          iw,
          ih,
          cw,
          ch,
        ),
      ),
      valueSize: 9,
    );
  }

  /// 확장의 실행 — 판을 짜서(그림 + 흐린 빈칸 + 마스크) 인페인트로 보낸다.
  Future<void> _runOutpaint(AppState state) async {
    final m = _moveInputs(state);
    if (m == null) {
      showToast(
        context,
        state.targetI2iImage == null ? "히스토리에서 먼저 이미지를 선택해주세요!" : "이미지 크기를 읽지 못했습니다.",
      );
      return;
    }
    // 화면에 보이는 그대로 — 자리 · 경계 · 그림 정보를 누른 순간 것으로 잡아 둔다
    final OutpaintPlacement p = _placementFor(m.image, m.iw, m.ih, m.cw, m.ch);
    final int overlap = _outpaintOverlap;
    final srcMeta = state.targetI2iMetadata;
    if (outpaintNothingToFill(p, m.iw, m.ih, m.cw, m.ch)) {
      // 그림이 판을 다 덮었다 — 채울 게 없으니, 이 모양 그대로 작업 그림으로 쓸지 묻는다
      //  (그림의 한 부분만 잘라 키워 두고 붓으로 인페인트하고 싶을 때)
      await _offerBakeOutpaint(state, m, p);
      return;
    }
    if (outpaintKeepRects(p, m.iw, m.ih, m.cw, m.ch, overlap).isEmpty) {
      showToast(context, "그림이 너무 작아 남길 곳이 없어요. 조금 키우거나 경계를 줄여 주세요!");
      return;
    }
    if (!await _confirmAnlas(state, AnlasJob.inpaint, "확장", cost: state.outpaintAnlas)) {
      return;
    }
    if (!mounted) {
      return;
    }
    final OutpaintCanvas? canvas = await _composeCanvas(m, p, overlap);
    if (!mounted) {
      return;
    }
    if (canvas == null) {
      showToast(context, "그림을 읽지 못했어요.");
      return;
    }
    // 이번 배치를 남긴다 — 결과가 마음에 안 들면 '확장' 꾹으로 그대로 다시 놓는다 (_restoreLastOutpaint)
    state.lastOutpaint = (
      image: m.image,
      meta: srcMeta,
      placement: p,
      crop: m.crop,
      overlap: overlap,
      canvasW: m.cw,
      canvasH: m.ch,
    );
    // 결과가 작업 그림으로 바뀌면(자동 전환) 확장은 리스너가 끈다 (_handleI2iMaskChanges)
    await state.handleOutpaintGenerate(context, canvas.png, canvas.mask, m.cw, m.ch);
  }

  /// 직전 확장 다시 ('확장' 꾹) — 그때 보낸 그림으로 돌아가 자리 · 크기 · 회전 · 자르기 · 경계를 그대로 놓고 확장을 켠다.
  ///  결과가 마음에 안 들면 실행만 다시 누르면 같은 배치로 다시 돌린다 (조금 고쳐서 돌려도 된다).
  ///  · 그림을 바꾸면 리스너(_handleI2iMaskChanges)가 자리를 먼저 비운다 — 알림은 바로 돌기 때문에 그 뒤에 채운다.
  ///  · 칠해 둔 마스크는 그대로 둔다 ('직전 이미지' 버튼과 같다 — 확장은 붓 마스크를 쓰지 않는다).
  ///  · 판 크기(상세 환경 해상도)가 그때와 다르면 자리는 맞지 않아 처음 자리로 — 자르기 · 경계만 그대로.
  void _restoreLastOutpaint(AppState state) {
    final LastOutpaint? r = state.lastOutpaint;
    if (r == null) {
      showToast(context, "아직 확장한 적이 없어요 — 확장을 한 번 돌린 뒤 꾹 누르면 그 배치를 다시 불러와요.");
      return;
    }
    if (!identical(state.targetI2iImage, r.image)) {
      state.i2iMaskActionOnChange = I2iMaskAction.keepMask;
      state.targetI2iImage = r.image;
      state.targetI2iMetadata = r.meta;
      state.recordI2iView(r.image, r.meta); // '직전 이미지' 로 결과에 다시 돌아갈 수 있게
      state.refreshUI();
      if (!mounted) {
        return;
      }
    }
    final bool sameBoard = state.outpaintCanvasSize == (r.canvasW, r.canvasH);
    setState(() {
      _moveMode = true;
      _compareView = false; // 확장과 비교는 하나만
      _comparePeek = false;
      _cropEditing = false;
      _cropDrag = null;
      _moveGestureStart = null;
      _outpaintOverlap = r.overlap;
      _moveCrop = r.crop;
      _moveCropImage = r.image;
      _movePlacement = r.placement;
      _movePlacementImage = r.image;
      _movePlacementKey = (r.crop.width, r.crop.height, r.canvasW, r.canvasH);
    });
    // 같은 판이면 배치가 그대로 보이므로 알리지 않는다 — 판 크기가 달라 자리를 처음부터 잡았을 때만 알려 준다
    if (!sameBoard) {
      showToast(context, "직전 확장을 불러왔어요 — 판 크기가 그때와 달라 자리는 처음부터예요 (자르기 · 경계는 그대로)");
    }
  }

  /// 판을 짠다 (그림 + 흐린 빈칸 + 마스크) — 그림 풀기 · 판 픽셀마다 집어 오기 · PNG 굽기는 무겁다 — 화면 밖에서.
  ///  짜는 동안 실행 버튼을 잠근다. 못 읽으면 null.
  Future<OutpaintCanvas?> _composeCanvas(_MoveInputs m, OutpaintPlacement p, int overlap) async {
    setState(() => _isOutpaintComposing = true);
    try {
      return await compute(
        composeOutpaint,
        OutpaintJob(
          image: m.image,
          imageW: m.fw, // 자르기 전 전체 — 자르기는 판을 짜며 한다
          imageH: m.fh,
          canvasW: m.cw,
          canvasH: m.ch,
          placement: p,
          overlap: overlap,
          crop: m.crop,
        ),
      );
    } catch (e) {
      debugPrint("확장 판 짜기 실패: $e");
      return null;
    } finally {
      if (mounted) {
        setState(() => _isOutpaintComposing = false);
      }
    }
  }

  /// 빈칸이 없을 때 — 지금 모양(자르기 · 크기 · 자리 · 회전) 그대로 판 크기의 새 작업 그림으로 쓸지 묻는다.
  ///  기기에서 판만 짜므로 Anlas 가 들지 않는다. 쓰면 확장이 꺼지고(새 그림 — _handleI2iMaskChanges)
  ///  바로 붓으로 칠해 인페인트할 수 있다 — 그림의 한 부분만 잘라 키워 다시 그리고 싶을 때.
  ///  그림 정보는 비운다 — 크기가 판 크기로 바뀌어, 옛 그림 정보의 크기를 쓰면 안 된다 (AppState.i2iImageSize).
  Future<void> _offerBakeOutpaint(AppState state, _MoveInputs m, OutpaintPlacement p) async {
    final bool use = await showConfirmDialog(
      context,
      title: "채울 빈칸이 없어요",
      message:
          "그림이 판(${m.cw}×${m.ch})을 다 덮었어요.\n\n"
          "지금 모양(자르기 · 크기 · 회전) 그대로 새 작업 그림으로 쓸까요?\n"
          "Anlas는 들지 않아요 — 그 위에 붓으로 칠해 인페인트하면 돼요.\n\n"
          "(빈칸을 채우려면 그림을 줄이거나 옮겨 주세요)",
      confirmLabel: "이대로 쓰기",
      icon: Icons.crop,
      iconColor: AppColors.teal,
      destructive: false,
      confirmColor: AppColors.teal,
    );
    if (!use || !mounted) {
      return;
    }
    final OutpaintCanvas? canvas = await _composeCanvas(m, p, 0);
    if (!mounted) {
      return;
    }
    if (canvas == null) {
      showToast(context, "그림을 읽지 못했어요.");
      return;
    }
    final Uint8List png = canvas.png;
    state.i2iMaskActionOnChange = I2iMaskAction.clearMask; // 새 그림 — 마스크를 비우고 확장을 끈다
    state.targetI2iImage = png;
    state.targetI2iMetadata = null;
    state.recordI2iView(png, null, reset: true);
    state.addI2iResult(png, null, source: I2iMode.inpaint.id);
    state.refreshUI(); // 캔버스가 바로 바뀌어 보이므로 알리지 않는다
  }

  // 확장 캔버스 — 판 + 옮길 수 있는 그림.
  //  · 한 손가락: 옮기기 · 두 손가락: 키우기 / 줄이기 / 돌리기 (+ 옮기기) · 두 번 탭: 처음 자리 (반듯하게)
  //  · 0° · 90° · 180° · 270° 가까이 돌리면 딱 맞춘다 · 판 가장자리 · 가운데 가까이 가면 붙는다
  //  · 판 밖으로 나간 부분은 어둡게 — 보낼 때 잘린다 · 눈 버튼: 새로 그릴 곳(빈칸 + 경계)을 마스크 색으로
  //  ⚠️ 자식 수를 바꾸지 않는다 (DEVNOTES 2)
  Widget _buildMoveCanvas(AppState state) {
    final m = _moveInputs(state);
    if (m == null) {
      return const Center(
        child: Text("이미지 크기를 읽지 못했습니다.", style: TextStyle(color: Colors.white30)),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        // 판을 캔버스 안에 맞춰 놓는다 — 둘레에 여백을 둬 판 밖으로 나간 그림도 조금 보이게
        const double pad = 24;
        final double k = max(
          0.0001,
          min((box.maxWidth - pad * 2) / m.cw, (box.maxHeight - pad * 2) / m.ch),
        ); // 화면 픽셀 ÷ 판 픽셀
        final Rect frame = Rect.fromCenter(
          center: Offset(box.maxWidth / 2, box.maxHeight / 2),
          width: m.cw * k,
          height: m.ch * k,
        );
        final OutpaintPlacement p = _placementFor(m.image, m.iw, m.ih, m.cw, m.ch);
        final double sf = p.scale * k; // 화면 픽셀 ÷ 그림 픽셀
        // 돌리기 전 그림 '전체'(자르기 전)의 자리 — 가운데를 축으로 Transform.rotate 가 돌린다
        //  (outpaint.dart 와 같은 방향). 자른 곳만 보여 주고, 자르는 중엔 전체를 보여 준다.
        final fc = outpaintFullCenter(p, m.crop, m.fw, m.fh);
        final Rect imageRect = Rect.fromCenter(
          center: frame.topLeft + Offset(fc.x, fc.y) * k,
          width: m.fw * sf,
          height: m.fh * sf,
        );
        // 그림 상자 안의 자른 곳 (돌리기 전 · 화면 픽셀)
        final Rect cropBox = Rect.fromLTRB(
          m.crop.x0 * sf,
          m.crop.y0 * sf,
          m.crop.x1 * sf,
          m.crop.y1 * sf,
        );
        final bool cropped = m.iw != m.fw || m.ih != m.fh;
        final bool nothingToFill = outpaintNothingToFill(p, m.iw, m.ih, m.cw, m.ch);
        // 새로 그릴 곳은 눈 버튼을 켰을 때만 계산한다 (손가락을 움직일 때마다 다시 그린다)
        final List<Rect> keepRects = _maskVisible
            ? [
                for (final r in outpaintKeepRects(p, m.iw, m.ih, m.cw, m.ch, _outpaintOverlap))
                  Rect.fromLTRB(
                    frame.left + r.x0 * k,
                    frame.top + r.y0 * k,
                    frame.left + r.x1 * k,
                    frame.top + r.y1 * k,
                  ),
              ]
            : const [];
        // 화면 → 판 픽셀
        Offset toCanvas(Offset local) => (local - frame.topLeft) / k;
        final int deg = outpaintAngleDegrees(p.angle);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) {
            // 지금 자리를 새로 읽는다 — 손가락이 늘거나 줄면 다시 불리는데, 그 사이 화면이 아직 안 그려졌을 수 있다
            final OutpaintPlacement now = _placementFor(m.image, m.iw, m.ih, m.cw, m.ch);
            _cropDrag = null;
            // 자르는 중 한 손가락 — 손잡이 · 자른 곳 안이면 자르기, 밖이면 아래처럼 그림 옮기기 (두 손가락은 늘 그림)
            if (_cropEditing && d.pointerCount == 1) {
              final Offset c = toCanvas(d.localFocalPoint);
              final pt = outpaintImagePoint(now, m.crop, c.dx, c.dy);
              // 손가락이 닿는 범위 — 화면에서 28픽셀 (그림 픽셀로 바꿔서)
              final OutpaintCropHandle? h = hitOutpaintCrop(
                m.crop,
                pt.u,
                pt.v,
                28 / (now.scale * k),
              );
              if (h != null) {
                _cropDrag = (handle: h, crop: m.crop, placement: now, u: pt.u, v: pt.v);
                _moveGestureStart = null;
                return;
              }
            }
            _moveGestureStart = now;
            _moveFocalStart = toCanvas(d.localFocalPoint);
          },
          onScaleUpdate: (d) {
            final drag = _cropDrag;
            if (drag != null) {
              // 손가락을 댄 순간의 자리로 그림 좌표를 읽는다 — 끄는 동안 그림이 화면에서 움직이지 않는다
              final Offset c = toCanvas(d.localFocalPoint);
              final pt = outpaintImagePoint(drag.placement, drag.crop, c.dx, c.dy);
              final OutpaintRect next = dragOutpaintCrop(
                drag.crop,
                drag.handle,
                pt.u - drag.u,
                pt.v - drag.v,
                m.fw,
                m.fh,
              );
              _setCrop(m, drag.placement, drag.crop, next);
              return;
            }
            final OutpaintPlacement? start = _moveGestureStart;
            if (start == null) {
              return;
            }
            final Offset f = toCanvas(d.localFocalPoint);
            final next = zoomOutpaintPlacement(
              start,
              fx0: _moveFocalStart.dx,
              fy0: _moveFocalStart.dy,
              fx1: f.dx,
              fy1: f.dy,
              factor: d.scale,
              rotation: d.rotation,
              imageW: m.iw,
              imageH: m.ih,
              canvasW: m.cw,
              canvasH: m.ch,
            );
            // 화면에서 10픽셀 안이면 판 가장자리 · 가운데에 붙인다 (붙인 뒤 범위를 한 번 더 지킨다)
            _setPlacement(
              clampOutpaintPlacement(
                snapOutpaintPlacement(next, m.iw, m.ih, m.cw, m.ch, 10 / k),
                m.iw,
                m.ih,
                m.cw,
                m.ch,
              ),
              m.image,
              m.iw,
              m.ih,
              m.cw,
              m.ch,
            );
          },
          onScaleEnd: (_) {
            _moveGestureStart = null;
            if (_cropDrag != null) {
              _cropDrag = null;
              // 다 끈 뒤에 범위 안으로 (판과 겹치는 곳 · 배율 범위 — 자른 그림의 크기로)
              final mm = _moveInputs(state);
              if (mm != null) {
                final OutpaintPlacement now = _placementFor(mm.image, mm.iw, mm.ih, mm.cw, mm.ch);
                _setPlacement(
                  clampOutpaintPlacement(now, mm.iw, mm.ih, mm.cw, mm.ch),
                  mm.image,
                  mm.iw,
                  mm.ih,
                  mm.cw,
                  mm.ch,
                );
              }
            }
          },
          onDoubleTap: () => _setPlacement(
            outpaintInitial(m.iw, m.ih, m.cw, m.ch),
            m.image,
            m.iw,
            m.ih,
            m.cw,
            m.ch,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1) 판 — 빗금 = 새로 그려질 빈칸
              Positioned.fromRect(
                rect: frame,
                child: const CustomPaint(painter: _OutpaintFramePainter()),
              ),
              // 2) 그림 (가운데를 축으로 돌린다) — 자른 곳만. 자르는 중엔 전체 + 잘릴 곳 회색 · 모서리 'ㄱ' 손잡이
              Positioned.fromRect(
                rect: imageRect,
                child: Transform.rotate(
                  angle: p.angle,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRect(
                        clipper: _RectClipper(_cropEditing ? null : cropBox),
                        child: Image.memory(m.image, fit: BoxFit.fill, gaplessPlayback: true),
                      ),
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _CropEditPainter(crop: cropBox, editing: _cropEditing),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 3) 덮개 — 판 밖은 어둡게 · 새로 그릴 곳 · 판 테두리
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _OutpaintOverlayPainter(
                      frame: frame,
                      keep: keepRects,
                      showFill: _maskVisible,
                      fillColor: _maskColor,
                      warn: nothingToFill,
                    ),
                  ),
                ),
              ),
              // 4) 판 크기 · 그림 배율 · 각도 (판 바로 위)
              Positioned(
                left: frame.left,
                right: 4,
                top: max(0.0, frame.top - 22),
                child: IgnorePointer(
                  child: Text(
                    _cropEditing
                        ? "자르기 — 모서리 · 변을 끌어 남길 곳을 고르세요 (${m.iw}×${m.ih})"
                        : nothingToFill
                        ? "판 ${m.cw}×${m.ch} · 빈칸 없음 — 실행하면 이대로 쓸 수 있어요"
                        : "판 ${m.cw}×${m.ch} · 그림 ${(p.scale * 100).round()}%"
                              "${deg == 0 ? "" : " · $deg°"}${cropped ? " · 자름" : ""}",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: nothingToFill ? AppColors.amber : Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
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
  // 모자이크 처리 — 백그라운드 isolate에서 실행 (UI 멈춤 방지)
  // ============================================================================
  Future<void> _applyMosaic(AppState state) async {
    if (state.targetI2iImage == null) return;
    if (_strokes.isEmpty) {
      if (mounted) {
        showToast(context, "마스크를 그려주세요! 🖍️");
      }
      return;
    }

    setState(() => _isMosaicProcessing = true);

    try {
      final pngBytes = await _computeMosaic(state);

      if (pngBytes != null) {
        state.i2iMaskActionOnChange = I2iMaskAction.clearMask; // 모자이크 결과 → 마스크 초기화
        state.targetI2iImage = pngBytes;
        state.recordI2iView(pngBytes, null, reset: true); // 본 이미지 기록 새로 시작
        _strokes.clear();

        // 모자이크 결과는 메인 히스토리 대신 i2i 스크래치 릴로
        state.addI2iResult(pngBytes, null, source: I2iMode.mosaic.id);

        state.refreshUI();
      }
    } catch (e) {
      debugPrint("모자이크 처리 실패: $e");
      if (mounted) {
        showToast(context, "모자이크 처리 중 오류가 발생했습니다.");
      }
    } finally {
      if (mounted) {
        setState(() => _isMosaicProcessing = false);
      }
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
      if (m['invert'] == true) {
        _maskInvert(grid, w, h); // 마스킹 반전 — 그림 전체
        continue;
      }
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
      final previewBytes = await _computeMosaic(state);
      if (mounted) {
        setState(() => _mosaicPreviewImage = previewBytes);
      }
    } catch (e) {
      debugPrint("미리보기 생성 실패: $e");
    } finally {
      // ⚠️ 예전엔 캔버스를 못 찾아 중간에 return 하면 '불러오는 중' 표시가 꺼지지 않았다
      if (mounted) {
        setState(() => _isPreviewLoading = false);
      }
    }
  }

  /// 지금 마스크로 모자이크를 계산한다 (적용·미리보기 공용). 캔버스가 아직 없으면 null.
  ///  디코드 + 마스크 빌드 + 모자이크 전부 백그라운드 isolate에서 (UI 멈춤 방지)
  Future<Uint8List?> _computeMosaic(AppState state) async {
    final renderBox = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return null;
    }
    return compute(_processMosaicIsolate, {
      'imageBytes': state.targetI2iImage!,
      'strokes': _strokes
          .map(
            (s) => {
              'pts': [
                for (final p in s.points) ...[p.dx, p.dy],
              ],
              'size': s.size,
              'isEraser': s.isEraser,
              'invert': s.isInvert,
            },
          )
          .toList(),
      'renderW': renderBox.size.width,
      'renderH': renderBox.size.height,
      'type': _mosaicType,
      'strength': _mosaicStrength.round(),
    });
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
    // 부분 인페인트가 켜져 있으면 채운 아이콘 + 맥락 폭 (연필의 굵기처럼 — 한 번 더 누르면 바꾼다)
    if (toolId == 'focus') {
      final AppState? st = _appStateRef;
      if (st != null && _focusBoxFor(st) != null) {
        displayIcon = Icons.center_focus_strong;
        sizeText = "${st.focusInpaintContext}";
      }
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
            color: isSelected ? AppColors.accent.withValues(alpha: 0.3) : Colors.transparent,
            border: Border.all(color: isSelected ? AppColors.accent : Colors.white24, width: 1.5),
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
    return _valueButton(
      tooltip: "인페인트 강도",
      label: "강도",
      value: state.infillStrength.toStringAsFixed(2),
      onTap: _showStrengthDialog,
    );
  }

  // img2img 파라미터 버튼 (강도/노이즈) — 인페인트 강도 버튼과 동일 규격
  Widget _buildImg2ImgParamButton(AppState state, {required bool isNoise}) {
    final double value = isNoise ? state.img2imgNoise : state.img2imgStrength;
    return _valueButton(
      tooltip: isNoise ? "img2img 노이즈 (새 디테일 추가량)" : "img2img 강도 (원본 변형 정도)",
      label: isNoise ? "노이즈" : "강도",
      value: value.toStringAsFixed(2),
      onTap: () => _showImg2ImgParamDialog(isNoise: isNoise),
    );
  }

  /// 값 하나를 보여 주는 작은 도구 버튼 (위: 이름, 아래: 값). 누르면 설정창.
  ///  인페인트 강도·img2img 강도/노이즈·모자이크 강도가 같은 모양을 쓴다.
  ///  (예전엔 세 버튼이 이 겉모양 30줄을 각자 복사해 갖고 있었다)
  ///  [value] 가 없으면 이름만 조금 크게 가운데에 ('상세' 처럼 글자만 있는 버튼).
  Widget _valueButton({
    required String tooltip,
    required String label,
    String? value,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    double valueSize = 10,
  }) {
    const labelStyle = TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
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
              Text(label, style: value == null ? labelStyle.copyWith(fontSize: 12) : labelStyle),
              if (value != null) Text(value, style: labelStyle.copyWith(fontSize: valueSize)),
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
            backgroundColor: AppColors.surface,
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
                  activeColor: I2iMode.img2img.color, // img2img 설정창은 모드 색
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
                  state.saveAndRefresh();
                  Navigator.pop(ctx);
                },
                child: Text("적용", style: TextStyle(color: I2iMode.img2img.color)),
              ),
            ],
          );
        },
      ),
    );
  }

  // Director 화면으로 들어가고 나오는 전환 버튼.
  //  탭 바로 아래, 모드 칩 위에 둔다. 눌리면 아래 칩 영역이 통째로 바뀐다.
  Widget _buildDirectorToggle(AppState state) {
    final on = _directorMode;
    // 켜고 꺼도 아이콘·글자는 그대로 두고 색만 바꾼다.
    //  (모양이 바뀌면 폭이 흔들려 탭 바 아래에서 덜컹거린다)
    final Color tint = on ? AppColors.purple : Colors.white54;
    return Center(
      child: InkWell(
        onTap: () => setState(() {
          _directorMode = !_directorMode;
          if (_directorMode) {
            // 마스크 그리던 중이면 도구를 손 모양으로 되돌린다 (Director 는 마스크가 없다)
            _currentTool = 'pan';
          }
        }),
        // 탭 바에 붙어 내려온 것처럼 보이도록 위쪽만 각지게 둔다
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: on ? AppColors.purple.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
            border: Border(
              left: BorderSide(color: on ? AppColors.purple : Colors.white24),
              right: BorderSide(color: on ? AppColors.purple : Colors.white24),
              bottom: BorderSide(color: on ? AppColors.purple : Colors.white24),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 14, color: tint),
              const SizedBox(width: 6),
              Text(
                "Director tool",
                style: TextStyle(color: tint, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Director 도구 칩. 모드 칩과 같은 크기·같은 배치 규칙을 쓴다.
  //  (모드 칩 자리에 '대신' 들어가므로 높이가 어긋나면 캔버스가 밀린다)
  // Director 도구 칩 — 모드 칩과 같은 자리에 가로 한 줄로
  List<Widget> _buildDirectorChipRows(AppState state) {
    return [_directorChipRow(state, kDirectorTools)];
  }

  Widget _directorChipRow(AppState state, List<DirectorTool> tools) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final t in tools)
          Expanded(
            child: GestureDetector(
              onTap: () => state.setDirectorTool(t.reqType),
              child: Container(
                height: 22,
                margin: const EdgeInsets.symmetric(horizontal: 1.5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: state.directorTool == t.reqType
                      ? AppColors.purple.withValues(alpha: 0.22)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: state.directorTool == t.reqType ? AppColors.purple : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      t.icon,
                      size: 12,
                      color: state.directorTool == t.reqType ? AppColors.purple : Colors.white38,
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        t.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: state.directorTool == t.reqType ? Colors.white : Colors.white38,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    // 예상 Anlas. 0(무료)이거나 계산 불가면 표시하지 않는다.
                    if (state.directorCostFor(t.reqType) > 0) ...[
                      const SizedBox(width: 3),
                      Text(
                        "${state.directorCostFor(t.reqType)}",
                        style: TextStyle(
                          color: state.directorTool == t.reqType
                              ? AppColors.amber
                              : AppColors.amber.withValues(alpha: 0.5),
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // 모자이크 강도 설정창
  void _showMosaicStrengthDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
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
                style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Slider(
                value: _mosaicStrength,
                min: 2,
                max: 50,
                activeColor: AppColors.accent,
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
              child: Text("확인", style: TextStyle(color: AppColors.accent)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMosaicStrengthButton() {
    return _valueButton(
      tooltip: "모자이크 강도",
      label: "강도",
      value: "${_mosaicStrength.round()}",
      onTap: _showMosaicStrengthDialog,
      valueSize: 9, // 정수라 자릿수가 달라 조금 작게
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
            backgroundColor: AppColors.surface,
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
                  activeColor: AppColors.accent,
                  onChanged: (val) {
                    setModalState(() => tempStrength = double.parse(val.toStringAsFixed(2)));
                  },
                ),
                Text(tempStrength.toStringAsFixed(2), style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 8),
                const Text(
                  "0.1 = 원본 유지  /  1.0 = 완전 재생성 (공식 기본값)\n물건을 지우거나 완전히 바꾸려면 1.0 — 낮으면 원래 모양이 남아요",
                  textAlign: TextAlign.center,
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
                  state.saveAndRefresh();
                  Navigator.pop(ctx);
                },
                child: Text(
                  "확인",
                  style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPromptCard(
    BuildContext context,
    AppState state, {
    required String title,
    required IconData icon,
    required Color color,
    required TextEditingController controller,
    required String cardId, // 접기 상태 저장 키
    String hint = "",
  }) {
    // 접힘 여부는 AppState에 저장 → 앱을 껐다 켜도, 프롬값을 가져와도 그대로 유지
    final bool isCollapsed = state.collapsedI2iPrompts.contains(cardId);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 헤더: 탭하면 접기/펼치기 (오른쪽 연필 아이콘은 바로 편집)
          GestureDetector(
            onTap: () => state.toggleI2iPromptCollapsed(cardId),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: isCollapsed
                    ? BorderRadius.circular(12)
                    : const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          isCollapsed ? Icons.chevron_right : Icons.expand_more,
                          color: color,
                          size: 20,
                        ),
                        const SizedBox(width: 4),
                        Icon(icon, color: color, size: 20),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 접혀 있어도 바로 편집할 수 있게 연필은 항상 표시
                  GestureDetector(
                    onTap: () => showPromptEditDialog(
                      context,
                      state,
                      title,
                      icon,
                      color,
                      controller,
                      // 프롬프트탭과 이름이 같아 되돌리기 기록이 섞이지 않게 구분한다
                      undoKey: 'i2i/$title',
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(Icons.edit, color: color, size: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 본문(미리보기): 접히면 감춤. 탭하면 편집 다이얼로그
          if (!isCollapsed)
            GestureDetector(
              onTap: () => showPromptEditDialog(
                context,
                state,
                title,
                icon,
                color,
                controller,
                undoKey: 'i2i/$title',
              ),
              behavior: HitTestBehavior.opaque,
              child: Padding(
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
            ),
        ],
      ),
    );
  }

  // ============================================================================
  // 비교 보기 — 기준 그림과 지금 그림을 나란히 (캔버스 위에 덮는다)
  //  · 기준 = i2i 로 보낸 원본 (AppState.i2iCompareBase). 📌 로 지금 그림 · 릴의 결과를 기준으로 고정할 수 있다.
  //  · 두 칸은 확대 · 이동이 같이 움직인다 (같은 TransformationController) · 두 번 탭하면 원래 크기로.
  //  · '지금' 칸을 꾹 누르고 있으면 그 자리에 기준 그림 — 같은 자리에서 번갈아 보면 바뀐 곳이 잘 보인다
  //    (폰 화면을 반으로 나누면 그림이 작아서, 작은 차이는 나란히 보다 이쪽이 더 잘 보인다).
  //  · 그림 비율을 보고 좌우 / 위아래 중 그림이 더 크게 보이는 쪽으로 나눈다.
  //  · 떠 있는 동안 지금 그림이 바뀌면(인페인트 결과 · 릴 · 직전 이미지) '지금' 칸이 따라 바뀐다.
  //  ⚠️ 캔버스를 바꾸거나 빼지 않고 '위에 덮는다' — 비교 중에도 실행 버튼이 그대로 된다.
  //     인페인트는 캔버스의 크기로 마스크를 만든다 (_captureMask). 캔버스가 빠지면 실행이 안 되고,
  //     크기가 바뀌면 그려 둔 마스크가 어긋난다. 덮은 동안은 캔버스에 그릴 수 없다 (덮개가 손가락을 받는다).
  // ============================================================================
  void _setCompareView(bool on) {
    final AppState? state = _appStateRef;
    final Uint8List? now = state?.targetI2iImage;
    // 기준이 비었으면(보통은 보낼 때 정해져 비어 있을 일이 없다) 지금 그림을 기준으로 — 사용자가 고정한 건 아니다
    if (on && state != null && state.i2iCompareBase == null && now != null) {
      state.setI2iCompareBase(now, pinned: false);
    }
    setState(() {
      _compareView = on;
      _comparePeek = false;
      _compareTransform.value = Matrix4.identity(); // 열 때마다 원래 크기로
      // 확장과 비교는 하나만 — 비교가 캔버스를 덮으면 확장 판이 안 보인다
      if (on) {
        _moveMode = false;
        _moveGestureStart = null;
      }
    });
  }

  // 캔버스 맨 아래 줄의 버튼 ('프롬프트 보기' · '비교') — 같은 모양 · 같은 높이
  Widget _bottomLineButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool active = false,
    bool enabled = true,
  }) {
    final Color fg = active ? AppColors.accent : (enabled ? Colors.white54 : Colors.white24);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: active ? AppColors.accent.withValues(alpha: 0.15) : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? AppColors.accent : Colors.white24),
        ),
        // 좁은 화면에서 버튼이 셋이면 '프롬프트 보기'(남는 폭을 받는 칸)가 모자랄 수 있다 — 넘치지 않게 줄여 보인다.
        //  (폭이 정해지지 않은 버튼은 줄지 않는다. 줄 높이는 줄지 않은 버튼이 정하므로 캔버스 크기는 그대로)
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 20),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompareView(AppState state) {
    final Uint8List? base = state.i2iCompareBase;
    final Uint8List? now = state.targetI2iImage;
    final bool same = identical(base, now);
    final String baseLabel = state.i2iCompareBasePinned ? "📌 고정" : "원본";
    // 불투명 바탕 — 아래 캔버스를 가리고, 손가락도 여기서 받는다 (캔버스에 닿지 않게)
    return ColoredBox(
      color: AppColors.background,
      child: Column(
        children: [
          // 위 줄: 안내 · 지금 그림을 기준으로 고정 · 닫기
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 0, 0),
            child: Row(
              children: [
                const Icon(Icons.compare, color: Colors.white54, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    same ? "기준과 같은 그림" : "'지금' 꾹: 겹쳐 보기",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
                // 글자가 아주 크면 줄여 보인다 (Flexible — 고정 폭이면 넘친다)
                Flexible(
                  child: TextButton.icon(
                    onPressed: same || now == null ? null : () => state.setI2iCompareBase(now),
                    icon: const Icon(Icons.push_pin, size: 16),
                    label: const Text(
                      "지금 그림 고정",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _setCompareView(false),
                  icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                  tooltip: "비교 닫기",
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final (int w, int h) = state.i2iImageSize ?? (832, 1216);
                const double gap = 4;
                // 좌우로 나눌 때 · 위아래로 나눌 때 그림이 보이는 배율 — 큰 쪽으로 나눈다
                final double sideBySide = min(
                  (box.maxWidth - gap) / 2 / max(w, 1),
                  box.maxHeight / max(h, 1),
                );
                final double stacked = min(
                  box.maxWidth / max(w, 1),
                  (box.maxHeight - gap) / 2 / max(h, 1),
                );
                return Flex(
                  direction: sideBySide >= stacked ? Axis.horizontal : Axis.vertical,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _comparePanel(base, baseLabel)),
                    const SizedBox(width: gap, height: gap),
                    Expanded(
                      child: _comparePanel(
                        _comparePeek ? base : now,
                        _comparePeek ? baseLabel : "지금",
                        peekable: true,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // 비교 한 칸 — 같이 움직이는 확대 · 이동 + 이름표. [peekable] 이면 꾹 누르는 동안 기준 그림으로 바뀐다.
  Widget _comparePanel(Uint8List? bytes, String label, {bool peekable = false}) {
    void setPeek(bool v) {
      if (_comparePeek != v) {
        setState(() => _comparePeek = v);
      }
    }

    // ⚠️ 자식 수를 바꾸지 않는다 (DEVNOTES 2)
    return Stack(
      fit: StackFit.expand,
      children: [
        InteractiveViewer(
          transformationController: _compareTransform,
          minScale: 1,
          maxScale: 10,
          child: GestureDetector(
            onDoubleTap: () => _compareTransform.value = Matrix4.identity(),
            onLongPressStart: peekable ? (_) => setPeek(true) : null,
            onLongPressEnd: peekable ? (_) => setPeek(false) : null,
            onLongPressCancel: peekable ? () => setPeek(false) : null,
            child: bytes == null
                ? const Center(
                    child: Text("그림 없음", style: TextStyle(color: Colors.white30, fontSize: 12)),
                  )
                // gaplessPlayback — 꾹 눌러 바꿀 때 · 지금 그림이 바뀔 때 깜빡이지 않게
                : Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
          ),
        ),
        Positioned(
          top: 6,
          left: 6,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ],
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
    // ⚠️ Stack 의 자식 '개수'를 바꾸지 않는다.
    //    조건부로 넣었다 뺐다 하면 Flutter 가 남은 자식들을 순서로 다시 맞추면서
    //    엉뚱한 요소끼리 짝지어지고, 멀쩡한 화면(body 전체)이 통째로
    //    해제·재생성된다. 그 과정에서 아직 쓰이는 것이 정리되면 앱이 죽는다.
    //    항상 자리를 지키게 두고 보이기만 감춘다. 키로 짝도 고정한다.
    //    (DEVNOTES.md 2번 항목)
    return Stack(
      children: [
        Positioned.fill(key: const ValueKey('i2iBody'), child: body),
        // 패널 열렸을 때 바깥 영역 탭하면 닫기
        Positioned.fill(
          key: const ValueKey('i2iReelScrim'),
          child: Offstage(
            offstage: !_reelOpen,
            child: GestureDetector(
              onTap: () => setState(() => _reelOpen = false),
              child: Container(color: Colors.black54),
            ),
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
        // 트리거 핸들 (오른쪽 아래) — 패널이 닫혀 있을 때만 보인다
        Positioned(
          key: const ValueKey('i2iReelHandle'),
          right: 0,
          bottom: handleBottom,
          child: Offstage(
            offstage: _reelOpen,
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
                        color: AppColors.accent,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(14),
                          bottomLeft: Radius.circular(14),
                        ),
                        boxShadow: pulse > 0
                            ? [
                                BoxShadow(
                                  color: AppColors.accent.withValues(alpha: 0.85 * pulse),
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
                          // 누르기 · 꾹 · ★ 은 번호가 아니라 이 결과(r)로 — 그린 뒤 새 결과가 들어와 번호가 밀릴 수 있다
                          return GestureDetector(
                            onTap: () {
                              state.useI2iResult(r);
                              setState(() => _reelOpen = false);
                            },
                            onLongPress: () => _showI2iResultMenu(state, r),
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
                                      final ok = state.toggleI2iFavorite(r);
                                      if (!ok && mounted) {
                                        showToast(
                                          context,
                                          "즐겨찾기는 최대 ${AppState.i2iFavoriteCap}개까지예요",
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
                                        color: r.favorite ? AppColors.amber : Colors.white70,
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
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _sourceIcon(r.source),
                                            size: 13,
                                            color: _sourceColor(r.source),
                                          ),
                                          // 배경 제거는 결과가 3장(M/G/B)이라 아이콘만으로는
                                          // 구분되지 않는다. 종류 글자를 한 자 덧붙인다.
                                          if (_variantLetter(r.source) != null) ...[
                                            const SizedBox(width: 1),
                                            Text(
                                              _variantLetter(r.source)!,
                                              style: TextStyle(
                                                color: _sourceColor(r.source),
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ],
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
  /// Director 결과인지 판별하고, 맞으면 그 도구를 돌려준다.
  ///  source 에는 도구 배지가 들어간다 ('LINE', 'BG-M' 처럼).
  ///  배경 제거는 결과가 3장이라 '-M/-G/-B' 접미사가 붙는다.
  DirectorTool? _directorToolOfSource(String source) {
    final base = source.split('-').first; // 'BG-M' → 'BG'
    for (final t in kDirectorTools) {
      if (t.badge == base) {
        return t;
      }
    }
    return null;
  }

  /// 결과가 여러 장인 도구에서 몇 번째 종류인지 ('BG-M' → 'M').
  ///  한 장짜리 도구나 일반 모드면 null.
  String? _variantLetter(String source) {
    final parts = source.split('-');
    if (parts.length < 2) {
      return null;
    }
    return parts.last;
  }

  IconData _sourceIcon(String source) {
    // Director 도구는 각자의 아이콘을 쓴다 (인페인트와 헷갈리지 않게)
    final dt = _directorToolOfSource(source);
    if (dt != null) {
      return dt.icon;
    }
    if (source == 'origin') {
      return Icons.image_outlined; // i2i로 보낸 원본
    }
    // 모드 결과는 그 모드 아이콘 (모르는 출처는 인페인트)
    return (I2iMode.fromId(source) ?? I2iMode.inpaint).icon;
  }

  Color _sourceColor(String source) {
    // Director 결과는 전부 보라색 계열로 묶어 한눈에 구분되게 한다
    if (_directorToolOfSource(source) != null) {
      return AppColors.purple;
    }
    if (source == 'origin') {
      return Colors.white60; // 원본
    }
    // 모드 결과는 그 모드 색 (모르는 출처는 인페인트)
    return (I2iMode.fromId(source) ?? I2iMode.inpaint).color;
  }

  // i2i 결과 꾹 누르기 메뉴 — 누른 결과(r)를 잡아 두고 메뉴의 일을 다 그것으로 한다.
  //  ⚠️ 번호로 하면 메뉴가 떠 있는 사이 새 결과가 들어와 릴이 정리될 때 옆 결과를 지웠다 (DEVNOTES 5)
  void _showI2iResultMenu(AppState state, I2iResult r) {
    final Uint8List bytes = r.bytes;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        // 항목이 4개라 가로 화면에선 시트 높이를 넘을 수 있다 — 넘치면 스크롤 (안에 Expanded 없음)
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.history, color: AppColors.purple),
                title: const Text("히스토리로 보내기", style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await state.promoteI2iToHistory(r, context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.save_alt, color: AppColors.teal),
                title: const Text("폴더에 저장하기", style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await state.saveI2iToFolder(r, context);
                },
              ),
              // 비교 보기의 기준으로 (캔버스 아래 '비교' — 지금 그림과 나란히)
              ListTile(
                leading: Icon(Icons.push_pin_outlined, color: AppColors.accent),
                title: const Text("비교 기준으로 고정", style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  state.setI2iCompareBase(bytes);
                  // 남긴다 — 고정한 건 '비교' 를 열어야 보여서, 눌렀는지 · 어디서 보는지 알려 준다
                  showToast(context, "비교 기준으로 고정했어요 📌 (캔버스 아래 '비교')");
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text("내역에서 삭제", style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  state.removeI2iResult(r);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
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

    // (설정에서 지금 모드를 끈 경우는 _fixModeIfDisabled 가 리스너에서 처리한다)

    bool canDraw =
        (_i2iMode.usesMask && !_directorMode) &&
        (_currentTool == 'pencil' || _currentTool == 'eraser');
    // 부분 인페인트 — 인페인트에서만 보이고 끈다 (다른 모드 · Director 에선 숨긴다 — 상자는 남는다)
    final bool focusShown = _i2iMode == I2iMode.inpaint && !_directorMode;
    final bool focusEditing = focusShown && _currentTool == 'focus';
    final OutpaintRect? focusBox = focusShown ? _focusBoxFor(state) : null;
    final FocusPlan? focusPlanNow = focusBox == null ? null : state.focusPlanFor(focusBox);
    // 비교 보기가 떠 있는지 (그림이 있을 때만)
    final bool comparing = _compareView && state.targetI2iImage != null;
    if (!comparing) {
      _comparePeek = false; // 안 보이는 동안 꾹 누르기가 끊겼어도 다음에 열 때 남지 않게 (그리기만 하는 값이라 setState 불필요)
    }

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

            // 설정에서 Director 버튼을 끈 채로 Director 화면에 있으면
            // 돌아올 방법이 없어진다. 그럴 땐 일반 모드로 되돌린다.
            //  ⚠️ build 도중 setState 를 부를 수 없어 프레임 뒤로 미룬다.
            if (_directorMode && !state.directorToolVisible) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _directorMode && !state.directorToolVisible) {
                  setState(() => _directorMode = false);
                }
              });
            }

            // ⚠️ 위쪽 여백을 0으로 두고, Director 버튼 아래에서 다시 확보한다.
            //    버튼이 탭 바에 딱 붙어 내려온 것처럼 보이게 하기 위함.
            return Padding(
              padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Director 화면 전환 버튼 (탭 바에 붙임)
                  //  설정에서 끄면 버튼만 감춘다. 켜져 있던 화면은 아래에서 되돌린다.
                  if (state.directorToolVisible) ...[
                    _buildDirectorToggle(state),
                    const SizedBox(height: 12),
                  ] else
                    const SizedBox(height: 16),
                  // 모드 칩 가로 1줄 (실행 버튼은 아래 도구 줄 오른쪽에 있다)
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _directorMode
                            ? AppColors.purple.withValues(alpha: 0.5)
                            : Colors.white24,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _directorMode
                          ? _buildDirectorChipRows(state)
                          : _buildModeChipRows(state),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 캔버스: 남는 공간을 그대로 차지
                  // → 높이를 직접 계산하면 실제 위젯 높이와 어긋나 UI가 밀리는 문제가 생김
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: state.isInpaintLoading ? AppColors.amber : Colors.white24,
                          // 두께는 항상 동일: 로딩 때 1→2로 바뀌면 캔버스 내부가 2px 줄어
                          // 이미지가 재배치되며 마스크가 어긋나 보인다 (색만 바꾼다)
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        // ⚠️ 자식 수를 바꾸지 않는다 (DEVNOTES 2) — 비교 보기는 늘 자리를 두고 내용만 바꾼다.
                        //    비교 보기는 캔버스 '위에' 덮는다 — 캔버스는 그대로 둔다 (_setCompareView 위 설명).
                        //    ⚠️ 여는 버튼을 캔버스 위에 띄우지 않는다 — 그 자리에서 시작한 획이 그려지지 않는다 (맨 아래 줄에 있다)
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            state.targetI2iImage == null
                                ? const Center(
                                    child: Text(
                                      "히스토리에서 이미지를 선택하세요.",
                                      style: TextStyle(color: Colors.white30),
                                    ),
                                  )
                                // 확장 — 판 위에서 그림을 옮긴다 (붓 캔버스는 빠지지만 칠한 마스크는 AppState 에 그대로)
                                : _moving
                                ? _buildMoveCanvas(state)
                                : Center(
                                    child: InteractiveViewer(
                                      transformationController: _transformController,
                                      panEnabled:
                                          _currentTool == 'pan' ||
                                          _currentTool == 'zoom_in' ||
                                          _currentTool == 'zoom_out',
                                      scaleEnabled: false,
                                      child: AspectRatio(
                                        // 그림의 실제 비율 — 그림 정보가 없으면 파일에서 읽은 크기로
                                        //  (예전엔 832×1216 으로 고정돼 밖에서 가져온 그림은 마스크가 어긋났다)
                                        aspectRatio:
                                            (state.i2iImageSize?.$1 ?? 832) /
                                            (state.i2iImageSize?.$2 ?? 1216),
                                        child: GestureDetector(
                                          // 붓 · 지우개 — 마스크 칠하기 (pan) / '부분' — 상자 그리기 · 끌기 · 두 손가락 옮기기 (scale)
                                          //  ⚠️ pan 과 scale 을 같이 주면 GestureDetector 가 오류를 낸다 — 둘은 늘 하나만 (도구가 다르다)
                                          onPanStart: canDraw ? _onPanStart : null,
                                          onPanUpdate: canDraw ? _onPanUpdate : null,
                                          onPanEnd: canDraw ? _onPanEnd : null,
                                          onScaleStart: focusEditing ? _onFocusScaleStart : null,
                                          onScaleUpdate: focusEditing ? _onFocusScaleUpdate : null,
                                          onScaleEnd: focusEditing ? _onFocusScaleEnd : null,
                                          onTapDown:
                                              (_currentTool == 'zoom_in' || _currentTool == 'zoom_out')
                                              ? _onZoomTap
                                              : null,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              Image.memory(
                                                _mosaicPreviewImage != null &&
                                                        _i2iMode == I2iMode.mosaic
                                                    ? _mosaicPreviewImage!
                                                    : state.targetI2iImage!,
                                                fit: BoxFit.fill,
                                              ),
                                              Positioned.fill(
                                                child: CustomPaint(
                                                  key: _canvasKey,
                                                  painter: MaskPainter(
                                                    strokes:
                                                        (_i2iMode == I2iMode.upscale ||
                                                            _i2iMode == I2iMode.img2img ||
                                                            !_maskVisible ||
                                                            (_mosaicPreviewImage != null &&
                                                                _i2iMode == I2iMode.mosaic))
                                                        ? []
                                                        : _strokes,
                                                    maskColor: _maskColor,
                                                  ),
                                                  size: Size.infinite,
                                                ),
                                              ),
                                              // 부분 인페인트 상자 — 늘 자리를 둔다 (상자가 없으면 아무것도 안 그린다, DEVNOTES 2)
                                              Positioned.fill(
                                                child: CustomPaint(
                                                  painter: _FocusBoxPainter(
                                                    box: focusBox == null
                                                        ? null
                                                        : Rect.fromLTRB(
                                                            focusBox.x0.toDouble(),
                                                            focusBox.y0.toDouble(),
                                                            focusBox.x1.toDouble(),
                                                            focusBox.y1.toDouble(),
                                                          ),
                                                    interior: focusPlanNow == null
                                                        ? null
                                                        : Rect.fromLTRB(
                                                            focusPlanNow.interiorInImage.x0,
                                                            focusPlanNow.interiorInImage.y0,
                                                            focusPlanNow.interiorInImage.x1,
                                                            focusPlanNow.interiorInImage.y1,
                                                          ),
                                                    imageW: state.i2iImageSize?.$1 ?? 0,
                                                    imageH: state.i2iImageSize?.$2 ?? 0,
                                                    editing: focusEditing,
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
                            KeyedSubtree(
                              key: const ValueKey('i2iCompareView'),
                              child: comparing ? _buildCompareView(state) : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 도구 2줄(왼쪽) + 실행 버튼(오른쪽)
                  _buildBottomBar(state),
                  const SizedBox(height: 12),
                  // 맨 아래 줄: 프롬프트 보기 토글 + 비교 보기
                  //  ⚠️ Director 도구는 프롬프트를 쓰지 않으므로 '프롬프트 보기' 는 숨기고 비교만 오른쪽에 둔다.
                  //     시스템 내비게이션 바 여백은 늘 남겨야 버튼이 가리지 않는다.
                  Padding(
                    padding: EdgeInsets.only(bottom: bottomPad),
                    child: Row(
                      children: [
                        Expanded(
                          child: _directorMode
                              ? const SizedBox.shrink()
                              : _bottomLineButton(
                                  icon: Icons.expand_more,
                                  label: "프롬프트 보기",
                                  onTap: () => setState(() => _showCanvasView = false),
                                ),
                        ),
                        // 확장 켜기/끄기 — 인페인트에서만 (판 위로 그림을 옮겨 빈칸을 채운다). 비교와는 하나만.
                        if (_i2iMode == I2iMode.inpaint && !_directorMode) ...[
                          const SizedBox(width: 8),
                          // 탭: 켜기 · 끄기 / 꾹: 직전 확장 배치 그대로 다시 (결과가 마음에 안 들 때 — _restoreLastOutpaint)
                          _bottomLineButton(
                            icon: Icons.zoom_out_map,
                            label: "확장",
                            active: _moveMode,
                            enabled: state.targetI2iImage != null,
                            onTap: () => _toggleMoveMode(state),
                            onLongPress: () => _restoreLastOutpaint(state),
                          ),
                        ],
                        const SizedBox(width: 8),
                        // 비교 보기 켜기/끄기 — 보낸 원본(📌 고정한 그림)과 지금 그림을 나란히
                        _bottomLineButton(
                          icon: Icons.compare,
                          label: "비교",
                          active: comparing,
                          enabled: state.targetI2iImage != null,
                          onTap: () {
                            if (state.targetI2iImage == null) {
                              showToast(context, "히스토리에서 먼저 이미지를 선택해주세요!");
                              return;
                            }
                            _setCompareView(!_compareView);
                          },
                        ),
                      ],
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
                  color: AppColors.surface,
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
              title: "긍정적 프롬프트",
              icon: Icons.add_circle_outline,
              color: AppColors.teal,
              controller: state.inpaintPositiveController,
              cardId: 'positive',
              hint: "프롬프트를 입력하세요...",
            ),
            const SizedBox(height: 12),
            _buildPromptCard(
              context,
              state,
              title: "선행 프롬프트",
              icon: Icons.arrow_right_alt,
              color: AppColors.blue,
              controller: state.inpaintPrefixController,
              cardId: 'prefix',
              hint: "프롬프트를 입력하세요...",
            ),
            const SizedBox(height: 12),
            _buildPromptCard(
              context,
              state,
              title: "후행 프롬프트",
              icon: Icons.keyboard_double_arrow_right,
              color: AppColors.orange,
              controller: state.inpaintSuffixController,
              cardId: 'suffix',
              hint: "프롬프트를 입력하세요...",
            ),
            const SizedBox(height: 16),
            _buildPromptCard(
              context,
              state,
              title: "부정적 프롬프트",
              icon: Icons.remove_circle_outline,
              color: AppColors.red,
              controller: state.inpaintNegativeController,
              cardId: 'negative',
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
                    }); // 칸이 바로 채워져 보이므로 알리지 않는다
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
  final bool invert; // 마스킹 반전 표시 (점이 없다 — MaskStroke.invert)
  const _MaskStrokeData(this.pts, this.radius, this.isEraser, this.invert);
}

class _MaskBuildParams {
  final int maskW;
  final int maskH;
  final List<_MaskStrokeData> strokes;
  // 그림 자리 (판의 왼쪽 위) — 마스킹 반전은 여기만 뒤집는다 (채워 보내는 오른쪽 · 아래는 늘 안 칠한다)
  final int imageW;
  final int imageH;
  const _MaskBuildParams(this.maskW, this.maskH, this.strokes, this.imageW, this.imageH);
}

// grid 빌드 + raw 픽셀 배열(헤더 8바이트 + 1바이트/픽셀) 생성
Uint8List _buildMaskRaw(_MaskBuildParams p) => _maskRawOf(
  _paintMaskGrid(p.maskW, p.maskH, p.strokes, min(p.imageW, p.maskW), min(p.imageH, p.maskH)),
  p.maskW,
  p.maskH,
);

/// 부분 인페인트 마스크 만들기 — 잘라 키운 판(보낼 크기)에 옮긴 획 · 다시 그릴 곳 (FocusPlan.interior)
class _FocusMaskParams {
  final int maskW;
  final int maskH;
  final List<_MaskStrokeData> strokes;
  final OutpaintRect interior;
  const _FocusMaskParams(this.maskW, this.maskH, this.strokes, this.interior);
}

/// 부분 인페인트 마스크 — 판에 획을 칠하고(반전은 판 전체 — 잘라 낸 곳은 다 그림이다), 다시 그릴 곳 밖은 지운다.
///  안에 칠한 곳이 없으면 다시 그릴 곳 전체를 칠한다 (공식: 상자 안을 비우면 상자 안 전체). [painted] = 안에 칠한 곳이 있었는지.
({Uint8List raw, bool painted}) _buildFocusMaskRaw(_FocusMaskParams p) {
  final grid = _paintMaskGrid(p.maskW, p.maskH, p.strokes, p.maskW, p.maskH);
  final OutpaintRect r = p.interior;
  bool painted = false;
  for (int y = 0; y < p.maskH; y++) {
    final row = grid[y];
    final bool rowIn = y >= r.y0 && y < r.y1;
    for (int x = 0; x < p.maskW; x++) {
      if (rowIn && x >= r.x0 && x < r.x1) {
        if (row[x]) {
          painted = true;
        }
      } else {
        row[x] = false;
      }
    }
  }
  if (!painted) {
    for (int y = max(0, r.y0); y < min(p.maskH, r.y1); y++) {
      final row = grid[y];
      for (int x = max(0, r.x0); x < min(p.maskW, r.x1); x++) {
        row[x] = true;
      }
    }
  }
  return (raw: _maskRawOf(grid, p.maskW, p.maskH), painted: painted);
}

/// 획들을 [maskW]×[maskH] 칸에 칠한다 (true = 칠함). 마스킹 반전은 왼쪽 위 [invertW]×[invertH] 만 뒤집는다.
List<List<bool>> _paintMaskGrid(
  int maskW,
  int maskH,
  List<_MaskStrokeData> strokes,
  int invertW,
  int invertH,
) {
  final grid = List.generate(maskH, (_) => List.filled(maskW, false));

  for (final s in strokes) {
    if (s.invert) {
      _maskInvert(grid, invertW, invertH);
      continue;
    }
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
  return grid;
}

/// 칠한 칸 → raw (헤더 8바이트(가로 · 세로) + 1바이트/픽셀)
Uint8List _maskRawOf(List<List<bool>> grid, int maskW, int maskH) {
  final raw = Uint8List(8 + maskW * maskH);
  final header = ByteData.sublistView(raw);
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

// 마스킹 반전 — 왼쪽 위 [w]×[h] 칸을 뒤집는다 (인페인트/모자이크 isolate 공용)
void _maskInvert(List<List<bool>> grid, int w, int h) {
  for (int y = 0; y < h; y++) {
    final row = grid[y];
    for (int x = 0; x < w; x++) {
      row[x] = !row[x];
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
      if (stroke.isInvert) {
        // 마스킹 반전 — 판 전체를 xor 로 칠하면 칠한 곳은 빠지고 빈 곳은 칠해진다 (가장자리의 반투명도 반대로)
        canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..color = maskColor
            ..blendMode = BlendMode.xor,
        );
        continue;
      }
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

// ============================================================================
// 확장 — 판 바탕(빗금 = 새로 그려질 빈칸)과 덮개(판 밖 어둡게 · 새로 그릴 곳 · 판 테두리)
// ============================================================================
/// 확장에 쓰는 값 (_I2iTabState._moveInputs) — [iw] · [ih] 는 자른 그림, [fw] · [fh] 는 자르기 전 그림 전체,
///  [crop] 은 남길 곳 (그림 픽셀), [cw] · [ch] 는 판.
typedef _MoveInputs = ({
  Uint8List image,
  int iw,
  int ih,
  int fw,
  int fh,
  OutpaintRect crop,
  int cw,
  int ch,
});

/// 자른 곳만 보이게 — [rect] 가 null 이면 상자 전체 (자르는 중)
class _RectClipper extends CustomClipper<Rect> {
  final Rect? rect;

  const _RectClipper(this.rect);

  @override
  Rect getClip(Size size) => rect ?? Offset.zero & size;

  @override
  bool shouldReclip(covariant _RectClipper oldClipper) => oldClipper.rect != rect;
}

/// 확장의 자르기 — 그림 상자(돌리기 전 · 화면 픽셀) 안에 그린다. 자르는 중일 때만:
///  잘릴 곳은 회색으로 덮고, 자른 곳 테두리 · 3등분 선 · 모서리 'ㄱ' 손잡이 · 변 가운데 짧은 막대.
///  손잡이는 테두리 바깥으로 조금 내어 그린다 (자른 곳의 그림을 덜 가리게).
class _CropEditPainter extends CustomPainter {
  final Rect crop;
  final bool editing;

  const _CropEditPainter({required this.crop, required this.editing});

  @override
  void paint(Canvas canvas, Size size) {
    if (!editing) {
      return;
    }
    // 잘릴 곳 — 회색
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(crop);
    canvas.drawPath(outside, Paint()..color = const Color(0xB3424242));
    // 3등분 선
    final thin = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.35);
    for (int i = 1; i < 3; i++) {
      final double x = crop.left + crop.width * i / 3;
      final double y = crop.top + crop.height * i / 3;
      canvas.drawLine(Offset(x, crop.top), Offset(x, crop.bottom), thin);
      canvas.drawLine(Offset(crop.left, y), Offset(crop.right, y), thin);
    }
    _drawBoxFrame(canvas, crop);
  }

  @override
  bool shouldRepaint(covariant _CropEditPainter oldDelegate) =>
      oldDelegate.crop != crop || oldDelegate.editing != editing;
}

/// 상자 테두리와 손잡이 — 모서리 'ㄱ' · 변 가운데 짧은 막대 (테두리 바깥으로 조금 내어 그려 상자 안을 덜 가린다).
///  확장의 자르기 · 부분 인페인트 상자가 같이 쓴다. [handles] 가 거짓이면 테두리만.
void _drawBoxFrame(Canvas canvas, Rect r, {Color color = Colors.white, bool handles = true}) {
  canvas.drawRect(
    r,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color,
  );
  if (!handles) {
    return;
  }
  final handle = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 4
    ..strokeCap = StrokeCap.square
    ..color = color;
  const double o = 2; // 테두리 바깥으로 내는 만큼 (굵기의 반)
  // 모서리 'ㄱ' — 상자가 작아도 서로 겹치지 않게 짧아진다
  final double len = min(22.0, min(r.width, r.height) / 3);
  for (final (Offset c, double sx, double sy) in [
    (r.topLeft, 1.0, 1.0),
    (r.topRight, -1.0, 1.0),
    (r.bottomRight, -1.0, -1.0),
    (r.bottomLeft, 1.0, -1.0),
  ]) {
    final Offset k = c - Offset(sx * o, sy * o);
    canvas.drawPath(
      Path()
        ..moveTo(k.dx, k.dy + sy * len)
        ..lineTo(k.dx, k.dy)
        ..lineTo(k.dx + sx * len, k.dy),
      handle,
    );
  }
  // 변 가운데 짧은 막대
  final double bar = min(12.0, min(r.width, r.height) / 6);
  final Offset m = r.center;
  canvas.drawLine(Offset(m.dx - bar, r.top - o), Offset(m.dx + bar, r.top - o), handle);
  canvas.drawLine(Offset(m.dx - bar, r.bottom + o), Offset(m.dx + bar, r.bottom + o), handle);
  canvas.drawLine(Offset(r.left - o, m.dy - bar), Offset(r.left - o, m.dy + bar), handle);
  canvas.drawLine(Offset(r.right + o, m.dy - bar), Offset(r.right + o, m.dy + bar), handle);
}

/// 부분 인페인트 상자 — 그림 위(화면 캔버스 좌표)에 그린다. 상자 밖은 어둡게, 맥락 띠(다시 그리지 않는 곳)는 빨갛게,
///  '부분' 도구일 때만 손잡이. 상자가 없으면 아무것도 안 그린다 (캔버스의 자식 수는 늘 같게 — DEVNOTES 2).
///  [box] · [interior] 는 그림 픽셀 — 캔버스 크기 ÷ 그림 크기로 옮긴다.
class _FocusBoxPainter extends CustomPainter {
  final Rect? box;
  final Rect? interior;
  final int imageW;
  final int imageH;
  final bool editing;

  const _FocusBoxPainter({
    required this.box,
    required this.interior,
    required this.imageW,
    required this.imageH,
    required this.editing,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Rect? b = box;
    if (b == null || imageW <= 0 || imageH <= 0) {
      return;
    }
    final double kx = size.width / imageW;
    final double ky = size.height / imageH;
    Rect toCanvas(Rect r) => Rect.fromLTRB(r.left * kx, r.top * ky, r.right * kx, r.bottom * ky);
    final Rect cb = toCanvas(b);
    // 상자 밖 — 어둡게 (이번엔 건드리지 않는 곳)
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(cb),
      Paint()..color = const Color(0x8C000000),
    );
    // 맥락 띠 — 빨갛게 (보내지만 다시 그리지 않는 곳)
    final Rect? i = interior;
    if (i != null) {
      final Rect ci = toCanvas(i).intersect(cb);
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(cb)
          ..addRect(ci),
        Paint()..color = Colors.redAccent.withValues(alpha: 0.3),
      );
    }
    _drawBoxFrame(canvas, cb, color: editing ? Colors.white : Colors.white70, handles: editing);
  }

  @override
  bool shouldRepaint(covariant _FocusBoxPainter oldDelegate) =>
      oldDelegate.box != box ||
      oldDelegate.interior != interior ||
      oldDelegate.imageW != imageW ||
      oldDelegate.imageH != imageH ||
      oldDelegate.editing != editing;
}

class _OutpaintFramePainter extends CustomPainter {
  const _OutpaintFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = AppColors.surfaceAlt);
    // 빗금 — 그림이 없는 곳이 '비어 있다'는 걸 보여 준다 (그림이 위를 덮는다)
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..strokeWidth = 1;
    canvas.save();
    canvas.clipRect(r);
    const double gap = 12;
    for (double d = -size.height; d < size.width; d += gap) {
      canvas.drawLine(Offset(d, size.height), Offset(d + size.height, 0), line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OutpaintFramePainter oldDelegate) => false;
}

class _OutpaintOverlayPainter extends CustomPainter {
  final Rect frame; // 판 (화면 좌표)
  final List<Rect> keep; // 원본을 남길 곳 — 8픽셀 칸을 이은 사각형들 (비었으면 판 전체를 새로 그린다)
  final bool showFill; // 새로 그릴 곳을 칠해 보일지 (눈 버튼)
  final Color fillColor;
  final bool warn; // 채울 빈칸이 없다 — 테두리를 경고색으로

  const _OutpaintOverlayPainter({
    required this.frame,
    required this.keep,
    required this.showFill,
    required this.fillColor,
    required this.warn,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 판 밖 — 보낼 때 잘리는 곳
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.6));
    // 새로 그릴 곳 = 판 − 남길 곳 (빈칸 + 경계, 8픽셀 칸에 맞춘 실제 마스크 그대로 — 남길 곳 사각형끼리는 안 겹친다)
    if (showFill) {
      final fill = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(frame);
      for (final r in keep) {
        fill.addRect(r);
      }
      canvas.drawPath(fill, Paint()..color = fillColor.withValues(alpha: 0.3));
    }
    // 판 테두리
    canvas.drawRect(
      frame.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = warn ? AppColors.amber : AppColors.accent,
    );
  }

  @override
  bool shouldRepaint(covariant _OutpaintOverlayPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      !listEquals(oldDelegate.keep, keep) ||
      oldDelegate.showFill != showFill ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.warn != warn;
}
