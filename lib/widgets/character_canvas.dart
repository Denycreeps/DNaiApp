import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../models/nai_character.dart';
import '../app_theme.dart';

/// 캐릭터 위치를 캔버스에서 직접 지정하는 위젯 (V5용).
///
/// V5는 5x5 그리드 대신 캔버스 어디든 좌표를 찍을 수 있다.
///  · 빈 곳을 탭 → 선택된 캐릭터를 그 자리로 이동
///  · 마커를 탭 → 그 캐릭터를 선택
///  · 마커를 드래그 → 위치 미세 조정
///
/// 좌표는 0.0~1.0 비율이라 해상도가 바뀌어도 그대로 쓸 수 있다.
class CharacterCanvas extends StatefulWidget {
  final List<NaiCharacter> characters;
  final int selectedIndex;
  final double aspectRatio; // 생성 해상도 비율 (예: 832/1216)
  final bool showGrid; // 정렬용 격자선
  final bool snapToGrid; // 0.05 단위로 맞추기

  /// 격자 칸 수 (가로/세로 따로). 2면 가운데 1줄이 생긴다.
  final int gridCols;
  final int gridRows;

  /// 배경으로 깔 이미지 (선택).
  ///  공식처럼 실제 그림을 보면서 위치를 잡을 수 있게 한다.
  ///  null이면 빈 캔버스로 그린다.
  final Uint8List? backgroundImage;

  /// 배경 이미지의 투명도 (0.0~1.0). 마커가 묻히지 않게 살짝 흐리게 둔다.
  final double backgroundOpacity;
  final void Function(int index) onSelect;
  final void Function(int index, double x, double y) onMove;

  const CharacterCanvas({
    super.key,
    required this.characters,
    required this.selectedIndex,
    required this.onSelect,
    required this.onMove,
    this.aspectRatio = 832 / 1216,
    this.showGrid = false,
    this.snapToGrid = false,
    this.gridCols = 5,
    this.gridRows = 5,
    this.backgroundImage,
    this.backgroundOpacity = 0.45,
  });

  @override
  State<CharacterCanvas> createState() => _CharacterCanvasState();
}

class _CharacterCanvasState extends State<CharacterCanvas> {
  // 드래그 중인 마커. null이면 드래그 아님.
  int? _dragging;

  static const double _markerSize = 34;

  // 마커 색상 — 캐릭터 번호로 구분한다
  static const List<Color> _palette = [
    AppColors.purple, // 보라
    AppColors.teal, // 청록
    Color(0xFFFF7043), // 주황
    Color(0xFF42A5F5), // 파랑
    Color(0xFFEC407A), // 분홍
    Color(0xFF9CCC65), // 연두
    Color(0xFFFFCA28), // 노랑
    Color(0xFF26C6DA), // 하늘
  ];

  // 사용자가 정한 색이 있으면 그걸 쓰고, 없으면 번호별 기본 팔레트
  Color _colorOf(int i) {
    final custom = widget.characters[i].colorArgb;
    if (custom != null) {
      return Color(custom);
    }
    return _palette[i % _palette.length];
  }

  double _snap(double v) {
    if (!widget.snapToGrid) {
      return v;
    }
    return (v / 0.05).round() * 0.05;
  }

  /// 화면 좌표 → 0~1 비율
  Offset _toRatio(Offset local, Size size) {
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  /// 그 지점에 있는 마커 찾기 (가까운 것 우선)
  int? _hitTest(Offset ratio, Size size) {
    double best = double.infinity;
    int? found;
    for (int i = 0; i < widget.characters.length; i++) {
      final c = widget.characters[i];
      if (!c.isActive) {
        continue;
      }
      final dx = (c.centerX - ratio.dx) * size.width;
      final dy = (c.centerY - ratio.dy) * size.height;
      final dist = dx * dx + dy * dy;
      // 마커 크기 정도로 가까우면 명중
      if (dist < (_markerSize * _markerSize) && dist < best) {
        best = dist;
        found = i;
      }
    }
    return found;
  }

  void _onTapDown(TapDownDetails d, Size size) {
    final ratio = _toRatio(d.localPosition, size);
    final hit = _hitTest(ratio, size);
    if (hit != null) {
      widget.onSelect(hit); // 마커 탭 → 선택
    } else if (widget.selectedIndex < widget.characters.length) {
      // 빈 곳 탭 → 선택된 캐릭터를 그 자리로
      widget.onMove(widget.selectedIndex, _snap(ratio.dx), _snap(ratio.dy));
    }
  }

  void _onPanStart(DragStartDetails d, Size size) {
    final ratio = _toRatio(d.localPosition, size);
    final hit = _hitTest(ratio, size);
    if (hit != null) {
      setState(() => _dragging = hit);
      widget.onSelect(hit);
    }
  }

  void _onPanUpdate(DragUpdateDetails d, Size size) {
    final i = _dragging;
    if (i == null) {
      return;
    }
    final ratio = _toRatio(d.localPosition, size);
    widget.onMove(i, _snap(ratio.dx), _snap(ratio.dy));
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          // ⚠️ 이 위젯은 세로 스크롤(ListView) 안에 놓인다.
          //    보통의 GestureDetector는 세로 드래그를 스크롤에게 양보하기 때문에
          //    마커를 위아래로 끌면 터치가 씹히고 화면만 스크롤된다.
          //    그래서 제스처 경쟁에서 곧바로 이기는 인식기를 직접 등록한다.
          return RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              _EagerPanRecognizer: GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                () => _EagerPanRecognizer(),
                (r) {
                  // ⚠️ 콜백은 void를 돌려줘야 한다.
                  //    `(d) => _onPanStart(...)` 형태로 쓰면 void 값을 반환하는
                  //    꼴이 되어 분석기가 오류로 잡는다. 블록으로 감싼다.
                  r.onStart = (d) {
                    _onPanStart(d, size);
                  };
                  r.onUpdate = (d) {
                    _onPanUpdate(d, size);
                  };
                  r.onEnd = (_) {
                    setState(() => _dragging = null);
                  };
                  r.onCancel = () {
                    setState(() => _dragging = null);
                  };
                },
              ),
              TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(),
                (r) {
                  r.onTapDown = (d) {
                    _onTapDown(d, size);
                  };
                },
              ),
            },
            child: Stack(
              children: [
                // 배경 — 실제 생성될 그림의 영역을 나타낸다.
                //  이미지가 있으면 그걸 깔고, 없으면 회색 판으로 둔다.
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt, // 작업 영역(회색)
                        border: Border.all(color: Colors.white24),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: widget.backgroundImage == null
                          ? null
                          : Opacity(
                              opacity: widget.backgroundOpacity,
                              child: Image.memory(
                                widget.backgroundImage!,
                                fit: BoxFit.cover,
                                // 작게만 보이므로 원본을 통째로 디코드하지 않는다
                                cacheWidth: 512,
                                gaplessPlayback: true,
                              ),
                            ),
                    ),
                  ),
                ),
                // 격자선 (정렬용, 선택)
                if (widget.showGrid)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _GridPainter(cols: widget.gridCols, rows: widget.gridRows),
                    ),
                  ),
                // 캐릭터 마커
                for (int i = 0; i < widget.characters.length; i++)
                  if (widget.characters[i].isActive)
                    Positioned(
                      left: widget.characters[i].centerX * size.width - _markerSize / 2,
                      top: widget.characters[i].centerY * size.height - _markerSize / 2,
                      child: _marker(i, i == widget.selectedIndex),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _marker(int index, bool selected) {
    final color = _colorOf(index);
    final char = widget.characters[index];
    // 마커가 작아서 긴 이름은 어차피 다 안 보인다. 앞부분만 쓴다.
    //  ⚠️ substring은 이모지 중간을 잘라 크래시하므로 runes(실제 글자) 기준으로 자른다.
    String label = char.name.isNotEmpty ? char.name : "${index + 1}";
    const int maxLabel = 5;
    final runes = label.runes.toList();
    if (runes.length > maxLabel) {
      label = String.fromCharCodes(runes.take(maxLabel));
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: _markerSize,
      height: _markerSize,
      decoration: BoxDecoration(
        color: color.withValues(alpha: selected ? 0.9 : 0.55),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? Colors.white : Colors.white24,
          width: selected ? 2 : 1,
        ),
        boxShadow: selected
            ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)]
            : null,
      ),
      alignment: Alignment.center,
      // 이름 길이가 제각각이라 마커(34px) 안에 그대로 넣으면 넘쳐서 오류가 난다.
      //  · substring으로 자르면 이모지 중간이 잘려 크래시한다.
      //  · clip은 '그리기'만 자를 뿐 레이아웃은 자연 크기를 요구한다.
      //  그래서 FittedBox로 감싸 마커 안에 들어가도록 자동 축소한다.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

/// 세로 스크롤 안에서도 드래그를 놓치지 않는 Pan 인식기.
///  기본 인식기는 스크롤과 경쟁하다 지는 경우가 있어, 여기서는 곧바로 승리를 선언한다.
class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// 정렬을 돕는 옅은 격자선 (5x5).
///  V4.5의 5x5 배치 그리드와 칸이 맞아떨어져 감각을 그대로 쓸 수 있다.
///  ⚠️ 5등분 선은 0.2/0.4/0.6/0.8에 오므로 중앙(0.5)과 겹치지 않는다.
///     예전에 중앙선을 따로 그렸더니 선이 몰려 보여서 뺐다.
///  (공식은 Thirds / Phi / 2~12칸 Grid를 지원한다 — 필요해지면 여기서 확장)
class _GridPainter extends CustomPainter {
  /// 칸 수 (2면 가운데 1줄). 가로·세로를 따로 정한다.
  final int cols;
  final int rows;

  const _GridPainter({required this.cols, required this.rows});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    // 세로선 (칸을 나누는 선은 칸 수보다 하나 적다)
    for (int i = 1; i < cols; i++) {
      final x = size.width * i / cols;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    // 가로선
    for (int i = 1; i < rows; i++) {
      final y = size.height * i / rows;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.cols != cols || oldDelegate.rows != rows;
}
