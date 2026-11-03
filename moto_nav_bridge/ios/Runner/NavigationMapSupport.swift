import Flutter
import MapKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

final class NavigationMapViewFactory: NSObject, FlutterPlatformViewFactory {
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
final class MovementLocationView: MKAnnotationView {
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
final class MapTouchSequenceObserver: UIGestureRecognizer {
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

final class RiderAnnotation: NSObject, MKAnnotation {
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

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
