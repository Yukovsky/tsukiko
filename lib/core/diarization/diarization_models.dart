import 'dart:io';

import '../logger.dart';
import '../models.dart' show Download, modelPathFor;
import 'sha256.dart';

/// Эмбеддер голоса: нейросеть, которая превращает кусок речи в вектор
/// «как звучит этот человек». По расстоянию между такими векторами
/// кластеризация и решает, один это голос или два.
class DiarizationEmbedder {
  const DiarizationEmbedder({
    required this.id,
    required this.file,
    required this.mb,
    required this.sha256,
    required this.threshold,
    required this.license,
  });

  final String id, file;

  /// Размер загрузки — его показывают до начала, в диалоге включения.
  final int mb;

  /// Закреплённая сумма файла из `checksum.txt` релиза sherpa-onnx,
  /// пересчитанная заново при выборе модели.
  final String sha256;

  /// Порог кластеризации по умолчанию — расстояние в пространстве именно
  /// этого эмбеддера: у другого эмбеддера тот же порог значит совсем
  /// другое. Подобран замером, см. `docs/diarization-threshold.md`.
  final double threshold;

  /// Лицензия, как её называет первоисточник модели.
  final String license;

  String get url =>
      // В названии тега опечатка («recongition») — она настоящая.
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'speaker-recongition-models/$file';
}

/// Модели режима «Несколько голосов» и их установка.
///
/// В приложение они не вшиваются, а скачиваются при первом включении
/// режима, как остальные модели: вопрос, можно ли раздавать
/// сконвертированные в ONNX файлы вместе с программой, у авторов
/// sherpa-onnx остался без ответа (обсуждение k2-fsa/sherpa-onnx#3939),
/// а скачивание человеком из первоисточника такого вопроса не ставит.
class DiarizationModels {
  DiarizationModels._();

  // ── сегментация ───────────────────────────────────────────────────────────
  // pyannote/segmentation-3.0, сконвертированная sherpa-onnx. Лицензия MIT
  // (файл LICENSE в самом архиве: «Copyright (c) 2022 CNRS»).
  static const segmentationName = 'sherpa-onnx-pyannote-segmentation-3-0';
  static const segmentationArchiveUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'speaker-segmentation-models/$segmentationName.tar.bz2';
  static const segmentationSha256 =
      '24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488';

  /// Архив весит 7 МБ, из него остаются полтора.
  static const segmentationMb = 7;

  static String get segmentationDir => modelPathFor(segmentationName);

  /// Восьмибитная модель: 1.5 МБ против 5.7 у полной.
  static String get segmentationModel => '$segmentationDir/model.int8.onnx';

  static bool get isSegmentationInstalled {
    final f = File(segmentationModel);
    return f.existsSync() && f.lengthSync() > 1024 * 1024;
  }

  // ── эмбеддеры ─────────────────────────────────────────────────────────────

  /// NeMo TitaNet-S. Самый быстрый из проверенных (RTF 0.12 на одном
  /// потоке по замеру sherpa-onnx). Лицензия: «covered by the license of
  /// the NeMo Toolkit» — так сказано в карточке модели на NGC, а NeMo
  /// Toolkit — Apache-2.0.
  static const titanetSmall = DiarizationEmbedder(
    id: 'titanet-small',
    file: 'nemo_en_titanet_small.onnx',
    mb: 39,
    sha256: 'ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e',
    // Лучший из замеренных: на девяти записях реальных людей (русский,
    // английский, встреча AMI) верное число голосов на шести, средняя
    // ошибка 0.35 — см. docs/diarization-threshold.md.
    threshold: 0.9,
    license: 'Apache-2.0 (NeMo Toolkit)',
  );

  /// WeSpeaker ResNet34-LM на VoxCeleb. Лицензия модели — лицензия
  /// набора данных, CC BY 4.0 (`docs/pretrained.md` у WeSpeaker).
  static const wespeakerResnet34 = DiarizationEmbedder(
    id: 'wespeaker-resnet34',
    file: 'wespeaker_en_voxceleb_resnet34_LM.onnx',
    mb: 26,
    sha256: 'e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012',
    // Самый неустойчивый из трёх: на китайской записи верно 0.25–0.35,
    // на русских и английских — не ниже 0.5. Брать его по умолчанию нельзя.
    threshold: 0.5,
    license: 'CC-BY-4.0 (VoxCeleb)',
  );

  /// 3D-Speaker ERes2Net base. Тот, под который подобран порог 0.5 из
  /// примера sherpa, — и как раз на нём YazSes мерил узкое окно 1.0–1.2.
  static const eres2netBase = DiarizationEmbedder(
    id: 'eres2net-base',
    file: '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx',
    mb: 38,
    sha256: '1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b',
    // Как и TitaNet-S — 0.9, но чуть хуже по ошибке и вдвое медленнее.
    threshold: 0.9,
    license: 'Apache-2.0 (3D-Speaker)',
  );

  static const embedders = [titanetSmall, wespeakerResnet34, eres2netBase];

  static const defaultEmbedder = titanetSmall;

  static DiarizationEmbedder embedderById(String? id) =>
      embedders.where((e) => e.id == id).firstOrNull ?? defaultEmbedder;

  static String embedderPath(DiarizationEmbedder e) => modelPathFor(e.file);

  static bool isEmbedderInstalled(DiarizationEmbedder e) {
    final f = File(embedderPath(e));
    return f.existsSync() && f.lengthSync() > 10 * 1024 * 1024;
  }

  static bool isInstalled([DiarizationEmbedder e = defaultEmbedder]) =>
      isSegmentationInstalled && isEmbedderInstalled(e);

  /// Сколько мегабайт осталось скачать.
  static int downloadMb([DiarizationEmbedder e = defaultEmbedder]) =>
      (isSegmentationInstalled ? 0 : segmentationMb) +
      (isEmbedderInstalled(e) ? 0 : e.mb);

  /// Скачать недостающее. Возвращает null, если всё на месте, иначе —
  /// почему не вышло (для журнала и подписи; текст движка не переводится).
  ///
  /// [onProgress] получает долю от 0 до 1 по всей загрузке.
  static Future<String?> ensureInstalled({
    DiarizationEmbedder embedder = defaultEmbedder,
    void Function(double share)? onProgress,
    bool Function()? cancelled,
  }) async {
    final total = downloadMb(embedder);
    if (total == 0) return null;
    var doneMb = 0;
    if (!isSegmentationInstalled) {
      final problem = await _ensureSegmentation(
        cancelled: cancelled,
        onProgress: (share) =>
            onProgress?.call(share * segmentationMb / total),
      );
      if (problem != null) return problem;
      doneMb += segmentationMb;
    }
    if (!isEmbedderInstalled(embedder)) {
      final dest = embedderPath(embedder);
      final download = Download(embedder.url, dest, title: embedder.file);
      final result = await download.run(
        onProgress: () {
          if (cancelled?.call() ?? false) download.cancel();
          onProgress?.call(
            (doneMb + embedder.mb * download.percent / 100) / total,
          );
        },
      );
      if (result == null) {
        return download.error ?? 'download cancelled';
      }
      final sum = await sha256OfFile(dest);
      if (sum != embedder.sha256) {
        try {
          File(dest).deleteSync();
        } catch (_) {}
        return 'sha256 mismatch for ${embedder.file}: $sum';
      }
    }
    onProgress?.call(1);
    return null;
  }

  /// Архив сегментации — тем же путём, что модели голосовой активации
  /// (`WakeWordModelPaths._ensureArchive`): скачать в `.download`,
  /// распаковать в `.staging`, проверить и только потом переименовать —
  /// оборванная загрузка не должна выглядеть установленной моделью.
  /// Сверх того — сверка суммы архива до распаковки.
  static Future<String?> _ensureSegmentation({
    void Function(double share)? onProgress,
    bool Function()? cancelled,
  }) async {
    final targetDir = segmentationDir;
    final archive = File('$targetDir.download');
    final staging = Directory('$targetDir.staging');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      await archive.parent.create(recursive: true);
      if (staging.existsSync()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final request = await client.getUrl(Uri.parse(segmentationArchiveUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return 'download returned ${response.statusCode}: '
            '$segmentationArchiveUrl';
      }
      final sink = archive.openWrite();
      final length = response.contentLength;
      var got = 0;
      try {
        await for (final chunk in response) {
          if (cancelled?.call() ?? false) return 'download cancelled';
          sink.add(chunk);
          got += chunk.length;
          if (length > 0) onProgress?.call(got / length);
        }
      } finally {
        await sink.close();
      }
      final sum = await sha256OfFile(archive.path);
      if (sum != segmentationSha256) {
        return 'sha256 mismatch for $segmentationName: $sum';
      }
      final result = await Process.run('tar', [
        '-xf',
        archive.path,
        '--strip-components=1',
        '-C',
        staging.path,
      ]);
      if (result.exitCode != 0) return 'tar: ${result.stderr}';
      final model = File('${staging.path}/model.int8.onnx');
      if (!model.existsSync() || model.lengthSync() < 1024 * 1024) {
        return 'incomplete archive: $segmentationArchiveUrl';
      }
      // В архиве ещё полная модель и питоновские скрипты экспорта —
      // оставляем только то, чем пользуемся, и лицензию.
      for (final entity in staging.listSync()) {
        final name = entity.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;
        if (name == 'model.int8.onnx' || name == 'LICENSE') continue;
        await entity.delete(recursive: true);
      }
      final installed = Directory(targetDir);
      if (installed.existsSync()) await installed.delete(recursive: true);
      await staging.rename(targetDir);
      return isSegmentationInstalled ? null : 'segmentation not installed';
    } catch (e, st) {
      Log.error('Diarization', 'Segmentation install failed: $e', e, st);
      return '$e';
    } finally {
      client.close(force: true);
      if (archive.existsSync()) await archive.delete();
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }
}
