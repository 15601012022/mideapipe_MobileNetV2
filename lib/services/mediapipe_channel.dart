import 'dart:typed_data';
import 'package:flutter/services.dart';

class MediaPipeResult {
  final bool faceDetected;
  final double ear;
  final double mar;
  final double pitch;
  final double yaw;
  final double roll;
  final bool eyeClosed;
  final bool yawning;
  final bool headNodding;
  final bool drowsyGeometric;
  final double boxLeft;
  final double boxTop;
  final double boxRight;
  final double boxBottom;


  const MediaPipeResult({
    required this.faceDetected,
    required this.ear,
    required this.mar,
    required this.pitch,
    required this.yaw,
    required this.roll,
    required this.eyeClosed,
    required this.yawning,
    required this.headNodding,
    required this.drowsyGeometric,
    this.boxLeft   = 0.0,
    this.boxTop    = 0.0,
    this.boxRight  = 0.0,
    this.boxBottom = 0.0,

  });

  factory MediaPipeResult.empty() => const MediaPipeResult(
    faceDetected: false, ear: 0, mar: 0,
    pitch: 0, yaw: 0, roll: 0,
    eyeClosed: false, yawning: false,
    headNodding: false, drowsyGeometric: false,
    boxLeft: 0, boxTop: 0, boxRight: 0, boxBottom: 0,
  );

  factory MediaPipeResult.fromMap(Map map) => MediaPipeResult(

    faceDetected:    map['faceDetected']    ?? false,
    ear:             (map['ear']            ?? 0.0).toDouble(),
    mar:             (map['mar']            ?? 0.0).toDouble(),
    pitch:           (map['pitch']          ?? 0.0).toDouble(),
    yaw:             (map['yaw']            ?? 0.0).toDouble(),
    roll:            (map['roll']           ?? 0.0).toDouble(),
    eyeClosed:       map['eyeClosed']       ?? false,
    yawning:         map['yawning']         ?? false,
    headNodding:     map['headNodding']     ?? false,
    drowsyGeometric: map['drowsyGeometric'] ?? false,
    boxLeft:         (map['boxLeft']        ?? 0.0).toDouble(),
    boxTop:          (map['boxTop']         ?? 0.0).toDouble(),
    boxRight:        (map['boxRight']       ?? 0.0).toDouble(),
    boxBottom:       (map['boxBottom']      ?? 0.0).toDouble(),
  );
}

class MediaPipeChannel {
  static const _channel = MethodChannel('mediapipe_channel');

  Future<MediaPipeResult> analyzeFrame(Uint8List jpegBytes) async {
    try {
      final result = await _channel.invokeMethod('analyzeFrame', {
        'imageBytes': jpegBytes,
      });
      return MediaPipeResult.fromMap(result as Map);
    } catch (e) {
      print('MediaPipe channel error: $e');
      return MediaPipeResult.empty();
    }
  }

  Future<bool> isInitialized() async {
    try {
      return await _channel.invokeMethod('isInitialized') ?? false;
    } catch (_) {
      return false;
    }
  }
}