import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../platform/os.dart';

/// Обновление из приложения.
///
/// Без Sparkle и WinSparkle: им нужен свой канал (appcast) и свой ключ
/// подписи, а выпуски и так лежат на GitHub вместе с описью сумм. Поэтому
/// приложение само спрашивает последний выпуск, качает файл своей
/// системы, сверяет его SHA-256 с SHA256SUMS.txt того же выпуска и только
/// потом ставит: на macOS подменяет .app (если новая копия подписана тем
/// же разработчиком), на Windows запускает установщик без окон.
/// Настройки и модели лежат отдельно и переезд переживают.
///
/// Где поставить так нельзя (переносная сборка, приложение запущено
/// прямо из образа), остаётся страница выпуска.
class Update {
  const Update(this.version, this.url, this.notes, {this.download, this.sums});

  final String version;
  final String url;
  final String notes;

  /// Ссылки на файл установки этой системы и на опись сумм. Нет хотя бы
  /// одной — ставить нечего или нечем проверить, остаётся страница.
  final String? download;
  final String? sums;

  bool get installable => download != null && sums != null;
}

/// Где лежит опись выпусков. Один файл на обе системы: страница выпуска
/// у них общая, а какой файл качать — видно на ней.
const releasesUrl =
    'https://api.github.com/repos/Yukovsky/tsukiko/releases/latest';

/// Какой файл выпуска ставит эту систему.
String get updateAsset =>
    Platform.isMacOS ? 'tsukiko.dmg' : 'tsukiko-setup.exe';

/// Есть ли версия новее [current]. Нет сети, нет ответа, чужой ответ —
/// значит новостей нет: проверка обновлений не тот повод, чтобы
/// беспокоить человека сообщением об ошибке.
Future<Update?> checkForUpdate(String current, {String url = releasesUrl}) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    client.close();

    final tag = ((body as Map)['tag_name'] as String?)?.trim();
    if (tag == null || tag.isEmpty) return null;
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    if (!isNewer(latest, current)) return null;
    String? asset(String name) => [
      for (final a in (body['assets'] as List?) ?? const [])
        if (a is Map && a['name'] == name) a['browser_download_url'] as String?,
    ].firstOrNull;
    return Update(
      latest,
      (body['html_url'] as String?) ?? 'https://github.com/Yukovsky/tsukiko/releases',
      (body['body'] as String?)?.trim() ?? '',
      download: asset(updateAsset),
      sums: asset('SHA256SUMS.txt'),
    );
  } catch (_) {
    return null;
  }
}

/// Сравнение версий по числам, а не по строкам: «1.10.0» новее «1.9.0»,
/// хотя как строка она меньше.
bool isNewer(String candidate, String current) {
  List<int> parts(String v) => [
        for (final p in v.split(RegExp(r'[.+-]')))
          int.tryParse(p) ?? 0,
      ];
  final a = parts(candidate), b = parts(current);
  for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Сумма файла [name] из описи в формате sha256sum: `сумма  имя`.
String? expectedSum(String sums, String name) {
  for (final line in const LineSplitter().convert(sums)) {
    final parts = line.trim().split(RegExp(r'\s+\*?'));
    if (parts.length == 2 && parts[1] == name) return parts[0].toLowerCase();
  }
  return null;
}

/// Скачать файл установки во временную папку и сверить его SHA-256
/// с описью. Не сошлось или в описи его нет — бросает ошибку, и ставить
/// нечего: непроверенный файл не запускается никогда.
Future<File> downloadUpdate(Update update, void Function(int percent) onProgress) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final sums = await (await _get(client, update.sums!)).transform(utf8.decoder).join();
    final expected = expectedSum(sums, updateAsset);
    if (expected == null) throw StateError('$updateAsset is not in SHA256SUMS.txt');

    final response = await _get(client, update.download!);
    final dir = await Directory.systemTemp.createTemp('tsukiko-update');
    final file = File('${dir.path}${Platform.pathSeparator}$updateAsset');
    final sink = file.openWrite();
    var got = 0, shown = -1;
    await for (final chunk in response) {
      sink.add(chunk);
      got += chunk.length;
      final percent = response.contentLength > 0 ? got * 100 ~/ response.contentLength : 0;
      if (percent != shown) onProgress(shown = percent);
    }
    await sink.close();

    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual != expected) {
      await dir.delete(recursive: true);
      throw StateError('SHA-256 mismatch for $updateAsset');
    }
    return file;
  } finally {
    client.close();
  }
}

Future<HttpClientResponse> _get(HttpClient client, String url) async {
  final response = await (await client.getUrl(Uri.parse(url))).close();
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
  }
  return response;
}

/// Подготовить установку проверенного [file] и оставить на выходе
/// приложения маленький скрипт: он ждёт, пока этот процесс закроется,
/// ставит новую версию и запускает её. Приложение после `true` надо
/// закрыть самому. `false` — здесь так поставить нельзя.
Future<bool> installUpdate(File file) async {
  final self = File(Platform.resolvedExecutable);
  if (Platform.isWindows) {
    // У переносной сборки нет деинсталлятора, и установщик поставил бы
    // рядом вторую копию вместо обновления этой.
    if (!File('${self.parent.path}\\unins000.exe').existsSync()) return false;
    final setup = file.path.replaceAll("'", "''");
    await Process.start('powershell', [
      '-NoProfile', '-WindowStyle', 'Hidden', '-Command',
      // Ждём выхода: пока приложение держит свой мьютекс, установщик
      // в тихом режиме не начнёт.
      'Wait-Process -Id $pid -ErrorAction SilentlyContinue; '
          "Start-Process -FilePath '$setup' "
          "-ArgumentList '/SILENT','/SUPPRESSMSGBOXES','/NORESTART'",
    ], mode: ProcessStartMode.detached);
    return true;
  }

  final app = self.parent.parent.parent.path; // …/tsukiko.app
  // Из образа, из «карантинной» копии и из папки без права записи
  // подменить себя нельзя.
  try {
    File('${File(app).parent.path}/.tsukiko-update').createSync();
    File('${File(app).parent.path}/.tsukiko-update').deleteSync();
  } catch (_) {
    return false;
  }

  final dir = file.parent.path;
  final staged = '$dir/tsukiko.app';
  final mount = await Process.run('hdiutil',
      ['attach', file.path, '-nobrowse', '-readonly', '-mountpoint', '$dir/volume']);
  if (mount.exitCode != 0) return false;
  try {
    await Process.run('ditto', ['$dir/volume/tsukiko.app', staged]);
  } finally {
    await Process.run('hdiutil', ['detach', '$dir/volume', '-force']);
  }
  // Ставим только копию, подписанную тем же разработчиком, что и эта,
  // или командой, на которую переезжает подпись выпусков.
  final team = await _team(staged);
  if (team == null || (team != await _team(app) && team != '59QLAACKD5')) {
    return false;
  }
  final verify = await Process.run('codesign', ['--verify', '--deep', '--strict', staged]);
  if (verify.exitCode != 0) return false;

  await Process.start('/bin/sh', [
    '-c',
    r'''
while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
rm -rf "$1.old"
mv "$1" "$1.old" && { mv "$2" "$1" || mv "$1.old" "$1"; }
rm -rf "$1.old" "$3"
open "$1"
''',
    '$pid', app, staged, dir,
  ], mode: ProcessStartMode.detached);
  return true;
}

Future<String?> _team(String app) async {
  final info = await Process.run('codesign', ['-dv', app]);
  return RegExp(r'^TeamIdentifier=(\w+)$', multiLine: true)
      .firstMatch('${info.stderr}')
      ?.group(1);
}

/// Открыть страницу выпуска в браузере.
Future<void> openReleasePage(String url) => os.openUrl(url);
