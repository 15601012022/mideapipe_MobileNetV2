import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ml_model_service.dart';
import 'services/watch_service.dart';
import 'services/face_detection_service.dart';
import 'watch_screen.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';


class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {

  // ── Alert state ───────────────────────────────────────────
  Timer? _vibrationTimer;
  Timer? _alertDelayTimer;
  Timer? _deepSleepTimer;
  Timer? _deepSleepSmsTimer;
  Timer? _drowsyWallClockTimer;   // WALL CLOCK timer — not frame-based
  bool  _isAlertDialogOpen = false;
  bool  _isAlertPending    = false;
  bool  _isDeepSleepMode   = false;
  bool  _isInferenceRunning = false; // GUARD: prevent overlapping inference
  int   _consecutiveDrowsyFrames = 0;
  int   _continuousDrowsySeconds = 0;
  int   _alertToleranceFrames    = 0;
  int   _warmupFrames            = 0;

  // ── Services ──────────────────────────────────────────────
  final MLModelService        _mlModelService       = MLModelService();
  final FaceDetectionService  _faceDetectionService = FaceDetectionService();
  final WatchService          _watchService         = WatchService();
  final AudioPlayer           _audioPlayer          = AudioPlayer();
  final FirebaseAuth          _auth                 = FirebaseAuth.instance;
  final FirebaseFirestore     _firestore            = FirebaseFirestore.instance;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
  FlutterLocalNotificationsPlugin();

  // ── Camera ────────────────────────────────────────────────
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _isModelLoaded       = false;
  bool _isModelLoading      = true;

  // ── Monitoring state ──────────────────────────────────────

  bool   _isMonitoring     = false;
  int    _detectionCount   = 0;
  String _currentStatus    = 'Initializing...';
  String _drowsinessStatus = 'Normal';
  Timer? _captureTimer;

  // ── Face box overlay ──────────────────────────────────────
  Map<String, double>? _faceBox;
  bool _isFaceDrowsy = false;

  // ── Settings ──────────────────────────────────────────────
  bool _soundAlert         = true;
  bool _vibrationAlert     = true;
  bool _smsAlert           = false;
  int  _drowsinessThreshold = 3;

  // ── Bluetooth ─────────────────────────────────────────────
  bool _isBluetoothCameraConnected = false;
  String _bluetoothStatus = 'Disconnected';
  List<BluetoothDevice> devicesList = [];
  BluetoothDevice? connectedDevice;

  StreamSubscription<String>? _watchCommandSub;

  static const Color kGreen  = Color(0xFF78C841);
  static const Color kRed    = Color(0xFFE53935);
  static const Color kOrange = Color(0xFFFFA726);

  // ══════════════════════════════════════════════════════════
  // INIT
  // ══════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await Future.wait([_initializeCamera(), _loadModel()]);
    await _loadUserSettings();
    await _initWatch();
    await _initNotifications();
    await _faceDetectionService.initialize();
  }

  @override
  void dispose() {
    _watchCommandSub?.cancel();
    _cameraController?.dispose();
    _captureTimer?.cancel();
    _alertDelayTimer?.cancel();
    _deepSleepTimer?.cancel();
    _deepSleepSmsTimer?.cancel();
    _drowsyWallClockTimer?.cancel();
    _vibrationTimer?.cancel();
    _audioPlayer.dispose();
    _faceDetectionService.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════
  // NOTIFICATIONS + WATCH
  // ══════════════════════════════════════════════════════════

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings androidSettings =
    AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notificationsPlugin.initialize(
        const InitializationSettings(android: androidSettings));
    await Permission.notification.request();
  }

  Future<void> _sendWatchNotification({bool isDeepSleep = false}) async {
    final androidDetails = AndroidNotificationDetails(
      'drowsiness_channel', 'Drowsiness Alerts',
      channelDescription: 'Driver drowsiness detection alerts',
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: true,
      visibility: NotificationVisibility.public,
      fullScreenIntent: true,
    );
    await _notificationsPlugin.show(
      isDeepSleep ? 1 : 0,
      isDeepSleep ? '🚨 DEEP SLEEP ALERT!' : '⚠️ Drowsiness Detected!',
      isDeepSleep
          ? 'Driver asleep for 30+ seconds! TAKE OVER NOW!'
          : 'Detection #$_detectionCount — Please take a break!',
      NotificationDetails(android: androidDetails),
    );
  }

  Future<void> _initWatch() async {
    await _watchService.initialize();
    _watchCommandSub = _watchService.watchCommands.listen((command) {
      if (command == 'START' && !_isMonitoring) _startMonitoring();
      if (command == 'STOP'  && _isMonitoring)  _stopMonitoring();
    });
  }

  // ══════════════════════════════════════════════════════════
  // MODEL
  // ══════════════════════════════════════════════════════════

  Future<void> _loadModel() async {
    try {
      setState(() { _currentStatus = 'Loading AI model...'; _isModelLoading = true; });
      await _mlModelService.loadModel().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Model loading timed out'),
      );
      if (mounted) setState(() {
        _isModelLoaded  = true;
        _isModelLoading = false;
        _currentStatus  = _isCameraInitialized ? 'Ready to start' : 'Waiting for camera...';
      });
    } catch (e) {
      if (mounted) setState(() {
        _isModelLoaded  = true;
        _isModelLoading = false;
        _currentStatus  = _isCameraInitialized ? 'Ready to start' : 'Waiting for camera...';
      });
    }
  }

  // ══════════════════════════════════════════════════════════
  // CAMERA
  // ══════════════════════════════════════════════════════════

  Future<void> _initializeCamera() async {
    try {
      setState(() => _currentStatus = 'Requesting camera permission...');
      if (!await Permission.camera.request().isGranted) {
        setState(() => _currentStatus = 'Camera permission denied');
        return;
      }
      setState(() => _currentStatus = 'Initializing camera...');
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() => _currentStatus = 'No camera found');
        return;
      }
      final frontCamera = _cameras!.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras!.first,
      );
      _cameraController = CameraController(
        frontCamera, ResolutionPreset.medium,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() {
        _isCameraInitialized = true;
        _currentStatus = _isModelLoaded ? 'Ready to start' : 'Loading AI model...';
      });
    } catch (e) {
      if (mounted) setState(() => _currentStatus = 'Camera error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════
  // DETECTION — SEQUENTIAL (FIX FOR SPEED)
  // ══════════════════════════════════════════════════════════

  Future<void> _captureAndRunInference() async {
    // GUARD: skip if previous inference still running
    if (_isInferenceRunning || !_isCameraInitialized) return;
    _isInferenceRunning = true;

    try {
      final XFile image = await _cameraController!.takePicture();

      // ── STEP 1: MediaPipe face detection (fast, ~100ms) ──
      final faceResult = await _faceDetectionService.detectFromFile(image.path);

      // Update face box immediately after MediaPipe
      final rawBox = faceResult['face_box'];
      if (mounted) {
        setState(() {
          _faceBox = rawBox == null ? null : {
            'left':   (rawBox['left']   as num).toDouble(),
            'top':    (rawBox['top']    as num).toDouble(),
            'right':  (rawBox['right']  as num).toDouble(),
            'bottom': (rawBox['bottom'] as num).toDouble(),
            'width':  (rawBox['width']  as num).toDouble(),
            'height': (rawBox['height'] as num).toDouble(),
          };
        });
      }

      final mlkitDrowsy = faceResult['is_drowsy'] as bool;
      final eyeClosed   = faceResult['eye_closed'] as bool;
      final yawning     = faceResult['yawn_detected'] as bool;
      final nodding     = faceResult['is_nodding'] as bool;
      final earScore    = (faceResult['ear_score'] as num?)?.toDouble() ?? 1.0;


      // ── STEP 2: MobileNetV2 — skip if MediaPipe already very confident ──
      double modelScore = 0.0;
      if (_isModelLoaded) {
        final Uint8List bytes = await File(image.path).readAsBytes();
        final modelResult = await _mlModelService.runPrediction(
            _mlModelService.preprocessCameraFile(bytes));
        modelScore = (modelResult['drowsy_score'] as num?)?.toDouble() ?? 0.0;
      }

      // ── COMBINED LOGIC ────────────────────────────────────
      // MediaPipe is primary. Model confirms or catches missed cases.
      bool isDrowsy = mlkitDrowsy || modelScore > 0.35;

      print('👁 MLKit=$mlkitDrowsy (eye=$eyeClosed yawn=$yawning nod=$nodding) '
          '| Model=${modelScore.toStringAsFixed(3)} | Final=$isDrowsy');

      // ── WAKE UP: stop alerts immediately ─────────────────
      if (!isDrowsy && (_isAlertPending || _isAlertDialogOpen)) {
        _alertDelayTimer?.cancel();
        _stopAllAlerts();
        setState(() {
          _drowsinessStatus = 'Normal';
          _isFaceDrowsy     = false;
        });
      }

      // ── UPDATE UI ─────────────────────────────────────────
      if (mounted) setState(() {
        _isFaceDrowsy     = isDrowsy;
        _drowsinessStatus = isDrowsy ? 'Drowsy Detected!' : 'Normal';
        if (isDrowsy) _detectionCount++;
      });

      _watchService.sendDrowsinessAlert(
          isDrowsy: isDrowsy, earScore: earScore, detectionCount: _detectionCount);

      // ── FRAME COUNTER + ALERTS ────────────────────────────────
      _warmupFrames++;

      if (isDrowsy) {
        _consecutiveDrowsyFrames++;
        _alertToleranceFrames = 0;

        // Skip first 3 frames — MediaPipe needs warmup
        if (_consecutiveDrowsyFrames >= 1 && _warmupFrames > 3) {
          _triggerAlerts();
        }

        // Start wall-clock drowsy timer if not already running
        _startDrowsyWallClock();

      } else {
        _consecutiveDrowsyFrames = 0;
        _alertToleranceFrames++;

        if (_alertToleranceFrames >= 3) {
          _alertToleranceFrames = 0;
          _stopDrowsyWallClock();
          if (_isDeepSleepMode) _cancelDeepSleepAlarm();
          if (!_isAlertPending && mounted) {
            setState(() { _isFaceDrowsy = false; _drowsinessStatus = 'Normal'; });
          }
        }
      }

    } catch (e) {
      print('Inference error: $e');
    } finally {
      _isInferenceRunning = false; // always release guard
    }
  }

  // ══════════════════════════════════════════════════════════
  // WALL CLOCK DROWSY TIMER (replaces frame-count approach)
  // Counts real seconds regardless of frame speed
  // ══════════════════════════════════════════════════════════

  void _startDrowsyWallClock() {
    if (_drowsyWallClockTimer != null) return; // already running
    print('⏱ Drowsy wall clock started');
    _drowsyWallClockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isMonitoring) { _stopDrowsyWallClock(); return; }
      _continuousDrowsySeconds++;
      if (mounted) setState(() {}); // refresh UI counter

      print('⏱ Drowsy for $_continuousDrowsySeconds seconds');

      if (_continuousDrowsySeconds >= 30 && !_isDeepSleepMode) {
        _triggerDeepSleepAlarm();
      }
    });
  }

  void _stopDrowsyWallClock() {
    _drowsyWallClockTimer?.cancel();
    _drowsyWallClockTimer = null;
    if (mounted) setState(() => _continuousDrowsySeconds = 0);
  }

  // ══════════════════════════════════════════════════════════
  // DEEP SLEEP ALARM
  // ══════════════════════════════════════════════════════════

  void _triggerDeepSleepAlarm() {
    if (_isDeepSleepMode) return;
    _isDeepSleepMode = true;
    print('🚨 DEEP SLEEP MODE ACTIVATED');

    // Repeated watch notifications every 5 seconds
    _deepSleepTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_isDeepSleepMode) {
        _sendWatchNotification(isDeepSleep: true);
        _watchService.sendDrowsinessAlert(
            isDrowsy: true, earScore: 0.0, detectionCount: _detectionCount);
      }
    });

    // Auto SMS after 60 seconds of no response
    _deepSleepSmsTimer = Timer(const Duration(seconds: 60), () async {
      if (!_isDeepSleepMode) return;
      print('🚨 No response 60s — sending emergency SMS');
      final user = _auth.currentUser;
      if (user == null) return;
      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (doc.exists) await _sendDeepSleepEmergencySMS(doc.data());
    });

    _alertDelayTimer?.cancel();
    if (_isAlertDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      _isAlertDialogOpen = false;
    }

    _sendWatchNotification(isDeepSleep: true);
    _startDeepSleepSound();
    _watchService.sendDrowsinessAlert(
        isDrowsy: true, earScore: 0.0, detectionCount: _detectionCount);
    _showDeepSleepDialog();
  }

  void _startDeepSleepSound() async {
    await _audioPlayer.setReleaseMode(ReleaseMode.loop);
    try {
      final prefs      = await SharedPreferences.getInstance();
      final selected   = prefs.getString('selectedSound') ?? 'alert_sound.mp3';
      final customPath = prefs.getString('customSoundPath');
      if (selected == 'custom' && customPath != null) {
        await _audioPlayer.play(DeviceFileSource(customPath));
      } else {
        await _audioPlayer.play(AssetSource(selected));
      }
    } catch (e) {
      await _audioPlayer.play(AssetSource('alert_sound.mp3'));
    }
    _vibrationTimer?.cancel();
    _vibrationTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      Vibration.vibrate(duration: 250, amplitude: 255);
    });
  }

  void _showDeepSleepDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: Colors.red.shade900,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Colors.red, width: 3),
          ),
          title: const Column(
            children: [
              Icon(Icons.emergency, color: Colors.white, size: 48),
              SizedBox(height: 8),
              Text('🚨 DEEP SLEEP!',
                  style: TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 22),
                  textAlign: TextAlign.center),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('You have been drowsy for 30+ seconds!\nPull over immediately!',
                  style: TextStyle(color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: Colors.red.shade700,
                    borderRadius: BorderRadius.circular(12)),
                child: Text(
                  'Detections: $_detectionCount\n'
                      'Emergency SMS sends in 60s if no response',
                  style: const TextStyle(color: Colors.white,
                      fontSize: 14, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () { _cancelDeepSleepAlarm(); Navigator.pop(context); },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.red.shade900,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('I AM AWAKE — STOP ALARM',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _cancelDeepSleepAlarm() {
    _isDeepSleepMode = false;
    _deepSleepTimer?.cancel();
    _deepSleepSmsTimer?.cancel();
    _drowsyWallClockTimer?.cancel();
    _drowsyWallClockTimer = null;
    _audioPlayer.stop();
    _audioPlayer.setReleaseMode(ReleaseMode.release);
    _stopContinuousVibration();
    _isAlertPending    = false;
    _isAlertDialogOpen = false;
    _continuousDrowsySeconds = 0;
    if (mounted) setState(() {});
    print('✅ Deep sleep alarm cancelled');
  }

  // ══════════════════════════════════════════════════════════
  // NORMAL ALERTS
  // ══════════════════════════════════════════════════════════

  void _stopAllAlerts() {
    _audioPlayer.stop();
    _stopContinuousVibration();
    _alertDelayTimer?.cancel();
    _isAlertPending = false;
    if (_isAlertDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      _isAlertDialogOpen = false;
    }
  }

  Future<void> _triggerAlerts() async {
    if (_isAlertPending || _isDeepSleepMode) return;
    _isAlertPending = true;

    // Vibration must be scheduled via Timer to guarantee main thread
    if (_vibrationAlert) {
      Timer(Duration.zero, () {
        Vibration.vibrate(duration: 1000, amplitude: 255);
      });
    }

    if (_soundAlert) _playAlertSound();
    await _sendWatchNotification();

    _alertDelayTimer = Timer(const Duration(seconds: 10), () {
      if (!_isAlertDialogOpen && mounted && _isMonitoring) _showAlertDialog();
      _isAlertPending = false;
    });

    if (_smsAlert && _detectionCount >= _drowsinessThreshold) {
      final user = _auth.currentUser;
      if (user == null) return;
      final doc = await _firestore.collection('users').doc(user.uid).get();
      _sendEmergencySMS(doc.data());
    }
  }

  void _showAlertDialog() {
    if (_isAlertDialogOpen) return;
    _isAlertDialogOpen = true;
    _startContinuousVibration();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: kRed, size: 28),
          const SizedBox(width: 12),
          Text('Alert!', style: TextStyle(color: kRed, fontWeight: FontWeight.bold)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Drowsiness Detected!',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                  color: Colors.black87)),
          const SizedBox(height: 8),
          Text('Detection count: $_detectionCount',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
        ]),
        actions: [
          ElevatedButton(
            onPressed: () { _stopAllAlerts(); Navigator.pop(context); },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade400,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Stop Alert',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ).then((_) { _isAlertDialogOpen = false; _stopContinuousVibration(); });

    Future.delayed(const Duration(seconds: 30), () {
      if (_isAlertDialogOpen && mounted) { _stopAllAlerts(); Navigator.pop(context); }
    });
  }

  void _startContinuousVibration() {
    _vibrationTimer?.cancel();
    Vibration.vibrate(duration: 300, amplitude: 255); // immediate
    _vibrationTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      Vibration.vibrate(duration: 300, amplitude: 255);
    });
  }

  void _stopContinuousVibration() {
    _vibrationTimer?.cancel();
    _vibrationTimer = null;
    Vibration.cancel();
  }

  void _playAlertSound() async {
    try {
      final prefs      = await SharedPreferences.getInstance();
      final selected   = prefs.getString('selectedSound') ?? 'alert_sound.mp3';
      final customPath = prefs.getString('customSoundPath');

      if (selected == 'custom' && customPath != null) {
        await _audioPlayer.play(DeviceFileSource(customPath));
      } else {
        await _audioPlayer.play(AssetSource(selected));
      }
    } catch (e) {
      try { await _audioPlayer.play(AssetSource('alert_sound.mp3')); } catch (_) {}
    }
  }

  // ══════════════════════════════════════════════════════════
  // MONITORING
  // ══════════════════════════════════════════════════════════

  void _toggleMonitoring() => _isMonitoring ? _stopMonitoring() : _startMonitoring();

  void _startMonitoring() {
    if (!_isCameraInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera not initialized.')));
      _initializeCamera();
      return;
    }
    setState(() {
      _isMonitoring     = true;
      _currentStatus    = 'Monitoring active...';
      _detectionCount   = 0;
      _drowsinessStatus = 'Normal';
      _consecutiveDrowsyFrames = 0;
      _continuousDrowsySeconds = 0;
      _warmupFrames             = 0;
    });
    // Capture every 3 seconds — gives model enough time to finish
    _captureTimer = Timer.periodic(
        const Duration(milliseconds: 1500), (_) => _captureAndRunInference());
    _watchService.sendMonitoringStatus(isActive: true);
  }

  void _stopMonitoring() {
    setState(() {
      _isMonitoring     = false;
      _currentStatus    = 'Monitoring stopped';
      _drowsinessStatus = 'Normal';
      _faceBox          = null;
      _isFaceDrowsy     = false;
    });
    _captureTimer?.cancel();
    _alertDelayTimer?.cancel();
    _deepSleepTimer?.cancel();
    _deepSleepSmsTimer?.cancel();
    _drowsyWallClockTimer?.cancel();
    _drowsyWallClockTimer = null;
    _isAlertPending      = false;
    _isDeepSleepMode     = false;
    _isInferenceRunning  = false;
    _consecutiveDrowsyFrames = 0;
    _continuousDrowsySeconds = 0;
    _watchService.sendMonitoringStatus(isActive: false);
  }

  // ══════════════════════════════════════════════════════════
  // SETTINGS + SMS
  // ══════════════════════════════════════════════════════════

  Future<void> _loadUserSettings() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (doc.exists && mounted) {
        final data = doc.data();
        setState(() {
          _soundAlert          = data?['soundAlert']          ?? true;
          _vibrationAlert      = data?['vibrationAlert']      ?? true;
          _smsAlert            = data?['smsAlert']            ?? false;
          _drowsinessThreshold = data?['drowsinessThreshold'] ?? 3;
        });
      }
    } catch (e) { print('Settings error: $e'); }
  }

  Future<void> _sendEmergencySMS(Map<String, dynamic>? userData) async {
    if (userData?['emergencyContact'] == null) return;
    final phone = userData!['emergencyContact']['phone']
        .toString().replaceAll(RegExp(r'[^\d+]'), '');
    final message = '🚨 ALERT: ${userData['fullName']} '
        'is drowsy while driving! Detected $_detectionCount times. '
        'Please call immediately!';

    final Uri smsUri = Uri(scheme: 'sms', path: phone,
        queryParameters: {'body': message});
    await launchUrl(smsUri, mode: LaunchMode.externalApplication);
    print('✅ Deep sleep SMS sent to $phone');
  }
  Future<void> _sendDeepSleepEmergencySMS(Map<String, dynamic>? userData) async {
    if (userData?['emergencyContact'] == null) return;

    final phone = userData!['emergencyContact']['phone']
        .toString()
        .replaceAll(RegExp(r'[^\d+]'), '');

    final message = '🚨 URGENT: ${userData['fullName']} '
        'has been ASLEEP while driving for over 60 seconds! '
        'No response to alarm. Please call immediately!';

    final Uri smsUri = Uri(scheme: 'sms', path: phone,
        queryParameters: {'body': message});
    await launchUrl(smsUri, mode: LaunchMode.externalApplication);
    print('✅ Deep sleep SMS sent to $phone');
  }
  // ══════════════════════════════════════════════════════════
  // BLUETOOTH
  // ══════════════════════════════════════════════════════════

  void _connectBluetoothCamera() async {
    if (_isBluetoothCameraConnected) {
      await connectedDevice?.disconnect();
      setState(() {
        _isBluetoothCameraConnected = false;
        _bluetoothStatus = 'Disconnected';
        connectedDevice  = null;
      });
    } else {
      _showBluetoothDevicesDialog();
    }
  }

  void _showBluetoothDevicesDialog() async {
    if (!await Permission.bluetooth.request().isGranted) return;
    setState(() => _bluetoothStatus = 'Scanning...');
    devicesList.clear();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    final sub = FlutterBluePlus.scanResults.listen(
            (results) => setState(() => devicesList = results.map((r) => r.device).toList()));
    await Future.delayed(const Duration(seconds: 5));
    FlutterBluePlus.stopScan();
    sub.cancel();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Bluetooth Device'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: devicesList.length,
            itemBuilder: (context, index) {
              final device = devicesList[index];
              return ListTile(
                title: Text(device.platformName.isEmpty ? 'Unknown' : device.platformName),
                subtitle: Text(device.remoteId.toString()),
                onTap: () { _connectToDevice(device); Navigator.pop(context); },
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))
        ],
      ),
    );
  }

  void _connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      setState(() {
        connectedDevice = device;
        _isBluetoothCameraConnected = true;
        _bluetoothStatus = 'Connected: ${device.platformName}';
      });
    } catch (e) {
      setState(() => _bluetoothStatus = 'Connection failed');
    }
  }

  // ══════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: kGreen,
        title: const Text('Driver Safety Monitor',
            style: TextStyle(color: Colors.white)),
        centerTitle: true,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.watch, color: Colors.white),
            onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => WatchScreen(
                  isMonitoring: _isMonitoring, isDrowsy: _isFaceDrowsy,
                  detectionCount: _detectionCount, earScore: 0.0),
            )),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            _buildBluetoothCard(),
            const SizedBox(height: 8),
            if (_isCameraInitialized && _isMonitoring) _buildCameraWithFaceBox(),
            _buildStatusCard(),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Expanded(child: _buildStatCard(
                    title: 'Detections', value: '$_detectionCount',
                    icon: Icons.warning_amber_rounded, color: kOrange)),
                const SizedBox(width: 16),
                Expanded(child: _buildStatCard(
                    title: 'Status', value: _isMonitoring ? 'Active' : 'Inactive',
                    icon: Icons.info_outline,
                    color: _isMonitoring ? Colors.green : Colors.grey)),
              ]),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // CAMERA WITH FACE BOX
  // ══════════════════════════════════════════════════════════

  Widget _buildCameraWithFaceBox() {
    return Container(
      height: 280,
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _isFaceDrowsy ? kRed : kGreen, width: 3),
        boxShadow: [BoxShadow(
            color: (_isFaceDrowsy ? kRed : kGreen).withOpacity(0.3),
            blurRadius: 12, spreadRadius: 2)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: LayoutBuilder(builder: (context, constraints) {
          return Stack(fit: StackFit.expand, children: [
            CameraPreview(_cameraController!),
            if (_faceBox != null)
              CustomPaint(
                painter: _FaceBoxPainter(
                  faceBox: _faceBox!, isDrowsy: _isFaceDrowsy,
                  previewSize: Size(constraints.maxWidth, constraints.maxHeight),
                  imageSize: Size(
                    _cameraController!.value.previewSize?.height ?? 640,
                    _cameraController!.value.previewSize?.width ?? 480,
                  ),
                ),
              ),
            if (_isFaceDrowsy)
              Positioned(
                top: 10, left: 0, right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                        color: kRed.withOpacity(0.85),
                        borderRadius: BorderRadius.circular(20)),
                    child: const Text('⚠️  DROWSY DETECTED',
                        style: TextStyle(color: Colors.white,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                ),
              ),
            if (_isDeepSleepMode)
              Positioned(
                bottom: 10, left: 0, right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                        color: Colors.red.shade900.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(20)),
                    child: const Text('🚨 DEEP SLEEP MODE',
                        style: TextStyle(color: Colors.white,
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                ),
              ),
          ]);
        }),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // UI WIDGETS
  // ══════════════════════════════════════════════════════════

  Widget _buildBluetoothCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05),
                blurRadius: 10, offset: const Offset(0, 5))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.bluetooth, color: Colors.blue, size: 24),
            const SizedBox(width: 10),
            const Expanded(child: Text('Webcam Connectivity',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            ElevatedButton.icon(
              onPressed: _connectBluetoothCamera,
              icon: Icon(_isBluetoothCameraConnected ? Icons.link_off : Icons.link,
                  size: 18, color: Colors.white),
              label: Text(_isBluetoothCameraConnected ? 'Disconnect' : 'Connect'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isBluetoothCameraConnected
                    ? Colors.red.shade400 : Colors.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(70, 32), elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Status: $_bluetoothStatus',
              style: TextStyle(fontSize: 13,
                  color: _isBluetoothCameraConnected ? Colors.green : Colors.grey)),
        ]),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05),
                blurRadius: 10, offset: const Offset(0, 5))]),
        child: Column(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 80, height: 80,
            decoration: BoxDecoration(
              color: _isDeepSleepMode
                  ? Colors.red.shade900.withOpacity(0.15)
                  : _isFaceDrowsy ? kRed.withOpacity(0.1) : kGreen.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isDeepSleepMode ? Icons.emergency
                  : _isFaceDrowsy ? Icons.warning_amber_rounded
                  : _isMonitoring ? Icons.visibility : Icons.visibility_off,
              size: 40,
              color: _isDeepSleepMode ? Colors.red.shade900
                  : _isFaceDrowsy ? kRed : kGreen,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _isDeepSleepMode ? '🚨 DEEP SLEEP!' : _drowsinessStatus,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold,
                color: _isDeepSleepMode ? Colors.red.shade900
                    : _isFaceDrowsy ? kRed : Colors.black87),
          ),
          const SizedBox(height: 8),
          if (_isMonitoring && _continuousDrowsySeconds > 0)
            Text(
              'Drowsy for ${_continuousDrowsySeconds}s'
                  '${_continuousDrowsySeconds >= 20 ? ' — WARNING!' : ''}',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                  color: _continuousDrowsySeconds >= 20 ? kRed : kOrange),
            ),
          Text(_currentStatus,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity, height: 60,
            child: ElevatedButton(
              onPressed: _isCameraInitialized ? _toggleMonitoring : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isMonitoring ? Colors.red.shade400 : kGreen,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(_isMonitoring ? Icons.stop_circle : Icons.play_circle_filled,
                    size: 28),
                const SizedBox(width: 12),
                Text(_isMonitoring ? 'Stop Monitoring' : 'Start Monitoring',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
          if (!_isCameraInitialized) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade200)),
              child: Row(children: [
                Icon(Icons.info_outline, color: Colors.orange.shade700, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Waiting for camera initialization...',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade900))),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _buildStatCard({required String title, required String value,
    required IconData icon, required Color color}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05),
              blurRadius: 10, offset: const Offset(0, 5))]),
      child: Column(children: [
        Icon(icon, size: 32, color: color),
        const SizedBox(height: 12),
        Text(value, style: TextStyle(fontSize: 24,
            fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 4),
        Text(title, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════
// FACE BOX PAINTER
// ══════════════════════════════════════════════════════════

class _FaceBoxPainter extends CustomPainter {
  final Map<String, double> faceBox;
  final bool isDrowsy;
  final Size previewSize;
  final Size imageSize;

  _FaceBoxPainter({required this.faceBox, required this.isDrowsy,
    required this.previewSize, required this.imageSize});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isDrowsy ? const Color(0xFFE53935) : const Color(0xFF78C841)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    final cornerPaint = Paint()
      ..color = isDrowsy ? const Color(0xFFE53935) : const Color(0xFF78C841)
      ..strokeWidth = 5.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final double scaleX = previewSize.width  / imageSize.width;
    final double scaleY = previewSize.height / imageSize.height;

    const double padX = 30.0;
    const double padY = 50.0;

    final double left   = (faceBox['left']!   * scaleX - padX).clamp(0, previewSize.width);
    final double top    = (faceBox['top']!    * scaleY - padY).clamp(0, previewSize.height);
    final double right  = (faceBox['right']!  * scaleX + padX).clamp(0, previewSize.width);
    final double bottom = (faceBox['bottom']! * scaleY + 10.0).clamp(0, previewSize.height);

    final rect = Rect.fromLTRB(left, top, right, bottom);
    canvas.drawRect(rect, paint);

    final double cornerLen = (right - left) * 0.2;
    canvas.drawLine(Offset(left, top), Offset(left + cornerLen, top), cornerPaint);
    canvas.drawLine(Offset(left, top), Offset(left, top + cornerLen), cornerPaint);
    canvas.drawLine(Offset(right, top), Offset(right - cornerLen, top), cornerPaint);
    canvas.drawLine(Offset(right, top), Offset(right, top + cornerLen), cornerPaint);
    canvas.drawLine(Offset(left, bottom), Offset(left + cornerLen, bottom), cornerPaint);
    canvas.drawLine(Offset(left, bottom), Offset(left, bottom - cornerLen), cornerPaint);
    canvas.drawLine(Offset(right, bottom), Offset(right - cornerLen, bottom), cornerPaint);
    canvas.drawLine(Offset(right, bottom), Offset(right, bottom - cornerLen), cornerPaint);

    final textSpan = TextSpan(
      text: isDrowsy ? ' DROWSY ' : ' ALERT ',
      style: TextStyle(
        color: isDrowsy ? const Color(0xFFE53935) : const Color(0xFF78C841),
        fontSize: 13, fontWeight: FontWeight.bold,
        background: Paint()..color = Colors.black.withOpacity(0.5),
      ),
    );
    final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
    textPainter.layout();
    textPainter.paint(canvas, Offset(left, top - 20));
  }

  @override
  bool shouldRepaint(_FaceBoxPainter old) =>
      old.faceBox != faceBox || old.isDrowsy != isDrowsy;
}