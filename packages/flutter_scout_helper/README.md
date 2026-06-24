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
inspect and operate a running debug/profile app:

- compact screen inspection
- tap, long press, input, fill, scroll, swipe, and back
- wait-until-stable
- hard runtime signal capture from Flutter/platform error hooks
- target metadata for screenshots and crops
- stable labels for keyed, text, tooltip, and common icon-only controls

No per-screen wrappers or per-widget action annotations are required.
