require 'spec_helper'
require 'lambdiko/metadata'

RSpec.describe 'Lambdiko::Metadata' do
  describe '#parse_metadata_date' do
    context '正常系' do
      it 'ISO 8601 形式の日付文字列を YYYY-MM-DD に変換する' do
        expect(parse_metadata_date('2024-04-07')).to eq('2024-04-07')
      end

      it 'RFC 2822 形式の日付文字列を YYYY-MM-DD に変換する' do
        expect(parse_metadata_date('Sun, 07 Apr 2024 00:00:00 +0900')).to eq('2024-04-07')
      end

      it 'YYYY/MM/DD 形式の日付文字列を YYYY-MM-DD に変換する' do
        expect(parse_metadata_date('2024/04/07')).to eq('2024-04-07')
      end
    end

    context '異常系' do
      it 'nil を渡すと nil を返す' do
        expect(parse_metadata_date(nil)).to be_nil
      end

      it '空文字を渡すと nil を返す' do
        expect(parse_metadata_date('')).to be_nil
      end

      it 'パースできない文字列を渡すと nil を返す' do
        expect(parse_metadata_date('not-a-date')).to be_nil
      end
    end
  end

  describe '#build_metadata_options' do
    let(:metadata) do
      {
        'title' => '安部礼司',
        'artist' => '安部礼司 / CAST',
        'album' => '安部礼司',
        'album_artist' => 'TOKYO FM',
        'date' => '2024-04-07',
        'comment' => 'テスト放送回'
      }
    end

    it 'すべてのフィールドが存在するとき ffmpeg の -metadata オプション配列を返す' do
      result = build_metadata_options(metadata)

      expect(result).to include('-metadata', 'title=安部礼司')
      expect(result).to include('-metadata', 'artist=安部礼司 / CAST')
      expect(result).to include('-metadata', 'album=安部礼司')
      expect(result).to include('-metadata', 'album_artist=TOKYO FM')
      expect(result).to include('-metadata', 'date=2024-04-07')
      expect(result).to include('-metadata', 'comment=テスト放送回')
    end

    it '値が nil のフィールドはオプションから除外される' do
      metadata['artist'] = nil
      result = build_metadata_options(metadata)

      expect(result).not_to include('artist=')
    end

    it '値が空文字のフィールドはオプションから除外される' do
      metadata['comment'] = ''
      result = build_metadata_options(metadata)

      expect(result).not_to include('comment=')
    end

    it 'date が ISO 8601 形式のとき YYYY-MM-DD に正規化される' do
      metadata['date'] = '2024/04/07'
      result = build_metadata_options(metadata)

      expect(result).to include('-metadata', 'date=2024-04-07')
    end

    it 'date が nil のときオプションから除外される' do
      metadata['date'] = nil
      result = build_metadata_options(metadata)

      expect(result).not_to include('date=')
    end

    it '戻り値は偶数個の要素を持つ（key/value のペア）' do
      result = build_metadata_options(metadata)
      expect(result.size).to be_even
    end
  end

  describe '#build_artwork_option' do
    let(:file_dir) { '/tmp/test_artwork' }
    let(:img_url) { 'https://example.com/image.jpg' }

    # build_artwork_option は download_file に依存するため
    # テスト用にダミー実装を定義してスタブする
    def download_file(_url, _file_path)
      raise 'stub not configured'
    end

    context '画像URLが存在するとき' do
      before do
        allow(self).to receive(:download_file).with(img_url, "#{file_dir}/image.jpg").and_return(
          true
        )
      end

      it 'ffmpeg の artwork 埋め込みオプション配列を返す' do
        result = build_artwork_option({ 'img' => img_url }, file_dir)

        expect(result).to include('-i', "#{file_dir}/image.jpg")
        expect(result).to include('-map', '0:a')
        expect(result).to include('-map', '1:v')
        expect(result).to include('-disposition:1', 'attached_pic')
        expect(result).to include('-id3v2_version', '3')
      end
    end

    context 'ダウンロードが失敗したとき' do
      before { allow(self).to receive(:download_file).and_return(false) }

      it 'nil を返す' do
        result = build_artwork_option({ 'img' => img_url }, file_dir)
        expect(result).to be_nil
      end
    end

    context '画像URLが指定されていないとき' do
      it 'nil のとき nil を返す' do
        expect(build_artwork_option(nil, file_dir)).to be_nil
      end

      it '空文字のとき nil を返す' do
        expect(build_artwork_option({ 'img' => '' }, file_dir)).to be_nil
      end

      it 'img キーが存在しないとき nil を返す' do
        expect(build_artwork_option({}, file_dir)).to be_nil
      end
    end
  end
end
