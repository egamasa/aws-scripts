require 'base64'
require 'net/http'
require 'open-uri'
require 'rexml/document'
require 'uri'
require_relative 'area'
require_relative 'key'

module Radiko
  class Client
    VERSION = '1.4.1'
    FULL_KEY = Radiko::FULL_KEY
    AREA_LIST = Radiko::AREA_LIST

    def get_stations
      uri = URI.parse('https://radiko.jp/v3/station/region/full.xml')
      response = Net::HTTP.get(uri)
      xml_doc = REXML::Document.new(response)
      stations = []
      xml_doc
        .elements
        .each('region/stations/station') do |station|
          info = {}
          station.elements.each { |tag| info[tag.name] = tag.text }
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
      xml_doc
        .elements
        .each('urls/url') do |url|
          if url.attributes['timefree'] == timefree_flag &&
               url.attributes['areafree'] == areafree_flag
            base_urls << url.elements['playlist_create_url'].text
          end
        end

      base_urls
    end

    def get_live_stream_info(station_id)
      return {} unless is_available_station_id?(station_id)

      auth_token = get_auth_token_by_station_id(station_id)
      base_urls = get_stream_base_urls(station_id)

      { auth_token:, url: "#{base_urls[0]}?station_id=#{station_id}&l=15&lsid=&type=b" }
    end

    def get_timefree_stream_info(station_id, ft, to)
      return {} unless is_available_station_id?(station_id)
      raise 'Invalid ft' unless ft.match?(/\d{14}/)
      raise 'Invalid to' unless to.match?(/\d{14}/)

      auth_token = get_auth_token_by_station_id(station_id)
      base_urls = get_stream_base_urls(station_id, timefree: true)

      { auth_token:, url: "#{base_urls[-1]}?station_id=#{station_id}&l=15&ft=#{ft}&to=#{to}" }
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

      coordinate = "#{AREA_LIST[area_id][0]},#{AREA_LIST[area_id][1]},gps"
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
