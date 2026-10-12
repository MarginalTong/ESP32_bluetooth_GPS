# Connection-card liquid glass trial

The trial is disabled after a physical-device report of a black connection
card over MapKit. Native-map texture sampling is suspected, not confirmed.
`ConnectionCard` no longer opts in. The experimental path on iOS uses pinned
`liquid_glass_renderer` 0.2.0-dev.4. Other platforms, unsupported renderers and
high-contrast mode retain `GlassPanel`. No changes to MapKit, routing or BLE.

Disable without changing code by adding `--dart-define=LIQUID_GLASS_TRIAL=false`
to the Flutter run/build command. The trial now defaults to disabled. Retesting
requires both explicitly opting a test widget in and setting the define to true;
the shipping connection card stays on the fallback even with a stale true define.

Before expanding to other panels, test on a physical iPhone:

- Pan/zoom the native map: confirm background refraction actually follows it.
- Check readable text and connect/disconnect taps in all BLE states.
- Compare sustained navigation frame rate, heat and battery with the flag off.
- Confirm high-contrast mode still uses the fallback.

Widget tests exercise layout/fallback, not Impeller or native-map refraction.
The dependency's MIT license is retained in the package and Flutter's bundled
license registry. This is a third-party approximation, not Apple's native glass.
