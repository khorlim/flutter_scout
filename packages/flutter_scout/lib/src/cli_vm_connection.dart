part of 'flutter_scout_cli.dart';

// Lifecycle of the persistent agent's cached VM clients.
extension _CliVmConnection on FlutterScoutCli {
  Future<void> _disposeCachedVmService() async {
    final cached = _cachedVmService;
    _cachedVmService = null;
    _cachedVmUri = null;
    if (cached != null) {
      try {
        await cached.dispose();
      } catch (_) {
        // A dead socket failing to close cleanly is not an error.
      }
    }
  }
}
