import Flutter
import MapKit
import UIKit
import AVFoundation
import Security
import UIKit.UIGestureRecognizerSubclass

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {
  private var navigationUtterance: AVSpeechUtterance?
  /// Tells Dart when a navigation announcement starts and ends, so it can
  /// defer non-urgent guidance instead of cutting the current one off.
  private var speechEvent: ((String) -> Void)?
  private func endNavigationSpeech() {
    guard navigationUtterance != nil else { return }
    navigationUtterance = nil
    speechEvent?("navigationSpeechEnded")
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    if utterance === navigationUtterance { endNavigationSpeech() }
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    if utterance === navigationUtterance { endNavigationSpeech() }
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    if utterance === navigationUtterance { speechEvent?("navigationSpeechStarted") }
  }
  private var activeSearchCompleters: [SearchCompleter] = []
  private let navigationSpeech = AVSpeechSynthesizer()

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
      navigationSpeech.usesApplicationAudioSession = false
      navigationSpeech.delegate = self
      let voiceChannel = FlutterMethodChannel(
        name: "moto_nav_bridge/voice", binaryMessenger: controller.binaryMessenger)
      speechEvent = { state in voiceChannel.invokeMethod("speechState", arguments: state) }
      voiceChannel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { result(nil); return }
        if call.method == "stop" {
          self.endNavigationSpeech()
          self.navigationSpeech.stopSpeaking(at: .immediate)
          result(nil)
        } else if call.method == "speak",
                  let args = call.arguments as? [String: String],
                  let text = args["text"], let language = args["language"],
                  let voice = AVSpeechSynthesisVoice(language: language) {
          // A newer announcement always replaces the one playing.
          self.endNavigationSpeech()
          self.navigationSpeech.stopSpeaking(at: .immediate)
          let utterance = AVSpeechUtterance(string: text)
          utterance.voice = voice
          self.navigationUtterance = utterance
          self.navigationSpeech.speak(utterance)
          result(nil)
        } else {
          result(FlutterError(code: "VOICE_UNAVAILABLE", message: nil, details: nil))
        }
      }
      let channel = FlutterMethodChannel(
        name: "moto_nav_bridge/apple_maps",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleMapsCall(call, result: result)
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

  private func handleMapsCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "BAD_ARGS", message: "Missing arguments", details: nil))
      return
    }
    switch call.method {
    case "completePlaces":
      completePlaces(args, result: result)
    case "searchPlaces":
      searchPlaces(args, result: result)
    case "drivingRoute":
      drivingRoute(args, result: result)
    case "drivingRoutes":
      drivingRoutes(args, result: result)
    case "loadSearchHistory":
      loadSearchHistory(result: result)
    case "saveSearchHistory":
      saveSearchHistory(args, result: result)
    case "clearSearchHistory":
      clearSearchHistory(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var searchHistoryKey: String { "moto_nav_bridge.search_history" }

  private func usesEnglish(_ args: [String: Any]) -> Bool {
    if let languageCode = args["languageCode"] as? String {
      return languageCode.lowercased().hasPrefix("en")
    }
    return Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true
  }

  private func noDrivingRouteMessage(_ args: [String: Any]) -> String {
    usesEnglish(args) ? "No drivable route found" : "没有找到可驾驶路线"
  }

  private func unnamedPlaceName(_ args: [String: Any]) -> String {
    usesEnglish(args) ? "Unnamed place" : "未命名地点"
  }

  private func defaultRouteName(index: Int, args: [String: Any]) -> String {
    if usesEnglish(args) {
      return index == 0 ? "Recommended route" : "Route \(index + 1)"
    }
    return index == 0 ? "推荐路线" : "路线 \(index + 1)"
  }

  private func loadSearchHistory(result: @escaping FlutterResult) {
    result(UserDefaults.standard.array(forKey: searchHistoryKey) as? [[String: Any]] ?? [])
  }

  private func saveSearchHistory(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let place = args["place"] as? [String: Any] else {
      result(FlutterError(code: "BAD_ARGS", message: "Missing place", details: nil))
      return
    }

    let limit = args["limit"] as? Int ?? 10
    let name = place["name"] as? String ?? ""
    let address = place["address"] as? String ?? ""
    let latitude = place["latitude"] as? Double ?? 0
    let longitude = place["longitude"] as? Double ?? 0

    var history = UserDefaults.standard.array(forKey: searchHistoryKey) as? [[String: Any]] ?? []
    history.removeAll { item in
      let sameText = (item["name"] as? String ?? "") == name
        && (item["address"] as? String ?? "") == address
      let sameCoordinate = abs((item["latitude"] as? Double ?? 0) - latitude) < 0.000001
        && abs((item["longitude"] as? Double ?? 0) - longitude) < 0.000001
      return sameText || sameCoordinate
    }

    history.insert([
      "name": name,
      "address": address,
      "latitude": latitude,
      "longitude": longitude,
    ], at: 0)

    if history.count > limit {
      history = Array(history.prefix(limit))
    }

    UserDefaults.standard.set(history, forKey: searchHistoryKey)
    result(nil)
  }

  private func clearSearchHistory(result: @escaping FlutterResult) {
    UserDefaults.standard.removeObject(forKey: searchHistoryKey)
    result(nil)
  }

  private func completePlaces(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let query = args["query"] as? String, !query.isEmpty else {
      result([])
      return
    }

    let completer = SearchCompleter(result: result) { [weak self] completer in
      self?.activeSearchCompleters.removeAll { $0 === completer }
    }
    activeSearchCompleters.append(completer)
    completer.search(query)
  }

  private func searchPlaces(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let query = args["query"] as? String, !query.isEmpty else {
      result([])
      return
    }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = [.address, .pointOfInterest]
    let categories: [String: MKPointOfInterestCategory] = [
      "fuel": .gasStation, "parking": .parking, "cafe": .cafe,
      "restaurant": .restaurant, "pharmacy": .pharmacy]
    let nearbyCategory = (args["category"] as? String).flatMap { categories[$0] }
    if let category = nearbyCategory,
       let latitude = args["latitude"] as? Double,
       let longitude = args["longitude"] as? Double {
      guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else {
        result(FlutterError(code: "INVALID_LOCATION", message: nil, details: nil)); return
      }
      request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                         latitudinalMeters: 30000, longitudinalMeters: 30000)
      request.resultTypes = [.pointOfInterest]
      request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category])
    }
    MKLocalSearch(request: request).start { response, error in
      if let error {
        let nsError = error as NSError
        if nsError.domain == MKError.errorDomain && nsError.code == MKError.Code.placemarkNotFound.rawValue {
          result([])
        } else {
          result(FlutterError(
            code: "SEARCH_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }
        return
      }
      let items = response?.mapItems.filter { nearbyCategory == nil || $0.pointOfInterestCategory == nearbyCategory }.prefix(20).map { item -> [String: Any] in
        let coordinate = item.placemark.coordinate
        return [
          "name": item.name ?? item.placemark.name ?? self.unnamedPlaceName(args),
          "address": item.placemark.title ?? "",
          "latitude": coordinate.latitude,
          "longitude": coordinate.longitude,
        ]
      } ?? []
      result(items)
    }
  }

  private func drivingRoute(_ args: [String: Any], result: @escaping FlutterResult) {
    calculateDrivingRoutes(args) { routeResult in
      if let error = routeResult as? FlutterError {
        result(error)
        return
      }
      guard
        let routes = routeResult as? [[String: Any]],
        let first = routes.first,
        let steps = first["steps"] as? [[String: Any]]
      else {
        result(FlutterError(
          code: "NO_ROUTE",
          message: self.noDrivingRouteMessage(args),
          details: nil
        ))
        return
      }
      result(steps)
    }
  }

  private func drivingRoutes(_ args: [String: Any], result: @escaping FlutterResult) {
    calculateDrivingRoutes(args, result: result)
  }

  private func calculateDrivingRoutes(_ args: [String: Any], result: @escaping (Any?) -> Void) {
    guard
      let originLat = args["originLatitude"] as? Double,
      let originLng = args["originLongitude"] as? Double,
      let destinationLat = args["destinationLatitude"] as? Double,
      let destinationLng = args["destinationLongitude"] as? Double
    else {
      result(FlutterError(
        code: "BAD_ARGS",
        message: "Invalid route coordinates",
        details: nil
      ))
      return
    }

    let request = MKDirections.Request()
    // MKDirections.Request has no public source heading/bearing parameter.
    // Latest-position/course reconciliation is performed by the Dart caller.
    request.source = MKMapItem(placemark: MKPlacemark(
      coordinate: CLLocationCoordinate2D(latitude: originLat, longitude: originLng)
    ))
    request.destination = MKMapItem(placemark: MKPlacemark(
      coordinate: CLLocationCoordinate2D(
        latitude: destinationLat,
        longitude: destinationLng
      )
    ))
    request.transportType = .automobile
    request.requestsAlternateRoutes = true

    MKDirections(request: request).calculate { response, error in
      if let error {
        result(FlutterError(
          code: "ROUTE_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }
      guard let routes = response?.routes, !routes.isEmpty else {
        result(FlutterError(
          code: "NO_ROUTE",
          message: self.noDrivingRouteMessage(args),
          details: nil
        ))
        return
      }

      result(routes.prefix(3).enumerated().map { index, route in
        self.routeDictionary(route, index: index, args: args)
      })
    }
  }

  private func routeDictionary(_ route: MKRoute, index: Int, args: [String: Any]) -> [String: Any] {
    [
      "name": route.name.isEmpty ? defaultRouteName(index: index, args: args) : route.name,
      "distance": Int(route.distance.rounded()),
      "expectedTravelTime": Int(route.expectedTravelTime.rounded()),
      "steps": routeStepDictionaries(route),
    ]
  }

  private func routeStepDictionaries(_ route: MKRoute) -> [[String: Any]] {
      var previousHeading: CLLocationDirection?
      var output: [[String: Any]] = []
      for step in route.steps where step.polyline.pointCount >= 2 {
        var coordinates = Array(
          repeating: CLLocationCoordinate2D(),
          count: step.polyline.pointCount
        )
        step.polyline.getCoordinates(
          &coordinates,
          range: NSRange(location: 0, length: step.polyline.pointCount)
        )
        guard let start = coordinates.first, let end = coordinates.last else {
          continue
        }
        let heading = self.heading(from: start, to: end)
        let instruction = step.instructions.lowercased()
          .replacingOccurrences(of: "‑", with: "-")
          .replacingOccurrences(of: "–", with: "-")
        let explicitUTurn = instruction.contains("u-turn") ||
          instruction.contains("u turn") || instruction.contains("uturn") ||
          instruction.contains("掉头") || instruction.contains("調頭") ||
          instruction.contains("掉頭")
        let direction = explicitUTurn ? "UTURN" : self.maneuver(from: previousHeading, to: heading)
        previousHeading = heading
        output.append([
          "direction": direction,
          "startLatitude": start.latitude,
          "startLongitude": start.longitude,
          "endLatitude": end.latitude,
          "endLongitude": end.longitude,
          "distance": Int(step.distance.rounded()),
          "instruction": step.instructions,
          "coordinates": coordinates.map { coordinate in
            [
              "latitude": coordinate.latitude,
              "longitude": coordinate.longitude,
            ]
          },
        ])
      }
      return output
  }

  private func heading(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
  ) -> CLLocationDirection {
    let lat1 = start.latitude * .pi / 180
    let lat2 = end.latitude * .pi / 180
    let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
    let y = sin(deltaLongitude) * cos(lat2)
    let x = cos(lat1) * sin(lat2)
      - sin(lat1) * cos(lat2) * cos(deltaLongitude)
    return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
  }

  private func maneuver(
    from previous: CLLocationDirection?,
    to current: CLLocationDirection
  ) -> String {
    guard let previous else { return "UP" }
    let delta = (current - previous + 540).truncatingRemainder(dividingBy: 360) - 180
    let amount = abs(delta)
    if amount < 20 { return "UP" }
    if amount >= 150 { return "UTURN" }
    if delta < 0 { return amount < 55 ? "BEAR_LEFT" : "LEFT" }
    return amount < 55 ? "BEAR_RIGHT" : "RIGHT"
  }
}

private final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
  private let flutterResult: FlutterResult
  private let onFinish: (SearchCompleter) -> Void
  private let completer = MKLocalSearchCompleter()
  private var didFinish = false

  init(
    result: @escaping FlutterResult,
    onFinish: @escaping (SearchCompleter) -> Void
  ) {
    flutterResult = result
    self.onFinish = onFinish
    super.init()
    completer.delegate = self
    completer.resultTypes = [.address, .pointOfInterest]
  }

  func search(_ query: String) {
    completer.queryFragment = query
  }

  func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
    guard !didFinish else { return }
    didFinish = true

    let items = completer.results.prefix(12).map { item -> [String: Any] in
      [
        "title": item.title,
        "subtitle": item.subtitle,
      ]
    }
    flutterResult(items)
    onFinish(self)
  }

  func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
    guard !didFinish else { return }
    didFinish = true

    let nsError = error as NSError
    if nsError.domain == MKError.errorDomain &&
      nsError.code == MKError.Code.placemarkNotFound.rawValue {
      flutterResult([])
      onFinish(self)
      return
    }

    flutterResult(FlutterError(
      code: "COMPLETE_FAILED",
      message: error.localizedDescription,
      details: nil
    ))
    onFinish(self)
  }
}

private final class NavigationMapViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NavigationMapPlatformView(
      frame: frame,
      args: args as? [String: Any],
      messenger: messenger
    )
  }
}

// A north-pointing movement pointer behind a white-ringed location dot.
private final class MovementLocationView: MKAnnotationView {
  private let pointer = CAShapeLayer()

  override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
    canShowCallout = false
    displayPriority = .required
    let blue = UIColor(red: 0.18, green: 0.46, blue: 1, alpha: 1)
    pointer.frame = bounds
    let path = UIBezierPath()
    path.move(to: CGPoint(x: 28, y: 2))
    path.addLine(to: CGPoint(x: 17, y: 27))
    path.addLine(to: CGPoint(x: 39, y: 27))
    path.close()
    pointer.path = path.cgPath
    pointer.fillColor = blue.cgColor
    pointer.isHidden = true
    layer.addSublayer(pointer)
    let dot = CAShapeLayer()
    dot.path = UIBezierPath(ovalIn: CGRect(x: 16, y: 16, width: 24, height: 24)).cgPath
    dot.fillColor = blue.cgColor
    dot.strokeColor = UIColor.white.cgColor
    dot.lineWidth = 4
    dot.shadowColor = UIColor.black.cgColor
    dot.shadowOpacity = 0.18
    dot.shadowRadius = 4
    dot.shadowOffset = CGSize(width: 0, height: 1)
    layer.addSublayer(dot)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func update(course: CLLocationDirection?, mapHeading: CLLocationDirection) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pointer.isHidden = course == nil
    if let course {
      pointer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(
        (course - mapHeading) * .pi / 180
      )))
    }
    CATransaction.commit()
  }
}

/// Watches touch sequences on the map without taking part in them: it never
/// recognizes and never delays or cancels touches. It reports when every
/// finger of a sequence has lifted, so stuck recognizers can be reset, and
/// when the map last saw a sequence begin.
private final class MapTouchSequenceObserver: UIGestureRecognizer {
  /// Called once every finger of a touch sequence has lifted or cancelled.
  var onSequenceEnded: (() -> Void)?
  /// When the native map last saw a touch sequence begin.
  private(set) var lastSequenceBegan: CFTimeInterval = 0

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if numberOfTouches == touches.count {
      lastSequenceBegan = CACurrentMediaTime()
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if numberOfTouches == touches.count {
      state = .failed
      onSequenceEnded?()
    }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    state = .failed
    onSequenceEnded?()
  }
}

private final class RiderAnnotation: NSObject, MKAnnotation {
  let identifier: String
  var avatarVersion: String?
  var avatarImage: UIImage?
  @objc dynamic var coordinate: CLLocationCoordinate2D
  var title: String? { "NAVIO · \(identifier.prefix(4).uppercased())" }
  var subtitle: String? { "Approximate location · ~100 m" }
  init(identifier: String, coordinate: CLLocationCoordinate2D) {
    self.identifier = identifier
    self.coordinate = coordinate
    super.init()
  }
}

private final class NavigationMapPlatformView: NSObject, FlutterPlatformView, MKMapViewDelegate, UIGestureRecognizerDelegate {
  private var movementCourse: CLLocationDirection?
  private let mapView: MKMapView
  private let eventChannel: FlutterMethodChannel
  private let controlChannel: FlutterMethodChannel
  private var routeLines: [MKPolyline] = []
  private var riderAnnotations: [String: RiderAnnotation] = [:]
  private var selectedRouteIndex = 0
  private var lastRouteArguments: NSArray = []
  private var lastDestinationKey = ""
  private var hasCenteredOnUser = false
  private var hasFittedCurrentRoute = false
  private weak var selectionLongPress: UILongPressGestureRecognizer?
  private weak var touchObserver: MapTouchSequenceObserver?
  private var destinationCoordinate: CLLocationCoordinate2D?
  private var selectedPointAnnotation: MKPointAnnotation?
  private var mapPointSelectionEnabled = false
  private var languageCode = "zh"
  private var mapStyle = "standard"
  private var showsTraffic = false
  private let attributionButton = UIButton(type: .system)
  private var attributionURL: URL?
  private var attributionCollapseTimer: Timer?
  private var attributionCollapsed = false
  private var routePadding = UIEdgeInsets(top: 42, left: 28, bottom: 42, right: 28)
  private var attributionTop: NSLayoutConstraint!
  private var attributionLeft: NSLayoutConstraint!

  init(frame: CGRect, args: [String: Any]?, messenger: FlutterBinaryMessenger) {
    mapView = MKMapView(frame: frame)
    eventChannel = FlutterMethodChannel(
      name: "moto_nav_bridge/navigation_map_events",
      binaryMessenger: messenger
    )
    controlChannel = FlutterMethodChannel(
      name: "moto_nav_bridge/navigation_map_control",
      binaryMessenger: messenger
    )
    super.init()
    mapView.delegate = self
    mapView.showsUserLocation = true
    // A persistent follow mode fights a rider's manual pan. Center once when
    // the first location arrives; subsequent camera movement belongs to them.
    mapView.userTrackingMode = .none
    mapView.pointOfInterestFilter = .includingAll
    mapView.isRotateEnabled = true
    mapView.isPitchEnabled = true
    let tap = UITapGestureRecognizer(
      target: self,
      action: #selector(handleMapTap(_:))
    )
    tap.delegate = self
    tap.cancelsTouchesInView = false
    mapView.addGestureRecognizer(tap)
    let longPress = UILongPressGestureRecognizer(
      target: self,
      action: #selector(handleMapLongPress(_:))
    )
    longPress.minimumPressDuration = 0.45
    longPress.delegate = self
    longPress.cancelsTouchesInView = false
    selectionLongPress = longPress
    mapView.addGestureRecognizer(longPress)
    let observer = MapTouchSequenceObserver(target: nil, action: nil)
    // Same timing as the engine's own fix for its forwarding recognizer:
    // check on the next main-queue turn, after UIKit's normal reset.
    observer.onSequenceEnded = { [weak self] in
      DispatchQueue.main.async { self?.resetStuckRecognizers(reason: "sequence_end") }
    }
    touchObserver = observer
    mapView.addGestureRecognizer(observer)
    // This credits third-party route geometry, not the Apple basemap. Keep it
    // away from MapKit's own attribution and open its licence only on a tap.
    attributionButton.translatesAutoresizingMaskIntoConstraints = false
    attributionButton.titleLabel?.font = .systemFont(ofSize: 11)
    attributionButton.setTitleColor(.secondaryLabel, for: .normal)
    attributionButton.tintColor = .secondaryLabel
    attributionButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.78)
    attributionButton.layer.cornerRadius = 7
    attributionButton.addTarget(self, action: #selector(openRouteAttribution), for: .touchUpInside)
    attributionButton.isHidden = true
    mapView.addSubview(attributionButton)
    attributionTop = attributionButton.topAnchor.constraint(equalTo: mapView.topAnchor, constant: 8)
    attributionLeft = attributionButton.leadingAnchor.constraint(equalTo: mapView.leadingAnchor, constant: 8)
    NSLayoutConstraint.activate([
      attributionLeft,
      attributionTop,
      attributionButton.trailingAnchor.constraint(lessThanOrEqualTo: mapView.trailingAnchor, constant: -8),
      attributionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
      attributionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
    ])
    controlChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "pointerDown" {
        self?.recoverIfTouchMissed()
        result(nil)
        return
      }
      if call.method == "updateRiders", let args = call.arguments as? [String: Any] {
        self?.updateRiders(args["riders"] as? [[String: Any]] ?? [])
        result(nil)
        return
      }
      guard call.method == "updateMap",
            let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.configure(args: args, animated: true)
      result(nil)
    }
    configure(args: args ?? [:], animated: false)
  }

  deinit {
    controlChannel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    mapView
  }

  private func configure(args: [String: Any], animated: Bool) {
    let started = CACurrentMediaTime()
    defer {
      eventChannel.invokeMethod("mapDiagnostic", arguments: ["event": "update_ms=\(Int((CACurrentMediaTime() - started) * 1000))"])
    }
    routePadding = UIEdgeInsets(
      top: max(42, args["paddingTop"] as? Double ?? 42),
      left: max(28, args["paddingLeft"] as? Double ?? 28),
      bottom: max(42, args["paddingBottom"] as? Double ?? 42),
      right: max(28, args["paddingRight"] as? Double ?? 28))
    let nextMapStyle = args["mapStyle"] as? String ?? "standard"
    let nextShowsTraffic = args["showTraffic"] as? Bool ?? false
    if !animated || nextMapStyle != mapStyle || nextShowsTraffic != showsTraffic {
      mapStyle = nextMapStyle
      showsTraffic = nextShowsTraffic
      mapView.overrideUserInterfaceStyle = mapStyle == "standard" ? .light : .dark
      let configuration: MKMapConfiguration
      switch mapStyle {
      case "hybrid":
        let hybrid = MKHybridMapConfiguration()
        hybrid.showsTraffic = showsTraffic
        configuration = hybrid
      case "satellite":
        configuration = MKImageryMapConfiguration()
      case "standard_dark":
        let standard = MKStandardMapConfiguration()
        standard.showsTraffic = showsTraffic
        configuration = standard
      default:
        let standard = MKStandardMapConfiguration()
        standard.showsTraffic = showsTraffic
        configuration = standard
      }
      mapView.preferredConfiguration = configuration
    }
    attributionTop.constant = routePadding.top
    attributionLeft.constant = routePadding.left
    mapPointSelectionEnabled = args["mapPointSelectionEnabled"] as? Bool ?? false
    selectionLongPress?.isEnabled = mapPointSelectionEnabled
    // The current-position marker must remain visible during navigation too.
    // Destination picking controls gestures, not user-location visibility.
    mapView.showsUserLocation = true
    languageCode = args["languageCode"] as? String ?? languageCode
    updateRiders(args["riders"] as? [[String: Any]] ?? [])
    let nextIndex = args["selectedRouteIndex"] as? Int ?? 0
    let routeArguments = args["routes"] as? [[String: Any]] ?? []
    let destinationKey = "\(args["destinationLatitude"] ?? ""):\(args["destinationLongitude"] ?? "")"
    let destinationChanged = lastDestinationKey != destinationKey
    let selectionChanged = selectedRouteIndex != nextIndex
    let routeChanged = !lastRouteArguments.isEqual(to: routeArguments) ||
      selectionChanged || destinationChanged
    if destinationChanged { hasFittedCurrentRoute = false }
    selectedRouteIndex = nextIndex
    lastRouteArguments = routeArguments as NSArray
    lastDestinationKey = destinationKey
    updateRouteAttribution(routeArguments, restartDisplay: routeChanged)
    // Padding, language and navigation-mode updates must not recreate all
    // overlays or restart the camera while a rider is exploring the map.
    if animated && !routeChanged {
      return
    }

    guard
      let destinationLat = args["destinationLatitude"] as? Double,
      let destinationLng = args["destinationLongitude"] as? Double
    else {
      destinationCoordinate = nil
      selectedPointAnnotation = nil
      routeLines = []
      updateRouteAttribution([])
      mapView.removeAnnotations(mapView.annotations.compactMap { $0 as? MKPointAnnotation })
      mapView.removeOverlays(mapView.overlays)
      if !hasCenteredOnUser {
        centerOnUserFallback()
      }
      return
    }

    mapView.userTrackingMode = .none
    let destination = CLLocationCoordinate2D(
      latitude: destinationLat,
      longitude: destinationLng
    )
    destinationCoordinate = destination
    mapView.removeAnnotations(mapView.annotations.compactMap { $0 as? MKPointAnnotation })
    let annotation = MKPointAnnotation()
    annotation.coordinate = destination
    let destinationName = args["destinationName"] as? String ?? destinationTitle
    annotation.title = destinationName
    mapView.addAnnotation(annotation)
    if destinationName == mapPointTitle || destinationName == "地图选点" {
      selectedPointAnnotation = annotation
    } else {
      selectedPointAnnotation = nil
    }

    let routes = routePolylines(from: routeArguments)
    if !routes.isEmpty {
      routeLines = routes
      redrawRouteOverlays()
      // Reroute/side-road refreshes may replace the route geometry often.
      // Update the line, but never yank the camera away from a manual pan.
      if !hasFittedCurrentRoute || destinationChanged || selectionChanged {
        if let selected = routeLines[safe: selectedRouteIndex] {
          fitMap(
            to: [originCoordinate(args) ?? destination, destination],
            overlay: selected,
            animated: animated
          )
        } else {
          fitMap(to: [destination], overlay: routeLines[0], animated: animated)
        }
        hasFittedCurrentRoute = true
      }
      return
    }

    routeLines = []
    mapView.removeOverlays(mapView.overlays)

    guard
      let originLat = args["originLatitude"] as? Double,
      let originLng = args["originLongitude"] as? Double
    else {
      guard !animated else { return }
      let region = MKCoordinateRegion(
        center: destination,
        latitudinalMeters: 1800,
        longitudinalMeters: 1800
      )
      mapView.setRegion(region, animated: false)
      return
    }

    let origin = CLLocationCoordinate2D(latitude: originLat, longitude: originLng)
    // Dart owns route selection and navigation for every provider. The map is
    // display-only: never request an independent Apple route that could arrive
    // late and replace the selected reroute shown by Flutter and the ESP32.
    fitMap(to: [origin, destination], animated: animated)
  }

  private func originCoordinate(_ args: [String: Any]) -> CLLocationCoordinate2D? {
    guard
      let originLat = args["originLatitude"] as? Double,
      let originLng = args["originLongitude"] as? Double
    else {
      return nil
    }
    return CLLocationCoordinate2D(latitude: originLat, longitude: originLng)
  }

  private var usesEnglish: Bool {
    languageCode.lowercased().hasPrefix("en")
  }

  private var destinationTitle: String {
    usesEnglish ? "Destination" : "目的地"
  }

  private var mapPointTitle: String {
    usesEnglish ? "Map point" : "地图选点"
  }

  private func updateRouteAttribution(_ routes: [[String: Any]], restartDisplay: Bool = false) {
    // All alternatives are visible, so credit OSM even if its route is not the
    // selected one. The only supported external licence URL is allowlisted.
    let attributed = routes.first { ($0["attribution"] as? String)?.isEmpty == false }
    let credit = attributed?["attribution"] as? String
    let urlString = attributed?["attributionUrl"] as? String
    attributionURL = urlString == "https://www.openstreetmap.org/copyright"
      ? URL(string: "https://www.openstreetmap.org/copyright") : nil
    guard let credit else {
      attributionCollapseTimer?.invalidate()
      attributionCollapseTimer = nil
      attributionButton.isHidden = true
      return
    }
    attributionButton.isHidden = false
    attributionButton.isEnabled = attributionURL != nil
    attributionButton.accessibilityLabel = usesEnglish
      ? "Route data: \(credit). Open licence information"
      : "路线数据：\(credit)。查看许可信息"
    if restartDisplay {
      attributionCollapsed = false
      attributionCollapseTimer?.invalidate()
      attributionCollapseTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
        guard let self else { return }
        self.attributionCollapsed = true
        self.updateRouteAttributionAppearance(credit)
      }
    }
    updateRouteAttributionAppearance(credit)
  }

  private func updateRouteAttributionAppearance(_ credit: String) {
    if attributionCollapsed {
      attributionButton.setTitle(nil, for: .normal)
      attributionButton.setImage(UIImage(systemName: "info.circle"), for: .normal)
    } else {
      attributionButton.setImage(nil, for: .normal)
      let prefix = usesEnglish ? "Route" : "路线"
      attributionButton.setTitle("  \(prefix) · \(credit)  ", for: .normal)
    }
  }

  @objc private func openRouteAttribution() {
    guard let url = attributionURL else { return }
    UIApplication.shared.open(url)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // A licence tap must not also select a destination or alternative route.
    guard let touchedView = touch.view else { return true }
    return !touchedView.isDescendant(of: attributionButton)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    // Our point-selection gestures must not prevent MapKit pan/zoom/rotation.
    return otherGestureRecognizer is UIPanGestureRecognizer ||
      otherGestureRecognizer is UIPinchGestureRecognizer ||
      otherGestureRecognizer is UIRotationGestureRecognizer
  }

  private func routePolylines(from routes: [[String: Any]]) -> [MKPolyline] {
    routes.compactMap { route -> MKPolyline? in
      guard let points = route["points"] as? [[String: Any]], points.count >= 2 else {
        return nil
      }
      var coordinates = points.compactMap { point -> CLLocationCoordinate2D? in
        guard
          let latitude = point["latitude"] as? Double,
          let longitude = point["longitude"] as? Double
        else {
          return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
      }
      guard coordinates.count >= 2 else { return nil }
      return MKPolyline(coordinates: &coordinates, count: coordinates.count)
    }
  }

  private func redrawRouteOverlays() {
    mapView.removeOverlays(mapView.overlays)
    for (index, line) in routeLines.enumerated() where index != selectedRouteIndex {
      mapView.addOverlay(line)
    }
    if let selected = routeLines[safe: selectedRouteIndex] {
      mapView.addOverlay(selected, level: .aboveRoads)
    }
  }

  private func centerOnUserFallback() {
    let location = mapView.userLocation.coordinate
    guard CLLocationCoordinate2DIsValid(location), location.latitude != 0 else {
      return
    }
    mapView.setRegion(
      MKCoordinateRegion(
        center: location,
        latitudinalMeters: 1200,
        longitudinalMeters: 1200
      ),
      animated: false
    )
    hasCenteredOnUser = true
  }

  /// UIKit can leave a gesture recognizer stuck in a final state after a touch
  /// sequence, notably a two-finger one; a stuck recognizer then ignores every
  /// later touch. The engine resets its own forwarding recognizer for this
  /// before iOS 26 (flutter/flutter#179907) but not MapKit's, so the map pans
  /// once and freezes. Reset any enabled recognizer in the map that has not
  /// returned to .possible. Disabling then re-enabling is the public way to
  /// reset one; recognizers that are deliberately disabled stay disabled.
  ///
  /// With [sparingLiveTouches], recognizers still holding a touch are left
  /// alone: they belong to the gesture in progress. Resetting one that has
  /// already failed for it puts it back in .possible with no touches, so it
  /// never fails again and a pan that requires its failure waits forever.
  private func resetStuckRecognizers(reason: String, sparingLiveTouches: Bool = false) {
    var stuck: [UIGestureRecognizer] = []
    func collect(_ view: UIView) {
      stuck += (view.gestureRecognizers ?? []).filter {
        $0.isEnabled && $0.state != .possible &&
          !(sparingLiveTouches && $0.numberOfTouches > 0)
      }
      view.subviews.forEach(collect)
    }
    collect(mapView)
    guard !stuck.isEmpty else { return }
    let states = stuck.map { "\($0.state.rawValue)/\($0.numberOfTouches)" }
      .joined(separator: ",")
    for recognizer in stuck {
      recognizer.isEnabled = false
      recognizer.isEnabled = true
    }
    eventChannel.invokeMethod("mapDiagnostic", arguments: [
      "event": "recognizers_reset reason=\(reason) count=\(stuck.count) states=\(states)",
    ])
  }

  /// Fallback when the sequence-end check was missed: Flutter saw a touch on
  /// the map but the native map did not (no sequence began around it). That
  /// touch is lost, but the next one works again.
  ///
  /// Flutter's platform-view gate can hand the touch to the map after this
  /// call arrives, so decide only once it has had time to: judging at once
  /// mistook every late touch for a missed one and reset recognizers in the
  /// middle of a live pan, which froze the map.
  private func recoverIfTouchMissed() {
    let pointerDown = CACurrentMediaTime()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, let observer = self.touchObserver,
            observer.lastSequenceBegan < pointerDown - 0.3 else { return }
      // A healthy observer tracking an ongoing gesture (e.g. a second finger
      // added to a pan) is in .possible with touches: never reset a live one.
      let tracking = observer.state == .possible && observer.numberOfTouches > 0
      guard !tracking else { return }
      self.reportTouchGate(observer: observer)
      self.recoverTouchGate()
    }
  }

  private var lastTouchGateReport: CFTimeInterval = 0
  private var lastGateReattach: CFTimeInterval = 0

  /// Escalating recovery when touches stop reaching the map. Toggling
  /// isEnabled does not reset these recognizers (diagnostics showed the same
  /// states after every toggle). First, detach and re-attach the ones stuck
  /// without touches — Flutter's delaying recognizer (the engine applies the
  /// same fix itself for web views on iOS 18.2) and the map's own — which
  /// makes UIKit reset them. The forwarding recognizer, which still receives
  /// touches, is left alone. If touches are missed again soon after, ask
  /// Dart to rebuild the map view, which cannot carry any stuck state over.
  private func recoverTouchGate() {
    let now = CACurrentMediaTime()
    if lastGateReattach > 0 && now - lastGateReattach < 10 {
      lastGateReattach = 0
      eventChannel.invokeMethod("mapDiagnostic", arguments: ["event": "view_recreate"])
      eventChannel.invokeMethod("recreateMapView", arguments: [String: Any]())
      return
    }
    lastGateReattach = now
    var stuck: [UIGestureRecognizer] = []
    if let gate = mapView.superview {
      stuck += (gate.gestureRecognizers ?? []).filter {
        NSStringFromClass(type(of: $0)).contains("Delaying") &&
          $0.state != .possible && $0.numberOfTouches == 0
      }
    }
    func collect(_ view: UIView) {
      stuck += (view.gestureRecognizers ?? []).filter {
        $0.isEnabled && $0.state != .possible && $0.numberOfTouches == 0
      }
      view.subviews.forEach(collect)
    }
    collect(mapView)
    for recognizer in stuck {
      guard let view = recognizer.view else { continue }
      view.removeGestureRecognizer(recognizer)
      view.addGestureRecognizer(recognizer)
    }
    eventChannel.invokeMethod("mapDiagnostic", arguments: [
      "event": "gate_reattach count=\(stuck.count)",
    ])
  }

  /// Diagnostic: when a touch Flutter saw never reached the map, record the
  /// recognizers on the map's ancestors (Flutter's touch-intercepting view
  /// holds the gate that delays and forwards touches) and our own observer,
  /// to tell which one is stuck. At most once every 2 s.
  private func reportTouchGate(observer: MapTouchSequenceObserver) {
    let now = CACurrentMediaTime()
    guard now - lastTouchGateReport >= 2 else { return }
    lastTouchGateReport = now
    func describe(_ recognizer: UIGestureRecognizer) -> String {
      let name = String(NSStringFromClass(type(of: recognizer))
        .split(separator: ".").last ?? "")
        .filter { $0.isLetter || $0.isNumber || $0 == "_" }
      return "\(name.prefix(32)):\(recognizer.state.rawValue)/\(recognizer.numberOfTouches)/\(recognizer.isEnabled ? 1 : 0)"
    }
    var levels: [String] = []
    var view = mapView.superview
    while let current = view, levels.count < 3 {
      let recognizers = (current.gestureRecognizers ?? []).map(describe).joined(separator: ",")
      levels.append(recognizers.isEmpty ? "none" : recognizers)
      view = current.superview
    }
    let observerState = "\(observer.state.rawValue)/\(observer.numberOfTouches)"
    eventChannel.invokeMethod("mapDiagnostic", arguments: [
      "event": "touch_gate observer=\(observerState) ancestors=\(levels.joined(separator: "|"))",
    ])
  }

  @objc private func handleMapTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    eventChannel.invokeMethod("mapDiagnostic", arguments: ["event": "tap_received"])

    let point = gesture.location(in: mapView)
    if routeLines.count > 1 {
      var bestIndex: Int?
      var bestDistance = CGFloat.greatestFiniteMagnitude

      for (index, route) in routeLines.enumerated() {
        let distance = screenDistance(from: point, to: route)
        if distance < bestDistance {
          bestDistance = distance
          bestIndex = index
        }
      }

      if let index = bestIndex,
         index != selectedRouteIndex,
         bestDistance <= 28 {
        selectedRouteIndex = index
        redrawRouteOverlays()
        eventChannel.invokeMethod("routeSelected", arguments: ["index": index])
        return
      }
    }

    selectMapPoint(at: point)
  }

  @objc private func handleMapLongPress(_ gesture: UILongPressGestureRecognizer) {
    // Do not launch route planning while the finger is still on the map.
    guard gesture.state == .ended else { return }
    let point = gesture.location(in: mapView)
    selectMapPoint(at: point)
  }

  private func selectMapPoint(at point: CGPoint) {
    guard mapPointSelectionEnabled else { return }

    let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
    guard CLLocationCoordinate2DIsValid(coordinate) else { return }

    if let selectedPointAnnotation {
      mapView.removeAnnotation(selectedPointAnnotation)
    }

    let annotation = MKPointAnnotation()
    annotation.coordinate = coordinate
    annotation.title = mapPointTitle
    mapView.addAnnotation(annotation)
    selectedPointAnnotation = annotation

    eventChannel.invokeMethod("mapPointSelected", arguments: [
      "latitude": coordinate.latitude,
      "longitude": coordinate.longitude,
    ])
  }

  private func screenDistance(from tap: CGPoint, to route: MKPolyline) -> CGFloat {
    var coordinates = Array(
      repeating: CLLocationCoordinate2D(),
      count: route.pointCount
    )
    route.getCoordinates(&coordinates, range: NSRange(location: 0, length: route.pointCount))
    guard coordinates.count >= 2 else { return .greatestFiniteMagnitude }

    var best = CGFloat.greatestFiniteMagnitude
    for index in 0..<(coordinates.count - 1) {
      let a = mapView.convert(coordinates[index], toPointTo: mapView)
      let b = mapView.convert(coordinates[index + 1], toPointTo: mapView)
      best = min(best, distance(from: tap, toSegmentFrom: a, to: b))
    }
    return best
  }

  private func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    if lengthSquared <= 0 {
      return hypot(point.x - a.x, point.y - a.y)
    }
    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
    let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    return hypot(point.x - projection.x, point.y - projection.y)
  }

  func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
    if destinationCoordinate == nil && !hasCenteredOnUser {
      centerOnUserFallback()
    }
    // CLLocation.course is travel direction, not the phone's compass heading.
    // Reject stationary/poor/stale fixes instead of inventing a direction.
    if let location = userLocation.location,
       abs(location.timestamp.timeIntervalSinceNow) <= 10,
       location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 25,
       location.speed >= 0.5, location.course >= 0 {
      movementCourse = location.course
    } else {
      movementCourse = nil
    }
    updateMovementPointer()
  }

  private func updateRiders(_ rows: [[String: Any]]) {
    var visible = Set<String>()
    for row in rows.prefix(500) {
      guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
            let lat = row["latitude"] as? Double,
            let lon = row["longitude"] as? Double,
            lat.isFinite, lon.isFinite,
            (-34.15 ... -33.50).contains(lat), (150.50 ... 151.45).contains(lon) else { continue }
      visible.insert(id)
      let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
      if let existing = riderAnnotations[id] {
        if applyRiderAvatar(row, to: existing), let view = mapView.view(for: existing) {
          view.image = riderImage(existing)
        }
        if abs(existing.coordinate.latitude - lat) > 0.000001 ||
            abs(existing.coordinate.longitude - lon) > 0.000001 {
          UIView.animate(withDuration: 1.0) { existing.coordinate = coordinate }
        }
      } else {
        let marker = RiderAnnotation(identifier: id, coordinate: coordinate)
        _ = applyRiderAvatar(row, to: marker)
        riderAnnotations[id] = marker
        mapView.addAnnotation(marker)
      }
    }
    for id in Array(riderAnnotations.keys) where !visible.contains(id) {
      if let marker = riderAnnotations.removeValue(forKey: id) { mapView.removeAnnotation(marker) }
    }
    // No camera fitting, route overlay replacement or gesture reset here.
  }

  func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
    if let rider = annotation as? RiderAnnotation {
      let identifier = "navio-rider"
      let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
          ?? MKAnnotationView(annotation: rider, reuseIdentifier: identifier)
      view.annotation = rider
      view.canShowCallout = true
      view.clusteringIdentifier = "navio-riders"
      view.image = riderImage(rider)
      return view
    }
    guard annotation is MKUserLocation else { return nil }
    let identifier = "movement-location"
    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
      as? MovementLocationView) ?? MovementLocationView(
        annotation: annotation, reuseIdentifier: identifier)
    view.annotation = annotation
    view.update(course: movementCourse, mapHeading: mapView.camera.heading)
    return view
  }

  private func applyRiderAvatar(_ row: [String: Any], to rider: RiderAnnotation) -> Bool {
    let version = (row["avatar_id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
    var changed = version != rider.avatarVersion
    if changed { rider.avatarVersion = version; rider.avatarImage = nil }
    if version != nil, rider.avatarImage == nil,
       let encoded = row["avatar_jpeg"] as? String, encoded.utf8.count <= 43692,
       let data = Data(base64Encoded: encoded), data.count <= 32768,
       let image = UIImage(data: data), image.size.width <= 256, image.size.height <= 256 {
      rider.avatarImage = image
      changed = true
    }
    return changed
  }

  private func riderImage(_ rider: RiderAnnotation) -> UIImage {
    let hue = CGFloat(rider.identifier.utf8.reduce(0) { ($0 + Int($1)) % 360 }) / 360
    return UIGraphicsImageRenderer(size: CGSize(width: 38, height: 38)).image { context in
      UIColor.white.setFill()
      context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 38, height: 38))
      let inner = CGRect(x: 2, y: 2, width: 34, height: 34)
      if let image = rider.avatarImage {
        context.cgContext.saveGState()
        context.cgContext.addEllipse(in: inner)
        context.cgContext.clip()
        image.draw(in: inner)
        context.cgContext.restoreGState()
      } else {
        UIColor(hue: hue, saturation: 0.65, brightness: 0.78, alpha: 1).setFill()
        context.cgContext.fillEllipse(in: inner)
        UIImage(systemName: "person.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
            .draw(in: CGRect(x: 10, y: 9, width: 18, height: 20))
      }
    }
  }

  func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
    updateMovementPointer()
  }

  func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
    eventChannel.invokeMethod("mapDiagnostic", arguments: ["event": "region_changed"])
  }

  private func updateMovementPointer() {
    (mapView.view(for: mapView.userLocation) as? MovementLocationView)?.update(
      course: movementCourse, mapHeading: mapView.camera.heading)
  }

  private func fitMap(
    to coordinates: [CLLocationCoordinate2D],
    overlay: MKOverlay? = nil,
    animated: Bool = false
  ) {
    func interacting(_ view: UIView) -> Bool {
      if (view.gestureRecognizers ?? []).contains(where: {
        ($0 is UIPanGestureRecognizer || $0 is UIPinchGestureRecognizer ||
          $0 is UIRotationGestureRecognizer) &&
        ($0.state == .began || $0.state == .changed)
      }) { return true }
      return view.subviews.contains(where: { interacting($0) })
    }
    // Keep overlay updates, but do not take the camera from an active gesture.
    if animated && interacting(mapView) {
      eventChannel.invokeMethod("mapDiagnostic", arguments: ["event": "fit_skipped_active_gesture"])
      return
    }
    eventChannel.invokeMethod("mapDiagnostic", arguments: ["event": "fit_requested"])
    if let overlay {
      mapView.setVisibleMapRect(
        overlay.boundingMapRect,
        edgePadding: routePadding,
        animated: animated
      )
      return
    }

    let points = coordinates.map(MKMapPoint.init)
    guard let first = points.first else { return }
    let rect = points.dropFirst().reduce(
      MKMapRect(origin: first, size: MKMapSize(width: 1, height: 1))
    ) { partial, point in
      partial.union(MKMapRect(origin: point, size: MKMapSize(width: 1, height: 1)))
    }
    mapView.setVisibleMapRect(
      rect,
      edgePadding: routePadding,
      animated: animated
    )
  }

  func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    guard overlay is MKPolyline else {
      return MKOverlayRenderer(overlay: overlay)
    }
    let renderer = MKPolylineRenderer(overlay: overlay)
    if let line = overlay as? MKPolyline,
       let index = routeLines.firstIndex(where: { $0 === line }),
       index != selectedRouteIndex {
      renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.75)
      renderer.lineWidth = 4
    } else {
      renderer.strokeColor = .systemOrange
      renderer.lineWidth = 7
    }
    renderer.lineCap = .round
    renderer.lineJoin = .round
    return renderer
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

/// The paired display's binding JSON, including the key that signs every
/// navigation write. Stored as one opaque string; Dart validates its content.
enum DisplayBindingKeychain {
  private static let item: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.williamli.motonav.display",
    kSecAttrAccount as String: "binding"]

  /// The stored JSON, nil when nothing is saved, or a FlutterError.
  static func load() -> Any? {
    var query = item
    query[kSecReturnData as String] = true
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = found as? Data,
          let text = String(data: data, encoding: .utf8) else {
      return FlutterError(code: "BINDING_READ_FAILED", message: nil, details: nil)
    }
    return text
  }

  static func save(_ text: String?) -> Any? {
    guard let text = text, !text.isEmpty, text.utf8.count <= 1024,
          let data = text.data(using: .utf8) else {
      return FlutterError(code: "INVALID_BINDING", message: nil, details: nil)
    }
    // Reconnects run in the background with the phone locked in a pocket, so
    // the key must stay readable after the first unlock. ThisDeviceOnly keeps
    // it out of backups and off other devices.
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    var status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(item.merging(update) { _, new in new } as CFDictionary, nil)
    }
    return status == errSecSuccess ? nil :
      FlutterError(code: "BINDING_SAVE_FAILED", message: nil, details: nil)
  }

  static func clear() -> Any? {
    let status = SecItemDelete(item as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound ? nil :
      FlutterError(code: "BINDING_SAVE_FAILED", message: nil, details: nil)
  }
}
