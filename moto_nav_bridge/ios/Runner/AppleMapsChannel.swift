import Flutter
import MapKit

/// Apple Maps search, suggestions, driving routes and search history for the
/// `moto_nav_bridge/apple_maps` channel.
final class AppleMapsChannel {
  private var activeSearchCompleters: [SearchCompleter] = []

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
        let heading = Self.heading(from: start, to: end)
        let instruction = step.instructions.lowercased()
          .replacingOccurrences(of: "‑", with: "-")
          .replacingOccurrences(of: "–", with: "-")
        let explicitUTurn = instruction.contains("u-turn") ||
          instruction.contains("u turn") || instruction.contains("uturn") ||
          instruction.contains("掉头") || instruction.contains("調頭") ||
          instruction.contains("掉頭")
        let direction = explicitUTurn ? "UTURN" : Self.maneuver(from: previousHeading, to: heading)
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

  static func heading(
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

  static func maneuver(
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
