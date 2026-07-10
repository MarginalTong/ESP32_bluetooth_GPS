import Flutter
import MapKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "NavigationMapView") {
      registrar.register(
        NavigationMapViewFactory(),
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
    case "searchPlaces":
      searchPlaces(args, result: result)
    case "drivingRoute":
      drivingRoute(args, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
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
        result(FlutterError(
          code: "SEARCH_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }
      let items = response?.mapItems.prefix(20).map { item -> [String: Any] in
        let coordinate = item.placemark.coordinate
        return [
          "name": item.name ?? item.placemark.name ?? "未命名地点",
          "address": item.placemark.title ?? "",
          "latitude": coordinate.latitude,
          "longitude": coordinate.longitude,
        ]
      } ?? []
      result(items)
    }
  }

  private func drivingRoute(_ args: [String: Any], result: @escaping FlutterResult) {
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

    MKDirections(request: request).calculate { response, error in
      if let error {
        result(FlutterError(
          code: "ROUTE_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }
      guard let route = response?.routes.first else {
        result(FlutterError(
          code: "NO_ROUTE",
          message: "没有找到可驾驶路线",
          details: nil
        ))
        return
      }

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
        let direction = self.maneuver(from: previousHeading, to: heading)
        previousHeading = heading
        output.append([
          "direction": direction,
          "startLatitude": start.latitude,
          "startLongitude": start.longitude,
          "endLatitude": end.latitude,
          "endLongitude": end.longitude,
          "distance": Int(step.distance.rounded()),
          "instruction": step.instructions,
        ])
      }
      result(output)
    }
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

private final class NavigationMapViewFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NavigationMapPlatformView(frame: frame, args: args as? [String: Any])
  }
}

private final class NavigationMapPlatformView: NSObject, FlutterPlatformView, MKMapViewDelegate {
  private let mapView: MKMapView
  private var routeLine: MKPolyline?

  init(frame: CGRect, args: [String: Any]?) {
    mapView = MKMapView(frame: frame)
    super.init()
    mapView.delegate = self
    mapView.showsUserLocation = true
    mapView.userTrackingMode = .follow
    mapView.pointOfInterestFilter = .includingAll
    mapView.isRotateEnabled = true
    mapView.isPitchEnabled = true
    configure(args: args ?? [:])
  }

  func view() -> UIView {
    mapView
  }

  private func configure(args: [String: Any]) {
    guard
      let destinationLat = args["destinationLatitude"] as? Double,
      let destinationLng = args["destinationLongitude"] as? Double
    else {
      centerOnUserFallback()
      return
    }

    let destination = CLLocationCoordinate2D(
      latitude: destinationLat,
      longitude: destinationLng
    )
    let annotation = MKPointAnnotation()
    annotation.coordinate = destination
    annotation.title = args["destinationName"] as? String ?? "目的地"
    mapView.addAnnotation(annotation)

    guard
      let originLat = args["originLatitude"] as? Double,
      let originLng = args["originLongitude"] as? Double
    else {
      let region = MKCoordinateRegion(
        center: destination,
        latitudinalMeters: 1800,
        longitudinalMeters: 1800
      )
      mapView.setRegion(region, animated: false)
      return
    }

    let origin = CLLocationCoordinate2D(latitude: originLat, longitude: originLng)
    calculateRoute(from: origin, to: destination)
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

  private func calculateRoute(
    from origin: CLLocationCoordinate2D,
    to destination: CLLocationCoordinate2D
  ) {
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
    request.transportType = .automobile

    MKDirections(request: request).calculate { [weak self] response, _ in
      guard let self, let route = response?.routes.first else {
        self?.fitMap(to: [origin, destination])
        return
      }
      self.routeLine = route.polyline
      self.mapView.addOverlay(route.polyline)
      self.fitMap(to: [origin, destination], overlay: route.polyline)
    }
  }

  private func fitMap(to coordinates: [CLLocationCoordinate2D], overlay: MKOverlay? = nil) {
    if let overlay {
      mapView.setVisibleMapRect(
        overlay.boundingMapRect,
        edgePadding: UIEdgeInsets(top: 42, left: 28, bottom: 42, right: 28),
        animated: false
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
      edgePadding: UIEdgeInsets(top: 42, left: 28, bottom: 42, right: 28),
      animated: false
    )
  }

  func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    guard overlay is MKPolyline else {
      return MKOverlayRenderer(overlay: overlay)
    }
    let renderer = MKPolylineRenderer(overlay: overlay)
    renderer.strokeColor = UIColor.systemOrange
    renderer.lineWidth = 6
    renderer.lineCap = .round
    renderer.lineJoin = .round
    return renderer
  }
}
