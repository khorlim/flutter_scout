# Agent-only hard cutover — verification

Date: 2026-09-15. CLI: 2.0.0-dev.2. Agent protocol: 2. Helper protocol: 15 (unchanged).

## Implemented

- Public standalone UI reads, actions and waits fail before dispatch with
  `agent_session_required`. HTTP serve/explore, live, batch/export-batch,
  record and replay execution implementations are removed. Historical journals,
  stable error meanings and exact-ownership cleanup remain.
- One persistent agent owns each named session. A second connection, or an
  existing verified pre-cutover controller, prevents another hand from opening.
- Input receipts must be delivered and acknowledged before further input.
  Failed actions require explicit fresh-view reconciliation; unknown dispatch
  outcomes remain halted. Nothing automatically retries.
- Fixed query response correlation and out-of-order view regression. Added
  read-only focused queries, held-drag/reveal/deep-link actions, and explicit
  scene actionability. Input now accepts exactly one value argument so a
  mistaken field handle cannot silently become part of the entered text.
- Updated shared usage/setup/annotation skills and local CLI installation.
  Screenshots remain manual. No model/tier requirement or Fast mode is enabled.
  Interactive-terminal fallback guidance uses short output yields, not fixed
  30-second waits after already-completed Scout responses.
- Added explicit macOS foreground activation on the same connection. It targets
  only the connected VM's app, shares the hand, re-observes actual rendering and
  preserves receipt/runtime guards. No Accessibility service, frame pumping or
  automatic focus stealing is involved.
- Updated release-critical CI, network-egress policy, proof references and the
  v2 contract generator. Historical evaluation adapters are explicitly marked
  v1-only, not current live acceptance evidence.

## Automated verification

| Check | Result |
| --- | --- |
| CLI analysis and full suite | Clean; 327 passed |
| Helper analysis and full suite | Clean; 195 passed |
| Fixture analysis and tests | Clean; 16 passed |
| Node client tests | 8 passed |
| Evaluation analysis and full suite | Clean; 126 passed |
| Shared skill validation and installed-file comparison | Passed |
| Installed legacy command probe | Rejected with `agent_session_required` |
| Second live controller probe | Rejected with `agent_session_busy` |

The public JSONL integration test exercises actual agent dispatch through a
fake VM transport, receipt delivery, acknowledgement, exactly-once behavior,
secret redaction and persistence. Existing safety/storage/compatibility tests
remain. Removed-transport-only tests were retired, not reinterpreted as live
coverage. Historical v1 envelope fixtures were replaced with a reviewed exact
v2 digest plus an explicit retired-error allowlist.

Two existing test problems were repaired without weakening their assertions:
an unawaited Flutter pump and a detached-worker fixture launched against an
intentionally fake package configuration. The latter now uses the real test
package configuration and waits for a worker-ready signal.

Final CLI output: `/tmp/scout-main-cli-tests.log`.
Helper output: `/tmp/scout-cutover-helper-final-tests.log`.
Fixture output: `/tmp/scout-cutover-fixture-tests.log`.
Independent test-agent report: `/tmp/scout-cutover-sol-test-result.md`.

## Earlier clean-agent attempts — blocked

Independent CLI agents were started without inherited conversation using
`gpt-5.6-sol`, `model_reasoning_effort="high"`, `service_tier="default"` and
`--ignore-user-config`. No priority/Fast option was used; billing-tier telemetry
was not independently measured.

The live goal was to add a supplier, verify the list, visit another surface,
and return. The first clean agent used one connection, dispatched two inputs,
handled a known non-dispatched input failure by reconciliation, and stopped
when macOS hid the fixture. No supplier was saved. It took about 5m06s, including
avoidable 30-second terminal yields; this motivated the revised fallback guidance.

A second fresh agent using the installed CLI and corrected guidance found
rendering suspended at its initial observation. It issued zero UI inputs,
closed its sole connection, and did not retry or take screenshots. Its Scout
session lasted about eight seconds. This proves safe abstention, not completed
business behavior or a speed improvement.

The parent restored the window with its observed native Raise action, but
visibility did not persist. A subsequent native activation attempt failed with
`Sky Computer Use service startup request failed`. The rendering guard was
never bypassed. This motivated explicit native activation and fresh acceptance.

Live reports: `/tmp/scout-cutover-sol-live-result.md` and
`/tmp/scout-cutover-sol-live-final-result.md`.

The owned `scout-hard-cutover` app and its supervisor were stopped successfully;
session evidence was preserved. No TunaiPro app or other task was stopped.
Those attempts did not establish end-to-end success.

## Fresh clean-agent acceptance — passed

A fresh `gpt-5.6-sol` / high agent, with `service_tier="default"` and
`--ignore-user-config`, tested the candidate on `scout-main-acceptance` without
prior reports or app source. It used one persistent Node/Scout connection and
no screenshots. Native `foreground()` recovered the initially hidden fixture.

The agent opened Add supplier, filled the observed name/phone fields with
`Sol Main Acceptance` / `601500000003`, saved, and independently located exactly
one matching supplier on the list. It visited `StressLabHub`, returned, opened
an empty supplier form, cancelled, and verified the same supplier still existed.
The phone is not rendered on the list, so visible phone verification is not claimed.

Eight inputs dispatched with successful canonical receipts and clean runtime
health. One stale Save decision was rejected before dispatch (no action ID);
the agent re-observed and made a fresh decision. An Account settings tap only
changed a fixture intent label; the agent correctly did not count that as
navigation and selected a distinct observed screen instead. It closed its
connection successfully. Elapsed connection-to-close time: 354,552 ms (5m55s).

This establishes live functional acceptance and safe stale-decision handling,
not human-equivalent speed or a percentage improvement. Helper production code
and its protocol are unchanged by this cutover. Previously passing helper and
fixture suites were not redundantly rerun after CLI-only fixes.

Clean-agent raw evidence: `/tmp/scout-main-sol.jsonl`.
Evaluation suite: `/tmp/scout-main-evaluation-tests.log`.

The installed CLI's subsequent stop check exposed `agent.lock` as unexpected
residue after all owned processes stopped. Cleanup now recognizes and preserves
that serialization inode, like the retention lock; it must not unlink a lock
that another controller can still hold. The existing cleanup behavior test also
verifies writes through the original lease still reach the same file.
