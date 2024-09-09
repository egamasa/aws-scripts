require 'base64'
require 'net/http'
require 'open-uri'
require 'rexml/document'
require 'uri'
require_relative 'key'

module Radiko
  class Client
    VERSION = '1.4.1'
    FULL_KEY = Radiko::FULL_KEY
    COORDINATES_LIST = {
      'JP1' => [43.064615, 141.346807], 'JP2' => [40.824308, 140.739998], 'JP3' => [39.703619, 141.152684],
      'JP4' => [38.268837, 140.8721], 'JP5' => [39.718614, 140.102364], 'JP6' => [38.240436, 140.363633],
      'JP7' => [37.750299, 140.467551], 'JP8' => [36.341811, 140.446793], 'JP9' => [36.565725, 139.883565],
      'JP10' => [36.390668, 139.060406], 'JP11' => [35.856999, 139.648849], 'JP12' => [35.605057, 140.123306],
      'JP13' => [35.689488, 139.691706], 'JP14' => [35.447507, 139.642345], 'JP15' => [37.902552, 139.023095],
      'JP16' => [36.695291, 137.211338], 'JP17' => [36.594682, 136.625573], 'JP18' => [36.065178, 136.221527],
      'JP19' => [35.664158, 138.568449], 'JP20' => [36.651299, 138.180956], 'JP21' => [35.391227, 136.722291],
      'JP22' => [34.97712, 138.383084], 'JP23' => [35.180188, 136.906565], 'JP24' => [34.730283, 136.508588],
      'JP25' => [35.004531, 135.86859], 'JP26' => [35.021247, 135.755597], 'JP27' => [34.686297, 135.519661],
      'JP28' => [34.691269, 135.183071], 'JP29' => [34.685334, 135.832742], 'JP30' => [34.225987, 135.167509],
      'JP31' => [35.503891, 134.237736], 'JP32' => [35.472295, 133.0505], 'JP33' => [34.661751, 133.934406],
      'JP34' => [34.39656, 132.459622], 'JP35' => [34.185956, 131.470649], 'JP36' => [34.065718, 134.55936],
      'JP37' => [34.340149, 134.043444], 'JP38' => [33.841624, 132.765681], 'JP39' => [33.559706, 133.531079],
      'JP40' => [33.606576, 130.418297], 'JP41' => [33.249442, 130.299794], 'JP42' => [32.744839, 129.873756],
      'JP43' => [32.789827, 130.741667], 'JP44' => [33.238172, 131.612619], 'JP45' => [31.911096, 131.423893],
      'JP46' => [31.560146, 130.557978], 'JP47' => [26.2124, 127.680932]
    }

    def get_stations
      uri = URI.parse('https://radiko.jp/v3/station/region/full.xml')
      response = Net::HTTP.get(uri)
      xml_doc = REXML::Document.new(response)
      stations = []
      xml_doc.elements.each('region/stations/station') do |station|
        info = {}
        station.elements.each do |tag|
          info[tag.name] = tag.text
        end
        stations << info
      end

      stations
    end

    def get_station(station_id)
      stations = get_stations
      stations.find { |station| station['id'] == station_id } || {}
    end

    def get_station_ids
      get_stations.map { |station| station['id'] }
    end

    def is_available_station_id?(station_id)
      get_station_ids.include?(station_id)
    end

    def get_stream_base_urls(station_id, timefree: false, areafree: false)
      return [] unless is_available_station_id?(station_id)

      uri = URI.parse("https://radiko.jp/v3/station/stream/aSmartPhone7o/#{station_id}.xml")
      response = Net::HTTP.get(uri)
      xml_doc = REXML::Document.new(response)
      timefree_flag = timefree ? '1' : '0'
      areafree_flag = areafree ? '1' : '0'
      base_urls = []
      xml_doc.elements.each('urls/url') do |url|
        if url.attributes['timefree'] == timefree_flag && url.attributes['areafree'] == areafree_flag
          base_urls << url.elements['playlist_create_url'].text
        end
      end

      base_urls
    end

    def get_live_stream_info(station_id)
      return {} unless is_available_station_id?(station_id)

      auth_token = get_auth_token_by_station_id(station_id)
      base_urls = get_stream_base_urls(station_id)

      {
        auth_token:,
        url: "#{base_urls[0]}?station_id=#{station_id}&l=15&lsid=&type=b"
      }
    end

    def get_timefree_stream_info(station_id, ft, to)
      return {} unless is_available_station_id?(station_id)
      raise 'Invalid ft' unless ft.match?(/\d{14}/)
      raise 'Invalid to' unless to.match?(/\d{14}/)

      auth_token = get_auth_token_by_station_id(station_id)
      base_urls = get_stream_base_urls(station_id, timefree: true)

      {
        auth_token:,
        url: "#{base_urls[-1]}?station_id=#{station_id}&l=15&ft=#{ft}&to=#{to}"
      }
    end

    def get_area_id_by_station_id(station_id)
      station = get_station(station_id)
      station['area_id'] || ''
    end

    def get_auth_token_by_station_id(station_id)
      return '' unless is_available_station_id?(station_id)

      area_id = get_area_id_by_station_id(station_id)
      get_auth_token(area_id)
    end

    private

    def get_auth_token(area_id)
      raise 'Invalid area_id' unless area_id.match?(/JP[1-47]/)

      uri = URI.parse('https://radiko.jp/v2/api/auth1')
      auth1_headers = {
        'X-Radiko-App' => 'aSmartPhone7o',
        'X-Radiko-App-Version' => VERSION,
        'X-Radiko-Device' => 'Ruby.radiko',
        'X-Radiko-User' => 'dummy_user'
      }
      response1 = Net::HTTP.get_response(uri, auth1_headers)
      raise 'Auth1 failed' unless response1.is_a?(Net::HTTPSuccess)

      auth_token = response1['X-Radiko-AuthToken']
      key_offset = response1['X-Radiko-KeyOffset'].to_i
      key_length = response1['X-Radiko-KeyLength'].to_i
      partial_key = Base64.strict_encode64(Base64.decode64(FULL_KEY)[key_offset, key_length])

      coordinate = "#{COORDINATES_LIST[area_id][0]},#{COORDINATES_LIST[area_id][1]},gps"
      uri2 = URI.parse('https://radiko.jp/v2/api/auth2')
      auth2_headers = {
        'X-Radiko-App' => 'aSmartPhone7o',
        'X-Radiko-App-Version' => VERSION,
        'X-Radiko-AuthToken' => auth_token,
        'X-Radiko-Connection' => 'wifi',
        'X-Radiko-Device' => 'Ruby.radiko',
        'X-Radiko-Location' => coordinate,
        'X-Radiko-PartialKey' => partial_key,
        'X-Radiko-User' => 'dummy_user'
      }
      response2 = Net::HTTP.get_response(uri2, auth2_headers)
      raise 'Auth2 failed' unless response2.is_a?(Net::HTTPSuccess)

      auth_token
    end
  end
end
