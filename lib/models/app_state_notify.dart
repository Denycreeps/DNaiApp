// lib/models/app_state_notify.dart
//
// AppState 의 생성 진행 · 완료 알림 쪽 — 언제 무엇을 알릴지 정한다 (알림 자체는 utils/generation_notifier.dart).
//  · 설정 '생성 진행 · 완료 알림'(generationNotify, 기본 꺼짐)이 켜져 있을 때만 움직인다.
//  · 생성 한 번(한 장 · 연속 · 무한 · 다시 생성 · 다시 뽑기)마다 짝으로 부른다:
//      _notifyStart(전체 장수) → (한 장 시도가 끝날 때마다) _notifyTick() → (끝나면, finally 에서) _notifyEnd()
//    지금 부르는 곳: handleBatchGenerate · _runBatchLoop (app_state.dart),
//                    _generateFromMetadata (app_state_history.dart — 다시 생성 · 다시 뽑기).
//  · 받은 장수는 sessionGenerateCount 가 는 만큼 — 그림이 실제로 온 것만 센다 (서버 오류는 '실패').
//  ⚠️ 상태 값(_ntf…)은 AppState 에 있다 (확장에는 필드를 둘 수 없다).
part of 'app_state.dart';

extension AppStateNotify on AppState {
  /// 설정에서 켤 때 — 알림을 준비하고 (안드로이드 13+) 권한을 묻는다. 알림을 띄울 수 있으면 true.
  ///  false 여도 설정은 켜 둔다 — 앱을 보고 있을 때의 진동은 권한 없이도 된다.
  Future<bool> prepareGenerationNotify() => GenerationNotifier.instance.requestPermission();

  /// 생성 시작 — 이번에 만들 전체 장수 [total] (1 = 한 장, 0 = 무한).
  ///  두 장 이상 · 무한이면 진행 알림을 바로 띄운다 (한 장은 금방 끝나 띄우지 않는다).
  void _notifyStart(int total) {
    _ntfRunning = generationNotify;
    if (!_ntfRunning) {
      return;
    }
    _ntfTotal = total;
    _ntfTried = 0;
    _ntfStartCount = sessionGenerateCount;
    if (total != 1) {
      unawaited(GenerationNotifier.instance.showProgress(done: 0, tried: 0, total: total));
    }
  }

  /// 한 장 시도가 끝났다 (그림이 왔든 서버 오류든).
  ///  [tried] 는 이번 요청이 만들려던 장수 — 생성 버튼 꾹(한 번에 여러 장)이면 그 장수.
  void _notifyTick([int tried = 1]) {
    // 도중에 설정을 껐으면 진행 알림을 더 띄우지 않는다 (끝날 때 지우기만 한다)
    if (!_ntfRunning || !generationNotify) {
      return;
    }
    _ntfTried += tried;
    if (_ntfTotal != 1) {
      unawaited(
        GenerationNotifier.instance.showProgress(
          done: sessionGenerateCount - _ntfStartCount,
          tried: _ntfTried,
          total: _ntfTotal,
        ),
      );
    }
  }

  /// 생성이 끝났다 (다 됨 · 정지 · 오류 모두) — 진행 알림을 지우고, 앱이 뒤에 있으면 알림 · 앞이면 진동.
  ///  도중에 설정을 껐으면 진행 알림만 지운다.
  void _notifyEnd() {
    if (!_ntfRunning) {
      return;
    }
    _ntfRunning = false;
    unawaited(
      GenerationNotifier.instance.finish(
        done: sessionGenerateCount - _ntfStartCount,
        tried: _ntfTried,
        total: _ntfTotal,
        error: lastErrorMessage,
        announce: generationNotify,
      ),
    );
  }
}
