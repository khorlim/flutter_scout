part of 'flutter_scout_cli.dart';

Stream<String> _boundedAgentLines(Stream<List<int>> input) async* {
  final pending = <int>[];
  await for (final chunk in input) {
    for (final byte in chunk) {
      if (byte == 10) {
        final line = utf8.decode(pending).trim();
        pending.clear();
        if (line.isNotEmpty) yield line;
      } else {
        pending.add(byte);
        if (pending.length > 65536) {
          throw const ScoutCliException(
            'live_request_too_large',
            'An agent request exceeds 64 KiB.',
          );
        }
      }
    }
  }
  if (pending.isNotEmpty) {
    final line = utf8.decode(pending).trim();
    if (line.isNotEmpty) yield line;
  }
}
