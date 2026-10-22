# Location link import

Paste a link or decimal latitude,longitude into the existing destination search field,
or use its explicit clipboard button. Choose a candidate, confirm, then inspect the
pin/route on the home map and use the existing start-navigation button. The original
GPS-origin / Valhalla / BLE flow is unchanged. No server or firmware changes.

Implementation: LocationLinkParser, MapUrlResolver, optional sourceUrl and
resolutionStatus on PlaceResult, and PlaceSearchPage integration.

Short URLs: HTTPS-only allowlist, no credentials/custom ports, manual redirects,
five-redirect limit, loop detection, ten-second overall timeout, client closed on
completion/failure. Only redirect headers are used, never HTML. Long links parse
locally. Explicit destination/query parameters outrank viewport coordinates.
Google place paths fall back to name search. Standalone viewport coordinates are
labelled and require a warning confirmation. Identifier-only links fail clearly.

Geocoding uses existing Apple Maps search on iOS; all candidates are shown, never
silently selecting the first. This is a cross-provider search, not a guaranteed
Google Place ID match. Android direct-coordinate parsing works, but name lookup
still requires an Android implementation of the existing search service. No paid
Google API or new dependencies were added. No reverse geocoding is fabricated:
coordinate-only links display coordinates instead of an invented street address.

Supported hosts are deliberately limited to Google .com/.com.au map hosts,
maps.app.goo.gl, goo.gl/maps and maps.apple.com. Other regional hosts, app-only
links, HTML/JavaScript redirects, consent pages and identifier-only links may not
resolve. Only the destination is imported, not Google's route or waypoints.

Manual network check: user sample maps.app.goo.gl/jRszrFpJuSBtBA9F9 returned a
302 to maps.google.com with a place-name/address q parameter (Decathlon Tempe).
No destination is hardcoded. Full real-device Apple search → route → ESP32 check
remains necessary; HTTP response-header verification alone is not end-to-end QA.

URL references:
- https://developers.google.com/maps/documentation/urls/get-started
- https://developer.apple.com/documentation/mapkit/unified-map-urls
