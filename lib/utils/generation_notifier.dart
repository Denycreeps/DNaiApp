// lib/utils/generation_notifier.dart
//
// 생성 진행 · 완료 알림 (설정 > 일반 > 동작 · 기타 > '생성 진행 · 완료 알림', 기본 꺼짐).
//  · 연속 생성(2장 이상 · 무한) 동안: 알림창에 진행 막대 — 조용히 (소리 · 진동 없음), 끝나면 지운다.
//  · 다 끝나면: 앱이 뒤에 있으면 완료 알림 (소리 · 진동은 휴대폰의 알림 설정을 따른다),
//               앱을 보고 있으면 진동만 — 소리 없는 '진동 알림'을 잠깐 띄웠다가 1.5초 뒤 저절로 지운다
//               (그림은 이미 화면에 떠 있다). 휴대폰이 무음이면 울리지 않는다 (진동 모드 · 소리 모드에서 울린다).
//  ⚠️ AppState 를 모른다 — 언제 무엇을 띄울지는 AppState 쪽(app_state_notify.dart)이 정해 넘긴다.
//  ⚠️ 그림 · 프롬프트는 알림에 넣지 않는다 — 잠금화면 · 알림창에 그대로 보인다.
//  ⚠️ 알림 아이콘은 android/app/src/main/res/drawable/ic_stat_generate.xml (흰 단색 — 상태 표시줄용).
//     이름을 바꾸거나 지우면 알림을 준비할 때 오류가 난다 (그땐 알림만 안 뜨고 생성은 그대로).
import 'package:flutter/foundation.dart'; // kIsWeb · debugPrint · Int64List(진동 패턴)
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class GenerationNotifier {
  GenerationNotifier._();

  /// 앱 전체에 하나
  static final GenerationNotifier instance = GenerationNotifier._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// 준비는 한 번만 — 동시에 불려도 같은 결과를 기다린다 (실패도 기억한다: 매번 다시 시도하지 않게)
  Future<bool>? _ready;

  /// 진행 알림을 띄워 둔 상태인지 (지울 게 있을 때만 지운다)
  bool _progressShown = false;

  static const int _progressId = 7101;
  static const int _doneId = 7102;
  static const int _buzzId = 7103;
  static const String _icon = 'ic_stat_generate';

  Future<bool> _init() => _ready ??= _doInit();

  Future<bool> _doInit() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false; // 이 앱의 알림은 안드로이드만
    }
    try {
      // 알림을 누르면 앱이 열린다 (따로 처리할 일이 없어 응답 콜백은 두지 않는다)
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings(_icon)),
      );
      return true;
    } catch (e) {
      debugPrint('알림 준비 실패(알림 없이 계속): $e');
      return false;
    }
  }

  /// 알림을 띄울 수 있게 준비하고, 안드로이드 13 부터는 알림 권한을 묻는다.
  ///  알림을 띄울 수 있으면 true (권한을 거절했거나 휴대폰 설정에서 꺼 두면 false).
  Future<bool> requestPermission() async {
    if (!await _init()) {
      return false;
    }
    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) {
      return false;
    }
    try {
      // 안드로이드 12 이하는 묻지 않는다 (권한이 따로 없다) — 그래서 '켜져 있는지' 를 한 번 더 본다
      final bool granted = await android.requestNotificationsPermission() ?? false;
      return granted || (await android.areNotificationsEnabled() ?? false);
    } catch (e) {
      debugPrint('알림 권한 확인 실패: $e');
      return false;
    }
  }

  /// 연속 생성 진행 — [tried] 번 시도해서 [done] 장 받음, 전체 [total] 장 (0 = 무한).
  ///  같은 번호로 다시 띄워 '바꿔 끼운다' (onlyAlertOnce — 처음 한 번도 조용하다).
  Future<void> showProgress({required int done, required int tried, required int total}) async {
    // 띄우기 '전에' 표시한다 — 띄우는 사이 생성이 끝나면 지우기가 이 표시를 보고 지운다
    //  (띄운 뒤에 표시하면, 곧바로 끝난 배치의 진행 알림이 지워지지 않고 남았다)
    _progressShown = true;
    if (!await _init()) {
      return;
    }
    final int failed = tried - done;
    final String title = total > 0 ? "연속 생성 중 · $tried/$total" : "무한 생성 중 · $tried장째";
    final String body = [
      "받은 이미지 $done장",
      if (failed > 0) "실패 $failed번",
      "정지는 앱에서",
    ].join(" · ");
    try {
      await _plugin.show(
        id: _progressId,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'gen_progress',
            '생성 진행',
            channelDescription: '연속 생성 중 진행 상황 (소리 · 진동 없음)',
            importance: Importance.low,
            priority: Priority.low,
            playSound: false,
            enableVibration: false,
            onlyAlertOnce: true,
            // ongoing 을 켜지 않는다 — 밀어서 지울 수 있게 (앱이 도중에 강제로 꺼져도 알림창에 갇혀 남지 않게).
            //  지워도 다음 장이 끝나면 다시 뜬다. 눌러서 앱을 열어도 지워지지 않게 autoCancel 은 끈다.
            autoCancel: false,
            showWhen: false,
            showProgress: true,
            maxProgress: total > 0 ? total : 0,
            progress: total > 0 ? tried.clamp(0, total) : 0,
            indeterminate: total == 0,
            category: AndroidNotificationCategory.progress,
          ),
        ),
      );
    } catch (e) {
      debugPrint('진행 알림 실패(무시): $e');
    }
  }

  /// 진행 알림을 지운다 (띄운 적이 있을 때만).
  Future<void> clearProgress() async {
    if (!_progressShown || !await _init()) {
      return;
    }
    _progressShown = false;
    try {
      await _plugin.cancel(id: _progressId);
    } catch (e) {
      debugPrint('진행 알림 지우기 실패(무시): $e');
    }
  }

  /// 앱을 켤 때 — 지난번에 앱이 도중에 꺼져 남은 진행 알림을 치운다.
  Future<void> clearStaleProgress() async {
    _progressShown = true; // 이번 실행에서 띄운 적이 없어도 지운다
    await clearProgress();
  }

  /// 생성이 끝났다 (다 됨 · 정지 · 오류 모두) — 진행 알림을 지우고 끝났음을 알린다.
  ///  [done] 받은 장수 · [tried] 시도한 수 · [total] 전체 (1 = 한 장, 0 = 무한) · [error] 마지막 오류.
  ///  [announce] 가 false 면 진행 알림만 지운다 (생성 도중에 설정을 끈 경우).
  Future<void> finish({
    required int done,
    required int tried,
    required int total,
    String? error,
    bool announce = true,
  }) async {
    await clearProgress();
    if (!announce) {
      return;
    }
    final (String title, String body) = doneText(done, tried, total, error);
    // 앱을 보고 있으면 알림 대신 진동만
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await _buzz(title);
      return;
    }
    if (!await _init()) {
      return;
    }
    try {
      await _plugin.show(
        id: _doneId,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'gen_done',
            '생성 완료',
            channelDescription: '생성이 끝났을 때 (앱이 뒤에 있을 때만)',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.status,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
      );
    } catch (e) {
      debugPrint('완료 알림 실패(무시): $e');
    }
  }

  // 앱을 보고 있을 때의 진동 — 소리 없는 '진동 알림' 을 띄우고 1.5초 뒤 저절로 지운다.
  //  ⚠️ HapticFeedback 은 '터치 진동' 이라 휴대폰 설정에서 터치 진동을 꺼 두면 아무것도 울리지 않는다.
  //     그래서 알림을 띄울 수 없을 때(권한 없음)만 그걸로 대신한다.
  Future<void> _buzz(String title) async {
    final android = await _init()
        ? _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        : null;
    bool canNotify = false;
    try {
      canNotify = android != null && (await android.areNotificationsEnabled() ?? false);
    } catch (_) {
      // 확인을 못 하면 터치 진동으로
    }
    if (!canNotify) {
      await HapticFeedback.vibrate();
      await Future<void>.delayed(const Duration(milliseconds: 160));
      await HapticFeedback.vibrate();
      return;
    }
    try {
      await _plugin.show(
        id: _buzzId,
        title: title,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'gen_buzz',
            '생성 완료 진동',
            channelDescription: '앱을 보고 있을 때 생성이 끝나면 진동만 (소리 없음 · 잠깐 뒤 저절로 사라짐)',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            playSound: false,
            enableVibration: true,
            vibrationPattern: Int64List.fromList(const [0, 200, 120, 200]),
            timeoutAfter: 1500,
            showWhen: false,
            category: AndroidNotificationCategory.status,
          ),
        ),
      );
    } catch (e) {
      debugPrint('진동 알림 실패(무시): $e');
    }
  }

  /// 완료 알림의 (제목, 내용) — test/generation_notifier_test.dart 가 확인한다.
  @visibleForTesting
  static (String, String) doneText(int done, int tried, int total, String? error) {
    final int failed = tried - done;
    final String? err = _firstLine(error);
    if (total == 1) {
      return done > 0
          ? ("이미지 생성 완료", "새 이미지가 히스토리에 들어갔어요.")
          : ("이미지 생성 실패", err ?? "이미지를 받지 못했어요.");
    }
    final String title;
    if (done == 0) {
      title = total == 0 ? "무한 생성 실패" : "연속 생성 실패";
    } else if (total == 0) {
      title = "무한 생성 끝 · $done장";
    } else {
      title = tried < total ? "연속 생성 멈춤 · $done장" : "연속 생성 완료 · $done장";
    }
    final String body = [
      total > 0 ? "$tried/$total 생성" : "$tried번 생성",
      if (failed > 0) "실패 $failed번",
      if (err != null && failed > 0) "마지막 오류: $err",
    ].join(" · ");
    return (title, body);
  }

  // 오류 글의 첫 줄만, 80 글자까지 (글자 단위 — 이모지가 쪼개지지 않게)
  static String? _firstLine(String? s) {
    if (s == null || s.trim().isEmpty) {
      return null;
    }
    final String line = s.trim().split('\n').first.trim();
    final List<int> runes = line.runes.toList();
    return runes.length > 80 ? '${String.fromCharCodes(runes.take(80))}…' : line;
  }
}
