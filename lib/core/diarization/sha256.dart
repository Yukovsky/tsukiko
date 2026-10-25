/// SHA-256 файла — проверить, что скачалась именно та модель.
///
/// Своё, а не `package:crypto`: в зависимостях приложения его нет (он
/// приходит только транзитивно), а новых зависимостей ради одной проверки
/// после загрузки мы не заводим. Алгоритм — дословно FIPS 180-4, проверка
/// по эталонным векторам — в `test/core/diarization_test.dart`.
library;

import 'dart:io';
import 'dart:typed_data';

const _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Потоковый SHA-256: куски подаются по мере чтения, весь файл в память
/// не поднимается.
class Sha256 {
  final _h = Uint32List.fromList(const [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  final _block = Uint8List(64);
  final _w = Uint32List(64);
  var _fill = 0;
  var _length = 0;

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

  void _compress() {
    final w = _w;
    for (var i = 0; i < 16; i++) {
      w[i] = (_block[i * 4] << 24) |
          (_block[i * 4 + 1] << 16) |
          (_block[i * 4 + 2] << 8) |
          _block[i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = _h[0], b = _h[1], c = _h[2], d = _h[3];
    var e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & 0xffffffff & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    _h[0] += a;
    _h[1] += b;
    _h[2] += c;
    _h[3] += d;
    _h[4] += e;
    _h[5] += f;
    _h[6] += g;
    _h[7] += h;
  }

  void add(List<int> bytes) {
    _length += bytes.length;
    for (final byte in bytes) {
      _block[_fill++] = byte;
      if (_fill == 64) {
        _compress();
        _fill = 0;
      }
    }
  }

  /// Шестнадцатеричная строка, как её печатают `shasum` и `checksum.txt`
  /// в релизах sherpa-onnx.
  String close() {
    final bits = _length * 8;
    add(const [0x80]);
    while (_fill != 56) {
      add(const [0]);
    }
    for (var i = 7; i >= 0; i--) {
      _block[_fill++] = (bits >> (i * 8)) & 0xff;
    }
    _compress();
    return [
      for (final word in _h) word.toRadixString(16).padLeft(8, '0'),
    ].join();
  }
}

String sha256OfBytes(List<int> bytes) => (Sha256()..add(bytes)).close();

Future<String> sha256OfFile(String path) async {
  final hash = Sha256();
  await for (final chunk in File(path).openRead()) {
    hash.add(chunk);
  }
  return hash.close();
}
