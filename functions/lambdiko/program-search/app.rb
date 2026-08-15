require 'aws-sdk-lambda'
require 'aws-sdk-sns'
require 'date'
require 'json'
require 'logger'
require 'net/http'
require 'rexml/document'
require 'time'
require 'uri'

LOGGER = Logger.new($stdout)
WDAY_LIST = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 }.freeze

USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.7258.67 Safari/537.36'

HIBIKI_API_HEADERS = {
  'Referer' => 'http://hibiki-radio.jp/',
  'X-Requested-With' => 'XMLHttpRequest',
  'Origin' => 'http://hibiki-radio.jp',
  'User-Agent' => USER_AGENT
}.freeze

# 直近の指定曜日の日付を算出
def prev_date_of_week(week, include_today: true)
  wday = WDAY_LIST.fetch(week)
  base_date = Date.today - (include_today ? 0 : 1)
  days_ago = (base_date.wday - wday) % 7

  base_date - days_ago
end

def remove_html_tags(text)
  text.to_s.gsub(%r{</?[^>]+?>}, '').gsub(/\s+/, ' ').strip
end

def zenkaku_to_hankaku(text)
  text.to_s.tr('Ａ-Ｚａ-ｚ０-９　', 'A-Za-z0-9 ')
end

def http_get_xml(url)
  res = Net::HTTP.get_response(URI.parse(url))
  return REXML::Document.new(res.body) if res.is_a?(Net::HTTPSuccess)

  raise "Failed to fetch XML: HTTP #{res.code} - #{url}"
end

def http_get_json(url, headers = {})
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')

  req = Net::HTTP::Get.new(uri.request_uri)
  headers.each { |key, value| req[key] = value }

  res = http.request(req)
  return JSON.parse(res.body) if res.is_a?(Net::HTTPSuccess)

  raise "Failed to fetch JSON: HTTP #{res.code} - #{url}"
end

# radiko 番組表（日付・放送局ID指定）取得
def radiko_program_xml(date, station_id)
  url = "https://radiko.jp/v3/program/station/date/#{date.strftime('%Y%m%d')}/#{station_id}.xml"
  http_get_xml(url)
end

# radiko 番組表から放送局名抽出
def parse_station_name(xml_doc, station_id = nil)
  stations = xml_doc.elements.to_a('//station')
  return stations.first&.elements['name']&.text unless station_id

  stations.find { |s| s.attributes['id'] == station_id }&.elements['name']&.text
end

# radiko 番組検索
def search_radiko_programs(xml_doc, station_id, target: 'title', keyword:, custom_title: nil)
  station_name = parse_station_name(xml_doc)
  programs = xml_doc.elements.to_a('//progs/prog')

  programs
    .select { |prog| prog.elements[target]&.text&.include?(keyword) }
    .map do |prog|
      {
        title: custom_title || prog.elements['title']&.text,
        station_id: station_id,
        ft: prog.attributes['ft'],
        to: prog.attributes['to'],
        metadata: {
          title: prog.elements['title']&.text,
          artist: prog.elements['pfm']&.text,
          album: custom_title || prog.elements['title']&.text,
          album_artist: station_name,
          date: xml_doc.elements['//progs/date']&.text,
          comment:
            "#{remove_html_tags(prog.elements['desc']&.text)}#{remove_html_tags(prog.elements['info']&.text)}",
          img: prog.elements['img']&.text
        }
      }
    end
end

# らじる 番組表（日付指定）取得
def radiru_program_list(date)
  url =
    "https://www.nhk.or.jp/radio-api/app/v1/web/ondemand/corners?onair_date=#{date.strftime('%Y%m%d')}"
  http_get_json(url)
end

# らじる 番組情報取得
def get_radiru_program_info(program)
  url =
    "https://www.nhk.or.jp/radio-api/app/v1/web/ondemand/series?site_id=#{program['series_site_id']}&corner_site_id=#{program['corner_site_id']}"
  http_get_json(url)
end

# らじる 番組開始＆終了時刻抽出
def parse_radiru_aa_contents_id(aa_contents_id)
  data = aa_contents_id.split(';')
  start_time = Time.strptime(data[4][/^[^_]+/], '%Y-%m-%dT%H:%M:%S%z')
  end_time = Time.strptime(data[4][/[^_]+$/], '%Y-%m-%dT%H:%M:%S%z')

  [start_time.strftime('%Y%m%d%H%M00'), end_time.strftime('%Y%m%d%H%M00')]
end

# らじる 番組検索（番組タイトルのみ対応）
def search_radiru_programs(list, keyword:, custom_title: nil)
  onair_date = list['onair_date']
  programs_list = list['corners']

  extracted_programs = programs_list.select { |prog| prog['title']&.include?(keyword) }

  extracted_programs.flat_map do |program|
    program_info = get_radiru_program_info(program)
    program_info['episodes'].filter_map do |episode|
      ft, to = parse_radiru_aa_contents_id(episode['aa_contents_id'])
      next unless ft.include?(onair_date)

      station_id =
        (
          if program_info['radio_broadcast'].split(',').count == 1
            "NHK-#{program_info['radio_broadcast']}"
          else
            'NHK'
          end
        )

      {
        title: custom_title || program_info['title'],
        station_id: station_id,
        ft: ft,
        to: to,
        stream_url: episode['stream_url'],
        metadata: {
          title: zenkaku_to_hankaku(episode['program_title']),
          artist: nil,
          album: custom_title || program_info['title'],
          album_artist: 'NHK',
          date: onair_date,
          comment: remove_html_tags(program_info['series_description']),
          img: program_info['thumbnail_url']
        }
      }
    end
  end
end

# 響 番組表（曜日指定）取得
def hibiki_program_list(wday)
  url = "https://vcms-api.hibiki-radio.jp/api/v1/programs?day_of_week=#{wday}"
  http_get_json(url, HIBIKI_API_HEADERS)
end

# 響 番組情報取得
def get_hibiki_program_info(access_id)
  url = "https://vcms-api.hibiki-radio.jp/api/v1/programs/#{access_id}"
  http_get_json(url, HIBIKI_API_HEADERS)
end

# 響 番組検索
# targets は Array（複数指定可能）
def search_hibiki_programs(list, targets: ['name'], keyword:, custom_title: nil)
  programs =
    list.select { |program| targets.any? { |target| program[target]&.to_s&.include?(keyword) } }

  programs.map do |program|
    program_info = get_hibiki_program_info(program['access_id'])

    {
      title: custom_title || program_info['name'].tr('　', ' ').squeeze(' '),
      station_id: 'HiBiKi',
      ft: program_info['episode_updated_at']&.delete('^0-9') || '',
      # 終了時刻データは存在しないため、to は video_id の送信に使用する
      to: program_info['episode']['video']['id'],
      metadata: {
        title: program_info['episode']['name'],
        artist: program_info['cast'],
        album: custom_title || program_info['name'].tr('　', ' ').squeeze(' '),
        album_artist: 'HiBiKi Radio Station',
        date: program_info['episode_updated_at']&.delete('^0-9')&.[](0..7) || '',
        comment:
          remove_html_tags(
            program_info['episode']['episode_parts'][0]['description'].tr('　', ' ').squeeze(' ')
          ),
        img: program_info['sp_image_url']
      }
    }
  end
end

def sns_publish(message)
  sns = Aws::SNS::Client.new
  sns.publish(topic_arn: ENV['SNS_TOPIC_ARN'], message: message.to_json)
end

def send_notify(status: nil, description:)
  title =
    case status
    when :info
      'リクエスト成功'
    when :warn
      '検索結果なし'
    when :error
      'リクエストエラー'
    else
      '検索テスト'
    end

  message = {
    service: 'Lambdiko',
    title:,
    status: status.to_s.upcase,
    description:,
    timestamp: Time.now
  }
  sns_publish(message)
end

def main(event, context)
  mode =
    case event['station_id'].to_s.upcase
    when 'NHK'
      :radiru
    when 'HIBIKI'
      :hibiki
    else
      :radiko
    end
  is_today = event.fetch('today', true)
  program_date = prev_date_of_week(event['week'].to_sym, include_today: is_today)

  # 検索テストモード（ダウンロード実行しない）
  is_test = event.fetch('test', false)

  programs, download_func_name =
    case mode
    when :radiko
      xml = radiko_program_xml(program_date, event['station_id'])

      [
        search_radiko_programs(
          xml,
          event['station_id'],
          target: event['target'],
          keyword: event['keyword'],
          custom_title: event['title']
        ),
        ENV['RADIKO_DL_FUNC_NAME']
      ]
    when :radiru
      list = radiru_program_list(program_date)

      [
        search_radiru_programs(list, keyword: event['keyword'], custom_title: event['title']),
        ENV['RADIRU_DL_FUNC_NAME']
      ]
    when :hibiki
      list = hibiki_program_list(event['week'])

      [
        search_hibiki_programs(
          list,
          targets: Array(event['target'] || 'name'),
          keyword: event['keyword'],
          custom_title: event['title']
        ),
        ENV['HIBIKI_DL_FUNC_NAME']
      ]
    else
      [[], nil]
    end

  # 検索テストモード: 検索結果を通知して処理終了
  if is_test
    return(
      send_notify(
        description:
          "Event\n```json\n#{JSON.pretty_generate(event, ascii_only: false)}\n```\n\nResults\n```json\n#{JSON.pretty_generate(programs, ascii_only: false)}\n```"
      )
    )
  end

  if programs.empty?
    LOGGER.warn("No program found: #{JSON.generate(event, ascii_only: false)}")
    return send_notify(status: :warn, description: "#{event['target']}: #{event['keyword']}")
  end

  lambda_client = Aws::Lambda::Client.new
  programs.each do |program|
    lambda_client.invoke(
      function_name: download_func_name,
      invocation_type: 'Event',
      payload: program.to_json
    )

    LOGGER.info(
      "Download requested -> #{download_func_name}: #{JSON.generate(program, ascii_only: false)}"
    )
    send_notify(
      status: :info,
      description:
        "#{program[:metadata][:title]}\n#{program[:station_id]} / #{program[:ft]}-#{program[:to]}"
    )
  end
end

def lambda_handler(event:, context:)
  main(event, context)
rescue StandardError => e
  LOGGER.error("Error [#{e.class}] #{e.message}")
  LOGGER.error(e.backtrace.join("\n"))
  send_notify(status: :error, description: "#{e.class}\n```\n#{e.message}\n```")
end
