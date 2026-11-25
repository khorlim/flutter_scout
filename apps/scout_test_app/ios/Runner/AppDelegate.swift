import AVFoundation
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Runtime permission prompts for lib/system_dialogs_main.dart.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ScoutTestPermissions") {
      let channel = FlutterMethodChannel(
        name: "scout_test_app/permissions", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        let kind = call.arguments as? String ?? ""
        let reply: (String) -> Void = { value in DispatchQueue.main.async { result(value) } }
        switch call.method {
        case "status": ScoutTestPermissions.status(kind, reply)
        case "request": ScoutTestPermissions.request(kind, reply)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}

enum ScoutTestPermissions {
  static func media(_ kind: String) -> AVMediaType? {
    switch kind {
    case "camera": return .video
    case "microphone": return .audio
    default: return nil
    }
  }

  static func name(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
  }

  static func name(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized, .provisional, .ephemeral: return "granted"
    case .denied: return "denied"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
  }

  static func status(_ kind: String, _ reply: @escaping (String) -> Void) {
    if let type = media(kind) {
      reply(name(AVCaptureDevice.authorizationStatus(for: type)))
    } else if kind == "notifications" {
      UNUserNotificationCenter.current().getNotificationSettings { reply(name($0.authorizationStatus)) }
    } else {
      reply("unsupported")
    }
  }

  static func request(_ kind: String, _ reply: @escaping (String) -> Void) {
    if let type = media(kind) {
      AVCaptureDevice.requestAccess(for: type) { granted in reply(granted ? "granted" : "denied") }
    } else if kind == "notifications" {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
        granted, _ in reply(granted ? "granted" : "denied")
      }
    } else {
      reply("unsupported")
    }
  }
}
