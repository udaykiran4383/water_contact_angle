import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'image_processor.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Water Contact Angle Analyzer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
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
    setState(() {
      _isProcessing = true;
      _resultText = 'Processing image...';
      _latestResult = null;
    });

    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        File imageFile = File(pickedFile.path);

        setState(() {
          _image = null;
          _annotatedImage = null;
        });

        var result = await ImageProcessor.processImage(imageFile);

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
          (_latestResult![key] as bool?) ??
          ((_latestResult![key] as num?) == 1);
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
        escape(
            uncertainty.isFinite ? uncertainty.toStringAsExponential(3) : ''),
        escape(n('theta_circle').isFinite
            ? n('theta_circle').toStringAsFixed(6)
            : ''),
        escape(n('theta_ellipse').isFinite
            ? n('theta_ellipse').toStringAsFixed(6)
            : ''),
        escape(
            n('theta_poly').isFinite ? n('theta_poly').toStringAsFixed(6) : ''),
        escape(n('theta_young_laplace').isFinite
            ? n('theta_young_laplace').toStringAsFixed(6)
            : ''),
        escape(angleLeft.isFinite ? angleLeft.toStringAsFixed(6) : ''),
        escape(angleRight.isFinite ? angleRight.toStringAsFixed(6) : ''),
        escape(hysteresis.isFinite ? hysteresis.toStringAsFixed(6) : ''),
        escape(n('r_squared_circle').isFinite
            ? n('r_squared_circle').toStringAsFixed(6)
            : ''),
        escape(n('r_squared_ellipse').isFinite
            ? n('r_squared_ellipse').toStringAsFixed(6)
            : ''),
        escape(n('r_squared_young_laplace').isFinite
            ? n('r_squared_young_laplace').toStringAsFixed(6)
            : ''),
        escape(n('uncertainty_bootstrap').isFinite
            ? n('uncertainty_bootstrap').toStringAsFixed(6)
            : ''),
        escape(n('uncertainty_method').isFinite
            ? n('uncertainty_method').toStringAsFixed(6)
            : ''),
        escape(n('uncertainty_edge').isFinite
            ? n('uncertainty_edge').toStringAsFixed(6)
            : ''),
        escape(n('bond_number_fit').isFinite
            ? n('bond_number_fit').toStringAsExponential(6)
            : ''),
        escape(n('bond_number_physical').isFinite
            ? n('bond_number_physical').toStringAsExponential(6)
            : ''),
        escape(n('bond_number_physical_uncertainty').isFinite
            ? n('bond_number_physical_uncertainty').toStringAsExponential(6)
            : ''),
        escape(n('drop_radius_px').isFinite
            ? n('drop_radius_px').toStringAsFixed(6)
            : ''),
        escape(n('drop_radius_mm').isFinite
            ? n('drop_radius_mm').toStringAsFixed(6)
            : ''),
        escape(scaleCalibrated ? 'true' : 'false'),
        escape(n('scale_relative_uncertainty').isFinite
            ? n('scale_relative_uncertainty').toStringAsFixed(6)
            : ''),
        escape((_latestResult!['scale_source'] as String?) ?? ''),
        escape(n('pixel_size_um').isFinite
            ? n('pixel_size_um').toStringAsFixed(6)
            : ''),
        escape(n('meters_per_pixel').isFinite
            ? n('meters_per_pixel').toStringAsExponential(6)
            : ''),
        escape(surface),
        escape(contourCount.toString()),
        escape(
            n('baseline_y').isFinite ? n('baseline_y').toStringAsFixed(6) : ''),
        escape(n('baseline_tilt').isFinite
            ? n('baseline_tilt').toStringAsFixed(6)
            : ''),
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
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('Contact Angle Analyzer'),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Column(
                children: [
                  Icon(Icons.water_drop, size: 48, color: Colors.blue[700]),
                  const SizedBox(height: 8),
                  Text(
                    'Sessile Drop Analysis',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue[800],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Automated contact angle measurement for surface science',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.blue[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  // Show filename when available
                  if (_image != null)
                    Text(
                      'File: ${_image!.path.split('/').last}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Gallery'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[600],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing
                        ? null
                        : () => _pickImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Camera'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue[600],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Processing Status
            if (_isProcessing)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange[200]!),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.orange[700]!),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Analyzing droplet...\nThis may take 2-5 seconds',
                        style: TextStyle(color: Colors.orange[800]),
                      ),
                    ),
                  ],
                ),
              ),

            // Results Display
            if (!_isProcessing && _resultText != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Analysis Results',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[800],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _resultText!,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.4,
                        color: Colors.grey[700],
                      ),
                    ),

                    // Scientific display of angle
                    if (_latestResult != null &&
                        _latestResult!['angle_numeric'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12.0),
                        child: Text(
                          'Angle (scientific): ${((_latestResult!['angle_numeric'] as num).toDouble()).toStringAsExponential(3)}°',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[800]),
                        ),
                      ),

                    if (_latestResult != null &&
                        _latestResult!['bond_number_physical'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6.0),
                        child: Text(
                          'Bo (physical): ${((_latestResult!['bond_number_physical'] as num).toDouble()).toStringAsExponential(3)}'
                          ' | Radius: ${((_latestResult!['drop_radius_mm'] as num?)?.toDouble() ?? double.nan).isFinite ? ((_latestResult!['drop_radius_mm'] as num).toDouble()).toStringAsFixed(4) : 'N/A'} mm'
                          ' | Scale: ${((_latestResult!['pixel_size_um'] as num?)?.toDouble() ?? double.nan).isFinite ? ((_latestResult!['pixel_size_um'] as num).toDouble()).toStringAsFixed(3) : 'N/A'} um/px'
                          ' (${(_latestResult!['scale_source'] as String?) ?? 'fallback_approximate'})',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey[800],
                          ),
                        ),
                      ),

                    const SizedBox(height: 8),

                    // Export CSV button
                    if (_latestResult != null)
                      ElevatedButton.icon(
                        onPressed: _exportResultsToCSV,
                        icon: const Icon(Icons.file_download),
                        label: const Text('Export Results (CSV)'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal[600],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

            // Original Image
            if (_image != null && !_isProcessing)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),
                  Text(
                    'Original Image',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 250,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        _image!,
                        fit: BoxFit.contain,
                        width: double.infinity,
                      ),
                    ),
                  ),
                ],
              ),

            // Annotated Image + Save Button
            if (_annotatedImage != null && !_isProcessing)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),
                  Text(
                    'Annotated Analysis',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Green: Droplet boundary | Red: Baseline | Purple: Contact points & fit',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 250,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        _annotatedImage!,
                        fit: BoxFit.contain,
                        width: double.infinity,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _saveAnnotatedImage,
                          icon: const Icon(Icons.download),
                          label: const Text("Save Annotated Image"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.purple[600],
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Quick export CSV next to save
                      if (_latestResult != null)
                        SizedBox(
                          width: 160,
                          child: ElevatedButton.icon(
                            onPressed: _exportResultsToCSV,
                            icon: const Icon(Icons.insert_drive_file),
                            label: const Text('CSV'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.indigo[600],
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),

            // Usage Tips
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.amber[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '📸 Tips for Best Results',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.amber[800],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '• Use backlit droplet images (silhouette against bright background)\n'
                    '• Ensure droplet is centered and touches clear surface\n'
                    '• Avoid glare and reflections on droplet surface\n'
                    '• Higher resolution images improve accuracy\n'
                    '• Expected angles: 0-180° (0°=complete wetting, 180°=superhydrophobic)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.amber[700],
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
