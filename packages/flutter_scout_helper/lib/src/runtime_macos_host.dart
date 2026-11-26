part of 'flutter_scout_binding.dart';

// part: what macOS itself says about whether anyone can see this app.
// Flutter's lifecycle alone is not enough: an app launched behind the lock
// screen never goes `hidden`, and a display that sleeps often leaves the
// window `resumed` with vsync stopped. These facts are read in-process with
// `dart:ffi` (no plugin code) and combined with the lifecycle by
// `_appOnScreen`, so Scout never reports a window as on screen when macOS
// says it is not.

/// Facts macOS reports about the app's visibility. A null fact could not be
/// read; it never hides the app by itself.
@visibleForTesting
class ScoutMacosHostFacts {
  const ScoutMacosHostFacts({
    this.displayAsleep,
    this.sessionLockFlag,
    this.onConsole,
    this.loginWindowFrontmost,
    this.windowVisible,
  });

  /// Every online display is asleep (`CGDisplayIsAsleep`).
  final bool? displayAsleep;

  /// `CGSSessionScreenIsLocked`. macOS sets it the moment the display
  /// sleeps, also inside the password grace period, so alone it does not
  /// prove the lock is in force.
  final bool? sessionLockFlag;

  /// `kCGSSessionOnConsoleKey`: false after fast user switching away.
  final bool? onConsole;

  /// `com.apple.loginwindow` is the frontmost app: the lock or login screen
  /// is up.
  final bool? loginWindowFrontmost;

  /// `NSApplicationOcclusionStateVisible`: some part of an app window is
  /// visible.
  final bool? windowVisible;

  /// True only when the lock is really in force: the display is awake and
  /// the login window is in front. False when macOS reports no lock. Null
  /// when the flag is set but nothing proves the password is required yet
  /// (the display is asleep, or the login window is not in front).
  bool? get screenLocked {
    if (displayAsleep != true && loginWindowFrontmost == true) return true;
    return sessionLockFlag == false ? false : null;
  }

  /// Why macOS hides the app, most specific first; null when no fact says
  /// so.
  String? get hiddenReason {
    if (displayAsleep == true) return 'display_asleep';
    if (screenLocked == true) return 'screen_locked';
    if (onConsole == false) return 'session_inactive';
    if (windowVisible == false) return 'window_occluded';
    return null;
  }

  Map<String, Object?> toJson() {
    final reason = hiddenReason;
    return {
      'platform': 'macos',
      'hidden': reason != null,
      'hiddenReason': ?reason,
      'displayAsleep': displayAsleep,
      'screenLocked': screenLocked,
      'sessionLockFlag': sessionLockFlag,
      'loginWindowFrontmost': loginWindowFrontmost,
      'onConsole': onConsole,
      'windowVisible': windowVisible,
      if (sessionLockFlag == true && screenLocked == null)
        'screenLockNote':
            'macOS sets its session lock flag as soon as the display sleeps, '
            'also inside the password grace period, so whether the lock is '
            'in force is unknown until the login window shows.',
    };
  }
}

/// One cached read of the host facts, at most once a second.
class _MacosHostFactsCache {
  int? atMs;
  ScoutMacosHostFacts? facts;
}

extension _RuntimeMacosHost on FlutterScoutRuntime {
  /// macOS visibility facts, or null off macOS (and under `flutter test`
  /// unless injected).
  ScoutMacosHostFacts? _hostFacts() {
    final injected = debugMacosHostFacts;
    if (injected != null) return injected;
    final host = _MacosHost.instance;
    if (host == null) return null;
    final now = _renderingClock.elapsedMilliseconds;
    final cache = _hostFactsCache;
    final at = cache.atMs;
    if (at != null && now - at < 1000) return cache.facts;
    cache
      ..atMs = now
      ..facts = host.visibilityFacts();
    return cache.facts;
  }

  /// Flutter renders frames and no macOS fact hides the window. This, not
  /// `framesEnabled` alone, decides `rendering.status: active`.
  bool get _appOnScreen =>
      WidgetsBinding.instance.framesEnabled &&
      _hostFacts()?.hiddenReason == null;
}

typedef _IdFromCString = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>);
typedef _MsgSendId =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendUint64Native =
    ffi.Uint64 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _MsgSendInt =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _MsgSendCString =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendBeginNative =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Uint64,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendBegin =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      int,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendVoidIdNative =
    ffi.Void Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendVoidId =
    void Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _CopyDictionary = ffi.Pointer<ffi.Void> Function();
typedef _GetValue =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _TypeIdOfNative = ffi.UintPtr Function(ffi.Pointer<ffi.Void>);
typedef _TypeIdOf = int Function(ffi.Pointer<ffi.Void>);
typedef _TypeIdNative = ffi.UintPtr Function();
typedef _TypeId = int Function();
typedef _BoolOfNative = ffi.Uint8 Function(ffi.Pointer<ffi.Void>);
typedef _BoolOf = int Function(ffi.Pointer<ffi.Void>);
typedef _ReleaseNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _Release = void Function(ffi.Pointer<ffi.Void>);
typedef _OnlineDisplaysNative =
    ffi.Int32 Function(
      ffi.Uint32,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Uint32>,
    );
typedef _OnlineDisplays =
    int Function(int, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>);
typedef _DisplayAsleepNative = ffi.Int32 Function(ffi.Uint32);
typedef _DisplayAsleep = int Function(int);
typedef _PoolPush = ffi.Pointer<ffi.Void> Function();
typedef _PoolPopNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _PoolPop = void Function(ffi.Pointer<ffi.Void>);
typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.IntPtr);
typedef _Malloc = ffi.Pointer<ffi.Uint8> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _Free = void Function(ffi.Pointer<ffi.Uint8>);
typedef _MsgSendIdOne = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);

/// The few macOS calls Scout needs, through the Objective-C runtime,
/// Foundation, AppKit and CoreGraphics with `dart:ffi`, so the helper stays
/// a pure Dart package with no plugin code. Null off macOS, under
/// `flutter test`, or when a symbol is missing; every call is best effort.
/// Flutter's macOS embedder runs Dart on the platform (main) thread, so the
/// AppKit reads are made where AppKit expects them.
class _MacosHost {
  _MacosHost._(ffi.DynamicLibrary lib)
    : _malloc = lib.lookupFunction<_MallocNative, _Malloc>('malloc'),
      _free = lib.lookupFunction<_FreeNative, _Free>('free'),
      _getClass = lib.lookupFunction<_IdFromCString, _IdFromCString>(
        'objc_getClass',
      ),
      _selector = lib.lookupFunction<_IdFromCString, _IdFromCString>(
        'sel_registerName',
      ),
      _sendId = lib.lookupFunction<_MsgSendId, _MsgSendId>('objc_msgSend'),
      _sendUint64 = lib.lookupFunction<_MsgSendUint64Native, _MsgSendInt>(
        'objc_msgSend',
      ),
      _sendCString = lib.lookupFunction<_MsgSendCString, _MsgSendCString>(
        'objc_msgSend',
      ),
      _sendBegin = lib.lookupFunction<_MsgSendBeginNative, _MsgSendBegin>(
        'objc_msgSend',
      ),
      _sendVoidId = lib.lookupFunction<_MsgSendVoidIdNative, _MsgSendVoidId>(
        'objc_msgSend',
      ),
      _stringFromSelector = lib.lookupFunction<_MsgSendIdOne, _MsgSendIdOne>(
        'NSStringFromSelector',
      ),
      _poolPush = lib.lookupFunction<_PoolPush, _PoolPush>(
        'objc_autoreleasePoolPush',
      ),
      _poolPop = lib.lookupFunction<_PoolPopNative, _PoolPop>(
        'objc_autoreleasePoolPop',
      ),
      _copySession = lib.lookupFunction<_CopyDictionary, _CopyDictionary>(
        'CGSessionCopyCurrentDictionary',
      ),
      _getValue = lib.lookupFunction<_GetValue, _GetValue>(
        'CFDictionaryGetValue',
      ),
      _typeIdOf = lib.lookupFunction<_TypeIdOfNative, _TypeIdOf>('CFGetTypeID'),
      _booleanTypeId = lib.lookupFunction<_TypeIdNative, _TypeId>(
        'CFBooleanGetTypeID',
      ),
      _booleanValue = lib.lookupFunction<_BoolOfNative, _BoolOf>(
        'CFBooleanGetValue',
      ),
      _release = lib.lookupFunction<_ReleaseNative, _Release>('CFRelease'),
      _onlineDisplays = lib
          .lookupFunction<_OnlineDisplaysNative, _OnlineDisplays>(
            'CGGetOnlineDisplayList',
          ),
      _displayAsleep = lib.lookupFunction<_DisplayAsleepNative, _DisplayAsleep>(
        'CGDisplayIsAsleep',
      );

  static _MacosHost? _instance;
  static bool _unavailable = false;

  static _MacosHost? get instance {
    if (_unavailable) return null;
    if (_instance != null) return _instance;
    try {
      if (!Platform.isMacOS ||
          Platform.environment.containsKey('FLUTTER_TEST')) {
        _unavailable = true;
        return null;
      }
      // The frameworks are already loaded in a macOS Flutter app; opening
      // them only makes the lookups independent of the embedder's links.
      for (final framework in const ['Foundation', 'AppKit', 'CoreGraphics']) {
        ffi.DynamicLibrary.open(
          '/System/Library/Frameworks/$framework.framework/$framework',
        );
      }
      return _instance = _MacosHost._(ffi.DynamicLibrary.process());
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  final _Malloc _malloc;
  final _Free _free;
  final _IdFromCString _getClass;
  final _IdFromCString _selector;
  final _MsgSendId _sendId;
  final _MsgSendInt _sendUint64;
  final _MsgSendCString _sendCString;
  final _MsgSendBegin _sendBegin;
  final _MsgSendVoidId _sendVoidId;
  final _MsgSendIdOne _stringFromSelector;
  final _PoolPush _poolPush;
  final _PoolPop _poolPop;
  final _CopyDictionary _copySession;
  final _GetValue _getValue;
  final _TypeIdOf _typeIdOf;
  final _TypeId _booleanTypeId;
  final _BoolOf _booleanValue;
  final _Release _release;
  final _OnlineDisplays _onlineDisplays;
  final _DisplayAsleep _displayAsleep;
  final Map<String, ffi.Pointer<ffi.Void>> _selectors = {};
  final Map<String, ffi.Pointer<ffi.Void>> _classes = {};

  ffi.Pointer<ffi.Void> _withCString(
    String value,
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>) use,
  ) {
    final bytes = utf8.encode(value);
    final pointer = _malloc(bytes.length + 1);
    try {
      pointer.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return use(pointer);
    } finally {
      _free(pointer);
    }
  }

  ffi.Pointer<ffi.Void> _sel(String name) =>
      _selectors[name] ??= _withCString(name, _selector);

  ffi.Pointer<ffi.Void> _class(String name) =>
      _classes[name] ??= _withCString(name, _getClass);

  /// An NSString, also usable as a CFString, from a selector name. Selector
  /// names are interned by the runtime, so the string is never freed.
  ffi.Pointer<ffi.Void> _string(String value) =>
      _stringFromSelector(_sel(value));

  /// `[[NSProcessInfo processInfo] beginActivityWithOptions:reason:]` with
  /// NSActivityUserInitiatedAllowingIdleSystemSleep, retained because the
  /// returned object is autoreleased and the activity ends when it is freed.
  ffi.Pointer<ffi.Void>? beginActivity(String reason) {
    try {
      final processInfo = _sendId(_class('NSProcessInfo'), _sel('processInfo'));
      if (processInfo == ffi.nullptr) return null;
      const userInitiatedAllowingIdleSystemSleep = 0x00FFFFFF & ~(1 << 20);
      final activity = _sendBegin(
        processInfo,
        _sel('beginActivityWithOptions:reason:'),
        userInitiatedAllowingIdleSystemSleep,
        _string(reason),
      );
      if (activity == ffi.nullptr) return null;
      return _sendId(activity, _sel('retain'));
    } catch (_) {
      return null;
    }
  }

  void endActivity(ffi.Pointer<ffi.Void> activity) {
    try {
      final processInfo = _sendId(_class('NSProcessInfo'), _sel('processInfo'));
      _sendVoidId(processInfo, _sel('endActivity:'), activity);
      _sendId(activity, _sel('release'));
    } catch (_) {}
  }

  /// All visibility facts in one autorelease scope.
  ScoutMacosHostFacts visibilityFacts() {
    final pool = _poolPush();
    try {
      final session = _sessionFlags();
      return ScoutMacosHostFacts(
        displayAsleep: _allDisplaysAsleep(),
        sessionLockFlag: session.locked,
        onConsole: session.onConsole,
        loginWindowFrontmost: _loginWindowFrontmost(),
        windowVisible: _appWindowVisible(),
      );
    } finally {
      _poolPop(pool);
    }
  }

  /// `CGSSessionScreenIsLocked` and `kCGSSessionOnConsoleKey` from the
  /// current login session's dictionary.
  ({bool? locked, bool? onConsole}) _sessionFlags() {
    try {
      final session = _copySession();
      if (session == ffi.nullptr) return (locked: null, onConsole: null);
      try {
        bool? flag(String key, {required bool absent}) {
          final value = _getValue(session, _string(key));
          if (value == ffi.nullptr) return absent;
          if (_typeIdOf(value) != _booleanTypeId()) return null;
          return _booleanValue(value) != 0;
        }

        return (
          // macOS removes the key when the session is not locked.
          locked: flag('CGSSessionScreenIsLocked', absent: false),
          onConsole: flag('kCGSSessionOnConsoleKey', absent: true),
        );
      } finally {
        _release(session);
      }
    } catch (_) {
      return (locked: null, onConsole: null);
    }
  }

  /// True only when every online display sleeps: the window may be on any
  /// of them, and displays normally sleep together.
  bool? _allDisplaysAsleep() {
    const maximum = 16;
    final buffer = _malloc(4 * (maximum + 1));
    try {
      final ids = buffer.cast<ffi.Uint32>();
      final count = (buffer + 4 * maximum).cast<ffi.Uint32>();
      if (_onlineDisplays(maximum, ids, count) != 0) return null;
      final n = count.value;
      if (n == 0) return null;
      for (var i = 0; i < n; i++) {
        if (_displayAsleep((ids + i).value) == 0) return false;
      }
      return true;
    } catch (_) {
      return null;
    } finally {
      _free(buffer);
    }
  }

  bool? _loginWindowFrontmost() {
    try {
      final workspace = _sendId(_class('NSWorkspace'), _sel('sharedWorkspace'));
      if (workspace == ffi.nullptr) return null;
      final app = _sendId(workspace, _sel('frontmostApplication'));
      // No frontmost app at all is not the login window.
      if (app == ffi.nullptr) return false;
      final bundle = _sendId(app, _sel('bundleIdentifier'));
      if (bundle == ffi.nullptr) return false;
      final chars = _sendCString(bundle, _sel('UTF8String'));
      if (chars == ffi.nullptr) return null;
      var length = 0;
      while (length < 256 && (chars + length).value != 0) {
        length++;
      }
      return utf8.decode(chars.asTypedList(length), allowMalformed: true) ==
          'com.apple.loginwindow';
    } catch (_) {
      return null;
    }
  }

  /// `[NSApp occlusionState] & NSApplicationOcclusionStateVisible`, the
  /// fact Flutter's own lifecycle is derived from, read now rather than
  /// from the last notification.
  bool? _appWindowVisible() {
    try {
      final app = _sendId(_class('NSApplication'), _sel('sharedApplication'));
      if (app == ffi.nullptr) return null;
      const visible = 1 << 1;
      return _sendUint64(app, _sel('occlusionState')) & visible != 0;
    } catch (_) {
      return null;
    }
  }
}
