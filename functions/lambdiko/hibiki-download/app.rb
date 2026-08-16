unless File.exist?('/opt/ruby/lib/lambdiko')
  $LOAD_PATH.unshift(File.expand_path('../../layers/ruby', __dir__))
end

require 'aws-sdk-sns'
require 'fileutils'
require 'http'
require 'json'
require 'logger'
require 'openssl'
require 'securerandom'
require 'time'
require 'uri'
require 'lambdiko/ffmpeg'
require 'lambdiko/metadata'
require 'lambdiko/s3'

LOGGER = Logger.new($stdout)
RETRY_LIMIT = 3
THREAD_LIMIT = 3
WDAY_JA = %w[日 月 火 水 木 金 土].freeze

USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.7258.67 Safari/537.36'

HIBIKI_API_HEADERS = {
  'Referer' => 'http://hibiki-radio.jp/',
  'X-Requested-With' => 'XMLHttpRequest',
  'Origin' => 'http://hibiki-radio.jp',
  'User-Agent' => USER_AGENT
}.freeze

# プレイリスト処理
def parse_pre_playlist(body)
  urls = []
  lines = body.to_s.lines.map(&:strip).reject(&:empty?)
  lines.each_with_index do |line, i|
    next_line = lines[i + 1]
    urls << next_line if line.start_with?('#EXT-X-STREAM-INF:') && next_line
  end
  urls
end

def parse_playlist(playlist, base_url)
  segments = []
  key_uri = nil
  iv = nil

  playlist.to_s.lines.each do |line|
    line.strip!
    next if line.empty?

    if line.start_with?('#EXT-X-KEY')
      key_uri = line.match(/URI="(.*?)"/)[1]
      iv_hex = line.match(/IV=0x([0-9A-Fa-f]+)/)[1]
      iv = [iv_hex].pack('H*')
    end

    next if line.start_with?('#')

    url = line.start_with?('http') ? line : "#{base_url}#{line}"
    segments << url
  end

  [segments, key_uri, iv]
end

# セグメント復号
def decrypt_aes128(data, key, iv)
  cipher = OpenSSL::Cipher.new('aes-128-cbc')
  cipher.decrypt
  cipher.key = key
  cipher.iv = iv
  cipher.update(data) + cipher.final
end

# ダウンロード
def download_file(url, file_path, mode: :file, key: nil, iv: nil)
  RETRY_LIMIT.times do |attempt|
    res = HTTP.get(url)
    raise "HTTP #{res.status}" unless res.status.success?

    case mode
    when :file
      File.open(file_path, 'wb') { |f| f.write(res.body) }
      return true
    when :key
      return res.body.to_s
    when :segment
      decrypted = decrypt_aes128(res.body.to_s, key, iv)
      File.open(file_path, 'wb') { |f| f.write(decrypted) }
      return true
    end
  rescue StandardError => e
    retry_count = attempt + 1
    if retry_count < RETRY_LIMIT
      LOGGER.warn("Download retry (#{retry_count}/#{RETRY_LIMIT}): #{e.message} - #{url}")
      sleep 1
    else
      LOGGER.error("Download failed: #{e.message} - #{url}")
      return false
    end
  end
end

def download_segments(urls, file_dir, key:, iv:)
  queue = Queue.new
  segment_file_path_list = Array.new(urls.size)

  urls.each_with_index { |url, index| queue << [url, index] }

  threads =
    THREAD_LIMIT.times.map do
      Thread.new do
        loop do
          begin
            url, index = queue.pop(true)
            file_name = File.basename(URI.parse(url).path)
            file_path = "#{file_dir}/#{file_name}"
            result = download_file(url, file_path, mode: :segment, key: key, iv: iv)
            segment_file_path_list[index] = result ? file_path : nil
          rescue ThreadError
            break
          end
        end
      end
    end
  threads.each(&:join)

  failed_count = urls.size - segment_file_path_list.compact.size
  LOGGER.warn("#{failed_count} segment(s) failed to download") if failed_count > 0

  segment_file_path_list.compact
end

# セグメント結合
def create_segment_list_file(urls, file_dir)
  list_file_path = "#{file_dir}/segment_files.txt"

  File.open(list_file_path, 'w') do |file|
    urls.each do |url|
      file_name = File.basename(URI.parse(url).path)
      file.puts "file '#{file_dir}/#{file_name}'"
    end
  end

  list_file_path
end

# API
def get_hibiki_stream(video_id)
  url = "https://vcms-api.hibiki-radio.jp/api/v1/videos/play_check?video_id=#{video_id}"
  res = HTTP.headers(HIBIKI_API_HEADERS).get(url)
  raise "Failed to fetch stream info: HTTP #{res.code}" unless res.status.success?

  JSON.parse(res.body.to_s)
end

# 日時処理
def to_time(time_str)
  Time.strptime(time_str, '%Y%m%d%H%M%S')
end

def format_airtime(ft_str)
  ft = to_time(ft_str)
  date = ft.to_date

  ft_hh = ft.hour.to_s.rjust(2, '0')
  ft_mm = ft.strftime('%M')

  {
    file_name: "#{date.strftime('%Y%m%d')}#{ft_hh}#{ft_mm}",
    notify: "#{date.strftime('%Y-%m-%d')}（#{WDAY_JA[date.wday]}）#{ft_hh}:#{ft_mm}"
  }
end

# 通知
def sns_publish(message)
  sns = Aws::SNS::Client.new
  sns.publish(topic_arn: ENV['SNS_TOPIC_ARN'], message: message.to_json)
end

def send_notify(status: nil, description: nil, fields: nil)
  title = { ok: 'ダウンロード完了', error: 'ダウンロードエラー' }[status]

  message = {
    service: 'Lambdiko',
    title: title,
    status: status.to_s.upcase,
    description: description,
    fields: fields,
    timestamp: Time.now
  }
  sns_publish(message)
end

def main(event, _context)
  file_dir = nil

  begin
    # event['to'] に video_id が格納されている
    video_id = event['to']
    stream_info = get_hibiki_stream(video_id)

    res = HTTP.get(stream_info['playlist_url'])
    playlist_urls = parse_pre_playlist(res.body)

    raise 'No playlist URLs found' if playlist_urls.empty?

    file_dir = "/tmp/#{SecureRandom.uuid}"
    Dir.mkdir(file_dir) unless Dir.exist?(file_dir)

    segment_urls = []
    segment_files_count = 0

    playlist_urls.each do |playlist_url|
      base_url = playlist_url.match(%r{^(https?://[^?]+/)}).to_s
      playlist = HTTP.get(playlist_url)
      playlist_segment_urls, key_uri, iv = parse_playlist(playlist.body, base_url)
      segment_urls.concat(playlist_segment_urls)

      key = download_file(key_uri, file_dir, mode: :key)
      segment_file_path_list = download_segments(playlist_segment_urls, file_dir, key: key, iv: iv)
      segment_files_count += segment_file_path_list.count
    end

    segment_list_file_path = create_segment_list_file(segment_urls, file_dir)

    raise 'Segment count mismatch' unless segment_urls.count == segment_files_count

    airtime = format_airtime(event['ft'])

    output_file_name = "#{event['title']}_#{event['station_id']}_#{airtime[:file_name]}.m4a"
    output_file_path = "#{file_dir}/#{output_file_name}"

    metadata_options = build_metadata_options(event['metadata'])
    artwork_option = build_artwork_option(event['metadata'], file_dir)

    run_ffmpeg(segment_list_file_path, output_file_path, metadata_options, artwork_option)

    s3_file_path = upload_to_s3(output_file_path, output_file_name)

    file_size = "#{(File.size(output_file_path).to_f / 1024 / 1024).round(2)} MB"
    duration = probe_duration(output_file_path)

    LOGGER.info("Download completed: #{s3_file_path} (#{file_size} / #{duration})")

    fields = [
      { name: 'Title', value: event['metadata']['title'], inline: false },
      { name: 'On Air', value: airtime[:notify], inline: true },
      { name: 'Size', value: "#{file_size} / #{duration}", inline: true }
    ]
    send_notify(status: :ok, description: s3_file_path, fields: fields)
  ensure
    FileUtils.rm_rf(file_dir) if file_dir && Dir.exist?(file_dir)
  end
end

def lambda_handler(event:, context:)
  main(event, context)
rescue StandardError => e
  LOGGER.error("Error [#{e.class}] #{e.message}")
  LOGGER.error(e.backtrace.join("\n"))
  send_notify(status: :error, description: "#{e.class}\n```\n#{e.message}\n```")
end
