# Nearby destination voice tasks

Deploy the updated `server.py` and restart `nav-voice`, and install the updated
app together. The existing `/v1/voice` URL and saved token remain unchanged.
No new API key or dependency is needed. No remote deployment was performed by
the code change.

Supported in Chinese/English: nearby fuel stations, parking, cafes, restaurants,
pharmacies, optionally with an explicit brand. Example: “找最近的 BP 加油站”.
The model returns a validated `find_nearby` intent with category/brand, never
coordinates, a POI name invented as a result, or route instructions.

App pipeline:
1. Require active navigation and a fresh, accurate location.
2. Ask Apple MapKit for POIs near that fix, with a category filter.
3. Filter actual returned names for the requested brand, enforce a 15 km radius,
   deduplicate and retain at most five spatially nearest search results.
4. Ask Valhalla for routes using the active trip preferences; ignore failed,
   mismatched, reverse-course or missing-ETA results. Prefer routes with fewer
   U-turns, then rank destinations by estimated driving time.
5. Read the best verified candidate, full address and approximate minutes.
   Explain that opening hours are unverified and this replaces the destination.
6. Wait for explicit spoken confirmation, then recalculate from the latest fix
   using the existing guarded destination-change transaction.

Cancellation, stale fixes, more than 250 m movement during search, trip changes
or calculation failures retain the existing route. Location goes to the map and
routing services, not Gemini. Audio follows the existing explicit-consent flow.
Up to five bounded route calls per search; no polling or unbounded model agent.

This is fastest among returned, verified candidates, NOT an exhaustive nearest
station guarantee and NOT live-traffic ETA. Brand checks depend on map names;
unknown/missing brands are not silently substituted. Does not verify opening
hours, prices, fuel grades, detour constraints, or add intermediate stops. Those
requests return an unsupported-task explanation rather than dropping constraints.

Test on a parked physical device for real microphone, POI data and gateway model
behavior. Unit tests mock providers; no live Gemini/MapKit call is a unit test.
