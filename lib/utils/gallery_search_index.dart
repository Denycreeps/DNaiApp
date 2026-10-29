// lib/utils/gallery_search_index.dart
//
// 갤러리 검색의 바탕 — 화면 · AppState 와 무관한 코드 (test/gallery_search_index_test.dart).
//  · 부분 읽기 (readSearchMetadata): 그림 파일을 통째로 읽지 않고 '그림 정보' 가 든 부분만 읽는다.
//      PNG  — 앞에서부터 청크 머리를 따라가 글자 청크(tEXt · zTXt · iTXt)만. 그림 데이터(IDAT)를 만나면 멈춘다.
//             NovelAI(와 그 그림을 그대로 저장하는 이 앱)는 글자 청크를 IDAT 앞에 둔다.
//             ⚠️ 글자 청크를 IDAT 뒤에 두는 다른 프로그램의 그림은 '그림 정보 없음' 으로 본다.
//      WebP — 청크 머리를 따라가 VP8X(크기)와 EXIF(그림 정보)만. NovelAI · 이 앱은 EXIF 를 그림 데이터 뒤에 둔다.
//    읽은 조각으로 '필요한 청크만 담은 작은 PNG/WebP' 를 만들어 image_metadata.dart 의
//    extractNovelAIMetadata 에 넘긴다 — 그림 정보를 읽는 규칙은 그쪽 한 곳뿐이다 (DEVNOTES 6).
//  · 색인 (GallerySearchIndex): 파일 uri → (수정 시각, 찾을 글). 수정 시각이 다르면 다시 읽는다.
//      앱 캐시 폴더에 gzip JSON 파일 하나 (1,000장 ≈ 0.1MB). 폰이 캐시를 지워도 다시 만들면 된다.
//      ⚠️ 찾을 글을 만드는 규칙(history_search.dart 의 historySearchText)을 바꾸면 [GallerySearchIndex.version] 을 올린다.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../models/image_metadata.dart';

/// 파일의 [start] 부터 [count] 바이트를 읽는다 — 파일 끝이면 그보다 짧게. 읽지 못하면 null.
typedef RangeReader = Future<Uint8List?> Function(int start, int count);

/// 부분 읽기 결과 — [ok] 가 false 면 파일을 읽지 못한 것 (다음에 다시 읽어 본다 — 색인에 넣지 않는다).
///  [ok] 인데 [meta] 가 null 이면 그림 정보가 없는 그림이다 (색인에 '없음' 으로 넣어 다시 읽지 않는다).
typedef SearchMetaResult = ({bool ok, NaiMetadata? meta});

const int _kHeadBytes = 64 * 1024; // 한 번에 읽는 양 — NovelAI PNG 는 그림 정보가 거의 다 처음 64KB 안에 있다
const int _kMaxChunks = 256; // 청크 머리를 따라가는 횟수 상한 (깨진 파일에서 헤매지 않게)
const int _kMaxChunkBytes = 4 * 1024 * 1024; // 그림 정보 청크가 이보다 크면 깨진 것으로 본다 (보통 수 KB)

/// 그림 파일에서 그림 정보만 읽는다 (위 설명). JPEG · GIF 등은 그림 정보가 없어 더 읽지 않는다.
Future<SearchMetaResult> readSearchMetadata(RangeReader read) async {
  final Uint8List? head = await _readFully(read, 0, _kHeadBytes);
  if (head == null) {
    return (ok: false, meta: null);
  }
  final win = _Window(read, head);
  try {
    if (_isPng(head)) {
      return (ok: true, meta: await _pngMetadata(win));
    }
    if (_isWebp(head)) {
      return (ok: true, meta: await _webpMetadata(win, head));
    }
  } on _ReadFailed {
    return (ok: false, meta: null);
  } catch (e) {
    debugPrint('갤러리 검색: 그림 정보 읽기 실패(정보 없음으로): $e');
  }
  return (ok: true, meta: null);
}

/// 읽기가 실패했다 (저장소 오류) — 파일 끝에 닿은 것과는 다르다 (그건 null)
class _ReadFailed implements Exception {}

/// [count] 바이트를 다 받을 때까지 읽는다 (한 번에 덜 주는 저장소가 있다). 파일 끝이면 거기까지.
///  읽기가 실패하면(저장소 오류 — 빈 조각이 아니라 null) null — 도중이어도 (반쯤 읽은 것을 '정보 없음' 으로 굳히지 않게).
Future<Uint8List?> _readFully(RangeReader read, int start, int count) async {
  final first = await read(start, count);
  if (first == null || first.isEmpty || first.length >= count) {
    return first;
  }
  final out = BytesBuilder(copy: false)..add(first);
  while (out.length < count) {
    final more = await read(start + out.length, count - out.length);
    if (more == null) {
      return null;
    }
    if (more.isEmpty) {
      break; // 파일 끝
    }
    out.add(more); // 늘 조금이라도 늘어나므로 끝난다
  }
  return out.toBytes();
}

/// 파일의 한 구간을 들고 있다가, 그 안이면 거기서 주고 밖이면 그 자리부터 새로 읽는다
///  (청크 머리와 내용이 붙어 있어 한 번 읽으면 보통 둘 다 들어온다).
class _Window {
  _Window(this._read, this._buf);
  final RangeReader _read;
  Uint8List _buf;
  int _start = 0;

  /// [start] 부터 [count] 바이트. 파일 끝에 걸려 모자라면 null. 읽지 못하면 [_ReadFailed].
  Future<Uint8List?> at(int start, int count) async {
    if (start >= _start && start + count <= _start + _buf.length) {
      return Uint8List.sublistView(_buf, start - _start, start - _start + count);
    }
    final got = await _readFully(_read, start, count > _kHeadBytes ? count : _kHeadBytes);
    if (got == null) {
      throw _ReadFailed();
    }
    _buf = got;
    _start = start;
    return got.length >= count ? Uint8List.sublistView(got, 0, count) : null;
  }
}

bool _isPng(Uint8List b) =>
    b.length >= 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47 &&
    b[4] == 0x0D &&
    b[5] == 0x0A &&
    b[6] == 0x1A &&
    b[7] == 0x0A;

bool _isWebp(Uint8List b) =>
    b.length >= 12 &&
    ascii.decode(b.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
    ascii.decode(b.sublist(8, 12), allowInvalid: true) == 'WEBP';

List<int> _u32le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

// PNG — 서명 · IHDR · 글자 청크만 모은 작은 PNG 로 읽는다 (그림 데이터 IDAT 를 만나면 멈춘다)
Future<NaiMetadata?> _pngMetadata(_Window win) async {
  final out = BytesBuilder(copy: false)..add((await win.at(0, 8))!);
  int offset = 8;
  bool hasText = false;
  for (int n = 0; n < _kMaxChunks; n++) {
    final Uint8List? hdr = await win.at(offset, 8);
    if (hdr == null) {
      break; // 파일 끝
    }
    final int len = ByteData.sublistView(hdr).getUint32(0);
    final String type = ascii.decode(hdr.sublist(4, 8), allowInvalid: true);
    if (type == 'IDAT' || type == 'IEND') {
      break;
    }
    if (type == 'IHDR' || type == 'tEXt' || type == 'zTXt' || type == 'iTXt') {
      if (len > _kMaxChunkBytes) {
        break;
      }
      // 머리 + 내용 + CRC(4) — 읽는 쪽은 CRC 를 보지 않지만 청크 모양은 그대로 둔다
      final Uint8List? chunk = await win.at(offset, 12 + len);
      if (chunk == null) {
        break; // 잘린 파일
      }
      out.add(chunk);
      hasText = hasText || type != 'IHDR';
    }
    offset += 12 + len;
  }
  if (!hasText) {
    return null;
  }
  out.add(const [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]); // IEND
  return extractNovelAIMetadata(out.toBytes());
}

// WebP — VP8X(크기) · EXIF(그림 정보)만 모은 작은 WebP 로 읽는다
//  RIFF 머리에 적힌 크기까지만 따라간다 — 파일 끝 너머를 읽으려 하지 않게 (저장소에 따라 오류가 나면 '못 읽음' 이 되어
//  그림 정보가 없는 WebP 를 매번 다시 읽게 된다)
Future<NaiMetadata?> _webpMetadata(_Window win, Uint8List head) async {
  final int riffEnd = 8 + ByteData.sublistView(head).getUint32(4, Endian.little);
  Uint8List? vp8x;
  Uint8List? exif;
  int offset = 12;
  for (int n = 0; n < _kMaxChunks && offset + 8 <= riffEnd; n++) {
    final Uint8List? hdr = await win.at(offset, 8);
    if (hdr == null) {
      break; // 파일 끝
    }
    final String fourcc = ascii.decode(hdr.sublist(0, 4), allowInvalid: true);
    final int len = ByteData.sublistView(hdr).getUint32(4, Endian.little);
    if (fourcc == 'VP8X' || fourcc == 'EXIF') {
      if (len > _kMaxChunkBytes) {
        break;
      }
      final Uint8List? chunk = await win.at(offset, 8 + len);
      if (chunk == null) {
        break; // 잘린 파일
      }
      // 홀수 길이면 1바이트 채움 (WebP 규칙 — 읽는 쪽이 다음 청크 자리를 그렇게 센다)
      final bytes = len.isOdd ? (BytesBuilder(copy: false)..add(chunk)..addByte(0)).toBytes() : chunk;
      if (fourcc == 'EXIF') {
        exif = bytes;
        break;
      }
      vp8x = bytes;
    }
    offset += 8 + len + (len.isOdd ? 1 : 0);
  }
  if (exif == null) {
    return null;
  }
  final body = (BytesBuilder(copy: false)
        ..add(ascii.encode('WEBP'))
        ..add(vp8x ?? const <int>[])
        ..add(exif))
      .toBytes();
  final webp = (BytesBuilder(copy: false)
        ..add(ascii.encode('RIFF'))
        ..add(_u32le(body.length))
        ..add(body))
      .toBytes();
  return extractNovelAIMetadata(webp);
}

// ════════════════════════════════════════════════════════════════════════════
// 색인
// ════════════════════════════════════════════════════════════════════════════

/// 색인 한 칸 — 파일의 수정 시각(ms) · 마지막으로 본 날(1970-01-01 부터 며칠) · 찾을 글('' = 그림 정보 없음)
typedef _Entry = ({int modified, int seen, String text});

class GallerySearchIndex {
  GallerySearchIndex._(this._items);

  /// 빈 색인 (테스트 · 파일이 없을 때)
  factory GallerySearchIndex.empty() => GallerySearchIndex._({});

  /// 색인 모양 — 찾을 글을 만드는 규칙이 바뀌면 올린다 (옛 색인은 버리고 새로 만든다)
  static const int version = 1;

  /// 이 날수 동안 한 번도 보이지 않은 파일은 저장할 때 뺀다 (지우거나 옮긴 그림이 쌓이지 않게)
  static const int keepDays = 60;

  final Map<String, _Entry> _items;
  bool _dirty = false;

  int get length => _items.length;

  /// 바뀐 게 있는지 (저장할 게 있는지)
  bool get isDirty => _dirty;

  static int _today() => DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  /// [uri] 의 찾을 글. 색인에 없거나 파일이 바뀌었으면([modified] 가 다르면) null — 다시 읽어야 한다.
  ///  찾으면 '오늘 봤다' 고 적는다 (오래 안 보인 칸을 지울 때 쓴다).
  String? lookup(String uri, int modified, {int? today}) {
    final e = _items[uri];
    if (e == null || e.modified != modified) {
      return null;
    }
    final int day = today ?? _today();
    if (e.seen != day) {
      _items[uri] = (modified: e.modified, seen: day, text: e.text);
      _dirty = true;
    }
    return e.text;
  }

  /// 새로 읽은 것을 넣는다 ([text] 가 '' 이면 그림 정보 없음).
  void put(String uri, int modified, String text, {int? today}) {
    _items[uri] = (modified: modified, seen: today ?? _today(), text: text);
    _dirty = true;
  }

  /// 지운 그림을 뺀다
  void remove(String uri) {
    if (_items.remove(uri) != null) {
      _dirty = true;
    }
  }

  /// 파일에 쓸 모양 — {"v": 판, "items": {uri: [수정 시각, 본 날, 찾을 글]}}. 오래 안 보인 칸은 뺀다.
  @visibleForTesting
  Map<String, Object> toJson({int? today}) {
    final int day = today ?? _today();
    return {
      'v': version,
      'items': {
        for (final e in _items.entries)
          if (day - e.value.seen <= keepDays) e.key: [e.value.modified, e.value.seen, e.value.text],
      },
    };
  }

  /// [toJson] 의 반대. 모양이 다르거나 판이 다르면 빈 색인.
  @visibleForTesting
  static GallerySearchIndex fromJson(Object? json) {
    final items = <String, _Entry>{};
    if (json is Map && json['v'] == version && json['items'] is Map) {
      for (final e in (json['items'] as Map).entries) {
        final v = e.value;
        if (e.key is String && v is List && v.length == 3 && v[0] is int && v[1] is int && v[2] is String) {
          items[e.key as String] = (modified: v[0] as int, seen: v[1] as int, text: v[2] as String);
        }
      }
    }
    return GallerySearchIndex._(items);
  }

  /// 파일에서 읽는다 (gzip JSON). 없거나 깨졌으면 빈 색인. 푸는 일은 화면 밖(isolate)에서.
  static Future<GallerySearchIndex> load(File file) async {
    try {
      if (!await file.exists()) {
        return GallerySearchIndex.empty();
      }
      final Uint8List raw = await file.readAsBytes();
      final Object? json = await Isolate.run(() => jsonDecode(utf8.decode(gzip.decode(raw))));
      return fromJson(json);
    } catch (e) {
      debugPrint('갤러리 검색 색인 읽기 실패(새로 만든다): $e');
      return GallerySearchIndex.empty();
    }
  }

  /// 파일로 쓴다 — 임시 파일에 다 쓴 뒤 바꿔 끼운다 (쓰다 꺼져도 옛 색인이 남게). 굽는 일은 화면 밖에서.
  Future<void> save(File file, {int? today}) async {
    final Map<String, Object> json = toJson(today: today);
    _dirty = false; // 쓰는 사이에 바뀐 것은 다음 저장에서 (먼저 내려 둔다)
    try {
      final List<int> bytes = await Isolate.run(() => gzip.encode(utf8.encode(jsonEncode(json))));
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      _dirty = true;
      debugPrint('갤러리 검색 색인 저장 실패: $e');
    }
  }

  // ── 앱 전체에 하나 (앱 캐시 폴더) ──
  static Future<GallerySearchIndex>? _shared;
  static GallerySearchIndex? _loaded;
  static Future<void> _saving = Future.value();

  static Future<File> _sharedFile() async =>
      File('${(await getTemporaryDirectory()).path}/gallery_search_index.json.gz');

  /// 앱 전체가 같이 쓰는 색인 — 처음 부를 때 한 번 읽는다 (캐시 폴더를 못 찾아도 빈 색인으로 — 저장만 안 된다)
  static Future<GallerySearchIndex> shared() => _shared ??= () async {
    GallerySearchIndex idx;
    try {
      idx = await load(await _sharedFile());
    } catch (e) {
      debugPrint('갤러리 검색 색인 위치를 못 찾음(빈 색인으로): $e');
      idx = GallerySearchIndex.empty();
    }
    _loaded = idx;
    return idx;
  }();

  /// 이미 읽어 둔 색인 (아직이면 null) — 지운 그림을 뺄 때처럼 기다릴 수 없는 곳에서
  static GallerySearchIndex? get loaded => _loaded;

  /// 바뀐 게 있으면 저장한다 — 겹쳐 부르면 차례로 (같은 파일을 동시에 쓰지 않게)
  static Future<void> saveShared() {
    final idx = _loaded;
    if (idx == null || !idx.isDirty) {
      return _saving;
    }
    return _saving = _saving.then((_) async {
      try {
        if (idx.isDirty) {
          await idx.save(await _sharedFile());
        }
      } catch (e) {
        // 캐시 폴더를 못 찾았다 — 이번엔 못 쓴다 (다음 저장에서 다시 해 본다. 줄이 끊기지 않게 여기서 삼킨다)
        debugPrint('갤러리 검색 색인 저장 실패: $e');
      }
    });
  }
}
