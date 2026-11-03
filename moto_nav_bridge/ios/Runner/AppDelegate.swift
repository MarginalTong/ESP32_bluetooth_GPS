import Flutter
import UIKit

/// App start-up: registers the platform channels and the native map view.
/// Each feature lives in its own file (NavigationSpeech, AppleMapsChannel,
/// NavigationMapPlatformView, DisplayBindingKeychain).
@main
@objc class AppDelegate: FlutterAppDelegate {
  private let speech = NavigationSpeech()
  private let appleMaps = AppleMapsChannel()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "NavioAuthConfiguration") {
      let authConfiguration = FlutterMethodChannel(
        name: "moto_nav_bridge/auth_configuration", binaryMessenger: registrar.messenger())
      authConfiguration.setMethodCallHandler { call, result in
        guard call.method == "hasUrlScheme", let requested = call.arguments as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        result(types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(requested) })
      }
    }

    if let registrar = self.registrar(forPlugin: "NavigationMapView") {
      registrar.register(
        NavigationMapViewFactory(messenger: registrar.messenger()),
        withId: "moto_nav_bridge/navigation_map"
      )
    }

    if let controller = window?.rootViewController as? FlutterViewController {
      speech.attach(to: controller.binaryMessenger)
      let mapsChannel = FlutterMethodChannel(
        name: "moto_nav_bridge/apple_maps",
        binaryMessenger: controller.binaryMessenger
      )
      mapsChannel.setMethodCallHandler { [weak self] call, result in
        self?.appleMaps.handle(call, result: result)
      }
      let bindingChannel = FlutterMethodChannel(
        name: "moto_nav_bridge/display_binding",
        binaryMessenger: controller.binaryMessenger
      )
      bindingChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "load": result(DisplayBindingKeychain.load())
        case "save": result(DisplayBindingKeychain.save(call.arguments as? String))
        case "clear": result(DisplayBindingKeychain.clear())
        default: result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
