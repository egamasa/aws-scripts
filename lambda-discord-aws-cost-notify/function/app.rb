require 'active_support/all'
require 'aws-sdk-costexplorer'
require 'discordrb/webhooks'
require 'json'
require 'net/http'

# 料金取得期間
def get_billing_term
  today = Date.today
  # 開始日: 当月1日
  start_date = today.yesterday.beginning_of_month.iso8601
  # 終了日: スクリプト実行日の前日
  end_date = today.yesterday.iso8601

  # スクリプト実行日が月初の場合、前月1日～末日を取得期間とする
  if start_date == end_date
    start_date = today.prev_month.beginning_of_month.iso8601
    end_date = today.prev_month.end_of_month.iso8601
  end

  return start_date, end_date
end

# 料金取得
def get_costs(start_date, end_date, metric = 'AmortizedCost')
  response =
    @ce.get_cost_and_usage(
      time_period: {
        start: start_date,
        end: end_date
      },
      granularity: 'MONTHLY',
      metrics: [metric],
      group_by: [{ type: 'DIMENSION', key: 'SERVICE' }],
      filter: {
        not: {
          # クレジット充当額を除外
          dimensions: {
            key: 'RECORD_TYPE',
            values: ['Credit']
          }
        }
      }
    )

  # 月間積算料金（合計）
  total = 0
  response.results_by_time.first.groups.each do |group|
    cost = group.metrics[metric].amount.to_f
    total += cost
  end
  cost_total = {
    amount: total,
    unit: response.results_by_time.first.groups.first.metrics[metric].unit
  }

  # 月間積算料金（サービス毎）
  cost_per_service =
    response.results_by_time.first.groups.map do |group|
      {
        service: group.keys.first,
        amount: group.metrics[metric].amount.to_f,
        unit: group.metrics[metric].unit
      }
    end

  return cost_total, cost_per_service
end

# 為替レート取得
def get_exchange_rate(unit = 'JPY')
  uri = URI('https://www.gaitameonline.com/rateaj/getrate')
  response = Net::HTTP.get(uri)
  rate_data = JSON.parse(response)

  rate_info = rate_data['quotes'].find { |rate| rate['currencyPairCode'] == "USD#{unit}" }

  rate_info ? rate_info['open'] : nil
end

# 為替レート計算
def convert_amount(amount_value, exchange_rate)
  amount_value.to_f * exchange_rate.to_f
end

# 表示フォーマット
def format_amount(cost_group, exchange_rate)
  amount = cost_group[:amount]
  unit = cost_group[:unit]

  if exchange_rate
    converted_amount = convert_amount(amount, exchange_rate)
    format('$%.2f %s / %d円', amount, unit, converted_amount.round)
  else
    format('$%.2f %s', amount, unit)
  end
end

# Discord 送信
def send_message(start_date, end_date, cost_total, cost_per_service)
  unit = 'JPY'
  exchange_rate = get_exchange_rate()

  webhook_url = ENV['DISCORD_WEBHOOK_URL']
  discord_client = Discordrb::Webhooks::Client.new(url: webhook_url)

  discord_client.execute do |builder|
    builder.add_embed do |embed|
      embed.title = 'AWS 利用料金'
      embed.description = "#{start_date} ～ #{end_date}"

      embed.add_field(name: '合計', value: format_amount(cost_total, exchange_rate), inline: false)

      cost_per_service.each do |service_cost|
        next if service_cost[:amount].to_f.round(2) == 0.0

        embed.add_field(
          name: service_cost[:service],
          value: format_amount(service_cost, exchange_rate),
          inline: true
        )
      end

      if exchange_rate
        embed.footer =
          Discordrb::Webhooks::EmbedFooter.new(text: "$1 USD = #{exchange_rate} #{unit}")
      else
        embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: '為替レートの取得に失敗しました')
      end

      embed.color = 0x7aa116
      embed.timestamp = Time.now
    end
  end
end

def lambda_handler(event:, context:)
  start_date, end_date = get_billing_term()

  @ce = Aws::CostExplorer::Client.new(region: 'us-east-1')
  cost_total, cost_per_service = get_costs(start_date, end_date)

  send_message(start_date, end_date, cost_total, cost_per_service)
end
