import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';
import 'package:kairanban/core/dictionary.dart';

void main() {
  group('kDictionaryV1', () {
    test('サイズは 4〜8 KB', () {
      expect(kDictionaryV1.length, inInclusiveRange(4096, 8192));
    });

    test('内容が変わっていない（全端末で同一でなければならない）', () {
      // 辞書はプロトコルの一部。変更が必要なら kDictionaryV2 を追加する。
      expect(kDictionaryV1.length, 7828);
      expect(
        sha256.convert(kDictionaryV1).toString(),
        'fc39184a88aa76cbfde64fbcb6b39560ebc34987fb79b164d33e91f463373117',
      );
    });

    test('正しい UTF-8 である', () {
      expect(() => utf8.decode(kDictionaryV1), returnsNormally);
    });

    test('変更できない', () {
      expect(() => kDictionaryV1[0] = 0, throwsUnsupportedError);
    });

    test('災害通知の主要語彙を含む', () {
      final text = utf8.decode(kDictionaryV1);
      const words = [
        '避難所', '物資', '給水', '炊き出し', '毛布', '水', '食料', 'おむつ',
        'トイレ', '医療', '巡回', '停電', '断水', '復旧', '通行止め', '受付',
        '配布', '到着', '開設', '閉鎖', '小学校', '中学校', '公民館', '体育館',
        '役場', '市役所', '町役場', '防災課', '災害対策本部', '午前', '午後',
        '時', '分', 'から', 'まで', 'です', 'ます', 'ください', 'とどきました',
        'はじまります', 'おわりました', '注意してください', '余震', '土砂',
        '火災', '詐欺', 'ボランティア', '高齢者',
      ];
      for (final w in words) {
        expect(text, contains(w), reason: w);
      }
    });

    test('v1 の見出しテンプレートの固定部分を含む（辞書は凍結。v2 で足した例文は対象外）', () {
      final text = utf8.decode(kDictionaryV1);
      const v1Templates = <String, String>{
        'general': '{場所}からの お知らせです',
        'evacuation': '{場所}に 避難してください',
        'shelter': '{場所}が 避難所として 開きました',
        'supply': '{場所}に {物資}が とどきました',
        'water': '{場所}で 給水を しています',
        'food': '{場所}で 炊き出しを します',
        'medical': '{場所}で 医師の 診察が 受けられます',
        'traffic': '{場所}の 道路は 通行止めです',
        'lifeline': '{場所}の {電気}が 復旧しました',
        'warning': '{余震}に 注意してください',
        'sanitation': '{場所}に トイレが できました',
        'shops': '{場所}の {お店}が 開いています',
        'admin': '{場所}で {手続き}の 受付を しています',
        'request': '{場所}で {物資}が 足りません',
        'damage': '{場所}で 被害が 出ています',
      };
      for (final entry in v1Templates.entries) {
        // 穴埋め {…} を取り除いた固定部分が辞書に含まれること。
        final fixedParts = entry.value
            .split(RegExp(r'\{[^}]*\}'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty);
        for (final part in fixedParts) {
          expect(text, contains(part), reason: '${entry.key}: $part');
        }
      }
      // 現行の既定テンプレートも v1 と同じ（例文の先頭は変えていない）。
      for (final c in NoticeCategory.values) {
        if (c == NoticeCategory.safety) {
          continue; // 安否は個人名を促さない文に変えた（C11）。
        }
        expect(c.titleTemplate, v1Templates[c.name], reason: c.name);
      }
    });

    test('頻出語は末尾に置かれている', () {
      final tail = utf8.decode(
        kDictionaryV1.sublist(kDictionaryV1.length - 1024),
        allowMalformed: true,
      );
      for (final w in ['避難所', '午前', '午後', 'です', 'ます', 'ください',
          'とどきました', '注意してください', '物資', '給水']) {
        expect(tail, contains(w), reason: w);
      }
    });
  });
}
