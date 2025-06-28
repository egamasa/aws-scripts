require 'aws-sdk-s3'
require 'base64'
require 'http'
require 'json'
require 'logger'
require 'open3'
require 'securerandom'
require 'time'
require_relative 'lib/radiko'

RETRY_LIMIT = 3
THREAD_LIMIT = 3

def parse_playlist(playlist)
  list = []

  playlist.to_s.lines.each do |line|
    next if line.strip.empty? || line.strip.start_with?('#')
    list << line.strip
  end

  return list
end

def download_file(url, file_path)
  retry_count = 0
  begin
    File.open(file_path, 'wb') do |file|
      res = HTTP.get(url)
      file.write(res.body)
    end
    return true
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

def create_segment_list_file(urls, file_dir)
  list_file_path = "#{file_dir}/segment_files.txt"

  File.open(list_file_path, 'w') do |file|
    urls.each do |url|
      file_name = File.basename(url)
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
    file_name = File.basename(url)
    file_path = "#{file_dir}/#{file_name}"

    threads << Thread.new do
      result = semaphore.synchronize { download_file(url, file_path) }
      segment_file_path_list << file_path if result
    end

    threads.shift.join while threads.size >= THREAD_LIMIT
  end

  threads.each(&:join)

  return segment_file_path_list
end

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
    options << '-metadata'
    options << "#{key}=#{value}"
  end

  return options
end

def upload_to_s3(file_path, file_name)
  s3_client = Aws::S3::Client.new
  s3_bucket = ENV['BUCKET_NAME']
  file_content = File.open(file_path, 'rb')

  s3_client.put_object(bucket: s3_bucket, key: file_name, body: file_content)
end

def main(event, context)
  logger = Logger.new($stdout, progname: 'RadikoDownload')
  logger.formatter =
    proc do |severity, datetime, progname, msg|
      log = {
        timestamp: datetime.iso8601,
        level: severity,
        progname: progname,
        message: msg[:text],
        event: msg[:event]
      }
      log[:error] = { type: msg[:error].class.to_s, backtrace: msg[:error].backtrace } if msg[
        :error
      ]
      log.to_json + "\n"
    end

  client = Radiko::Client.new

  stream_info = client.get_timefree_stream_info(event['station_id'], event['ft'], event['to'])

  headers = {
    'X-Radiko-AuthToken' => stream_info[:auth_token],
    'X-Radiko-Device' => 'Ruby.radiko',
    'X-Radiko-User' => 'dummy_user'
  }
  pre_playlist = HTTP.headers(headers).get(stream_info[:url])
  playlist_urls = parse_playlist(pre_playlist)

  segment_urls = []
  playlist_urls.each do |playlist_url|
    playlist = HTTP.get(playlist_url)
    segments = parse_playlist(playlist)
    segment_urls.concat(segments)
  end

  file_dir = "/tmp/#{SecureRandom.uuid}"
  Dir.mkdir(file_dir)
  segment_list_file_path = create_segment_list_file(segment_urls, file_dir)
  segment_file_path_list = download_segments(segment_urls, file_dir)

  if segment_urls.count == segment_file_path_list.count
    output_file_name = "#{event['title']}_#{event['station_id']}_#{event['ft'][0...12]}.m4a"
    output_file_path = "#{file_dir}/#{output_file_name}"

    metadata_options = build_metadata_options(event['metadata'])

    unless event['metadata']['img'].empty?
      artwork_path = "#{file_dir}/#{File.basename(event['metadata']['img'])}"
      download_file(event['metadata']['img'], artwork_path)
      artwork_option = [
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
    else
      artwork_path = nil
    end

    ffmpeg_path = '/opt/bin/ffmpeg'
    ffmpeg_cmd = [
      ffmpeg_path,
      '-hide_banner',
      '-y',
      '-safe',
      '0',
      '-f',
      'concat',
      '-i',
      segment_list_file_path
    ]
    ffmpeg_cmd.concat(artwork_option) if artwork_path
    ffmpeg_cmd.concat(metadata_options)
    ffmpeg_cmd.concat(['-c', 'copy', output_file_path])

    begin
      _, stderr, _ = Open3.capture3(*ffmpeg_cmd)
    rescue => e
      logger.error({ text: "Error on FFmpeg: #{ffmpeg_cmd}", event:, error: stderr })
    end
  else
    logger.error({ text: 'Failed to download segments', event: })
  end

  begin
    res = upload_to_s3(output_file_path, output_file_name)
    logger.info({ text: "Download completed: #{output_file_name}", event: }) if res.etag
  rescue => e
    logger.error({ text: "Failed to upload to S3: #{output_file_path}", event:, error: e })
  end
end

def lambda_handler(event:, context:)
  main(event, context)
end
