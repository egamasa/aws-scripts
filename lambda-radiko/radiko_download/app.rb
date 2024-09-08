require 'base64'
require 'json'
require 'net/http'
require 'open-uri'
require 'rexml/document'
require 'uri'
require_relative 'lib/radiko'

def main(event)
  client = Radiko::Client.new
end

def lambda_handler(event:, context:)
  main(event)
end
