require 'aws-sdk-secretsmanager'
require 'base64'
require 'json'
require 'net/http'
require 'time'
require 'uri'
require 'zlib'

class Line
  URI = URI.parse('https://api.line.me/v2/bot/message/broadcast')

  def make_broadcast_request(data, secret)
    token = secret['channel_access_token']
    req = Net::HTTP::Post.new(URI.path)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{token}"
    req.body = data.to_json

    return req
  end

  def send_broadcast(payload, secret)
    data = { 'messages' => [{ 'type' => 'text', 'text' => payload }] }
    req = make_broadcast_request(data, secret)

    begin
      http = Net::HTTP.new(URI.host, URI.port)
      Net::HTTP.start(URI.hostname, URI.port, use_ssl: URI.scheme == 'https') do |https|
        https.request(req)
      end
    rescue => e
      raise e
    end
  end
end

def get_line_secret
  secret_name = ENV['LINE_SECRET_NAME']
  client = Aws::SecretsManager::Client.new(region: ENV['LINE_SECRET_REGION'])

  begin
    res = client.get_secret_value(secret_id: secret_name)
    secret = JSON.parse(res.secret_string)
  rescue => e
    raise e
  end

  return secret
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

def parse_awslogs(event)
  data_base64 = Base64.decode64(event['awslogs']['data'])
  data_json = Zlib::GzipReader.new(StringIO.new(data_base64)).read
  data = JSON.parse(data_json)

  text_rows = []
  data['logEvents'].each do |log|
    text_rows << log['message']
    text_rows << format_time(log['timestamp'])
  end

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
  if event.has_key?('body')
    body = JSON.parse(event['body'])
    text_rows << body['message']
  else
    text_rows << event
  end
  text_rows << format_time(Time.now)

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

  if payload
    line_secret = get_line_secret
    line = Line.new
    line.send_broadcast(payload.force_encoding('UTF-8'), line_secret)
  end
end

def lambda_handler(event:, context:)
  main(event)
end
