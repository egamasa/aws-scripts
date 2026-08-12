# Lambdiko（らむじこ）

IPサイマルラジオ ダウンロードツール for AWS Lambda

## 対応サービス

- radiko タイムフリー
- NHKラジオ らじる★らじる 聴き逃し番組

## 動作環境

- AWS Lambda
  - arm64 アーキテクチャ
  - Ruby 3.4 ランタイム
- AWS SAM CLI（デプロイ時）

## デプロイ

### FFmpeg バイナリの入手

ビルド実行前に、 https://www.johnvansickle.com/ffmpeg/ より **ARM64** 版の静的ビルドバイナリをダウンロードし、`layers/bin` ディレクトリ内に ffmpeg および ffprobe を配置する。

### デプロイ

```bash
sam build
sam deploy --guided
```

### パラメータ

- BucketName
  - 音声ファイルの保存先 S3 バケット名
- LogGroupName
  - ログ出力先の CloudWatch ロググループ名
- NotifySnsTopicArn
  - ダウンロード完了通知 送信先SNSトピックARN
    - [discord-notify](../discord-notify/) をデプロイし、出力される `DiscordNotifyFunctionArn` を指定する想定

## 機能・使用方法

### デプロイされるLambda関数の一覧

- lambdiko-program-search
  - 番組検索
- lambdiko-radiko-download
  - radiko タイムフリー ダウンロード
- lambdiko-radiru-download
  - らじる★らじる 聴き逃し番組 ダウンロード

### lambdiko-program-search

番組表から指定条件に一致する番組を検索し、ダウンロード関数を呼び出す。

#### イベントパラメータ

- `station_id` 放送局ID
  - radiko： `TBS`, `QRR`, `FMT` など
  - らじる： `NHK` 固定
- `week` 検索対象曜日
  - `sun`, `mon`, `tue`, `wed`, `thu`, `fri`, `sat`
- `target` 検索対象フィールド
  - radiko： `title`, `pfm`, `desc`, `info`
  - らじる： `title` のみ指定可能
- `keyword` 検索キーワード
- `title` カスタムタイトル（省略可）
  - 保存時のファイル名に反映される。同じ番組を定期録音する場合に、ファイル名を揃えることができる。省略時は番組表から取得した番組タイトルをファイル名に使用する。
- `today` 検索対象曜日に当日を含むか
  - デフォルト： `true`
- `test` テストモード（検索結果のみ通知、ダウンロード実行しない）
  - デフォルト： `false`

#### 実行例

- 検索条件をJSONファイルで定義

  ```json
  // event.json
  {
    "title": "NISSAN あ、安部礼司 ～BEYOND THE AVERAGE～",
    "station_id": "FMT",
    "week": "sun",
    "target": "title",
    "keyword": "安部礼司",
    "today": true
  }
  ```

- AWS CLI で手動実行

  ```bash
  aws lambda invoke \
    --function-name lambdiko-program-search \
    --payload file://event.json \
    output.json
  ```

- EventBridge でスケジュールを定義し、定期実行も可能

### lambdiko-radiko-download

radiko タイムフリー番組をダウンロードし、S3へアップロードする。
通常は `lambdiko-program-search` から渡されるイベントパラメータで実行するが、単独で手動実行も可能。

#### イベントパラメータ

- `station_id` 放送局ID
- `ft` 開始時刻 ( `YYYYMMDDHHmmss` )
- `to` 終了時刻 ( `YYYYMMDDHHmmss` )
  - `ft` および `to` は、番組の実際の開始・終了時刻に関わらず任意の値を指定可能。
    - 連続する番組を1ファイルで保存したい場合
    - 番組内のミニコーナー部分のみを保存したい場合　など
- `title` カスタムタイトル（ファイル名に使用）
- `metadata` ID3タグ メタデータ
  - `title`
  - `artist`
  - `album`
  - `album_artist`
  - `date`
  - `comment`
  - `img` （URLを指定）

#### 実行例

[event.json の例](./events/radiko-download.json)

### lambdiko-radiru-download

らじる★らじる 聴き逃し番組をダウンロードし、S3へアップロードする。
通常は `lambdiko-program-search` から渡されるイベントパラメータで実行するが、単独で手動実行も可能。

#### イベントパラメータ

- `station_id` 放送局ID
  - `NHK-R1`, `NHK-R2`, `NHK-FM`, `NHK`
  - ファイル名にのみ使用
- `ft` 開始時刻 ( `YYYYMMDDHHmmss` )
- `to` 終了時刻 ( `YYYYMMDDHHmmss` )
  - ファイル名にのみ使用
  - らじる★らじる では番組単位でストリーミングURLが提供されるため、任意の開始～終了時刻間のダウンロードは不可。
- `title` カスタムタイトル（ファイル名に使用）
- `stream_url` ストリーミングURL
- `metadata` ID3タグ メタデータ
  - `title`
  - `artist`
  - `album`
  - `album_artist`
  - `date`
  - `comment`
  - `img` （URLを指定）

#### 実行例

[event.json の例](./events/radiru-download.json)
