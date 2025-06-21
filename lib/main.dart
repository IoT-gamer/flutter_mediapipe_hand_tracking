import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:jni/jni.dart';
import 'hand_landmarker_bindings.dart';

late List<CameraDescription> _cameras;
late MyHandLandmarker _landmarker;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  final int _skipFrames = 3; // Process every 3rd frame

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  void _initializeCamera() {
    // Note: To test the other camera, change this to CameraLensDirection.back
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
    if (_frameCounter % _skipFrames != 0) {
      return; // Process every _skipFrames number of frames to reduce load
    }
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final yPlane = image.planes[0].bytes;
      final uPlane = image.planes[1].bytes;
      final vPlane = image.planes[2].bytes;

      final int yRowStride = image.planes[0].bytesPerRow;
      final int uvRowStride = image.planes[1].bytesPerRow;
      final int uvPixelStride = image.planes[1].bytesPerPixel!;
      final int width = image.width;
      final int height = image.height;

      // print('Image size width: $width, height: $height');

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
          rgbaBytes[writeIndex++] = 255;
        }
      }

      final byteBuffer = JByteBuffer.fromList(rgbaBytes);
      final rotation = _controller!.description.sensorOrientation;

      final resultJString = _landmarker.detect(
        byteBuffer,
        width,
        height,
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
    } finally {
      _isProcessing = false;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    // Get the size of the camera preview in logical pixels
    final previewSize = controller.value.previewSize!;

    return Scaffold(
      appBar: AppBar(title: const Text('Live Hand Tracking')),
      body: Stack(
        // Use a Stack to overlay the preview and the painter
        children: [
          // 1. The camera preview will fill the screen, potentially being cropped
          Positioned.fill(child: CameraPreview(controller)),

          // 2. The FittedBox will scale our painter to fit correctly over the preview
          FittedBox(
            // BoxFit.contain ensures the aspect ratio is preserved
            fit: BoxFit.contain,
            child: SizedBox(
              // Create a SizedBox with the camera's resolution.
              // IMPORTANT: Swap width and height because the camera's
              // native orientation is landscape, but the preview is portrait.
              width: previewSize.height,
              height: previewSize.width,
              child: CustomPaint(
                // The painter now draws on a canvas that has the exact same
                // size and aspect ratio as the camera image.
                painter: LandmarkPainter(
                  hands: _landmarks,
                  lensDirection: controller.description.lensDirection,
                  sensorOrientation: controller.description.sensorOrientation,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LandmarkPainter extends CustomPainter {
  LandmarkPainter({
    required this.hands,
    required this.lensDirection,
    required this.sensorOrientation,
  });

  final List<List<Map<String, double>>> hands;
  final CameraLensDirection lensDirection;
  final int sensorOrientation;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    final linePaint = Paint()
      ..color = Colors.lightBlueAccent
      ..strokeWidth = 4;

    canvas.save();

    final center = Offset(size.width / 2, size.height / 2);
    final rotationAngle = sensorOrientation * math.pi / 180;

    canvas.translate(center.dx, center.dy);

    // // Apply the base rotation for all cameras
    canvas.rotate(rotationAngle);

    // For the front camera, we need to apply special transformations
    if (lensDirection == CameraLensDirection.front) {
      // Flip horizontally
      canvas.scale(-1, 1);
      // Apply an additional 180-degree rotation to correct the orientation
      canvas.rotate(math.pi);
    }

    canvas.translate(-center.dy, -center.dx);
    // print('Canvas size width: ${size.width}, height: ${size.height}');

    // Drawing logic
    for (var hand in hands) {
      for (var landmark in hand) {
        canvas.drawCircle(
          Offset(landmark['x']! * size.height, landmark['y']! * size.width),
          8,
          paint,
        );
      }
      for (var connection in HandLandmarkConnections.connections) {
        final start = hand[connection[0]];
        final end = hand[connection[1]];
        canvas.drawLine(
          Offset(start['x']! * size.height, start['y']! * size.width),
          Offset(end['x']! * size.height, end['y']! * size.width),
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
