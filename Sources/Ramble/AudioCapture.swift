@preconcurrency import AVFAudio
import Foundation
import os

final class VoiceMeter: Sendable {
    private let amplitude = OSAllocatedUnfairLock(initialState: Float.zero)
    var level: Float { amplitude.withLock { $0 } }

    func update(_ value: Float) {
        amplitude.withLock { $0 = value }
    }
}

@MainActor
final class AudioCapture {
    let meter = VoiceMeter()
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(160))
    }

    func start() throws {
        try Self.installTap(on: engine.inputNode, continuation: continuation, meter: meter)
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            stop()
            throw RambleError("Confira a entrada de áudio nos Ajustes do Sistema.")
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [continuation] _ in
            continuation.finish(throwing: RambleError("A entrada de áudio mudou durante a captura."))
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
        meter.update(0)
    }

    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        meter: VoiceMeter
    ) throws {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw RambleError("Nenhum microfone disponível. Confira a entrada de áudio do Mac.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            do {
                let pcm = try convert(buffer, with: converter)
                guard let channel = pcm.int16ChannelData?.pointee, pcm.frameLength > 0 else { return }

                let samples = UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength))
                let sum = samples.reduce(Float.zero) { total, sample in
                    let value = Float(sample) / 32_768
                    return total + value * value
                }
                let decibels = 10 * log10(max(sum / Float(samples.count), 0.00000001))
                meter.update(pow(max(0, min(1, (decibels + 55) / 43)), 1.35))

                let data = Data(bytes: channel, count: samples.count * MemoryLayout<Int16>.size)
                if case .dropped = continuation.yield(data) {
                    continuation.finish(throwing: RambleError("A conexão ficou lenta demais para transmitir a gravação."))
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let format = converter.outputFormat
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RambleError("Não foi possível preparar o áudio.")
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
            throw RambleError("A entrada de áudio mudou durante a captura.")
        }
        return output
    }
}
