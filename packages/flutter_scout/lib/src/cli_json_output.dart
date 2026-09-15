part of 'flutter_scout_cli.dart';

// Marker preserved for redacting historical journals, never for replay.
const String _kRecordRedactedPrefix = ' VAR:';

extension _CliJsonOutput on FlutterScoutCli {
  void _printJson(
    Object? value, {
    bool? success,
    String? commandName,
    bool pretty = true,
  }) => _writeCliResponse(
    value,
    success: success,
    commandName: commandName,
    pretty: pretty,
  );
}
