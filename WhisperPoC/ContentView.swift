//
//  ContentView.swift
//  WhisperPoC
//
//  Created by Satoshi MATSUMOTO on 2025/12/16.
//

import SwiftUI

struct ContentView: View {
    // MARK: - 状態管理
    @State private var manager = WhisperManager()

    // MARK: - ビュー本体
    var body: some View {
        VStack(spacing: 20) {
            // タイトル
            Text("WhisperPoC")
                .font(.title)
                .fontWeight(.bold)

            // ステータスメッセージ
            Text(manager.statusMessage)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Divider()

            // WhisperKit初期化セクション
            whisperInitSection

            // WhisperKitが準備完了したら録音セクションを表示
            if case .ready = manager.state {
                Divider()
                recordingSection
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - WhisperKit初期化セクション
    private var whisperInitSection: some View {
        HStack(spacing: 20) {
            // 状態アイコン
            whisperStateIcon
                .font(.system(size: 40))

            // 初期化ボタン
            Button(action: {
                Task {
                    await manager.initialize()
                }
            }) {
                Text(whisperButtonTitle)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(whisperButtonColor)
                    .cornerRadius(8)
            }
            .disabled(isWhisperButtonDisabled)

            // ローディング
            if isWhisperLoading {
                ProgressView()
            }
        }
    }

    // MARK: - 録音セクション
    private var recordingSection: some View {
        VStack(spacing: 20) {
            // 時間表示
            Text(timeDisplay)
                .font(.system(size: 48, weight: .light, design: .monospaced))

            // 録音/再生ボタン
            HStack(spacing: 40) {
                // 録音ボタン
                Button(action: {
                    if manager.recordingState == .recording {
                        manager.stopRecording()
                    } else {
                        manager.startRecording()
                    }
                }) {
                    Image(systemName: recordButtonIcon)
                        .font(.system(size: 50))
                        .foregroundColor(recordButtonColor)
                }
                .disabled(manager.recordingState == .playing)

                // 再生ボタン（録音完了後のみ表示）
                if manager.recordingState == .recorded || manager.recordingState == .playing {
                    Button(action: {
                        if manager.recordingState == .playing {
                            manager.stopPlayback()
                        } else {
                            manager.startPlayback()
                        }
                    }) {
                        Image(systemName: playButtonIcon)
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                    }
                }
            }

            // 状態テキスト
            Text(recordingStateText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - WhisperKit関連のコンピューテッドプロパティ

    private var whisperStateIcon: some View {
        Group {
            switch manager.state {
            case .idle:
                Image(systemName: "waveform.circle")
                    .foregroundColor(.gray)
            case .downloading:
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.blue)
            case .loading:
                Image(systemName: "cpu")
                    .foregroundColor(.orange)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
    }

    private var whisperButtonTitle: String {
        switch manager.state {
        case .idle:
            return "WhisperKit初期化"
        case .downloading:
            return "ダウンロード中..."
        case .loading:
            return "読み込み中..."
        case .ready:
            return "初期化完了"
        case .error:
            return "再試行"
        }
    }

    private var whisperButtonColor: Color {
        switch manager.state {
        case .idle: return .blue
        case .downloading, .loading: return .gray
        case .ready: return .green
        case .error: return .orange
        }
    }

    private var isWhisperButtonDisabled: Bool {
        switch manager.state {
        case .downloading, .loading, .ready:
            return true
        case .idle, .error:
            return false
        }
    }

    private var isWhisperLoading: Bool {
        switch manager.state {
        case .downloading, .loading:
            return true
        default:
            return false
        }
    }

    // MARK: - 録音関連のコンピューテッドプロパティ

    private var timeDisplay: String {
        switch manager.recordingState {
        case .idle:
            return "00:00"
        case .recording:
            return manager.formatTime(manager.recordingDuration)
        case .recorded:
            return "\(manager.formatTime(0))/\(manager.formatTime(manager.recordingDuration))"
        case .playing:
            return "\(manager.formatTime(manager.playbackCurrentTime))/\(manager.formatTime(manager.recordingDuration))"
        }
    }

    private var recordButtonIcon: String {
        switch manager.recordingState {
        case .recording:
            return "stop.circle.fill"
        default:
            return "record.circle"
        }
    }

    private var recordButtonColor: Color {
        switch manager.recordingState {
        case .recording:
            return .red
        default:
            return .red.opacity(0.8)
        }
    }

    private var playButtonIcon: String {
        switch manager.recordingState {
        case .playing:
            return "stop.circle.fill"
        default:
            return "play.circle.fill"
        }
    }

    private var recordingStateText: String {
        switch manager.recordingState {
        case .idle:
            return "録音ボタンを押して開始"
        case .recording:
            return "録音中... もう一度押して停止"
        case .recorded:
            return "録音完了"
        case .playing:
            return "再生中..."
        }
    }
}

#Preview {
    ContentView()
}
