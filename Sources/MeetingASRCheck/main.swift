import Foundation
import MeetingCore

@main struct MeetingASRCheck {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            var options: [String: String] = [:]
            guard args.count % 2 == 0 else { throw CLIError.usage }
            for i in stride(from: 0, to: args.count, by: 2) {
                guard ["--runtime", "--model", "--wav", "--revision", "--manifest", "--backend"].contains(args[i]), options[args[i]] == nil else { throw CLIError.usage }
                options[args[i]] = args[i+1]
            }
            guard let runtime = options["--runtime"] else { throw CLIError.usage }
            let backend = options["--backend"] ?? "qwen"
            guard ["qwen", "sensevoice"].contains(backend) else { throw CLIError.usage }
            if options.keys.allSatisfy({ ["--runtime", "--backend"].contains($0) }) {
                let version = try QwenASREngine.probeRuntime(path: runtime)
                try emit(["runtimeVersion": version, "runtimePath": runtime, "evidence": "symbol-version-probe-only"])
                return
            }
            guard let model = options["--model"], let wav = options["--wav"], let revision = options["--revision"] else { throw CLIError.usage }
            var hashes: [String: String]?
            if let path = options["--manifest"] { hashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
            let attributes = try FileManager.default.attributesOfItem(atPath: wav)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 4_000_000 else { throw QwenASRError.audioTooLong }
            let pcm = try QwenPCM16WAV.parse(Data(contentsOf: URL(fileURLWithPath: wav)))
            if backend == "sensevoice" {
                let engine = SenseVoiceASREngine(configuration: SenseVoiceASRConfiguration(modelDirectory: URL(fileURLWithPath: model), runtimePath: runtime, revision: revision, maximumSeconds: 120, expectedSHA256: hashes))
                let result = try await engine.transcribe(samples: pcm, sampleRate: 16000)
                try await engine.shutdown()
                try emit(result)
            } else {
                let engine = QwenASREngine(configuration: QwenASRConfiguration(modelDirectory: URL(fileURLWithPath: model), runtimePath: runtime, revision: revision, maximumSeconds: 120, expectedSHA256: hashes))
                let result = try await engine.transcribe(samples: pcm, sampleRate: 16000)
                try await engine.shutdown()
                try emit(result)
            }
        } catch {
            try? emit(["error": String(describing: error)])
            exit(1)
        }
    }
    enum CLIError: Error { case usage }
    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
