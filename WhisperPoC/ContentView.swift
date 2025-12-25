//
//  ContentView.swift
//  WhisperPoC
//
//  Created by Satoshi MATSUMOTO on 2025/12/16.
//

import SwiftUI

// MARK: - エンジン種別
enum EngineType: String, CaseIterable {
    case whisperKit = "WhisperKit"
    case speechAnalyzer = "SpeechAnalyzer"
}

struct ContentView: View {
    // MARK: - 状態管理
    @State private var selectedEngine: EngineType = .whisperKit
    @State private var whisperManager = WhisperManager()
    @State private var speechAnalyzerManager = SpeechAnalyzerManager()
    @State private var benchmarkManager = BenchmarkManager()

    // MARK: - ビュー本体
    var body: some View {
        VStack(spacing: 16) {
            // タイトル
            Text("SpeechPoC")
                .font(.title)
                .fontWeight(.bold)

            // エンジン切り替え
            Picker("エンジン", selection: $selectedEngine) {
                ForEach(EngineType.allCases, id: \.self) { engine in
                    Text(engine.rawValue).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // ステータスメッセージ
            Text(currentStatusMessage)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Divider()

            // エンジン別の初期化セクション
            if selectedEngine == .whisperKit {
                whisperInitSection
            } else {
                speechAnalyzerInitSection
            }

            // 準備完了したら録音セクションを表示
            if isEngineReady {
                Divider()
                recordingSection

                // 録音完了後に文字起こしセクションを表示
                if currentRecordingState == .recorded || currentRecordingState == .playing {
                    Divider()
                    transcriptionSection
                }

                Divider()
                benchmarkSection
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - ベンチマークセクション
    private var benchmarkSection: some View {
        VStack(spacing: 15) {
            Text("ベンチマーク")
                .font(.headline)

            // 状態表示
            HStack {
                Text(benchmarkStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: thermalStateIcon)
                        .foregroundColor(thermalStateColor)
                    Text(thermalStateText)
                        .font(.caption)
                        .foregroundColor(thermalStateColor)
                }
            }

            // 実行/停止ボタン
            HStack(spacing: 20) {
                Button(action: {
                    Task {
                        benchmarkManager.configure(
                            whisperManager: whisperManager,
                            speechAnalyzerManager: speechAnalyzerManager,
                            engine: selectedEngine
                        )
                        await benchmarkManager.runBenchmark()
                    }
                }) {
                    HStack {
                        if isBenchmarkRunning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("実行")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(canStartBenchmark ? Color.blue : Color.gray)
                    .cornerRadius(8)
                }
                .disabled(!canStartBenchmark)

                // キャンセルボタン
                if isBenchmarkRunning {
                    Button(action: {
                        benchmarkManager.cancel()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                    }
                }

                // リセットボタン
                if case .completed = benchmarkManager.state {
                    Button(action: {
                        benchmarkManager.reset()
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                    }
                }

                if case .error = benchmarkManager.state {
                    Button(action: {
                        benchmarkManager.reset()
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                    }
                }
            }

            // 進捗バー
            if case .processing(let current, let total, _) = benchmarkManager.state {
                ProgressView(value: Double(current), total: Double(total))
                    .padding(.horizontal)
                Text("\(current) / \(total) ファイル処理中")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 結果一覧
            if !benchmarkManager.results.isEmpty {
                benchmarkResultsView
            }

            // サマリー
            if case .completed = benchmarkManager.state {
                benchmarkSummaryView
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var benchmarkResultsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("処理結果:")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(benchmarkManager.results) { result in
                        HStack {
                            // ステータスアイコン
                            benchmarkStatusIcon(for: result.status)
                                .frame(width: 20)

                            // ファイル名
                            Text(result.fileName)
                                .font(.caption)
                                .lineLimit(1)

                            Spacer()

                            // 処理時間
                            if let time = result.processingTime {
                                Text(String(format: "%.2fs", time))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            // CER
                            if let cer = result.cer {
                                Text(String(format: "CER: %.1f%%", cer * 100))
                                    .font(.caption)
                                    .foregroundColor(cerColor(cer))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private var benchmarkSummaryView: some View {
        VStack(spacing: 8) {
            Divider()

            HStack {
                Text("合計処理時間:")
                Spacer()
                Text(String(format: "%.2f秒", benchmarkManager.totalProcessingTime))
                    .fontWeight(.bold)
            }

            if let avgCER = benchmarkManager.averageCER {
                HStack {
                    Text("平均CER:")
                    Spacer()
                    Text(String(format: "%.1f%%", avgCER * 100))
                        .fontWeight(.bold)
                        .foregroundColor(cerColor(avgCER))
                }
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func benchmarkStatusIcon(for status: BenchmarkFileResult.FileStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.gray)
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.blue)
        case .transcribing:
            Image(systemName: "waveform")
                .foregroundColor(.orange)
        case .uploading:
            Image(systemName: "arrow.up.circle")
                .foregroundColor(.purple)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private func cerColor(_ cer: Double) -> Color {
        if cer < 0.05 { return .green }
        if cer < 0.10 { return .orange }
        return .red
    }

    private var canStartBenchmark: Bool {
        guard isEngineReady else { return false }
        switch benchmarkManager.state {
        case .idle, .completed, .error:
            return true
        default:
            return false
        }
    }

    private var isBenchmarkRunning: Bool {
        switch benchmarkManager.state {
        case .fetchingFiles, .processing:
            return true
        default:
            return false
        }
    }

    private var benchmarkStatusText: String {
        switch benchmarkManager.state {
        case .idle:
            return "待機中"
        case .fetchingFiles:
            return "ファイルリスト取得中..."
        case .processing(let current, let total, let phase):
            let phaseText: String
            switch phase {
            case .downloading:
                phaseText = "ダウンロード中"
            case .transcribing:
                phaseText = "文字起こし中"
            case .uploading:
                phaseText = "結果送信中"
            }
            return "\(phaseText) (\(current)/\(total))"
        case .completed:
            return "完了"
        case .error(let message):
            return "エラー: \(message)"
        }
    }

    private var thermalStateText: String {
        benchmarkManager.thermalStateString(benchmarkManager.thermalState)
    }

    private var thermalStateIcon: String {
        switch benchmarkManager.thermalState {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "thermometer.sun.fill"
        @unknown default: return "thermometer"
        }
    }

    private var thermalStateColor: Color {
        switch benchmarkManager.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    // MARK: - 現在のエンジンの状態
    private var isEngineReady: Bool {
        switch selectedEngine {
        case .whisperKit:
            if case .ready = whisperManager.state { return true }
            return false
        case .speechAnalyzer:
            if case .ready = speechAnalyzerManager.state { return true }
            return false
        }
    }

    private var currentStatusMessage: String {
        switch selectedEngine {
        case .whisperKit:
            return whisperManager.statusMessage
        case .speechAnalyzer:
            return speechAnalyzerManager.statusMessage
        }
    }

    private var currentRecordingState: RecordingState {
        switch selectedEngine {
        case .whisperKit:
            return whisperManager.recordingState
        case .speechAnalyzer:
            return speechAnalyzerManager.recordingState
        }
    }

    // MARK: - WhisperKit初期化セクション
    private var whisperInitSection: some View {
        VStack(spacing: 15) {
            // モデル選択
            HStack {
                Text("モデル:")
                    .font(.subheadline)
                Picker("モデル", selection: $whisperManager.selectedModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isWhisperPickerDisabled)
            }

            HStack(spacing: 20) {
                // 状態アイコン
                whisperStateIcon
                    .font(.system(size: 40))

                // 初期化ボタン
                Button(action: {
                    Task {
                        await whisperManager.initialize()
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

                // リセットボタン（初期化完了後に表示）
                if case .ready = whisperManager.state {
                    Button(action: {
                        whisperManager.reset()
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 20))
                            .foregroundColor(.red)
                    }
                }

                // ローディング
                if isWhisperLoading {
                    ProgressView()
                }
            }

            // メモリ使用量（常に表示）
            Text("メモリ使用量: \(whisperManager.formatMemory(whisperManager.memoryUsage)) (\(whisperManager.formatTimeOfDay(whisperManager.memoryUpdatedAt)))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - SpeechAnalyzer初期化セクション
    private var speechAnalyzerInitSection: some View {
        VStack(spacing: 15) {
            // 言語選択
            HStack {
                Text("言語:")
                    .font(.subheadline)
                Picker("言語", selection: Binding(
                    get: { speechAnalyzerManager.selectedLocale.identifier },
                    set: { speechAnalyzerManager.selectedLocale = Locale(identifier: $0) }
                )) {
                    Text("日本語").tag("ja-JP")
                    Text("English").tag("en-US")
                }
                .pickerStyle(.menu)
                .disabled(isSpeechAnalyzerPickerDisabled)
            }

            HStack(spacing: 20) {
                // 状態アイコン
                speechAnalyzerStateIcon
                    .font(.system(size: 40))

                // 初期化ボタン
                Button(action: {
                    Task {
                        await speechAnalyzerManager.initialize()
                    }
                }) {
                    Text(speechAnalyzerButtonTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(speechAnalyzerButtonColor)
                        .cornerRadius(8)
                }
                .disabled(isSpeechAnalyzerButtonDisabled)

                // リセットボタン（初期化完了後に表示）
                if case .ready = speechAnalyzerManager.state {
                    Button(action: {
                        speechAnalyzerManager.reset()
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 20))
                            .foregroundColor(.red)
                    }
                }

                // ローディング
                if isSpeechAnalyzerLoading {
                    ProgressView()
                }
            }

            // メモリ使用量
            Text("メモリ使用量: \(speechAnalyzerManager.formatMemory(speechAnalyzerManager.memoryUsage)) (\(speechAnalyzerManager.formatTimeOfDay(speechAnalyzerManager.memoryUpdatedAt)))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 録音セクション（共通）
    private var recordingSection: some View {
        VStack(spacing: 20) {
            // 時間表示
            Text(timeDisplay)
                .font(.system(size: 48, weight: .light, design: .monospaced))

            // 録音/再生ボタン
            HStack(spacing: 40) {
                // 録音ボタン
                Button(action: {
                    if selectedEngine == .whisperKit {
                        if whisperManager.recordingState == .recording {
                            whisperManager.stopRecording()
                        } else {
                            whisperManager.startRecording()
                        }
                    } else {
                        if speechAnalyzerManager.recordingState == .recording {
                            speechAnalyzerManager.stopRecording()
                        } else {
                            speechAnalyzerManager.startRecording()
                        }
                    }
                }) {
                    Image(systemName: recordButtonIcon)
                        .font(.system(size: 50))
                        .foregroundColor(recordButtonColor)
                }
                .disabled(currentRecordingState == .playing)

                // 再生ボタン（録音完了後のみ表示）
                if currentRecordingState == .recorded || currentRecordingState == .playing {
                    Button(action: {
                        if selectedEngine == .whisperKit {
                            if whisperManager.recordingState == .playing {
                                whisperManager.stopPlayback()
                            } else {
                                whisperManager.startPlayback()
                            }
                        } else {
                            if speechAnalyzerManager.recordingState == .playing {
                                speechAnalyzerManager.stopPlayback()
                            } else {
                                speechAnalyzerManager.startPlayback()
                            }
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

    // MARK: - 文字起こしセクション（共通）
    private var transcriptionSection: some View {
        VStack(spacing: 15) {
            // 文字起こしボタン
            Button(action: {
                Task {
                    if selectedEngine == .whisperKit {
                        await whisperManager.transcribe()
                    } else {
                        await speechAnalyzerManager.transcribe()
                    }
                }
            }) {
                HStack {
                    if currentIsTranscribing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "text.bubble")
                    }
                    Text(currentIsTranscribing ? "文字起こし中..." : "文字起こし")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .background(currentIsTranscribing ? Color.gray : Color.purple)
                .cornerRadius(10)
            }
            .disabled(currentIsTranscribing || currentRecordingState == .playing)

            // 処理時間表示
            if currentTranscriptionTime > 0 {
                let speedRatio = currentRecordingDuration / currentTranscriptionTime
                Text(String(format: "処理時間: %.2f秒 (%.1fx)", currentTranscriptionTime, speedRatio))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 結果表示エリア
            if !currentTranscriptionResult.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("文字起こし結果:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        // コピーボタン
                        Button(action: {
                            UIPasteboard.general.string = currentTranscriptionResult
                        }) {
                            Label("コピー", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                    }

                    ScrollView {
                        Text(currentTranscriptionResult)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                    .frame(maxHeight: 150)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - 現在のエンジンの文字起こし関連プロパティ
    private var currentIsTranscribing: Bool {
        selectedEngine == .whisperKit ? whisperManager.isTranscribing : speechAnalyzerManager.isTranscribing
    }

    private var currentTranscriptionResult: String {
        selectedEngine == .whisperKit ? whisperManager.transcriptionResult : speechAnalyzerManager.transcriptionResult
    }

    private var currentTranscriptionTime: TimeInterval {
        selectedEngine == .whisperKit ? whisperManager.transcriptionTime : speechAnalyzerManager.transcriptionTime
    }

    private var currentRecordingDuration: TimeInterval {
        selectedEngine == .whisperKit ? whisperManager.recordingDuration : speechAnalyzerManager.recordingDuration
    }

    // MARK: - WhisperKit関連のコンピューテッドプロパティ

    private var whisperStateIcon: some View {
        Group {
            switch whisperManager.state {
            case .idle:
                Image(systemName: "waveform.circle")
                    .foregroundColor(.gray)
            case .initializing:
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.blue)
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
        switch whisperManager.state {
        case .idle:
            return "初期化"
        case .initializing:
            return "初期化中..."
        case .ready:
            return "初期化完了"
        case .error:
            return "再試行"
        }
    }

    private var whisperButtonColor: Color {
        switch whisperManager.state {
        case .idle: return .blue
        case .initializing: return .gray
        case .ready: return .green
        case .error: return .orange
        }
    }

    private var isWhisperButtonDisabled: Bool {
        switch whisperManager.state {
        case .initializing, .ready:
            return true
        case .idle, .error:
            return false
        }
    }

    private var isWhisperLoading: Bool {
        switch whisperManager.state {
        case .initializing:
            return true
        default:
            return false
        }
    }

    private var isWhisperPickerDisabled: Bool {
        switch whisperManager.state {
        case .initializing, .ready:
            return true
        case .idle, .error:
            return false
        }
    }

    // MARK: - SpeechAnalyzer関連のコンピューテッドプロパティ

    private var speechAnalyzerStateIcon: some View {
        Group {
            switch speechAnalyzerManager.state {
            case .idle:
                Image(systemName: "waveform.circle")
                    .foregroundColor(.gray)
            case .initializing:
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.blue)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
    }

    private var speechAnalyzerButtonTitle: String {
        switch speechAnalyzerManager.state {
        case .idle:
            return "初期化"
        case .initializing:
            return "初期化中..."
        case .ready:
            return "初期化完了"
        case .error:
            return "再試行"
        }
    }

    private var speechAnalyzerButtonColor: Color {
        switch speechAnalyzerManager.state {
        case .idle: return .blue
        case .initializing: return .gray
        case .ready: return .green
        case .error: return .orange
        }
    }

    private var isSpeechAnalyzerButtonDisabled: Bool {
        switch speechAnalyzerManager.state {
        case .initializing, .ready:
            return true
        case .idle, .error:
            return false
        }
    }

    private var isSpeechAnalyzerLoading: Bool {
        switch speechAnalyzerManager.state {
        case .initializing:
            return true
        default:
            return false
        }
    }

    private var isSpeechAnalyzerPickerDisabled: Bool {
        switch speechAnalyzerManager.state {
        case .initializing, .ready:
            return true
        case .idle, .error:
            return false
        }
    }

    // MARK: - 録音関連のコンピューテッドプロパティ

    private var timeDisplay: String {
        switch currentRecordingState {
        case .idle:
            return "00:00"
        case .recording:
            return whisperManager.formatTime(currentRecordingDuration)
        case .recorded:
            return "\(whisperManager.formatTime(0))/\(whisperManager.formatTime(currentRecordingDuration))"
        case .playing:
            return "\(whisperManager.formatTime(currentPlaybackTime))/\(whisperManager.formatTime(currentRecordingDuration))"
        }
    }

    private var currentPlaybackTime: TimeInterval {
        selectedEngine == .whisperKit ? whisperManager.playbackCurrentTime : speechAnalyzerManager.playbackCurrentTime
    }

    private var recordButtonIcon: String {
        switch currentRecordingState {
        case .recording:
            return "stop.circle.fill"
        default:
            return "record.circle"
        }
    }

    private var recordButtonColor: Color {
        switch currentRecordingState {
        case .recording:
            return .red
        default:
            return .red.opacity(0.8)
        }
    }

    private var playButtonIcon: String {
        switch currentRecordingState {
        case .playing:
            return "stop.circle.fill"
        default:
            return "play.circle.fill"
        }
    }

    private var recordingStateText: String {
        switch currentRecordingState {
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
