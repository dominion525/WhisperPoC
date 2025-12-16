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
    case downloading    // モデルダウンロード中
    case loading        // モデル読み込み中
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

// MARK: - WhisperKit管理クラス
@Observable
class WhisperManager: NSObject {
    // MARK: - 公開プロパティ
    var state: WhisperState = .idle
    var statusMessage: String = "初期化前"

    // 録音関連
    var recordingState: RecordingState = .idle
    var recordingDuration: TimeInterval = 0
    var playbackCurrentTime: TimeInterval = 0

    // MARK: - 非公開プロパティ
    private var whisperKit: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?

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

    // MARK: - WhisperKit初期化メソッド
    func initialize() async {
        await MainActor.run {
            self.state = .downloading
            self.statusMessage = "モデルをダウンロード中..."
        }

        do {
            let config = WhisperKitConfig(model: "tiny")

            await MainActor.run {
                self.state = .loading
                self.statusMessage = "モデルを読み込み中..."
            }

            let kit = try await WhisperKit(config)

            await MainActor.run {
                self.whisperKit = kit
                self.state = .ready
                self.statusMessage = "初期化完了! WhisperKitが使用可能です"
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
        // オーディオセッションの設定
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            statusMessage = "オーディオセッション設定エラー: \(error.localizedDescription)"
            return
        }

        // 録音設定
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
