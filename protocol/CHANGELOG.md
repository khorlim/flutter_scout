# Flutter Scout protocol changelog

## Unreleased

- Define the immutable schema-1 document set under `protocol/schemas/v1/` and
  bind every document to a deterministic release schema manifest.
- Coordinate protocol 15 across the CLI and helper, including typed envelopes,
  mutation identity, runtime and state preconditions, deduplication, hard-signal
  cursors, phase timings, source redaction, and capability negotiation.
- Publish the source-only protocol-15 compatibility matrix and explicit
  protocol-14/protocol-16 fail-closed pairings. Separately built artifacts and
  simulator exercises remain required before release ratification.
- Treat additions within schema 1 as optional-only. Missing required fields,
  unknown mutation fields, changed closed error semantics, or incompatible
  protocol ranges require pre-dispatch rejection; incompatible schema changes
  require a new versioned schema directory.
- Register stable `insecure_dart_define_secret` and
  `invalid_dart_define_source` semantics for fail-closed CLI compile-time-value
  ingress; no helper wire field or protocol capability changed.
- Publish per-method CLI and helper request descriptors and validate the same
  exact type, size, conflict, and side-effect contracts before dispatch.
- Register bounded runtime-log corruption/change/record-size failures and
  lossless event-journal capacity failure as stable machine errors.

This section is aligned with the CLI and helper `Unreleased` sections. It is a
source-change record, not a release date, signed tag, or compatibility claim.
