import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class QualityGauge extends StatelessWidget {
  final double score;       // 0.0 – 1.0
  final List<String> warnings;

  const QualityGauge({
    super.key,
    required this.score,
    this.warnings = const [],
  });

  Color get _color =>
      score > 0.7 ? AppTheme.tealAccent :
      score > 0.4 ? AppTheme.amberWarn  : AppTheme.errorRed;

  String get _label =>
      score > 0.7 ? 'Excellent' :
      score > 0.4 ? 'Fair'      : 'Poor';

  @override
  Widget build(BuildContext context) {
    final pct = (score * 100).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              score > 0.7 ? Icons.verified_rounded :
              score > 0.4 ? Icons.warning_amber_rounded : Icons.error_rounded,
              color: _color, size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              '$_label  $pct%',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: score,
            minHeight: 6,
            backgroundColor: AppTheme.dividerColor,
            valueColor: AlwaysStoppedAnimation<Color>(_color),
          ),
        ),
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...warnings.map((w) => Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('⚠ ', style: TextStyle(fontSize: 12)),
                Expanded(
                  child: Text(w,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.amberWarn.withValues(alpha: 0.9),
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          )),
        ],
      ],
    );
  }
}
