# Scout Design System — "Recon HUD"

The visual language for Flutter Scout's in-app annotation overlay. It is
**deliberately not Material**: Scout floats on top of an arbitrary running app,
so its chrome must (a) read on any background, light or dark, and (b) look
unmistakably like *tooling*, not part of the app under test.

The metaphor is a **heads-up display / reconnaissance scanner**:

- **Dark translucent "glass" surfaces** — near-opaque deep teal-black panels that
  sit over any host app.
- **Luminous hairline borders + soft outer glow** instead of Material drop
  shadows and ripples.
- **A single signal-cyan accent**, with **amber** for review states and **rose**
  for danger/stale.
- **Tracked uppercase micro-labels** and **monospace numerals** (the technical,
  instrument feel).
- **Corner reticle ticks** on panels and the selected target (the HUD signature).
- **Confident, snappy motion** with a slight overshoot "pop".

## Where it lives

- Tokens + primitives: `packages/flutter_scout_helper/lib/src/scout_design.dart`
  (a `part of flutter_scout_binding.dart`).
- Consumers: `annotation_overlay.dart` (toggle pill, send-to-agent button,
  comment panel, pin popup, pin reticles, the field painter).

## Tokens (single source of truth)

| Group | Token | Notes |
|---|---|---|
| Color | `ScoutColors.glass` / `glassRaised` | panel fill / inset well fill (≈95% opaque) |
| | `ScoutColors.border` | cyan hairline at low alpha |
| | `ScoutColors.ink` / `inkDim` | primary / secondary text |
| | `ScoutColors.signal` (+`signalGlow`, `onSignal`) | primary accent — open/active/focus |
| | `ScoutColors.amber` | `pending_review` |
| | `ScoutColors.rose` | danger / `stale_target` |
| | `ScoutColors.scrim` | capture scrim — intentionally barely-there |
| | `ScoutColors.forStatus(status)` | maps annotation status → accent |
| Space | `ScoutSpace.xs/s/m/l/xl` | 4 / 8 / 12 / 16 / 24 |
| Radius | `ScoutRadius.panel/control/pill` | 14 / 10 / 999 |
| Type | `ScoutType.label/title/body/meta/numeral` | label & numeral are the HUD voice |
| Motion | `ScoutMotion.fast/base/slow` | 130 / 220 / 340 ms |
| | `ScoutMotion.enter/exit/pop` | easeOutCubic / easeInCubic / easeOutBack |

## Primitives

- **`ScoutPanel`** — glass surface: fill + hairline border + glow + corner ticks.
  Optional `accent` to tint the glow/edge per status. Base for the comment panel
  and pin popup.
- **`ScoutButton`** (`ScoutButtonKind.primary | ghost | danger`) — tracked
  uppercase label, optional icon, **press-scale** (no Material ripple).
- **`ScoutPill`** — draggable stadium control (the annotation toggle /
  send-to-agent), with icon, optional numeral `count`, and an `active` state.
- **`ScoutField`** — HUD text input (raised glass well, no underline). Needs a
  `Material` ancestor (wrap call sites in `Material(type: transparency)`).
- **`scoutGlass(...)`** — the `BoxDecoration` helper if you need the surface
  without the panel's corner ticks.

## Motion

- **Pins** appear with a `pop` scale+fade (easeOutBack) and exit via a short
  reverse (a "ghost" kept mounted until the exit completes — see `_ScoutPin` and
  `_exitingPins` in `annotation_overlay.dart`).
- **Comment panel** slides up + fades in; **pin popup** scales up from its anchor.
- **Send-to-agent** cross-fades between its send / sent states.

## Rules for future changes

1. **Never** use raw Material widgets (`FilledButton`, `Card`, `Material` color,
   `Theme.of(context)`) for Scout chrome. Build from the primitives + tokens.
2. Tokens are **fixed**, not theme-derived — Scout must look identical over a
   light app, a dark app, or no app.
3. Annotation status → color goes through `ScoutColors.forStatus`.
4. New chrome that can appear over a captured region must respect the
   capture-clear mechanism (see "Captures stay clean" in ARCHITECTURE.md): the
   painter clips `clearRects`; pin widgets dim themselves inside a clear rect.
5. Keep motion within the `ScoutMotion` tokens so the feel stays coherent.
