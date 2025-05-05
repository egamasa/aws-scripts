# lambda-discord-nhk-program-notify

**NHK番組情報 通知スクリプト**

ジャンルまたはキーワード・放送サービス・放送日・エリアを指定して、NHKで放送予定の番組情報を Discord へ通知します。

## デプロイ

```bash
sam build
sam deploy --guided
```

### パラメータ

- ApiKeyParameterName
  - NHK番組表APIより取得したAPIキーをパラメータストアに登録し、パラメータ名を指定
- WebhookUrlParameterName
  - Discord より取得した Webhook URL をパラメータストアに登録し、パラメータ名を指定
- ExcludeBS8KPrograms
  - NHK BS8K で放送される番組を除外する
  - True または False（デフォルト：True）

## Lambda ペイロード

### パラメータ

参考： [NHK番組表API ドキュメント リクエスト](https://api-portal.nhk.or.jp/doc-request)

#### ジャンル・放送サービス・エリア

[constants.rb](./function/config/constants.rb) を参照

#### 放送日

n日後で指定

### キーワード指定（タイトル検索）の例

```
[
  {
    "keyword": "歌謡スクランブル",
    "items": [
      "title"
    ],
    "service": "radio",
    "days_after": 2,
    "area": "saga"
  },
  {
    "keyword": "おとなのＥテレタイムマシン",
    "items": [
      "title"
    ],
    "service": "tv",
    "days_after": 2,
    "area": "saga"
  }
]
```

### ジャンル指定の例

```
[
  {
    "genre": "0600",
    "service": "tv",
    "days_after": 2,
    "area": "saga"
  },
  {
    "genre": "0601",
    "service": "tv",
    "days_after": 2,
    "area": "saga"
  }
]
```
