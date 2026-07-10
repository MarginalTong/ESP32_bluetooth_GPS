import Flutter
import UIKit

// NOTE: This app uses the classic UIApplication launch path (Info.plist has no
// UIApplicationSceneManifest), so this SceneDelegate is never instantiated. It
// is kept only to satisfy the Xcode project reference. Reintroducing the Scene
// manifest re-enabled a VSyncClient crash on iOS 18 with Flutter 3.44, so the
// classic path is intentional.
class SceneDelegate: FlutterSceneDelegate {
}
