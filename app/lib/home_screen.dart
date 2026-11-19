import 'dart:async';

import 'package:flutter/material.dart';

import 'check_screen.dart';
import 'check_session.dart';
import 'main.dart';
import 'raw_screen.dart';
import 'serial_link.dart';
import 'sites/site_store.dart';
import 'sites/sites_screen.dart';

/// The app's tabs: Plot, Check, and Sites. It owns the one connection to the logger, which the Plot and Check tabs
/// share. Only the Plot tab answers the logger's startup prompt with commands that change its settings, so moving
/// between Plot and the other tabs restarts the logger: away from Plot, it runs exactly as CONFIG.TXT says.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialTab = checkTab});

  static const plotTab = 0;
  static const checkTab = 1;
  static const rawTab = 3;
  final int initialTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final link = SerialLink();
  late final check = CheckSession(link);
  final sites = SiteStore();
  late int tab = widget.initialTab;
  // One key per tab, so a tab keeps its state (text, plots, settings) when turning the phone swaps the layout below.
  final _bodyKeys = [for (var i = 0; i < 4; i++) GlobalKey()];

  static const _destinations = [
    (icon: Icons.show_chart, label: 'Plot'),
    (icon: Icons.fact_check_outlined, label: 'Check'),
    (icon: Icons.place_outlined, label: 'Sites'),
    (icon: Icons.terminal, label: 'Raw'),
  ];

  @override
  void initState() {
    super.initState();
    link.plotMode = tab == HomeScreen.plotTab;
    check.start(); // listens before the connection starts, so it sees the logger's whole startup
    link.start();
  }

  @override
  void dispose() {
    check.dispose();
    sites.dispose();
    link.dispose();
    super.dispose();
  }

  Future<void> _select(int i) async {
    if (i == tab) return;
    // Leaving the Raw tab: the port goes back to the logger's baud rate before anything restarts the logger.
    if (tab == HomeScreen.rawTab && link.baud != SerialLink.normalBaud && link.currentStatus == 'connected') {
      await link.setBaud(SerialLink.normalBaud);
    }
    if (!mounted) return;
    setState(() => tab = i);
    unawaited(link.setPlotMode(i == HomeScreen.plotTab));
  }

  Widget _body() => KeyedSubtree(
        key: _bodyKeys[tab],
        child: switch (tab) {
          HomeScreen.plotTab => PlotScreen(link: link),
          HomeScreen.checkTab => CheckScreen(session: check),
          HomeScreen.rawTab => RawScreen(link: link),
          _ => SitesScreen(store: sites, check: check),
        },
      );

  /// The tabs down the left edge when the phone is sideways: as narrow as the labels allow, to leave room for the content.
  Widget _sideTabs() {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      key: const Key('side-tabs'),
      width: 46,
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _destinations.length; i++)
                InkWell(
                  onTap: () => _select(i),
                  child: Container(
                    width: 46,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    color: i == tab ? primary.withValues(alpha: 0.12) : null,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_destinations[i].icon, size: 22, color: i == tab ? primary : Colors.black54),
                        Text(
                          _destinations[i].label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: i == tab ? FontWeight.bold : FontWeight.normal,
                            color: i == tab ? primary : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final landscape = MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    if (landscape) {
      // Sideways (for bigger plots): the tabs go down the left edge instead of along the bottom.
      return Scaffold(
        body: Row(
          children: [
            SafeArea(right: false, child: _sideTabs()),
            const VerticalDivider(width: 1),
            Expanded(child: _body()),
          ],
        ),
      );
    }
    return Scaffold(
      body: _body(),
      bottomNavigationBar: NavigationBar(
        height: 60,
        selectedIndex: tab,
        onDestinationSelected: _select,
        destinations: [for (final d in _destinations) NavigationDestination(icon: Icon(d.icon), label: d.label)],
      ),
    );
  }
}
