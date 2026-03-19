import 'dart:async';
import 'package:flutter/services.dart';

/// Singleton service that handles all communication with the paired smartwatch.
/// Uses a MethodChannel to call native Android code (Wear OS Data Layer API).
class WatchService {
  static final WatchService _instance = WatchService._internal();
  factory WatchService() => _instance;
  WatchService._internal();

  // MethodChannel matches the channel name in MainActivity.kt
  static const MethodChannel _channel = MethodChannel('com.greener.watch/drowsiness');

  // StreamController to broadcast watch commands (start/stop) back to the app
  final StreamController<String> _watchCommandController =
  StreamController<String>.broadcast();

  Stream<String> get watchCommands => _watchCommandController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  /// Call once at app start (in main.dart or HomePage initState)
  Future<void> initialize() async {
    _channel.setMethodCallHandler(_handleWatchMessage);
    await _checkConnection();
  }

  /// Handles incoming messages FROM the watch (start/stop commands)
  Future<dynamic> _handleWatchMessage(MethodCall call) async {
    switch (call.method) {
      case 'onWatchCommand':
        final command = call.arguments as String;
        _watchCommandController.add(command); // 'START' or 'STOP'
        break;
      case 'onConnectionChanged':
        _isConnected = call.arguments as bool;
        break;
    }
  }

  Future<void> _checkConnection() async {
    try {
      _isConnected = await _channel.invokeMethod('checkConnection') ?? false;
    } catch (_) {
      _isConnected = false;
    }
  }

  /// Send drowsiness alert to watch — call this when EAR < threshold
  Future<void> sendDrowsinessAlert({
    required bool isDrowsy,
    required double earScore,
    required int detectionCount,
  }) async {
    try {
      await _channel.invokeMethod('sendAlert', {
        'isDrowsy': isDrowsy,
        'earScore': earScore,
        'detectionCount': detectionCount,
      });
    } catch (e) {
      // Watch not connected — ignore silently
    }
  }

  Future<void> sendMonitoringStatus({required bool isActive}) async {
    try {
      await _channel.invokeMethod('sendStatus', {'isMonitoring': isActive});
    } catch (e) {
      // Watch not connected — ignore silently
    }
  }

  /// Send heart rate to watch (if you collect it from a sensor)
  Future<void> sendHeartRate(int bpm) async {
    try {
      await _channel.invokeMethod('sendHeartRate', {'bpm': bpm});
    } on PlatformException catch (e) {
      print('WatchService sendHeartRate error: ${e.message}');
    }
  }

  void dispose() {
    _watchCommandController.close();
  }
}