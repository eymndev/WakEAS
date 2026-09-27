import MusicKit

@MainActor
final class MusicAlarmPlayer {
    private let player = ApplicationMusicPlayer.shared
    private var currentSongID: String?

    func start(songID: String) async -> Bool {
        guard !songID.isEmpty, MusicAuthorization.currentStatus == .authorized else { return false }
        if currentSongID == songID {
            if player.state.playbackStatus == .playing { return true }
            do {
                try await player.play()
                return !Task.isCancelled
            } catch {
                currentSongID = nil
            }
        }
        do {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(songID))
            guard let song = try await request.response().items.first, !Task.isCancelled else { return false }
            player.queue = ApplicationMusicPlayer.Queue(for: [song])
            player.state.repeatMode = .one
            try await player.play()
            guard !Task.isCancelled else {
                player.stop()
                return false
            }
            currentSongID = songID
            return true
        } catch {
            player.stop()
            currentSongID = nil
            return false
        }
    }

    func stop() {
        player.stop()
        currentSongID = nil
    }
}
