import Flutter
import UIKit
#if canImport(SpotifyiOS)
import SpotifyiOS
#endif

/// iOS side of the `classipod/remote_media` channel (see online_playback.dart).
///
/// Android reads any app's media session; iOS doesn't allow that, so this
/// drives Spotify through its App Remote SDK instead. Setup:
///  1. Add the SpotifyiOS SDK to the Runner target (see README).
///  2. Create an app at developer.spotify.com, add the redirect URI
///     `classipod-spotify://spotify-login-callback` and this bundle id.
///  3. Put the Client ID in Info.plist under `SpotifyClientID`.
/// Without the SDK this still compiles; the Spotify screen explains what's
/// missing instead of failing.
final class SpotifyRemoteBridge: NSObject {
  static let shared = SpotifyRemoteBridge()

  private static let appStoreURL =
    URL(string: "https://apps.apple.com/app/spotify/id324684580")!

  private var clientID: String? {
    let id = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String
    guard let id, !id.isEmpty, !id.hasPrefix("YOUR_") else { return nil }
    return id
  }

  private var redirectURL: URL? {
    (Bundle.main.object(forInfoDictionaryKey: "SpotifyRedirectURL") as? String)
      .flatMap(URL.init(string:))
  }

  private var isSpotifyInstalled: Bool {
    UIApplication.shared.canOpenURL(URL(string: "spotify:")!)
  }

  private var lastError: String?
  private var observers: [NSObjectProtocol] = []

  #if canImport(SpotifyiOS)
  private var playerState: SPTAppRemotePlayerState?
  private var stateReceivedAt = Date()
  private var artKey: String?
  private var art: Data?
  private var connecting = false

  private lazy var appRemote: SPTAppRemote? = {
    guard let clientID, let redirectURL else { return nil }
    let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirectURL)
    let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
    remote.delegate = self
    return remote
  }()
  #endif

  private override init() {
    super.init()
    let center = NotificationCenter.default
    // Spotify asks apps to drop the connection in the background and
    // reconnect when they come back.
    observers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil,
      queue: .main) { [weak self] _ in self?.reconnectIfAuthorized() })
    observers.append(center.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil,
      queue: .main) { [weak self] _ in self?.disconnect() })
  }

  // MARK: Flutter channel

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "classipod/remote_media", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let args = call.arguments as? [String: Any]
      let package = args?["package"] as? String
      switch call.method {
      case "state":
        result(self.state(package: package))
      case "command":
        if package != nil { self.command(args?["action"] as? String ?? "") }
        result(nil)
      case "openAccess":
        if package != nil { self.authorize() }
        result(nil)
      case "openApp":
        self.openSpotify()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func state(package: String?) -> [String: Any] {
    // "Other App" (no package): iOS has no API for another app's player.
    guard package != nil else {
      return ["access": false, "installed": true, "active": false,
              "message": "iPhone doesn't let apps control other music players."]
    }
    var m: [String: Any] = ["installed": isSpotifyInstalled]
    #if canImport(SpotifyiOS)
    guard let remote = appRemote else {
      m["access"] = false
      m["message"] = "Add your Spotify Client ID to Info.plist (SpotifyClientID)."
      return m
    }
    m["access"] = remote.isConnected
    if !remote.isConnected, let lastError { m["message"] = lastError }
    guard remote.isConnected, let s = playerState else {
      m["active"] = false
      return m
    }
    let track = s.track
    var position = s.playbackPosition
    if !s.isPaused {
      position += Int(Date().timeIntervalSince(stateReceivedAt) * 1000
        * Double(s.playbackSpeed))
    }
    let duration = Int(track.duration)
    m["active"] = true
    m["appName"] = "Spotify"
    m["title"] = track.name
    m["artist"] = track.artist.name
    m["album"] = track.album.name
    m["playing"] = !s.isPaused
    m["positionMs"] = duration > 0 ? min(position, duration) : position
    m["durationMs"] = duration
    if let artKey {
      m["artKey"] = artKey
      if let art { m["art"] = FlutterStandardTypedData(bytes: art) }
    }
    #else
    m["access"] = false
    m["message"] = "This build doesn't include the Spotify SDK."
    #endif
    return m
  }

  private func command(_ action: String) {
    #if canImport(SpotifyiOS)
    guard let remote = appRemote else { return }
    guard remote.isConnected, let player = remote.playerAPI else {
      // Not linked yet: Play wakes Spotify, resumes, and links in one step.
      if action == "toggle" || action == "play" { authorize() }
      return
    }
    switch action {
    case "toggle":
      if playerState?.isPaused == false { player.pause(nil) } else { player.resume(nil) }
    case "play": player.resume(nil)
    case "pause": player.pause(nil)
    case "next": player.skip(toNext: nil)
    case "previous": player.skip(toPrevious: nil)
    default: break
    }
    #endif
  }

  private func openSpotify() {
    let url = isSpotifyInstalled ? URL(string: "spotify:")! : Self.appStoreURL
    UIApplication.shared.open(url)
  }

  // MARK: Connection

  /// Opens Spotify to approve Classipod; Spotify starts playing and sends the
  /// user back with a token (see `handle(url:)`).
  private func authorize() {
    #if canImport(SpotifyiOS)
    guard let remote = appRemote else { return }
    guard isSpotifyInstalled else { return openSpotify() }
    lastError = nil
    _ = remote.authorizeAndPlayURI("")
    #endif
  }

  private func reconnectIfAuthorized() {
    #if canImport(SpotifyiOS)
    guard let remote = appRemote, !remote.isConnected, !connecting,
          remote.connectionParameters.accessToken != nil else { return }
    connecting = true
    remote.connect()
    #endif
  }

  private func disconnect() {
    #if canImport(SpotifyiOS)
    guard let remote = appRemote, remote.isConnected else { return }
    remote.disconnect()
    #endif
  }

  /// Called by SceneDelegate for incoming URLs. Returns true if it was the
  /// Spotify login callback.
  func handle(url: URL) -> Bool {
    guard let redirectURL, url.scheme == redirectURL.scheme else { return false }
    #if canImport(SpotifyiOS)
    guard let remote = appRemote else { return true }
    let params = remote.authorizationParameters(from: url)
    if let token = params?[SPTAppRemoteAccessTokenKey] {
      remote.connectionParameters.accessToken = token
      reconnectIfAuthorized()
    } else if let error = params?[SPTAppRemoteErrorDescriptionKey] {
      lastError = "Spotify: \(error)"
    }
    #endif
    return true
  }
}

#if canImport(SpotifyiOS)
extension SpotifyRemoteBridge: SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
  func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
    connecting = false
    lastError = nil
    appRemote.playerAPI?.delegate = self
    appRemote.playerAPI?.subscribe(toPlayerState: nil)
    appRemote.playerAPI?.getPlayerState { [weak self] result, _ in
      if let state = result as? SPTAppRemotePlayerState { self?.update(state) }
    }
  }

  func appRemote(_ appRemote: SPTAppRemote,
                 didFailConnectionAttemptWithError error: Error?) {
    connecting = false
    lastError = "Couldn't reach Spotify. Select Connect to try again."
  }

  func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
    connecting = false
    playerState = nil
  }

  func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
    update(playerState)
  }

  private func update(_ state: SPTAppRemotePlayerState) {
    playerState = state
    stateReceivedAt = Date()
    let key = state.track.uri
    guard key != artKey else { return }
    artKey = key
    art = nil
    appRemote?.imageAPI?.fetchImage(
      forItem: state.track, with: CGSize(width: 300, height: 300)
    ) { [weak self] result, _ in
      guard let self, self.artKey == key, let image = result as? UIImage else { return }
      self.art = image.jpegData(compressionQuality: 0.8)
    }
  }
}
#endif

/// Subclassed only to catch the Spotify login callback URL.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      _ = SpotifyRemoteBridge.shared.handle(url: context.url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let others = URLContexts.filter { !SpotifyRemoteBridge.shared.handle(url: $0.url) }
    if !others.isEmpty { super.scene(scene, openURLContexts: others) }
  }
}
