import 'package:blobatar/flutter.dart' as blob;
import 'package:flutter/material.dart';
import 'cat.dart';

void main() => runApp(const MascotLab());

class MascotLab extends StatefulWidget {
  const MascotLab({super.key});
  @override
  State<MascotLab> createState() => _MascotLabState();
}

class _MascotLabState extends State<MascotLab> {
  CatMood mood = CatMood.idle;
  bool animate = true, personal = false, reference = false;
  String seed = 'tsukiko';
  double voice = .65;
  CatProfile get profile =>
      CatProfile(kind: personal ? CatKind.personal : CatKind.moon, seed: seed);

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Tsukiko · живой кот',
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'LabSans',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffaaa2d4),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff222223),
      useMaterial3: true,
      sliderTheme: const SliderThemeData(trackHeight: 2),
    ),
    home: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1060),
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'tsukiko / живая мастерская · 03',
                      style: TextStyle(fontSize: 12, color: Color(0xffb7b3c4)),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'Знакомый характер. Своя жизнь.',
                      style: TextStyle(
                        fontSize: 30,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Два формата одного кота. Наведи курсор, погладь, переключи состояние.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Color(0xffbbb7c8),
                      ),
                    ),
                    const SizedBox(height: 24),
                    LayoutBuilder(
                      builder: (_, constraints) {
                        final full = _panel(
                          'Кот целиком',
                          'Голова, уши, корпус и хвост двигаются вместе.',
                          LayoutBuilder(
                            builder: (_, c) => LivingCat(
                              key: const ValueKey('cat-full'),
                              profile: profile,
                              mood: mood,
                              size: c.maxWidth,
                              height: 310,
                              animate: animate,
                              voiceLevel: voice,
                            ),
                          ),
                        );
                        final face = _panel(
                          'Только мордочка',
                          'Тот же характер — для компактных мест.',
                          Column(
                            children: [
                              LivingCat(
                                key: const ValueKey('cat-face'),
                                profile: profile,
                                mood: mood,
                                view: CatView.face,
                                size: 250,
                                height: 230,
                                animate: animate,
                                voiceLevel: voice,
                              ),
                              _hud(context),
                              const SizedBox(height: 18),
                            ],
                          ),
                        );
                        return constraints.maxWidth < 650
                            ? Column(
                                children: [
                                  full,
                                  const SizedBox(height: 14),
                                  face,
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: full),
                                  const SizedBox(width: 18),
                                  Expanded(child: face),
                                ],
                              );
                      },
                    ),
                    const SizedBox(height: 22),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final value in CatMood.values)
                          ChoiceChip(
                            label: Text(value.label),
                            selected: mood == value,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => mood = value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Icon(
                          Icons.circle,
                          size: 7,
                          color: Color(0xffc4b4ef),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            mood.status,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xffccc8d6),
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => setState(() => animate = !animate),
                          icon: Icon(
                            animate
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 18,
                          ),
                          label: Text(animate ? 'Остановить' : 'Оживить'),
                        ),
                      ],
                    ),
                    if (mood == CatMood.listening) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Text(
                            'Демо-голос',
                            style: TextStyle(fontSize: 12),
                          ),
                          Expanded(
                            child: Slider(
                              value: voice,
                              label: '${(voice * 100).round()}%',
                              semanticFormatterCallback: (v) =>
                                  '${(v * 100).round()} процентов',
                              onChanged: (v) => setState(() => voice = v),
                            ),
                          ),
                        ],
                      ),
                      const Text(
                        'Уши и хвост отвечают на условную громкость. Микрофон не включается.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xffb7b3c4),
                        ),
                      ),
                    ],
                    const Divider(height: 36, color: Color(0xff414044)),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ChoiceChip(
                          label: const Text('Лунная база'),
                          selected: !personal,
                          showCheckmark: false,
                          onSelected: (_) => setState(() => personal = false),
                        ),
                        ChoiceChip(
                          label: const Text('Из аватара'),
                          selected: personal,
                          showCheckmark: false,
                          onSelected: (_) => setState(() => personal = true),
                        ),
                        SizedBox(
                          width: 220,
                          child: TextFormField(
                            initialValue: seed,
                            style: const TextStyle(fontSize: 14),
                            decoration: const InputDecoration(
                              labelText: 'Строка внешности',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) => setState(() {
                              seed = v;
                              personal = true;
                            }),
                          ),
                        ),
                        blob.Blobatar(
                          name: seed,
                          size: 46,
                          options: const blob.BlobatarOptions(tone: .68),
                          semanticLabel: 'Исходный Blobatar для этой строки',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => setState(() => reference = !reference),
                      child: Text(
                        reference
                            ? 'Скрыть исходный ориентир'
                            : 'Показать исходный ориентир',
                      ),
                    ),
                    if (reference)
                      Image.asset(
                        'assets/reference/current-cat.png',
                        width: 220,
                        semanticLabel:
                            'Исходный кот: ориентир для силуэта и мягкости рисунка',
                      ),
                    const SizedBox(height: 12),
                    const Text(
                      'Эскиз поведения · состояния выбираются вручную · рабочее приложение не подключено.',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: Color(0xffaaa7b5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _hud(BuildContext context) => Container(
    width: 248,
    padding: const EdgeInsets.fromLTRB(10, 3, 15, 3),
    decoration: BoxDecoration(
      color: const Color(0xff303033),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: const Color(0xff48474d)),
    ),
    child: Row(
      children: [
        LivingCat(
          key: const ValueKey('cat-hud'),
          profile: profile,
          mood: mood,
          view: CatView.face,
          size: 48,
          height: 48,
          animate: animate,
          voiceLevel: voice,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(mood.label, style: const TextStyle(fontSize: 12)),
              const Text(
                'макет панели',
                style: TextStyle(fontSize: 10, color: Color(0xffb7b3c4)),
              ),
            ],
          ),
        ),
        if (mood == CatMood.listening)
          const Icon(Icons.circle, size: 7, color: Color(0xffed9e9e)),
      ],
    ),
  );

  Widget _panel(String title, String subtitle, Widget content) => Container(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 15),
    decoration: BoxDecoration(
      color: const Color(0xff282829),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: const Color(0xff414044)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Center(child: content),
        const SizedBox(height: 5),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 12,
            height: 1.5,
            color: Color(0xffbbb7c8),
          ),
        ),
      ],
    ),
  );
}
