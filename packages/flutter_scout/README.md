# Flutter Scout CLI

Command-line eyes and hands for Flutter Scout.

This CLI attaches to or launches a Flutter debug session, calls the
`flutter_scout_helper` VM service extensions, captures simulator or macOS
app-window screenshots,
records action sessions, and replays flows.

It can also read user-created annotation comments from the running app:

```bash
dart run bin/flutter_scout.dart annotations list
dart run bin/flutter_scout.dart annotations targets
```

## Basic Flow

```bash
dart run bin/flutter_scout.dart launch --device <simulator-id> --project ../../apps/scout_test_app
dart run bin/flutter_scout.dart inspect
dart run bin/flutter_scout.dart tap btn.add_supplier
dart run bin/flutter_scout.dart fill --json '{"Supplier name":"QA Supplier","Phone":"0123456789"}'
dart run bin/flutter_scout.dart tap btn.save_supplier
dart run bin/flutter_scout.dart crop btn.add_supplier
dart run bin/flutter_scout.dart replay .flutter_scout/session.json
```

Attach to a running app when the human or IDE already started it:

```bash
dart run bin/flutter_scout.dart attach --device <simulator-id>
dart run bin/flutter_scout.dart attach --debug-url http://127.0.0.1:XXXXX/...
```

The session state lives under `.flutter_scout/` in the current working
directory.
