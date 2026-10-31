import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

void main() {
  setUpAll(ensureGoldenFonts);
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  for (final direction in FaVisualDirection.values) {
    for (final brightness in Brightness.values) {
      testWidgets('components ${direction.name} ${brightness.name}', (
        tester,
      ) async {
        await pumpGolden(
          tester,
          _ComponentGallery(direction: direction),
          size: const Size(500, 900),
          theme: buildFaTheme(direction: direction, brightness: brightness),
          wrap: (child) => child,
        );
        await expectGolden(
          tester,
          'fa2_components_${direction.name}_${brightness.name}',
        );
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('settings direction previews ${brightness.name}', (
      tester,
    ) async {
      final controller = ThemeController.inMemory(
        brightness == Brightness.dark ? FahThemeMode.dark : FahThemeMode.light,
      );
      await pumpGolden(
        tester,
        VisualDirectionSection(controller: controller),
        size: const Size(500, 360),
        theme: buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: brightness,
        ),
        wrap: (child) => Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: child,
          ),
        ),
      );
      await expectGolden(tester, 'fa2_settings_directions_${brightness.name}');
      if (brightness == Brightness.dark) {
        await tester.tap(find.text('Nebula'));
        await tester.pump();
        expect(controller.visualDirection, FaVisualDirection.nebula);
      }
    });
  }

  const frames = <String, Size>{
    'small': Size(390, 844),
    'medium': Size(800, 900),
    'large': Size(1440, 1000),
  };
  for (final entry in frames.entries) {
    testWidgets('adaptive ${entry.key}', (tester) async {
      await pumpGolden(
        tester,
        FaAdaptiveScaffold(
          destinations: const [
            FaDestination(icon: Icons.chat_bubble_outline, label: 'Chat'),
            FaDestination(icon: Icons.apps, label: 'Apps'),
            FaDestination(icon: Icons.grid_view, label: 'Board'),
            FaDestination(icon: Icons.settings, label: 'Settings'),
          ],
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          title: const Text('Fa workspace'),
          actions: [FaIconButton(icon: Icons.search, onPressed: () {})],
          body: const _AdaptiveConversation(),
          secondaryPanel: const _SessionPanel(),
          boardPanel: const _BoardPanel(),
        ),
        size: entry.value,
        theme: buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: Brightness.dark,
        ),
        wrap: (child) => child,
      );
      await expectGolden(tester, 'fa2_adaptive_${entry.key}');
    });
  }
}

class _ComponentGallery extends StatelessWidget {
  const _ComponentGallery({required this.direction});

  final FaVisualDirection direction;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${direction.name.toUpperCase()} · ${tokens.brightness.name}',
        ),
        leading: const Padding(
          padding: EdgeInsets.all(8),
          child: FaLogo(size: 36),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'One system. Every surface.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Semantic colors, squircle geometry, shared controls and responsive motion.',
            style: TextStyle(color: tokens.ink2),
          ),
          const SizedBox(height: 20),
          FaSurface(
            glass: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const FaTextField(
                  hintText: 'Ask Fa anything…',
                  prefixIcon: Icon(Icons.auto_awesome),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FaButton(label: 'Continue', onPressed: () {}),
                    ),
                    const SizedBox(width: 10),
                    FaIconButton(icon: Icons.add, onPressed: () {}),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FaButton(
                        label: 'Secondary',
                        variant: FaButtonVariant.secondary,
                        onPressed: () {},
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FaButton(
                        label: 'Ghost',
                        variant: FaButtonVariant.ghost,
                        onPressed: () {},
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FaBadge('Connected'),
              FaChip(label: 'Liquid Glass', icon: Icons.blur_on),
              FaChip(label: 'Adaptive', icon: Icons.devices),
            ],
          ),
          const SizedBox(height: 16),
          FaCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                FaSettingsTile(
                  leading: Icon(Icons.wifi),
                  title: Text('Join a network'),
                  subtitle: Text('Provider-free onboarding'),
                  trailing: FaSwitch(value: true, onChanged: (_) {}),
                ),
                Divider(height: 1, color: tokens.hairline),
                const FaSettingsTile(
                  leading: Icon(Icons.grid_4x4),
                  title: Text('Responsive app grid'),
                  subtitle: Text('4 columns · 6 columns · 8 columns'),
                  trailing: FaBadge('4 / 6 / 8'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text('Accent intensity'),
          FaSlider(value: .65, onChanged: (_) {}),
        ],
      ),
    );
  }
}

class _AdaptiveConversation extends StatelessWidget {
  const _AdaptiveConversation();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Good evening.',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'The same conversation, controls and brand at every window size.',
          style: TextStyle(color: FaDesignTokens.of(context).ink2),
        ),
        const SizedBox(height: 24),
        const FaCard(
          child: Text(
            'Small keeps the content first. Medium adds navigation and sessions. Large opens the board.',
          ),
        ),
        const SizedBox(height: 16),
        const FaSurface(
          glass: true,
          child: FaTextField(
            hintText: 'Message Fa…',
            prefixIcon: Icon(Icons.add),
            suffixIcon: Icon(Icons.arrow_upward),
          ),
        ),
      ],
    );
  }
}

class _SessionPanel extends StatelessWidget {
  const _SessionPanel();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        Text('Sessions'),
        SizedBox(height: 16),
        FaCard(child: Text('Design system')),
        SizedBox(height: 8),
        FaCard(child: Text('Responsive shell')),
        SizedBox(height: 8),
        FaCard(child: Text('Liquid Glass')),
      ],
    );
  }
}

class _BoardPanel extends StatelessWidget {
  const _BoardPanel();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        Text('Board'),
        SizedBox(height: 16),
        FaAppIcon(icon: Icon(Icons.check_circle), label: 'Tasks'),
        SizedBox(height: 20),
        FaAppIcon(icon: Icon(Icons.bar_chart), label: 'Insights'),
      ],
    );
  }
}
