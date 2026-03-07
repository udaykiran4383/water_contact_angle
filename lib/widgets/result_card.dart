import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'glass_card.dart';

/// Comprehensive scientific results display card.
/// Reads actual keys from ImageProcessor.processImage output.
class ResultCard extends StatelessWidget {
  final Map<String, dynamic> results;

  const ResultCard({super.key, required this.results});

  // ── helpers ──────────────────────────────────────────────

  double _d(String key) =>
      (results[key] as num?)?.toDouble() ?? double.nan;

  String _fmtAngle(double v, {int decimals = 1}) =>
      v.isFinite ? '${v.toStringAsFixed(decimals)}°' : '—';

  String _fmtNum(double v, {int decimals = 2}) =>
      v.isFinite ? v.toStringAsFixed(decimals) : '—';

  String _fmtSci(double v, {int digits = 2}) =>
      v.isFinite ? v.toStringAsExponential(digits) : '—';

  @override
  Widget build(BuildContext context) {
    final angle = _d('angle_numeric');
    final uncertainty = _d('uncertainty_numeric');
    final left = _d('angle_left');
    final right = _d('angle_right');
    final hysteresis = (left.isFinite && right.isFinite)
        ? (left - right).abs()
        : double.nan;
    final baselineTilt = _d('baseline_tilt');
    final surfaceType = results['surface_type'] as String? ?? '—';
    final contourCount = results['contour_count'] as int? ?? 0;
    final pixelSizeUm = _d('pixel_size_um');
    final dropRadiusMm = _d('drop_radius_mm');
    final dropRadiusPx = _d('drop_radius_px');
    final bondNumber = _d('bond_number');
    final bondPhysical = _d('bond_number_physical');
    final bondPhysicalUnc = _d('bond_number_physical_uncertainty');
    final scaleSource = results['scale_source'] as String? ?? '';
    final isCalibrated = results['scale_is_calibrated'] == true;
    final scaleRelUnc = _d('scale_relative_uncertainty');
    final surfaceMode = results['surface_mode'] as String? ?? '';
    final substrateSlopeDeg = _d('substrate_slope_deg');
    final appliedRotation = _d('applied_rotation_deg');
    final text = results['text'] as String? ?? '';

    // Background detection from text
    String background = 'Light';
    if (text.contains('Background: Dark')) {
      background = 'Dark (auto-corrected)';
    }

    // Method angles & R² values
    final thetaCircle = _d('theta_circle');
    final thetaEllipse = _d('theta_ellipse');
    final thetaPoly = _d('theta_poly');
    final thetaYL = _d('theta_young_laplace');
    final r2Circle = _d('r_squared_circle');
    final r2Ellipse = _d('r_squared_ellipse');
    final r2YL = _d('r_squared_young_laplace');
    final bondFit = _d('bond_number_fit');

    // Method quality/rejection reasons
    final methodQuality = results['method_quality'] as Map<String, dynamic>?;

    // Uncertainty breakdown
    final uncBootstrap = _d('uncertainty_bootstrap');
    final uncMethod = _d('uncertainty_method');
    final uncEdge = _d('uncertainty_edge');

    // If result is an error, show error text
    if (text.startsWith('❌')) {
      return GlassCard(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 14, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title row ──
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.tealAccent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.science,
                    color: AppTheme.tealAccent, size: 20),
              ),
              const SizedBox(width: 12),
              const Text(
                'Analysis Results',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ═══════════ Primary result: Contact Angle ± Uncertainty ═══════════
          _primaryAngle(angle, uncertainty),
          const SizedBox(height: 16),

          // ═══════════ Left / Right / Hysteresis / Baseline tilt ═══════════
          _sectionLabel('Angle Details'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child:
                      _metricTile('Left', _fmtAngle(left), Colors.cyanAccent)),
              const SizedBox(width: 10),
              Expanded(
                  child: _metricTile(
                      'Right', _fmtAngle(right), Colors.cyanAccent)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: _metricTile('Hysteresis', _fmtAngle(hysteresis),
                      Colors.amberAccent)),
              const SizedBox(width: 10),
              Expanded(
                  child: _metricTile(
                      'Baseline Tilt',
                      _fmtAngle(baselineTilt, decimals: 2),
                      Colors.blueAccent)),
            ],
          ),
          if (substrateSlopeDeg.isFinite &&
              substrateSlopeDeg.abs() > 0.01) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                    child: _metricTile(
                        'Substrate Slope',
                        _fmtAngle(substrateSlopeDeg, decimals: 2),
                        Colors.deepPurpleAccent)),
                const SizedBox(width: 10),
                if (appliedRotation.isFinite && appliedRotation.abs() > 0.01)
                  Expanded(
                      child: _metricTile(
                          'Applied Rotation',
                          _fmtAngle(appliedRotation, decimals: 2),
                          Colors.deepPurpleAccent))
                else
                  const Expanded(child: SizedBox()),
              ],
            ),
          ],
          const SizedBox(height: 16),

          // ═══════════ Methods ═══════════
          _sectionLabel('Methods'),
          const SizedBox(height: 8),
          _methodRow('Circle fit', thetaCircle, r2Circle,
              rejection: _rejectionReason(methodQuality, 'circle')),
          _methodRow('Ellipse fit', thetaEllipse, r2Ellipse,
              rejection: _rejectionReason(methodQuality, 'ellipse')),
          _methodRow('Polynomial', thetaPoly, null,
              rejection: _rejectionReason(methodQuality, 'polynomial')),
          _methodRow('Young-Laplace', thetaYL, r2YL,
              extra: bondFit.isFinite ? 'Bo=${_fmtSci(bondFit)}' : null,
              rejection: _rejectionReason(methodQuality, 'young_laplace')),
          const SizedBox(height: 16),

          // ═══════════ Physical metrics ═══════════
          _sectionLabel('Physical Metrics'),
          const SizedBox(height: 8),
          _infoRow(
              'Scale',
              '${_fmtNum(pixelSizeUm, decimals: 3)} µm/px'
                  '${isCalibrated ? '' : ' (approx)'}'),
          if (scaleRelUnc.isFinite)
            _infoRow('Scale uncert.',
                '±${(scaleRelUnc * 100.0).toStringAsFixed(2)}%'),
          _infoRow('Drop radius', '${_fmtNum(dropRadiusMm, decimals: 4)} mm'
              ' (${_fmtNum(dropRadiusPx, decimals: 1)} px)'),
          _infoRow(
              'Bo (physical)',
              '${_fmtSci(bondPhysical)}'
                  '${bondPhysicalUnc.isFinite ? ' ± ${_fmtSci(bondPhysicalUnc, digits: 1)}' : ''}'),
          if (bondNumber.isFinite && bondNumber != bondPhysical)
            _infoRow('Bo (fit)', _fmtSci(bondNumber)),
          const SizedBox(height: 16),

          // ═══════════ Surface & Diagnostics ═══════════
          _sectionLabel('Diagnostics'),
          const SizedBox(height: 8),
          _infoRow('Surface', surfaceType),
          if (surfaceMode.isNotEmpty) _infoRow('Mode', surfaceMode),
          _infoRow('Contour', '$contourCount points'),
          _infoRow('Background', background),
          if (scaleSource.isNotEmpty) _infoRow('Scale source', scaleSource),
          const SizedBox(height: 16),

          // ═══════════ Uncertainty Breakdown ═══════════
          if (uncBootstrap.isFinite || uncMethod.isFinite || uncEdge.isFinite) ...[
            _sectionLabel('Uncertainty Breakdown'),
            const SizedBox(height: 4),
            Text(
              'Combined ± ${_fmtNum(uncertainty)}° from these sources:',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            if (uncBootstrap.isFinite)
              _uncertaintyRow(
                '±${_fmtNum(uncBootstrap)}°',
                'Sampling noise',
                'How stable the fit is when data points are resampled',
                Colors.lightBlueAccent,
              ),
            if (uncMethod.isFinite)
              _uncertaintyRow(
                '±${_fmtNum(uncMethod)}°',
                'Method agreement',
                'How closely circle, ellipse, and polynomial fits agree',
                Colors.orangeAccent,
              ),
            if (uncEdge.isFinite)
              _uncertaintyRow(
                '±${_fmtNum(uncEdge)}°',
                'Edge precision',
                'Pixel-level accuracy of detected drop boundary',
                Colors.purpleAccent,
              ),
            const SizedBox(height: 16),
          ],

          // ═══════════ Scientific notation summary ═══════════
          _sectionLabel('Scientific Notation'),
          const SizedBox(height: 8),
          _infoRow('Angle', '${_fmtSci(angle)}°'),
          if (bondPhysical.isFinite)
            _infoRow('Bo',
                '${_fmtSci(bondPhysical)} | R: ${_fmtNum(dropRadiusMm, decimals: 4)} mm'),
          _infoRow(
              'Scale',
              '${_fmtNum(pixelSizeUm, decimals: 3)} µm/px'
                  ' (${isCalibrated ? scaleSource : 'fallback_approximate'})'),

          // ═══════════ Calibration warning ═══════════
          if (!isCalibrated) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: Colors.amber.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: Colors.amber.withValues(alpha: 0.8)),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Physical units approximate — add scale calibration for scientific metrology.',
                      style: TextStyle(
                          color: Colors.amber, fontSize: 11, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Sub-widgets ─────────────────────────────────────────

  String? _rejectionReason(
      Map<String, dynamic>? quality, String methodName) {
    if (quality == null) return null;
    final entry = quality[methodName] as Map<String, dynamic>?;
    if (entry == null) return null;
    if (entry['is_valid'] == true) return null;
    return entry['invalid_reason'] as String?;
  }

  Widget _primaryAngle(double angle, double uncertainty) {
    final angleStr = angle.isFinite ? angle.toStringAsFixed(2) : '—';
    final uncStr =
        uncertainty.isFinite ? '± ${uncertainty.toStringAsFixed(2)}°' : '';

    // Color-code uncertainty quality
    Color uncColor;
    String uncQuality;
    if (!uncertainty.isFinite) {
      uncColor = Colors.grey;
      uncQuality = '';
    } else if (uncertainty <= 2.0) {
      uncColor = Colors.greenAccent;
      uncQuality = '  Excellent';
    } else if (uncertainty <= 5.0) {
      uncColor = Colors.lightGreenAccent;
      uncQuality = '  Good';
    } else if (uncertainty <= 8.0) {
      uncColor = Colors.amberAccent;
      uncQuality = '  Fair';
    } else {
      uncColor = Colors.redAccent;
      uncQuality = '  Poor';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          AppTheme.tealAccent.withValues(alpha: 0.12),
          Colors.cyan.withValues(alpha: 0.06),
        ]),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: AppTheme.tealAccent.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          const Text('🎯  Contact Angle',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$angleStr°',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'RobotoMono',
                ),
              ),
              if (uncStr.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  uncStr,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 16,
                    fontFamily: 'RobotoMono',
                  ),
                ),
              ],
            ],
          ),
          if (uncStr.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: uncColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  'Combined Uncertainty$uncQuality',
                  style: TextStyle(
                    color: uncColor.withValues(alpha: 0.8),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        color: AppTheme.tealAccent.withValues(alpha: 0.8),
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _metricTile(String label, String value, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'RobotoMono')),
        ],
      ),
    );
  }

  Widget _methodRow(String name, double angle, double? r2,
      {String? extra, String? rejection}) {
    final valid = angle.isFinite;
    final angleText = valid ? '${angle.toStringAsFixed(1)}°' : 'N/A';
    final r2Text =
        (r2 != null && r2.isFinite) ? '(R²=${r2.toStringAsFixed(3)})' : '';
    final extraText = extra != null ? ' $extra' : '';
    final rejText = (!valid && rejection != null) ? ' [$rejection]' : '';
    final statusColor = valid
        ? Colors.greenAccent.withValues(alpha: 0.7)
        : Colors.redAccent.withValues(alpha: 0.5);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration:
                BoxDecoration(color: statusColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: Text(name,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12)),
          ),
          Expanded(
            child: Text(
              '$angleText $r2Text$extraText$rejText',
              style: TextStyle(
                color: valid ? Colors.white : Colors.white38,
                fontSize: 12,
                fontFamily: 'RobotoMono',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'RobotoMono')),
          ),
        ],
      ),
    );
  }

  Widget _uncertaintyRow(
      String value, String label, String description, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'RobotoMono',
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12,
                        fontWeight: FontWeight.w500)),
                Text(description,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 10,
                        height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
