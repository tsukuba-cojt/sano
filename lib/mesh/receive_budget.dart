/// 同時接続全体で共有する、保存待ちデータの上限。
library;

/// 展開済み本文とワイヤデータを含めて数える。オブジェクトの固定費として
/// 1 件 128 バイトを加える（実際の VM ヒープ使用量そのものではない）。
class ReceiveBudget {
  ReceiveBudget({this.maxMessages = 4096, this.maxBytes = 8 * 1024 * 1024});

  final int maxMessages;
  final int maxBytes;
  int _messages = 0;
  int _bytes = 0;

  int get messages => _messages;
  int get bytes => _bytes;

  bool reserve(int bytes) {
    if (bytes < 0 || _messages >= maxMessages || _bytes + bytes > maxBytes) {
      return false;
    }
    _messages++;
    _bytes += bytes;
    return true;
  }

  void release(int messages, int bytes) {
    assert(messages >= 0 && messages <= _messages);
    assert(bytes >= 0 && bytes <= _bytes);
    _messages -= messages;
    _bytes -= bytes;
  }
}
