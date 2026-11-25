## Unreleased

* A control's state facts (`enabled`, `selected`, `checked`, `toggled`,
  `expanded`) now count as an observed change. A tap whose only effect is
  one of them (a filter chip becoming selected) reports `changed` instead
  of `activated_no_observed_change` and returns without waiting out the
  late-change window (about 1 s). The stability wait also treats a state
  flip as a semantic change, so a state that flickers during an animation
  settles before the view is called quiet. State an app only paints is
  still not seen.
* After an input with no immediate change, each late-change round now ends
  as soon as a lasting change lands (`stoppingReason:
  late_change_observed`) instead of first waiting out its 250 ms stability
  window. The late-wait bound is unchanged. A late change can therefore
  report `stable: false`; the agent client settles a changed view itself.
* The session label no longer blinks during in-app captures. It stays
  mounted and visible for `overlay: include` captures (`--with-overlay`),
  so those images show it, and other captures hide it, by opacity, only
  for the frames a captured region covers it, as they do the pins. Before,
  every in-app capture removed and rebuilt it.
* The session label says "observing" only after about 15 s without input
  (any input resets the wait), not 2.4 s, so it no longer flips between
  "controlling" and "observing" on every agent turn. The glow and cursor
  still calm down after 2.4 s. The state word has a fixed-width slot and
  cross-fades, so the chip keeps its size. The overlay status adds `label`.

* A small control that shows its own text no longer borrows the next
  control's text as an alias (a "Points" chip also answering to
  `tap.credit`); nearby-text aliases stay for icon-only controls.
* A dialog, sheet or modal page is named from its stated title: an AppBar,
  SliverAppBar or Cupertino navigation bar title, a dialog or action sheet
  title, or a `Semantics(header: true)` (`source: appBarTitle`,
  `dialogTitle`, `header`), shown as written; else from its one prominent
  heading (16 pt or more and 2 pt above its common text, `source:
  heading`); else from its content widget type (`MemberListScreen`,
  `source: widgetType`). Only then do the old first-text guesses apply.
  Text inside a control (a segment pill in an app bar) is never a title. A
  surface keeps its name while it stays mounted (`instance`); a guessed name
  is replaced once, when a title appears. Before: a member profile was
  "OutstandingSurface", an item sheet "QuantitySurface", a member picker
  "CarSurface" then "ZernYetSurface".
* Duplicate handle numbering is sticky. A control that held `btn.x` or
  `btn.x_2` in the previous snapshot keeps it while it stays mounted; only
  newcomers take the lowest free number in screen order. Adding a cart row
  named like a grid tile now gives the row `btn.thai_yoga_2` instead of
  renumbering the tile. If a handle passes to a replacement control, its
  `instance` differs, so a stale decision on it is refused (agent
  `target <id> changed`, helper dispatch-time `target <id> changed`) instead
  of hitting the new control.
* Controls report the specific state Flutter knows: `checked` (Checkbox,
  CupertinoCheckbox, Radio under a RadioGroup, `Semantics(checked:)`),
  `toggled` (Switch, CupertinoSwitch, `Semantics(toggled:)`) and `expanded`
  (an ExpansionTile header, `Semantics(expanded:)`), in full and brief
  output and in deltas. `selected` stays the umbrella "on" fact (selected,
  else toggled, else checked). It is read from the widget, a state-bearing
  descendant, or a Semantics just above it in the same semantics node
  (SegmentedButton segments, NavigationBar destinations), and a list tile's
  own `selected: false` no longer hides the radio or checkbox inside it. A
  state shown only by paint (a coloured border) is still not observable.
* Controls are named after their own text, however deep it is drawn: the
  label search is bounded by elements instead of depth 18, so a CupertinoButton
  menu row (about 19 levels of its own) or a press-effect card is no longer
  named after its icon or asset (`btn.shippingbox_fill` -> `btn.thai_yoga`,
  `btn.page_sparkle_fill` -> `btn.default`, `btn.male` -> `btn.zern_yet`). It
  skips hidden text and prefers a real label over avatar initials or a badge
  count drawn first. Only a string `ValueKey` names a control: a GlobalKey,
  UniqueKey, ObjectKey or numeric key no longer becomes `btn.globalkey_<hash>`.
  Slugs keep meaningful symbols (`<180 days` -> `lt_180_days`, `>180 days`
  -> `gt_180_days`, `+` plus, `%` pct, a lone `-` minus).
* A switch or checkbox takes its name from a list tile's title
  (SwitchListTile, CheckboxListTile) or from one caption stacked directly
  above it, and the row title is now its primary handle
  (`btn.cupertinoswitch_2` -> `btn.enable_overall_remark`). A keyed switch
  keeps its key handle with the title as an alias.
* Every control carries `instance`, one number per mounted element, so a
  handle that moved to another control is a different target.
* A brief scene shows up to `maxItems / 10` scrollables (3 to 8; six in an
  agent scene, was always three). When a brief list is cut, `omitted` counts
  it (`scrollables` added) and adds `recoverWith: {method: 'inspect', params:
  {sections}}`, the query that reads exactly the cut lists. `inspect`
  `maxItems` accepts 1-500.
* The runtime tombstone filter for pruned mutation keys grows from 2^16 to
  2^20 bits, so long app runs no longer refuse fresh keys as
  `idempotency_outcome_pruned` filter collisions (about 1 in 25 after 10,000
  mutations before).
* Opt-in headless drive (`headlessDriveV1`): a request with
  `headlessDrive=true` keeps a hidden debug app rendering with Scout-driven
  frames (one per request plus at most 20 fps while app work is pending),
  reports `rendering.status: driven` with the reason, and holds an App Nap
  activity through `dart:ffi` while an agent is attached. Off by default;
  without the flag nothing changes.
* A swipe that moves nothing on screen now fails with `swipe_no_effect`
  (dispatched, `observation: no_effect`) instead of `ok` with
  `result: unchanged`, naming the widget it landed on. Scroll is unchanged.
* A control takes its label from its own text before text it merely covers:
  a floating "Add Payment" button over a "Cash" payment row was reported as
  `btn.cash`, so swipes meant for the row went to the button. Of two
  same-kind controls on one rect, the live one wins, so a `Slidable` row is
  the enabled drag detector instead of its callback-less auto-close wrapper
  (which made the row `target_disabled`).

* Let an exact-target agent action through a background state change between
  the CLI's preflight and dispatch when its target nodes, surface and field
  values are unchanged (`targetFreshnessV1`, optional `freshTargets`).
  `activeSurface.instance` identifies a mounted dialog or sheet while its
  guessed name follows typed text.

* Keep `FlutterScoutBinding.ensureInitialized()` safe as an application's main
  initializer in profile and release builds. It now always establishes the
  standard Flutter widget binding before the debug-only Scout registration,
  preventing pre-`runApp()` platform-channel calls from failing or leaving an
  app on its native launch screen.
* Report passive scheduler/lifecycle and completed framework-frame facts on
  inspect, distinguishing quiet active screens from suspended rendering without
  scheduling frames. Add optional `requireLiveRendering` mutation guard and
  advertise `renderingStateV1`/`liveRenderingGuardV1`; compositor pixels remain
  unobserved. Existing protocol-15 callers are unchanged.

* Give ordinary single-switch settings rows their title and a readable
  alias such as `btn.enable_overall_remark`, while preserving raw switch/key
  handles and selected/enabled state. Keep subtitles separate, support localized
  and RTL labels, retain aliases while scrolling, and abstain on competing
  labels or multiple controls.
* Keep desktop sibling panes usable when a nested navigator contains a sheet
  or dialog. Only viewport-owned surfaces restrict the global active surface;
  local barriers still block covered controls, and root dialogs retain their
  own title instead of borrowing a background pane's heading.
* Recognize ordinary non-Latin text and short localized control labels. Keep
  Unicode letters, numbers, and combining marks in discovered handles instead
  of collapsing them to empty slugs, and prefer a card's visible text over its
  leading icon. Existing ASCII handles are unchanged; re-inspect localized
  controls after upgrading. Symbol/icon filtering and duplicate abstention
  remain in effect.
* Scope every opt-in inspect section to the active modal surface when surface
  focus is explicit or automatic. Background scrollables, rows, control groups,
  visual-tree branches, overlays, semantic diagnostics, and offscreen text no
  longer leak into a modal-focused response.
* Restore the bottom-left session badge for Scout-owned launches so concurrent
  named agent windows remain distinguishable. The launch badge is passive,
  pointer-transparent, and absent from semantics until annotation or recording
  UI is explicitly enabled; attach-only apps remain unchanged.
* Bound runtime sensitive-value retention to 256 values/1 MiB and fail closed
  if that budget is exceeded. Reuse the sorted exact matcher and scan the
  widget tree at most once per protocol request, while error hooks can still
  force an immediate source scan before sanitizing diagnostics.
* Accept Dart VM service `isolateId` routing metadata at the strict request
  boundary, bound it independently, and exclude it from Scout mutation
  business fingerprints so real VM extension calls reach their handlers.
* Publish helper-visible stable structured-error meanings in the shared v1
  error catalog and include every one in deterministic CLI envelope goldens;
  source-emission drift is blocking, while no runtime or release-binary
  execution is implied by these contract fixtures.
* Publish per-extension typed argument contracts and enforce their exact keys,
  JSON shapes, bounds, conflicts, and mutation legality before any read handler
  or mutation dispatch.

* Identify this pre-1.0 compatibility-boundary candidate as `0.2.0-dev.1`;
  the prerelease marker does not imply release qualification.
* Identify the compiled helper package version in every typed runtime response
  so CLI operability diagnostics do not infer it from the source checkout.
* Publish bounded `delta.changedRegions` and snapshot-bound changed-region
  capture. Retained baseline/current identities, complete semantic/render
  geometry, DPR, backend, capture identity, and every count/area/pixel bound
  remain explicit; stale, ambiguous, global, oversized, platform-view, or
  capture-race cases fail closed without returning pixels. In-app rasterization
  now skips needless chrome frames when no Scout overlay exists and restores an
  opted-in overlay before the mandatory post-raster identity check.
* Bump the helper protocol to 15 with typed v1 response envelopes, negotiated
  protocol ranges, capabilities, runtime/run correlation, phase timing, and
  cursor-addressable runtime errors.
* Publish the aligned source-only `N`/`N-1`/`N+1` compatibility matrix and
  fixtures, and make every pre-handler mutation failure explicitly report
  `dispatch:not_dispatched` plus `activation.dispatched:false`. Separately
  built release artifacts and simulator runs remain required for ratification.
* Measure helper-owned action phases on one request-local exclusive monotonic
  timeline, keep application quiescence isolated in `settle`, close reads and
  failures with exact unavailable reasons, and retain all eight phase keys in
  bounded and emergency responses.
* Add monotonic state generations and SHA-256 identities over canonical,
  redacted agent-observable state. Full, brief, and action snapshots now carry
  the generation, digest, and combined snapshot identity.
* Require strict safety envelopes for every mutation, serialize all mutations,
  deduplicate concurrent and completed retries exactly once, reject stale or
  cross-runtime requests before dispatch, and give held drags exclusive
  mutation ownership.
* Canonicalize idempotency fingerprints over stable business identity (not
  retry deadlines, cursors, commands, or state preconditions), bound completed
  outcomes, and retain fail-safe tombstones so cache pressure can never turn a
  retry into a second dispatch.
* Source-redact obscured and sensitive field values across snapshots, deltas,
  recording, errors, visual/control structures, and debug responses while
  retaining only redacted presence metadata.
* Centralize handle resolution for all targeted mutations. Duplicate exact
  handles and fuzzy matches now abstain with ranked, snapshot-scoped evidence;
  dispatch requires the unique control to remain on the active surface,
  visible, enabled, and hit-tested at a safe point on a fresh snapshot.
* Report logical/physical coordinate frames, viewport, device pixel ratio, and
  immediate hit-test evidence for explicit-coordinate gesture actions.
* Include the locate snapshot's logical/physical Flutter-view coordinate frame,
  metrics provenance, and native-image matching contract so the CLI can fail
  closed instead of guessing system-bar or inset offsets for native crops.
* Add bounded semantic stability observations with closed stable, transient,
  continuous-animation, never-settling, runtime-loss, and unavailable states;
  action results retain the legacy `stable` flag plus actionable semantics,
  stopping reason, timing, samples, and generation-bound snapshot identities.
* Distinguish loss of an already observed app/root as `runtime_lost` from an
  initially unavailable observation, isolate malformed Semantics elements from
  healthy sibling evidence, and exercise capture-backend and opaque
  platform-view degradation through production paths without assigning pixel
  meaning.
* Label screen and targeting inferences explicitly, replace uncalibrated
  confidence/quality claims with named heuristic scores, and report immutable
  logical/physical view metrics, insets, keyboard evidence, orientation, and
  per-node physical geometry.
* Disclose observed CustomPaint, Texture, platform-view, image-pixel, and
  ErrorWidget perception gaps with scoped geometry, capture-backend coverage,
  pixel-evidence recommendations, and locally isolated degradation. Compact
  inspect output retains these limitations instead of implying full coverage.
* Report scroll regions as nested, uniquely scoped observations with logical
  and physical bounds, axis/direction, live Flutter ScrollPosition metrics,
  viewport/extents, derived normalized position, endpoint facts, and explicit
  availability/provenance in inspect and bounded-navigation responses.
* Persist helper-side recordings only when private storage can be guaranteed:
  source-placeholder all input/fill values, enforce owner-only permissions,
  reject unsafe paths and links, use atomic writes and a blocking index lock,
  bound recovery scans, and otherwise delegate the redacted flow to the CLI.
* Make observation non-interfering by construction: inspect, where, locate,
  snapshot-relative inspect, wait, drag-status, annotation reads, and recorder
  reads never schedule or manually advance frames. Only explicitly labelled
  post-mutation settling may advance disabled frames. Annotation/recording
  overlay chrome is absent at attach, installed only after explicit UI opt-in,
  and removed when both modes are inactive.
* Promote a currently visible Flutter `ErrorWidget` to a deduplicated active
  blocking signal with widget-tree provenance. The signal remains active until
  the surface disappears, while rendered diagnostic text is omitted and
  source-redacted from snapshots and protocol responses.
* Reject every unknown VM-service parameter before read or mutation dispatch
  against a published per-method allowlist. Enforce finite request count, name,
  identifier, total, and per-value byte limits plus the exact safe-ASCII
  idempotency-key contract before any handler or mutation cache. Bound every
  encoded helper response to 4 MiB and fail closed on oversized, deep, cyclic,
  or otherwise unsafe payloads while retaining compact identity, dispatch,
  cursor, truthful active-versus-blocking runtime health, hard-signal, and
  phase-timing evidence.
* Add bounded, seeded property campaigns for Unicode and duplicate selector
  abstention, ambiguity ranking, geometry isolation, canonical state identity,
  and protocol request/response limits, with exact seed/case replay documented
  in `FUZZING.md`.

## 0.0.1

* Initial helper package skeleton.
