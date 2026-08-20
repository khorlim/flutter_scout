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
dart run bin/flutter_scout.dart annotations check
dart run bin/flutter_scout.dart annotations resolve ann_001 --note "Fixed"
dart run bin/flutter_scout.dart annotations dismiss ann_002
dart run bin/flutter_scout.dart annotations clear --resolved
```

Annotation output includes captured `snapshotRect` values and matched `liveRect`
values when the target is still present, so code fixes do not need to delete the
review marker. Resolve or dismiss annotations explicitly when they are done.

## Basic Flow

```bash
dart run bin/flutter_scout.dart launch --device <simulator-id> --project ../../apps/scout_test_app
dart run bin/flutter_scout.dart inspect
dart run bin/flutter_scout.dart tap btn.add_supplier
# Create /private/tmp/supplier.json as an owner-only 0600 JSON file first.
dart run bin/flutter_scout.dart fill --file /private/tmp/supplier.json
dart run bin/flutter_scout.dart tap btn.save_supplier
dart run bin/flutter_scout.dart crop btn.add_supplier
dart run bin/flutter_scout.dart crop --changed-since '<snapshot-id>'
dart run bin/flutter_scout.dart replay .flutter_scout/session.json
```

`crop --changed-since` is a fail-closed in-app visual-delta primitive. It uses
retained helper snapshot history and `delta.changedRegions`, bounds the complete
union to 16 regions / 50% of the viewport / 256 logical padding / 4,194,304
output pixels, and verifies that the capture-time snapshot did not change. The
result includes baseline/current/verification identities, logical and physical
rects, DPR, backend, limits, and capture provenance. It does not guess missing
geometry or native transforms; platform views require a full native screenshot.

Attach to a running app when the human or IDE already started it:

```bash
dart run bin/flutter_scout.dart attach --device <simulator-id>
dart run bin/flutter_scout.dart attach --debug-url-file /private/path/vm-service-url
```

The VM-service URL file must be a regular non-symlink file and exactly `0600`
on POSIX. `--debug-url-stdin` is the protected pipe alternative. Scout accepts
only an explicit loopback host and port; remote VM-service egress is
unsupported. Legacy `--debug-url` remains temporarily compatible but warns
because the capability URL is visible in process argv.

Pass Flutter compile-time values to `launch` or `ensure` with an owner-only
`--dart-define-from-file <path>`. Scout validates the bounded, strict-UTF-8,
regular non-symlink file before session creation and revalidates it in the
detached worker immediately before starting Flutter. Scout's state and direct
Flutter-tool argv contain only the absolute path. Keep the file private and
stable until Flutter reads it. Inline `--dart-define` warns for nonsecret values
and rejects secret-looking names or values. Flutter may still materialize
compile-time values in downstream tools or the built app, so Dart defines are
not a secure application secret store.

The session state lives under `.flutter_scout/` in the current working
directory.

## Operability

Use `status` for session/runtime ownership, `doctor` for project and setup
diagnostics, and `health` for current app/runtime health. All three include the
same bounded `operability` object. It distinguishes observed facts from
unavailable ones and includes CLI/helper identity, protocol negotiation,
session/run/runtime/source/device identity, runner and supervisor ownership,
artifact paths, active drag/recording state, source freshness, and one
prioritized recovery action.

The persistent transport's authenticated loopback-only `GET /health` separates
daemon readiness (`transportHealthy`) from app health (`healthy` and
`appReachable`), so a live daemon never implies a reachable Flutter app. See
[`docs/operability-contract.md`](../../docs/operability-contract.md) for the
field semantics and unavailable-state rules.
