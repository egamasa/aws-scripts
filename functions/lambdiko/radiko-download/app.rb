require 'aws-sdk-s3'
require 'aws-sdk-sns'
require 'base64'
require 'fileutils'
require 'http'
require 'json'
require 'logger'
require 'open3'
require 'securerandom'
require 'time'
require_relative 'lib/radiko'

LOGGER = Logger.new($stdout)
RETRY_LIMIT = 3
THREAD_LIMIT = 3
SEEK_SEC = 300
WDAY_JA = %w[日 月 火 水 木 金 土].freeze

def to_time(time_str)
  Time.strptime(time_str, '%Y%m%d%H%M%S')
end

def seek(seek_time, seek_sec = SEEK_SEC)
  sought_time = seek_time + seek_sec
  [sought_time, sought_time.strftime('%Y%m%d%H%M%S')]
end

def parse_playlist(playlist)
  playlist.to_s.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
end

def download_file(url, file_path)
  RETRY_LIMIT.times do |attempt|
    File.open(file_path, 'wb') { |file| file.write(HTTP.get(url).body) }
    return true
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
    urls.each { |url| file.puts "file '#{file_dir}/#{File.basename(url)}'" }
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
            file_name = File.basename(url)
            file_path = "#{file_dir}/#{file_name}"
            result = download_file(url, file_path)
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
  ft_hour = ft.hour
  to_hour = to.hour

  # 放送中に日付を跨ぐ番組
  # 終了時刻のみ29時間制表記
  to_hour += 24 if to.hour < ft.hour

  # 深夜0〜4時台に開始する番組
  if ft.hour < 5
    # 放送日は前日
    date -= 1
    # 開始時刻・終了時刻を29時間制表記
    ft_hour += 24
    to_hour += 24
  end

  ft_hh = ft_hour.to_s.rjust(2, '0')
  ft_mm = ft.strftime('%M')
  to_hh = to_hour.to_s.rjust(2, '0')
  to_mm = to.strftime('%M')

  {
    file_name: "#{date.strftime('%Y%m%d')}#{ft_hh}#{ft_mm}",
    notify: "#{date.strftime('%Y-%m-%d')}（#{WDAY_JA[date.wday]}）#{ft_hh}:#{ft_mm}-#{to_hh}:#{to_mm}"
  }
end

def parse_metadata_date(date_str)
  return nil if date_str.nil? || date_str.empty?
  Time.parse(date_str).strftime('%Y-%m-%d')
rescue StandardError
  nil
end

def build_metadata_options(metadata)
  date = parse_metadata_date(metadata['date'])

  {
    title: metadata['title'],
    artist: metadata['artist'],
    album: metadata['album'],
    album_artist: metadata['album_artist'],
    date: date,
    comment: metadata['comment']
  }.flat_map { |key, value| value && !value.empty? ? ['-metadata', "#{key}=#{value}"] : [] }
end

def build_artwork_option(metadata, file_dir)
  img_url = metadata&.dig('img')
  return nil if img_url.nil? || img_url.empty?

  artwork_path = "#{file_dir}/#{File.basename(img_url)}"
  unless download_file(img_url, artwork_path)
    LOGGER.warn("Artwork download failed: #{img_url}")
    return nil
  end

  [
    '-i',
    artwork_path,
    '-map',
    '0:a',
    '-map',
    '1:v',
    '-disposition:1',
    'attached_pic',
    '-id3v2_version',
    '3'
  ]
end

def upload_to_s3(file_path, file_name)
  s3_bucket = ENV['BUCKET_NAME']
  File.open(file_path, 'rb') do |file|
    Aws::S3::Client.new.put_object(bucket: s3_bucket, key: file_name, body: file)
  end

  "s3://#{s3_bucket}/#{file_name}"
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
    client = Radiko::Client.new
    area_id = client.get_area_id_by_station_id(event['station_id'])
    stream_info = client.get_timefree_stream_info(event['station_id'])

    lsid = SecureRandom.hex(16)
    headers = { 'X-Radiko-AreaId' => area_id, 'X-Radiko-AuthToken' => stream_info[:auth_token] }
    params = {
      lsid: lsid,
      station_id: event['station_id'],
      l: SEEK_SEC.to_s,
      start_at: event['ft'],
      end_at: event['to'],
      type: 'b',
      ft: event['ft'],
      to: event['to']
    }

    segment_urls = []
    seek_time = to_time(event['ft'])
    seek_str = event['ft']
    end_time = to_time(event['to'])

    while seek_time < end_time
      params[:seek] = seek_str
      pre_playlist = HTTP.headers(headers).get(stream_info[:url], params:)
      playlist_urls = parse_playlist(pre_playlist)

      playlist_urls.each do |playlist_url|
        playlist = HTTP.get(playlist_url)
        segments = parse_playlist(playlist)
        segment_urls.concat(segments)
      end

      seek_time, seek_str = seek(seek_time)
    end

    file_dir = "/tmp/#{lsid}"
    Dir.mkdir(file_dir) unless Dir.exist?(file_dir)
    segment_list_file_path = create_segment_list_file(segment_urls, file_dir)
    segment_file_path_list = download_segments(segment_urls, file_dir)

    raise 'Segment count mismatch' unless segment_urls.count == segment_file_path_list.count

    airtime = format_airtime(event['ft'], event['to'])

    output_file_name = "#{event['title']}_#{event['station_id']}_#{airtime[:file_name]}.m4a"
    output_file_path = "#{file_dir}/#{output_file_name}"

    metadata_options = build_metadata_options(event['metadata'])
    artwork_option = build_artwork_option(event['metadata'], file_dir)

    ffmpeg_cmd = [
      '/opt/bin/ffmpeg',
      '-hide_banner',
      '-y',
      '-safe',
      '0',
      '-f',
      'concat',
      '-i',
      segment_list_file_path
    ]
    ffmpeg_cmd.concat(artwork_option) if artwork_option
    ffmpeg_cmd.concat(metadata_options)
    ffmpeg_cmd.concat(['-c', 'copy', output_file_path])

    _, stderr, status = Open3.capture3(*ffmpeg_cmd)
    raise "FFmpeg failed: #{stderr}" unless status.success?

    s3_file_path = upload_to_s3(output_file_path, output_file_name)

    file_size = "#{(File.size(output_file_path).to_f / 1024 / 1024).round(2)} MB"

    # ffprobe 再生時間取得
    ffprobe_cmd = [
      '/opt/bin/ffprobe',
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=noprint_wrappers=1:nokey=1',
      output_file_path
    ]
    ffprobe_out, _, ffprobe_status = Open3.capture3(*ffprobe_cmd)
    duration =
      if ffprobe_status.success? && !ffprobe_out.strip.empty?
        total_sec = ffprobe_out.strip.to_f.round
        h, m, s = total_sec / 3600, (total_sec % 3600) / 60, total_sec % 60
        (h > 0 ? "#{h}h" : '') + "#{m}m#{s}s"
      else
        LOGGER.warn("ffprobe failed: #{ffprobe_out}")
        '-h--m--s'
      end

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
