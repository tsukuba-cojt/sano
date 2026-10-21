import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairanban/mesh/store_file.dart';

Uint8List bytes(List<int> v) => Uint8List.fromList(v);

void main() {
  group('MemoryStoreBackend', () {
    test('追記した順に読める・rewrite で全置換される', () async {
      final b = MemoryStoreBackend();
      expect(await b.readAll(), isEmpty);
      await b.append(bytes([1, 2]));
      await b.append(bytes([3]));
      expect(await b.readAll(), [bytes([1, 2]), bytes([3])]);
      await b.rewrite([bytes([9])]);
      expect(await b.readAll(), [bytes([9])]);
      expect(b.appendCount, 2);
      expect(b.rewriteCount, 1);
    });

    test('返されるレコードは複製（外から書き換えても影響しない）', () async {
      final b = MemoryStoreBackend();
      final src = bytes([1, 2, 3]);
      await b.append(src);
      src[0] = 99;
      final read = await b.readAll();
      expect(read.single, bytes([1, 2, 3]));
      read.single[1] = 77;
      expect((await b.readAll()).single, bytes([1, 2, 3]));
    });
  });

  group('FileStoreBackend', () {
    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('kairanban_store_');
      path = '${dir.path}/messages.bin';
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('存在しないファイルは空', () async {
      final b = FileStoreBackend(path);
      expect(await b.readAll(), isEmpty);
    });

    test('u32 長さ付きで追記され、順に読める', () async {
      final b = FileStoreBackend(path);
      await b.append(bytes([1, 2, 3]));
      await b.append(bytes([4]));
      await b.append(Uint8List(300));
      final raw = await File(path).readAsBytes();
      expect(raw.sublist(0, 4), [3, 0, 0, 0]);
      expect(raw.sublist(4, 7), [1, 2, 3]);
      expect(raw.sublist(7, 11), [1, 0, 0, 0]);
      expect(raw[11], 4);
      expect(raw.sublist(12, 16), [300 & 0xFF, 300 >> 8, 0, 0]);
      expect(raw.length, 4 + 3 + 4 + 1 + 4 + 300);

      final again = FileStoreBackend(path);
      final records = await again.readAll();
      expect(records.length, 3);
      expect(records[0], bytes([1, 2, 3]));
      expect(records[1], bytes([4]));
      expect(records[2].length, 300);
    });

    test('途中で切れた末尾は捨てられ、以後の追記が壊れない', () async {
      final b = FileStoreBackend(path);
      await b.append(bytes([1, 2, 3]));
      await b.append(bytes([4, 5]));
      // 長さ 100 と宣言して 10 バイトしかない壊れたレコードを足す。
      final file = File(path);
      final before = (await file.readAsBytes()).length;
      await file.writeAsBytes([100, 0, 0, 0, ...List.filled(10, 7)],
          mode: FileMode.append, flush: true);

      final read = await FileStoreBackend(path).readAll();
      expect(read, [bytes([1, 2, 3]), bytes([4, 5])]);
      // 切り捨てられている。
      expect((await file.readAsBytes()).length, before);

      final c = FileStoreBackend(path);
      await c.append(bytes([6]));
      expect(await c.readAll(), [bytes([1, 2, 3]), bytes([4, 5]), bytes([6])]);
    });

    test('長さフィールドだけが残った末尾（4 バイト未満）も捨てる', () async {
      final b = FileStoreBackend(path);
      await b.append(bytes([1]));
      await File(path).writeAsBytes([5, 0], mode: FileMode.append, flush: true);
      expect(await FileStoreBackend(path).readAll(), [bytes([1])]);
      expect((await File(path).readAsBytes()).length, 5);
    });

    test('異常な長さ（0 や上限超過）はそこから先を破損とみなす', () async {
      final b = FileStoreBackend(path);
      await b.append(bytes([1]));
      await File(path).writeAsBytes([0, 0, 0, 0, 1, 2, 3],
          mode: FileMode.append, flush: true);
      expect(await FileStoreBackend(path).readAll(), [bytes([1])]);

      await b.append(bytes([2]));
      await File(path).writeAsBytes([0xFF, 0xFF, 0xFF, 0x7F, 1],
          mode: FileMode.append, flush: true);
      expect(await FileStoreBackend(path).readAll(), [bytes([1]), bytes([2])]);
    });

    test('rewrite は全置換し、一時ファイルを残さない', () async {
      final b = FileStoreBackend(path);
      await b.append(bytes([1]));
      await b.append(bytes([2]));
      await b.rewrite([bytes([9, 9])]);
      expect(await b.readAll(), [bytes([9, 9])]);
      expect(await File('$path.tmp').exists(), isFalse);
      await b.rewrite([]);
      expect(await b.readAll(), isEmpty);
    });

    test('同時に呼んでも直列化され順序が保たれる', () async {
      final b = FileStoreBackend(path);
      final futures = <Future<void>>[];
      for (var i = 0; i < 20; i++) {
        futures.add(b.append(bytes([i])));
      }
      await Future.wait(futures);
      final read = await b.readAll();
      expect(read.map((r) => r[0]).toList(), List.generate(20, (i) => i));
    });

    test('親ディレクトリがなければ作る', () async {
      final nested = FileStoreBackend('${dir.path}/a/b/c/messages.bin');
      await nested.append(bytes([1]));
      expect(await nested.readAll(), [bytes([1])]);
    });
  });
}
