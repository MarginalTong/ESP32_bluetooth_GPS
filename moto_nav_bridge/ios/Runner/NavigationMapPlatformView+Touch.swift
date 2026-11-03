import MapKit
import UIKit

/// Map gestures: tap/long-press selection, route picking, and recovery of
/// gesture recognizers that UIKit can leave stuck after multi-finger pans.
extension NavigationMapPlatformView {
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
  func resetStuckRecognizers(reason: String, sparingLiveTouches: Bool = false) {
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
  func recoverIfTouchMissed() {
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

  /// Escalating recovery when touches stop reaching the map. Toggling
  /// isEnabled does not reset these recognizers (diagnostics showed the same
  /// states after every toggle). First, detach and re-attach the ones stuck
  /// without touches — Flutter's delaying recognizer (the engine applies the
  /// same fix itself for web views on iOS 18.2) and the map's own — which
  /// makes UIKit reset them. The forwarding recognizer, which still receives
  /// touches, is left alone. If touches are missed again soon after, ask
  /// Dart to rebuild the map view, which cannot carry any stuck state over.
  func recoverTouchGate() {
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
  func reportTouchGate(observer: MapTouchSequenceObserver) {
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

  @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
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

  @objc func handleMapLongPress(_ gesture: UILongPressGestureRecognizer) {
    // Do not launch route planning while the finger is still on the map.
    guard gesture.state == .ended else { return }
    let point = gesture.location(in: mapView)
    selectMapPoint(at: point)
  }

  func selectMapPoint(at point: CGPoint) {
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

  func screenDistance(from tap: CGPoint, to route: MKPolyline) -> CGFloat {
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
      best = min(best, Self.distance(from: tap, toSegmentFrom: a, to: b))
    }
    return best
  }

  static func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
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
}
