//
//  SpeechAnalyzerManager.swift
//  WhisperPoC
//
//  Created by Satoshi MATSUMOTO on 2025/12/16.
//

import Foundation
import AVFoundation
import Speech

// MARK: - SpeechAnalyzer管理クラス
@Observable
class SpeechAnalyzerManager: NSObject {
    // MARK: - 公開プロパティ
    var state: WhisperState = .idle
    var statusMessage: String = "初期化前"
    var selectedLocale: Locale = Locale(identifier: "ja-JP")
    var memoryUsage: UInt64 = 0
    var memoryUpdatedAt: Date = Date()

    // 録音関連
    var recordingState: RecordingState = .idle
    var recordingDuration: TimeInterval = 0
    var playbackCurrentTime: TimeInterval = 0

    // 文字起こし関連
    var isTranscribing: Bool = false
    var transcriptionResult: String = ""
    var transcriptionTime: TimeInterval = 0

    // MARK: - 非公開プロパティ
    private var speechTranscriber: SpeechTranscriber?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var memoryTimer: Timer?

    // 録音ファイルのURL
    var recordingURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("recording_sa.m4a")
    }

    // MARK: - 初期化
    override init() {
        super.init()
        memoryUsage = getMemoryUsage()
        startMemoryTimer()
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
        memoryUpdatedAt = Date()
    }

    // 時刻フォーマット（HH:mm:ss）
    func formatTimeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
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

    // MARK: - モデル解放
    func reset() {
        speechTranscriber = nil
        state = .idle
        recordingState = .idle
        transcriptionResult = ""
        transcriptionTime = 0
        statusMessage = "モデルを解放しました"
        updateMemoryUsage()
    }

    // MARK: - SpeechAnalyzer初期化メソッド
    func initialize() async {
        await MainActor.run {
            self.state = .initializing
            self.statusMessage = "SpeechAnalyzer を初期化中..."
        }

        do {
            // 言語サポート確認（言語コードで比較）
            let supportedLocales = await SpeechTranscriber.supportedLocales
            let selectedLanguage = selectedLocale.language.languageCode?.identifier ?? ""

            // サポートされている言語を探す
            let matchedLocale = supportedLocales.first { locale in
                locale.language.languageCode?.identifier == selectedLanguage
            }

            guard let targetLocale = matchedLocale else {
                let supportedList = supportedLocales.map { $0.identifier }.joined(separator: ", ")
                await MainActor.run {
                    self.state = .error("言語がサポートされていません")
                    self.statusMessage = "エラー: \(selectedLocale.identifier) は未サポート\nサポート: \(supportedList)"
                }
                return
            }

            // サポートされているロケールを使用
            await MainActor.run {
                self.statusMessage = "言語: \(targetLocale.identifier) を使用..."
            }

            // SpeechTranscriber を作成
            let transcriber = SpeechTranscriber(
                locale: targetLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )

            // モデルがインストールされているか確認
            let installedLocales = await SpeechTranscriber.installedLocales
            let isInstalled = installedLocales.contains { locale in
                locale.language.languageCode?.identifier == selectedLanguage
            }

            if !isInstalled {
                await MainActor.run {
                    self.statusMessage = "モデルをダウンロード中..."
                }

                // モデルダウンロード
                if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await downloader.downloadAndInstall()
                }
            }

            // 実際に使用するロケールを保存
            await MainActor.run {
                self.selectedLocale = targetLocale
                self.speechTranscriber = transcriber
                self.state = .ready
                self.statusMessage = "SpeechAnalyzer 準備完了!"
                self.updateMemoryUsage()
            }

        } catch {
            await MainActor.run {
                self.state = .error(error.localizedDescription)
                self.statusMessage = "エラー: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 録音開始
    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            statusMessage = "オーディオセッション設定エラー: \(error.localizedDescription)"
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.record()

            recordingState = .recording
            recordingDuration = 0
            statusMessage = "録音中..."

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
        guard speechTranscriber != nil else {
            await MainActor.run {
                statusMessage = "SpeechAnalyzerが初期化されていません"
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
            // 新しいトランスクライバーを作成（各転写セッションで新規作成が必要）
            // 初期化時に確認済みのロケールを使用
            let sessionTranscriber = SpeechTranscriber(
                locale: selectedLocale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: []
            )

            // SpeechAnalyzer でファイルを転写
            let analyzer = SpeechAnalyzer(modules: [sessionTranscriber])

            // 結果を収集するタスク
            let transcriptionTask = Task {
                var result = ""
                for try await segment in sessionTranscriber.results {
                    if segment.isFinal {
                        result += String(segment.text.characters)
                    }
                }
                return result
            }

            // 音声ファイルを開く
            let audioFile = try AVAudioFile(forReading: recordingURL)

            // 音声ファイルを分析
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }

            let result = try await transcriptionTask.value
            let endTime = Date()
            let elapsed = endTime.timeIntervalSince(startTime)

            await MainActor.run {
                self.transcriptionResult = result.isEmpty ? "(文字起こし結果なし)" : result
                self.transcriptionTime = elapsed
                self.isTranscribing = false
                self.statusMessage = String(format: "文字起こし完了 (%.2f秒)", elapsed)
                self.updateMemoryUsage()
            }

        } catch {
            await MainActor.run {
                transcriptionResult = "エラー: \(error.localizedDescription)"
                isTranscribing = false
                statusMessage = "文字起こしエラー"
                updateMemoryUsage()
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension SpeechAnalyzerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackTimer?.invalidate()
        playbackTimer = nil

        playbackCurrentTime = 0
        recordingState = .recorded
        statusMessage = "再生完了"
    }
}
