

import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class MLModelService {
  Interpreter? _interpreter;
  bool _isLoaded = false;

  // ── Thresholds (tune these based on your test results) ──
  static const double DROWSY_THRESHOLD = 0.35; // score > this = drowsy
  static const double HIGH_CONFIDENCE  = 0.75; // very confident drowsy

  bool get isLoaded => _isLoaded;

  // ── Load model ────────────────────────────────────────────
  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        'assets/model/drowsiness_model_fp16.tflite',
        options: options,
      );
      _isLoaded = true;
      print('✅ MobileNetV2 drowsiness model loaded');
      print('   Input:  ${_interpreter!.getInputTensor(0).shape}');
      print('   Output: ${_interpreter!.getOutputTensor(0).shape}');
    } catch (e) {
      _isLoaded = false;
      print('❌ Model load error: $e');
      rethrow;
    }
  }

  // ── Preprocess image bytes → float tensor ─────────────────
  // Model expects: [1, 224, 224, 3] float32, normalized 0-1
  List<double> preprocessCameraFile(Uint8List imageBytes) {
    try {
      // Decode image
      img.Image? decoded = img.decodeImage(imageBytes);
      if (decoded == null) return List.filled(224 * 224 * 3, 0.0);

      // Resize to 224x224
      img.Image resized = img.copyResize(decoded, width: 224, height: 224);

      // Normalize to [0, 1]
      List<double> input = [];
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          final pixel = resized.getPixel(x, y);
          input.add(pixel.r / 255.0);
          input.add(pixel.g / 255.0);
          input.add(pixel.b / 255.0);
        }
      }
      return input;
    } catch (e) {
      print('Preprocessing error: $e');
      return List.filled(224 * 224 * 3, 0.0);
    }
  }

  // ── Run inference ─────────────────────────────────────────
  // Returns map with drowsiness score and flags
  Future<Map<String, dynamic>> runPrediction(List<double> inputTensor) async {
    if (!_isLoaded || _interpreter == null) {
      return _defaultResult();
    }

    try {
      // Input shape: [1, 224, 224, 3]
      var input = [
        List.generate(224, (y) =>
            List.generate(224, (x) =>
                List.generate(3, (c) =>
                inputTensor[(y * 224 + x) * 3 + c]
                )
            )
        )
      ];

      // Output shape: [1, 1] — single sigmoid score
      var output = List.filled(1, [0.0]);

      _interpreter!.run(input, output);

      double score = output[0][0];

      // Determine states
      bool isDrowsy    = score > DROWSY_THRESHOLD;
      bool isHighConf  = score > HIGH_CONFIDENCE;

      // Simulate separate eye/yawn signals from score range
      // (model predicts combined drowsiness — we infer likely cause)
      bool eyeClosed   = isDrowsy && score > 0.55;
      bool yawnDetected = isDrowsy && score > 0.65;

      print('🔍 Drowsiness score: ${score.toStringAsFixed(3)} → ${isDrowsy ? "DROWSY" : "ALERT"}');

      return {
        'drowsy_score':    score,
        'is_drowsy':       isDrowsy,
        'high_confidence': isHighConf,
        'eye_closed':      eyeClosed,
        'yawn_detected':   yawnDetected,
        // Legacy keys (keep for compatibility with your existing home_page.dart)
        'eye_confidence':  score,
        'yawn_confidence': score,
      };
    } catch (e) {
      print('Inference error: $e');
      return _defaultResult();
    }
  }

  Map<String, dynamic> _defaultResult() => {
    'drowsy_score':    0.0,
    'is_drowsy':       false,
    'high_confidence': false,
    'eye_closed':      false,
    'yawn_detected':   false,
    'eye_confidence':  0.0,
    'yawn_confidence': 0.0,
  };

  void dispose() {
    _interpreter?.close();
    _isLoaded = false;
  }
}
