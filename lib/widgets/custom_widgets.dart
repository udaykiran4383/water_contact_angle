import 'package:flutter/material.dart';
import '../utils/app_colors.dart';
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';

class GradientHeader extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final String? fileName;

  const GradientHeader({
    Key? key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.fileName,
  }) : super(key: key);

  @override
  State<GradientHeader> createState() => _GradientHeaderState();
}

class _GradientHeaderState extends State<GradientHeader>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _slideAnimation = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
        .animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Card(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: AppColors.primaryGradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primaryBlue.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              children: [
                ScaleTransition(
                  scale: Tween<double>(begin: 0.8, end: 1).animate(
                    CurvedAnimation(parent: _animationController, curve: Curves.elasticOut),
                  ),
                  child: Icon(widget.icon, size: 64, color: AppColors.white),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: AppColors.white,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.subtitle,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFFE0E7FF),
                    height: 1.5,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (widget.fileName != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.insert_drive_file,
                            size: 14, color: AppColors.white),
                        const SizedBox(width: 8),
                        Text(
                          widget.fileName!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.white,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ActionButtonRow extends StatelessWidget {
  final VoidCallback onGallery;
  final VoidCallback onCamera;
  final bool isLoading;

  const ActionButtonRow({
    Key? key,
    required this.onGallery,
    required this.onCamera,
    required this.isLoading,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _AnimatedButton(
            onPressed: isLoading ? null : onGallery,
            icon: Icons.photo_library,
            label: 'Gallery',
            backgroundColor: AppColors.accentGreen,
            isLoading: isLoading,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _AnimatedButton(
            onPressed: isLoading ? null : onCamera,
            icon: Icons.camera_alt,
            label: 'Camera',
            backgroundColor: AppColors.info,
            isLoading: isLoading,
          ),
        ),
      ],
    );
  }
}

class _AnimatedButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final Color backgroundColor;
  final bool isLoading;

  const _AnimatedButton({
    Key? key,
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.isLoading,
  }) : super(key: key);

  @override
  State<_AnimatedButton> createState() => _AnimatedButtonState();
}

class _AnimatedButtonState extends State<_AnimatedButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: ElevatedButton.icon(
        onPressed: widget.isLoading
            ? null
            : () {
                _controller.forward().then((_) {
                  _controller.reverse();
                  widget.onPressed?.call();
                });
              },
        icon: Icon(widget.icon, size: 20),
        label: Text(widget.label),
        style: ElevatedButton.styleFrom(
          backgroundColor: widget.backgroundColor,
          foregroundColor: AppColors.white,
          disabledBackgroundColor: AppColors.mediumGray,
          elevation: 4,
          shadowColor: widget.backgroundColor.withOpacity(0.4),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }
}

class ProcessingIndicator extends StatefulWidget {
  const ProcessingIndicator({Key? key}) : super(key: key);

  @override
  State<ProcessingIndicator> createState() => _ProcessingIndicatorState();
}

class _ProcessingIndicatorState extends State<ProcessingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, -0.2), end: Offset.zero)
          .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Card(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: [
                const Color(0xFFFEF3C7).withOpacity(0.8),
                const Color(0xFFFEF08A).withOpacity(0.8),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: const Color(0xFFFCD34D), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFCD34D).withOpacity(0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.accentOrange),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Analyzing droplet...',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF92400E),
                        letterSpacing: 0.3,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Processing image with advanced algorithms',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFFB45309),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData? icon;
  final String? unit;

  const MetricTile({
    Key? key,
    required this.label,
    required this.value,
    required this.color,
    this.icon,
    this.unit,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withOpacity(0.08),
        border: Border.all(color: color.withOpacity(0.25), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 12),
              ],
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.darkGray,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                  letterSpacing: -0.5,
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(
                  unit!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color.withOpacity(0.7),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class SurfaceIndicator extends StatelessWidget {
  final String surfaceType;
  final double angle;

  const SurfaceIndicator({
    Key? key,
    required this.surfaceType,
    required this.angle,
  }) : super(key: key);

  Color _getSurfaceColor() {
    if (angle < 90) return AppColors.hydrophilic;
    if (angle > 120) return AppColors.hydrophobic;
    return AppColors.accentOrange;
  }

  String _getSurfaceLabel() {
    if (angle < 90) return 'Hydrophilic';
    if (angle > 120) return 'Hydrophobic';
    return 'Intermediate';
  }

  @override
  Widget build(BuildContext context) {
    final color = _getSurfaceColor();
    final label = _getSurfaceLabel();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.3), width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              angle < 90 ? Icons.opacity : Icons.water_drop,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Surface Type',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.darkGray,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${angle.toStringAsFixed(1)}°',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ResultsCard extends StatelessWidget {
  final String resultText;
  final double? angle;
  final double? uncertainty;
  final VoidCallback onExport;
  final Map<String, dynamic>? latestResult;

  const ResultsCard({
    Key? key,
    required this.resultText,
    this.angle,
    this.uncertainty,
    required this.onExport,
    this.latestResult,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AppColors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: AppColors.primaryGradient,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.assessment,
                      color: AppColors.white, size: 24),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Analysis Results',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryBlue,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            if (angle != null && angle!.isFinite)
              MetricTile(
                label: 'Contact Angle',
                value: angle!.toStringAsFixed(2),
                unit: '°',
                color: AppColors.info,
                icon: Icons.water_drop,
              ),
            if (uncertainty != null && uncertainty!.isFinite)
              MetricTile(
                label: 'Uncertainty',
                value: '±${uncertainty!.toStringAsFixed(2)}',
                unit: '°',
                color: AppColors.accentPurple,
                icon: Icons.error_outline,
              ),
            
            if (angle != null && angle!.isFinite) ...[
              const SizedBox(height: 12),
              SurfaceIndicator(
                surfaceType: latestResult?['surface_type'] ?? 'Unknown',
                angle: angle!,
              ),
            ],
            
            const SizedBox(height: 16),
            Divider(color: Colors.grey[200], thickness: 1),
            const SizedBox(height: 16),
            
            Text(
              'Detailed Analysis',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.grey[800],
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: Colors.grey[50],
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Text(
                resultText,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: Colors.grey[700],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onExport,
                icon: const Icon(Icons.file_download, size: 18),
                label: const Text('Export CSV'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryCyan,
                  foregroundColor: AppColors.white,
                  elevation: 4,
                  shadowColor: AppColors.primaryCyan.withOpacity(0.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ImageDisplayCard extends StatelessWidget {
  final String title;
  final File imageFile;
  final VoidCallback? onSave;

  const ImageDisplayCard({
    Key? key,
    required this.title,
    required this.imageFile,
    this.onSave,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primaryBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.image, color: AppColors.primaryBlue, size: 20),
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlue,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              imageFile,
              fit: BoxFit.contain,
              height: 280,
              width: double.infinity,
            ),
          ),
        ),
        if (onSave != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Save Image'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentPurple,
                foregroundColor: AppColors.white,
                elevation: 4,
                shadowColor: AppColors.accentPurple.withOpacity(0.4),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class LegendItem extends StatelessWidget {
  final String label;
  final Color boxColor;
  final Color borderColor;

  const LegendItem({
    Key? key,
    required this.label,
    required this.boxColor,
    required this.borderColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: boxColor.withOpacity(0.1),
        border: Border.all(color: borderColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: boxColor,
              border: Border.all(color: borderColor, width: 1.5),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }
}

class AnnotatedImageSection extends StatelessWidget {
  final File annotatedImage;
  final VoidCallback onSave;

  const AnnotatedImageSection({
    Key? key,
    required this.annotatedImage,
    required this.onSave,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primaryBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.edit, color: AppColors.primaryBlue, size: 20),
            ),
            const SizedBox(width: 12),
            const Text(
              'Annotated Analysis',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlue,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Colors.grey[50],
            border: Border.all(color: Colors.grey[200]!),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Legend',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[800],
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  LegendItem(
                    label: 'Baseline',
                    boxColor: Colors.white,
                    borderColor: Colors.grey[400]!,
                  ),
                  LegendItem(
                    label: 'Circle Fit',
                    boxColor: Colors.blue,
                    borderColor: Colors.blue,
                  ),
                  LegendItem(
                    label: 'Left Tangent',
                    boxColor: Colors.green,
                    borderColor: Colors.green,
                  ),
                  LegendItem(
                    label: 'Right Tangent',
                    boxColor: Colors.red,
                    borderColor: Colors.red,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              annotatedImage,
              fit: BoxFit.contain,
              height: 280,
              width: double.infinity,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: onSave,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Save Annotated Image'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentPurple,
              foregroundColor: AppColors.white,
              elevation: 4,
              shadowColor: AppColors.accentPurple.withOpacity(0.4),
            ),
          ),
        ),
      ],
    );
  }
}

class TipsSection extends StatefulWidget {
  const TipsSection({Key? key}) : super(key: key);

  @override
  State<TipsSection> createState() => _TipsSectionState();
}

class _TipsSectionState extends State<TipsSection>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tips = [
      'Use backlit droplet images (silhouette against bright background)',
      'Ensure droplet is centered and touches clear surface',
      'Avoid glare and reflections on droplet surface',
      'Higher resolution images improve accuracy',
      'Expected angles: 0-180° (0°=complete wetting, 180°=superhydrophobic)',
    ];

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Card(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: [
                const Color(0xFFFEF08A).withOpacity(0.9),
                const Color(0xFFFEF3C7).withOpacity(0.9),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: const Color(0xFFFCD34D), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFCD34D).withOpacity(0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.lightbulb, color: AppColors.accentOrange, size: 22),
                  SizedBox(width: 10),
                  Text(
                    'Tips for Best Results',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF92400E),
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ...tips.asMap().entries.map((entry) {
                int index = entry.key;
                String tip = entry.value;
                return TipItem(
                  text: tip,
                  index: index,
                  totalTips: tips.length,
                );
              }).toList(),
            ],
          ),
        ),
      ),
    );
  }
}

class TipItem extends StatefulWidget {
  final String text;
  final int index;
  final int totalTips;

  const TipItem({
    Key? key,
    required this.text,
    required this.index,
    required this.totalTips,
  }) : super(key: key);

  @override
  State<TipItem> createState() => _TipItemState();
}

class _TipItemState extends State<TipItem> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(begin: const Offset(-0.2, 0), end: Offset.zero)
        .animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    Future.delayed(Duration(milliseconds: widget.index * 100), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: const Color(0xFFB45309).withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Center(
                child: Text(
                  '•',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFB45309),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.text,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF78350F),
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InstitutionHeader extends StatelessWidget {
  const InstitutionHeader({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primaryBlue,
            AppColors.primaryBlue.withOpacity(0.95),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border(
          bottom: BorderSide(
            color: AppColors.primaryCyan.withOpacity(0.3),
            width: 2,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryBlue.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Image.network(
                'https://hebbkx1anhila5yf.public.blob.vercel-storage.com/Indian_Institute_of_Technology_Bombay_Logo.svg-oogRtGScrsqNLOiSfKMt9eruF7ycrG.png',
                width: 48,
                height: 48,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'IIT',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryBlue,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        'B',
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryCyan,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Water Contact Angle Analyzer',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'IIT Bombay | MEMS',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.primaryCyan,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Prof. S. Mallick',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withOpacity(0.9),
                    fontWeight: FontWeight.w500,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DeveloperFooter extends StatefulWidget {
  const DeveloperFooter({Key? key}) : super(key: key);

  @override
  State<DeveloperFooter> createState() => _DeveloperFooterState();
}

class _DeveloperFooterState extends State<DeveloperFooter>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _launchLinkedIn() async {
    const url = 'https://www.linkedin.com/in/uday-yennampelly/';
    try {
      if (await canLaunchUrl(Uri.parse(url))) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      print('Error launching LinkedIn: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.primaryBlue,
              AppColors.primaryBlue.withOpacity(0.9),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border(
            top: BorderSide(
              color: AppColors.primaryCyan.withOpacity(0.3),
              width: 1.5,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryBlue.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.code,
                        size: 12,
                        color: AppColors.primaryCyan,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Developed by Udaykiran (22B2509)',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '© 2025 IIT Bombay MEMS',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withOpacity(0.5),
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: _launchLinkedIn,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: AppColors.primaryCyan.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.link,
                      size: 10,
                      color: AppColors.primaryCyan,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'LinkedIn',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryCyan,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
