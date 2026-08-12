require 'spec_helper'
require 'open3'
require 'lambdiko/ffmpeg'

RSpec.describe 'Lambdiko::FFmpeg' do
  describe '#run_ffmpeg' do
    let(:segment_list) { '/tmp/segment_files.txt' }
    let(:output_path) { '/tmp/output.m4a' }
    let(:metadata_options) { %w[-metadata title=テスト] }
    let(:artwork_option) { nil }

    context '正常終了のとき' do
      before do
        status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture3).and_return(['', '', status])
      end

      it '例外を発生させない' do
        expect {
          run_ffmpeg(segment_list, output_path, metadata_options, artwork_option)
        }.not_to raise_error
      end

      it 'ffmpeg に concat / input / output を含むコマンドを渡す' do
        run_ffmpeg(segment_list, output_path, metadata_options, artwork_option)
        expect(Open3).to have_received(:capture3).with(
          '/opt/bin/ffmpeg',
          '-hide_banner',
          '-y',
          '-safe',
          '0',
          '-f',
          'concat',
          '-i',
          segment_list,
          '-metadata',
          'title=テスト',
          '-c',
          'copy',
          output_path
        )
      end

      context 'artwork_option が指定されているとき' do
        let(:artwork_option) do
          %w[-i /tmp/art.jpg -map 0:a -map 1:v -disposition:1 attached_pic -id3v2_version 3]
        end

        it 'artwork オプションが metadata より前に挿入される' do
          run_ffmpeg(segment_list, output_path, metadata_options, artwork_option)
          expect(Open3).to have_received(:capture3).with(
            '/opt/bin/ffmpeg',
            '-hide_banner',
            '-y',
            '-safe',
            '0',
            '-f',
            'concat',
            '-i',
            segment_list,
            '-i',
            '/tmp/art.jpg',
            '-map',
            '0:a',
            '-map',
            '1:v',
            '-disposition:1',
            'attached_pic',
            '-id3v2_version',
            '3',
            '-metadata',
            'title=テスト',
            '-c',
            'copy',
            output_path
          )
        end
      end
    end

    context 'ffmpeg が失敗したとき' do
      before do
        status = instance_double(Process::Status, success?: false)
        allow(Open3).to receive(:capture3).and_return(['', 'some error', status])
      end

      it 'FFmpeg failed を含む RuntimeError を発生させる' do
        expect {
          run_ffmpeg(segment_list, output_path, metadata_options, artwork_option)
        }.to raise_error(RuntimeError, /FFmpeg failed/)
      end
    end
  end

  describe '#probe_duration' do
    let(:file_path) { '/tmp/output.m4a' }

    context '正常終了のとき' do
      before do
        status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture3).and_return(["#{seconds}\n", '', status])
      end

      context '1時間未満のとき' do
        let(:seconds) { 3 * 60 + 45 } # 3分45秒

        it '時間部分を省略した形式で返す' do
          expect(probe_duration(file_path)).to eq('3m 45s')
        end
      end

      context '1時間以上のとき' do
        let(:seconds) { 2 * 3600 + 15 * 60 + 30 } # 2時間15分30秒

        it '時間を含む形式で返す' do
          expect(probe_duration(file_path)).to eq('2h 15m 30s')
        end
      end

      context 'ちょうど1時間のとき' do
        let(:seconds) { 3600 }

        it '1h 0m 0s を返す' do
          expect(probe_duration(file_path)).to eq('1h 0m 0s')
        end
      end
    end

    context 'ffprobe が失敗したとき' do
      before do
        status = instance_double(Process::Status, success?: false)
        allow(Open3).to receive(:capture3).and_return(['', '', status])
      end

      it '"-h --m --s" を返す' do
        expect(probe_duration(file_path)).to eq('-h --m --s')
      end
    end

    context 'ffprobe の出力が空のとき' do
      before do
        status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture3).and_return(['', '', status])
      end

      it '"-h --m --s" を返す' do
        expect(probe_duration(file_path)).to eq('-h --m --s')
      end
    end
  end
end
