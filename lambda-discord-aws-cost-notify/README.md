# lambda-discord-aws-cost-notify

Discord向け AWS当月利用料金 通知スクリプト

![image](https://github.com/user-attachments/assets/44974f8f-be4e-4039-aa86-ad24107a8f1e)

当月1日～前日（当日が1日の場合は、前月1日～前月末日）の合計利用料金およびサービス毎の利用料金を通知します。

EventBridge Scheduler を用いた定期実行を想定しています。

## デプロイ

```bash
sam build
sam deploy --guided
```

### パラメータ

- DiscordWebhookUrl
  - Discord より取得した Webhook URL
    - サーバー設定 > アプリ: 連携サービス > ウェブフック
    - ウェブフックを作成後（もしくは既存のウェブフックを選択後）、「ウェブフックURLをコピー」から取得
