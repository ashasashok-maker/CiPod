import 'dart:async';

import 'package:classipod/core/extensions/build_context_extensions.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/navigation/routes.dart';
import 'package:classipod/core/services/audio_player_service.dart';
import 'package:classipod/core/theme/ipod_typography.dart';
import 'package:classipod/core/widgets/album_art_song_list_tile.dart';
import 'package:classipod/core/widgets/display_list_tile.dart';
import 'package:classipod/core/widgets/input_text_bar.dart';
import 'package:classipod/features/custom_screen_elements/custom_input_text_screen.dart';
import 'package:classipod/features/custom_screen_elements/custom_screen.dart';
import 'package:classipod/features/music/search/model/search_model.dart';
import 'package:classipod/features/music/search/widgets/search_list_tile.dart';
import 'package:classipod/features/now_playing/provider/now_playing_details_provider.dart';
import 'package:classipod/features/online/online_catalogs.dart';
import 'package:classipod/features/online/online_library.dart';
import 'package:classipod/features/online/online_playback.dart';
import 'package:classipod/features/online/youtube_account.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

// region Online menu

bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

enum _OnlineItems {
  radio('Radio'),
  podcasts('Podcasts'),
  youTube('YouTube'),
  youTubePlaylists('YouTube Playlists'),
  myYouTube('My YouTube'),
  spotify('Spotify'),
  otherApp('Other App');

  final String title;
  const _OnlineItems(this.title);
}

/// Free internet sources: radio, podcasts, YouTube audio, and driving Spotify
/// or any other app's player from the click wheel.
class OnlineMenuScreen extends ConsumerStatefulWidget {
  const OnlineMenuScreen({super.key});

  @override
  ConsumerState createState() => _OnlineMenuScreenState();
}

class _OnlineMenuScreenState extends ConsumerState<OnlineMenuScreen>
    with CustomScreen {
  @override
  String get routeName => Routes.onlineMenu.name;

  @override
  List<_OnlineItems> get displayItems => [
    for (final item in _OnlineItems.values)
      // iOS doesn't let apps control another app's player.
      if (item != _OnlineItems.otherApp || !_isIOS) item,
  ];

  @override
  void onSelectPressed() => _open(displayItems[selectedDisplayItem]);

  void _open(_OnlineItems item) {
    setState(() => selectedDisplayItem = displayItems.indexOf(item));
    switch (item) {
      case _OnlineItems.radio:
        context.goNamed(Routes.radio.name);
      case _OnlineItems.podcasts:
        context.goNamed(Routes.podcasts.name);
      case _OnlineItems.youTube:
        context.goNamed(Routes.youTube.name);
      case _OnlineItems.youTubePlaylists:
        context.goNamed(Routes.youTubePlaylists.name);
      case _OnlineItems.myYouTube:
        context.goNamed(Routes.myYouTube.name);
      case _OnlineItems.spotify:
        context.goNamed(Routes.spotify.name);
      case _OnlineItems.otherApp:
        context.goNamed(Routes.otherApp.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Column(
        children: [
          Flexible(
            child: CupertinoScrollbar(
              controller: scrollController,
              child: ListView.builder(
                controller: scrollController,
                itemCount: displayItems.length,
                prototypeItem: const DisplayListTile(
                  text: '',
                  isSelected: false,
                ),
                itemBuilder: (context, index) => DisplayListTile(
                  text: displayItems[index].title,
                  isSelected: selectedDisplayItem == index,
                  onTap: () => _open(displayItems[index]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// endregion
// region Search + list screens (radio, podcasts, YouTube)

/// One online list: a search tile (typed with the wheel's letter bar), then
/// either search results or the "kept" list (presets, subscriptions, saved).
/// Select plays or opens; long-press stars / subscribes / saves.
class OnlineSearchScreen<T> extends ConsumerStatefulWidget {
  final String route;
  final Future<List<T>> Function(String query) search;
  final Future<List<T>> Function() kept;
  final Future<List<T>> Function()? browse;
  final MusicMetadata Function(T item, int index, bool starred) toMetadata;
  final bool Function(T item, List<T> kept) isKept;
  final Future<void> Function(T item) toggleKept;
  final Future<void> Function(BuildContext context, WidgetRef ref, List<T> items, int index) onSelect;

  const OnlineSearchScreen({
    super.key,
    required this.route,
    required this.search,
    required this.kept,
    required this.toMetadata,
    required this.isKept,
    required this.toggleKept,
    required this.onSelect,
    this.browse,
  });

  @override
  ConsumerState<OnlineSearchScreen<T>> createState() =>
      _OnlineSearchScreenState<T>();
}

class _OnlineSearchScreenState<T> extends ConsumerState<OnlineSearchScreen<T>>
    with CustomInputTextScreen {
  String _query = '';
  List<T>? _results;
  List<T> _kept = [];
  List<T> _browse = [];
  String? _status;
  Timer? _debounce;
  int _searchId = 0;

  @override
  String get inputText => _query;

  @override
  set inputText(String value) => _query = value;

  @override
  int get extraDisplayItems => 1;

  @override
  String get routeName => widget.route;

  /// What the list shows below the search tile.
  List<T> get _items {
    final results = _results;
    if (results != null) return results;
    final keptIds = _kept.toSet();
    return [..._kept, ..._browse.where((b) => !keptIds.contains(b) && !widget.isKept(b, _kept))];
  }

  @override
  List<MusicMetadata> get displayItems {
    final items = _items;
    return [
      for (var i = 0; i < items.length; i++)
        widget.toMetadata(items[i], i, widget.isKept(items[i], _kept)),
    ];
  }

  @override
  void initState() {
    super.initState();
    isInputTextBarActive = false;
    unawaited(_loadKept());
    final browse = widget.browse;
    if (browse != null) {
      unawaited(
        _run(() async {
          final list = await browse();
          if (mounted) setState(() => _browse = list);
        }),
      );
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadKept() async {
    final kept = await widget.kept();
    if (mounted) setState(() => _kept = kept);
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _status = 'Loading…');
    try {
      await job();
      if (mounted) setState(() => _status = null);
    } catch (e) {
      if (mounted) setState(() => _status = 'Couldn\'t load: $e');
    }
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 900), () {
      final id = ++_searchId;
      unawaited(
        _run(() async {
          final found = await widget.search(value);
          if (mounted && id == _searchId) setState(() => _results = found);
        }),
      );
    });
  }

  @override
  void seekBackwardLongPress() {
    if (isInputTextBarActive) {
      inputTextBarController.clearText();
      _onQueryChanged('');
    }
  }

  @override
  Future<void> onSelectAction() => _activate(selectedDisplayItem);

  Future<void> _activate(int displayIndex) async {
    setState(() => selectedDisplayItem = displayIndex);
    if (displayIndex == 0) {
      setState(() => isInputTextBarActive = !isInputTextBarActive);
      return;
    }
    final items = _items;
    final i = displayIndex - 1;
    if (i >= items.length) return;
    await widget.onSelect(context, ref, items, i);
  }

  @override
  void onSelectLongPress() => _toggle(selectedDisplayItem);

  Future<void> _toggle(int displayIndex) async {
    if (isInputTextBarActive || displayIndex == 0) return;
    final items = _items;
    final i = displayIndex - 1;
    if (i >= items.length) return;
    await widget.toggleKept(items[i]);
    await _loadKept();
  }

  @override
  Widget build(BuildContext context) {
    final items = displayItems;
    final playing = ref
        .watch(nowPlayingDetailsProvider.select((e) => e.currentMetadata))
        ?.identity;
    return CupertinoPageScaffold(
      resizeToAvoidBottomInset: false,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            children: [
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    _status!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: IpodTypography.metadata.copyWith(
                      color: context.appSecondaryTextColor,
                    ),
                  ),
                ),
              Flexible(
                child: CupertinoScrollbar(
                  controller: scrollController,
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: items.length + 1,
                    itemExtent: 54,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return SearchListTile(
                          searchResult: SearchResultsModel(
                            searchResultType: SearchResultType.defaultSearch,
                            result: _query,
                            count: items.length,
                          ),
                          isSelected: selectedDisplayItem == 0,
                          onTap: () => _activate(0),
                          onLongPress: () {},
                        );
                      }
                      final m = items[index - 1];
                      return AlbumArtSongListTile(
                        songMetadata: m,
                        isSelected: selectedDisplayItem == index,
                        isCurrentlyPlaying: playing == m.identity,
                        onTap: () => _activate(index),
                        onLongPress: () => _toggle(index),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          if (isInputTextBarActive)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: InputTextBar(
                inputTextBarController: inputTextBarController,
                onSearchTextChanged: _onQueryChanged,
              ),
            ),
        ],
      ),
    );
  }
}

String _starred(String name, bool starred) => starred ? '★ $name' : name;

class RadioScreen extends StatelessWidget {
  const RadioScreen({super.key});

  @override
  Widget build(BuildContext context) => OnlineSearchScreen<Station>(
    route: Routes.radio.name,
    search: OnlineCatalogs.searchStations,
    kept: OnlineLibrary.presets,
    browse: OnlineCatalogs.topStations,
    isKept: (s, kept) => kept.any((k) => k.uuid == s.uuid),
    toggleKept: OnlineLibrary.togglePreset,
    toMetadata: (s, i, starred) {
      final m = s.toMetadata(i);
      return m.copyWith(trackName: _starred(s.name, starred));
    },
    onSelect: (context, ref, items, index) async {
      unawaited(OnlineCatalogs.countClick(items[index].uuid));
      await playOnline(context, ref, [
        for (var i = 0; i < items.length; i++) items[i].toMetadata(i),
      ], index);
    },
  );
}

class PodcastsScreen extends StatelessWidget {
  const PodcastsScreen({super.key});

  @override
  Widget build(BuildContext context) => OnlineSearchScreen<Podcast>(
    route: Routes.podcasts.name,
    search: OnlineCatalogs.searchPodcasts,
    kept: OnlineLibrary.subscriptions,
    isKept: (p, kept) => kept.any((k) => k.feedUrl == p.feedUrl),
    toggleKept: OnlineLibrary.toggleSubscription,
    toMetadata: (p, i, starred) {
      final m = p.toMetadata(i);
      return m.copyWith(trackName: _starred(p.title, starred));
    },
    onSelect: (context, ref, items, index) async {
      context.goNamed(Routes.podcastEpisodes.name, extra: items[index]);
    },
  );
}

class YouTubeScreen extends StatelessWidget {
  const YouTubeScreen({super.key});

  @override
  Widget build(BuildContext context) => OnlineSearchScreen<YtVideo>(
    route: Routes.youTube.name,
    search: (query) async {
      final id = YouTubeAudio.videoId(query);
      if (id != null) return [await YouTubeAudio.video(id)];
      return YouTubeAudio.search(query);
    },
    kept: OnlineLibrary.savedVideos,
    isKept: (v, kept) => kept.any((k) => k.id == v.id),
    toggleKept: OnlineLibrary.toggleSaved,
    toMetadata: (v, i, starred) {
      final m = v.toMetadata(i);
      return m.copyWith(trackName: _starred(v.title, starred));
    },
    onSelect: (context, ref, items, index) => playOnline(context, ref, [
      for (var i = 0; i < items.length; i++) items[i].toMetadata(i),
    ], index),
  );
}

// endregion
// region Podcast episodes

class PodcastEpisodesScreen extends ConsumerStatefulWidget {
  final Podcast show;

  const PodcastEpisodesScreen({super.key, required this.show});

  @override
  ConsumerState createState() => _PodcastEpisodesScreenState();
}

class _PodcastEpisodesScreenState extends ConsumerState<PodcastEpisodesScreen>
    with CustomScreen {
  List<Episode> _episodes = [];
  String? _status = 'Loading episodes…';

  @override
  double get displayTileHeight => 54;

  @override
  String get routeName => Routes.podcastEpisodes.name;

  @override
  List<MusicMetadata> get displayItems => [
    for (var i = 0; i < _episodes.length; i++)
      _episodes[i].toMetadata(widget.show, i),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final list = await OnlineCatalogs.episodes(widget.show);
      if (mounted) {
        setState(() {
          _episodes = list;
          _status = list.isEmpty ? 'No episodes in this feed.' : null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Couldn\'t load: $e');
    }
  }

  @override
  Future<void> onSelectPressed() => _play(selectedDisplayItem);

  Future<void> _play(int index) async {
    if (index >= _episodes.length) return;
    setState(() => selectedDisplayItem = index);
    await playOnline(context, ref, displayItems, index);
  }

  @override
  Widget build(BuildContext context) {
    final items = displayItems;
    final playing = ref
        .watch(nowPlayingDetailsProvider.select((e) => e.currentMetadata))
        ?.identity;
    return CupertinoPageScaffold(
      child: Column(
        children: [
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _status!,
                style: IpodTypography.metadata.copyWith(
                  color: context.appSecondaryTextColor,
                ),
              ),
            ),
          Flexible(
            child: CupertinoScrollbar(
              controller: scrollController,
              child: ListView.builder(
                controller: scrollController,
                itemCount: items.length,
                itemExtent: 54,
                itemBuilder: (context, index) => AlbumArtSongListTile(
                  songMetadata: items[index],
                  isSelected: selectedDisplayItem == index,
                  isCurrentlyPlaying: playing == items[index].identity,
                  onTap: () => _play(index),
                  onLongPress: () {},
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// endregion
// region YouTube playlists (saved links and the signed-in account)

/// Shared look for the text-menu screens below: an optional status line (and
/// a big sign-in code), then iPod menu rows.
Widget _menuPage(
  BuildContext context, {
  required ScrollController scrollController,
  required List<String> rows,
  required int selected,
  required void Function(int index) onTap,
  String? status,
  String? code,
}) {
  final secondary = IpodTypography.metadata.copyWith(
    color: context.appSecondaryTextColor,
  );
  return CupertinoPageScaffold(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (status != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(status, maxLines: 4, style: secondary),
          ),
        if (code != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              code,
              textAlign: TextAlign.center,
              style: IpodTypography.title.copyWith(
                fontSize: 26,
                letterSpacing: 2,
              ),
            ),
          ),
        Flexible(
          child: CupertinoScrollbar(
            controller: scrollController,
            child: ListView.builder(
              controller: scrollController,
              itemCount: rows.length,
              prototypeItem: const DisplayListTile(text: '', isSelected: false),
              itemBuilder: (context, index) => DisplayListTile(
                text: rows[index],
                isSelected: selected == index,
                onTap: () => onTap(index),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Playlists kept by link. In YouTube or YouTube Music use Share > Copy link
/// on a playlist (it must be Public or Unlisted), then "Paste Playlist Link".
/// Hold select on a playlist to remove it.
class YouTubePlaylistsScreen extends ConsumerStatefulWidget {
  const YouTubePlaylistsScreen({super.key});

  @override
  ConsumerState createState() => _YouTubePlaylistsScreenState();
}

class _YouTubePlaylistsScreenState
    extends ConsumerState<YouTubePlaylistsScreen>
    with CustomScreen {
  List<YtPlaylist> _saved = [];
  String? _status;
  bool _busy = false;

  @override
  String get routeName => Routes.youTubePlaylists.name;

  @override
  List<String> get displayItems => [
    'Paste Playlist Link',
    for (final p in _saved) p.title,
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final saved = await OnlineLibrary.savedPlaylists();
    if (!mounted) return;
    setState(() {
      _saved = saved;
      if (saved.isEmpty) {
        _status =
            'Copy a playlist link in YouTube (Share > Copy link), '
            'then select Paste Playlist Link.';
      }
    });
  }

  @override
  Future<void> onSelectPressed() => _activate(selectedDisplayItem);

  Future<void> _activate(int index) async {
    setState(() => selectedDisplayItem = index);
    if (index == 0) return _paste();
    final i = index - 1;
    if (i >= _saved.length) return;
    context.goNamed(Routes.youTubePlaylist.name, extra: _saved[i]);
  }

  Future<void> _paste() async {
    if (_busy) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final id = YouTubeAudio.playlistId(text);
    if (!mounted) return;
    if (id == null) {
      setState(
        () => _status =
            'No playlist link copied. In YouTube open the playlist, '
            'then Share > Copy link.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Loading playlist…';
    });
    try {
      final playlist = await YouTubeAudio.playlist(id);
      await OnlineLibrary.addPlaylist(playlist);
      await _load();
      if (mounted) setState(() => _status = 'Added ${playlist.title}.');
    } catch (_) {
      if (mounted) {
        setState(
          () => _status =
              "Couldn't open that playlist. Set it to Public or Unlisted, "
              'or use My YouTube for private ones.',
        );
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void onSelectLongPress() => unawaited(_remove(selectedDisplayItem));

  Future<void> _remove(int index) async {
    final i = index - 1;
    if (i < 0 || i >= _saved.length) return;
    final playlist = _saved[i];
    await OnlineLibrary.removePlaylist(playlist.id);
    await _load();
    if (!mounted) return;
    setState(() {
      _status = 'Removed ${playlist.title}.';
      selectedDisplayItem = (index - 1).clamp(0, displayItems.length - 1);
    });
  }

  @override
  Widget build(BuildContext context) => _menuPage(
    context,
    scrollController: scrollController,
    rows: displayItems,
    selected: selectedDisplayItem,
    onTap: (i) => unawaited(_activate(i)),
    status: _status,
  );
}

/// The videos of one playlist: through the account for [YtPlaylist.mine]
/// ones (private works), otherwise read publicly.
class YouTubePlaylistScreen extends ConsumerStatefulWidget {
  final YtPlaylist playlist;
  final String route;

  const YouTubePlaylistScreen({
    super.key,
    required this.playlist,
    required this.route,
  });

  @override
  ConsumerState createState() => _YouTubePlaylistScreenState();
}

class _YouTubePlaylistScreenState extends ConsumerState<YouTubePlaylistScreen>
    with CustomScreen {
  List<YtVideo> _videos = [];
  String? _status = 'Loading…';

  @override
  double get displayTileHeight => 54;

  @override
  String get routeName => widget.route;

  @override
  List<MusicMetadata> get displayItems => [
    for (var i = 0; i < _videos.length; i++)
      _videos[i]
          .toMetadata(i)
          .copyWith(albumName: widget.playlist.title),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final p = widget.playlist;
    try {
      final list = p.mine
          ? await YouTubeAccount.playlistVideos(p.id)
          : await YouTubeAudio.playlistVideos(p.id);
      if (mounted) {
        setState(() {
          _videos = list;
          _status = list.isEmpty ? 'This playlist is empty.' : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _status = p.mine
              ? "Couldn't load: $e"
              : "Couldn't load. Is the playlist still Public or Unlisted?",
        );
      }
    }
  }

  bool _starting = false;

  @override
  Future<void> onSelectPressed() => _play(selectedDisplayItem);

  /// Says what's happening at each step, so a song that won't start shows
  /// why instead of silently doing nothing.
  Future<void> _play(int index) async {
    if (index >= _videos.length || _starting) return;
    final video = _videos[index];
    setState(() {
      selectedDisplayItem = index;
      _starting = true;
      _status = 'Getting audio for ${video.title}…';
    });
    try {
      // Resolve the stream first (it's cached for the player), so a video
      // YouTube won't serve fails here with a readable reason.
      await YouTubeAudio.audioUrl(video.id).timeout(
        const Duration(seconds: 45),
      );
      if (!mounted) return;
      setState(() => _status = 'Starting playback…');
      await playOnline(context, ref, displayItems, index).timeout(
        const Duration(seconds: 45),
      );
      if (!mounted) return;
      final error = ref.read(audioPlayerServiceProvider).error;
      setState(
        () => _status = error == null ? null : "Couldn't play: $error",
      );
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _status =
              'Timed out starting ${video.title}. Check the connection and '
              'try again.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _status = "Couldn't play ${video.title}: $e");
    } finally {
      _starting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = displayItems;
    final playing = ref
        .watch(nowPlayingDetailsProvider.select((e) => e.currentMetadata))
        ?.identity;
    return CupertinoPageScaffold(
      child: Column(
        children: [
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _status!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: IpodTypography.metadata.copyWith(
                  color: context.appSecondaryTextColor,
                ),
              ),
            ),
          Flexible(
            child: CupertinoScrollbar(
              controller: scrollController,
              child: ListView.builder(
                controller: scrollController,
                itemCount: items.length,
                itemExtent: 54,
                itemBuilder: (context, index) => AlbumArtSongListTile(
                  songMetadata: items[index],
                  isSelected: selectedDisplayItem == index,
                  isCurrentlyPlaying: playing == items[index].identity,
                  onTap: () => _play(index),
                  onLongPress: () {},
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The signed-in Google account's liked videos and playlists, private ones
/// included. Sign-in shows a code to enter at google.com/device.
class MyYouTubeScreen extends ConsumerStatefulWidget {
  const MyYouTubeScreen({super.key});

  @override
  ConsumerState createState() => _MyYouTubeScreenState();
}

class _MyYouTubeScreenState extends ConsumerState<MyYouTubeScreen>
    with CustomScreen {
  bool? _signedIn;
  DeviceCode? _code;
  List<YtPlaylist> _playlists = [];
  String? _status;

  static const _liked = YtPlaylist(
    id: YtPlaylist.likedId,
    title: 'Liked Videos',
    mine: true,
  );

  @override
  String get routeName => Routes.myYouTube.name;

  List<(String, Future<void> Function())> get _rows {
    final code = _code;
    if (code != null) {
      return [
        ('Open Google Sign-In Page', () => _openPage(code)),
        ('Cancel', _cancel),
      ];
    }
    return switch (_signedIn) {
      null => [],
      false => [('Sign In', _signIn)],
      true => [
        ('Liked Videos', () => _open(_liked)),
        for (final p in _playlists) (p.title, () => _open(p)),
        ('Refresh', _refresh),
        ('Sign Out', _signOut),
      ],
    };
  }

  @override
  List<String> get displayItems => [for (final row in _rows) row.$1];

  @override
  void initState() {
    super.initState();
    if (!YouTubeAccount.isConfigured) {
      _status =
          "This build doesn't have Google sign-in set up yet. "
          'See "My YouTube" in the README.';
      return;
    }
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _code = null; // stops the sign-in polling
    super.dispose();
  }

  Future<void> _refresh() async {
    final signedIn = await YouTubeAccount.isSignedIn();
    if (!mounted) return;
    setState(() {
      _signedIn = signedIn;
      _status = signedIn ? 'Loading your playlists…' : null;
    });
    if (!signedIn) return;
    try {
      final playlists = await YouTubeAccount.playlists();
      if (mounted) {
        setState(() {
          _playlists = playlists;
          _status = null;
        });
      }
    } catch (e) {
      final still = await YouTubeAccount.isSignedIn();
      if (mounted) {
        setState(() {
          _signedIn = still;
          _status = "$e";
        });
      }
    }
  }

  void _select(int index) {
    final rows = _rows;
    if (index >= rows.length) return;
    setState(() => selectedDisplayItem = index);
    unawaited(rows[index].$2());
  }

  @override
  void onSelectPressed() => _select(selectedDisplayItem);

  Future<void> _open(YtPlaylist playlist) async {
    context.goNamed(Routes.myYouTubePlaylist.name, extra: playlist);
  }

  Future<void> _signIn() async {
    setState(() => _status = 'Getting a sign-in code…');
    final DeviceCode code;
    try {
      code = await YouTubeAccount.startSignIn();
    } catch (e) {
      if (mounted) setState(() => _status = "Couldn't start sign-in: $e");
      return;
    }
    if (!mounted) return;
    setState(() {
      _code = code;
      selectedDisplayItem = 0;
      _status =
          'On any phone or computer go to google.com/device and enter this '
          'code, or select Open below:';
    });
    final ok = await YouTubeAccount.waitForApproval(
      code,
      isCancelled: () => !mounted || _code != code,
    );
    if (!mounted || _code != code) return;
    setState(() {
      _code = null;
      selectedDisplayItem = 0;
      _status = ok
          ? null
          : 'Sign-in was declined or the code expired. Select Sign In again.';
    });
    if (ok) await _refresh();
  }

  Future<void> _openPage(DeviceCode code) async {
    await Clipboard.setData(ClipboardData(text: code.userCode));
    if (mounted) {
      setState(
        () => _status =
            'Code copied. Paste it on the Google page, approve, '
            'then come back here.',
      );
    }
    await launchUrl(Uri.parse(code.url), mode: LaunchMode.externalApplication);
  }

  Future<void> _cancel() async {
    setState(() {
      _code = null;
      _status = null;
      selectedDisplayItem = 0;
    });
  }

  Future<void> _signOut() async {
    await YouTubeAccount.signOut();
    if (!mounted) return;
    setState(() {
      _signedIn = false;
      _playlists = [];
      _status = 'Signed out.';
      selectedDisplayItem = 0;
    });
  }

  @override
  Widget build(BuildContext context) => _menuPage(
    context,
    scrollController: scrollController,
    rows: displayItems,
    selected: selectedDisplayItem,
    onTap: _select,
    status: _status,
    code: _code?.userCode,
  );
}

// endregion
// region Spotify / other app remote

enum _RemoteAction { playPause, next, previous, openApp, access }

/// Drives another app's player from the click wheel: select = play/pause on
/// the first row, the seek buttons skip tracks.
class RemoteAppScreen extends ConsumerStatefulWidget {
  /// The app's package, or null for whatever other app is playing.
  final String? package;
  final String label;
  final String route;

  const RemoteAppScreen({
    super.key,
    required this.package,
    required this.label,
    required this.route,
  });

  @override
  ConsumerState createState() => _RemoteAppScreenState();
}

class _RemoteAppScreenState extends ConsumerState<RemoteAppScreen>
    with CustomScreen {
  RemoteMediaState _state = const RemoteMediaState();
  Timer? _poll;

  @override
  String get routeName => widget.route;

  @override
  List<_RemoteAction> get displayItems => [
    if (!_state.access) _RemoteAction.access,
    _RemoteAction.playPause,
    _RemoteAction.next,
    _RemoteAction.previous,
    _RemoteAction.openApp,
  ];

  String _label(_RemoteAction a) => switch (a) {
    _RemoteAction.playPause => _state.playing ? 'Pause' : 'Play',
    _RemoteAction.next => 'Next Track',
    _RemoteAction.previous => 'Previous Track',
    _RemoteAction.openApp =>
      widget.package == null
          ? 'Open ${_state.appName ?? 'App'}'
          : 'Open ${widget.label}',
    _RemoteAction.access =>
      _isIOS ? 'Connect to ${widget.label}' : 'Grant Notification Access',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final next = await RemoteMedia.state(widget.package);
    if (!mounted) return;
    // Keep the last cover when the bridge only sends it on change.
    setState(
      () => _state = next.art == null && next.artKey == _state.artKey
          ? RemoteMediaState(
              access: next.access,
              installed: next.installed,
              active: next.active,
              appName: next.appName,
              title: next.title,
              artist: next.artist,
              album: next.album,
              playing: next.playing,
              positionMs: next.positionMs,
              durationMs: next.durationMs,
              artKey: next.artKey,
              art: _state.art,
            )
          : next,
    );
  }

  @override
  Future<void> onSelectPressed() => _run(displayItems[selectedDisplayItem]);

  Future<void> _run(_RemoteAction action) async {
    setState(() => selectedDisplayItem = displayItems.indexOf(action));
    switch (action) {
      case _RemoteAction.playPause:
        await RemoteMedia.command(widget.package, 'toggle');
      case _RemoteAction.next:
        await RemoteMedia.command(widget.package, 'next');
      case _RemoteAction.previous:
        await RemoteMedia.command(widget.package, 'previous');
      case _RemoteAction.openApp:
        await RemoteMedia.openApp(widget.package);
      case _RemoteAction.access:
        await RemoteMedia.openAccess();
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _refresh();
  }

  @override
  Future<void> seekForward() => RemoteMedia.command(widget.package, 'next');

  @override
  Future<void> seekBackward() =>
      RemoteMedia.command(widget.package, 'previous');

  String get _headline {
    if (!_state.access) {
      if (_state.message != null) return _state.message!;
      return _isIOS
          ? 'Select Connect to link ${widget.label}.'
          : 'Classipod needs notification access to see ${widget.label}.';
    }
    if (!_state.installed) return '${widget.label} isn\'t installed.';
    if (!_state.active) {
      return widget.package == null
          ? 'Start music in any app and it shows up here.'
          : 'Nothing playing in ${widget.label}. Select Play to resume.';
    }
    return _state.title ?? 'Playing';
  }

  @override
  Widget build(BuildContext context) {
    final art = _state.art;
    final items = displayItems;
    return CupertinoPageScaffold(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: art != null
                      ? Image.memory(
                          art,
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        )
                      : Container(
                          width: 72,
                          height: 72,
                          color: CupertinoColors.systemGrey4,
                          child: const Icon(CupertinoIcons.music_note_2),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: IpodTypography.title.copyWith(
                          color: context.appPrimaryTextColor,
                        ),
                      ),
                      if (_state.active && _state.artist != null)
                        Text(
                          _state.artist!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: IpodTypography.metadata.copyWith(
                            color: context.appSecondaryTextColor,
                          ),
                        ),
                      if (_state.active)
                        Text(
                          [
                            _state.appName ?? widget.label,
                            if (_state.durationMs > 0)
                              '${_time(_state.positionMs)} / ${_time(_state.durationMs)}',
                          ].join(' · '),
                          style: IpodTypography.metadata.copyWith(
                            color: context.appSecondaryTextColor,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: CupertinoScrollbar(
              controller: scrollController,
              child: ListView.builder(
                controller: scrollController,
                itemCount: items.length,
                prototypeItem: const DisplayListTile(text: '', isSelected: false),
                itemBuilder: (context, index) => DisplayListTile(
                  text: _label(items[index]),
                  isSelected: selectedDisplayItem == index,
                  onTap: () => _run(items[index]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _time(int ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class SpotifyScreen extends StatelessWidget {
  const SpotifyScreen({super.key});

  @override
  Widget build(BuildContext context) => RemoteAppScreen(
    package: RemoteMedia.spotify,
    label: 'Spotify',
    route: Routes.spotify.name,
  );
}

class OtherAppScreen extends StatelessWidget {
  const OtherAppScreen({super.key});

  @override
  Widget build(BuildContext context) => RemoteAppScreen(
    package: null,
    label: 'the other app',
    route: Routes.otherApp.name,
  );
}

// endregion
