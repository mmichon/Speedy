import Foundation
import AVFoundation

final class SoundManager {
    static let shared = SoundManager()

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isEnginePrepared = false
    private let audioFormat: AVAudioFormat

    // Volume levels for different alert types - All at 100% for maximum audibility
    private let speedingVolume: Float = 1.0      // Maximum volume for safety
    private let offlineVolume: Float = 1.0       // Maximum volume for connectivity issues
    private let onlineVolume: Float = 1.0        // Maximum volume for status changes

    private init() {
        let sampleRate: Double = 44100
        audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        audioEngine.attach(playerNode)
        let mainMixer = audioEngine.mainMixerNode
        audioEngine.connect(playerNode, to: mainMixer, format: audioFormat)

        // Set maximum output volume for watch
        mainMixer.outputVolume = 1.0

        prepareEngineIfNeeded()
    }

    private func prepareEngineIfNeeded() {
        guard !isEnginePrepared else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try audioEngine.start()
            isEnginePrepared = true
        } catch {
            print("WatchSoundManager: Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Different Sound Alerts

    /// Loud warning sound for speeding alerts
    func playSpeedingAlert() {
        prepareEngineIfNeeded()
        let duration: Double = 0.5  // Longer duration for watch
        let frequency: Double = 440  // A4 - Warning tone
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
            // Sharp attack, slower decay for warning sound
            let envelope = exp(-2.5 * t / duration)
            let sineWave = sin(twoPi * frequency * t)
            let sample = Float(sineWave * envelope * Double(speedingVolume))
            channel[i] = sample
        }

        playBuffer(buffer)
    }

    /// Alert sound for going offline
    func playOfflineAlert() {
        prepareEngineIfNeeded()
        let duration: Double = 0.4  // Longer duration for watch
        let frequency: Double = 330  // E4 - Lower tone for offline
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
            // Medium attack and decay
            let envelope = exp(-3.0 * t / duration)
            let sineWave = sin(twoPi * frequency * t)
            let sample = Float(sineWave * envelope * Double(offlineVolume))
            channel[i] = sample
        }

        playBuffer(buffer)
    }

    /// Confirmation sound for going online
    func playOnlineAlert() {
        prepareEngineIfNeeded()
        let duration: Double = 0.35 // Longer duration for watch
        let frequency: Double = 660  // E5 - Higher tone for online
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
            // Quick attack, quick decay for positive feedback
            let envelope = exp(-4.0 * t / duration)
            let sineWave = sin(twoPi * frequency * t)
            let sample = Float(sineWave * envelope * Double(onlineVolume))
            channel[i] = sample
        }

        playBuffer(buffer)
    }

    /// Legacy ping sound (kept for backward compatibility)
    func playPing() {
        playSpeedingAlert() // Use speeding alert as default ping
    }

    // MARK: - Private Helper Methods

    private func playBuffer(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            // No-op
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// Set system volume to maximum for alerts
    func setMaximumVolume() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("WatchSoundManager: Failed to set maximum volume: \(error)")
        }
    }
}
