//
//  BenchmarkManager.swift
//  WhisperPoC
//
//  Created by Claude on 2025/12/23.
//

import Foundation
import AVFoundation
import WhisperKit
import Speech
import UIKit

// MARK: - APIレスポンスモデル
struct AudioFileItem: Codable, Identifiable {
    let id: String
    let url: String
}

struct AudioFilesResponse: Codable {
    let audio_set_id: String
    let category: String
    let files: [AudioFileItem]
}

struct TranscriptionResultRequest: Codable {
    let file_id: String
    let engine_name: String
    let engine_version: String?
    let asr_model: String?
    let asr_model_version: String?
    let processing_time: Double?
    let environment_name: String?
    let environment_info: [String: String]?
    let transcribed_text: String?
    let memo: String?
}

struct TranscriptionResultResponse: Codable {
    let id: Int
    let status: String
    let file_id: String
    let cer: Double?
    let reference_length: Int?
    let hypothesis_length: Int?
    let hits: Int?
    let substitutions: Int?
    let deletions: Int?
    let insertions: Int?
    let created_at: String
}

// MARK: - ベンチマーク進捗状態
enum BenchmarkState: Equatable {
    case idle
    case fetchingFiles
    case processing(current: Int, total: Int, phase: ProcessingPhase)
    case completed
    case error(String)

    enum ProcessingPhase: Equatable {
        case downloading
        case transcribing
        case uploading
    }
}

// MARK: - 個別ファイルの処理結果
struct BenchmarkFileResult: Identifiable {
    let id: String
    let fileName: String
    var processingTime: TimeInterval?
    var transcribedText: String?
    var cer: Double?
    var status: FileStatus

    enum FileStatus: Equatable {
        case pending
        case downloading
        case transcribing
        case uploading
        case completed
        case error(String)
    }
}

// MARK: - エラー定義
enum BenchmarkError: LocalizedError {
    case fetchFailed(String)
    case downloadFailed(String)
    case uploadFailed(String)
    case engineNotReady
    case cancelled
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .fetchFailed(let message):
            return "ファイルリスト取得エラー: \(message)"
        case .downloadFailed(let message):
            return "ダウンロードエラー: \(message)"
        case .uploadFailed(let message):
            return "結果送信エラー: \(message)"
        case .engineNotReady:
            return "認識エンジンが準備できていません"
        case .cancelled:
            return "キャンセルされました"
        case .transcriptionFailed(let message):
            return "文字起こしエラー: \(message)"
        }
    }
}

// MARK: - BenchmarkManager
@Observable
class BenchmarkManager {
    // MARK: - 設定
    private let baseURL = "http://192.168.0.5:3000"
    private let audioSetId = "reazonspeech-small"
    private let category = "batch_01"

    // MARK: - 公開プロパティ
    var state: BenchmarkState = .idle
    var results: [BenchmarkFileResult] = []
    var totalProcessingTime: TimeInterval = 0
    var averageCER: Double?
    var thermalState: ProcessInfo.ThermalState = .nominal

    // MARK: - 依存関係
    private weak var whisperManager: WhisperManager?
    private weak var speechAnalyzerManager: SpeechAnalyzerManager?
    private var currentEngine: EngineType = .whisperKit

    // MARK: - 一時ファイル管理
    private var downloadedFiles: [String: URL] = [:]
    private var isCancelled = false

    // MARK: - 設定メソッド
    func configure(
        whisperManager: WhisperManager,
        speechAnalyzerManager: SpeechAnalyzerManager,
        engine: EngineType
    ) {
        self.whisperManager = whisperManager
        self.speechAnalyzerManager = speechAnalyzerManager
        self.currentEngine = engine
    }

    // MARK: - ベンチマーク実行
    func runBenchmark() async {
        isCancelled = false

        await MainActor.run {
            state = .fetchingFiles
            results = []
            totalProcessingTime = 0
            averageCER = nil
        }

        do {
            // 1. ファイルリスト取得
            let files = try await fetchAudioFiles()

            guard !isCancelled else {
                await MainActor.run { state = .idle }
                return
            }

            await MainActor.run {
                results = files.map { file in
                    let fileName = file.url.split(separator: "/").last.map(String.init) ?? file.id
                    return BenchmarkFileResult(
                        id: file.id,
                        fileName: fileName,
                        status: .pending
                    )
                }
            }

            // 2. 各ファイルを処理
            for (index, file) in files.enumerated() {
                guard !isCancelled else {
                    await MainActor.run { state = .idle }
                    cleanupDownloadedFiles()
                    return
                }

                // ダウンロード
                await MainActor.run {
                    state = .processing(current: index + 1, total: files.count, phase: .downloading)
                    updateFileStatus(fileId: file.id, status: .downloading)
                }

                let localURL = try await downloadAudioFile(file)
                downloadedFiles[file.id] = localURL

                guard !isCancelled else {
                    await MainActor.run { state = .idle }
                    cleanupDownloadedFiles()
                    return
                }

                // 文字起こし
                await MainActor.run {
                    state = .processing(current: index + 1, total: files.count, phase: .transcribing)
                    updateFileStatus(fileId: file.id, status: .transcribing)
                }

                let (text, time) = try await transcribeFile(at: localURL)

                guard !isCancelled else {
                    await MainActor.run { state = .idle }
                    cleanupDownloadedFiles()
                    return
                }

                // 結果送信
                await MainActor.run {
                    state = .processing(current: index + 1, total: files.count, phase: .uploading)
                    updateFileStatus(fileId: file.id, status: .uploading)
                }

                let response = try await uploadResult(fileId: file.id, text: text, processingTime: time)

                // 結果を保存 & 熱状態を更新
                await MainActor.run {
                    updateFileResult(
                        fileId: file.id,
                        processingTime: time,
                        transcribedText: text,
                        cer: response.cer,
                        status: .completed
                    )
                    totalProcessingTime += time
                    thermalState = ProcessInfo.processInfo.thermalState
                }
            }

            // 3. 完了処理
            await MainActor.run {
                state = .completed
                calculateAverageCER()
            }

            // 4. クリーンアップ
            cleanupDownloadedFiles()

        } catch {
            await MainActor.run {
                state = .error(error.localizedDescription)
            }
            cleanupDownloadedFiles()
        }
    }

    // MARK: - キャンセル
    func cancel() {
        isCancelled = true
    }

    // MARK: - リセット
    func reset() {
        isCancelled = false
        state = .idle
        results = []
        totalProcessingTime = 0
        averageCER = nil
        cleanupDownloadedFiles()
    }

    // MARK: - API通信

    private func fetchAudioFiles() async throws -> [AudioFileItem] {
        guard let url = URL(string: "\(baseURL)/api/v1/audio_sets/\(audioSetId)/files?category=\(category)") else {
            throw BenchmarkError.fetchFailed("Invalid URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BenchmarkError.fetchFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw BenchmarkError.fetchFailed("HTTP \(httpResponse.statusCode)")
        }

        let result = try JSONDecoder().decode(AudioFilesResponse.self, from: data)
        return result.files
    }

    private func downloadAudioFile(_ file: AudioFileItem) async throws -> URL {
        guard let url = URL(string: "\(baseURL)\(file.url)") else {
            throw BenchmarkError.downloadFailed("Invalid URL")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BenchmarkError.downloadFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw BenchmarkError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }

        // 拡張子を取得
        let fileExtension = (file.url as NSString).pathExtension

        // 一時ディレクトリに移動
        let tempDir = FileManager.default.temporaryDirectory
        let destURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        return destURL
    }

    private func uploadResult(
        fileId: String,
        text: String,
        processingTime: TimeInterval
    ) async throws -> TranscriptionResultResponse {
        guard let url = URL(string: "\(baseURL)/api/v1/transcription_results") else {
            throw BenchmarkError.uploadFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = TranscriptionResultRequest(
            file_id: fileId,
            engine_name: currentEngine.rawValue,
            engine_version: getEngineVersion(),
            asr_model: getASRModel(),
            asr_model_version: nil,
            processing_time: processingTime,
            environment_name: await getEnvironmentName(),
            environment_info: getEnvironmentInfo(),
            transcribed_text: text,
            memo: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        request.httpBody = try encoder.encode(body)

        // デバッグ: 送信内容をログ出力
        if let jsonString = String(data: request.httpBody!, encoding: .utf8) {
            print("📤 POST /api/v1/transcription_results")
            print("📝 transcribed_text: \(text)")
            print("📦 Request body:\n\(jsonString)")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BenchmarkError.uploadFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BenchmarkError.uploadFailed("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        return try JSONDecoder().decode(TranscriptionResultResponse.self, from: data)
    }

    // MARK: - 文字起こし

    private func transcribeFile(at url: URL) async throws -> (text: String, time: TimeInterval) {
        let startTime = Date()
        var transcribedText: String = ""

        switch currentEngine {
        case .whisperKit:
            transcribedText = try await transcribeWithWhisperKit(url: url)
        case .speechAnalyzer:
            transcribedText = try await transcribeWithSpeechAnalyzer(url: url)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return (transcribedText, elapsed)
    }

    private func transcribeWithWhisperKit(url: URL) async throws -> String {
        guard let manager = whisperManager,
              let whisperKit = manager.whisperKit else {
            throw BenchmarkError.engineNotReady
        }

        let options = DecodingOptions(language: "ja")
        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
        return results.first?.text ?? ""
    }

    private func transcribeWithSpeechAnalyzer(url: URL) async throws -> String {
        guard let manager = speechAnalyzerManager else {
            throw BenchmarkError.engineNotReady
        }

        return try await manager.transcribeFile(at: url)
    }

    // MARK: - ヘルパーメソッド

    private func updateFileStatus(fileId: String, status: BenchmarkFileResult.FileStatus) {
        if let index = results.firstIndex(where: { $0.id == fileId }) {
            results[index].status = status
        }
    }

    private func updateFileResult(
        fileId: String,
        processingTime: TimeInterval,
        transcribedText: String,
        cer: Double?,
        status: BenchmarkFileResult.FileStatus
    ) {
        if let index = results.firstIndex(where: { $0.id == fileId }) {
            results[index].processingTime = processingTime
            results[index].transcribedText = transcribedText
            results[index].cer = cer
            results[index].status = status
        }
    }

    private func calculateAverageCER() {
        let cerValues = results.compactMap { $0.cer }
        if !cerValues.isEmpty {
            averageCER = cerValues.reduce(0, +) / Double(cerValues.count)
        }
    }

    private func cleanupDownloadedFiles() {
        for (_, url) in downloadedFiles {
            try? FileManager.default.removeItem(at: url)
        }
        downloadedFiles.removeAll()
    }

    private func getEngineVersion() -> String? {
        switch currentEngine {
        case .whisperKit:
            return nil // WhisperKitのバージョン取得は複雑なのでnil
        case .speechAnalyzer:
            return nil
        }
    }

    private func getASRModel() -> String? {
        switch currentEngine {
        case .whisperKit:
            return whisperManager?.selectedModel.rawValue
        case .speechAnalyzer:
            return speechAnalyzerManager?.selectedLocale.identifier
        }
    }

    @MainActor
    private func getEnvironmentName() -> String {
        // デバイス名からスペースを削除
        let basename = UIDevice.current.name.replacingOccurrences(of: " ", with: "")

        // エンジン名（大文字）
        let engineName: String
        switch currentEngine {
        case .whisperKit:
            engineName = "WHISPERKIT"
        case .speechAnalyzer:
            engineName = "SPEECHANALYZER"
        }

        // モデル名
        let modelName: String
        switch currentEngine {
        case .whisperKit:
            modelName = whisperManager?.selectedModel.rawValue ?? "unknown"
        case .speechAnalyzer:
            modelName = speechAnalyzerManager?.selectedLocale.identifier ?? "unknown"
        }

        return "\(basename)-\(engineName)-\(modelName)"
    }

    private func getEnvironmentInfo() -> [String: String] {
        var info: [String: String] = [:]
        info["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        info["engine"] = currentEngine.rawValue
        if currentEngine == .whisperKit, let model = whisperManager?.selectedModel {
            info["model"] = model.rawValue
        }
        info["thermal_state"] = thermalStateString(ProcessInfo.processInfo.thermalState)
        return info
    }

    func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
