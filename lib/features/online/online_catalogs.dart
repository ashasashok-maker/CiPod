import 'dart:convert';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Free, keyless sources: Radio Browser for stations, Apple's podcast search
/// plus each show's RSS feed, and YouTube through youtube_explode_dart.
/// Everything here becomes a [MusicMetadata] the normal player can queue.

const _userAgent = 'Classipod-CAK3D/1.0 (Android; github.com/real-CAK3D/Classipod)';
const _radioApi = 'https://all.api.radio-browser.info/json';

/// Prefix on [MusicMetadata.filePath] for YouTube videos; the player swaps in
/// the real audio stream when it loads the track.
const youTubeScheme = 'yt:';

class Station {
  final String uuid;
  final String name;
  final String url;
  final String? favicon;
  final String detail;

  const Station({
    required this.uuid,
    required this.name,
    required this.url,
    this.favicon,
    this.detail = '',
  });

  factory Station.fromApi(Map<String, dynamic> o) {
    final tags = (o['tags'] as String? ?? '')
        .split(',')
        .where((t) => t.trim().isNotEmpty)
        .take(2)
        .join(', ');
    final bitrate = (o['bitrate'] as num?)?.toInt() ?? 0;
    final country = (o['country'] as String? ?? '').trim();
    final favicon = o['favicon'] as String? ?? '';
    final resolved = o['url_resolved'] as String? ?? '';
    return Station(
      uuid: (o['stationuuid'] ?? o['uuid']) as String,
      name: (o['name'] as String? ?? '').trim(),
      url: resolved.isNotEmpty ? resolved : (o['url'] as String? ?? ''),
      favicon: favicon.startsWith('http') ? favicon : null,
      detail: [
        if (country.isNotEmpty) country,
        if (tags.isNotEmpty) tags,
        if (bitrate > 0) '$bitrate kbps',
      ].join(' · '),
    );
  }

  factory Station.fromJson(Map<String, dynamic> o) => Station(
    uuid: o['uuid'] as String,
    name: o['name'] as String,
    url: o['url'] as String,
    favicon: o['favicon'] as String?,
    detail: o['detail'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'name': name,
    'url': url,
    'favicon': favicon,
    'detail': detail,
  };

  MusicMetadata toMetadata(int index) => MusicMetadata(
    songId: 'radio:$uuid',
    trackName: name,
    trackArtistNames: [if (detail.isNotEmpty) detail else 'Internet radio'],
    albumName: 'Radio',
    filePath: url,
    thumbnailPath: favicon,
    isOnDevice: false,
    originalSongIndex: index,
  );
}

class Podcast {
  final String feedUrl;
  final String title;
  final String? author;
  final String? artwork;

  const Podcast({
    required this.feedUrl,
    required this.title,
    this.author,
    this.artwork,
  });

  factory Podcast.fromJson(Map<String, dynamic> o) => Podcast(
    feedUrl: o['feedUrl'] as String,
    title: o['title'] as String? ?? '',
    author: o['author'] as String?,
    artwork: o['artwork'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'feedUrl': feedUrl,
    'title': title,
    'author': author,
    'artwork': artwork,
  };

  /// For showing a show in the same list tiles as songs.
  MusicMetadata toMetadata(int index) => MusicMetadata(
    songId: 'show:$feedUrl',
    trackName: title,
    trackArtistNames: [author ?? 'Podcast'],
    thumbnailPath: artwork,
    isOnDevice: false,
    originalSongIndex: index,
  );
}

class Episode {
  final String guid;
  final String title;
  final String audioUrl;
  final String? published;
  final int durationSec;
  final String? image;

  const Episode({
    required this.guid,
    required this.title,
    required this.audioUrl,
    this.published,
    this.durationSec = 0,
    this.image,
  });

  MusicMetadata toMetadata(Podcast show, int index) => MusicMetadata(
    songId: 'ep:$guid',
    trackName: title,
    trackArtistNames: [
      [show.title, if (published != null) published!].join(' · '),
    ],
    albumName: show.title,
    filePath: audioUrl,
    thumbnailPath: image ?? show.artwork,
    trackDuration: durationSec > 0 ? durationSec * 1000 : null,
    isOnDevice: false,
    originalSongIndex: index,
  );
}

class YtVideo {
  final String id;
  final String title;
  final String? channel;
  final int durationSec;

  const YtVideo({
    required this.id,
    required this.title,
    this.channel,
    this.durationSec = 0,
  });

  String get thumbnail => 'https://img.youtube.com/vi/$id/hqdefault.jpg';

  factory YtVideo.fromJson(Map<String, dynamic> o) => YtVideo(
    id: o['id'] as String,
    title: o['title'] as String? ?? '',
    channel: o['channel'] as String?,
    durationSec: (o['duration'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'channel': channel,
    'duration': durationSec,
  };

  MusicMetadata toMetadata(int index) => MusicMetadata(
    songId: 'yt:$id',
    trackName: title,
    trackArtistNames: [channel ?? 'YouTube'],
    albumName: 'YouTube',
    filePath: '$youTubeScheme$id',
    thumbnailPath: thumbnail,
    trackDuration: durationSec > 0 ? durationSec * 1000 : null,
    isOnDevice: false,
    originalSongIndex: index,
  );
}

/// A YouTube or YouTube Music playlist. [mine] playlists come from the
/// signed-in Google account (see youtube_account.dart) and can be private;
/// the rest are read publicly, so they must be public or unlisted.
class YtPlaylist {
  /// Stands in for the account's liked videos, which have no playlist id.
  static const likedId = 'LIKED';

  final String id;
  final String title;
  final String? author;
  final String? thumbnail;
  final bool mine;

  const YtPlaylist({
    required this.id,
    required this.title,
    this.author,
    this.thumbnail,
    this.mine = false,
  });

  factory YtPlaylist.fromJson(Map<String, dynamic> o) => YtPlaylist(
    id: o['id'] as String,
    title: o['title'] as String? ?? '',
    author: o['author'] as String?,
    thumbnail: o['thumbnail'] as String?,
    mine: o['mine'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'thumbnail': thumbnail,
    'mine': mine,
  };
}

class OnlineCatalogs {
  OnlineCatalogs._();

  static Future<String> _get(String url) async {
    final response = await http
        .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  static List<Station> _stations(String body) {
    final seen = <String>{};
    return (jsonDecode(body) as List)
        .cast<Map<String, dynamic>>()
        .map(Station.fromApi)
        .where(
          (s) =>
              s.url.startsWith('http') && s.name.isNotEmpty && seen.add(s.uuid),
        )
        .toList();
  }

  static Future<List<Station>> topStations() async =>
      _stations(await _get('$_radioApi/stations/topclick/60?hidebroken=true'));

  static Future<List<Station>> searchStations(String query) async {
    final q = Uri.encodeQueryComponent(query.trim());
    const sort = 'limit=60&hidebroken=true&order=clickcount&reverse=true';
    final byName = _stations(
      await _get('$_radioApi/stations/search?name=$q&$sort'),
    );
    if (byName.length >= 10) return byName;
    final byTag = _stations(
      await _get('$_radioApi/stations/search?tag=$q&$sort'),
    );
    final seen = <String>{};
    return [...byName, ...byTag].where((s) => seen.add(s.uuid)).toList();
  }

  /// Tells Radio Browser a station was played, which keeps its top list useful.
  static Future<void> countClick(String uuid) async {
    try {
      await _get('$_radioApi/url/$uuid');
    } catch (_) {}
  }

  static Future<List<Podcast>> searchPodcasts(String query) async {
    final q = Uri.encodeQueryComponent(query.trim());
    final json =
        jsonDecode(
              await _get(
                'https://itunes.apple.com/search?media=podcast&limit=40&term=$q',
              ),
            )
            as Map<String, dynamic>;
    return (json['results'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .where((o) => (o['feedUrl'] as String? ?? '').startsWith('http'))
        .map(
          (o) => Podcast(
            feedUrl: o['feedUrl'] as String,
            title: o['collectionName'] as String? ?? '',
            author: o['artistName'] as String?,
            artwork: o['artworkUrl600'] as String?,
          ),
        )
        .toList();
  }

  /// Reads a show's RSS feed, newest episodes first (as feeds list them).
  static Future<List<Episode>> episodes(Podcast show) async {
    final doc = XmlDocument.parse(await _get(show.feedUrl));
    final episodes = <Episode>[];
    for (final item in doc.findAllElements('item')) {
      final enclosure = item.getElement('enclosure');
      final url = enclosure?.getAttribute('url');
      if (url == null || url.isEmpty) continue;
      String? text(String name) {
        final value = item.getElement(name)?.innerText.trim();
        return value == null || value.isEmpty ? null : value;
      }

      final pubDate = text('pubDate');
      episodes.add(
        Episode(
          guid: text('guid') ?? url,
          title: text('title') ?? 'Episode',
          audioUrl: url,
          published: pubDate == null ? null : _shortDate(pubDate),
          durationSec: _duration(text('itunes:duration') ?? ''),
          image: item.getElement('itunes:image')?.getAttribute('href'),
        ),
      );
    }
    return episodes;
  }

  static int _duration(String s) => s
      .split(':')
      .map((p) => int.tryParse(p.trim()))
      .whereType<int>()
      .fold(0, (acc, p) => acc * 60 + p);

  static String _shortDate(String s) {
    final parts = s.split(' ');
    return parts.length >= 4 ? '${parts[1]} ${parts[2]} ${parts[3]}' : s;
  }
}

/// YouTube search and audio-only streams. No account or Premium needed, and
/// it plays through Classipod's own player, so it keeps going screen-off.
class YouTubeAudio {
  YouTubeAudio._();

  static final _yt = YoutubeExplode();
  static final _resolved = <String, (String, DateTime)>{};

  static Future<List<YtVideo>> search(String query) async {
    final results = await _yt.search.search(query);
    return results
        .map(
          (v) => YtVideo(
            id: v.id.value,
            title: v.title,
            channel: v.author,
            durationSec: v.duration?.inSeconds ?? 0,
          ),
        )
        .toList();
  }

  static Future<YtVideo> video(String idOrUrl) async {
    final v = await _yt.videos.get(idOrUrl);
    return YtVideo(
      id: v.id.value,
      title: v.title,
      channel: v.author,
      durationSec: v.duration?.inSeconds ?? 0,
    );
  }

  /// The best audio-only stream URL for [id], cached for half an hour.
  static Future<String> audioUrl(String id) async {
    final cached = _resolved[id];
    if (cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 30)) {
      return cached.$1;
    }
    final manifest = await _yt.videos.streams.getManifest(
      id,
      ytClients: [YoutubeApiClient.androidVr, YoutubeApiClient.android],
    );
    // iOS/macOS (AVPlayer) can't decode WebM/Opus, which is usually the
    // highest-bitrate stream, so prefer the MP4/AAC one there.
    final apple =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    final mp4 = manifest.audioOnly.where(
      (s) => s.container == StreamContainer.mp4,
    );
    final audio = apple && mp4.isNotEmpty
        ? mp4.withHighestBitrate()
        : manifest.audioOnly.withHighestBitrate();
    final url = audio.url.toString();
    _resolved[id] = (url, DateTime.now());
    return url;
  }

  /// Pulls the playlist id from a YouTube / YouTube Music link (or a bare
  /// id), or null if [text] has none.
  static String? playlistId(String text) {
    final t = text.trim();
    final fromLink = RegExp(r'[?&]list=([A-Za-z0-9_-]+)').firstMatch(t);
    if (fromLink != null) return fromLink.group(1);
    if (RegExp(r'^(PL|OL|UU|FL|RD)[A-Za-z0-9_-]{8,}$').hasMatch(t)) return t;
    return null;
  }

  /// A public or unlisted playlist's details, read without signing in.
  static Future<YtPlaylist> playlist(String id) async {
    final p = await _yt.playlists.get(id);
    final first = await _yt.playlists.getVideos(id).take(1).toList();
    return YtPlaylist(
      id: p.id.value,
      title: p.title,
      author: p.author,
      thumbnail: first.isEmpty
          ? null
          : 'https://img.youtube.com/vi/${first.first.id.value}/hqdefault.jpg',
    );
  }

  /// The videos of a public or unlisted playlist, in order.
  static Future<List<YtVideo>> playlistVideos(String id, {int limit = 500}) =>
      _yt.playlists
          .getVideos(id)
          .take(limit)
          .map(
            (v) => YtVideo(
              id: v.id.value,
              title: v.title,
              channel: v.author,
              durationSec: v.duration?.inSeconds ?? 0,
            ),
          )
          .toList();

  /// Pulls the video id from a YouTube link, or null if [text] isn't one.
  static String? videoId(String text) {
    if (!text.contains('youtu')) return null;
    try {
      return VideoId(text.trim()).value;
    } catch (_) {
      return null;
    }
  }
}
