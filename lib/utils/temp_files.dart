// lib/utils/temp_files.dart
//
// 앱 캐시에 '잠깐' 생기는 파일들 — 쓰고 나면 치운다 (모르는 사이 쌓이지 않게).
//  · 그림 고르기 (pickGalleryImageBytes): image_picker 는 고른 그림을 캐시에 복사해(cache/<uuid>/…, 줄여 받으면
//    cache/scaled_…) 그 경로를 준다. 다 읽은 뒤 그 복사본들을 이름으로 골라 지운다 (사용자의 원본은 건드리지 않는다).
//  · 파일 고르기 (clearPickedFiles): file_picker 도 캐시(file_picker/)에 복사한다. 다 읽은 뒤 비운다.
//  · 공유로 내보내기 (exportTempFile): 캐시의 DNaiApp_exports/ 에 만든다. 다음에 내보낼 때 · 앱을 켤 때 비운다
//    → 많아야 마지막 하나만 남는다 (공유 받은 앱이 아직 읽고 있을 수 있어 보내자마자 지우지는 않는다).
//  · 앱을 켤 때 (cleanCacheLeftovers): 위에서 미처 못 지운 것 — 줄여 받은 그림의 원본 복사본 등 — 을 한 번 더 치운다
//    (방금 생긴 것은 남긴다 — 켜자마자 고르는 · 내보내는 중일 수 있어서).
//  ⚠️ 이름으로 골라 지우는 일(_sweepCache)은 안드로이드(앱 전용 캐시)에서만 한다.
//     데스크톱(Windows 등)의 '캐시'는 시스템 임시 폴더(%TEMP%)라 다른 프로그램 것도 있고,
//     image_picker 도 복사본이 아니라 사용자의 원본 경로를 준다. 내보내기 폴더 이름에도 그래서 앱 이름을 붙인다.
//  · 갤러리 섬네일 캐시 (trimThumbCache): 앱을 켤 때 너무 크면 오래 안 본 것부터 지운다.
//    지운 섬네일은 그 그림을 다시 볼 때 같은 크기(320px)로 새로 만들어진다.
//  ⚠️ 히스토리 그림 · 썸네일(앱 문서 폴더 history/), 사전 미리보기 · 큰 이미지(prompt_dict…), i2i 즐겨찾기는
//     여기서 다루지 않는다 — 앱 '데이터' 라 각자 자기 규칙으로 정리한다 (목록에 없는 파일만 지운다).
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

// ── 그림 · 파일 고르기 ──────────────────────────────────────────────

/// 갤러리에서 그림 하나를 골라 바이트로 돌려준다 (취소하면 null).
///  고르면서 image_picker 가 캐시에 만든 복사본은 다 읽은 뒤 지운다.
///  [maxWidth] · [maxHeight] 는 image_picker 에 그대로 넘긴다 (큰 그림을 받아 올 때부터 줄이기).
Future<Uint8List?> pickGalleryImageBytes({double? maxWidth, double? maxHeight}) async {
  final XFile? picked = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
  if (picked == null) {
    return null;
  }
  try {
    return await picked.readAsBytes();
  } finally {
    // 돌려받은 파일만 지우면 모자라다 — 줄여 받으면 돌려받는 건 scaled_ 파일이고,
    //  줄이기 전 복사본은 UUID 폴더에 그대로 남는다. 그래서 이름으로 골라 둘 다 치운다.
    //  (고르기는 한 번에 하나라, 지금 남은 복사본은 다 방금 다 읽은 것이다)
    await _sweepCache(_isPickerCopy);
  }
}

/// file_picker 가 캐시(file_picker/)에 복사해 둔 파일을 비운다 — 고른 파일을 '다 읽은 뒤' 부른다.
Future<void> clearPickedFiles() async {
  try {
    await FilePicker.platform.clearTemporaryFiles();
  } catch (e) {
    debugPrint('고른 파일 복사본 정리 실패(무시 — 시스템이 나중에 치운다): $e');
  }
}

// ── 공유로 내보내기 ──────────────────────────────────────────────

/// 공유로 내보낼 파일 [name] 을 캐시의 DNaiApp_exports/ 에 만들 자리 (앞서 내보낸 것은 지운다 — 쌓이지 않게).
Future<File> exportTempFile(String name) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/$_exportDirName');
  await _emptyDir(dir);
  await dir.create(recursive: true);
  return File('${dir.path}/$name');
}

// 내보내기 폴더 — 앱 이름을 붙인다 (데스크톱의 임시 폴더는 다른 프로그램과 같이 쓴다)
const String _exportDirName = 'DNaiApp_exports';

// 예전 버전이 캐시 바로 아래에 남긴 내보내기 파일 (설정 · 정밀 참조 · 바이브)
//  확장자까지 본다 — 저장 폴더에 못 쓸 때 캐시에 남기는 그림(사용자 이름 규칙)과 헷갈리지 않게
final RegExp _legacyExportName = RegExp(
  r'^DNaiApp_(Settings|Precise|Vibe)_.*\.(json|zip|naiv4vibe|naiv4vibebundle)$',
);

// image_picker 가 남기는 것 — 그림마다 만드는 폴더(이름이 UUID), 줄여 받을 때 만드는 scaled_… 파일
//  (줄여 받으면 돌려주는 건 scaled_ 파일이고, 줄이기 전 복사본은 UUID 폴더에 남는다)
final RegExp _pickerDirName = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final RegExp _pickerFileName = RegExp(r'^(scaled_|image_picker)');

bool _isPickerCopy(String name, bool isDir) =>
    isDir ? _pickerDirName.hasMatch(name) : _pickerFileName.hasMatch(name);

// 통째로 비워도 되는 잠깐 폴더 — 내보내기 · file_picker 복사본 · share_plus 복사본
//  (share_plus 는 보낼 파일을 자기 폴더에 한 번 더 복사하고, 다음에 공유할 때에야 비운다)
const Set<String> _scratchDirNames = {_exportDirName, 'file_picker', 'share_plus'};

/// 앱을 켤 때 — 캐시에 남은 잠깐 파일을 치운다.
///  · 지난번에 내보낸 파일 (DNaiApp_exports/ · share_plus/) · 예전 버전이 캐시 바로 아래에 남긴 내보내기 파일
///  · image_picker 가 남긴 복사본 (UUID 폴더 · scaled_ 파일) · file_picker 복사본 (file_picker/)
///  ⚠️ 방금(1분 안) 생긴 것은 남긴다 — 앱을 켜자마자 그림을 고르거나 공유로 내보내는 중일 수 있다.
Future<void> cleanCacheLeftovers() => _sweepCache(
  (name, isDir) =>
      _isPickerCopy(name, isDir) ||
      (isDir ? _scratchDirNames.contains(name) : _legacyExportName.hasMatch(name)),
  before: DateTime.now().subtract(const Duration(minutes: 1)),
);

// 캐시 바로 아래에서 [isLeftover] 가 고른 것을 지운다 ([before] 를 주면 그보다 오래된 것만).
//  ⚠️ 안드로이드에서만 — 다른 곳의 임시 폴더엔 다른 프로그램의 UUID 폴더 등이 있다 (지우면 안 된다).
//  ⚠️ 그 밖의 캐시(갤러리 섬네일 · i2i 릴 · 검색 색인 …)는 이름이 안 맞아 건드리지 않는다.
Future<void> _sweepCache(
  bool Function(String name, bool isDir) isLeftover, {
  DateTime? before,
}) async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    final cache = await getTemporaryDirectory();
    await for (final e in cache.list(followLinks: false)) {
      if (e is! File && e is! Directory) {
        continue; // 링크 등은 건드리지 않는다
      }
      final String name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!isLeftover(name, e is Directory)) {
        continue;
      }
      try {
        if (before == null || (await e.stat()).modified.isBefore(before)) {
          await e.delete(recursive: true);
        }
      } catch (err) {
        debugPrint('캐시 잠깐 파일 지우기 실패(무시): $name $err');
      }
    }
  } catch (e) {
    debugPrint('캐시 잠깐 파일 정리 실패(무시): $e');
  }
}

Future<void> _emptyDir(Directory dir) async {
  try {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  } catch (e) {
    debugPrint('임시 폴더 비우기 실패(무시): $e');
  }
}

// ── 갤러리 섬네일 캐시 ──────────────────────────────────────────────

/// 섬네일 캐시 상한 — 넘으면 [kThumbCacheTarget] 까지 줄인다 (장당 15~30KB → 상한이면 대략 7천~1만 장)
const int kThumbCacheMax = 200 * 1024 * 1024;
const int kThumbCacheTarget = 150 * 1024 * 1024;

/// 섬네일을 읽을 때 부른다 — 사흘 넘게 안 본 것이면 '봤다' 고 시각을 새로 적는다 (정리할 때 남게).
///  매번 적지 않는 건 쓰기를 줄이려고 (자주 보는 것은 사흘에 한 번만 적힌다).
Future<void> touchCacheFile(File f) async {
  try {
    final DateTime now = DateTime.now();
    if (now.difference(await f.lastModified()) > const Duration(days: 3)) {
      await f.setLastModified(now);
    }
  } catch (_) {
    // 못 적어도 그만이다 — 정리 때 조금 일찍 지워질 뿐 (볼 때 다시 만든다)
  }
}

/// [dir] 이 [maxBytes] 를 넘으면 오래 안 본 것(수정 시각이 옛날인 것)부터 지워 [targetBytes] 아래로.
///  파일을 훑는 일은 화면 밖(isolate)에서 한다. 반환: 지운 개수.
Future<int> trimThumbCache(
  Directory dir, {
  int maxBytes = kThumbCacheMax,
  int targetBytes = kThumbCacheTarget,
}) async {
  final String path = dir.path;
  try {
    return await Isolate.run(() => _trimDirSync(path, maxBytes, targetBytes));
  } catch (e) {
    debugPrint('섬네일 캐시 정리 실패(무시): $e');
    return 0;
  }
}

int _trimDirSync(String path, int maxBytes, int targetBytes) {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    return 0;
  }
  final files = <({File f, int size, int modified})>[];
  int total = 0;
  for (final e in dir.listSync(followLinks: false)) {
    if (e is! File) {
      continue;
    }
    try {
      final st = e.statSync();
      files.add((f: e, size: st.size, modified: st.modified.millisecondsSinceEpoch));
      total += st.size;
    } catch (_) {
      // 그사이 지워진 파일 — 건너뛴다
    }
  }
  if (total <= maxBytes) {
    return 0;
  }
  files.sort((a, b) => a.modified.compareTo(b.modified)); // 오래된 것부터
  int removed = 0;
  for (final x in files) {
    if (total <= targetBytes) {
      break;
    }
    try {
      x.f.deleteSync();
      total -= x.size;
      removed++;
    } catch (_) {
      // 못 지운 파일은 두고 다음 것으로
    }
  }
  return removed;
}
