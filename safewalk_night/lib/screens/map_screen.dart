import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_store.dart';
import '../services/route_service.dart';
import '../services/session_controller.dart';

/// Community unsafe-locations map + safer-route suggestion.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const LatLng _fallbackCentre = LatLng(6.8213, 80.0416); // NSBM Green University

  final MapController _map = MapController();
  final RouteService _routes = RouteService();
  GeoFix? _me;
  GeoFix? _destination;
  List<RouteOption> _options = const [];
  bool _picking = false;
  bool _loading = false;
  String? _routeNote;

  @override
  void initState() {
    super.initState();
    _locate(moveCamera: true);
  }

  Future<void> _locate({bool moveCamera = false}) async {
    final controller = context.read<SessionController>();
    final fix = controller.lastFix ?? await controller.location.current();
    if (!mounted || fix == null) return;
    setState(() => _me = fix);
    if (moveCamera) _map.move(LatLng(fix.lat, fix.lng), 16);
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _onTap(LatLng point) async {
    if (!_picking) return;
    final from = _me;
    if (from == null) {
      _snack('Your location is not available yet. Turn on GPS and try again.');
      return;
    }
    final to = GeoFix(lat: point.latitude, lng: point.longitude, time: DateTime.now());
    final reports = context.read<AppStore>().reports;
    setState(() {
      _picking = false;
      _loading = true;
      _destination = to;
      _options = const [];
      _routeNote = null;
    });
    List<RouteOption> ranked;
    String? note;
    try {
      ranked = RouteService.rankBySafety(await _routes.fetchAlternatives(from, to), reports);
      if (ranked.length == 1) note = 'Only one walking route was found for this trip.';
    } catch (_) {
      ranked = RouteService.rankBySafety([RouteService.straightLine(from, to)], reports);
      note = 'Routes could not be loaded (offline?). Showing a straight line only.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _options = ranked;
      _routeNote = note;
    });
    final best = ranked.first.points;
    if (best.length >= 2) {
      _map.fitCamera(CameraFit.coordinates(
        coordinates: [for (final p in best) LatLng(p[0], p[1])],
        padding: const EdgeInsets.fromLTRB(40, 90, 40, 220),
      ));
    }
  }

  Future<void> _report(LatLng point) async {
    final store = context.read<AppStore>();
    var category = UnsafeReport.categories.first;
    final note = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Report an unsafe location', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final c in UnsafeReport.categories)
                    ChoiceChip(label: Text(c), selected: category == c, onSelected: (_) => setSheet(() => category = c)),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: note,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'What should others know? (optional)'),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add to map')),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true) {
      await store.addReport(lat: point.latitude, lng: point.longitude, category: category, note: note.text);
      if (mounted) _snack('Thanks - your report was added to the map.');
    }
  }

  void _showReport(UnsafeReport r) {
    final store = context.read<AppStore>();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(r.category, style: Theme.of(ctx).textTheme.titleLarge)),
                if (r.sample) const Chip(label: Text('Sample data')),
              ],
            ),
            if (r.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(r.note)),
            const SizedBox(height: 6),
            Text('Confirmed by ${r.confirmations} ${r.confirmations == 1 ? 'person' : 'people'}'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      store.confirmReport(r.id);
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.thumb_up_alt_outlined),
                    label: const Text('I noticed this too'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    store.removeReport(r.id);
                    Navigator.pop(ctx);
                  },
                  child: const Text('Remove'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _km(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final best = _options.isEmpty ? null : _options.first;
    final shortest = _options.isEmpty ? null : _options.reduce((a, b) => a.distanceMeters <= b.distanceMeters ? a : b);

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _me == null ? _fallbackCentre : LatLng(_me!.lat, _me!.lng),
            initialZoom: 15,
            onTap: (_, p) => _onTap(p),
            onLongPress: (_, p) => _report(p),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'lk.nsbm.group46.safewalk_night',
            ),
            CircleLayer(
              circles: [
                for (final r in store.reports)
                  CircleMarker(
                    point: LatLng(r.lat, r.lng),
                    radius: RouteService.dangerRadiusMeters,
                    useRadiusInMeter: true,
                    color: const Color(0xFFE5484D).withValues(alpha: 0.15),
                    borderColor: const Color(0xFFE5484D).withValues(alpha: 0.5),
                    borderStrokeWidth: 1,
                  ),
              ],
            ),
            PolylineLayer(
              polylines: [
                for (final o in _options.skip(1))
                  Polyline(
                    points: [for (final p in o.points) LatLng(p[0], p[1])],
                    strokeWidth: 4,
                    color: Colors.grey.withValues(alpha: 0.8),
                  ),
                if (best != null)
                  Polyline(
                    points: [for (final p in best.points) LatLng(p[0], p[1])],
                    strokeWidth: 6,
                    color: const Color(0xFF2FBF71),
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                for (final r in store.reports)
                  Marker(
                    point: LatLng(r.lat, r.lng),
                    width: 40,
                    height: 40,
                    child: GestureDetector(
                      onTap: () => _showReport(r),
                      child: const Icon(Icons.warning_rounded, color: Color(0xFFE5484D), size: 34),
                    ),
                  ),
                if (_destination != null)
                  Marker(
                    point: LatLng(_destination!.lat, _destination!.lng),
                    width: 40,
                    height: 40,
                    alignment: Alignment.topCenter,
                    child: const Icon(Icons.flag, color: Color(0xFF2FBF71), size: 36),
                  ),
                if (_me != null)
                  Marker(
                    point: LatLng(_me!.lat, _me!.lng),
                    width: 26,
                    height: 26,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF3B82F6),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  ),
              ],
            ),
            const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Card(
            color: scheme.surface.withValues(alpha: 0.94),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                _picking
                    ? 'Tap your destination on the map'
                    : 'Unsafe-locations map  ·  long-press anywhere to report a place',
                style: TextStyle(fontWeight: _picking ? FontWeight.w700 : FontWeight.w500),
              ),
            ),
          ),
        ),
        if (_loading) const Center(child: CircularProgressIndicator()),
        if (best != null && shortest != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 84,
            child: Card(
              color: scheme.surface.withValues(alpha: 0.96),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.verified_user, color: Color(0xFF2FBF71)),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('Suggested safer route', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        ),
                        IconButton(
                          tooltip: 'Clear route',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _options = const [];
                            _destination = null;
                            _routeNote = null;
                          }),
                        ),
                      ],
                    ),
                    Text(
                      '${_km(best.distanceMeters)}  ·  about ${(best.durationSeconds / 60).ceil()} min walk  ·  '
                      '${best.reportsNearby == 0 ? 'no reported spots on the way' : '${best.reportsNearby} reported spot(s) nearby'}',
                    ),
                    if (_options.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          identical(best, shortest)
                              ? 'Compared ${_options.length} routes - the shortest is also the safest.'
                              : 'Compared ${_options.length} routes - this one avoids '
                                  '${shortest.reportsNearby - best.reportsNearby} reported spot(s) '
                                  'for ${_km(best.distanceMeters - shortest.distanceMeters)} extra.',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                        ),
                      ),
                    if (_routeNote != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_routeNote!, style: const TextStyle(color: Colors.amber, fontSize: 13)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          right: 12,
          bottom: 16,
          child: Row(
            children: [
              FloatingActionButton.small(
                heroTag: 'locate',
                tooltip: 'My location',
                onPressed: () => _locate(moveCamera: true),
                child: const Icon(Icons.my_location),
              ),
              const SizedBox(width: 10),
              FloatingActionButton.extended(
                heroTag: 'route',
                onPressed: () => setState(() => _picking = !_picking),
                icon: Icon(_picking ? Icons.close : Icons.alt_route),
                label: Text(_picking ? 'Cancel' : 'Safer route'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
