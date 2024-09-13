require 'aws-sdk-s3'
require 'base64'
require 'http'
require 'json'
require 'net/http'
require 'open-uri'
require 'rexml/document'
require 'securerandom'
require 'uri'
require_relative 'lib/radiko'

RETRY_LIMIT = 3
THREAD_LIMIT = 3

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

  uri = URI.parse(stream_info[:url])
  headers = {
    'X-Radiko-AuthToken' => stream_info[:auth_token],
    'X-Radiko-Device' => 'Ruby.radiko',
    'X-Radiko-User' => 'dummy_user'
  }
  pre_playlist = Net::HTTP.get_response(uri, headers)

  playlist_urls = []
  pre_playlist.body.lines do |line|
    next if line.strip.empty?
    next if line.strip.start_with?('#')
    url = line.strip
    playlist_urls << url
  end

  segment_urls = []
  playlist_urls.each do |playlist_url|
    uri = URI.parse(playlist_url)
    playlist = Net::HTTP.get_response(uri)

    playlist.body.lines do |line|
      next if line.strip.empty?
      next if line.strip.start_with?('#')
      url = line.strip
      segment_urls << url
    end
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
    result = `#{ffmpeg_cmd}`
    p result

    upload_to_s3(aac_file_path, aac_file_name)
  end
end

def lambda_handler(event:, context:)
  main(event)
end
