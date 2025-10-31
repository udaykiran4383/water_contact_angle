import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../image_processor.dart';
import '../widgets/custom_widgets.dart';
import '../utils/app_colors.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  File? _image;
  String? _resultText;
  File? _annotatedImage;
  bool _isProcessing = false;
  final ImagePicker _picker = ImagePicker();
  Map<String, dynamic>? _latestResult;

  Future<void> _pickImage(ImageSource source) async {
    setState(() {
      _isProcessing = true;
      _resultText = null;
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

        // Process the image file directly
        var result = await ImageProcessor.processImage(imageFile);

        setState(() {
          _image = imageFile;
          _resultText = result['text'];
          _annotatedImage = result['annotated'];
          _latestResult = result;
        });
      }
    } catch (e) {
      print('Error picking image: $e');
      setState(() {
        _resultText = 'Error: $e\n\nPlease check permissions and try again.';
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _saveAnnotatedImage() async {
    if (_annotatedImage == null) return;

    try {
      final bytes = await _annotatedImage!.readAsBytes();
      final result = await ImageGallerySaverPlus.saveImage(
        Uint8List.fromList(bytes),
        quality: 100,
        name: "contact_angle_result_${DateTime.now().millisecondsSinceEpoch}",
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['isSuccess'] == true
              ? "✅ Annotated image saved to gallery!"
              : "❌ Failed to save image."),
          backgroundColor: result['isSuccess'] == true
              ? AppColors.success
              : AppColors.error,
        ),
      );
    } catch (e) {
      print("Error saving image: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Error saving image: $e"),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _exportResultsToCSV() async {
    if (_latestResult == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No results to export.')),
      );
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final filename =
          'contact_angle_results_${DateTime.now().millisecondsSinceEpoch}.csv';
      final filePath = '${dir.path}/$filename';

      final headers = [
        'timestamp',
        'source_file',
        'angle_deg',
        'angle_scientific',
        'uncertainty_deg',
        'uncertainty_scientific',
        'circle_deg',
        'poly_deg',
        'surface_type',
        'contour_points',
        'baseline_y',
        'annotated_path'
      ];

      String escape(String v) => '"' + v.replaceAll('"', '""') + '"';

      String timestamp = DateTime.now().toIso8601String();
      String sourceFile =
          _latestResult!['filename'] ?? (_image?.path.split('/').last ?? '');

      double angle =
          (_latestResult!['angle_numeric'] as num?)?.toDouble() ?? double.nan;
      double unc = (_latestResult!['uncertainty_numeric'] as num?)?.toDouble() ??
          double.nan;
      double circ =
          (_latestResult!['theta_circle'] as num?)?.toDouble() ?? double.nan;
      double poly =
          (_latestResult!['theta_poly'] as num?)?.toDouble() ?? double.nan;
      String surface = _latestResult!['surface_type'] ?? '';
      int contourCount = _latestResult!['contour_count'] ?? 0;
      double baselineY =
          (_latestResult!['baseline_y'] as num?)?.toDouble() ?? double.nan;
      String annotatedPath = _latestResult!['annotated_path'] ?? '';

      final headerLine = headers.map(escape).join(',');
      final row = [
        escape(timestamp),
        escape(sourceFile),
        escape(angle.isFinite ? angle.toStringAsFixed(6) : ''),
        escape(angle.isFinite ? angle.toStringAsExponential(3) : ''),
        escape(unc.isFinite ? unc.toStringAsFixed(6) : ''),
        escape(unc.isFinite ? unc.toStringAsExponential(3) : ''),
        escape(circ.isFinite ? circ.toStringAsFixed(6) : ''),
        escape(poly.isFinite ? poly.toStringAsFixed(6) : ''),
        escape(surface),
        escape(contourCount.toString()),
        escape(baselineY.isFinite ? baselineY.toStringAsFixed(2) : ''),
        escape(annotatedPath),
      ].join(',');

      final csv = '$headerLine\n$row\n';
      final file = File(filePath);
      await file.writeAsString(csv);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ CSV exported to: $filePath'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      print('Error exporting CSV: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Failed to export CSV: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    double angle =
        (_latestResult?['angle_numeric'] as num?)?.toDouble() ?? double.nan;
    double uncertainty = (_latestResult?['uncertainty_numeric'] as num?)
            ?.toDouble() ??
        double.nan;

    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: const InstitutionHeader(),
        toolbarHeight: 90,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GradientHeader(
                      title: 'Sessile Drop Analysis',
                      subtitle:
                          'Automated contact angle measurement for surface science',
                      icon: Icons.water_drop,
                      fileName: _image?.path.split('/').last,
                    ),
                    const SizedBox(height: 24),
                    ActionButtonRow(
                      onGallery: () => _pickImage(ImageSource.gallery),
                      onCamera: () => _pickImage(ImageSource.camera),
                      isLoading: _isProcessing,
                    ),
                    const SizedBox(height: 24),
                    if (_isProcessing) const ProcessingIndicator(),
                    if (!_isProcessing && _resultText != null)
                      ResultsCard(
                        resultText: _resultText!,
                        angle: angle,
                        uncertainty: uncertainty,
                        onExport: _exportResultsToCSV,
                        latestResult: _latestResult,
                      ),
                    if (_image != null && !_isProcessing)
                      ImageDisplayCard(
                        title: 'Original Image',
                        imageFile: _image!,
                      ),
                    if (_annotatedImage != null && !_isProcessing)
                      AnnotatedImageSection(
                        annotatedImage: _annotatedImage!,
                        onSave: _saveAnnotatedImage,
                      ),
                    const SizedBox(height: 24),
                    const TipsSection(),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
          const DeveloperFooter(),
        ],
      ),
    );
  }
}
