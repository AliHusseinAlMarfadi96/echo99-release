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
  Future<void> _operations = Future<void>.value();

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _operations.then((_) => action());
    _operations = next.catchError((Object _) {});
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
    await _enqueue(start);
  }

  Future<void> finish() async {
    if (!_active) return;
    _active = false;
    await _enqueue(stop);
  }

  Future<void> close() async {
    _closed = true;
    await finish();
  }
}
