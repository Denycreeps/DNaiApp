// lib/models/setting_field.dart
//
// 설정 하나를 '한 줄'로 적는 틀 (AppState._settings 가 이걸 모아 둔 목록이다).
//
// 예전엔 설정 하나를 넣으려면 AppState 의 다섯 곳 — 선언 · 불러오기 · 내보내기 · 가져오기 · 저장 —
// 을 손으로 맞춰야 했고, 하나라도 빠지면 그 설정은 조용히 사라졌다 (DEVNOTES '설정을 추가할 때').
// 이제 목록에 한 줄을 더하면 나머지 네 곳은 목록을 돌며 알아서 처리한다.
//
//  · 저장 키 = 백업(내보내기 파일) 키 — 둘은 늘 같은 이름이다.
//  · 기본값은 [def] 하나. 저장된 값이 없거나 · 형이 다르면 이 값.
//    (백업 파일에 그 칸이 아예 없으면 AppState._applySettings 가 지금 값을 그대로 둔다)
//  · [fix] 는 읽은 뒤 바로잡기 (범위 자르기 · 목록에 없는 값 고치기). 저장소 · 백업 모두에 똑같이 적용된다.
//  · [backup] 이 false 면 내보내기 · 가져오기에서 뺀다 (이 기기에서만 의미 있는 값).
//
// 다룰 수 있는 형: bool · int · double · String · String?(없으면 저장하지 않음) · List<String>.
//  (Set 은 get/set 에서 목록으로 바꿔 쓴다. JSON 으로 묶어 두는 큰 값 — 캐릭터 · 와일드카드 등 — 은
//   AppState 가 따로 다룬다)
import 'package:flutter/foundation.dart' show listEquals;
import 'package:shared_preferences/shared_preferences.dart';

class SettingField<T> {
  SettingField(
    this.key, {
    required T Function() get,
    required void Function(T value) set,
    required this.def,
    T Function(T value)? fix,
    this.backup = true,
  }) : assert(
         def == null ||
             def is bool ||
             def is int ||
             def is double ||
             def is String ||
             def is List<String>,
         '설정 "$key": 저장할 수 없는 형 (save 가 터지면 그 뒤 설정 · 캐릭터 저장까지 통째로 건너뛴다)',
       ),
       _get = get,
       _set = set,
       _fix = fix;

  /// 저장 키 = 백업 키
  final String key;

  /// 기본값 (값이 없거나 형이 다를 때)
  final T def;

  /// 내보내기 · 가져오기에 담는지
  final bool backup;

  // ⚠️ 바깥에서 꺼내 쓰지 않는다 — 목록은 SettingField<Object?> 로 들고 있어서,
  //    꺼내면 형 검사에 걸릴 수 있다. 아래 메서드로만 쓴다.
  //    같은 이유로 T 를 '받는' 공개 메서드(예: void put(T v))를 더하지 않는다 —
  //    목록을 거쳐 부르면 실행 중에 형 오류가 난다. 받을 땐 apply 처럼 Object? 로 받는다.
  final T Function() _get;
  final void Function(T value) _set;
  final T Function(T value)? _fix;

  /// 지금 값 (내보내기용)
  Object? get value => _get();

  /// 저장소 · 백업에서 읽은 값을 적용한다. 없거나(null) 형이 다르면 기본값.
  ///  (기본값도 [_coerce] 를 거친다 — 목록이면 새 사본이 된다. 상수 목록을 그대로 넣으면 고칠 때 터진다)
  void apply(Object? raw) {
    final T v = _coerce(raw) ?? _coerce(def) ?? def;
    final fix = _fix;
    _set(fix == null ? v : fix(v));
  }

  /// [raw] 를 T 로 — 못 바꾸면 null.
  ///  JSON 은 숫자 형을 가리지 않아서(1 과 1.0) 숫자는 맞춰 주고, 목록은 글자만 골라 담는다.
  T? _coerce(Object? raw) {
    if (raw == null) {
      return null;
    }
    final d = def;
    // ⚠️ 목록은 '늘' 새 사본으로. SharedPreferences.get 은 저장소가 들고 있는 목록 그 자체를 준다 —
    //    그걸 그대로 들고 앱에서 고치면 저장소 안쪽 사본까지 같이 바뀌어,
    //    저장할 때 '바뀐 게 없다' 고 보고 건너뛴다 (고친 내용이 영영 저장되지 않는다).
    if (raw is List && d is List<String>) {
      return <String>[
        for (final e in raw)
          if (e is String) e,
      ] as T;
    }
    // 'as T' 를 꼭 붙인다 — 위의 null 검사로 raw 가 이미 Object 로 좁혀져 있어서,
    //  T(String? 처럼 null 을 품을 수 있는 형)로는 더 좁혀지지 않는다
    if (raw is T) {
      return raw as T;
    }
    if (raw is num) {
      if (d is double) {
        return raw.toDouble() as T;
      }
      if (d is int && raw.isFinite) {
        return raw.toInt() as T; // 무한대는 toInt 에서 터진다 → 기본값
      }
      if (d is String) {
        return raw.toString() as T; // 손으로 고친 백업의 "steps": 28 같은 것
      }
    }
    return null;
  }

  /// 저장소에 쓴다. 저장소가 들고 있는 값과 같으면 건너뛴다
  ///  (안드로이드 설정 저장소는 값 하나만 써도 파일 전체를 다시 쓴다).
  ///  값이 null 이면 쓰지 않는다 (지우지도 않는다).
  Future<void> save(SharedPreferences p) async {
    final v = _get();
    if (v == null) {
      return;
    }
    final cur = p.get(key);
    if (v is List<String>) {
      if (cur is List<String> && listEquals(cur, v)) {
        return;
      }
      await p.setStringList(key, v);
      return;
    }
    if (cur == v) {
      return;
    }
    if (v is String) {
      await p.setString(key, v);
    } else if (v is bool) {
      await p.setBool(key, v);
    } else if (v is int) {
      await p.setInt(key, v);
    } else if (v is double) {
      await p.setDouble(key, v);
    } else {
      throw StateError('설정 "$key" 는 저장할 수 없는 형이다: ${v.runtimeType}');
    }
  }
}
