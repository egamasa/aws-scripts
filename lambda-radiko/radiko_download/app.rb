require 'aws-sdk-s3'
require 'base64'
require 'http'
require 'json'
require 'securerandom'
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

def upload_to_s3(file_path, file_name)
  s3_client = Aws::S3::Client.new(region: ENV['S3_REGION'])
  s3_bucket = ENV['S3_BUCKET_ARN'].split(':').last
  file_content = File.open(file_path, 'rb')

  s3_client.put_object(bucket: s3_bucket, key: file_name, body: file_content)
end

def main(event)
  client = Radiko::Client.new

  stream_info =
    client.get_timefree_stream_info(
      event['station_id'],
      event['ft'],
      event['to']
    )

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
    aac_file_name = "#{event['station_id']}_#{event['ft']}-#{event['to']}.aac"
    aac_file_path = "#{file_dir}/#{aac_file_name}"

    ffmpeg_path = '/opt/bin/ffmpeg'
    ffmpeg_cmd =
      "#{ffmpeg_path} -f concat -safe 0 -i #{segment_list_file_path} -c copy #{aac_file_path}"
    begin
      result = `#{ffmpeg_cmd}`
      p result

      upload_to_s3(aac_file_path, aac_file_name)
    rescue => e
      p e
    end
  else
    raise 'Failed to download'
  end
end

def lambda_handler(event:, context:)
  main(event)
end
