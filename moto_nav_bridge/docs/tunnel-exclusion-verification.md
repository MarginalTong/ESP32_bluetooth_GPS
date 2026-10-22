# Tunnel exclusion verification — 2026-10-13

Deployment: `valhalla`, image `ghcr.io/valhalla/valhalla-scripted:latest`.
Version reported by `/status`: `3.9.0-53e00619f`.
Mounted config: `/home/ubuntu/valhalla/custom_files/valhalla.json`
→ `/custom_files/valhalla.json`.

The operator backed up the config, was instructed to change
`service_limits.allow_hard_exclusions` from false to true, and reported a
successful container restart and HTTP 200 status. No image upgrade or tile
rebuild was performed by the assistant.

Public endpoint verification used synthetic public-road coordinates, not rider
logs: (-33.8695, 151.1888) → (-33.8754, 151.2255).
POST `/route`, auto costing, then POST `/trace_attributes` with returned
`encoded_polyline`, `shape_match: edge_walk`, and `edge.tunnel` / `edge.names`.

| `costing_options.auto.exclude_tunnels` | Distance km | Time seconds | Trace edges | Tunnel edges |
| --- | --- | --- | --- | --- |
| false | 5.099 | 635.478 | 86 | 7 (Cross City Tunnel) |
| true | 4.107 | 738.373 | 129 | 0 |

This demonstrates exclusion on one controlled route, not every tunnel or a
guarantee of complete OSM data. Start/end tunnel exceptions still apply.
App uses the same trip preference snapshot for initial routing and rerouting;
no retry removes the flag. No-path responses remain errors. Tunnel preference
is persisted in the existing local settings JSON; older settings default off.
Recheck configuration and this comparison after replacing/recreating the image,
because `latest` is not an immutable version.
