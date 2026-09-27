import Foundation
import AVFoundation

/// Plays a very short click with low latency (a pre-built buffer on an always-running audio engine).
final class ClickPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var ready = false

    init() {
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let frames = AVAudioFrameCount(sampleRate * 0.02)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                let t = Double(i) / sampleRate
                let envelope = exp(-t * 260.0)
                ch[i] = Float(sin(2.0 * Double.pi * 1800.0 * t) * envelope)
            }
        }
        buffer = buf
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            try engine.start()
            node.play()
            ready = true
        } catch {
            ready = false
        }
    }

    func click(volume: Float) {
        guard ready, let b = buffer else { return }
        node.volume = volume
        node.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }
}
