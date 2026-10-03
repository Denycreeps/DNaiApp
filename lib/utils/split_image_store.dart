// lib/utils/split_image_store.dart
//
// 그림 여러 장을 '작은 목록 파일 하나 + 그림 파일 한 장씩' 으로 나눠 보관한다.
//  i2i 결과 릴(캐시 폴더)과 i2i 즐겨찾기(문서 폴더)가 같이 쓴다.
//
// 왜 나누는가:
//  · 그림을 base64 로 JSON 한 파일에 넣으면 33% 커지고, 한 장만 바뀌어도 전부 다시 쓰며,
//    읽을 때 글자 덩어리와 그림이 동시에 메모리에 올라가 순간적으로 2~3배를 먹는다.
//  · 나눠 두면 바뀐 그림만 쓰고, 목록은 몇 KB 라 통째로 바꿔도 가볍다.
//
// 쓰는 순서 (도중에 꺼져도 어긋나지 않게):
//  ① 새 그림 파일 → ② 목록 파일 (여기서 '확정') → ③ 목록에 없는 그림 지우기
//  ①에서 꺼지면 아무도 가리키지 않는 그림이 남을 뿐이고 (다음 ③에서 치운다),
//  목록이 '없는 그림' 을 가리키는 일은 생기지 않는다.
//  파일 하나하나는 임시 파일(.tmp)에 다 쓴 뒤 이름만 바꾼다 — 반쯤 쓴 파일이 남지 않는다.
//
// 읽는 순서: 목록 → 그림. 그림이 없으면 (시스템이 캐시를 치웠다 등) 그 칸만 빠진다.
//  목록이 없거나 깨졌는데 그림은 남아 있으면, 그림 파일로 목록을 다시 만든다 —
//  그림이 '진짜 데이터' 이고 목록은 순서·정보일 뿐이라서. (이때 정보는 잃고 파일 시각이 순서가 된다)
//
// ⚠️ 쓰는 쪽 약속: 처음 [load] 를 마치기 전에는 [sync] 를 부르지 않는다.
//    안 읽은 그림을 '목록에 없는 그림' 으로 보고 ③에서 지우게 된다.
//    (앱을 켤 때 빈 사전을 읽고 큰 이미지를 다 지웠던 사고와 같은 함정)
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

/// 보관할 그림 한 장.
///  [info] 는 목록 파일에 함께 적히는 작은 정보 (JSON 으로 바꿀 수 있어야 한다. 'id' 는 쓰지 않는다).
typedef StoredImage = ({String id, Uint8List bytes, Map<String, dynamic> info});

class SplitImageStore {
  SplitImageStore({required this.dir, required this.indexName, required this.filePrefix});

  /// 보관 폴더. 앱 폴더 경로는 비동기로만 얻을 수 있어 함수로 받는다 (없으면 쓸 때 만든다).
  final Future<Directory> Function() dir;

  /// 목록 파일 이름 (예: 'reel.json')
  final String indexName;

  /// 그림 파일 이름 앞머리 (예: 'r_' → r_{id}.img)
  final String filePrefix;

  /// 이번 실행에서 파일이 있다고 확인한(쓰거나 읽은) 그림 id — 같은 그림을 다시 쓰지 않으려고
  final Set<String> _onDisk = {};

  /// 맞추기를 차례로 돌린다 (두 맞추기가 같은 파일을 동시에 건드리지 않게)
  Future<bool> _chain = Future.value(true);

  File _imageFile(Directory d, String id) => File('${d.path}/$filePrefix$id.img');

  /// 이 그림이 이 보관함에 들어 있는지 (이번 실행에서 쓰거나 읽은 것 기준).
  ///  두 보관함 사이에서 그림을 옮길 때 '새 자리에 쓰였는지' 확인하는 데 쓴다.
  bool isStored(String id) => _onDisk.contains(id);

  static final RegExp _imgTail = RegExp(r'\.img$');

  /// 그림 파일 이름이면 그 id, 아니면 null
  String? _idOfFileName(String name) {
    if (!name.startsWith(filePrefix) || !name.endsWith('.img')) {
      return null;
    }
    return name.replaceFirst(filePrefix, '').replaceFirst(_imgTail, '');
  }

  /// 보관된 그림을 목록 순서대로 읽는다.
  ///  보관된 게 아예 없으면 (목록도 그림도 없음) null — 처음이거나, 옛 형식에서 옮겨 와야 하는 경우.
  Future<List<StoredImage>?> load() async {
    final d = await dir();
    if (!await d.exists()) {
      return null;
    }
    final List? entries = await _readIndex(d);
    final out = <StoredImage>[];
    if (entries != null) {
      for (final e in entries) {
        // 한 칸이 이상해도 그 칸만 건너뛴다 (나머지까지 못 읽으면, 부른 쪽은 '못 읽음'으로 보고
        //  이번 실행 동안 이 보관함을 건드리지 않는다 — 그래도 한 칸 때문에 다 막히는 건 손해다)
        try {
          if (e is! Map) {
            continue;
          }
          final id = e['id'];
          if (id is! String) {
            continue;
          }
          final img = await _readImage(d, id);
          if (img != null) {
            out.add((id: id, bytes: img, info: Map<String, dynamic>.from(e)..remove('id')));
          }
        } catch (err) {
          debugPrint('보관함($indexName) 한 칸 읽기 실패(건너뜀): $err');
        }
      }
      return out;
    }
    // 목록이 없거나 깨졌다 → 남은 그림 파일로 다시 만든다 (오래된 것부터)
    final files = <(File, int)>[];
    for (final f in d.listSync().whereType<File>()) {
      if (_idOfFileName(f.uri.pathSegments.last) == null) {
        continue;
      }
      try {
        files.add((f, f.lastModifiedSync().millisecondsSinceEpoch));
      } catch (_) {
        // 그 사이 지워진 파일 — 건너뛴다
      }
    }
    if (files.isEmpty) {
      return null;
    }
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, t) in files) {
      final id = _idOfFileName(f.uri.pathSegments.last)!;
      final img = await _readImage(d, id);
      if (img != null) {
        out.add((id: id, bytes: img, info: {'t': t})); // 정보는 잃었다 — 파일 시각만 순서로
      }
    }
    debugPrint('보관함 목록($indexName)을 그림 파일 ${out.length}장으로 다시 만들었습니다');
    return out;
  }

  /// 목록 파일을 읽는다. 없거나 깨졌으면 null.
  Future<List?> _readIndex(Directory d) async {
    try {
      final f = File('${d.path}/$indexName');
      if (!await f.exists()) {
        return null;
      }
      final raw = jsonDecode(await f.readAsString());
      return raw is List ? raw : null;
    } catch (e) {
      debugPrint('보관함 목록($indexName) 읽기 실패: $e');
      return null;
    }
  }

  Future<Uint8List?> _readImage(Directory d, String id) async {
    try {
      final f = _imageFile(d, id);
      if (!await f.exists()) {
        return null; // 시스템이 치웠거나 쓰다 꺼짐 — 그 장만 빠진다
      }
      final bytes = await f.readAsBytes();
      _onDisk.add(id);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 보관 내용을 [current] 가 돌려주는 목록에 맞춘다. 반환: 끝까지 성공했는지.
  ///  차례로 돌고, 돌 때의 최신 목록을 쓴다 (사이에 여러 번 바뀌었어도 마지막 모습으로).
  Future<bool> sync(List<StoredImage> Function() current) {
    final next = _chain.then((_) => _sync(current()));
    _chain = next.catchError((_) => false); // 한 번 실패해도 줄이 막히지 않게
    return next;
  }

  Future<bool> _sync(List<StoredImage> items) async {
    try {
      final d = await dir();
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
      // ① 아직 안 쓴 그림
      for (final it in items) {
        if (_onDisk.contains(it.id)) {
          continue;
        }
        await _writeAtomic(_imageFile(d, it.id), it.bytes);
        _onDisk.add(it.id);
      }
      // ② 목록 — 여기서 '확정'
      await _writeAtomic(
        File('${d.path}/$indexName'),
        utf8.encode(
          jsonEncode([
            for (final it in items) {...it.info, 'id': it.id},
          ]),
        ),
      );
      // ③ 목록에 없는 파일 (지운 것·밀려난 것·다른 보관함으로 옮긴 것·남은 임시 파일)
      final keep = {for (final it in items) it.id};
      for (final f in d.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name == indexName || keep.contains(_idOfFileName(name))) {
          continue;
        }
        try {
          await f.delete();
        } catch (_) {
          // 못 지운 파일은 다음 맞추기 때 다시 지운다
        }
      }
      _onDisk.retainAll(keep);
      return true;
    } catch (e) {
      debugPrint('보관함($indexName) 저장 실패: $e');
      return false;
    }
  }

  static Future<void> _writeAtomic(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }
}
