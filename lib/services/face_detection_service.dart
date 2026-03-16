

import 'dart:typed_data';
import 'dart:math' as math;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'dart:io';

class FaceDetectionService {
  FaceDetector? _faceDetector;
  bool _isInitialized = false;

  // ── Thresholds (tuned for accuracy) ──────────────────────
  static const double EAR_THRESHOLD       = 0.25; //  closed eyes
  static const double EAR_OPEN_THRESHOLD  = 0.45; //
  static const double MAR_THRESHOLD       = 0.55; // yawn

  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    try {
      final options = FaceDetectorOptions(
        enableClassification: true,   // gives eye open probability
        enableLandmarks: true,        // gives face landmarks
        enableTracking: true,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.1,
      );
      _faceDetector = FaceDetector(options: options);
      _isInitialized = true;
      print('✅ ML Kit Face Detector initialized');
    } catch (e) {
      _isInitialized = false;
      print('❌ Face detector init error: $e');
    }
  }

  // ── Main detection method ─────────────────────────────────
  Future<Map<String, dynamic>> detectFromFile(String imagePath) async {
    if (!_isInitialized || _faceDetector == null) {
      return _defaultResult();
    }

    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final faces = await _faceDetector!.processImage(inputImage);

      if (faces.isEmpty) {
        return {
          ..._defaultResult(),
          'face_detected': false,
          'face_box': null,
        };
      }

      // Use the largest face (closest to camera)
      final face = faces.reduce((a, b) =>
      (a.boundingBox.width * a.boundingBox.height) >
          (b.boundingBox.width * b.boundingBox.height) ? a : b);

      // ── Eye open probability from ML Kit ─────────────────
      // leftEyeOpenProbability: 1.0 = fully open, 0.0 = closed
      final leftEyeProb  = face.leftEyeOpenProbability  ?? 1.0;
      final rightEyeProb = face.rightEyeOpenProbability ?? 1.0;
      final avgEyeProb   = (leftEyeProb + rightEyeProb) / 2.0;

      final earScore = avgEyeProb;

      // Convert to EAR-like score (inverted: low = closed)
      final eyesClosed = avgEyeProb < 0.40 ||
          math.min(leftEyeProb, rightEyeProb) < 0.30;

      // ── Mouth open detection from landmarks ──────────────
      double marScore  = 0.0;
      bool   yawning   = false;

      final upperLip = face.landmarks[FaceLandmarkType.bottomMouth];
      final lowerLip = face.landmarks[FaceLandmarkType.leftMouth];
      final leftMouth = face.landmarks[FaceLandmarkType.leftMouth];
      final rightMouth = face.landmarks[FaceLandmarkType.rightMouth];
      final noseBase = face.landmarks[FaceLandmarkType.noseBase];

      if (upperLip != null && lowerLip != null &&
          leftMouth != null && rightMouth != null) {
        final mouthHeight = (lowerLip.position.y - upperLip.position.y).abs();
        final mouthWidth  = (rightMouth.position.x - leftMouth.position.x).abs();
        marScore = mouthWidth > 0 ? mouthHeight / mouthWidth : 0.0;
        yawning  = marScore > MAR_THRESHOLD;
      }

      // ── Head pose ─────────────────────────────────────────
      final headTiltY = face.headEulerAngleY ?? 0.0; // left/right
      final headTiltX = face.headEulerAngleX ?? 0.0; // up/down (nodding)
      final isNodding = headTiltX.abs() > 20.0;
      // head drooping forward

      // ── Bounding box for red overlay ─────────────────────
      final box = face.boundingBox;

      // ── Combined drowsiness decision ──────────────────────
      final isDrowsy = eyesClosed || yawning || isNodding; // original, no oneEyeClosed


      print('👁️  EAR: ${earScore.toStringAsFixed(3)} '
          'closed=$eyesClosed | '
          'MAR: ${marScore.toStringAsFixed(3)} yawn=$yawning | '
          'Nod: ${headTiltX.toStringAsFixed(1)}° $isNodding');

      return {
        'face_detected':  true,
        'is_drowsy':      isDrowsy,
        'eye_closed':     eyesClosed,
        'yawn_detected':  yawning,
        'is_nodding':     isNodding,
        'ear_score':      earScore,
        'mar_score':      marScore,
        'head_tilt_x':    headTiltX,
        'head_tilt_y':    headTiltY,
        'left_eye_prob':  leftEyeProb,
        'right_eye_prob': rightEyeProb,
        // Bounding box for red overlay
        'face_box': {
          'left':   box.left,
          'top':    box.top,
          'right':  box.right,
          'bottom': box.bottom,
          'width':  box.width,
          'height': box.height,
        },
      };
    } catch (e) {
      print('Face detection error: $e');
      return _defaultResult();
    }
  }

  Map<String, dynamic> _defaultResult() => {
    'face_detected':  false,
    'is_drowsy':      false,
    'eye_closed':     false,
    'yawn_detected':  false,
    'is_nodding':     false,
    'ear_score':      1.0,
    'mar_score':      0.0,
    'head_tilt_x':    0.0,
    'head_tilt_y':    0.0,
    'left_eye_prob':  1.0,
    'right_eye_prob': 1.0,
    'face_box':       null,
  };

  void dispose() {
    _faceDetector?.close();
    _isInitialized = false;
  }
}
