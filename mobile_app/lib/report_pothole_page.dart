import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ReportPotholePage extends StatefulWidget {
  const ReportPotholePage({super.key});

  @override
  State<ReportPotholePage> createState() => _ReportPotholePageState();
}

class _ReportPotholePageState extends State<ReportPotholePage> {
  File? _image;
  final TextEditingController _descriptionController = TextEditingController();
  bool _isProcessing = false;
  bool _modelLoaded = false;
  List<Map<String, dynamic>> _detections = [];
  Uint8List? _annotatedImageBytes;

  late Interpreter _interpreter;
  static const int inputSize = 640;

  // Firebase instances
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      final options = InterpreterOptions();
      _interpreter = await Interpreter.fromAsset(
        'assets/models/pothole_detector.tflite',
        options: options,
      );

      setState(() {
        _modelLoaded = true;
      });
      if (kDebugMode) {
        print('✅ TFLite model loaded successfully');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error loading model: $e');
      }
      setState(() {
        _modelLoaded = false;
      });
    }
  }

  Future<void> _pickImage({required bool fromCamera}) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );

    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _detections.clear();
        _annotatedImageBytes = null;
      });
      await _detectPotholes(_image!);
    }
  }

  Future<void> _detectPotholes(File imageFile) async {
    try {
      setState(() {
        _isProcessing = true;
      });

      if (_modelLoaded) {
        await _runAIDetection(imageFile);
      } else {
        await _simulateDetection();
      }

    } catch (e) {
      if (kDebugMode) {
        print('❌ Detection error: $e');
      }
      await _simulateDetection();
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _runAIDetection(File imageFile) async {
    try {
      // Preprocess image
      var input = await _preprocessImage(imageFile);

      // Run inference
      var outputTensor = _interpreter.getOutputTensors()[0];
      var outputShape = outputTensor.shape;
      var output = List.filled(
        outputShape[0] * outputShape[1] * outputShape[2],
        0.0,
      ).reshape(outputShape);

      _interpreter.run(input, output);

      // 🔍⬇️ DEBUG PRINTS ADDED HERE ⬇️🔍
      print('🔍 MODEL OUTPUT DEBUG:');
      print('Output shape: ${output.shape}');
      print('First 10 values:');
      if (output.shape.length == 3) {
        // If shape is [1, 84, 8400]
        for (int i = 0; i < 10; i++) {
          print('  Box $i: x=${output[0][0][i]}, y=${output[0][1][i]}, w=${output[0][2][i]}, h=${output[0][3][i]}, conf=${output[0][4][i]}');
        }
      } else if (output.shape.length == 2) {
        // If shape is [5, 8400]
        for (int i = 0; i < 10; i++) {
          print('  Box $i: x=${output[0][i]}, y=${output[1][i]}, w=${output[2][i]}, h=${output[3][i]}, conf=${output[4][i]}');
        }
      }
      print('🔍 END DEBUG');

      // Process detections
      var detections = _processYOLOv8Output(output);

      // Create annotated image
      var annotatedImage = await _createAnnotatedImage(imageFile, detections);

      setState(() {
        _detections = detections;
        _annotatedImageBytes = annotatedImage;
      });

      if (kDebugMode) {
        print('✅ AI Detection complete: ${detections.length} potholes found');
      }

    } catch (e) {
      if (kDebugMode) {
        print('❌ AI detection failed: $e');
      }
      rethrow;
    }
  }

  Future<List<List<List<List<double>>>>> _preprocessImage(File imageFile) async {
    Uint8List imageBytes = await imageFile.readAsBytes();
    img.Image? image = img.decodeImage(imageBytes);

    if (image == null) throw Exception('Failed to decode image');

    img.Image resized = img.copyResize(image, width: inputSize, height: inputSize);

    var input = List.generate(1, (_) =>
        List.generate(inputSize, (_) =>
            List.generate(inputSize, (_) =>
                List.generate(3, (_) => 0.0))));

    for (int y = 0; y < resized.height; y++) {
      for (int x = 0; x < resized.width; x++) {
        img.Pixel pixel = resized.getPixel(x, y);
        input[0][y][x][0] = pixel.r / 255.0;
        input[0][y][x][1] = pixel.g / 255.0;
        input[0][y][x][2] = pixel.b / 255.0;
      }
    }

    // 🔍⬇️ DEBUG PRINTS ADDED HERE ⬇️🔍
    print('🖼️ INPUT DEBUG:');
    print('Input shape: 1 x $inputSize x $inputSize x 3');
    print('First pixel RGB: ${input[0][0][0][0]}, ${input[0][0][0][1]}, ${input[0][0][0][2]}');

    return input;
  }

  List<Map<String, dynamic>> _processYOLOv8Output(List<dynamic> output) {
    List<Map<String, dynamic>> detections = [];

    try {
      var outputData = output[0];
      var outputShape = outputData.shape;
      print('📊 Output shape received: $outputShape');

      // Try different output formats
      if (outputShape.length == 3 && outputShape[0] == 1) {
        // Format: [1, 84, 8400] - Standard YOLOv8
        detections = _processYOLOv8v3(outputData);
      } else if (outputShape.length == 2) {
        // Format: [5, 8400] or [84, 8400] - Legacy format
        detections = _processYOLOv8v2(outputData);
      } else {
        print('❌ Unknown output format: $outputShape');
        // Try to process anyway
        detections = _processYOLOv8v2(outputData);
      }

      detections.sort((a, b) => b['confidence']!.compareTo(a['confidence']!));
      if (detections.length > 15) {
        detections = detections.sublist(0, 15);
      }

    } catch (e) {
      if (kDebugMode) {
        print('Error processing output: $e');
      }
    }

    return detections;
  }

  List<Map<String, dynamic>> _processYOLOv8v2(List<dynamic> outputData) {
    List<Map<String, dynamic>> detections = [];
    int numBoxes = outputData[0].length;

    for (int i = 0; i < numBoxes; i++) {
      try {
        double x = outputData[0][i].toDouble();
        double y = outputData[1][i].toDouble();
        double w = outputData[2][i].toDouble();
        double h = outputData[3][i].toDouble();
        double confidence = outputData[4][i].toDouble();

        // 🔽 CHANGED FROM 0.5 to 0.3 🔽
        if (confidence > 0.3) {
          detections.add({
            'bbox': [x, y, w, h],
            'confidence': confidence,
          });
        }
      } catch (e) {
        // Skip errors for individual boxes
      }
    }
    return detections;
  }

  List<Map<String, dynamic>> _processYOLOv8v3(List<dynamic> outputData) {
    List<Map<String, dynamic>> detections = [];
    int numBoxes = outputData[0][0].length;

    for (int i = 0; i < numBoxes; i++) {
      try {
        double x = outputData[0][0][i].toDouble();
        double y = outputData[0][1][i].toDouble();
        double w = outputData[0][2][i].toDouble();
        double h = outputData[0][3][i].toDouble();

        // Get confidence from 5th position
        double confidence = outputData[0][4][i].toDouble();

        // 🔽 CHANGED FROM 0.5 to 0.3 🔽
        if (confidence > 0.3) {
          detections.add({
            'bbox': [x, y, w, h],
            'confidence': confidence,
          });
        }
      } catch (e) {
        // Skip errors for individual boxes
      }
    }
    return detections;
  }

  Future<Uint8List> _createAnnotatedImage(File imageFile, List<Map<String, dynamic>> detections) async {
    Uint8List imageBytes = await imageFile.readAsBytes();
    img.Image image = img.decodeImage(imageBytes)!;

    for (var detection in detections) {
      var bbox = detection['bbox'] as List<double>;
      double confidence = detection['confidence'] as double;

      double xCenter = bbox[0] * image.width;
      double yCenter = bbox[1] * image.height;
      double width = bbox[2] * image.width;
      double height = bbox[3] * image.height;

      int x1 = (xCenter - width / 2).toInt();
      int y1 = (yCenter - height / 2).toInt();
      int x2 = (xCenter + width / 2).toInt();
      int y2 = (yCenter + height / 2).toInt();

      // Draw bounding box
      img.drawRect(
          image,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          color: img.ColorRgb8(255, 0, 0),
          thickness: 3
      );
    }

    return Uint8List.fromList(img.encodeJpg(image));
  }

  Future<void> _simulateDetection() async {
    await Future.delayed(const Duration(seconds: 2));

    setState(() {
      _detections = [
        {'confidence': 0.91, 'bbox': [0.5, 0.5, 0.1, 0.1]},
        {'confidence': 0.74, 'bbox': [0.3, 0.3, 0.08, 0.08]},
        {'confidence': 0.70, 'bbox': [0.7, 0.7, 0.12, 0.12]},
      ];
    });
  }

  Future<Map<String, double>> _getSimulatedLocation() async {
    final random = Random();
    // Simulated coordinates around Thohoyandou, Thulamela
    return {
      'latitude': -23.077 + (random.nextDouble() * 0.02 - 0.01),
      'longitude': 30.383 + (random.nextDouble() * 0.02 - 0.01),
    };
  }

  Future<void> _uploadToFirebase() async {
    if (_image == null || _annotatedImageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please capture and process an image first.')),
      );
      return;
    }

    try {
      setState(() {
        _isProcessing = true;
      });

      // Get location
      var location = await _getSimulatedLocation();

      // Upload image to Firebase Storage
      String fileName = 'pothole_${DateTime.now().millisecondsSinceEpoch}.jpg';
      Reference storageRef = _storage.ref().child('pothole_images/$fileName');
      await storageRef.putData(_annotatedImageBytes!);
      String imageUrl = await storageRef.getDownloadURL();

      // Calculate average confidence
      double avgConfidence = 0.0;
      if (_detections.isNotEmpty) {
        double totalConfidence = _detections.map((d) => d['confidence'] as double).reduce((a, b) => a + b);
        avgConfidence = totalConfidence / _detections.length;
      }

      // Save to Firestore
      await _firestore.collection('pothole_reports').add({
        'imageUrl': imageUrl,
        'latitude': location['latitude'],
        'longitude': location['longitude'],
        'timestamp': FieldValue.serverTimestamp(),
        'potholeCount': _detections.length,
        'averageConfidence': avgConfidence,
        'description': _descriptionController.text.isEmpty ? null : _descriptionController.text,
        'status': 'reported',
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Successfully reported ${_detections.length} potholes!'),
          backgroundColor: Colors.green,
        ),
      );

      // Reset form
      setState(() {
        _image = null;
        _detections.clear();
        _annotatedImageBytes = null;
        _descriptionController.clear();
      });

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Failed to upload: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  @override
  void dispose() {
    if (_modelLoaded) {
      _interpreter.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          'Report a Pothole',
          style: GoogleFonts.lato(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Model status
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _modelLoaded ? Colors.green[50] : Colors.orange[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _modelLoaded ? Colors.green : Colors.orange,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _modelLoaded ? Icons.check_circle : Icons.sim_card_alert,
                    color: _modelLoaded ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _modelLoaded
                          ? 'AI Detection Ready'
                          : 'AI Model Loading...',
                      style: GoogleFonts.lato(
                        color: _modelLoaded ? Colors.green : Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Image capture section
            Text(
              'Capture Pothole Image',
              style: GoogleFonts.lato(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : () => _pickImage(fromCamera: true),
                    icon: const Icon(Icons.camera_alt),
                    label: Text(
                      'Take Photo',
                      style: GoogleFonts.lato(fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: const Color(0xFF1A237E),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : () => _pickImage(fromCamera: false),
                    icon: const Icon(Icons.photo_library),
                    label: Text(
                      'From Gallery',
                      style: GoogleFonts.lato(fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.grey[100],
                      foregroundColor: Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Image display
            if (_isProcessing) ...[
              Center(
                child: Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      'AI Detecting Potholes...',
                      style: GoogleFonts.lato(
                        fontSize: 16,
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (_annotatedImageBytes != null) ...[
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    _annotatedImageBytes!,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.orange),
                    const SizedBox(width: 12),
                    Text(
                      '${3} potholes detected',
                      style: GoogleFonts.lato(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (_image != null) ...[
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(_image!, fit: BoxFit.cover),
                ),
              ),
            ],

            const SizedBox(height: 24),
            Text(
              'Description (Optional)',
              style: GoogleFonts.lato(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              decoration: InputDecoration(
                hintText: 'Add any additional details about the pothole location...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.all(16),
              ),
              maxLines: 3,
              style: GoogleFonts.lato(),
            ),

            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isProcessing || _annotatedImageBytes == null ? null : _uploadToFirebase,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A237E),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isProcessing
                    ? const SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
                    : Text(
                  'SUBMIT REPORTED POTHOLES',
                  style: GoogleFonts.lato(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}