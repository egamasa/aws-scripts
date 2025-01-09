require 'base64'
require 'discordrb'
require 'json'
require 'net/http'
require 'time'
require 'uri'
require 'zlib'

def get_bot_params
  query = URI.encode_www_form(name: ENV['BOT_PARAMS_NAME'], withDecryption: true)
  uri = URI.parse("http://localhost:2773/systemsmanager/parameters/get?#{query}")
  headers = { 'X-Aws-Parameters-Secrets-Token': ENV['AWS_SESSION_TOKEN'] }

  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Get.new(uri.request_uri)
  req.initialize_http_header(headers)
  res = http.request(req)

  if res.code == '200'
    params = JSON.parse(res.body, symbolize_names: true).dig(:Parameter, :Value)
  else
    return nil, nil
  end

  json = JSON.parse(params, symbolize_names: true)
  return json[:client_id], json[:token]
end

def send_message(payload)
  bot_client_id, bot_token = get_bot_params()
  bot = Discordrb::Bot.new(client_id: bot_client_id, token: bot_token)

  channel_id = ENV['CHANNEL_ID']
  bot.send_message(channel_id, payload.force_encoding('UTF-8'))
end

def format_time(time)
  case time
  when Time
    time_obj = time
  when Integer
    time_obj = Time.at(time / 1000.0)
  else
    time_obj = Time.parse(time)
  end

  return time_obj.localtime('+09:00').strftime('%Y-%m-%d %H:%M:%S')
end

def parse_lambda_log(log)
  text_rows = []

  begin
    message = JSON.parse(log['message'])
    text_rows << "[#{message['progname']}]" if message.has_key?('progname')
    text_rows << message['message']
    text_rows << message['error'] if message.has_key?('error')
    text_rows << format_time(message['timestamp'])
  rescue StandardError
    text_rows << log['message']
    text_rows << format_time(log['timestamp'])
  end

  return text_rows
end

def parse_awslogs(event)
  data_base64 = Base64.decode64(event['awslogs']['data'])
  data_json = Zlib::GzipReader.new(StringIO.new(data_base64)).read
  data = JSON.parse(data_json)

  text_rows = []
  data['logEvents'].each { |log| text_rows.concat(parse_lambda_log(log)) }

  return text_rows.join("\n")
end

def parse_sns_topic(event)
  text_rows = []
  text_rows << event['Records'][0]['Sns']['Message']
  sns_timestamp = event['Records'][0]['Sns']['Timestamp']
  text_rows << format_time(sns_timestamp)

  return text_rows.join("\n")
end

def parse_event(event)
  text_rows = []
  if event.has_key?('message')
    text_rows.concat(parse_lambda_log(event))
  elsif event.has_key?('body')
    body = JSON.parse(event['body'])
    text_rows << body['message']
    text_rows << format_time(Time.now)
  else
    text_rows << event
    text_rows << format_time(Time.now)
  end

  return text_rows.join("\n")
end

def main(event)
  payload = nil
  if event.has_key?('awslogs')
    payload = parse_awslogs(event)
  elsif event.has_key?('Records')
    payload = parse_sns_topic(event)
  else
    payload = parse_event(event)
  end

  send_message(payload) if payload
end

def lambda_handler(event:, context:)
  main(event)
end
