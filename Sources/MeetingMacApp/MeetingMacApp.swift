import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeetingCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var job: TranscriptionJob?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await job?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct MeetingMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var job = TranscriptionJob()
    var body: some Scene {
        Window("Meeting Mac", id: "workspace") {
            WorkspaceView(job: job)
                .onAppear { delegate.job = job; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
                .onDisappear { job.cancel() }
        }
        .defaultSize(width: 1000, height: 740)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor struct WorkspaceView: View {
    let job: TranscriptionJob
    @State private var configuration = Self.loadConfiguration()
    @State private var audioURL: URL?
    @State private var showSettings = false
    @State private var exportError: String?
    private static let settingsKey = "MeetingMac.transcription.v1"
    private static func loadConfiguration() -> TranscriptionConfiguration {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode(TranscriptionConfiguration.self, from: data) { return saved }
        var initial = TranscriptionConfiguration()
        initial.worker = Bundle.main.resourceURL?.appendingPathComponent("FunASR/worker.py").path ?? ""
        let runtime = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libsherpa-onnx-c-api.dylib")
        if FileManager.default.fileExists(atPath: runtime.path) { initial.qwenRuntime = runtime.path }
        return initial
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("音频转写").font(.largeTitle.bold())
                    Text("本地处理 · 短音频工作台").foregroundStyle(.secondary)
                }
                Spacer()
                Button("模型设置", systemImage: "slider.horizontal.3") { showSettings = true }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("转写引擎", selection: $configuration.engine) {
                        ForEach(TranscriptionConfiguration.Engine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 330)
                    Text("仅支持不超过 30 秒的 PCM16 / 16 kHz / 单声道 WAV。其他格式请先转换。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("选择 WAV 音频…", systemImage: "waveform") { chooseAudio() }.disabled(job.isBusy)
                        Text(audioURL?.lastPathComponent ?? "尚未选择音频").lineLimit(1).truncationMode(.middle)
                            .help(audioURL?.path ?? "请选择本地 WAV 文件")
                        Spacer()
                        if job.isBusy {
                            Button("取消") { job.cancel() }
                        } else {
                            Button("开始转写") {
                                if let audioURL { job.start(configuration: configuration, audioURL: audioURL) }
                            }.buttonStyle(.borderedProminent)
                                .disabled(audioURL == nil || configuration.missingConfiguration != nil)
                        }
                    }
                    if let missing = configuration.missingConfiguration {
                        Label(missing, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    }
                    HStack(spacing: 10) {
                        if job.isBusy { ProgressView().controlSize(.small) }
                        Text(job.status).font(.callout)
                    }.accessibilityElement(children: .combine)
                    if let error = job.errorMessage { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("转写结果").font(.headline)
                Spacer()
                Button("复制", systemImage: "doc.on.doc") {
                    if let text = job.result?.text { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                }.disabled(job.result == nil)
                Button("导出文本…", systemImage: "square.and.arrow.up") { exportText() }.disabled(job.result == nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let result = job.result {
                        Text("结果音频：\(job.resultAudioURL?.lastPathComponent ?? "")").font(.caption).foregroundStyle(.secondary).help(job.resultAudioURL?.path ?? "")
                        Text(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未识别到语音" : result.text)
                            .font(.system(size: 18)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        Divider()
                        Text("本次结果来源").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(result.provenance).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text("完成转写后，真实识别文本与引擎来源将显示在这里。")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(18)
            }.background(.background).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Text("本版不含实时录音、长音频处理或会议总结。取消与关闭会等待本地任务释放资源。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(26).frame(minWidth: 820, minHeight: 620)
        .sheet(isPresented: $showSettings) { SettingsView(configuration: $configuration) }
        .onChange(of: configuration) { _, value in
            if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
    private func chooseAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.message = "PCM16 · 16 kHz · 单声道 · 最长 30 秒"
        if panel.runModal() == .OK { audioURL = panel.url }
    }
    private func exportText() {
        guard let text = job.result?.text else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "转写结果.txt"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do { try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value }
                catch { exportError = error.localizedDescription }
            }
        }
    }
}

@MainActor private struct SettingsView: View {
    @Binding var configuration: TranscriptionConfiguration
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("模型设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("设置仅保存在此 Mac。模型与 Python 环境需预先安装；应用不会下载模型或启动服务。任务开始后使用当时的设置。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox("Qwen · sherpa-onnx 1.13.7") {
                        VStack(spacing: 12) {
                            pathRow("模型目录", path: $configuration.qwenModel, directory: true)
                            pathRow("运行库 dylib", path: $configuration.qwenRuntime)
                            entry("模型版本 / revision", value: $configuration.qwenRevision)
                            Text("选择 Qwen3-ASR sherpa 导出目录，包含 ONNX 与 tokenizer 文件。版本填写实际使用的模型修订标识。")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(8)
                    }
                    GroupBox("FunASR · 本地 CPU worker") {
                        VStack(spacing: 12) {
                            pathRow("Python 可执行文件", path: $configuration.python)
                            pathRow("Worker 脚本", path: $configuration.worker)
                            pathRow("模型目录", path: $configuration.funModel, directory: true)
                            entry("Checkpoint 文件名", value: $configuration.checkpoint)
                            entry("模型版本 / revision", value: $configuration.funRevision)
                            Text("Python 需已安装兼容的 FunASR 依赖。Checkpoint 填模型目录内的相对文件名，例如 model.pt。")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(8)
                    }
                }
            }
        }.padding(24).frame(width: 760, height: 670)
    }
    private func entry(_ title: String, value: Binding<String>) -> some View {
        HStack { Text(title).frame(width: 154, alignment: .leading); TextField(title, text: value).textFieldStyle(.roundedBorder) }
    }
    private func pathRow(_ title: String, path: Binding<String>, directory: Bool = false) -> some View {
        HStack {
            entry(title, value: path)
            Button("浏览…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }
}
