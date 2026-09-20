# Registered custom editable surfaces

Scout normally requires an explicit field target to be directly hit-testable before text input. A custom editor that deliberately hides its `EditableText` behind its own visual interaction surface can opt in to the versioned debug-only contract below:

```dart
ScoutExplicitEditableSurface(
  policyVersion: ScoutExplicitEditableSurface.currentPolicyVersion,
  controller: pinController,
  focusNode: pinFocusNode,
  child: PinCodeTextField(
    controller: pinController,
    focusNode: pinFocusNode,
    // ...
  ),
)
```

The contract is generic; it does not identify packages, screens, labels, or application classes. `policyVersion: 1` authorizes explicit `input --target ...` only when Scout freshly proves all of the following immediately before dispatch:

- the selector resolves to exactly one live, visible, enabled field on the active surface;
- the field still owns focus;
- the wrapper's exact render boundary is attached and contains exactly one live `EditableText`;
- the `EditableText` uses the identical registered `TextEditingController` and `FocusNode` objects;
- the current top hit path passes through that exact render boundary; and
- the logical field identity, registration object, and registration generation did not change during revalidation.

Unregistered custom editors and registrations with an unsupported policy version, zero or multiple editable descendants, or mismatched controller/focus identity fail closed. Ordinary directly hit-testable `TextField` behavior is unchanged.

## Trust boundary

Wrap only the custom control. Keep loading shields, modal barriers, and unrelated gesture or overlay siblings **outside** `ScoutExplicitEditableSurface`. An outer or same-owner sibling intercepts the hit path before it reaches the marker and Scout rejects input.

Anything deliberately placed inside the marker is declared to be part of that control. Scout cannot infer developer intent inside an explicitly authorized boundary. Over-broad wrapping therefore weakens the contract and is unsupported.

The marker exists only in debug builds; profile and release builds return `child` directly. Helper responses advertise `registeredCustomEditableSurfaceV1: true` when this policy is available. Successful resolution evidence reports `authorizationKind: registered_custom_editable_surface`, policy version, controller/focus identity matches, marker-path membership, registration generation, and immediate revalidation.
