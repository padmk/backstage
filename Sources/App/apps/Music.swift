// Music through its scripting dictionary: playback and the library.

import Foundation

private let target = "Music"

private let prelude = #"""
  const Music = Application('Music');
  const fail = (code, text) => { throw new Error(code + ': ' + text); };
  function playing() {
    const state = Music.playerState();
    const result = { state: state, volume: Music.soundVolume(), shuffle: Music.shuffleEnabled() };
    if (state !== 'stopped') {
      try {
        const track = Music.currentTrack;
        Object.assign(result, { track: track.name(), artist: track.artist(), album: track.album(), position: Math.round(Music.playerPosition()), duration: Math.round(track.duration()) });
      } catch (error) {}
    }
    return result;
  }
  """#

private func script(_ body: String) -> String { prelude + body }

private let nowPlaying = Operation(name: "now_playing", summary: "Read what is playing, the player state and the volume", effect: .reads, arguments: []) { _ in
  try dictionary(runScript(script("return playing();"), target: target), from: target)
}

private let control = Operation(
  name: "control", summary: "Play, pause, or skip to the next or previous track", effect: .changes,
  arguments: [Argument(name: "action", kind: .string, required: true, description: "What to do", allowed: ["play", "pause", "next", "previous"])]
) { arguments in
  try dictionary(runScript(script(#"""
    const before = playing();
    changeBegins({ action: args.action });
    if (args.action === 'play') Music.play();
    if (args.action === 'pause') Music.pause();
    if (args.action === 'next') Music.nextTrack();
    if (args.action === 'previous') Music.previousTrack();
    delay(0.3);
    const after = playing();
    after.verified = args.action === 'play' ? after.state === 'playing'
      : args.action === 'pause' ? after.state !== 'playing'
      : after.track !== before.track || after.position < before.position;
    return after;
    """#), arguments: arguments, target: target), from: target)
}

private let play = Operation(
  name: "play", summary: "Play a playlist by name, or the first library track matching a search", effect: .changes,
  arguments: [
    Argument(name: "playlist", kind: .string, required: false, description: "Exact playlist name, from list_playlists"),
    Argument(name: "search", kind: .string, required: false, description: "Song, artist or album to find in the library"),
  ]
) { arguments in
  guard (arguments["playlist"] == nil) != (arguments["search"] == nil) else {
    throw HelperError(code: "invalid_arguments", message: "Give either playlist or search.")
  }
  return try dictionary(runScript(script(#"""
    let wanted;
    if (args.playlist) {
      const list = Music.playlists.byName(args.playlist);
      try { list.name(); } catch (error) { fail('not_found', 'There is no playlist named ' + args.playlist + '.'); }
      changeBegins({ playlist: args.playlist });
      list.play();
    } else {
      const tracks = Music.search(Music.libraryPlaylists[0], { for: args.search });
      if (!tracks || tracks.length === 0) fail('not_found', 'Nothing in the library matches ' + args.search + '.');
      wanted = tracks[0].name();
      changeBegins({ track: wanted });
      tracks[0].play();
    }
    delay(0.5);
    const after = playing();
    after.verified = after.state === 'playing' && (wanted === undefined || after.track === wanted);
    return after;
    """#), arguments: arguments, target: target), from: target)
}

private let setVolume = Operation(
  name: "set_volume", summary: "Set Music's own volume, separate from the Mac's output volume", effect: .changes,
  arguments: [Argument(name: "level", kind: .integer, required: true, description: "0 to 100", minimum: 0, maximum: 100)]
) { arguments in
  try dictionary(runScript(script(#"""
    changeBegins({ level: args.level });
    Music.soundVolume = args.level;
    const after = playing();
    after.verified = after.volume === args.level;
    return after;
    """#), arguments: arguments, target: target), from: target)
}

private let listPlaylists = Operation(name: "list_playlists", summary: "List playlists by name", effect: .reads, arguments: [limitArgument]) { arguments in
  try dictionary(runScript(script(#"""
    const names = Music.userPlaylists.name();
    return { total: names.length, playlists: names.slice(0, args.limit) };
    """#), arguments: ["limit": limit(arguments)], target: target), from: target)
}

let musicKnowledge = AppKnowledge(
  bundleId: "com.apple.Music", name: "Music", scripted: true, summary: "Control playback, play playlists and library tracks, set Music's volume",
  pitfalls: [
    "Music starts if it is not running, to answer an operation, and may show its window behind the app you are in.",
    "search plays from the library only, not the Apple Music catalog.",
  ],
  operations: [nowPlaying, control, play, setVolume, listPlaylists])
