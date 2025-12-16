# WhisperPoC

オンデバイス音声文字起こしのPoC（Proof of Concept）アプリです。

## 機能

- 音声録音・再生
- 2つの文字起こしエンジンを切り替え可能
  - WhisperKit: 複数モデルの選択（Tiny / Base / Small / Medium / Large-v3）
  - Apple SpeechAnalyzer: OS組み込みの音声認識
- リアルタイムメモリ使用量モニタリング
- 文字起こし結果のコピー

## 要件

- macOS（Xcode用）
- Xcode 26.0以上
- iOS 26.0以上の実機
- Apple Developer アカウント（実機テスト用）

## 注意事項

- SpeechAnalyzerはシミュレーターでは動作しません

## セットアップ

```bash
git clone git@github.com:dominion525/WhisperPoC.git
cd WhisperPoC
open WhisperPoC.xcodeproj
```

### Xcodeでの設定

1. プロジェクトを開く
2. **Signing & Capabilities** で自分の Apple ID / Team を選択
3. **Bundle Identifier** を一意の値に変更（例: `com.yourname.WhisperPoC`）
4. 実機を接続して実行

### 初回実行時の注意

- iPhone で「信頼されていないデベロッパ」と表示された場合:
  - 設定 → 一般 → VPN とデバイス管理 → デベロッパ App → 信頼

## 使い方

### WhisperKit

1. **モデル選択**: ドロップダウンからWhisperモデルを選択
   - Tiny (~75MB): 最速、精度低め
   - Base (~140MB): バランス型
   - Small (~460MB): 実用的な精度
   - Medium (~1.5GB): 高精度
   - Large-v3 (~3GB): 最高精度

2. **初期化**: 「初期化」ボタンをタップ
   - 初回はモデルのダウンロードが必要（数分かかる場合あり）
   - ダウンロード後、ウォームアップ処理が実行される

3. **録音**: 赤い録音ボタンをタップして録音開始/停止

4. **再生**: 青い再生ボタンで録音内容を確認

5. **文字起こし**: 「文字起こし」ボタンをタップ
   - 処理時間と速度倍率が表示される
   - 結果はコピーボタンでクリップボードにコピー可能

6. **リセット**: 矢印ボタンでモデルを解放し、別のモデルを選択可能

### SpeechAnalyzer

1. **言語選択**: ドロップダウンから言語を選択（日本語 / English）

2. **初期化**: 「初期化」ボタンをタップ
   - OS組み込みのモデルを使用するため、ダウンロード不要

3. **録音**: 赤い録音ボタンをタップして録音開始/停止

4. **再生**: 青い再生ボタンで録音内容を確認

5. **文字起こし**: 「文字起こし」ボタンをタップ
   - 処理時間と速度倍率が表示される
   - 結果はコピーボタンでクリップボードにコピー可能

6. **リセット**: 矢印ボタンでモデルを解放し、別の言語を選択可能

## 技術詳細

### 使用技術

- SwiftUI
- WhisperKit（Swift Package Manager経由）
- Speech framework（SpeechAnalyzer）
- AVFoundation（録音・再生）
- CoreML / Apple Neural Engine

### アーキテクチャ

```
WhisperPoC/
├── WhisperPoCApp.swift          # アプリエントリーポイント
├── ContentView.swift            # メインUI
├── WhisperManager.swift         # WhisperKit管理
├── SpeechAnalyzerManager.swift  # SpeechAnalyzer管理
└── warmup.m4a                   # ウォームアップ用音声ファイル
```

### パフォーマンス

- 初回の文字起こしはANE/GPUコンパイルのため遅い
- ウォームアップ処理により、ユーザーの初回文字起こしは高速化済み
- Release ビルドで最適なパフォーマンスを発揮

## ライセンス

MIT License

## 参考

- [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- [Whisper](https://github.com/openai/whisper)
