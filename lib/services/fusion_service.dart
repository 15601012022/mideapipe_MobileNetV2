class FusionResult {
  final bool isDrowsy;
  final String reason;
  final double deepScore;
  final bool earFlag;
  final bool marFlag;
  final bool headFlag;
  final bool modelFlag;

  const FusionResult({
    required this.isDrowsy,
    required this.reason,
    required this.deepScore,
    required this.earFlag,
    required this.marFlag,
    required this.headFlag,
    required this.modelFlag,
  });
}

class FusionService {
  // ── Thresholds calibrated from YOUR actual log data ───────
  // Your alert EAR range: 0.29–0.42 (normal eyes open)
  // Your drowsy EAR range: 0.018–0.22 (eyes closing)
  // Safe threshold: 0.24 — well below normal, catches real drowsiness
  static const double _earThreshold         = 0.24;
  static const double _marThreshold         = 0.65;
  static const double _pitchThreshold       = -12.0;
  static const double _modelFaceThreshold   = 0.50;
  static const double _modelNoFaceThreshold = 0.70;

  // 2 consecutive frames = ~3 seconds at 1500ms capture rate
  static const int _earFramesRequired = 2;
  static const int _scoreWindowSize   = 3;

  int _consecutiveEyeClosedFrames = 0;
  int _consecutiveMarFrames       = 0;
  final List<double> _scoreWindow = [];

  FusionResult evaluate({
    required double ear,
    required double mar,
    required double pitch,
    required bool   faceDetected,
    required double deepScore,
  }) {
    // Rolling model score
    _scoreWindow.add(deepScore);
    if (_scoreWindow.length > _scoreWindowSize) _scoreWindow.removeAt(0);
    final avgScore = _scoreWindow.reduce((a, b) => a + b) / _scoreWindow.length;

    // No face = eyes completely shut, trust model if confident
    if (!faceDetected) {
      final modelFired = avgScore > _modelNoFaceThreshold;
      return FusionResult(
        isDrowsy:  modelFired,
        reason:    modelFired ? 'FaceLost+Model(${avgScore.toStringAsFixed(3)})' : 'NoFace',
        deepScore: avgScore,
        earFlag: false, marFlag: false, headFlag: false, modelFlag: modelFired,
      );
    }

    // Hard floor: EAR this low = eyes definitely shut
    if (ear < 0.10) {
      _consecutiveEyeClosedFrames++;
      return FusionResult(
        isDrowsy: true,
        reason: 'HardEAR(${ear.toStringAsFixed(3)})',
        deepScore: avgScore,
        earFlag: true, marFlag: false, headFlag: false, modelFlag: false,
      );
    }

    // EAR consecutive frame counter
    if (ear < _earThreshold) {
      _consecutiveEyeClosedFrames++;
    } else {
      _consecutiveEyeClosedFrames = 0;
    }
    final earFlag = _consecutiveEyeClosedFrames >= _earFramesRequired;

    // MAR: only counts when EAR is also low
    if (mar > _marThreshold) {
      _consecutiveMarFrames++;
    } else {
      _consecutiveMarFrames = 0;
    }
    final marFlag = _consecutiveMarFrames >= 2 && earFlag;

    // Head: forward drop only
    final headFlag  = pitch < _pitchThreshold;
    final modelFlag = avgScore > _modelFaceThreshold;

    // EAR is primary gatekeeper
    final isDrowsy = earFlag
        || (modelFlag && _consecutiveEyeClosedFrames >= 1)
        || (headFlag  && _consecutiveEyeClosedFrames >= 1)
        || (modelFlag && headFlag);

    final reasons = <String>[];
    if (earFlag)   reasons.add('EAR(${_consecutiveEyeClosedFrames}f)');
    if (marFlag)   reasons.add('MAR+EAR');
    if (headFlag)  reasons.add('Pitch(${pitch.toStringAsFixed(1)})');
    if (modelFlag) reasons.add('Model(${avgScore.toStringAsFixed(3)})');

    return FusionResult(
      isDrowsy:  isDrowsy,
      reason:    isDrowsy ? reasons.join('+') : 'Alert',
      deepScore: avgScore,
      earFlag:   earFlag,
      marFlag:   marFlag,
      headFlag:  headFlag,
      modelFlag: modelFlag,
    );
  }

  void reset() {
    _consecutiveEyeClosedFrames = 0;
    _consecutiveMarFrames       = 0;
    _scoreWindow.clear();
  }
}