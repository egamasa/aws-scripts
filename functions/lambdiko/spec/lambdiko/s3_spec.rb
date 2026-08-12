require 'spec_helper'
require 'lambdiko/s3'

RSpec.describe 'Lambdiko::S3' do
  describe '#upload_to_s3' do
    let(:bucket_name) { 'test-bucket' }
    let(:file_name) { 'test_file.m4a' }
    let(:file_path) { '/tmp/test_file.m4a' }
    let(:s3_client) { instance_double(Aws::S3::Client) }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('BUCKET_NAME').and_return(bucket_name)
      allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
      allow(s3_client).to receive(:put_object)
      # テスト用の空ファイルを作成
      File.write(file_path, 'dummy audio content')
    end

    after { File.delete(file_path) if File.exist?(file_path) }

    it 's3:// 形式のパスを返す' do
      result = upload_to_s3(file_path, file_name)
      expect(result).to eq("s3://#{bucket_name}/#{file_name}")
    end

    it 'S3::Client#put_object を正しいバケット名とキーで呼び出す' do
      upload_to_s3(file_path, file_name)
      expect(s3_client).to have_received(:put_object).with(
        hash_including(bucket: bucket_name, key: file_name)
      )
    end
  end
end
