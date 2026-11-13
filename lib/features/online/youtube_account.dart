import 'dart:async';
import 'dart:convert';

import 'package:classipod/features/online/online_catalogs.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// "My YouTube": reads the listener's own playlists and liked videos through
/// the YouTube Data API. Playback still goes through [YouTubeAudio].
///
/// Sign-in uses Google's device flow (the one TVs use): the app shows a short
/// code, the listener approves it at google.com/device on any device. That
/// needs no browser redirect, plugin or native code.
///
/// The OAuth client ("TVs and Limited Input devices" type) comes from
/// `--dart-define=YT_CLIENT_ID=... --dart-define=YT_CLIENT_SECRET=...`; see
/// README. The scope is read-only.
class YouTubeAccount {
  YouTubeAccount._();

  static const _clientId = String.fromEnvironment('YT_CLIENT_ID');
  static const _clientSecret = String.fromEnvironment('YT_CLIENT_SECRET');
  static const _scope = 'https://www.googleapis.com/auth/youtube.readonly';
  static const _refreshKey = 'youtube.refreshToken';
  static const _api = 'https://www.googleapis.com/youtube/v3';
  static const _storage = FlutterSecureStorage();

  static String? _accessToken;
  static DateTime _expiresAt = DateTime(0);

  /// False when the build has no OAuth client, so sign-in can't work.
  static bool get isConfigured =>
      _clientId.isNotEmpty && _clientSecret.isNotEmpty;

  static Future<bool> isSignedIn() async =>
      (await _storage.read(key: _refreshKey)) != null;

  /// Step 1: get a code for the listener to enter at [DeviceCode.url].
  static Future<DeviceCode> startSignIn() async {
    final res = await http.post(
      Uri.parse('https://oauth2.googleapis.com/device/code'),
      body: {'client_id': _clientId, 'scope': _scope},
    );
    final body = _decode(res);
    return DeviceCode(
      deviceCode: body['device_code'] as String,
      userCode: body['user_code'] as String,
      url: body['verification_url'] as String? ??
          'https://www.google.com/device',
      interval: Duration(seconds: (body['interval'] as num?)?.toInt() ?? 5),
      expiresAt: DateTime.now().add(
        Duration(seconds: (body['expires_in'] as num?)?.toInt() ?? 1800),
      ),
    );
  }

  /// Step 2: poll until the code is approved. Returns true once signed in,
  /// false if it was denied, expired or [isCancelled] became true.
  static Future<bool> waitForApproval(
    DeviceCode code, {
    required bool Function() isCancelled,
  }) async {
    var interval = code.interval;
    while (!isCancelled() && DateTime.now().isBefore(code.expiresAt)) {
      await Future<void>.delayed(interval);
      if (isCancelled()) return false;
      final res = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        body: {
          'client_id': _clientId,
          'client_secret': _clientSecret,
          'device_code': code.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      switch (body['error']) {
        case null:
          await _keepTokens(body);
          return true;
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
        default: // access_denied, expired_token, ...
          return false;
      }
    }
    return false;
  }

  static Future<void> signOut() async {
    final refresh = await _storage.read(key: _refreshKey);
    _accessToken = null;
    _expiresAt = DateTime(0);
    await _storage.delete(key: _refreshKey);
    if (refresh != null) {
      unawaited(
        http
            .post(
              Uri.parse('https://oauth2.googleapis.com/revoke'),
              body: {'token': refresh},
            )
            .then((_) {}, onError: (_) {}),
      );
    }
  }

  static Future<void> _keepTokens(Map<String, dynamic> body) async {
    _accessToken = body['access_token'] as String;
    final seconds = (body['expires_in'] as num?)?.toInt() ?? 3600;
    _expiresAt = DateTime.now().add(Duration(seconds: seconds - 60));
    final refresh = body['refresh_token'] as String?;
    if (refresh != null) {
      await _storage.write(key: _refreshKey, value: refresh);
    }
  }

  static Future<String> _token() async {
    final token = _accessToken;
    if (token != null && DateTime.now().isBefore(_expiresAt)) return token;
    final refresh = await _storage.read(key: _refreshKey);
    if (refresh == null) throw const YouTubeAccountException('Not signed in.');
    final res = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      },
    );
    if (res.statusCode == 400 || res.statusCode == 401) {
      // Revoked, or expired (test-mode Google apps expire it after 7 days).
      await signOut();
      throw const YouTubeAccountException(
        'Your Google sign-in expired. Select Sign In again.',
      );
    }
    await _keepTokens(_decode(res));
    return _accessToken!;
  }

  static Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final res = await http.get(
      Uri.parse('$_api/$path').replace(queryParameters: query),
      headers: {'Authorization': 'Bearer ${await _token()}'},
    );
    return _decode(res);
  }

  /// Follows nextPageToken up to [limit] items.
  static Future<List<Map<String, dynamic>>> _pages(
    String path,
    Map<String, String> query, {
    int limit = 500,
  }) async {
    final items = <Map<String, dynamic>>[];
    String? page;
    do {
      final body = await _get(path, {
        ...query,
        'maxResults': '50',
        'pageToken': ?page,
      });
      items.addAll((body['items'] as List? ?? []).cast<Map<String, dynamic>>());
      page = body['nextPageToken'] as String?;
    } while (page != null && items.length < limit);
    return items;
  }

  static Future<List<YtPlaylist>> playlists() async {
    final items = await _pages('playlists', {
      'part': 'snippet',
      'mine': 'true',
    });
    return [
      for (final p in items)
        YtPlaylist(
          id: p['id'] as String,
          title: _snippet(p)['title'] as String? ?? '',
          author: _snippet(p)['channelTitle'] as String?,
          thumbnail: _thumbnail(_snippet(p)),
          mine: true,
        ),
    ];
  }

  /// Videos of one of [playlists], or liked videos for [YtPlaylist.likedId].
  static Future<List<YtVideo>> playlistVideos(String id) async {
    if (id == YtPlaylist.likedId) {
      final items = await _pages('videos', {
        'part': 'snippet,contentDetails',
        'myRating': 'like',
      });
      return [
        for (final v in items)
          YtVideo(
            id: v['id'] as String,
            title: _snippet(v)['title'] as String? ?? '',
            channel: _snippet(v)['channelTitle'] as String?,
            durationSec: _seconds(
              (v['contentDetails'] as Map?)?['duration'] as String?,
            ),
          ),
      ];
    }
    final items = await _pages('playlistItems', {
      'part': 'snippet,contentDetails',
      'playlistId': id,
    });
    return [
      for (final v in items)
        if ((v['contentDetails'] as Map?)?['videoId'] case final String videoId)
          // Deleted and private videos stay in playlists but can't play.
          if (!const {'Deleted video', 'Private video'}
              .contains(_snippet(v)['title']))
            YtVideo(
              id: videoId,
              title: _snippet(v)['title'] as String? ?? '',
              channel: _snippet(v)['videoOwnerChannelTitle'] as String?,
            ),
    ];
  }

  static Map<String, dynamic> _snippet(Map<String, dynamic> item) =>
      (item['snippet'] as Map?)?.cast<String, dynamic>() ?? const {};

  static String? _thumbnail(Map<String, dynamic> snippet) {
    final thumbs = (snippet['thumbnails'] as Map?)?.cast<String, dynamic>();
    for (final size in const ['high', 'medium', 'default']) {
      final url = (thumbs?[size] as Map?)?['url'];
      if (url is String) return url;
    }
    return null;
  }

  /// "PT1H2M3S" -> 3723.
  static int _seconds(String? iso) {
    final m = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?').firstMatch(iso ?? '');
    if (m == null) return 0;
    int part(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
    return part(1) * 3600 + part(2) * 60 + part(3);
  }

  static Map<String, dynamic> _decode(http.Response res) {
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    final error = body['error'];
    final message = switch (error) {
      {'message': final String m} => m,
      final String e => (body['error_description'] as String?) ?? e,
      _ => 'HTTP ${res.statusCode}',
    };
    throw YouTubeAccountException(message);
  }
}

class DeviceCode {
  final String deviceCode;
  final String userCode;
  final String url;
  final Duration interval;
  final DateTime expiresAt;

  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.url,
    required this.interval,
    required this.expiresAt,
  });
}

class YouTubeAccountException implements Exception {
  final String message;

  const YouTubeAccountException(this.message);

  @override
  String toString() => message;
}
