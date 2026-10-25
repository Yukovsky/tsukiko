import 'dart:io';

import '../models.dart' show Download;
import '../../platform/os.dart';
import 'own_voice.dart';
import 'sha256.dart';

/// Загрузка моделей «Только мой голос»: эмбеддер TitaNet-S и детектор
/// речи Silero.
class OwnVoiceModels {
  OwnVoiceModels._();

  // NeMo TitaNet-S из релиза sherpa-onnx: «covered by the license of the
  // NeMo Toolkit» по карточке NGC, то есть Apache-2.0. В теге опечатка
  // («recongition») — она настоящая.
  static const embedderUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'speaker-recongition-models/${OwnVoicePaths.embedderFile}';
  static const embedderSha256 =
      'ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e';
  static const embedderMb = 39;
  static const vadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      '${OwnVoicePaths.vadFile}';
  static const vadSha256 =
      '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6';

  static bool get _embedderInstalled {
    final f = File(OwnVoicePaths.embedderPath);
    return f.existsSync() && f.lengthSync() > 10 * 1024 * 1024;
  }

  static bool get isInstalled =>
      _embedderInstalled &&
      File(OwnVoicePaths.vadPath).existsSync() &&
      File(OwnVoicePaths.vadPath).lengthSync() > 100 * 1024;

  /// Сколько мегабайт осталось скачать.
  static int get downloadMb =>
      (_embedderInstalled ? 0 : embedderMb) +
      (File(OwnVoicePaths.vadPath).existsSync() ? 0 : 1);

  /// Скачать недостающее. null — всё на месте, иначе — что пошло не так.
  static Future<String?> ensureInstalled() async {
    for (final (url, dest, sha) in [
      (embedderUrl, OwnVoicePaths.embedderPath, embedderSha256),
      (vadUrl, OwnVoicePaths.vadPath, vadSha256),
    ]) {
      if (File(dest).existsSync()) continue;
      final download = Download(url, dest);
      if (await download.run() == null) {
        return download.error ?? 'download failed: $url';
      }
      final sum = await sha256OfFile(dest);
      if (sum != sha) {
        try {
          File(dest).deleteSync();
        } catch (_) {}
        return 'sha256 mismatch for ${os.basename(dest)}: $sum';
      }
    }
    return null;
  }
}
