/// 端末から取り出した保存ファイル（messages.bin）の中身を数える。実機・エミュレータの
/// 試験で、何が残ったかを確かめるのに使う（#128 など）。MessageStore が Flutter に
/// 依存するので flutter test で動かす。
///
///   adb exec-out run-as jp.kairanban.kairanban cat files/messages.bin > a.bin
///   STORE=a.bin FIND=見出しの一部 flutter test tool/inspect/inspect_store_test.dart
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/app/test_data.dart';
import 'package:kairanban/core/envelope.dart';
import 'package:kairanban/mesh/message_store.dart';
import 'package:kairanban/mesh/store_file.dart';

void main() {
  final path = Platform.environment['STORE'];
  final want = Platform.environment['FIND'];

  test('保存ファイルの中身', () async {
    final store = MessageStore(FileStoreBackend(path!));
    await store.load();
    final kinds = <MessageKind, int>{};
    var local = 0;
    var test = 0;
    for (final m in store.all) {
      kinds[m.kind] = (kinds[m.kind] ?? 0) + 1;
      if (m.isLocal) {
        local++;
      }
      if (!m.isOpaque && !m.isStub && isTestEnvelope(m.envelope)) {
        test++;
      }
    }
    // ignore: avoid_print
    print('保存 ${store.count} 件（自分の投稿 $local 件、テスト用データ $test 件）'
        ' 種類: ${kinds.entries.map((e) => '${e.key.name} ${e.value}').join('、')}');
    if (want != null && want.isNotEmpty) {
      for (final m in store.all) {
        final notice = m.isOpaque || m.isStub ? null : m.envelope.notice;
        if (notice != null && notice.title.contains(want)) {
          // ignore: avoid_print
          print('見つかった: 「${notice.title}」'
              '${m.isLocal ? '（自分の投稿）' : '（受け取ったもの、転送 ${m.envelope.hop} 回）'}');
        }
      }
    }
  }, skip: path == null ? 'STORE=保存ファイル を付けて動かす' : false);
}
