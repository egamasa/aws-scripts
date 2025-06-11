# lambda-radiko

IPサイマル配信 ラジオ番組自動ダウンロードスクリプト for AWS Lambda

## 対応サービス

- radiko タイムフリー
- NHKラジオ らじる★らじる 聴き逃し番組

## 動作環境

- AWS Lambda (arm64)
- Ruby 3.3

## デプロイ

### FFmpeg バイナリの入手
ビルド実行前に、 https://www.johnvansickle.com/ffmpeg/ より **ARM64** 版の静的ビルドバイナリをダウンロードし、`layers/bin` ディレクトリ内に ffmpeg を配置する。

### デプロイ

```bash
sam build
sam deploy --guided
```

### パラメータ

- BucketName
  - 音声ファイルの保存先 S3 バケット名
- LogGroupName
  - ログの出力先ロググループ名
