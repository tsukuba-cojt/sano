/// メッセージ保存の追記型ログ（バックエンド）。
///
/// [MessageStore] はレコード（バイト列）の意味を知る側で、ここでは
/// 「順序付きのバイト列の列」を読み書きするだけに徹する。
library;

import 'dart:io';
import 'dart:typed_data';

/// 1 レコードの上限（これを超える長さは破損とみなす）。
const int kMaxStoreRecordBytes = 1 << 20;

/// 追記型ログのバックエンド。
abstract class StoreBackend {
  /// 記録順にすべてのレコードを返す。
  Future<List<Uint8List>> readAll();

  /// レコードを末尾に追記する。
  Future<void> append(Uint8List record);

  /// 全レコードを [records] で置き換える（圧縮）。
  Future<void> rewrite(List<Uint8List> records);
}

/// テスト用のインメモリバックエンド。
class MemoryStoreBackend implements StoreBackend {
  MemoryStoreBackend([List<Uint8List>? initial])
      : _records = [...?initial?.map(Uint8List.fromList)];

  final List<Uint8List> _records;

  /// 追記・置換の回数（テストでの確認用）。
  int appendCount = 0;
  int rewriteCount = 0;

  /// 現在のレコード一覧（複製）。
  List<Uint8List> get records =>
      List.unmodifiable(_records.map(Uint8List.fromList));

  @override
  Future<List<Uint8List>> readAll() async =>
      _records.map(Uint8List.fromList).toList();

  @override
  Future<void> append(Uint8List record) async {
    appendCount++;
    _records.add(Uint8List.fromList(record));
  }

  @override
  Future<void> rewrite(List<Uint8List> records) async {
    rewriteCount++;
    _records
      ..clear()
      ..addAll(records.map(Uint8List.fromList));
  }
}

/// ファイルに `u32 len + bytes` を追記していくバックエンド。
///
/// 末尾が途中で切れている（電源断など）場合はそこまでを有効とし、
/// 破損した末尾は [readAll] 時に切り捨てて以後の追記が壊れないようにする。
/// 操作は内部で直列化する。
class FileStoreBackend implements StoreBackend {
  FileStoreBackend(this.path);

  /// ログファイルのパス。
  final String path;

  Future<void> _chain = Future<void>.value();

  /// 直列化して [op] を実行する。
  Future<T> _serialized<T>(Future<T> Function() op) {
    final next = _chain.then((_) => op());
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }

  @override
  Future<List<Uint8List>> readAll() => _serialized(() async {
        final file = File(path);
        if (!await file.exists()) {
          return <Uint8List>[];
        }
        final bytes = await file.readAsBytes();
        final records = <Uint8List>[];
        var offset = 0;
        var validEnd = 0;
        final view = ByteData.sublistView(bytes);
        while (bytes.length - offset >= 4) {
          final len = view.getUint32(offset, Endian.little);
          if (len == 0 || len > kMaxStoreRecordBytes) {
            // 長さが異常 → ここから先は破損とみなす。
            break;
          }
          if (bytes.length - offset - 4 < len) {
            // 末尾が途中で切れている。
            break;
          }
          records.add(Uint8List.fromList(
              Uint8List.sublistView(bytes, offset + 4, offset + 4 + len)));
          offset += 4 + len;
          validEnd = offset;
        }
        if (validEnd != bytes.length) {
          // 破損末尾を切り捨てる。
          final raf = await file.open(mode: FileMode.append);
          try {
            await raf.truncate(validEnd);
          } finally {
            await raf.close();
          }
        }
        return records;
      });

  @override
  Future<void> append(Uint8List record) => _serialized(() async {
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(_frame(record),
            mode: FileMode.append, flush: true);
      });

  @override
  Future<void> rewrite(List<Uint8List> records) => _serialized(() async {
        final file = File(path);
        await file.parent.create(recursive: true);
        final builder = BytesBuilder(copy: false);
        for (final r in records) {
          builder.add(_frame(r));
        }
        // 一時ファイルに書いてから置き換える（途中で落ちても元が残る）。
        final tmp = File('$path.tmp');
        await tmp.writeAsBytes(builder.takeBytes(), flush: true);
        await tmp.rename(path);
      });

  static Uint8List _frame(Uint8List record) {
    if (record.length > kMaxStoreRecordBytes) {
      throw ArgumentError.value(
          record.length, 'record', '$kMaxStoreRecordBytes バイトを超えています');
    }
    final out = Uint8List(4 + record.length);
    ByteData.sublistView(out).setUint32(0, record.length, Endian.little);
    out.setRange(4, out.length, record);
    return out;
  }
}
