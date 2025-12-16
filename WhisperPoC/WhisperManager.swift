//
//  WhisperManager.swift
//  WhisperPoC
//
//  Created by Satoshi MATSUMOTO on 2025/12/16.
//

import Foundation
import AVFoundation
import WhisperKit

// MARK: - 初期化状態を表す列挙型
enum WhisperState {
    case idle           // 初期状態
    case initializing   // 初期化中（ダウンロード＋読み込み）
    case ready          // 準備完了
    case error(String)  // エラー発生
}

// MARK: - 録音状態を表す列挙型
enum RecordingState {
    case idle           // 待機中
    case recording      // 録音中
    case recorded       // 録音完了
    case playing        // 再生中
}

// MARK: - モデル選択
enum WhisperModel: String, CaseIterable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case largev3 = "large-v3"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (~75MB)"
        case .base: return "Base (~140MB)"
        case .small: return "Small (~460MB)"
        case .medium: return "Medium (~1.5GB)"
        case .largev3: return "Large-v3 (~3GB)"
        }
    }
}

// MARK: - WhisperKit管理クラス
@Observable
class WhisperManager: NSObject {
    // MARK: - 公開プロパティ
    var state: WhisperState = .idle
    var statusMessage: String = "初期化前"
    var selectedModel: WhisperModel = .tiny
    var memoryUsage: UInt64 = 0  // メモリ使用量（バイト）

    // 録音関連
    var recordingState: RecordingState = .idle
    var recordingDuration: TimeInterval = 0
    var playbackCurrentTime: TimeInterval = 0

    // 文字起こし関連
    var isTranscribing: Bool = false
    var transcriptionResult: String = ""
    var transcriptionTime: TimeInterval = 0

    // MARK: - 非公開プロパティ
    private var whisperKit: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var memoryTimer: Timer?

    // 録音ファイルのURL
    var recordingURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("recording.m4a")
    }

    // MARK: - 時間フォーマット
    func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - メモリ使用量取得
    func getMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }

    // メモリ使用量を更新
    func updateMemoryUsage() {
        memoryUsage = getMemoryUsage()
    }

    // メモリ監視タイマー開始（5秒ごと）
    private func startMemoryTimer() {
        memoryTimer?.invalidate()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateMemoryUsage()
            }
        }
    }

    // メモリ監視タイマー停止
    private func stopMemoryTimer() {
        memoryTimer?.invalidate()
        memoryTimer = nil
    }

    // MARK: - モデル解放
    func reset() {
        whisperKit = nil
        state = .idle
        recordingState = .idle
        transcriptionResult = ""
        transcriptionTime = 0
        statusMessage = "モデルを解放しました"
        updateMemoryUsage()
    }

    // MARK: - WhisperKit初期化メソッド
    func initialize() async {
        let modelName = selectedModel.rawValue

        await MainActor.run {
            self.state = .initializing
            self.statusMessage = "\(selectedModel.displayName) を初期化中..."
        }

        do {
            let config = WhisperKitConfig(model: modelName)
            let kit = try await WhisperKit(config)

            await MainActor.run {
                self.whisperKit = kit
                self.statusMessage = "ウォームアップ中..."
            }

            // ウォームアップ実行
            await warmup()

            let memory = getMemoryUsage()

            await MainActor.run {
                self.state = .ready
                self.memoryUsage = memory
                self.statusMessage = "初期化完了! WhisperKitが使用可能です"
                self.startMemoryTimer()
            }

        } catch {
            await MainActor.run {
                self.state = .error(error.localizedDescription)
                self.statusMessage = "エラー: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - ウォームアップ（初回推論のコンパイルを事前実行）
    private func warmup() async {
        guard let whisperKit = whisperKit,
              let warmupURL = Bundle.main.url(forResource: "warmup", withExtension: "m4a") else {
            return
        }

        do {
            let options = DecodingOptions(language: "ja")
            _ = try await whisperKit.transcribe(audioPath: warmupURL.path, decodeOptions: options)
        } catch {
            // ウォームアップ失敗は無視（本番の文字起こしには影響しない）
            print("Warmup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 録音開始
    func startRecording() {
        // オーディオセッションの設定
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            statusMessage = "オーディオセッション設定エラー: \(error.localizedDescription)"
            return
        }

        // 録音設定（AAC 16kHz モノラル）
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,  // WhisperKitは16kHzを推奨
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.record()

            recordingState = .recording
            recordingDuration = 0
            statusMessage = "録音中..."

            // タイマーで録音時間を更新
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    self.recordingDuration = self.audioRecorder?.currentTime ?? 0
                }
            }

        } catch {
            statusMessage = "録音開始エラー: \(error.localizedDescription)"
        }
    }

    // MARK: - 録音停止
    func stopRecording() {
        audioRecorder?.stop()
        recordingTimer?.invalidate()
        recordingTimer = nil

        recordingState = .recorded
        statusMessage = "録音完了: \(formatTime(recordingDuration))"
    }

    // MARK: - 再生開始
    func startPlayback() {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: recordingURL)
            audioPlayer?.delegate = self
            audioPlayer?.play()

            recordingState = .playing
            playbackCurrentTime = 0
            statusMessage = "再生中..."

            // タイマーで再生位置を更新
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    self.playbackCurrentTime = self.audioPlayer?.currentTime ?? 0
                }
            }

        } catch {
            statusMessage = "再生エラー: \(error.localizedDescription)"
        }
    }

    // MARK: - 再生停止
    func stopPlayback() {
        audioPlayer?.stop()
        playbackTimer?.invalidate()
        playbackTimer = nil

        playbackCurrentTime = 0
        recordingState = .recorded
        statusMessage = "再生停止"
    }

    // MARK: - 文字起こし
    func transcribe() async {
        guard let whisperKit = whisperKit else {
            await MainActor.run {
                statusMessage = "WhisperKitが初期化されていません"
            }
            return
        }

        await MainActor.run {
            isTranscribing = true
            transcriptionResult = ""
            statusMessage = "文字起こし中..."
        }

        let startTime = Date()

        do {
            // 日本語を指定
            let options = DecodingOptions(language: "ja")
            let results = try await whisperKit.transcribe(audioPath: recordingURL.path, decodeOptions: options)
            let endTime = Date()
            let elapsed = endTime.timeIntervalSince(startTime)

            await MainActor.run {
                if let result = results.first {
                    transcriptionResult = result.text
                } else {
                    transcriptionResult = "(文字起こし結果なし)"
                }
                transcriptionTime = elapsed
                isTranscribing = false
                statusMessage = String(format: "文字起こし完了 (%.2f秒)", elapsed)
            }

        } catch {
            await MainActor.run {
                transcriptionResult = "エラー: \(error.localizedDescription)"
                isTranscribing = false
                statusMessage = "文字起こしエラー"
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension WhisperManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackTimer?.invalidate()
        playbackTimer = nil

        playbackCurrentTime = 0
        recordingState = .recorded
        statusMessage = "再生完了"
    }
}
