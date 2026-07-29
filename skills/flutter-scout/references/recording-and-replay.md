# Recording and replay

Use in-app recording for a human-performed flow:

```bash
flutter-scout record start checkout --feature orders
flutter-scout record pause
flutter-scout record resume
flutter-scout record undo
flutter-scout record stop
```

Use retroactive extraction when the agent already completed the useful flow:

```bash
flutter-scout record save-last checkout --last 8 --feature orders
```

This selects the last successful action entries from the session journal and
writes a normal recording. Inspect and run it:

```bash
flutter-scout record show checkout --feature orders --transcript
flutter-scout record run checkout --feature orders
flutter-scout record export checkout --feature orders
```

Recorded sensitive fields can require `--var field=value` at replay time.
`could-not-start` is distinct from a regression and uses exit code 2.

Use `batch` for a known, timing-sensitive sequence:

```bash
flutter-scout batch --file flow.scout
flutter-scout batch 'tap btn.save --expect-text Saved; inspect --brief'
```

Use `evidence` for handoff. It includes screenshot, inspect, status, logs,
session actions/transcript, and `events.jsonl`. Event arguments redact input,
fill JSON, file values, Dart defines, and other sensitive payloads.
