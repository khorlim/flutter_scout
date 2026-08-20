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
flutter-scout record export checkout --feature orders \
  --out /private/path/checkout-replay.json --retention session
```

Exports are private application-data artifacts. Scout writes owner-only bytes
and metadata, registers their exact unchanged identity, and defaults to
`session`; choose `24h`, `7d`, or `manual` only when the handoff genuinely needs
to outlive session cleanup. Scout never changes the permissions of an existing
caller-owned output directory.

Recorded sensitive fields use placeholders. Supply them from protected stdin
or an owner-only, non-symlink `0600` JSON file so plaintext never enters process
arguments:

```bash
flutter-scout record run checkout --feature orders \
  --var-file /private/path/checkout-vars.json
flutter-scout replay session.json --var-stdin
```

Legacy `--var field=value` is accepted with a warning only for deliberately
non-sensitive values. `could-not-start` is distinct from a regression and uses
exit code 2.

Use `batch` for a known, timing-sensitive sequence:

```bash
flutter-scout batch --file flow.scout
flutter-scout batch 'tap btn.save --expect-text Saved; inspect --brief'
```

Use `evidence` for handoff. It includes screenshot, inspect, status, logs,
session actions/transcript, and `events.jsonl`. Event arguments redact input,
fill JSON, file values, Dart defines, and other sensitive payloads. Choose an
explicit private retention policy only when needed; `session` is the safe
default:

```bash
flutter-scout evidence -o /private/path/checkout-evidence \
  --retention session
```
