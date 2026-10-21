import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/core/categories.dart';

void main() {
  group('NoticeCategory', () {
    test('16 種あり、コードは宣言順 0..15', () {
      expect(NoticeCategory.values.length, 16);
      for (var i = 0; i < NoticeCategory.values.length; i++) {
        expect(NoticeCategory.values[i].code, i);
      }
      expect(NoticeCategory.general.code, 0);
      expect(NoticeCategory.evacuation.code, 1);
      expect(NoticeCategory.shelter.code, 2);
      expect(NoticeCategory.supply.code, 3);
      expect(NoticeCategory.water.code, 4);
      expect(NoticeCategory.food.code, 5);
      expect(NoticeCategory.medical.code, 6);
      expect(NoticeCategory.safety.code, 7);
      expect(NoticeCategory.traffic.code, 8);
      expect(NoticeCategory.lifeline.code, 9);
      expect(NoticeCategory.warning.code, 10);
      expect(NoticeCategory.sanitation.code, 11);
      expect(NoticeCategory.shops.code, 12);
      expect(NoticeCategory.admin.code, 13);
      expect(NoticeCategory.request.code, 14);
      expect(NoticeCategory.damage.code, 15);
    });

    test('ラベルは docs/05_dart_api.md の通り（v2: 安否・トイレ・店舗を改名）', () {
      const expected = [
        'お知らせ',
        '避難情報',
        '避難所',
        '物資',
        '給水',
        '炊き出し・食事',
        '医療・救護',
        '安否・名簿の 案内',
        '交通・道路',
        'ライフライン',
        '注意喚起',
        'トイレ・入浴・洗濯',
        '店舗・燃料・銀行',
        '行政手続き',
        '支援要請',
        '被害情報',
      ];
      expect(NoticeCategory.values.map((c) => c.label).toList(), expected);
    });

    test('既定 TTL は docs/02_protocol.md の表の通り（v2: 支援要請・ライフライン・安否は 3 日）', () {
      const h12 = Duration(hours: 12);
      const d1 = Duration(days: 1);
      const d3 = Duration(days: 3);
      const d7 = Duration(days: 7);
      const expected = {
        NoticeCategory.general: d3,
        NoticeCategory.evacuation: d3,
        NoticeCategory.shelter: d7,
        NoticeCategory.supply: h12,
        NoticeCategory.water: h12,
        NoticeCategory.food: h12,
        NoticeCategory.medical: d1,
        NoticeCategory.safety: d3,
        NoticeCategory.traffic: d1,
        NoticeCategory.lifeline: d3,
        NoticeCategory.warning: d1,
        NoticeCategory.sanitation: d1,
        NoticeCategory.shops: d1,
        NoticeCategory.admin: d7,
        NoticeCategory.request: d3,
        NoticeCategory.damage: d3,
      };
      for (final entry in expected.entries) {
        expect(entry.key.defaultTtl, entry.value, reason: entry.key.name);
      }
    });

    test('見出しテンプレートは穴埋め付き', () {
      expect(NoticeCategory.supply.titleTemplate, '{場所}に {物資}が とどきました');
      for (final c in NoticeCategory.values) {
        expect(c.titleTemplate, isNotEmpty, reason: c.name);
        expect(c.titleTemplate, contains('{'), reason: c.name);
        expect(c.titleTemplate, contains('}'), reason: c.name);
      }
    });

    test('fromCode は範囲外を general にする', () {
      for (final c in NoticeCategory.values) {
        expect(NoticeCategory.fromCode(c.code), c);
      }
      expect(NoticeCategory.fromCode(-1), NoticeCategory.general);
      expect(NoticeCategory.fromCode(16), NoticeCategory.general);
      expect(NoticeCategory.fromCode(255), NoticeCategory.general);
    });
  });
}
