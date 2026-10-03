import Flutter
import MapKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var activeSearchCompleters: [SearchCompleter] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "NavigationMapView") {
      registrar.register(
        NavigationMapViewFactory(messenger: registrar.messenger()),
        withId: "moto_nav_bridge/navigation_map"
      )
    }

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "moto_nav_bridge/apple_maps",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleMapsCall(call, result: result)
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
      let items = response?.mapItems.prefix(20).map { item -> [String: Any] in
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

private final class NavigationMapPlatformView: NSObject, FlutterPlatformView, MKMapViewDelegate, UIGestureRecognizerDelegate {
  private var movementCourse: CLLocationDirection?
  private let mapView: MKMapView
  private let eventChannel: FlutterMethodChannel
  private let controlChannel: FlutterMethodChannel
  private var routeLines: [MKPolyline] = []
  private var selectedRouteIndex = 0
  private var destinationCoordinate: CLLocationCoordinate2D?
  private var selectedPointAnnotation: MKPointAnnotation?
  private var mapPointSelectionEnabled = false
  private var languageCode = "zh"
  private let attributionButton = UIButton(type: .system)
  private var attributionURL: URL?
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
    mapView.userTrackingMode = .follow
    mapView.pointOfInterestFilter = .includingAll
    mapView.isRotateEnabled = true
    mapView.isPitchEnabled = true
    let tap = UITapGestureRecognizer(
      target: self,
      action: #selector(handleMapTap(_:))
    )
    tap.delegate = self
    mapView.addGestureRecognizer(tap)
    let longPress = UILongPressGestureRecognizer(
      target: self,
      action: #selector(handleMapLongPress(_:))
    )
    longPress.minimumPressDuration = 0.45
    longPress.delegate = self
    mapView.addGestureRecognizer(longPress)
    // This credits third-party route geometry, not the Apple basemap. Keep it
    // away from MapKit's own attribution and open its licence only on a tap.
    attributionButton.translatesAutoresizingMaskIntoConstraints = false
    attributionButton.titleLabel?.font = .systemFont(ofSize: 11)
    attributionButton.setTitleColor(.label, for: .normal)
    attributionButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
    attributionButton.layer.cornerRadius = 4
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
    ])
    controlChannel.setMethodCallHandler { [weak self] call, result in
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
    routePadding = UIEdgeInsets(
      top: max(42, args["paddingTop"] as? Double ?? 42),
      left: max(28, args["paddingLeft"] as? Double ?? 28),
      bottom: max(42, args["paddingBottom"] as? Double ?? 42),
      right: max(28, args["paddingRight"] as? Double ?? 28))
    attributionTop.constant = routePadding.top
    attributionLeft.constant = routePadding.left
    mapPointSelectionEnabled = args["mapPointSelectionEnabled"] as? Bool ?? false
    // The current-position marker must remain visible during navigation too.
    // Destination picking controls gestures, not user-location visibility.
    mapView.showsUserLocation = true
    languageCode = args["languageCode"] as? String ?? languageCode
    selectedRouteIndex = args["selectedRouteIndex"] as? Int ?? 0
    let routeArguments = args["routes"] as? [[String: Any]] ?? []
    updateRouteAttribution(routeArguments)

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
      mapView.userTrackingMode = .follow
      centerOnUserFallback()
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
      if let selected = routeLines[safe: selectedRouteIndex] {
        fitMap(
          to: [originCoordinate(args) ?? destination, destination],
          overlay: selected,
          animated: animated
        )
      } else {
        fitMap(to: [destination], overlay: routeLines[0], animated: animated)
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

  private func updateRouteAttribution(_ routes: [[String: Any]]) {
    // All alternatives are visible, so credit OSM even if its route is not the
    // selected one. The only supported external licence URL is allowlisted.
    let attributed = routes.first { ($0["attribution"] as? String)?.isEmpty == false }
    let credit = attributed?["attribution"] as? String
    let urlString = attributed?["attributionUrl"] as? String
    attributionURL = urlString == "https://www.openstreetmap.org/copyright"
      ? URL(string: "https://www.openstreetmap.org/copyright") : nil
    attributionButton.isHidden = credit == nil
    attributionButton.isEnabled = attributionURL != nil
    if let credit {
      let prefix = usesEnglish ? "Route" : "路线"
      attributionButton.setTitle("  \(prefix): \(credit)  ", for: .normal)
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
  }

  @objc private func handleMapTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }

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
    guard gesture.state == .began else { return }
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

  func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
    guard annotation is MKUserLocation else { return nil }
    let identifier = "movement-location"
    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
      as? MovementLocationView) ?? MovementLocationView(
        annotation: annotation, reuseIdentifier: identifier)
    view.annotation = annotation
    view.update(course: movementCourse, mapHeading: mapView.camera.heading)
    return view
  }

  func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
    updateMovementPointer()
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
      renderer.strokeColor = UIColor.systemOrange
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
