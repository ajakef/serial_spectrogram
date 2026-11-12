import 'package:flutter/material.dart';

import 'sample_rate.dart';

/// A small menu at the top of the plot screen showing the sample rate ("200 sps"). Picking another rate sets
/// [SampleRate.current] and calls [onChanged], which clears the plots and restarts the Aspen so that it takes the
/// new rate at its startup prompt.
class RateMenu extends StatelessWidget {
  const RateMenu({super.key, required this.onChanged});

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Sample rate',
      initialValue: SampleRate.current,
      onSelected: (rate) {
        if (rate == SampleRate.current) return;
        SampleRate.current = rate;
        onChanged();
      },
      itemBuilder: (context) => [
        for (final r in SampleRate.choices) PopupMenuItem<int>(value: r, child: Text('$r samples per second')),
      ],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text('${SampleRate.current} sps', style: const TextStyle(color: Colors.black54)),
      ),
    );
  }
}
