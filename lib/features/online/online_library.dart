import 'dart:convert';

import 'package:classipod/features/online/online_catalogs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the listener keeps from the online sources: radio presets, podcast
/// subscriptions and saved YouTube videos. Stored on the phone only.
class OnlineLibrary {
  OnlineLibrary._();

  static final _prefs = SharedPreferencesAsync();

  static Future<List<T>> _read<T>(
    String key,
    T Function(Map<String, dynamic>) parse,
  ) async {
    try {
      final raw = await _prefs.getString(key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(parse)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _write(String key, List<Map<String, dynamic>> items) =>
      _prefs.setString(key, jsonEncode(items));

  static Future<List<Station>> presets() =>
      _read('online.presets', Station.fromJson);

  static Future<List<Station>> togglePreset(Station station) async {
    final list = await presets();
    final had = list.any((s) => s.uuid == station.uuid);
    list.removeWhere((s) => s.uuid == station.uuid);
    if (!had) list.add(station);
    await _write('online.presets', list.map((s) => s.toJson()).toList());
    return list;
  }

  static Future<List<Podcast>> subscriptions() =>
      _read('online.subscriptions', Podcast.fromJson);

  static Future<List<Podcast>> toggleSubscription(Podcast show) async {
    final list = await subscriptions();
    final had = list.any((p) => p.feedUrl == show.feedUrl);
    list.removeWhere((p) => p.feedUrl == show.feedUrl);
    if (!had) list.insert(0, show);
    await _write('online.subscriptions', list.map((p) => p.toJson()).toList());
    return list;
  }

  static Future<List<YtVideo>> savedVideos() =>
      _read('online.videos', YtVideo.fromJson);

  static Future<List<YtVideo>> toggleSaved(YtVideo video) async {
    final list = await savedVideos();
    final had = list.any((v) => v.id == video.id);
    list.removeWhere((v) => v.id == video.id);
    if (!had) list.insert(0, video);
    await _write('online.videos', list.map((v) => v.toJson()).toList());
    return list;
  }
}
