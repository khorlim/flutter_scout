# Adversarial privacy corpus

This directory is the deterministic, versioned input contract for Flutter
Scout's `QUALITY_STANDARD.md` sections 8.2 and 8.4. The package tests generate a
unique plaintext for every sensitive category and payload trick, then sweep all
captured structures, stdout, stderr, and temporary artifacts for the plaintext
and its JSON, URI, Base64, Base64URL, and hexadecimal encodings.

The corpus stores a seed and payload grammar, not generated secrets. This keeps
test inputs reproducible without checking plaintext credentials into source.

`adversarial_privacy_coverage.json` is an honest coverage ledger. A future
`gap` is a release-blocking absence, never a passing or skipped test. A surface
is marked `implemented` only when the production path and an end-to-end
regression proof both exist.

The sweep deliberately excludes only the owner-only ingress file while a secret
is being supplied. That file is deleted before the final recursive artifact
sweep. All outputs and persistent artifacts remain in scope.

## Default-deny network inventory

`network_egress_policy.v1.json` is a separate source-level egress contract. It
enumerates every direct network primitive in production, evaluator, and
verification-app source. Each reviewed use must state a local-only destination
and retain the source evidence that constrains it to loopback. The evaluation
gate fails when a new HTTP, WebSocket, socket, VM-service, network-image, or
known telemetry client appears without an explicit policy entry.

The policy records that telemetry is not implemented and that any future
telemetry requires explicit opt-in. This is a deterministic source guard, not
proof that an OS process made zero outbound connections; release evidence must
still include an independent runtime network/process-boundary observation.
