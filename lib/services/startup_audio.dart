import 'dart:async';

/// The named startup clip starts once per app process, including login/guest.
/// The connection gate reuses it instead of restarting it after sign-in.
/// Backgrounding stops only this clip, never voice or gameplay audio.
class StartupAudio {
  StartupAudio({required this.start, required this.stop});
  final Future<void> Function() start;
  final Future<void> Function() stop;
  bool _started = false;
  bool _active = false;
  bool _closed = false;
  int _cycle = 0;
  Future<void> _stopBarrier = Future<void>.value();

  Future<void> _enqueueStop(Future<void> Function() action) {
    final next = _stopBarrier.then((_) => action());
    _stopBarrier = next.catchError((Object _) {});
    return next;
  }

  Future<void> startOnce() async {
    if (_started || _closed) return;
    _started = true;
    await connecting();
  }

  Future<void> connecting() async {
    if (_active || _closed) return;
    _active = true;
    final cycle = ++_cycle;
    // Wait only for any in-flight stop() to settle; never block on the full
    // playback duration of start(), otherwise finish() cannot interrupt the
    // startup clip until it ends naturally.
    await _stopBarrier;
    if (!_active || _closed || cycle != _cycle) return;
    // SoundBoard.loop already catches and records its own failures.
    unawaited(Future<void>.sync(start).catchError((Object _) {}));
  }

  Future<void> finish() async {
    if (!_active) return;
    _active = false;
    _cycle++;
    await _enqueueStop(stop);
  }

  Future<void> close() async {
    _closed = true;
    await finish();
  }
}
