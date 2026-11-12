import 'dart:typed_data';

import 'package:classipod/core/extensions/go_router_extensions.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/navigation/routes.dart';
import 'package:classipod/core/services/audio_player_service.dart';
import 'package:classipod/features/now_playing/models/now_playing_model.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Loads [items] (stations, episodes or videos) as the queue, plays [index]
/// and opens Now Playing, like picking a song from an album.
Future<void> playOnline(
  BuildContext context,
  WidgetRef ref,
  List<MusicMetadata> items,
  int index,
) async {
  if (items.isEmpty) return;
  final player = ref.read(audioPlayerServiceProvider.notifier);
  await player.setAudioSource(
    preload: false,
    nowPlayingType: NowPlayingType.playlist,
    musicMetadataList: items,
  );
  await player.playSongAtIndex(index.clamp(0, items.length - 1));
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await player.play();
  if (context.mounted) await context.openUniqueNamed(Routes.nowPlaying.name);
}

/// What another app's player is doing, as read through its media session.
class RemoteMediaState {
  final bool access;
  final bool installed;
  final bool active;
  final String? appName;
  final String? title;
  final String? artist;
  final String? album;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final String? artKey;
  final Uint8List? art;

  /// Why the bridge can't connect yet (iOS: missing Client ID or SDK).
  final String? message;

  const RemoteMediaState({
    this.access = false,
    this.installed = true,
    this.active = false,
    this.appName,
    this.title,
    this.artist,
    this.album,
    this.playing = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.artKey,
    this.art,
    this.message,
  });

  factory RemoteMediaState.fromMap(Map<Object?, Object?> m) => RemoteMediaState(
    access: m['access'] as bool? ?? false,
    installed: m['installed'] as bool? ?? true,
    active: m['active'] as bool? ?? false,
    appName: m['appName'] as String?,
    title: m['title'] as String?,
    artist: m['artist'] as String?,
    album: m['album'] as String?,
    playing: m['playing'] as bool? ?? false,
    positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
    artKey: m['artKey'] as String?,
    art: m['art'] as Uint8List?,
    message: m['message'] as String?,
  );
}

/// Drives Spotify (or any app, with no package) through the native bridge in
/// MainActivity / RemoteMediaBridge.kt on Android, and through the Spotify
/// App Remote SDK in SpotifyRemote.swift on iOS.
class RemoteMedia {
  RemoteMedia._();

  static const _channel = MethodChannel('classipod/remote_media');
  static const spotify = 'com.spotify.music';

  static Future<RemoteMediaState> state(String? package) async {
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('state', {
        'package': package,
      });
      return m == null ? const RemoteMediaState() : RemoteMediaState.fromMap(m);
    } on PlatformException {
      return const RemoteMediaState();
    } on MissingPluginException {
      return const RemoteMediaState();
    }
  }

  static Future<void> command(String? package, String action) async {
    try {
      await _channel.invokeMethod<void>('command', {
        'package': package,
        'action': action,
      });
    } catch (_) {}
  }

  static Future<void> openAccess() async {
    try {
      await _channel.invokeMethod<void>('openAccess');
    } catch (_) {}
  }

  static Future<void> openApp(String? package) async {
    try {
      await _channel.invokeMethod<void>('openApp', {'package': package});
    } catch (_) {}
  }
}
