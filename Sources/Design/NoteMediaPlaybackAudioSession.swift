import AVFoundation

enum NoteVideoPlaybackAudioSession {
    static func configureForMediaPlayback() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.mixWithOthers]
        )
    }

    static func activateIfNeeded() {
        let audioSession = AVAudioSession.sharedInstance()
        configureForMediaPlayback()
        try? audioSession.setActive(true, options: [])
    }
}
