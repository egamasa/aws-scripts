require 'active_support/all'
require 'aws-sdk-costexplorer'
require 'discordrb/webhooks'
require 'json'
require 'net/http'

def get_total_cost
  response =
    @ce.get_cost_and_usage(
      time_period: {
        start: @start_date,
        end: @end_date
      },
      granularity: 'MONTHLY',
      metrics: ['AmortizedCost']
    )

  total_cost = response.results_by_time.first.total['AmortizedCost']
  { amount: total_cost.amount.to_f, unit: total_cost.unit }
end

def get_service_cost_list
  response =
    @ce.get_cost_and_usage(
      time_period: {
        start: @start_date,
        end: @end_date
      },
      granularity: 'MONTHLY',
      metrics: ['AmortizedCost'],
      group_by: [{ type: 'DIMENSION', key: 'SERVICE' }]
    )

  response.results_by_time.first.groups.map do |service_group|
    {
      service: service_group.keys.first,
      amount: service_group.metrics['AmortizedCost'].amount.to_f,
      unit: service_group.metrics['AmortizedCost'].unit
    }
  end
end

def get_exchange_rate(unit = 'JPY')
  uri = URI('https://www.gaitameonline.com/rateaj/getrate')
  response = Net::HTTP.get(uri)
  rate_data = JSON.parse(response)

  rate_info = rate_data['quotes'].find { |rate| rate['currencyPairCode'] == "USD#{unit}" }

  rate_info ? rate_info['open'] : nil
end

def convert_amount(amount_value, exchange_rate)
  amount_value.to_f * exchange_rate.to_f
end

def format_amount(billing_info, exchange_rate)
  amount = billing_info[:amount]
  unit = billing_info[:unit]

  if exchange_rate
    converted_amount = convert_amount(amount, exchange_rate)
    format('$%.2f %s / %d円', amount, unit, converted_amount.round)
  else
    format('$%.2f %s', amount, unit)
  end
end

def get_billing_term
  today = Date.today
  start_date = today.yesterday.beginning_of_month.iso8601
  end_date = today.yesterday.iso8601

  if start_date == end_date
    start_date = today.prev_month.beginning_of_month.iso8601
    end_date = today.prev_month.end_of_month.iso8601
  end

  return start_date, end_date
end

def send_message
  unit = 'JPY'
  exchange_rate = get_exchange_rate()

  webhook_url = ENV['DISCORD_WEBHOOK_URL']
  discord_client = Discordrb::Webhooks::Client.new(url: webhook_url)

  discord_client.execute do |builder|
    builder.add_embed do |embed|
      embed.title = 'AWS 利用料金'
      embed.description = "#{@start_date} ～ #{@end_date}"

      embed.add_field(name: '合計', value: format_amount(@total_cost, exchange_rate), inline: false)

      @service_cost_list.each do |service_cost|
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

      embed.color = 0xb4d699
      embed.timestamp = Time.now
    end
  end
end

def lambda_handler(event:, context:)
  @start_date, @end_date = get_billing_term()

  @ce = Aws::CostExplorer::Client.new(region: 'us-east-1')
  @total_cost = get_total_cost()
  @service_cost_list = get_service_cost_list()

  send_message()
end
