import AVFoundation
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

nonisolated enum CalculatorSound: String, CaseIterable, Identifiable, Sendable {
    case soft, pop, tick, chime
    var id: String { rawValue }
    var title: String {
        switch self { case .soft: "Soft Click"; case .pop: "Pop"; case .tick: "Tick"; case .chime: "Chime" }
    }
}

@MainActor
final class CalculatorButtonFeedback {
    static let shared = CalculatorButtonFeedback()
    private var players: [CalculatorSound: AVAudioPlayer] = [:]
    #if os(iOS)
    private static var impact: UIImpactFeedbackGenerator?
    #endif

    func play(_ sound: CalculatorSound, volume: Double) throws {
        guard volume.isFinite, volume > 0 else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        let audio = AVAudioSession.sharedInstance()
        // Do not replace an audio/video player's active playback/recording policy.
        if audio.category == .soloAmbient { try audio.setCategory(.ambient) }
        #elseif os(macOS)
        guard NSApp.isActive else { return }
        #endif
        let player: AVAudioPlayer
        if let cached = players[sound] { player = cached }
        else {
            player = try AVAudioPlayer(data: Self.wave(sound), fileTypeHint: AVFileType.wav.rawValue)
            players[sound] = player
        }
        player.volume = Float(min(1, max(0, volume)))
        player.currentTime = 0
        player.prepareToPlay()
        if !player.play() { throw VellixError.editorBridge("The calculator sound could not be played.") }
    }

    static func haptic(enabled: Bool) {
        #if os(iOS)
        guard enabled, UIApplication.shared.applicationState == .active else { return }
        let generator = impact ?? UIImpactFeedbackGenerator(style: .light)
        impact = generator
        generator.prepare(); generator.impactOccurred()
        #endif
    }

    static func copy(_ state: CalculatorState) {
        guard state.error.isEmpty, CalculatorState.isNumber(state.result) else { return }
        #if os(iOS)
        UIPasteboard.general.string = state.result
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.result, forType: .string)
        #endif
    }

    private nonisolated static func wave(_ sound: CalculatorSound) -> Data {
        let rate = 22_050
        let duration: Double = sound == .chime ? 0.16 : sound == .pop ? 0.07 : 0.04
        let count = Int(Double(rate) * duration)
        var data = Data()
        func bytes<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); bytes(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        bytes(UInt32(16)); bytes(UInt16(1)); bytes(UInt16(1)); bytes(UInt32(rate)); bytes(UInt32(rate * 2))
        bytes(UInt16(2)); bytes(UInt16(16)); data.append(contentsOf: "data".utf8); bytes(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(rate), progress = Double(index) / Double(count)
            let envelope = min(1, time / 0.002) * pow(1 - progress, sound == .chime ? 3 : 5)
            let frequency: Double
            switch sound { case .soft: frequency = 450; case .pop: frequency = 650 - progress * 400; case .tick: frequency = 1800; case .chime: frequency = 880 }
            let fundamental = sin(2 * Double.pi * frequency * time)
            let harmonic = sound == .chime ? sin(2 * Double.pi * 1320 * time) * 0.35 : 0
            bytes(Int16(max(-1, min(1, (fundamental + harmonic) * envelope * 0.45)) * Double(Int16.max)))
        }
        return data
    }
}
