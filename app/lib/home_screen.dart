import 'dart:async';

import 'package:flutter/material.dart';

import 'check_screen.dart';
import 'check_session.dart';
import 'main.dart';
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
  final int initialTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final link = SerialLink();
  late final check = CheckSession(link);
  final sites = SiteStore();
  late int tab = widget.initialTab;

  static const _destinations = [
    (icon: Icons.show_chart, label: 'Plot'),
    (icon: Icons.fact_check_outlined, label: 'Check'),
    (icon: Icons.place_outlined, label: 'Sites'),
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

  void _select(int i) {
    if (i == tab) return;
    setState(() => tab = i);
    unawaited(link.setPlotMode(i == HomeScreen.plotTab));
  }

  Widget _body() => switch (tab) {
        HomeScreen.plotTab => PlotScreen(link: link),
        HomeScreen.checkTab => CheckScreen(session: check),
        _ => SitesScreen(store: sites, check: check),
      };

  @override
  Widget build(BuildContext context) {
    final landscape = MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    if (landscape) {
      // Sideways (for bigger plots): the tabs go down the left edge instead of along the bottom.
      return Scaffold(
        body: Row(
          children: [
            SafeArea(
              right: false,
              child: NavigationRail(
                selectedIndex: tab,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                minWidth: 56,
                destinations: [
                  for (final d in _destinations) NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
                ],
              ),
            ),
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
