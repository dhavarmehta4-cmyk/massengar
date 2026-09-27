import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var blurOverlay: UIVisualEffectView?
  private var isSecureModeEnabled = false
  private var isAppSwitcherBlurred = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      setupMethodChannel(messenger: controller.binaryMessenger)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupMethodChannel(messenger: engineBridge.binaryMessenger)
  }

  private func setupMethodChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "massengar/screen_security", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }
      switch call.method {
      case "enableSecureScreen", "enableSecureMode":
        self.isSecureModeEnabled = true
        result(true)
      case "disableSecureScreen", "disableSecureMode":
        self.isSecureModeEnabled = false
        self.removeBlurOverlay()
        result(true)
      case "setAppSwitcherBlurred":
        if let args = call.arguments as? [String: Any], let blurred = args["blurred"] as? Bool {
          self.isAppSwitcherBlurred = blurred
        } else {
          self.isAppSwitcherBlurred = true
        }
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    if isSecureModeEnabled || isAppSwitcherBlurred {
      showBlurOverlay()
    }
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    removeBlurOverlay()
  }

  private func showBlurOverlay() {
    guard blurOverlay == nil, let window = self.window else { return }
    let blurEffect = UIBlurEffect(style: .dark)
    let blurView = UIVisualEffectView(effect: blurEffect)
    blurView.frame = window.bounds
    blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blurView.tag = 99999
    window.addSubview(blurView)
    self.blurOverlay = blurView
  }

  private func removeBlurOverlay() {
    blurOverlay?.removeFromSuperview()
    blurOverlay = nil
  }
}
