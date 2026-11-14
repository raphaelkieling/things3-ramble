@preconcurrency import AVFAudio
import Foundation
import os

// The tap hands off a fresh buffer and never mutates it after yielding.
struct CapturedAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

final class VoiceMeter: Sendable {
    static let barCount = 17
    private let history = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: barCount))
    var levels: [Float] { history.withLock { $0 } }

    func update(_ value: Float) {
        history.withLock {
            $0.removeFirst()
            $0.append(value)
        }
    }
}

@MainActor
final class AudioCapture {
    let meter = VoiceMeter()
    let stream: AsyncThrowingStream<CapturedAudio, Error>
    private let continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation
    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(160))
    }

    func start(format: AVAudioFormat? = nil, timing: CaptureTiming? = nil) throws {
        try Self.installTap(on: engine.inputNode, target: format, continuation: continuation, meter: meter, timing: timing)
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            stop()
            throw RambleError(tr("Confira a entrada de áudio nos Ajustes do Sistema."))
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [continuation] _ in
            continuation.finish(throwing: RambleError(tr("A entrada de áudio mudou durante a captura.")))
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if tapInstalled {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        continuation.finish()
    }

    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        target: AVAudioFormat?,
        continuation: AsyncThrowingStream<CapturedAudio, Error>.Continuation,
        meter: VoiceMeter, timing: CaptureTiming?
    ) throws {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = target ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw RambleError(tr("Nenhum microfone disponível. Confira a entrada de áudio do Mac."))
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            if let timing {
                let received = ContinuousClock.now
                timing.mark("first_buffer", at: received, once: true)
                if time.isHostTimeValid {
                    let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    let audioStart = AVAudioTime.seconds(forHostTime: time.hostTime)
                    timing.mark("audio_origin", at: received.advanced(by: .seconds(audioStart - now)), once: true)
                }
            }
            do {
                let pcm = try convert(buffer, with: converter)
                guard pcm.frameLength > 0 else { return }
                updateMeter(meter, from: pcm)

                if case .dropped = continuation.yield(CapturedAudio(buffer: pcm)) {
                    continuation.finish(throwing: RambleError(tr("A transcrição não acompanhou a gravação.")))
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private nonisolated static func updateMeter(_ meter: VoiceMeter, from pcm: AVAudioPCMBuffer) {
        let count = Int(pcm.frameLength)
        let sum: Float
        if let channel = pcm.int16ChannelData?.pointee {
            sum = (0..<count).reduce(0) { total, index in
                let value = Float(channel[index * pcm.stride]) / 32_768
                return total + value * value
            }
        } else if let channel = pcm.floatChannelData?.pointee {
            sum = (0..<count).reduce(0) { total, index in
                let value = channel[index * pcm.stride]
                return total + value * value
            }
        } else {
            return
        }
        let decibels = 10 * log10(max(sum / Float(count), 0.00000001))
        meter.update(pow(max(0, min(1, (decibels + 55) / 43)), 1.35))
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let format = converter.outputFormat
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RambleError(tr("Não foi possível preparar o áudio."))
        }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !provided else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            throw RambleError(tr("A entrada de áudio mudou durante a captura."))
        }
        return output
    }
}
