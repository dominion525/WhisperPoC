//
//  WhisperManager.swift
//  WhisperPoC
//
//  Created by Satoshi MATSUMOTO on 2025/12/16.
//

import Foundation
import WhisperKit

// MARK: - 初期化状態を表す列挙型
enum WhisperState {
    case idle           // 初期状態
    case downloading    // モデルダウンロード中
    case loading        // モデル読み込み中
    case ready          // 準備完了
    case error(String)  // エラー発生
}

// MARK: - WhisperKit管理クラス
@Observable
class WhisperManager {
    // MARK: - 公開プロパティ
    var state: WhisperState = .idle
    var statusMessage: String = "初期化前"

    // MARK: - 非公開プロパティ
    private var whisperKit: WhisperKit?

    // MARK: - 初期化メソッド
    func initialize() async {
        // 状態をダウンロード中に更新
        await MainActor.run {
            self.state = .downloading
            self.statusMessage = "モデルをダウンロード中..."
        }

        do {
            // WhisperKitの初期化（小さいモデルを使用）
            // tiny モデルは約75MB、初回ダウンロードに数分かかる場合あり
            let config = WhisperKitConfig(model: "tiny")

            await MainActor.run {
                self.state = .loading
                self.statusMessage = "モデルを読み込み中..."
            }

            let kit = try await WhisperKit(config)

            // 初期化成功
            await MainActor.run {
                self.whisperKit = kit
                self.state = .ready
                self.statusMessage = "初期化完了! WhisperKitが使用可能です"
            }

        } catch {
            // エラーハンドリング
            await MainActor.run {
                self.state = .error(error.localizedDescription)
                self.statusMessage = "エラー: \(error.localizedDescription)"
            }
        }
    }
}
