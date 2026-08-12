require 'logger'
require 'time'

LOGGER = Logger.new($stdout) unless defined?(LOGGER)

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
