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
- Ruby 3.4（ローカルテスト時）

## デプロイ

### FFmpeg バイナリの入手

ビルド実行前に、 https://www.johnvansickle.com/ffmpeg/ より **ARM64** 版の静的ビルドバイナリをダウンロードし、`layers/bin` ディレクトリ内に ffmpeg および ffprobe を配置する。

### デプロイ

`samconfig.toml` に本番（`default`）と開発（`dev`）の2環境を定義している。
初回デプロイ前に `samconfig.toml` の各パラメータを環境に合わせて編集すること。

#### 本番環境

- スタック名： `lambdiko`
- 関数名： `lambdiko-*`

```bash
sam build
sam deploy
```

#### 開発環境

- スタック名： `lambdiko-dev`
- 関数名： `lambdiko-dev-*`

```bash
sam build
sam deploy --config-env dev
```

開発環境の確認が終わったら、以下で削除する。

```bash
sam delete --stack-name lambdiko-dev
```

初回デプロイ時など、対話形式で設定したい場合は `--guided` を付けて実行する。

```bash
sam deploy --guided
sam deploy --guided --config-env dev
```

### パラメータ

- StackName
  - Lambda 関数名・レイヤー名のプレフィックス
  - `samconfig.toml` で環境ごとに自動設定される
- BucketName
  - 音声ファイルの保存先 S3 バケット名
- LogGroupName
  - ログ出力先の CloudWatch ロググループ名
- NotifySnsTopicArn
  - ダウンロード完了通知 送信先SNSトピックARN
    - [discord-notify](../discord-notify/) をデプロイし、出力される `DiscordNotifyFunctionArn` を指定する想定

## ローカルテスト

### RSpec（ユニットテスト）

Lambda Layer の共通ライブラリ（`layers/ruby/lambdiko/`）に対するユニットテストを RSpec で実行する。

```bash
bundle install
bundle exec rspec
```

テスト対象：

- `spec/lambdiko/metadata_spec.rb`
  - `parse_metadata_date`
  - `build_metadata_options`
  - `build_artwork_option`
- `spec/lambdiko/s3_spec.rb`
  - `upload_to_s3`
- `spec/lambdiko/ffmpeg_spec.rb`
  - `run_ffmpeg`
  - `probe_duration`

### sam local invoke

`env.json.example` をコピーして環境変数を設定し、`sam local invoke` で実行する。

```bash
cp env.json.example env.json
# env.json 内の BUCKET_NAME および SNS_TOPIC_ARN を実際の値に書き換える

sam build

sam local invoke RadikoDownloadFunction \
  --event events/radiko-download.json \
  --env-vars env.json

sam local invoke RadiruDownloadFunction \
  --event events/radiru-download.json \
  --env-vars env.json

sam local invoke ProgramSearchFunction \
  --event events/program-search-radiko.json \
  --env-vars env.json
```

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
