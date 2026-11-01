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
  bool animate = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Tsukiko · возвращаем образ',
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'LabSans',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffa8a2ce),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff202021),
      useMaterial3: true,
    ),
    home: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'tsukiko / эскиз 02',
                      style: TextStyle(fontSize: 13, color: Color(0xffbbb7c8)),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Возвращаем характер котика.',
                      style: TextStyle(
                        fontSize: 30,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Сначала — знакомый силуэт и пропорции. Один лунный кот, без новых украшений.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Color(0xffbbb7c8),
                      ),
                    ),
                    const SizedBox(height: 28),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        Widget reference = _panel(
                          'Твой референс',
                          'Нынешний кот из приложения',
                          LayoutBuilder(
                            builder: (_, c) => Image.asset(
                              'assets/reference/current-cat.png',
                              width: c.maxWidth,
                              height: c.maxWidth * 334 / 380,
                              fit: BoxFit.contain,
                            ),
                          ),
                        );
                        Widget study = _panel(
                          'Векторный эскиз',
                          'Большие глаза, широкие щёчки, маленькое тело',
                          LayoutBuilder(
                            builder: (_, c) => LivingCat(
                              key: const ValueKey('cat-moon'),
                              profile: CatProfile(kind: CatKind.moon),
                              mood: mood,
                              size: c.maxWidth,
                              height: c.maxWidth * 334 / 380,
                              animate: animate,
                            ),
                          ),
                        );
                        return constraints.maxWidth < 620
                            ? Column(
                                children: [
                                  reference,
                                  const SizedBox(height: 16),
                                  study,
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: reference),
                                  const SizedBox(width: 20),
                                  Expanded(child: study),
                                ],
                              );
                      },
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final value in [
                          CatMood.idle,
                          CatMood.listening,
                          CatMood.thinking,
                          CatMood.happy,
                        ])
                          ChoiceChip(
                            label: Text(value.label),
                            selected: mood == value,
                            onSelected: (_) => setState(() => mood = value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Включить движение и взгляд'),
                      subtitle: const Text(
                        'По умолчанию остановлен, чтобы сравнить рисунок',
                      ),
                      value: animate,
                      onChanged: (value) => setState(() => animate = value),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      mood.status,
                      style: const TextStyle(color: Color(0xffbbb7c8)),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Солнечный и персональный варианты отложены до согласования базового образа.\n'
                      'Это исследовательский эскиз по текущему персонажу; приложение не изменено.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
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

  Widget _panel(String title, String subtitle, Widget content) => Container(
    padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
    decoration: BoxDecoration(
      color: const Color(0xff262627),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xff414044)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ),
        content,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Color(0xffbbb7c8)),
          ),
        ),
      ],
    ),
  );
}
