import Flutter
import MapKit
import UIKit

// Map gestures and touch recovery are in NavigationMapPlatformView+Touch.swift,
// rider markers in NavigationMapPlatformView+Riders.swift.
final class NavigationMapPlatformView: NSObject, FlutterPlatformView, MKMapViewDelegate, UIGestureRecognizerDelegate {
  var movementCourse: CLLocationDirection?
  let mapView: MKMapView
  let eventChannel: FlutterMethodChannel
  let controlChannel: FlutterMethodChannel
  var routeLines: [MKPolyline] = []
  var riderAnnotations: [String: RiderAnnotation] = [:]
  var selectedRouteIndex = 0
  var lastRouteArguments: NSArray = []
  var lastDestinationKey = ""
  var hasCenteredOnUser = false
  var hasFittedCurrentRoute = false
  weak var selectionLongPress: UILongPressGestureRecognizer?
  weak var touchObserver: MapTouchSequenceObserver?
  var destinationCoordinate: CLLocationCoordinate2D?
  var selectedPointAnnotation: MKPointAnnotation?
  var mapPointSelectionEnabled = false
  var languageCode = "zh"
  var mapStyle = "standard"
  let attributionButton = UIButton(type: .system)
  var attributionURL: URL?
  var attributionCollapseTimer: Timer?
  var attributionCollapsed = false
  var routePadding = UIEdgeInsets(top: 42, left: 28, bottom: 42, right: 28)
  var attributionTop: NSLayoutConstraint!
  var attributionLeft: NSLayoutConstraint!
  // Touch-gate recovery timing (see NavigationMapPlatformView+Touch.swift).
  var lastTouchGateReport: CFTimeInterval = 0
  var lastGateReattach: CFTimeInterval = 0

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

  func configure(args: [String: Any], animated: Bool) {
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
    if !animated || nextMapStyle != mapStyle {
      mapStyle = nextMapStyle
      mapView.overrideUserInterfaceStyle = mapStyle == "standard" ? .light : .dark
      let configuration: MKMapConfiguration
      switch mapStyle {
      case "hybrid":
        configuration = MKHybridMapConfiguration()
      case "satellite":
        configuration = MKImageryMapConfiguration()
      default:
        configuration = MKStandardMapConfiguration()
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

  func originCoordinate(_ args: [String: Any]) -> CLLocationCoordinate2D? {
    guard
      let originLat = args["originLatitude"] as? Double,
      let originLng = args["originLongitude"] as? Double
    else {
      return nil
    }
    return CLLocationCoordinate2D(latitude: originLat, longitude: originLng)
  }

  var usesEnglish: Bool {
    languageCode.lowercased().hasPrefix("en")
  }

  var destinationTitle: String {
    usesEnglish ? "Destination" : "目的地"
  }

  var mapPointTitle: String {
    usesEnglish ? "Map point" : "地图选点"
  }

  func updateRouteAttribution(_ routes: [[String: Any]], restartDisplay: Bool = false) {
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

  func updateRouteAttributionAppearance(_ credit: String) {
    if attributionCollapsed {
      attributionButton.setTitle(nil, for: .normal)
      attributionButton.setImage(UIImage(systemName: "info.circle"), for: .normal)
    } else {
      attributionButton.setImage(nil, for: .normal)
      let prefix = usesEnglish ? "Route" : "路线"
      attributionButton.setTitle("  \(prefix) · \(credit)  ", for: .normal)
    }
  }

  @objc func openRouteAttribution() {
    guard let url = attributionURL else { return }
    UIApplication.shared.open(url)
  }

  func routePolylines(from routes: [[String: Any]]) -> [MKPolyline] {
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

  func redrawRouteOverlays() {
    mapView.removeOverlays(mapView.overlays)
    for (index, line) in routeLines.enumerated() where index != selectedRouteIndex {
      mapView.addOverlay(line)
    }
    if let selected = routeLines[safe: selectedRouteIndex] {
      mapView.addOverlay(selected, level: .aboveRoads)
    }
  }

  func centerOnUserFallback() {
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

  func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
    updateMovementPointer()
  }

  func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
    eventChannel.invokeMethod("mapDiagnostic", arguments: ["event": "region_changed"])
  }

  func updateMovementPointer() {
    (mapView.view(for: mapView.userLocation) as? MovementLocationView)?.update(
      course: movementCourse, mapHeading: mapView.camera.heading)
  }

  func fitMap(
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
