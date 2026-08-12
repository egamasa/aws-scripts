require 'aws-sdk-s3'

def upload_to_s3(file_path, file_name)
  s3_bucket = ENV['BUCKET_NAME']
  File.open(file_path, 'rb') do |file|
    Aws::S3::Client.new.put_object(bucket: s3_bucket, key: file_name, body: file)
  end

  "s3://#{s3_bucket}/#{file_name}"
end
