import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Register ExecuTorch LLM channel for on-device inference
    if let controller = window?.rootViewController as? FlutterViewController {
      ExecuTorchLLMChannel.shared.register(with: controller.binaryMessenger)
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
