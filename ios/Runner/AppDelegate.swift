import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var deeplinkEventSink: FlutterEventSink?
  private var pendingDeepLink: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    if let controller = window?.rootViewController as? FlutterViewController {
      // Register ExecuTorch LLM channel for on-device inference
      ExecuTorchLLMChannel.shared.register(with: controller.binaryMessenger)

      // Register deep link EventChannel (mirrors Android's deeplink_events channel)
      let deeplinkChannel = FlutterEventChannel(
        name: "com.example.anchor/deeplink_events",
        binaryMessenger: controller.binaryMessenger
      )
      deeplinkChannel.setStreamHandler(self)
    }

    // Check if app was launched via a deep link
    if let url = launchOptions?[.url] as? URL {
      pendingDeepLink = url.absoluteString
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Handle deep links when app is already running (or in background)
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    let urlString = url.absoluteString
    NSLog("AppDelegate: Received deep link: \(urlString)")

    if let sink = deeplinkEventSink {
      sink(urlString)
    } else {
      // Store it so we can send it once Flutter's listener attaches
      pendingDeepLink = urlString
    }

    // Still call super so other plugins (e.g. Reown) can handle it too
    return super.application(app, open: url, options: options)
  }

  // Handle universal links
  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      let urlString = url.absoluteString
      NSLog("AppDelegate: Received universal link: \(urlString)")

      if let sink = deeplinkEventSink {
        sink(urlString)
      } else {
        pendingDeepLink = urlString
      }
    }
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }
}

// MARK: - FlutterStreamHandler for deep link events
extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    deeplinkEventSink = events
    NSLog("AppDelegate: Deep link listener attached")

    // Flush any link that arrived before Flutter was ready
    if let pending = pendingDeepLink {
      NSLog("AppDelegate: Sending pending deep link: \(pending)")
      events(pending)
      pendingDeepLink = nil
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    deeplinkEventSink = nil
    NSLog("AppDelegate: Deep link listener cancelled")
    return nil
  }
}
