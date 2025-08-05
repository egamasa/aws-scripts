require 'discordrb/webhooks'
require 'json'
require 'logger'
require 'net/http'
require 'time'

def get_webhook_url
  param_name = ENV['WEBHOOK_URL_PARAMETER_NAME']
  query = URI.encode_www_form(name: param_name, withDecryption: true)
  uri = URI.parse("http://localhost:2773/systemsmanager/parameters/get?#{query}")
  headers = { 'X-Aws-Parameters-Secrets-Token': ENV['AWS_SESSION_TOKEN'] }

  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Get.new(uri.request_uri)
  req.initialize_http_header(headers)
  res = http.request(req)

  if res.code == '200'
    return JSON.parse(res.body, symbolize_names: true).dig(:Parameter, :Value)
  else
    raise "Failed to get Webhook URL: #{uri} [#{res.code}] #{res.body}"
  end
end

def extract_messages(event)
  messages = []

  if event['Records']
    event['Records'].each do |record|
      message = { subject: nil, message: nil, timestamp: record['Sns']['Timestamp'], data: nil }

      begin
        message[:data] = JSON.parse(record['Sns']['Message'])
      rescue JSON::ParserError
        message[:subject] = record['Sns']['Subject']
        message[:message] = record['Sns']['Message']
      end

      messages << message
    end
  end

  return messages
end

def get_embed_color(status)
  case status
  when 'OK'
    0x00ff00
  when 'INFO'
    0x00bfff
  when 'WARN'
    0xffa500
  when 'ERROR'
    0xff4444
  end
end

def build_embed(message)
  embed = Discordrb::Webhooks::Embed.new

  title = message[:subject]
  description = message[:message]
  timestamp = message[:timestamp]

  if message[:data]
    title = [message[:data]['service'], message[:data]['title']].compact.join(' / ')
    description = message[:data]['message']
    timestamp = message[:data]['timestamp'] if message[:data]['timestamp']
    embed.color = get_embed_color(message[:data]['status'])

    if message[:data]['fields']&.is_a?(Array)
      message[:data]['fields'].each do |field|
        embed.add_field(name: field['name'], value: field['value'], inline: field['inline'])
      end
    end

    if message[:data]['footer']
      embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: message[:data]['footer'])
    end
  end

  embed.title = title
  embed.description = description
  embed.timestamp = Time.parse(timestamp)

  return embed
end

def send_message(messages)
  webhook_url = get_webhook_url

  messages.each do |message|
    embed = build_embed(message)

    discord_client = Discordrb::Webhooks::Client.new(url: webhook_url)
    discord_client.execute { |builder| builder << embed }
  end
end

def main(event)
  messages = extract_messages(event)

  send_message(messages) if messages.any?
end

def lambda_handler(event:, context:)
  main(event)
end
