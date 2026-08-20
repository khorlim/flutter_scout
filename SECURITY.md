# Security policy

Flutter Scout is a debug-only developer tool that gives an AI agent inspection
and mutation access to a running Flutter application. That access is powerful:
anyone who can use Scout against an app should be treated as able to read its
debug UI state and operate it as the developer.

This document defines the intended security boundary. It is not a claim that
every release gate in [RELEASING.md](RELEASING.md) currently passes. A release
must verify these properties; unresolved or unmeasured properties remain
blockers.

## Supported security scope

The supported scope is a single developer operating a debug Flutter app on a
trusted local workstation, simulator, emulator, or development device. Scout's
CLI, session files, VM-service connection, and optional persistent HTTP daemon
are expected to run under that developer's operating-system account.

Scout is not a production remote-control service and is not hardened for:

- profile or release applications;
- internet-facing or non-loopback listeners;
- shared hosting or mutually untrusted users under one account;
- hostile root/administrator access;
- a hostile process already running as the same user;
- protecting data from the debug application or Flutter VM service itself;
- evaluating untrusted Flutter projects inside a security sandbox.

Normal profile and release builds must not register Scout service extensions,
error hooks, recorders, overlays, or network listeners. The helper guards
registration with Flutter's debug-mode constant. Blocking CI builds the same
Android fixture in debug, profile, and release modes: debug is a positive
scanner control, while the profile and release AOT binaries must omit sentinels
for service-extension registration, VM-URI broadcast, recording, and mutation
handling. This proves the compiled Android boundary; runtime absence and other
Tier-1 targets remain part of release qualification.

## Threat model

Assets include application data visible in widgets, field contents, screenshots,
logs, VM-service credentials, session credentials, action recordings, evidence
bundles, and the integrity of the running app and other local processes.

Relevant threats include:

- a webpage attempting a cross-site request to a loopback Scout daemon;
- another local user connecting to a discovered port or reading an artifact;
- accidental publication of a recording, screenshot, log, or evidence bundle;
- an app placing secrets in labels, errors, routes, keys, or logs;
- stale session metadata resolving to a different process or runtime;
- retries causing a duplicate mutation after an uncertain timeout;
- ambiguous or stale handles activating the wrong control or surface;
- path traversal, oversized input, malformed JSON, or unsupported parameters;
- a release/profile build accidentally retaining active Scout behavior.

Loopback and file permissions do not defend against a malicious process running
as the same user. The bearer credential prevents unauthenticated requests; it is
not a second user-isolation boundary when that process can read the credential
file.

## Local authenticated transport

The persistent `serve` transport is local-only and must preserve all of these
properties:

- bind to loopback, never a wildcard or externally routable address;
- generate a fresh bearer credential for each daemon lifetime;
- store the authorization header in an owner-only credential file;
- require that credential for calls, mutations, and daemon shutdown;
- accept mutations only through `POST`;
- reject query parameters, unexpected paths, invalid UTF-8, wrong content
  types, oversized bodies, expired deadlines, and unknown typed parameters;
- compare credentials without an early-exit string comparison;
- reject cross-site browser requests and non-matching browser origins;
- keep legacy free-form `/run` disabled unless the operator explicitly enables
  it with `--allow-legacy-run`;
- serialize daemon operations so a timed-out, uncancellable mutation cannot
  overlap a later mutation.

`GET /health` and `GET /v1/schema` may expose daemon health and method schema but
must not expose application state or perform a mutation. The credential is
ephemeral and its file is removed on clean shutdown when ownership still
matches. A crash may leave an inert credential file; it must not authenticate a
future daemon.

The Dart VM service is a separate debugging interface with its own capability
URI and authentication token. Scout validates every explicit, log-discovered,
or saved URI before connection or persistence. Only `ws`, `wss`, `http`, and
`https` URLs with an explicit port and an unambiguous loopback host are
accepted: canonical `127/8`, `::1`, or exact `localhost`. User information,
fragments, missing or invalid ports, malformed URLs, and every non-loopback host
fail before network egress. Remote VM-service transport has no opt-in and is
unsupported.

The full VM-service URI may exist only in the designated owner-only
`.flutter_scout/vm_uri.txt` capability store and in the existing owner-only
one-shot helper-child handoff. Session metadata, command responses, errors,
status/doctor results, logs, and journals expose an endpoint identity only:
scheme, loopback host, port, whether a credential is present, and the local-only
transport policy. A legacy metadata URI is registered for redaction and
migrated before use. The detached Flutter worker validates a discovered tool
line, atomically commits the capability to that single store, and redacts the
line before log persistence; the launch parent polls the private store rather
than recovering credentials from logs. Scout's HTTP credential does not secure
the VM service. Do not expose it through port forwarding, a public proxy, or an
untrusted network.

## Secret redaction

Within the supported debug scope, Scout applies source-level redaction before
serializing observed state:

- `obscureText` and visible-password editables are sensitive;
- field keys, labels, hints, semantics, and autofill metadata are checked for
  common password, PIN, passcode, OTP, payment-card, session, token, cookie, and
  API-key descriptors;
- a sensitive field reports that it is redacted and whether it is empty, but not
  its plaintext or length;
- known sensitive values are scrubbed from derived labels, handles, validation
  messages, errors, snapshots, before/after payloads, and other extension
  response strings;
- recordings store placeholders rather than input/fill plaintext, and replay
  requires the value to be supplied again;
- command journals and Scout-owned logs redact recognized credential names and
  bearer values before persistence;
- VM-service URIs are passed to Scout and helper processes through owner-only
  files or standard input, not process arguments;
- deep-link URLs are treated as credentials because their user information,
  path, query, or fragment may contain tokens. Durable journals store only a
  placeholder and ingress provenance, never the URL.

Redaction is defense in depth, not a universal data-loss-prevention system. In
particular:

- a custom sensitive control that is neither an editable nor recognizably
  labelled may not be classified;
- arbitrary secrets in app prose, stack traces, native logs, binary data, or
  third-party tool output may not match known patterns;
- screenshots and crops contain rendered pixels and are not guaranteed to have
  secrets visually removed;
- a value supplied directly on a command line may already be visible to shell
  history or same-user process inspection before Scout can redact its own
  records;
- historical artifacts created by an older version must be treated as
  unredacted unless independently inspected;
- Scout cannot redact copies made by an agent host, terminal, IDE, shell,
  operating system, Flutter tool, or external logging system.

Use protected ingress whenever a value may be sensitive:

- `input --file <path>` or `input --stdin` for one text value;
- `fill --file <path>` or `fill --stdin` for a JSON object of string
  field/value pairs;
- `attach --debug-url-file <path>` or `attach --debug-url-stdin` for a
  VM-service capability URL;
- `deeplink --url-file <path>` or `deeplink --url-stdin` for a deep-link URL;
- `launch|ensure --dart-define-from-file <path>` for Flutter compile-time
  values;
- `--var-file <path>` or `--var-stdin` with `replay`, `record run`, and `batch`
  for a JSON object of string placeholder/value pairs.

Protected action/variable input is bounded to 1 MiB; VM-service capability URLs
have a tighter 16 KiB limit. Every source is decoded as strict UTF-8. Protected
files must be regular files, must not be symbolic links, and on POSIX must
already be exactly `0600`; Scout fails closed and never chmods caller-owned
input. Variable names are bounded and reject `=`, leading/trailing whitespace,
and C0/C1 control characters. Every variable source is parsed and every
required placeholder is preflighted before the first mutation. Duplicate names
across sources fail.

Dart define files use the same 1 MiB, strict-UTF-8, regular-file, non-symlink,
exact-`0600` boundary. Scout validates the caller-owned file before any session
artifact is created and the detached worker validates it again immediately
before spawning Flutter. Only its normalized absolute path is stored in the
private worker configuration and passed in the Flutter argument vector; raw
define contents are never copied into Scout state, the Scout worker invocation,
or the direct Flutter-tool argument vector Scout creates. The worker registers
bounded JSON or dotenv leaf values for sink redaction before Flutter can emit
output. This is a protected use of Flutter's native define-file interface, not
a claim that Flutter accepts secret defines over stdin or keeps them out of its
own downstream tool-process arguments, logs, or built application. Dart
compile-time values are not a secure application secret store. The caller must
keep the file private and stable until Flutter reads it, and the file path
remains visible to same-user process inspection.

Legacy positional input/deep links, `fill --json`, `--debug-url <url>`,
`--var name=value`, and nonsecret inline `--dart-define name=value` remain for
compatibility but emit a structured
`insecure_secret_source` deprecation warning: their values may be visible in
shell history and same-user process inspection before Scout starts.
Secret-looking inline Dart-define names or values are rejected before session
state or child-process creation; use `--dart-define-from-file` instead. The
native Android dispatch tool necessarily receives a deep link in its short-lived ADB
argument vector and remote-shell command after preflight; protected ingress
removes it from the caller's shell argv and from Scout persistence, not from the
platform API used to deliver it. Never include real production credentials in
fixtures. Generated adversarial redaction tests and a zero plaintext-leak
result are release requirements, not optional quality improvements.

## Private artifacts and retention

Treat all of the following as private application data even after redaction:

- `.flutter_scout/` session state and logs;
- credential and VM-URI files;
- action recordings and replay variables;
- screenshots and crops;
- evidence bundles and evaluation raw episodes;
- CI attachments, crash reports, and diagnostic transcripts.

Session directories should be owner-only `0700`; files containing credentials,
VM URIs, recordings, logs, or evidence should be `0600`. Do not commit these
artifacts, upload them to a public issue, place them in a shared temporary
directory, or sync them through an unapproved service.

CLI-managed evidence, screenshots, and crops require an explicit supported
retention classification (`session`, `24h`, `7d`, or `manual`) and default to
session retention. Record exports use the same policy contract. Their bytes and
metadata are committed before an entry is added to the owner-only, atomic,
lock-serialized session registry. Each entry binds the exact canonical artifact
and metadata paths to the policy, timestamps, session/run correlation, stable
file statistics, and SHA-256 content evidence. Directory bundles use a bounded,
sorted manifest and refuse links, non-regular entries, canonical aliases, and
portable case collisions.

At command start Scout removes expired registered `24h` and `7d` artifacts.
`stop --clear-session` additionally removes registered `session` artifacts and
an exact allowlist of managed session credentials, logs, locks, and temporary
state. `manual` artifacts and reusable recordings are never selected by those
automatic policies. Cleanup never scans a caller-owned parent: it rechecks the
recorded identity immediately before deleting only the registered object and
its metadata. A missing object is closed as already absent; a replacement,
symlink, non-regular object, changed directory, malformed registry, or unsafe
residue is preserved and surfaced as a typed incomplete/invalid result.
Unrelated commands may continue after a valid-registry identity mismatch, but
receive a typed warning; corrupt registry state fails closed and is neither
erased nor replaced.

External output parents remain caller-owned and are never chmodded by artifact
writes. Historical or unregistered artifacts are not guessed from filenames;
session clear reports `sessionCleared:false` while unexpected residue remains.
These guarantees have deterministic adversarial filesystem tests, including
expiry, concurrency, replacement, symlink, torn-registry, permission, and
session-residue cases. That test evidence is not empirical cross-platform or
long-duration qualification, so the release process must still exercise the
retention/endurance suite on supported hosts. Operators remain responsible for
access-controlled destinations and for manually deleting `manual` material.

Scout has no intentional product telemetry. Every Flutter tool process that
Scout starts receives `FLUTTER_SUPPRESS_ANALYTICS=true`, including discovery,
launch, and temporary-helper dependency resolution. Its explicit runtime
communication is with local tools, the Dart VM service, and the loopback daemon.
This does not turn dependency resolution into an offline operation: Flutter,
Dart, package repositories, CI providers, and agent hosts may still have
separate network behavior and policies. An artifact's
`telemetryCollected:false` label describes Scout's own collection, not a claim
that unrelated application or host processes made no network requests.

## Fail-closed principles

Security and safety uncertainty must stop the risky operation:

- missing or invalid authentication means reject the request;
- incompatible or missing required protocol capability means no mutation;
- ambiguous, stale, hidden, disabled, occluded, or wrong-surface targets mean no
  dispatch;
- an uncertain dispatch timeout means `dispatch_outcome_unknown`, never a blind
  retry;
- uncertain process ownership means do not signal or terminate the process;
- unsupported platform behavior means `unsupported_capability`, not a guessed
  fallback;
- a redaction/classification failure must not expose the raw sensitive field;
- cleanup must not reset application or simulator data unless explicitly
  requested;
- any reproducible secret leak, unrelated process termination, modal bypass,
  cross-session mutation, wrong-target activation, or duplicate mutation blocks
  release.

## Reporting a vulnerability

Please use GitHub's private vulnerability-reporting flow for this repository:
[open a private security advisory](https://github.com/khorlim/flutter_scout/security/advisories/new).

Include the affected commit or package version, operating system, Flutter/Dart
toolchain, reproduction steps, impact, and the smallest safe diagnostic evidence.
Do not include real secrets, private screenshots, VM-service tokens, bearer
credentials, or customer data. If private reporting is not enabled, do not open
a public issue containing exploit details; contact the maintainer privately
through GitHub first.
