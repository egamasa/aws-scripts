require 'aws-sdk-s3'
require 'http'
require 'json'
require 'logger'
require 'openssl'
require 'securerandom'
require 'uri'

RETRY_LIMIT = 3
THREAD_LIMIT = 3

def parse_playlist(playlist, base_url = nil)
  list = []
  key_uri = nil
  iv = '0000000000000000' # 16bit

  playlist.to_s.lines.each do |line|
    next if line.strip.empty?

    # 複合キーURI・初期化ベクトル抽出
    if line.start_with?('#EXT-X-KEY')
      key_uri = line.match(/URI="(.*?)"/)[1]
      iv = [line.match(/IV=(.*)/)[1]].pack('H*') if line.include?('IV=')
    end

    next if line.strip.start_with?('#')
    list << "#{base_url}#{line.strip}"
  end

  return list, key_uri, iv
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
  retry_count = 0
  begin
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
    retry_count += 1
    if retry_count <= RETRY_LIMIT
      sleep 1
      retry
    else
      return false
    end
  end
end

# ffmpeg 結合用ファイルリスト作成
def create_segment_list_file(urls, file_dir)
  list_file_path = "#{file_dir}/segment_files.txt"

  File.open(list_file_path, 'w') do |file|
    urls.each do |url|
      file_name = File.basename(URI.parse(url).path)
      file_path = "#{file_dir}/#{file_name}"
      file.puts "file '#{file_path}'"
    end
  end

  return list_file_path
end

def download_segments(urls, file_dir)
  semaphore = Mutex.new
  threads = []
  segment_file_path_list = []

  urls.each do |url|
    file_name = File.basename(URI.parse(url).path)
    file_path = "#{file_dir}/#{file_name}"

    threads << Thread.new do
      result = semaphore.synchronize { download_file(url, file_path, :segment) }
      segment_file_path_list << file_path if result
    end

    threads.shift.join while threads.size >= THREAD_LIMIT
  end

  threads.each(&:join)

  return segment_file_path_list
end

# ffmpeg メタデータ追加コマンド出力
def build_metadata_options(metadata)
  options = []
  {
    title: metadata['title'],
    artist: metadata['artist'],
    album: metadata['album'],
    album_artist: metadata['album_artist'],
    date: Time.parse(metadata['date']).strftime('%Y-%m-%d'),
    comment: metadata['comment']
  }.each do |key, value|
    next unless value && !value.empty?
    options << "-metadata #{key}='#{value}'"
  end

  return options.join(' ')
end

def upload_to_s3(file_path, file_name)
  s3_client = Aws::S3::Client.new
  s3_bucket = ENV['BUCKET_NAME']
  file_content = File.open(file_path, 'rb')

  s3_client.put_object(bucket: s3_bucket, key: file_name, body: file_content)
end

def main(event, context)
  logger = Logger.new($stdout, progname: 'RadiruDownload')
  logger.formatter =
    proc do |severity, datetime, progname, msg|
      log = {
        timestamp: datetime.iso8601,
        level: severity,
        progname: progname,
        message: msg[:text],
        event: msg[:event]
      }
      log[:error] = { type: msg[:error].class.to_a, backtrace: msg[:error].backtrace } if msg[
        :error
      ]
      log.to_json + "\n"
    end

  stream_url = event['stream_url']
  base_url = stream_url.match(%r{^(https://.*/)}).to_s

  pre_playlist = HTTP.get(stream_url)
  playlist_urls, *_ = parse_playlist(pre_playlist)

  file_dir = "/tmp/#{SecureRandom.uuid}"
  Dir.mkdir(file_dir)

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

  if segment_urls.count == segment_files_count
    output_file_name = "#{event['title']}_#{event['station_id']}_#{event['ft'][0...12]}.m4a"
    output_file_path = "#{file_dir}/#{output_file_name}"

    metadata_options = build_metadata_options(event['metadata'])

    unless event['metadata']['img'].empty?
      artwork_path = "#{file_dir}/#{File.basename(event['metadata']['img'])}"
      download_file(event['metadata']['img'], artwork_path)
      artwork_option =
        "-i '#{artwork_path}' -map 0:a -map 1:v -disposition:1 attached_pic -id3v2_version 3"
    else
      artwork_path = nil
    end

    ffmpeg_path = '/opt/bin/ffmpeg'
    ffmpeg_cmd =
      "#{ffmpeg_path} -hide_banner -y -safe 0 -f concat -i '#{segment_list_file_path}' #{artwork_option if artwork_path} #{metadata_options} -c copy '#{output_file_path}' 2>&1"

    begin
      `#{ffmpeg_cmd}`
    rescue => e
      logger.error({ text: "Error on FFmpeg: #{ffmpeg_cmd}", event:, error: e })
    end
  else
    logger.error({ text: 'Failed to download segments', event: })
  end

  begin
    res = upload_to_s3(output_file_path, output_file_name)
    logger.info({ text: "Download completed: #{output_file_name}", event: }) if res.etag
  rescue => e
    logger.error({ text: 'Failed to upload to S3', event:, error: e })
  end
end

def lambda_handler(event:, context:)
  main(event, context)
end
