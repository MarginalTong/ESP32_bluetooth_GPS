import CoreLocation
import XCTest
@testable import Runner

final class RouteGeometryTests: XCTestCase {
  func testHeadingPointsAlongTheRoute() {
    let start = CLLocationCoordinate2D(latitude: -33.88, longitude: 151.20)
    let north = CLLocationCoordinate2D(latitude: -33.87, longitude: 151.20)
    let east = CLLocationCoordinate2D(latitude: -33.88, longitude: 151.21)
    XCTAssertEqual(AppleMapsChannel.heading(from: start, to: north), 0, accuracy: 0.1)
    XCTAssertEqual(AppleMapsChannel.heading(from: start, to: east), 90, accuracy: 0.5)
    XCTAssertEqual(AppleMapsChannel.heading(from: north, to: start), 180, accuracy: 0.1)
  }

  func testManeuverFromHeadingChange() {
    XCTAssertEqual(AppleMapsChannel.maneuver(from: nil, to: 90), "UP")
    XCTAssertEqual(AppleMapsChannel.maneuver(from: 0, to: 10), "UP")
    XCTAssertEqual(AppleMapsChannel.maneuver(from: 0, to: 40), "BEAR_RIGHT")
    XCTAssertEqual(AppleMapsChannel.maneuver(from: 0, to: 90), "RIGHT")
    XCTAssertEqual(AppleMapsChannel.maneuver(from: 0, to: 320), "BEAR_LEFT")
    XCTAssertEqual(AppleMapsChannel.maneuver(from: 0, to: 270), "LEFT")
    XCTAssertEqual(AppleMapsChannel.maneuver(from: 0, to: 175), "UTURN")
    // Wrapping across north is still a small right turn.
    XCTAssertEqual(AppleMapsChannel.maneuver(from: 350, to: 30), "BEAR_RIGHT")
  }

  func testTapDistanceToARouteSegment() {
    let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
    XCTAssertEqual(
      NavigationMapPlatformView.distance(from: CGPoint(x: 5, y: 3), toSegmentFrom: a, to: b), 3)
    // Beyond an end the nearest point is that end.
    XCTAssertEqual(
      NavigationMapPlatformView.distance(from: CGPoint(x: 13, y: 4), toSegmentFrom: a, to: b), 5)
    // A zero-length segment is a point.
    XCTAssertEqual(
      NavigationMapPlatformView.distance(from: CGPoint(x: 3, y: 4), toSegmentFrom: a, to: a), 5)
  }
}
