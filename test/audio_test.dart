import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/models/audio.dart';

void main() {
  group('AudioTones', () {
    test('解析音色列表并丢掉无效 id', () {
      final tones = AudioTones.fromJson(const {
        'book_id': '7596021152615517209',
        'relate_book_id': '7596021152615517209',
        'genre_type': 0,
        'tones': [
          {'id': 74, 'title': '成熟大叔音升级版', 'icon': 'https://cdn/a.png'},
          {'id': 0, 'title': '坏数据'},
        ],
      });
      expect(tones.tones.length, 1);
      expect(tones.tones.first.id, 74);
      expect(tones.tones.first.title, '成熟大叔音升级版');
      expect(tones.relateBookId, '7596021152615517209');
      expect(tones.hasRecordedAudio, isFalse);
      expect(tones.isEmpty, isFalse);
    });

    test('genre_type=1 表示有声书', () {
      final tones = AudioTones.fromJson(const {'genre_type': 1, 'tones': []});
      expect(tones.hasRecordedAudio, isTrue);
      expect(tones.isEmpty, isTrue);
    });

    test('缺字段按默认值处理', () {
      final tones = AudioTones.fromJson(const {});
      expect(tones.bookId, '');
      expect(tones.tones, isEmpty);
    });
  });

  group('AudioTrack', () {
    test('解析播放地址与内容密钥', () {
      final track = AudioTrack.fromJson(const {
        'url': 'https://cdn/a.mp4',
        'backup_url': 'https://cdn/b.mp4',
        'key': '96bc18f364ba19c3',
        'duration_ms': 0,
        'encrypted': true,
      });
      expect(track.url, 'https://cdn/a.mp4');
      expect(track.keyHex, '96bc18f364ba19c3');
      expect(track.encrypted, isTrue);
      expect(track.isPlayable, isTrue);
    });

    test('空地址不可播放', () {
      expect(const AudioTrack().isPlayable, isFalse);
    });
  });
}