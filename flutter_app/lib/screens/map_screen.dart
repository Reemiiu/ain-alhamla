import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/session_provider.dart';
import '../services/api.dart';
import '../services/geo.dart';
import '../services/location_service.dart';
import '../services/map_cache.dart';
import '../services/offline_tiles.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// الخريطة — تعمل بدون إنترنت:
///  • صور الخريطة من ذاكرة الجوال (تُحفظ تلقائياً لمنطقة مواقع الحملة)
///  • موقعي من GPS (لا يحتاج إنترنت)
///  • نقاط التجمع والنطاقات وآخر موقع للمشرف من آخر بيانات محفوظة
///  • المسافة والسهم وزمن المشي تُحسب داخل الجوال
/// الحاج: يختار الهدف (التجمع / المشرف / مجموعتي). المشرف: يرى حجاج مجموعته ويضغط على أي حاج.
class MapScreen extends StatefulWidget {
  /// التبويب ظاهر الآن (يُشغَّل GPS المباشر فقط عند الحاجة حفاظاً على البطارية)
  final bool active;

  /// الهدف الأول: 'gathering' أو 'supervisor' أو 'group'
  final String? initialTarget;

  /// تُفتح كصفحة مستقلة (من شاشة «أنا تائه») — تُظهر شريط عنوان
  final bool standalone;

  const MapScreen({super.key, this.active = true, this.initialTarget, this.standalone = false});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  StreamSubscription<Position>? _sub;
  Timer? _timer;
  bool _ready = false;
  bool _fitted = false;
  bool _follow = false;
  late String _target;
  int? _selectedPilgrim;
  ({int count, int bytes})? _stats;
  List<LatLng> _lastFocus = const [], _lastAll = const [];

  static const _mina = LatLng(21.4135, 39.8905);

  @override
  void initState() {
    super.initState();
    _target = widget.initialTarget ?? 'gathering';
    _loadStats();
    if (widget.active) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(covariant MapScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _start();
    if (!widget.active && old.active) _stop();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _loadStats() async {
    final st = await TileStore.stats();
    if (mounted) setState(() => _stats = st);
  }

  Future<void> _start() async {
    if (!mounted) return;
    final session = context.read<SessionProvider>();
    session.refreshMapData().then((_) => _loadStats());
    final pos = await LocationService.current(askPermission: true);
    if (!mounted) return;
    if (pos != null) session.updateMyPosition(pos.latitude, pos.longitude);
    // عند فتح التبويب: تقريب الخريطة على موقعي والهدف
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fit(_lastFocus.length == 2 ? _lastFocus : _lastAll);
    });
    await _sub?.cancel();
    try {
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen((p) {
        session.updateMyPosition(p.latitude, p.longitude);
        if (_follow && _ready) _map.move(LatLng(p.latitude, p.longitude), _map.camera.zoom);
      }, onError: (_) {});
    } catch (_) {}
    _timer?.cancel();
    // المشرف يحتاج مواقع الحجاج أحدث، والحاج تكفيه كل دقيقتين (فقط عند وجود إنترنت)
    _timer = Timer.periodic(Duration(seconds: session.isPilgrim ? 120 : 30), (_) async {
      await session.refreshMapData();
      _loadStats();
    });
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
  }

  void _fit(List<LatLng> pts) {
    if (!_ready || pts.isEmpty) return;
    _follow = false;
    if (pts.length == 1) {
      _map.move(pts.first, 16);
      return;
    }
    _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.fromLTRB(48, 110, 48, 48), maxZoom: 17));
  }

  Future<void> _saveMap() async {
    final s = S.of(context);
    final session = context.read<SessionProvider>();
    if (!TileStore.supported) {
      showSnack(context, s.t('map_save_web'));
      return;
    }
    if (OfflineTiles.progress.value != null) return;
    final pts = MapCache.points(session.mapData);
    if (pts.isEmpty) {
      showSnack(context, s.t('map_no_data'), color: AppColors.warning);
      return;
    }
    final ok = await OfflineTiles.prefetch(pts);
    if (ok) await Api.prefs.setString('ain_tiles_key', MapCache.pointsKey(pts));
    await _loadStats();
    if (!mounted) return;
    showSnack(context, ok ? s.t('map_saved_done') : s.t('map_save_failed'), color: ok ? null : AppColors.warning);
  }

  static LatLng? _ll(Map<String, dynamic>? m) {
    final a = asDouble(m?['lat']), b = asDouble(m?['lng']);
    return a == null || b == null ? null : LatLng(a, b);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    final data = session.mapData;
    final me = session.myLat == null ? null : LatLng(session.myLat!, session.myLng!);

    final locations = MapCache.list(data, 'locations');
    final pilgrims = MapCache.list(data, 'pilgrims');
    final sups = MapCache.list(data, 'supervisors');
    final gathering = MapCache.nextGathering(data, groupId: session.isPilgrim ? (session.group?['id'] as int?) : null);
    final center = data?['group_center'] is Map ? Map<String, dynamic>.from(data!['group_center'] as Map) : null;
    final sup = sups.isEmpty ? null : sups.first;

    // ---------------- الهدف المختار ----------------
    LatLng? tp;
    String tName = '';
    String? tSub, tAt, tPhone;
    Color tColor = AppColors.gold;
    Map<String, dynamic>? selected;
    if (session.isPilgrim) {
      if (_target == 'supervisor') {
        tp = _ll(sup);
        tName = '${s.t('supervisor')} · ${sup?['name'] ?? session.group?['supervisor_name'] ?? ''}';
        tAt = sup?['at'] as String?;
        tPhone = (sup?['phone'] ?? session.group?['supervisor_phone']) as String?;
        tColor = AppColors.green;
      } else if (_target == 'group') {
        tp = _ll(center);
        tName = s.t('group_center', {'n': center?['members'] ?? 0});
        tAt = center?['at'] as String?;
        tColor = AppColors.greenSoft;
      } else {
        tp = _ll(gathering);
        tName = '${gathering?['title'] ?? s.t('no_gathering')}';
        tSub = gathering == null ? null : '${gathering['location']} · ${clockOf(gathering['scheduled_at'] as String?)}';
      }
    } else {
      for (final p in pilgrims) {
        if (p['pilgrim_id'] == _selectedPilgrim) selected = p;
      }
      if (selected != null) {
        tp = _ll(selected);
        tName = '${selected['name']}';
        tSub = '${selected['group'] ?? ''}';
        tAt = selected['at'] as String?;
        tPhone = selected['phone'] as String?;
        tColor = _pilgrimColor(selected);
      }
    }

    final target = tp, targetSub = tSub, targetAt = tAt, targetPhone = tPhone;
    final allPts = <LatLng>[
      for (final m in [...locations, ...pilgrims, ...sups])
        if (_ll(m) != null) _ll(m)!,
      if (me != null) me,
    ];
    final focusPts = <LatLng>[if (me != null) me, if (target != null) target];
    final start = me ?? (allPts.isNotEmpty ? allPts.first : _mina);
    _lastFocus = focusPts;
    _lastAll = allPts;

    final online = Api.online.value;
    final dist = (me != null && target != null) ? Geo.distanceM(me.latitude, me.longitude, target.latitude, target.longitude) : null;
    final bear = (me != null && target != null) ? Geo.bearing(me.latitude, me.longitude, target.latitude, target.longitude) : null;

    final mapWidget = FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: start,
        initialZoom: 15,
        minZoom: 10,
        maxZoom: 19,
        backgroundColor: AppColors.surfaceAlt,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        onPositionChanged: (_, hasGesture) {
          if (hasGesture) _follow = false;
        },
        onMapReady: () {
          _ready = true;
          if (!_fitted) {
            _fitted = true;
            _fit(focusPts.length == 2 ? focusPts : allPts);
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: OfflineTiles.urlTemplate,
          userAgentPackageName: OfflineTiles.userAgentPackage,
          tileProvider: OfflineTiles.provider,
          maxNativeZoom: 19,
          evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
        ),
        CircleLayer(circles: [
          for (final l in locations)
            if (_ll(l) != null)
              CircleMarker(
                point: _ll(l)!,
                radius: ((l['radius_m'] as num?) ?? 100).toDouble(),
                useRadiusInMeter: true,
                color: (l['type'] == 'CHECKPOINT' ? AppColors.gold : AppColors.success).withValues(alpha: 0.13),
                borderColor: l['type'] == 'CHECKPOINT' ? AppColors.gold : AppColors.success,
                borderStrokeWidth: 1.5,
              ),
        ]),
        if (me != null && target != null)
          PolylineLayer(polylines: [
            Polyline(points: [me, target], color: tColor, strokeWidth: 3.5, pattern: StrokePattern.dashed(segments: const [12, 8])),
          ]),
        MarkerLayer(markers: [
          for (final l in locations)
            if (_ll(l) != null)
              Marker(point: _ll(l)!, width: 150, height: 24, child: _Label('${l['name']}')),
          if (_ll(gathering) != null)
            Marker(
              point: _ll(gathering)!,
              width: 40,
              height: 40,
              child: _Pin(icon: Icons.flag_rounded, color: AppColors.gold, onTap: () => setState(() => _target = 'gathering')),
            ),
          if (session.isPilgrim && _ll(center) != null)
            Marker(
              point: _ll(center)!,
              width: 38,
              height: 38,
              child: _Pin(icon: Icons.groups_rounded, color: AppColors.greenSoft, onTap: () => setState(() => _target = 'group')),
            ),
          for (final x in sups)
            if (_ll(x) != null)
              Marker(
                point: _ll(x)!,
                width: 40,
                height: 40,
                child: _Pin(icon: Icons.badge_rounded, color: AppColors.green, onTap: () => setState(() => _target = 'supervisor')),
              ),
          for (final p in pilgrims)
            if (_ll(p) != null)
              Marker(
                point: _ll(p)!,
                width: 30,
                height: 30,
                child: GestureDetector(
                  onTap: () => setState(() => _selectedPilgrim = p['pilgrim_id'] as int?),
                  child: _Dot(
                    color: _pilgrimColor(p),
                    ring: p['priority'] == 'CRITICAL' ? AppColors.gold : Colors.white,
                    selected: p['pilgrim_id'] == _selectedPilgrim,
                  ),
                ),
              ),
          if (me != null) Marker(point: me, width: 28, height: 28, child: const _MeDot()),
        ]),
        const SimpleAttributionWidget(source: Text(OfflineTiles.attribution), alignment: Alignment.bottomLeft),
      ],
    );

    final body = Column(children: [
      Expanded(
        child: Stack(children: [
          Positioned.fill(child: mapWidget),
          // شريط الحالة: متصل/بدون إنترنت + عمر البيانات + تقدم حفظ الخريطة
          PositionedDirectional(
            top: 10,
            start: 10,
            end: 64,
            child: _StatusBar(online: online, data: data, stats: _stats),
          ),
          PositionedDirectional(
            top: 10,
            end: 10,
            child: Column(children: [
              _RoundBtn(
                icon: Icons.my_location_rounded,
                tooltip: s.t('my_location'),
                onTap: me == null
                    ? () => showSnack(context, s.t('gps_off'), color: AppColors.warning)
                    : () {
                        _follow = true;
                        if (_ready) _map.move(me, 17);
                      },
              ),
              const SizedBox(height: 8),
              _RoundBtn(
                icon: Icons.zoom_out_map_rounded,
                tooltip: s.t('fit_all'),
                onTap: () => _fit(focusPts.length == 2 ? focusPts : allPts),
              ),
              const SizedBox(height: 8),
              _RoundBtn(icon: Icons.download_for_offline_rounded, tooltip: s.t('map_save'), onTap: _saveMap),
            ]),
          ),
        ]),
      ),
      // ---------------- بطاقة الهدف ----------------
      Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (session.isPilgrim)
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 'gathering', icon: const Icon(Icons.flag_rounded, size: 18), label: Text(s.t('next_gathering'), overflow: TextOverflow.ellipsis)),
                ButtonSegment(value: 'supervisor', icon: const Icon(Icons.badge_rounded, size: 18), label: Text(s.t('supervisor'), overflow: TextOverflow.ellipsis)),
                ButtonSegment(value: 'group', icon: const Icon(Icons.groups_rounded, size: 18), label: Text(s.t('tab_group'), overflow: TextOverflow.ellipsis)),
              ],
              selected: {_target},
              onSelectionChanged: (v) => setState(() => _target = v.first),
            ),
          if (session.isPilgrim) const SizedBox(height: 10),
          if (!session.isPilgrim && selected == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const Icon(Icons.touch_app_rounded, color: AppColors.textFaint),
                const SizedBox(width: 8),
                Expanded(child: Text(s.t('tap_pilgrim'), style: const TextStyle(color: AppColors.textMuted))),
              ]),
            )
          else
            Row(children: [
              CompassArrow(bearing: bear, size: 58, color: tColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tName, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: AppColors.text)),
                  if (targetSub != null && targetSub.isNotEmpty)
                    Text(targetSub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                  const SizedBox(height: 2),
                  if (me == null)
                    Text(s.t('gps_off'), style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.w700, fontSize: 12.5))
                  else if (target == null || dist == null)
                    Text(s.t('no_target'), style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5))
                  else
                    Text('${fmtDistance(s, dist)} ${s.t('from_you')} · ${s.t('walk_min', {'n': Geo.walkMinutes(dist)})}',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.text)),
                  if (targetAt != null)
                    Text(s.t('last_known', {'t': timeAgo(s, targetAt)}), style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5)),
                  if (selected != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(spacing: 6, runSpacing: 4, children: [
                        StatusPill(status: selected['status'] as String?),
                        if (selected['open_alert'] != null)
                          _Chip(text: s.t('${selected['open_alert']}'), color: AppColors.danger),
                        if (selected['battery'] != null)
                          _Chip(text: '${s.t('battery')} ${selected['battery']}٪',
                              color: (selected['battery'] as num) < 20 ? AppColors.danger : AppColors.textMuted),
                      ]),
                    ),
                ]),
              ),
              if (targetPhone != null && targetPhone.isNotEmpty)
                IconButton.filledTonal(onPressed: () => callPhone(targetPhone), icon: const Icon(Icons.call_rounded), tooltip: s.t('call')),
              if (target != null && online)
                IconButton(
                  onPressed: () => launchMaps(target.latitude, target.longitude),
                  icon: const Icon(Icons.directions_rounded, color: AppColors.green),
                  tooltip: s.t('open_maps'),
                ),
            ]),
        ]),
      ),
    ]);

    if (!widget.standalone) return body;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('tab_map'))),
      body: SafeArea(top: false, child: body),
    );
  }

  static Color _pilgrimColor(Map<String, dynamic> p) {
    final a = p['open_alert'];
    if (a == 'SOS' || a == 'LOST' || a == 'GEOFENCE_BREACH') return AppColors.danger;
    final st = p['status'] as String?;
    return st == null ? AppColors.textFaint : statusColor(st);
  }
}

class _StatusBar extends StatelessWidget {
  final bool online;
  final Map<String, dynamic>? data;
  final ({int count, int bytes})? stats;
  const _StatusBar({required this.online, required this.data, required this.stats});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ValueListenableBuilder<({int done, int total})?>(
      valueListenable: OfflineTiles.progress,
      builder: (_, prog, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: online ? Colors.white.withValues(alpha: 0.95) : AppColors.text.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(online ? Icons.cloud_done_rounded : Icons.wifi_off_rounded, size: 16, color: online ? AppColors.success : Colors.white),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                online ? s.t('online') : s.t('map_offline'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: online ? AppColors.text : Colors.white),
              ),
            ),
          ]),
          Text(
            data == null
                ? s.t('map_no_data')
                : [
                    s.t('map_data_age', {'t': timeAgo(s, data!['generated_at'] as String?)}),
                    if (stats != null && stats!.count > 0)
                      stats!.bytes < 0
                          ? s.t('map_saved_n', {'n': stats!.count})
                          : s.t('map_saved', {'n': stats!.count, 'mb': (stats!.bytes / 1048576).toStringAsFixed(1)}),
                  ].join(' · '),
            style: TextStyle(fontSize: 11, color: online ? AppColors.textMuted : Colors.white70),
          ),
          if (prog != null) ...[
            const SizedBox(height: 6),
            Text(s.t('map_saving', {'a': prog.done, 'b': prog.total}),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: online ? AppColors.green : Colors.white)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: prog.total == 0 ? null : prog.done / prog.total,
              color: AppColors.gold,
              backgroundColor: AppColors.line,
              minHeight: 4,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
        ]),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _RoundBtn({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white,
          shape: const CircleBorder(side: BorderSide(color: AppColors.line)),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon, color: AppColors.green, size: 22)),
          ),
        ),
      );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.line),
          ),
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppColors.green)),
        ),
      );
}

class _Pin extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _Pin({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      );
}

class _Dot extends StatelessWidget {
  final Color color;
  final Color ring;
  final bool selected;
  const _Dot({required this.color, required this.ring, required this.selected});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: selected ? 24 : 18,
          height: selected ? 24 : 18,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: selected ? AppColors.text : ring, width: selected ? 3 : 2.5),
          ),
        ),
      );
}

class _MeDot extends StatelessWidget {
  const _MeDot();

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: const Color(0xFF2F6FDE).withValues(alpha: 0.2), shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFF2F6FDE),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
      );
}
