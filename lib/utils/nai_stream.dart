// lib/utils/nai_stream.dart
//
// NovelAI 스트리밍 생성(/ai/generate-image-stream) 응답 읽기 — 화면 · 서버와 무관한 순수 코드 (test/nai_stream_test.dart).
//  · 요청은 보통 생성과 같고 parameters 에 "stream": "msgpack" 만 더한다 (NovelAI 웹도 V4 부터 이 길로 생성한다).
//  · 응답은 '메시지' 가 이어진다: [길이 4바이트 (빅엔디안)] + [msgpack 한 덩어리] 가 반복.
//    한 덩어리 = {event_type: "intermediate" | "final", step_ix, samp_ix, gen_id, sigma, image}
//      intermediate — 중간 단계 미리보기 (JPEG), final — 완성 그림 (PNG, 그림 정보 포함)
//  · 혹시 SSE(글자: "event: …\ndata: {json}\n\n", image 는 base64)로 오면 그것도 읽는다.
//  ⚠️ 받는 조각(chunk)은 메시지 경계와 상관없이 잘려 온다 — 모자라면 다음 조각까지 기다린다.
import 'dart:convert';
import 'dart:typed_data';

/// 스트림 한 칸 — 중간 단계(미리보기) 또는 마지막 그림.
typedef NaiStreamEvent = ({bool isFinal, int step, Uint8List image});

/// 받은 조각을 차례로 넣으면 다 모인 칸들을 돌려준다.
class NaiStreamReader {
  Uint8List _buf = Uint8List(0);
  int _start = 0; // 아직 안 읽은 첫 자리
  int _end = 0; // 채운 끝
  bool? _sse; // 첫 글자를 보고 정한다 (null = 아직 모름)

  /// [chunk] 를 더하고, 이번에 다 모인 칸들을 돌려준다 (없으면 빈 목록).
  List<NaiStreamEvent> add(List<int> chunk) {
    _append(chunk);
    _sse ??= _looksLikeSse();
    return _sse == true ? _readSse() : _readFrames();
  }

  /// 응답이 끝났을 때 — SSE 는 마지막 빈 줄 없이 끝날 수 있어 남은 것을 마저 읽는다.
  List<NaiStreamEvent> close() {
    if (_sse != true || _end == _start) {
      return const [];
    }
    final String rest = utf8.decode(Uint8List.sublistView(_buf, _start, _end), allowMalformed: true);
    _start = _end;
    final ev = _sseEvent(rest);
    return ev == null ? const [] : [ev];
  }

  void _append(List<int> chunk) {
    final int pending = _end - _start;
    if (_end + chunk.length > _buf.length) {
      // 앞쪽(이미 읽은 자리)을 버리고, 그래도 모자라면 늘린다
      final int need = pending + chunk.length;
      final Uint8List next = need > _buf.length ? Uint8List(need * 2) : _buf;
      next.setRange(0, pending, _buf, _start);
      _buf = next;
      _start = 0;
      _end = pending;
    }
    _buf.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  // 'event:' · 'data:' · ':'(주석)으로 시작하면 SSE. 몇 글자 모이기 전엔 정하지 않는다.
  bool? _looksLikeSse() {
    if (_end - _start < 5) {
      return null;
    }
    final String head = ascii.decode(
      Uint8List.sublistView(_buf, _start, _start + 5),
      allowInvalid: true,
    );
    return head.startsWith('event') || head.startsWith('data:') || head.startsWith(':');
  }

  List<NaiStreamEvent> _readFrames() {
    final out = <NaiStreamEvent>[];
    while (_end - _start >= 4) {
      final int len =
          (_buf[_start] << 24) | (_buf[_start + 1] << 16) | (_buf[_start + 2] << 8) | _buf[_start + 3];
      if (_end - _start - 4 < len) {
        break; // 이 메시지가 아직 다 안 왔다
      }
      final Uint8List msg = Uint8List.sublistView(_buf, _start + 4, _start + 4 + len);
      _start += 4 + len;
      final ev = _eventOf(_decodeMessage(msg));
      if (ev != null) {
        out.add(ev);
      }
    }
    return out;
  }

  List<NaiStreamEvent> _readSse() {
    final out = <NaiStreamEvent>[];
    while (true) {
      // 칸 사이는 빈 줄 ("\n\n" 또는 "\r\n\r\n") — 글자로 바꾸기 전에 바이트로 찾는다
      //  (base64 그림이 커서 조각마다 통째로 글자로 바꾸면 느리다)
      int cut = -1;
      int next = -1;
      for (int i = _start; i < _end; i++) {
        if (_buf[i] != 0x0A) {
          continue;
        }
        int j = i + 1;
        if (j < _end && _buf[j] == 0x0D) {
          j++;
        }
        if (j < _end && _buf[j] == 0x0A) {
          cut = i;
          next = j + 1;
          break;
        }
      }
      if (cut < 0) {
        break;
      }
      final String raw = utf8.decode(Uint8List.sublistView(_buf, _start, cut), allowMalformed: true);
      _start = next;
      final ev = _sseEvent(raw);
      if (ev != null) {
        out.add(ev);
      }
    }
    return out;
  }

  static NaiStreamEvent? _sseEvent(String raw) {
    final data = StringBuffer();
    for (final line in raw.split('\n')) {
      if (line.startsWith('data:')) {
        data.write(line.replaceFirst('data:', '').trim());
      }
    }
    if (data.isEmpty) {
      return null;
    }
    try {
      return _eventOf(jsonDecode(data.toString()));
    } catch (_) {
      return null;
    }
  }

  // msgpack 이 아니면 JSON 으로 한 번 더 (다른 클라이언트도 그렇게 받는다)
  static Object? _decodeMessage(Uint8List msg) {
    try {
      return decodeMsgpack(msg);
    } catch (_) {
      try {
        return jsonDecode(utf8.decode(msg));
      } catch (_) {
        return null;
      }
    }
  }

  static NaiStreamEvent? _eventOf(Object? obj) {
    if (obj is! Map) {
      return null;
    }
    final Object? type = obj['event_type'];
    if (type != 'intermediate' && type != 'final') {
      return null; // 모르는 칸은 건너뛴다
    }
    final Object? raw = obj['image'];
    Uint8List? image;
    if (raw is Uint8List) {
      image = raw;
    } else if (raw is String) {
      try {
        image = base64Decode(raw);
      } catch (_) {
        image = null;
      }
    } else if (raw is List) {
      image = Uint8List.fromList(raw.whereType<int>().toList());
    }
    if (image == null || image.isEmpty) {
      return null;
    }
    final Object? step = obj['step_ix'];
    return (isFinal: type == 'final', step: step is int ? step : 0, image: image);
  }
}

/// msgpack 한 덩어리를 Dart 값으로 (Map · List · String · int · double · bool · null · Uint8List).
///  스트림 응답에 필요한 만큼만 — ext 형식은 건너뛰고 null 로 둔다. 모양이 틀리면 FormatException.
///  bin(그림)은 복사본으로 돌려준다 (읽는 버퍼가 나중에 다시 쓰여도 그림이 바뀌지 않게).
Object? decodeMsgpack(Uint8List data) {
  final reader = _Msgpack(data);
  final Object? value = reader.read();
  if (reader.pos != data.length) {
    throw const FormatException('msgpack: 남는 바이트가 있음');
  }
  return value;
}

class _Msgpack {
  _Msgpack(this.b) : v = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData v;
  int pos = 0;

  int _take(int n) {
    if (pos + n > b.length) {
      throw const FormatException('msgpack: 잘린 데이터');
    }
    final int at = pos;
    pos += n;
    return at;
  }

  int _u8() => b[_take(1)];
  int _u16() => v.getUint16(_take(2));
  int _u32() => v.getUint32(_take(4));

  String _str(int n) => utf8.decode(Uint8List.sublistView(b, _take(n), pos), allowMalformed: true);
  Uint8List _bin(int n) => b.sublist(_take(n), pos);

  List<Object?> _array(int n) => [for (int i = 0; i < n; i++) read()];

  Map<Object?, Object?> _map(int n) {
    final m = <Object?, Object?>{};
    for (int i = 0; i < n; i++) {
      final Object? key = read();
      m[key] = read();
    }
    return m;
  }

  // ext: 종류 1바이트 + 내용 n — 쓰지 않으므로 건너뛴다
  Object? _ext(int n) {
    _take(1 + n);
    return null;
  }

  Object? read() {
    final int t = _u8();
    if (t <= 0x7f) return t; // 양수 fixint
    if (t >= 0xe0) return t - 0x100; // 음수 fixint
    if (t <= 0x8f) return _map(t & 0x0f);
    if (t <= 0x9f) return _array(t & 0x0f);
    if (t <= 0xbf) return _str(t & 0x1f);
    switch (t) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        return _bin(_u8());
      case 0xc5:
        return _bin(_u16());
      case 0xc6:
        return _bin(_u32());
      case 0xc7:
        return _ext(_u8());
      case 0xc8:
        return _ext(_u16());
      case 0xc9:
        return _ext(_u32());
      case 0xca:
        return v.getFloat32(_take(4));
      case 0xcb:
        return v.getFloat64(_take(8));
      case 0xcc:
        return _u8();
      case 0xcd:
        return _u16();
      case 0xce:
        return _u32();
      case 0xcf:
        return v.getUint64(_take(8));
      case 0xd0:
        return v.getInt8(_take(1));
      case 0xd1:
        return v.getInt16(_take(2));
      case 0xd2:
        return v.getInt32(_take(4));
      case 0xd3:
        return v.getInt64(_take(8));
      case 0xd4:
        return _ext(1);
      case 0xd5:
        return _ext(2);
      case 0xd6:
        return _ext(4);
      case 0xd7:
        return _ext(8);
      case 0xd8:
        return _ext(16);
      case 0xd9:
        return _str(_u8());
      case 0xda:
        return _str(_u16());
      case 0xdb:
        return _str(_u32());
      case 0xdc:
        return _array(_u16());
      case 0xdd:
        return _array(_u32());
      case 0xde:
        return _map(_u16());
      case 0xdf:
        return _map(_u32());
    }
    throw FormatException('msgpack: 모르는 형식 0x${t.toRadixString(16)}');
  }
}
