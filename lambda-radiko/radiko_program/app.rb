require 'aws-sdk-lambda'
require 'date'
require 'json'
require 'logger'
require 'net/http'
require 'rexml/document'
require 'uri'

WDAY_LIST = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 }.freeze

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

def search_programs(xml_doc, station_id, target: 'title', keyword:, custom_title: nil)
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

  program_date = prev_date_of_week(event['week'].to_sym)
  xml = radiko_program_xml(program_date, event['station_id'])
  programs =
    search_programs(
      xml,
      event['station_id'],
      target: event['target'],
      keyword: event['keyword'],
      custom_title: event['title']
    )

  if programs.empty?
    logger.info({ text: "No program found: #{event['title']}", event: })
  else
    lambda_client = Aws::Lambda::Client.new
  end

  programs.each do |program|
    res =
      lambda_client.invoke(
        function_name: ENV['DOWNLOAD_FUNCTION_NAME'],
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
