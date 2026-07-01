import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'image_processor.dart';

import 'theme/app_theme.dart';
import 'processing/silhouette_extractor.dart';
import 'widgets/roi_select_screen.dart';
import 'widgets/glass_card.dart';
import 'widgets/gradient_button.dart';
import 'widgets/image_preview_card.dart';
import 'widgets/image_viewer.dart';
import 'widgets/loading_overlay.dart';
import 'widgets/result_card.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Water Contact Angle Analyzer',
      theme: AppTheme.darkTheme,
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  File? _image;
  String? _resultText;
  File? _annotatedImage;
  bool _isProcessing = false;
  final ImagePicker _picker = ImagePicker();

  /// Holds the raw numeric results returned by ImageProcessor for CSV/export
  Map<String, dynamic>? _latestResult;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      // High resolution + near-lossless quality: the silhouette/ADSA precision
      // scales with the number of edge pixels along the drop profile, so we
      // keep the goniometer capture as detailed as practical.
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 100,
      );

      if (pickedFile != null) {
        File imageFile = File(pickedFile.path);

        // Let the user optionally box the drop (excludes background features).
        if (!mounted) return;
        final selection = await showRoiSelector(context, imageFile);
        if (!selection.proceed) return; // user backed out
        final DropRoi? roi = selection.roi;

        setState(() {
          _isProcessing = true;
          _resultText = 'Processing image...';
          _latestResult = null;
          _image = null;
          _annotatedImage = null;
        });

        var result = await ImageProcessor.processImage(imageFile, roi: roi);

        if (!mounted) return;

        setState(() {
          _image = imageFile;
          _resultText = result['text'];
          _annotatedImage = result['annotated'];
          _latestResult = result; // store numeric & metadata for CSV
        });
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
      if (!mounted) return;
      setState(() {
        _resultText = 'Error: $e\n\nPlease check permissions and try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  /// Save annotated image to gallery
  Future<void> _saveAnnotatedImage() async {
    if (_annotatedImage == null) return;

    try {
      final bytes = await _annotatedImage!.readAsBytes();
      final result = await ImageGallerySaverPlus.saveImage(
        Uint8List.fromList(bytes),
        quality: 100,
        name: "contact_angle_result_${DateTime.now().millisecondsSinceEpoch}",
      );

      _showSnack(result['isSuccess'] == true
          ? "✅ Annotated image saved to gallery!"
          : "❌ Failed to save image.");
    } catch (e) {
      debugPrint("Error saving image: $e");
      _showSnack("❌ Error saving image: $e");
    }
  }

  /// Export the latest results (single-row) to CSV in app documents directory.
  Future<void> _exportResultsToCSV() async {
    if (_latestResult == null) {
      _showSnack('No results to export.');
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final filename =
          'contact_angle_results_${DateTime.now().millisecondsSinceEpoch}.csv';
      final filePath = '${dir.path}/$filename';

      // Build header and CSV row
      final headers = [
        'timestamp',
        'source_file',
        'angle_deg',
        'angle_scientific',
        'uncertainty_deg',
        'uncertainty_scientific',
        'circle_deg',
        'ellipse_deg',
        'poly_deg',
        'young_laplace_deg',
        'angle_left_deg',
        'angle_right_deg',
        'hysteresis_deg',
        'r2_circle',
        'r2_ellipse',
        'r2_young_laplace',
        'uncertainty_bootstrap_deg',
        'uncertainty_method_deg',
        'uncertainty_edge_deg',
        'bond_number_fit',
        'bond_number_physical',
        'bond_number_physical_uncertainty',
        'drop_radius_px',
        'drop_radius_mm',
        'scale_calibrated',
        'scale_relative_uncertainty',
        'scale_source',
        'pixel_size_um',
        'meters_per_pixel',
        'surface_type',
        'contour_points',
        'baseline_y',
        'baseline_tilt_deg',
        'annotated_path'
      ];

      String escape(String v) => '"${v.replaceAll('"', '""')}"';

      String timestamp = DateTime.now().toIso8601String();
      String sourceFile =
          _latestResult!['filename'] ?? (_image?.path.split('/').last ?? '');
      double n(String key) =>
          (_latestResult![key] as num?)?.toDouble() ?? double.nan;
      bool b(String key) =>
          (_latestResult![key] as bool?) ?? ((_latestResult![key] as num?) == 1);
      String surface = _latestResult!['surface_type'] ?? '';
      int contourCount =
          (_latestResult!['contour_count'] as num?)?.toInt() ?? 0;
      String annotatedPath = _latestResult!['annotated_path'] ?? '';

      final angle = n('angle_numeric');
      final uncertainty = n('uncertainty_numeric');
      final angleLeft = n('angle_left');
      final angleRight = n('angle_right');
      final hysteresis = (angleLeft.isFinite && angleRight.isFinite)
          ? (angleLeft - angleRight).abs()
          : double.nan;
      final scaleCalibrated = b('scale_is_calibrated');

      final headerLine = headers.map(escape).join(',');
      final row = [
        escape(timestamp),
        escape(sourceFile),
        escape(angle.isFinite ? angle.toStringAsFixed(6) : ''),
        escape(angle.isFinite ? angle.toStringAsExponential(3) : ''),
        escape(uncertainty.isFinite ? uncertainty.toStringAsFixed(6) : ''),
        escape(uncertainty.isFinite ? uncertainty.toStringAsExponential(3) : ''),
        escape(n('theta_circle').isFinite ? n('theta_circle').toStringAsFixed(6) : ''),
        escape(n('theta_ellipse').isFinite ? n('theta_ellipse').toStringAsFixed(6) : ''),
        escape(n('theta_poly').isFinite ? n('theta_poly').toStringAsFixed(6) : ''),
        escape(n('theta_young_laplace').isFinite ? n('theta_young_laplace').toStringAsFixed(6) : ''),
        escape(angleLeft.isFinite ? angleLeft.toStringAsFixed(6) : ''),
        escape(angleRight.isFinite ? angleRight.toStringAsFixed(6) : ''),
        escape(hysteresis.isFinite ? hysteresis.toStringAsFixed(6) : ''),
        escape(n('r_squared_circle').isFinite ? n('r_squared_circle').toStringAsFixed(6) : ''),
        escape(n('r_squared_ellipse').isFinite ? n('r_squared_ellipse').toStringAsFixed(6) : ''),
        escape(n('r_squared_young_laplace').isFinite ? n('r_squared_young_laplace').toStringAsFixed(6) : ''),
        escape(n('uncertainty_bootstrap').isFinite ? n('uncertainty_bootstrap').toStringAsFixed(6) : ''),
        escape(n('uncertainty_method').isFinite ? n('uncertainty_method').toStringAsFixed(6) : ''),
        escape(n('uncertainty_edge').isFinite ? n('uncertainty_edge').toStringAsFixed(6) : ''),
        escape(n('bond_number_fit').isFinite ? n('bond_number_fit').toStringAsExponential(6) : ''),
        escape(n('bond_number_physical').isFinite ? n('bond_number_physical').toStringAsExponential(6) : ''),
        escape(n('bond_number_physical_uncertainty').isFinite ? n('bond_number_physical_uncertainty').toStringAsExponential(6) : ''),
        escape(n('drop_radius_px').isFinite ? n('drop_radius_px').toStringAsFixed(6) : ''),
        escape(n('drop_radius_mm').isFinite ? n('drop_radius_mm').toStringAsFixed(6) : ''),
        escape(scaleCalibrated ? 'true' : 'false'),
        escape(n('scale_relative_uncertainty').isFinite ? n('scale_relative_uncertainty').toStringAsFixed(6) : ''),
        escape((_latestResult!['scale_source'] as String?) ?? ''),
        escape(n('pixel_size_um').isFinite ? n('pixel_size_um').toStringAsFixed(6) : ''),
        escape(n('meters_per_pixel').isFinite ? n('meters_per_pixel').toStringAsExponential(6) : ''),
        escape(surface),
        escape(contourCount.toString()),
        escape(n('baseline_y').isFinite ? n('baseline_y').toStringAsFixed(6) : ''),
        escape(n('baseline_tilt').isFinite ? n('baseline_tilt').toStringAsFixed(6) : ''),
        escape(annotatedPath),
      ].join(',');

      final csv = '$headerLine\n$row\n';

      final file = File(filePath);
      await file.writeAsString(csv);

      _showSnack('✅ CSV exported to: $filePath');
    } catch (e) {
      debugPrint('Error exporting CSV: $e');
      _showSnack('❌ Failed to export CSV: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Contact Angle Analyzer'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          // Background Gradient
          Container(
            decoration: const BoxDecoration(
              gradient: AppTheme.backgroundGradient,
            ),
          ),

          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  GlassCard(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.tealAccent.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.water_drop, size: 48, color: AppTheme.tealAccent),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Sessile Drop Analysis',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Automated scientific measurement',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_image != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'File: ${_image!.path.split('/').last}',
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Action Buttons
                  Row(
                    children: [
                      GradientButton(
                        onPressed: _isProcessing ? null : () => _pickImage(ImageSource.gallery),
                        icon: Icons.photo_library,
                        label: 'Gallery',
                      ),
                      const SizedBox(width: 16),
                      GradientButton(
                        onPressed: _isProcessing ? null : () => _pickImage(ImageSource.camera),
                        icon: Icons.camera_alt,
                        label: 'Camera',
                        colors: const [Colors.deepPurpleAccent, Colors.purpleAccent],
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Results Display (Using the new dark mode widget)
                  if (!_isProcessing && _latestResult != null) ...[
                    ResultCard(results: _latestResult!),
                    const SizedBox(height: 24),
                  ] else if (!_isProcessing && _resultText != null) ...[
                    // Fallback for simple error texts
                    GlassCard(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: AppTheme.amberWarn),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _resultText!,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Original Image
                  if (_image != null && !_isProcessing) ...[
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ImageViewerScreen(
                              image: FileImage(_image!),
                              title: 'Original Image',
                            ),
                          ),
                        );
                      },
                      child: ImagePreviewCard(
                        image: Image.file(_image!, fit: BoxFit.cover, width: double.infinity),
                        label: 'Original Image',
                        glowColor: Colors.blueAccent,
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Annotated Image
                  if (_annotatedImage != null && !_isProcessing) ...[
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ImageViewerScreen(
                              image: FileImage(_annotatedImage!),
                              title: 'Annotated Analysis',
                            ),
                          ),
                        );
                      },
                      child: ImagePreviewCard(
                        image: Image.file(_annotatedImage!, fit: BoxFit.cover, width: double.infinity),
                        label: 'Annotated Result',
                        glowColor: AppTheme.tealAccent,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        GradientButton(
                          onPressed: _saveAnnotatedImage,
                          icon: Icons.download,
                          label: 'Save Image',
                          colors: const [AppTheme.tealAccent, AppTheme.cyanLight],
                        ),
                        const SizedBox(width: 16),
                        if (_latestResult != null)
                          GradientButton(
                            onPressed: _exportResultsToCSV,
                            icon: Icons.insert_drive_file,
                            label: 'Export CSV',
                            colors: const [Colors.amber, Colors.deepOrange],
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Usage Tips
                  if (_latestResult == null && !_isProcessing) ...[
                    GlassCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: const [
                              Icon(Icons.lightbulb_outline, color: AppTheme.amberWarn, size: 18),
                              SizedBox(width: 8),
                              Text(
                                'Tips for Best Results',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.amberWarn,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '• Use backlit droplet images (silhouette against bright background)\n'
                            '• Ensure droplet is centered and touches clear surface\n'
                            '• Avoid glare and reflections on droplet surface\n'
                            '• Higher resolution images improve accuracy',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),

          // Loading Overlay
          if (_isProcessing)
            const LoadingOverlay(message: 'Analyzing droplet...'),
        ],
      ),
    );
  }
}
