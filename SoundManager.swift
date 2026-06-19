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

        // Set higher output volume
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
            print("SoundManager: Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Different Sound Alerts

    /// Loud warning sound for speeding alerts - Enhanced for better audibility
    func playSpeedingAlert() {
        prepareEngineIfNeeded()
        let duration: Double = 0.8  // Longer duration for better attention
        let frequency: Double = 440 // A4 - Warning tone
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
            // More aggressive envelope for better attention
            let envelope = exp(-2.0 * t / duration) // Slower decay
            // Add some harmonic content for richer sound
            let fundamental = sin(twoPi * frequency * t)
            let harmonic = sin(twoPi * frequency * 2.0 * t) * 0.3 // Add second harmonic
            let sineWave = fundamental + harmonic
            let sample = Float(sineWave * envelope * Double(speedingVolume))
            channel[i] = sample
        }

        playBuffer(buffer)

        // Play a second, shorter beep after a brief pause for urgency
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.playSpeedingAlertFollowUp()
        }
    }

    /// Follow-up beep for speeding alert
    private func playSpeedingAlertFollowUp() {
        let duration: Double = 0.3
        let frequency: Double = 550 // Higher frequency for urgency
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
            let envelope = exp(-4.0 * t / duration) // Quick attack and decay
            let sineWave = sin(twoPi * frequency * t)
            let sample = Float(sineWave * envelope * Double(speedingVolume))
            channel[i] = sample
        }

        playBuffer(buffer)
    }

    /// Alert sound for going offline - Enhanced for better audibility
    func playOfflineAlert() {
        prepareEngineIfNeeded()
        let duration: Double = 0.6  // Longer duration
        let frequency: Double = 330 // E4 - Lower tone for offline
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
            // Slower decay for more noticeable sound
            let envelope = exp(-2.5 * t / duration)
            // Add some variation in frequency for more attention-grabbing sound
            let frequencyVariation = sin(twoPi * 2.0 * t) * 20.0 // Slight frequency modulation
            let sineWave = sin(twoPi * (frequency + frequencyVariation) * t)
            let sample = Float(sineWave * envelope * Double(offlineVolume))
            channel[i] = sample
        }

        playBuffer(buffer)

        // Play a second, different tone for offline alert
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.playOfflineAlertFollowUp()
        }
    }

    /// Follow-up tone for offline alert
    private func playOfflineAlertFollowUp() {
        let duration: Double = 0.4
        let frequency: Double = 280 // Even lower tone
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
            let envelope = exp(-3.0 * t / duration)
            let sineWave = sin(twoPi * frequency * t)
            let sample = Float(sineWave * envelope * Double(offlineVolume))
            channel[i] = sample
        }

        playBuffer(buffer)
    }

    /// Confirmation sound for going online - Enhanced for better audibility
    func playOnlineAlert() {
        prepareEngineIfNeeded()
        let duration: Double = 0.5  // Longer duration
        let frequency: Double = 660 // E5 - Higher tone for online
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
            // More gradual decay for pleasant confirmation sound
            let envelope = exp(-3.0 * t / duration)
            // Add harmonic content for richer, more pleasant sound
            let fundamental = sin(twoPi * frequency * t)
            let harmonic = sin(twoPi * frequency * 1.5 * t) * 0.2 // Add harmonic
            let sineWave = fundamental + harmonic
            let sample = Float(sineWave * envelope * Double(onlineVolume))
            channel[i] = sample
        }

        playBuffer(buffer)

        // Play a second, higher tone for online confirmation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.playOnlineAlertFollowUp()
        }
    }

    /// Follow-up tone for online alert
    private func playOnlineAlertFollowUp() {
        let duration: Double = 0.3
        let frequency: Double = 880 // A5 - Higher tone for confirmation
        let frameCount = AVAudioFrameCount(duration * audioFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / audioFormat.sampleRate
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
            print("SoundManager: Failed to set maximum volume: \(error)")
        }
    }
}
