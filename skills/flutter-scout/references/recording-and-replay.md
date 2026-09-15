# Historical recordings

The record, replay, batch and export-batch entrypoints have been removed.
Existing private journals are evidence, not executable instructions or current
UI authorization. Do not replay old target handles or reproduce shell scripts.

For repeatable verification, express user goals using the current agent
session: observe, choose one current target, act once, check its receipt and
subsequent condition. Use bounded explicit reactions only when authorized.

Manual evidence bundles remain available:

```bash
flutter-scout --app <task> evidence -o /private/path/evidence --retention session
```

Journals redact secret values and are not complete historical screen trees.
A later observation cannot reconstruct an omitted earlier state. Unknown
input outcomes or evidence-persistence failures require reconciliation before
any further input, not a new action identity.
