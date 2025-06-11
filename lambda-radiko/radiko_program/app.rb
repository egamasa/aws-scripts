require 'aws-sdk-lambda'
require 'date'
require 'json'
require 'logger'
require 'net/http'
require 'rexml/document'
require 'time'
require 'uri'

WDAY_LIST = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 }.freeze

# 直近の指定曜日の日付を算出
def prev_date_of_week(week, include_today: true)
  wday = WDAY_LIST[week]
  base_date = Date.today - (include_today ? 0 : 1)
  base_date_wday = base_date.wday
  days_ago = (base_date_wday - wday) % 7
  prev_date = base_date - days_ago

  return prev_date
end

def remove_html_tags(text)
  text.to_s.gsub(%r{</?[^>]+?>}, '').gsub(/\s+/, ' ').strip
end

def zenkaku_to_hankaku(text)
  text.to_s.tr('Ａ-Ｚａ-ｚ０-９　', 'A-Za-z0-9 ')
end

# radiko 番組表（日付・放送局ID指定）取得
def radiko_program_xml(date, station_id)
  url = "https://radiko.jp/v3/program/station/date/#{date.strftime('%Y%m%d')}/#{station_id}.xml"

  uri = URI.parse(url)
  res = Net::HTTP.get_response(uri)

  if res.is_a?(Net::HTTPSuccess)
    xml_data = res.body
    xml_doc = REXML::Document.new(xml_data)

    return xml_doc
  end
end

# radiko 番組表から放送局名抽出
def parse_station_name(xml_doc, station_id = nil)
  if station_id
    xml_doc
      .elements
      .to_a('//station')
      .each do |station|
        return station.elements['name'].text if station.attributes['id'] == station_id
      end
  else
    return xml_doc.elements.to_a('//station').first&.elements['name'].text
  end
end

# radiko 番組検索
def search_radiko_programs(xml_doc, station_id, target: 'title', keyword:, custom_title: nil)
  station_name = parse_station_name(xml_doc)

  programs = xml_doc.elements.to_a('//progs/prog')

  result =
    programs
      .select do |program|
        title = program.elements[target]&.text
        title && title.include?(keyword)
      end
      .map do |program|
        {
          title: custom_title || program.elements['title']&.text,
          station_id: station_id,
          ft: program.attributes['ft'],
          to: program.attributes['to'],
          metadata: {
            title: program.elements['title']&.text,
            artist: program.elements['pfm']&.text,
            album: custom_title || program.elements['title']&.text,
            album_artist: station_name,
            date: xml_doc.elements['//progs/date']&.text,
            comment:
              "#{remove_html_tags(program.elements['desc']&.text)}#{remove_html_tags(program.elements['info']&.text)}",
            img: program.elements['img']&.text
          }
        }
      end

  return result
end

# らじる 番組表（日付指定）取得
def radiru_program_list(date)
  url =
    "https://www.nhk.or.jp/radio-api/app/v1/web/ondemand/corners?onair_date=#{date.strftime('%Y%m%d')}"

  uri = URI.parse(url)
  res = Net::HTTP.get_response(uri)

  if res.is_a?(Net::HTTPSuccess)
    json_data = res.body
    program_list = JSON.parse(json_data)

    return program_list
  end
end

# らじる 番組情報取得
def get_radiru_program_info(program)
  url =
    "https://www.nhk.or.jp/radio-api/app/v1/web/ondemand/series?site_id=#{program['series_site_id']}&corner_site_id=#{program['corner_site_id']}"

  uri = URI.parse(url)
  res = Net::HTTP.get_response(uri)

  if res.is_a?(Net::HTTPSuccess)
    json_data = res.body
    program_info = JSON.parse(json_data)

    return program_info
  end
end

# らじる 番組開始＆終了時刻抽出
def parse_radiru_aa_contents_id(aa_contents_id)
  data = aa_contents_id.split(';')

  start_time = Time.strptime(data[4][/^[^_]+/], '%Y-%m-%dT%H:%M:%S%z')
  end_time = Time.strptime(data[4][/[^_]+$/], '%Y-%m-%dT%H:%M:%S%z')
  ft = start_time.strftime('%Y%m%d%H%M00')
  to = end_time.strftime('%Y%m%d%H%M00')

  return ft, to
end

# らじる 番組検索（番組タイトルのみ対応）
def search_radiru_programs(list, keyword:, custom_title: nil)
  onair_date = list['onair_date']
  programs_list = list['corners']

  extracted_programs =
    programs_list.select do |program|
      title = program['title']
      title && title.include?(keyword)
    end

  programs = []
  extracted_programs.each do |program|
    program_info = get_radiru_program_info(program)
    program_info['episodes'].each do |episode|
      ft, to = parse_radiru_aa_contents_id(episode['aa_contents_id'])

      if program_info['radio_broadcast'].split(',').count == 1
        station_id = "NHK-#{program_info['radio_broadcast']}"
      else
        station_id = 'NHK'
      end

      programs << {
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

  return programs
end

def main(event, context)
  logger = Logger.new($stdout, progname: 'radikoProgram')
  logger.formatter =
    proc do |severity, datetime, progname, msg|
      log = {
        timestamp: datetime.iso8601,
        level: severity,
        progname: progname,
        message: msg[:text],
        event: msg[:event]
      }
      log.to_json + "\n"
    end

  if event['station_id'] == 'NHK'
    mode = :radiru
  else
    mode = :radiko
  end

  is_today = event.key?('today') ? event['today'] : true
  program_date = prev_date_of_week(event['week'].to_sym, include_today: is_today)

  case mode
  when :radiko
    xml = radiko_program_xml(program_date, event['station_id'])
    programs =
      search_radiko_programs(
        xml,
        event['station_id'],
        target: event['target'],
        keyword: event['keyword'],
        custom_title: event['title']
      )

    download_func_name = ENV['RADIKO_DL_FUNC_NAME']
  when :radiru
    list = radiru_program_list(program_date)
    programs = search_radiru_programs(list, keyword: event['keyword'], custom_title: event['title'])

    download_func_name = ENV['RADIRU_DL_FUNC_NAME']
  else
    programs = []
  end

  if programs.empty?
    logger.info({ text: "No program found: #{event['title']}", event: })
  else
    lambda_client = Aws::Lambda::Client.new
  end

  programs.each do |program|
    res =
      lambda_client.invoke(
        function_name: download_func_name,
        invocation_type: 'Event',
        payload: program.to_json
      )

    if res.status_code == 202
      logger.info({ text: "Download requested: #{program[:title]}", event: })
    else
      logger.error({ text: "Download request failed: #{program[:title]}", event: })
    end
  end
end

def lambda_handler(event:, context:)
  main(event, context)
end
