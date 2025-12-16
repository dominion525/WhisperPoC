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
        VStack(spacing: 30) {
            // タイトル
            Text("WhisperKit 初期化確認")
                .font(.title)
                .fontWeight(.bold)

            // 状態表示アイコン
            statusIcon
                .font(.system(size: 60))

            // ステータスメッセージ
            Text(manager.statusMessage)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // 初期化ボタン
            Button(action: {
                Task {
                    await manager.initialize()
                }
            }) {
                Text(buttonTitle)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(buttonColor)
                    .cornerRadius(10)
            }
            .disabled(isButtonDisabled)
            .padding(.horizontal, 40)

            // ローディングインジケーター
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
        .padding()
    }

    // MARK: - コンピューテッドプロパティ

    /// 状態に応じたアイコンを返す
    private var statusIcon: some View {
        Group {
            switch manager.state {
            case .idle:
                Image(systemName: "waveform.circle")
                    .foregroundColor(.gray)
            case .downloading, .loading:
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

    /// ボタンのタイトル
    private var buttonTitle: String {
        switch manager.state {
        case .idle:
            return "WhisperKitを初期化"
        case .downloading, .loading:
            return "初期化中..."
        case .ready:
            return "初期化完了"
        case .error:
            return "再試行"
        }
    }

    /// ボタンの色
    private var buttonColor: Color {
        switch manager.state {
        case .idle:
            return .blue
        case .downloading, .loading:
            return .gray
        case .ready:
            return .green
        case .error:
            return .orange
        }
    }

    /// ボタンが無効かどうか
    private var isButtonDisabled: Bool {
        switch manager.state {
        case .downloading, .loading, .ready:
            return true
        case .idle, .error:
            return false
        }
    }

    /// ローディング中かどうか
    private var isLoading: Bool {
        switch manager.state {
        case .downloading, .loading:
            return true
        default:
            return false
        }
    }
}

#Preview {
    ContentView()
}
