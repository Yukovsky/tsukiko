import 'dart:io';

import '../models.dart' show Download;
import '../../platform/os.dart';
import 'diarization_models.dart';
import 'own_voice.dart';
import 'sha256.dart';

/// Загрузка моделей «Только мой голос»: эмбеддер TitaNet-S (общий с
/// разметкой голосов в очереди) и детектор речи Silero.
class OwnVoiceModels {
  OwnVoiceModels._();

  static const embedder = DiarizationModels.titanetSmall;
  static const vadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      '${OwnVoicePaths.vadFile}';
  static const vadSha256 =
      '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6';

  static bool get isInstalled =>
      DiarizationModels.isEmbedderInstalled(embedder) &&
      File(OwnVoicePaths.vadPath).existsSync() &&
      File(OwnVoicePaths.vadPath).lengthSync() > 100 * 1024;

  /// Сколько мегабайт осталось скачать.
  static int get downloadMb =>
      (DiarizationModels.isEmbedderInstalled(embedder) ? 0 : embedder.mb) +
      (File(OwnVoicePaths.vadPath).existsSync() ? 0 : 1);

  /// Скачать недостающее. null — всё на месте, иначе — что пошло не так.
  static Future<String?> ensureInstalled() async {
    for (final (url, dest, sha) in [
      (embedder.url, OwnVoicePaths.embedderPath, embedder.sha256),
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
