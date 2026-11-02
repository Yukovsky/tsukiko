import 'package:flutter/material.dart';

import 'cat.dart';
import 'genome.dart';

void main() => runApp(const MascotLab());

const _muted = Color(0xffbbb6ca);
const _line = Color(0xff44404e);
const _card = Color(0xff27262e);
const _lilac = Color(0xffb1a6e4);

const _names = [
  'tsukiko',
  'yuko',
  'mori',
  'komorebi',
  'nori',
  'lumi',
  'sora',
  'hana',
  'kuro',
  'momo',
  'yuki',
  'aki',
  'ren',
  'miso',
  'taro',
  'kaze',
  'niwa',
  'tama',
  'ume',
];

class MascotLab extends StatefulWidget {
  const MascotLab({super.key});
  @override
  State<MascotLab> createState() => _MascotLabState();
}

class _MascotLabState extends State<MascotLab> {
  final field = TextEditingController(text: brandName);
  CatMood mood = CatMood.idle;
  bool animate = true;
  bool body = true;
  int roll = 0;

  CatProfile get profile => CatProfile(field.text);

  void put(String text) => setState(() => field.text = text);

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tsukiko · лунные коты',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'LabSans',
      scaffoldBackgroundColor: const Color(0xff202024),
      colorScheme: ColorScheme.fromSeed(
        seedColor: _lilac,
        brightness: Brightness.dark,
      ),
    ),
    home: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),
                    const SizedBox(height: 16),
                    const Text(
                      'Кот из одной строки',
                      style: TextStyle(
                        fontSize: 32,
                        height: 1.16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Имя решает всё сразу. Выбранные части дописываются к нему '
                      'слогами, как yuko-kimi, а слова вроде «лопухи» понимаются '
                      'тоже. Любой цвет задаётся так: #7fb8ec.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: _muted,
                      ),
                    ),
                    const SizedBox(height: 24),
                    LayoutBuilder(
                      builder: (_, box) {
                        if (box.maxWidth < 860) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _hero(),
                              const SizedBox(height: 16),
                              _genes(),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 440, child: _hero()),
                            const SizedBox(width: 24),
                            Expanded(child: _genes()),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 28),
                    _family(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _header() => Row(
    children: [
      const Text(
        'tsukiko / blob cats · 05',
        style: TextStyle(fontSize: 12, color: Color(0xffb6b0c7)),
      ),
      const Spacer(),
      IconButton(
        tooltip: animate ? 'Остановить движение' : 'Включить движение',
        onPressed: () => setState(() => animate = !animate),
        icon: Icon(
          animate ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 20,
        ),
      ),
    ],
  );

  Widget _hero() {
    final p = profile;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: LivingCat(
              key: const ValueKey('hero'),
              profile: p,
              mood: mood,
              animate: animate,
              body: body,
              size: 300,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('look'),
                  controller: field,
                  decoration: const InputDecoration(
                    labelText: 'Строка внешности',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 14),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                tooltip: 'Другое имя, закреплённое остаётся',
                icon: const Icon(Icons.shuffle_rounded, size: 20),
                onPressed: () {
                  roll++;
                  put(p.genome.withSeed(_names[roll % _names.length]));
                },
              ),
              IconButton(
                tooltip: 'Снять всё закреплённое',
                icon: const Icon(Icons.auto_awesome_rounded, size: 20),
                onPressed: () => put(p.genome.seed),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Тело и лапки', style: TextStyle(fontSize: 13)),
                    Text(
                      'Кот сидит целиком, лапы и хвост двигаются с настроением',
                      style: TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const ValueKey('body'),
                value: body,
                onChanged: (value) => setState(() => body = value),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final value in CatMood.values)
                ChoiceChip(
                  label: Text(
                    value.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  selected: mood == value,
                  onSelected: (_) => setState(() => mood = value),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${mood.status} · нажми на кота, он подмигнёт',
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final size in const [96.0, 64.0, 48.0, 32.0, 20.0])
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LivingCat(
                      key: ValueKey('size-$size'),
                      profile: p,
                      mood: mood,
                      animate: animate,
                      gaze: false,
                      glow: size > 40,
                      size: size,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${size.round()}',
                      style: const TextStyle(fontSize: 10, color: _muted),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _genes() {
    final p = profile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final gene in genes) ...[
          _gene(p, gene),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _gene(CatProfile p, Gene<CatOption> gene) {
    final pinned = p.genome.pins[gene];
    final custom = gene == coatGene && p.genome.paint != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              gene.title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 8),
            Text(
              pinned != null || custom ? 'закреплено' : 'из имени',
              style: TextStyle(
                fontSize: 11,
                color: pinned != null || custom ? _lilac : _muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final option in gene.values)
              _tile(p, gene, option, p.look.of(gene) == option && !custom),
          ],
        ),
      ],
    );
  }

  Widget _tile(
    CatProfile p,
    Gene<CatOption> gene,
    CatOption option,
    bool current,
  ) {
    final pinned = p.genome.pins[gene] == option;
    return Tooltip(
      message: option.word,
      child: Semantics(
        button: true,
        selected: current,
        label: '${gene.title}: ${option.word}',
        child: InkWell(
          key: ValueKey('option-${option.word}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => put(p.genome.withPin(gene, pinned ? null : option)),
          child: Container(
            width: 74,
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
            decoration: BoxDecoration(
              color: current ? const Color(0xff33313d) : _card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: pinned
                    ? _lilac
                    : current
                    ? const Color(0xff6c667e)
                    : Colors.transparent,
                width: pinned ? 1.5 : 1,
              ),
            ),
            child: Column(
              children: [
                StillCat(
                  profile: CatProfile(p.genome.withPin(gene, option)),
                  size: 58,
                ),
                Text(
                  option.word,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: current ? Colors.white : _muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _family() {
    final g = profile.genome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Другие имена с тем же закреплённым',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 1; i <= 10; i++)
              _relative(g.withSeed(_names[(roll + i) % _names.length])),
          ],
        ),
      ],
    );
  }

  Widget _relative(String text) => InkWell(
    key: ValueKey('family-$text'),
    borderRadius: BorderRadius.circular(14),
    onTap: () => put(text),
    child: Container(
      width: 104,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          StillCat(profile: CatProfile(text), mood: mood, size: 90),
          Text(
            text.split(' ').first,
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
        ],
      ),
    ),
  );
}
