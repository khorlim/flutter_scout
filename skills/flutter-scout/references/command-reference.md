# Command reference

Core lifecycle: `devices`, `doctor`, `ensure`, `launch`, `attach`, `status`,
`apps`, `stop`, `version`.

Eyes: `inspect`, `health`, `screenshot`, `crop`, `logs`, `evidence`,
`annotations`.

Hands: `tap`, `tap-text`, `input`, `fill`, `long-press`, `scroll`, `scroll-to`,
`swipe`, `drag-start`, `drag-move`, `drag-status`, `drag-end`, `drag-cancel`,
`back`, `dismiss`, `deeplink`.

Synchronization: `wait`, `wait-for`, action `--expect-*`, `--expect-log`,
`--reject-log`, `--allow-errors`.

Update: `reload`, `restart`.

Automation: `batch`, `serve`, `explore`, `record`, `export-batch`, `replay`.

Use `flutter-scout help <command>` for the installed build's exact options.
JSON is the source of truth. Nonzero exits mean the requested assertion or
operation failed; record replay uses exit code 2 when it could not start.
