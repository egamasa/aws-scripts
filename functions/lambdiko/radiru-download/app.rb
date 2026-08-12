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
require 'lambdiko/s3'
require 'lambdiko/metadata'
require 'lambdiko/ffmpeg'

LOGGER = Logger.new($stdout)
RETRY_LIMIT = 3
THREAD_LIMIT = 3
WDAY_JA = %w[日 月 火 水 木 金 土].freeze

def to_time(time_str)
  Time.strptime(time_str, '%Y%m%d%H%M%S')
end

def parse_playlist(playlist, base_url = nil)
  list = []
  key_uri = nil
  iv = '0000000000000000' # 16bit

  playlist.to_s.lines.each do |line|
    line.strip!
    next if line.empty?

    # 複合キーURI・初期化ベクトル抽出
    if line.start_with?('#EXT-X-KEY')
      key_uri = line.match(/URI="(.*?)"/)[1]
      iv = [line.match(/IV=(.*)/)[1]].pack('H*') if line.include?('IV=')
    end

    next if line.start_with?('#')
    list << "#{base_url}#{line}"
  end

  [list, key_uri, iv]
end

# セグメント復号
def decrypt_aes128(data)
  cipher = OpenSSL::Cipher.new('aes-128-cbc')
  cipher.decrypt
  cipher.key = @key
  cipher.iv = @iv
  cipher.update(data) + cipher.final
end

def download_file(url, file_path, mode = :file)
  RETRY_LIMIT.times do |attempt|
    res = HTTP.get(url)

    case mode
    when :file
      File.open(file_path, 'wb') { |file| file.write(res.body) }
      return true
    when :key
      return res.body.to_s
    when :segment
      data = res.to_s
      decrypted_data = decrypt_aes128(data)
      File.open(file_path, 'wb') { |file| file.write(decrypted_data) }
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

def download_segments(urls, file_dir)
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
            result = download_file(url, file_path, :segment)
            segment_file_path_list[index] = result ? file_path : nil
          rescue ThreadError
            break
          end
        end
      end
    end
  threads.each(&:join)

  segment_file_path_list.compact
end

def format_airtime(ft_str, to_str)
  ft = to_time(ft_str)
  to = to_time(to_str)

  date = ft.to_date

  ft_hh = ft.hour.to_s.rjust(2, '0')
  ft_mm = ft.strftime('%M')
  to_hh = to.hour.to_s.rjust(2, '0')
  to_mm = to.strftime('%M')

  {
    file_name: "#{date.strftime('%Y%m%d')}#{ft_hh}#{ft_mm}",
    notify: "#{date.strftime('%Y-%m-%d')}（#{WDAY_JA[date.wday]}）#{ft_hh}:#{ft_mm}-#{to_hh}:#{to_mm}"
  }
end

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

def main(event, context)
  file_dir = nil

  begin
    stream_url = event['stream_url']
    base_url = stream_url.match(%r{^(https://.*/)}).to_s

    pre_playlist = HTTP.get(stream_url)
    playlist_urls, *_ = parse_playlist(pre_playlist)

    file_dir = "/tmp/#{SecureRandom.uuid}"
    Dir.mkdir(file_dir) unless Dir.exist?(file_dir)

    segment_urls = []
    segment_files_count = 0

    playlist_urls.each do |playlist_url|
      playlist = HTTP.get("#{base_url}#{playlist_url}")
      playlist_segment_urls, key_uri, @iv = parse_playlist(playlist, base_url)
      segment_urls.concat(playlist_segment_urls)

      @key = download_file(key_uri, nil, :key)
      segment_file_path_list = download_segments(playlist_segment_urls, file_dir)
      segment_files_count += segment_file_path_list.count
    end

    segment_list_file_path = create_segment_list_file(segment_urls, file_dir)

    raise 'Segment count mismatch' unless segment_urls.count == segment_files_count

    airtime = format_airtime(event['ft'], event['to'])

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
