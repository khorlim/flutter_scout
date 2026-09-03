# Flutter Scout compatibility policy

This document distinguishes implemented compatibility from release-ratified
support. It is not a claim that the current checkout is releasable. The
fail-closed gates and current blockers are tracked in
[RELEASING.md](RELEASING.md).

## Compatibility is capability-based

Package versions are useful inventory, but they do not authorize an action.
The CLI and helper negotiate a schema version, an overlapping protocol range,
and required capabilities at runtime. A mutation is allowed only when the
helper proves all safety capabilities required by that command.

The current source contract is:

| Contract | Current source value | Status |
| --- | --- | --- |
| CLI package | `flutter_scout` 2.0.0-dev.1 | Unreleased prerelease identifier for the breaking protocol-15 candidate; not a published or release-ratified version. |
| Helper package | `flutter_scout_helper` 0.2.0-dev.1 | Unreleased prerelease identifier for the helper's pre-1.0 compatibility-boundary change; not published or release-ratified. |
| Core response schema | 1 | Machine-readable schemas exist under `protocol/schemas/v1/`; release immutability is not established until a signed release contains them. |
| CLI protocol range | 15 through 15 | Implemented in the current source. |
| Helper protocol range | 15 through 15 | Implemented in the current source. |
| Required mutation capabilities | The exact 12-capability set is machine-readable in `protocol/compatibility-matrix.v1.json`: typed envelope; state generation and SHA-256 digest; strict envelope; serialized mutations; stable idempotency fingerprint, execution, and tombstones; runtime-error cursor; held-drag exclusion; source redaction; and phase timings. | Negotiated before dispatch; capability presence is required rather than inferred from a package version. |
| Previous-helper migration window | None | Protocol 14 and older are not supported by this candidate. The CLI must abstain before mutation. |

Current-source/current-source protocol behavior has focused contract tests, but
the deterministic matrix in
[`protocol/compatibility-matrix.v1.json`](protocol/compatibility-matrix.v1.json)
is deliberately limited to current source plus configured protocol-14,
protocol-15, and protocol-16 fixtures. It proves bilateral range rejection,
required envelope/capability checks, additive response-field tolerance, and
pre-dispatch abstention at the source boundary. It does not exercise separately
built or published `N`, `N-1`, and `N+1` artifacts or a simulator. Therefore the
pair is **implemented, not yet release-ratified**.

## CLI and helper pairings

| CLI | Helper | Read behavior | Mutation behavior | Classification |
| --- | --- | --- | --- | --- |
| Current source, protocol 15 | Current source, protocol 15 | Typed schema-1 responses are expected. | Allowed only after identity, state, deadline, range, and capability preflight. | Implemented; release ratification pending. |
| Current source, protocol 15 | Protocol 14 or older | No compatibility promise. Diagnostics may be available, but callers must not depend on an operational read loop. | Must fail closed before dispatch because the ranges and strict capabilities do not match. | Intentionally incompatible. |
| Protocol 14-or-older CLI | Current source, protocol 15 helper | No compatibility promise. | Legacy mutations lack the mandatory envelope and must be rejected before dispatch. | Intentionally incompatible. |
| Current source, protocol 15 | Future protocol 16-only helper | No compatibility promise. | Must fail closed before dispatch unless a future reviewed change expands both ranges and tests the pair. | Intentionally incompatible today. |
| Future protocol 16-only CLI | Current protocol 15 helper | Unknown. | The helper range remains 15-only and must reject a non-overlapping client range. | Intentionally incompatible today. |

Unknown optional response fields may be ignored within schema 1. Missing
required fields, unknown mutation request fields, changed error semantics, or a
non-overlapping protocol range are incompatibilities. Published schema files
must never be changed incompatibly; a breaking schema change requires a new
schema directory.

Every command response and error is a typed JSON envelope. The explicit
human-rendering surfaces are `help`, `--help`, `-h`, and invocation without a
command; these emit prose by caller request and are not machine-response
records. Unknown commands emit one structured error on stderr and do not mix
usage prose into stdout. `cleanup` is a retained internal alias for `stop`;
`vm-log-listener` and `flutter-run-worker` are process-internal entry points,
not public commands. All other dispatchable commands are included in the
public command catalog used for discovery and suggestions.

The opt-in leading `--single-json` prefix emits exactly one compact final
response on stdout for finite machine commands, including errors, after command
evidence completion. Heartbeats, warnings, and intermediate responses remain
on stderr. Help remains a prose surface. `serve`, `explore`, and internal
workers reject this prefix before starting; persistent HTTP contracts and
default CLI stream routing are unchanged. This is presentation framing only:
all envelope fields, redaction, and payload bounds remain in force.

## Language and framework toolchains

| Layer | Declared constraint | Tested release evidence | Support statement |
| --- | --- | --- | --- |
| CLI Dart SDK | `^3.12.2` | Blocking CI is configured through Flutter 3.44.2; the exact bundled Dart identity must be captured for each candidate. | Dart versions satisfying the pub constraint are build-eligible, not automatically supported. Only the pinned candidate toolchain can be release-ratified. |
| Helper Dart SDK | `^3.12.2` | Same blocking pin as above. | Same qualification as the CLI. |
| Helper Flutter SDK | `>=3.44.2` | Blocking CI is pinned to exactly 3.44.2; newer stable/beta runs are canaries only. | The constraint refuses historically untested Flutter lines. Only the exact pinned candidate is release-eligible until broader retained evidence exists. |
| Stable/beta Flutter channels | Floating canary jobs | Non-blocking and version-dependent. | Compatibility signal only; never release evidence by itself. |

Every release evidence bundle must preserve the complete
`flutter --version --machine` result (or an explicit collection failure), Dart runtime identity,
lockfile inventory, candidate commit, and dirty-worktree state. A toolchain
change requires all blocking gates to be rerun.

## Host and target matrix

No target is Tier 1 until the same automated behavioral contract passes for
visibility, occlusion, modal scope, hit testing, input, scrolling, errors,
capture provenance, lifecycle, and cleanup. The repository currently lacks
that retained cross-platform evidence.

| Host / target | Current evidence | Release classification |
| --- | --- | --- |
| Ubuntu host, package/unit checks | Blocking CI configuration exists for Flutter 3.44.2. | Static and unit-check host only; not evidence for simulator behavior. |
| macOS host / macOS desktop | Core developer workflow and macOS-specific supervision exist. | Experimental; no current complete Tier-1 behavioral suite or ratified baseline. |
| macOS host / iOS Simulator | Manual workflows are documented. | Experimental; intended Tier 1, but not ratified. |
| macOS, Linux, or Windows host / Android Emulator | Exact recorded-emulator routing, local-argv ADB deep links with explicit remote-shell quoting, fully decoded native PNG capture, bounded output and TERM-to-KILL process handling, atomic private artifacts, and fail-closed crop coordinate validation have deterministic source tests. No complete real-emulator behavioral suite is retained. | Experimental; implemented native capability is not Tier-1 or parity ratification. |
| Windows desktop | No complete behavioral evidence. | Experimental. |
| Linux desktop | No complete behavioral evidence. | Experimental. |
| Web | VM-service, input, capture, and lifecycle parity are unproven. | Experimental. |
| Physical iOS or Android devices | State preservation, permissions, capture, and cleanup parity are unproven. | Experimental. |

An experimental platform may expose only capabilities it can prove. A missing
operation must return `unsupported_capability` before mutation. Native or
platform-specific fallbacks must report their backend, coordinate semantics,
provenance, and limitations.

Native mobile operations additionally require exact session device metadata and
a read-only reachability preflight. Android Emulator capture uses
`adb -s <id> exec-out screencap -p`; deep links use
`adb -s <id> shell am start -W -a android.intent.action.VIEW -d <url>` as a
local argv vector with the URL single-quoted for ADB's remote device shell.
Deep-link dispatch also requires a fresh protocol-valid observation whose run
identity exactly matches the selected session; otherwise Scout abstains before
ADB receives the URL.
Native crop materialization requires the helper's scoped
Flutter-view physical viewport to exactly match the captured PNG dimensions;
Scout does not infer status-bar, navigation-bar, inset, rotation, or letterbox
offsets. These source capabilities do not replace retained simulator evidence.

VM-service transport is host-local regardless of target classification. Every
explicit, log-discovered, or saved service URI must use `ws`, `wss`, `http`, or
`https`, an explicit valid port, and exact `localhost`, `::1`, or canonical
`127/8`. Non-loopback egress and an override for it are intentionally
unsupported. This is a security boundary, not a platform capability fallback.

## Upgrade procedure

Protocol 15 is a coordinated CLI/helper change with no protocol-14 migration
window. A safe upgrade therefore has a temporary fail-closed, non-operational
period:

1. Preserve private evidence and stop any Scout daemon for the session. Do not
   clear simulator or app data.
2. Install the candidate CLI and verify its commit with `flutter-scout version`
   and `flutter-scout doctor`.
3. Update the app's helper dependency to the candidate commit or immutable tag,
   resolve from the reviewed lockfile, and perform a full debug relaunch. Hot
   reload is not a dependency upgrade.
4. Run `status` and `inspect` and confirm schema 1, protocol 15, the expected
   runtime/run identities, and required capabilities.
5. Perform one uniquely targeted, guarded action. Preserve its closed outcome
   dimensions and fresh runtime signals.
6. Exercise capture/evidence and exact owned-process cleanup before restoring
   normal agent use.

Do not mutate through a mixed protocol-14/protocol-15 pair. The expected result
during the mixed interval is a clear pre-dispatch incompatibility.

## Downgrade and rollback compatibility

A downgrade must treat the CLI and helper as one compatibility set:

1. Stop candidate distribution and select a previously verified signed tag.
2. Stop the candidate daemon without killing attach-only or unrelated
   processes. Preserve uncertain-action evidence; never replay it automatically.
3. Activate the CLI from the selected immutable tag.
4. Pin the app to the helper revision documented for that tag and perform a full
   debug relaunch without resetting application data.
5. Re-run version, doctor, status, attach, inspect, one guarded action, evidence,
   and cleanup checks.

There is currently no signed known-good Flutter Scout tag or rehearsed release
rollback in this repository. Downgrade/rollback is consequently documented but
**not release-ratified**. See [RELEASING.md](RELEASING.md) for the blocking
exercise and signature-verification requirements.

## Versioning policy

The CLI and helper are versioned independently using Semantic Versioning:

- incompatible public API or documented command behavior changes require the
  appropriate major change (for a pre-1.0 package, the next minor version is
  the compatibility boundary described by SemVer);
- backward-compatible functionality requires a minor change;
- backward-compatible fixes require a patch change;
- build metadata does not establish protocol compatibility.

The core protocol version is an independent integer and the schema version is
an independent immutable contract directory. Every release must align package,
protocol, schema, capability, migration, and error-semantic changes in both
package changelogs and this matrix. No version number substitutes for runtime
negotiation.
