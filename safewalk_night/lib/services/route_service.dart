import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/models.dart';

/// One candidate walking route between two points.
class RouteOption {
  final List<List<double>> points; // [lat, lng]
  final double distanceMeters;
  final double durationSeconds;

  /// Risk score from nearby unsafe-location reports (0 = none nearby).
  final double risk;

  /// Number of reports within [RouteService.dangerRadiusMeters] of the route.
  final int reportsNearby;

  const RouteOption({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.risk = 0,
    this.reportsNearby = 0,
  });

  RouteOption scored(double risk, int reportsNearby) => RouteOption(
        points: points,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
        risk: risk,
        reportsNearby: reportsNearby,
      );
}

/// Suggests the safer of several walking routes.
///
/// Candidate routes come from the public OpenStreetMap routing service; each
/// one is then scored against the community unsafe-location reports and the
/// lowest-risk route is recommended (shortest wins a tie).
class RouteService {
  static const double dangerRadiusMeters = 150;

  static const List<String> _servers = [
    'https://routing.openstreetmap.de/routed-foot/route/v1/foot',
    'https://router.project-osrm.org/route/v1/foot',
  ];

  final http.Client _client;
  RouteService([http.Client? client]) : _client = client ?? http.Client();

  Future<List<RouteOption>> fetchAlternatives(GeoFix from, GeoFix to) async {
    Object? lastError;
    for (final server in _servers) {
      try {
        final routes = await _request(server, [from, to]);
        if (routes.isEmpty) continue;
        // The service often returns a single route. Ask for two more that are
        // forced through a point to the left / right of the direct line, so
        // there is a real choice to compare for safety.
        if (routes.length < 2) {
          for (final via in viaPoints(from, to)) {
            try {
              routes.addAll(await _request(server, [from, via, to]));
            } catch (_) {}
          }
        }
        return dedupe(routes);
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Could not fetch routes ($lastError)');
  }

  Future<List<RouteOption>> _request(String server, List<GeoFix> stops) async {
    final coords = stops.map((s) => '${s.lng},${s.lat}').join(';');
    final alternatives = stops.length == 2 ? 'alternatives=3&' : '';
    final uri = Uri.parse('$server/$coords?${alternatives}overview=full&geometries=geojson');
    final res = await _client
        .get(uri, headers: {'User-Agent': 'SafeWalkNight/1.0 (student project)'}).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return parseOsrm(res.body);
  }

  /// Two detour points, either side of the midpoint of the direct line.
  static List<GeoFix> viaPoints(GeoFix from, GeoFix to) {
    final direct = GeoFix.distanceMeters(from.lat, from.lng, to.lat, to.lng);
    if (direct < 50) return const [];
    final offset = (0.3 * direct).clamp(150.0, 800.0);
    final midLat = (from.lat + to.lat) / 2, midLng = (from.lng + to.lng) / 2;
    const metersPerDegLat = 111320.0;
    final metersPerDegLng = metersPerDegLat * math.cos(midLat * math.pi / 180);
    final dy = (to.lat - from.lat) * metersPerDegLat, dx = (to.lng - from.lng) * metersPerDegLng;
    final len = math.sqrt(dx * dx + dy * dy);
    final px = -dy / len, py = dx / len; // unit vector perpendicular to the line
    return [
      for (final side in const [1.0, -1.0])
        GeoFix(
          lat: midLat + side * py * offset / metersPerDegLat,
          lng: midLng + side * px * offset / metersPerDegLng,
          time: from.time,
        ),
    ];
  }

  /// Drops routes that are practically the same as one already kept.
  static List<RouteOption> dedupe(List<RouteOption> routes) {
    final kept = <RouteOption>[];
    for (final r in routes) {
      final same = kept.any((k) =>
          (k.distanceMeters - r.distanceMeters).abs() < 0.02 * k.distanceMeters + 5 && k.points.length == r.points.length);
      if (!same) kept.add(r);
    }
    return kept;
  }

  static List<RouteOption> parseOsrm(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final routes = (json['routes'] as List?) ?? const [];
    return [
      for (final r in routes)
        RouteOption(
          points: [
            for (final c in (r['geometry']['coordinates'] as List))
              [(c[1] as num).toDouble(), (c[0] as num).toDouble()],
          ],
          distanceMeters: (r['distance'] as num).toDouble(),
          durationSeconds: (r['duration'] as num).toDouble(),
        ),
    ];
  }

  /// Scores every route and returns them safest first.
  static List<RouteOption> rankBySafety(List<RouteOption> routes, List<UnsafeReport> reports) {
    final scored = [for (final r in routes) _score(r, reports)];
    scored.sort((a, b) {
      final byRisk = a.risk.compareTo(b.risk);
      return byRisk != 0 ? byRisk : a.distanceMeters.compareTo(b.distanceMeters);
    });
    return scored;
  }

  static RouteOption _score(RouteOption route, List<UnsafeReport> reports) {
    var risk = 0.0;
    var near = 0;
    for (final report in reports) {
      var closest = double.infinity;
      for (final p in route.points) {
        final d = GeoFix.distanceMeters(p[0], p[1], report.lat, report.lng);
        if (d < closest) closest = d;
      }
      if (closest <= dangerRadiusMeters) {
        near++;
        // Closer reports and reports confirmed by more people weigh more.
        final proximity = 1 - closest / dangerRadiusMeters;
        final weight = 1 + 0.25 * (report.confirmations - 1).clamp(0, 8);
        risk += (0.5 + 0.5 * proximity) * weight;
      }
    }
    return route.scored(risk, near);
  }

  /// A straight line, used when no route can be fetched (offline).
  static RouteOption straightLine(GeoFix from, GeoFix to) {
    final d = GeoFix.distanceMeters(from.lat, from.lng, to.lat, to.lng);
    return RouteOption(
      points: [
        [from.lat, from.lng],
        [to.lat, to.lng],
      ],
      distanceMeters: d,
      durationSeconds: d / 1.3,
    );
  }
}
