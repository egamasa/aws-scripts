require 'aws-sdk-ssm'
require 'base64'
require 'json'
require 'net/http'
require 'time'
require 'uri'
require 'zlib'

class Line
  URI = URI.parse('https://api.line.me/v2/bot/message/broadcast')

  def make_broadcast_request(data, token)
    req = Net::HTTP::Post.new(URI.path)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{token}"
    req.body = data.to_json

    return req
  end

  def send_broadcast(payload, token)
    data = { 'messages' => [{ 'type' => 'text', 'text' => payload }] }
    req = make_broadcast_request(data, token)

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

def get_line_token
  parameter_name = "/#{ENV['LINE_TOKEN_PARAMETER_NAME']}"
  client = Aws::SSM::Client.new(region: ENV['LINE_TOKEN_PARAMETER_REGION'])

  begin
    req = { name: parameter_name, with_decryption: true }
    res = client.get_parameter(req)
  rescue => e
    raise e
  end

  return res.parameter.value
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

  if payload
    line_token = get_line_token
    line = Line.new
    line.send_broadcast(payload.force_encoding('UTF-8'), line_token)
  end
end

def lambda_handler(event:, context:)
  main(event)
end
