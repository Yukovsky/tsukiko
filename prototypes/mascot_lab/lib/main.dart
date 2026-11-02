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
  CatKind kind = CatKind.moon;
  CatShape selected = CatShape.round;
  String seed = 'yuko';
  bool animate = true;
  int roll = 0;
  CatProfile profile(CatShape shape) =>
      CatProfile(kind: kind, seed: seed, shape: shape);

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tsukiko · коты Blobatar',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'LabSans',
      scaffoldBackgroundColor: const Color(0xff202024),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffb1a6e4),
        brightness: Brightness.dark,
      ),
    ),
    home: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'tsukiko / blob cats · 04',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xffb6b0c7),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: animate
                              ? 'Остановить движение'
                              : 'Включить движение',
                          onPressed: () => setState(() => animate = !animate),
                          icon: Icon(
                            animate
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Три кота. Один Blobatar.',
                      style: TextStyle(
                        fontSize: 32,
                        height: 1.16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Родные формы и эмоции Blobatar — с кошачьими ушами и своим характером.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Color(0xffbbb6ca),
                      ),
                    ),
                    const SizedBox(height: 26),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final compact = constraints.maxWidth < 700;
                        final cards = CatShape.values
                            .map((shape) => _card(shape, compact))
                            .toList();
                        return constraints.maxWidth < 440
                            ? Column(
                                children: [
                                  for (final card in cards)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: card,
                                    ),
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (var i = 0; i < cards.length; i++) ...[
                                    if (i > 0) const SizedBox(width: 12),
                                    Expanded(child: cards[i]),
                                  ],
                                ],
                              );
                      },
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Попробуй эмоции',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final value in CatMood.values)
                          ChoiceChip(
                            label: Text(
                              value.label,
                              style: const TextStyle(fontSize: 12),
                            ),
                            showCheckmark: false,
                            selected: mood == value,
                            onSelected: (_) => setState(() => mood = value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.circle,
                          size: 6,
                          color: Color(0xffb9a8ea),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            mood.status,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xffbbb6ca),
                            ),
                          ),
                        ),
                        const Text(
                          'Нажми на кота — он подмигнёт',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xffbbb6ca),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 36, color: Color(0xff3f3b49)),
                    Wrap(
                      spacing: 8,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final value in CatKind.values)
                          ChoiceChip(
                            label: Text(switch (value) {
                              CatKind.moon => 'Лунный',
                              CatKind.sun => 'Солнечный',
                              CatKind.personal => 'Цвет из seed',
                            }),
                            selected: kind == value,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => kind = value),
                          ),
                        SizedBox(
                          width: 210,
                          child: TextFormField(
                            initialValue: seed,
                            key: ValueKey('seed-$roll'),
                            decoration: const InputDecoration(
                              labelText: 'Строка внешности',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            style: const TextStyle(fontSize: 14),
                            onChanged: (value) => setState(() => seed = value),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Другая внешность',
                          icon: const Icon(Icons.shuffle_rounded, size: 20),
                          onPressed: () => setState(() {
                            roll++;
                            seed = [
                              'mori',
                              'komorebi',
                              'nori',
                              'lumi',
                              'sora',
                            ][roll % 5];
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'Выбранный в панели',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xffbbb6ca),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xff2c2b32),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              LivingCat(
                                key: const ValueKey('compact-cat'),
                                profile: profile(selected),
                                mood: mood,
                                animate: animate,
                                size: 48,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                mood.label,
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(width: 10),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Наведи курсор для взгляда · одна строка создаёт три варианта · состояния демонстрационные.',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: Color(0xffa8a2b5),
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

  Widget _card(CatShape shape, bool compact) {
    final p = profile(shape);
    final chosen = shape == selected;
    return Container(
      key: ValueKey('card-${shape.name}'),
      padding: EdgeInsets.all(compact ? 10 : 18),
      decoration: BoxDecoration(
        color: const Color(0xff27262e),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: chosen ? const Color(0xffafa2db) : const Color(0xff44404e),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '0${shape.index + 1}',
            style: const TextStyle(fontSize: 10, color: Color(0xffb4adc5)),
          ),
          LayoutBuilder(
            builder: (_, c) => LivingCat(
              key: ValueKey('cat-${shape.name}'),
              profile: p,
              mood: mood,
              size: c.maxWidth,
              height: compact ? 172 : 260,
              animate: animate,
              onPoke: () => setState(() => selected = shape),
            ),
          ),
          SizedBox(
            height: compact ? 42 : 30,
            child: Text(
              shape.label,
              style: TextStyle(
                fontSize: compact ? 14 : 21,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (!compact)
            Text(
              shape.description,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Color(0xffbbb6ca),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              blob.Blobatar(
                name: seed,
                options: p.options,
                size: compact ? 28 : 36,
                semanticLabel: 'Исходная форма ${shape.label}',
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'основа',
                  style: TextStyle(fontSize: 10, color: Color(0xffb4adc5)),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => selected = shape),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8),
                  minimumSize: const Size(0, 40),
                ),
                child: Text(
                  chosen ? 'Выбран' : 'Выбрать',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
