# Flutter Scout Helper

Flutter helper package for Flutter Scout.

Add one initializer in `main()`:

```dart
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

The helper registers VM service extensions that let the Flutter Scout CLI
inspect and operate a running debug app:

- compact screen inspection
- tap, long press, input, fill, scroll, swipe, and back
- wait-until-stable
- hard runtime signal capture from Flutter/platform error hooks
- target metadata for screenshots and crops
- bounded snapshot-relative changed regions and identity-verified in-app crop
  capture for `crop --changed-since`
- debug annotation overlay for selecting visible widgets and attaching user comments
- stable labels for keyed, text, tooltip, common icon-only controls, and common Material glyph text controls
- `tap-text` fallback to a visible text point when no actionable ancestor is exposed

No per-screen wrappers or per-widget action annotations are required.

Read-only commands are passive: they sample the current Flutter state without
scheduling, pumping, or fabricating frames, dispatching pointers, requesting
focus, changing routes, or installing overlay chrome. Post-action settling is
a separate, explicitly reported phase and may advance disabled frames after a
mutation has already been dispatched.

Stability observations distinguish a root that was unavailable before any
sample (`observation_unavailable`) from an app/root that disappears after a
trustworthy sample (`runtime_lost`). Widget and semantics failures are isolated
to the affected element, and capture-backend or opaque platform-view failures
remain explicit pixel-evidence limitations; they do not erase the remaining
trustworthy widget snapshot or imply knowledge of native pixels.

Changed-region capture derives complete regions from two retained, detached
snapshot identities and semantic/render geometry. It bounds their union before
rasterization and observes the snapshot again afterward; changed state discards
the bytes. The response exposes logical/physical geometry, DPR, backend,
identity, provenance, and every enforced limit. Pixel-only custom-paint changes
are not inferred, and platform-view/native fallback remains a typed limitation
because it cannot be atomically bound to the helper snapshot.

All service-extension calls use the typed protocol-15 envelope. The helper
rejects unknown parameters before invoking either a read or mutation handler;
the exact machine-readable allowlist is published in
[`helper-methods.json`](../../protocol/schemas/v1/helper-methods.json).
That catalog also publishes the pre-handler request byte/count limits and the
exact 1-128-character safe-ASCII idempotency-key contract.
Encoded responses are capped at 4 MiB. An oversized or structurally unsafe
result is replaced by a bounded
typed failure that keeps identity, dispatch uncertainty, hard-signal cursors,
runtime health, and phase availability without emitting a partial result.

The overlay is not installed at attach. `annotations enable` is the explicit
annotation-UI opt-in; starting a recording explicitly enables its HUD.
`annotations disable` and recording stop remove the overlay as soon as both
modes are inactive.
