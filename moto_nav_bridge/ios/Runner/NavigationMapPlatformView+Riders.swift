import MapKit
import UIKit

/// Other riders' markers and avatars on the map.
extension NavigationMapPlatformView {
  func updateRiders(_ rows: [[String: Any]]) {
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


  func applyRiderAvatar(_ row: [String: Any], to rider: RiderAnnotation) -> Bool {
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

  func riderImage(_ rider: RiderAnnotation) -> UIImage {
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
}
