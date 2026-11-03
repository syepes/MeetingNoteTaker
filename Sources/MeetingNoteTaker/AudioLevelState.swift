import SwiftUI

/// High-frequency values must not invalidate the shared application model.
@MainActor final class AudioLevelState: ObservableObject {
    struct Levels: Equatable { var microphone: Float = 0; var computer: Float = 0 }
    @Published private(set) var levels = Levels()
    func update(microphone: Float, computer: Float) {
        let next = Levels(microphone: microphone, computer: computer)
        if levels != next { levels = next }
    }
}

struct LiveAudioLevels: View {
    @ObservedObject var state: AudioLevelState
    var microphoneEnabled: Bool
    var body: some View {
        LevelRow(title: "Microphone", value: state.levels.microphone, enabled: microphoneEnabled)
        LevelRow(title: "Computer", value: state.levels.computer)
    }
}
