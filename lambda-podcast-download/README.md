# lambda-podcast-download

ポッドキャストの最新回をダウンロードしS3バケットへ保存

## デプロイ

```bash
sam build
sam deploy --guided
```

### パラメータ

- BucketName
  - 保存先S3バケット名を指定

## Lambda ペイロード

リクエスト例

```
{
  "rss_url": "https://www.omnycontent.com/d/playlist/67122501-9b17-4d77-84bd-a93d00dc791e/47891e36-ed27-416f-b246-b2c60013b8dc/f75c482f-1885-4dfc-959a-b2c60013bf04/podcast.rss",
  "title": "AiScReamのとろけるタイム♡♡♡",
  "artist": "AiScReam",
  "album_artist": "ニッポン放送",
  "album": "AiScReamのとろけるタイム♡♡♡",
  "genre": "Podcast"
}
```

- rss_url
  - ［必須］RSSフィードのURL
- title
  - 番組タイトル（保存ファイル名に反映）

以下の項目を設定すると、保存ファイルのID3v2タグを上書き（mp3ファイルでのみ有効）

- artist
  - アーティスト
- album
  - アルバム
- album_artist
  - アルバムアーティスト
- genre
  - ジャンル
- year
  - 年
- comment
  - コメント
