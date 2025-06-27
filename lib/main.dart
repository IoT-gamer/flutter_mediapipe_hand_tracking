import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:integral_isolates/integral_isolates.dart';
import 'package:jni/jni.dart';

import 'hand_landmarker_bindings.dart';

late List<CameraDescription> _cameras;
late MyHandLandmarker _landmarker;

// This data class is used to pass all necessary info to the background isolate.
class IsolateData {
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final int width;
  final int height;

  IsolateData(CameraImage image)
    : yPlane = image.planes[0].bytes,
      uPlane = image.planes[1].bytes,
      vPlane = image.planes[2].bytes,
      yRowStride = image.planes[0].bytesPerRow,
      uvRowStride = image.planes[1].bytesPerRow,
      uvPixelStride = image.planes[1].bytesPerPixel!,
      height = image.height,
      width = image.width;
}

/// This is the function that will run on the background isolate.
/// It performs the heavy YUV to RGBA conversion.
Uint8List convertYUVtoRGBA(IsolateData isolateData) {
  final int width = isolateData.width;
  final int height = isolateData.height;
  final int yRowStride = isolateData.yRowStride;
  final int uvRowStride = isolateData.uvRowStride;
  final int uvPixelStride = isolateData.uvPixelStride;

  final yPlane = isolateData.yPlane;
  final uPlane = isolateData.uPlane;
  final vPlane = isolateData.vPlane;

  final rgbaBytes = Uint8List(width * height * 4);
  int writeIndex = 0;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int uvIndex =
          uvPixelStride * (x / 2).floor() + uvRowStride * (y / 2).floor();
      final int index = y * yRowStride + x;

      final yp = yPlane[index];
      final up = uPlane[uvIndex];
      final vp = vPlane[uvIndex];

      int r = (yp + 1.402 * (vp - 128)).round();
      int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).round();
      int blue = (yp + 1.772 * (up - 128)).round();

      rgbaBytes[writeIndex++] = r.clamp(0, 255);
      rgbaBytes[writeIndex++] = g.clamp(0, 255);
      rgbaBytes[writeIndex++] = blue.clamp(0, 255);
      rgbaBytes[writeIndex++] = 255; // Alpha value (fully opaque)
    }
  }
  return rgbaBytes;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  _cameras = await availableCameras();

  final contextRef = Jni.getCachedApplicationContext();
  final contextObj = JObject.fromReference(contextRef);
  _landmarker = MyHandLandmarker(contextObj);
  contextObj.release();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Flutter Hand Tracker',
      home: HandTrackerView(),
    );
  }
}

class HandTrackerView extends StatefulWidget {
  const HandTrackerView({super.key});

  @override
  State<HandTrackerView> createState() => _HandTrackerViewState();
}

class _HandTrackerViewState extends State<HandTrackerView> {
  CameraController? _controller;
  List<List<Map<String, double>>> _landmarks = [];
  bool _isProcessing = false;
  int _frameCounter = 0;
  // Process one frame every `frameProcessingInterval` frames.
  final int frameProcessingInterval = 1; //

  // The stateful isolate that will handle our background processing
  final _isolate = StatefulIsolate(
    backpressureStrategy: ReplaceBackpressureStrategy(),
  );

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  void _initializeCamera() {
    final camera = _cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    _controller!.initialize().then((_) {
      if (!mounted) return;
      _controller!.startImageStream(_processCameraImage);
      setState(() {});
    });
  }

  void _processCameraImage(CameraImage image) {
    _frameCounter++;
    if (_frameCounter % frameProcessingInterval != 0) {
      return; // Skip this frame to reduce load
    }
    if (_isProcessing) return;
    _isProcessing = true;
    // The integral_isolates package has built-in backpressure handling.

    // Run the conversion on the background isolate
    _isolate.compute(convertYUVtoRGBA, IsolateData(image)).then((rgbaBytes) {
      // This code runs on the main thread when the conversion is complete
      final byteBuffer = JByteBuffer.fromList(rgbaBytes);
      final rotation = _controller!.description.sensorOrientation;

      final resultJString = _landmarker.detect(
        byteBuffer,
        image.width,
        image.height,
        rotation,
      );

      final resultString = resultJString.toDartString();
      final parsedResult = jsonDecode(resultString) as List<dynamic>;

      if (mounted) {
        setState(() {
          _landmarks = parsedResult.map((hand) {
            return (hand as List<dynamic>).map((landmark) {
              return Map<String, double>.from(landmark);
            }).toList();
          }).toList();
        });
      }

      resultJString.release();
      byteBuffer.release();
      _isProcessing = false;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _isolate.dispose(); // Always dispose the isolate
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final previewSize = controller.value.previewSize!;
    final previewAspectRatio = previewSize.height / previewSize.width;

    return Scaffold(
      appBar: AppBar(title: const Text('Live Hand Tracking')),
      body: Center(
        child: AspectRatio(
          aspectRatio: previewAspectRatio,
          child: Stack(
            children: [
              CameraPreview(controller),
              CustomPaint(
                // Tell the painter to fill the available space
                size: Size.infinite,
                painter: LandmarkPainter(
                  hands: _landmarks,
                  // Pass the camera's resolution explicitly
                  previewSize: previewSize,
                  lensDirection: controller.description.lensDirection,
                  sensorOrientation: controller.description.sensorOrientation,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LandmarkPainter extends CustomPainter {
  LandmarkPainter({
    required this.hands,
    required this.previewSize,
    required this.lensDirection,
    required this.sensorOrientation,
  });

  final List<List<Map<String, double>>> hands;
  final Size previewSize;
  final CameraLensDirection lensDirection;
  final int sensorOrientation;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / previewSize.height;

    final paint = Paint()
      ..color = Colors.red
      ..strokeWidth = 8 / scale
      ..strokeCap = StrokeCap.round;

    final linePaint = Paint()
      ..color = Colors.lightBlueAccent
      ..strokeWidth = 4 / scale;

    canvas.save();

    final center = Offset(size.width / 2, size.height / 2);
    canvas.translate(center.dx, center.dy);
    canvas.rotate(sensorOrientation * math.pi / 180);

    if (lensDirection == CameraLensDirection.front) {
      canvas.scale(-1, 1);
      canvas.rotate(math.pi);
    }

    canvas.scale(scale);

    // Correctly assign logicalWidth to the sensor's width and logicalHeight to the sensor's height.
    final logicalWidth = previewSize.width;
    final logicalHeight = previewSize.height;

    for (final hand in hands) {
      for (final landmark in hand) {
        // Now dx is scaled by width, and dy is scaled by height.
        final dx = (landmark['x']! - 0.5) * logicalWidth;
        final dy = (landmark['y']! - 0.5) * logicalHeight;
        canvas.drawCircle(Offset(dx, dy), 8 / scale, paint);
      }
      for (final connection in HandLandmarkConnections.connections) {
        final start = hand[connection[0]];
        final end = hand[connection[1]];
        final startDx = (start['x']! - 0.5) * logicalWidth;
        final startDy = (start['y']! - 0.5) * logicalHeight;
        final endDx = (end['x']! - 0.5) * logicalWidth;
        final endDy = (end['y']! - 0.5) * logicalHeight;
        canvas.drawLine(
          Offset(startDx, startDy),
          Offset(endDx, endDy),
          linePaint,
        );
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// Helper class
class HandLandmarkConnections {
  static const List<List<int>> connections = [
    [0, 1], [1, 2], [2, 3], [3, 4], // Thumb
    [0, 5], [5, 6], [6, 7], [7, 8], // Index finger
    [5, 9], [9, 10], [10, 11], [11, 12], // Middle finger
    [9, 13], [13, 14], [14, 15], [15, 16], // Ring finger
    [13, 17], [0, 17], [17, 18], [18, 19], [19, 20], // Pinky
  ];
}
