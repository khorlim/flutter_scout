import 'dart:async';
import 'dart:io';

Future<void> main() async {
  ProcessSignal.sigterm.watch().listen((_) {
    // Deliberately keep running so the caller must escalate from TERM to KILL.
  });
  stdout.writeln('ready:${List<String>.filled(1024, 'x').join()}');
  await stdout.flush();
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
