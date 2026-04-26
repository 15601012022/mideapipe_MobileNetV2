import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Singleton service that handles all communication with the paired smartwatch.
/// Uses a MethodChannel to call native Android code (Wear OS Data Layer API).
class WatchService {
  static final WatchService _instance = WatchService._internal();
  factory WatchService() => _instance;
  WatchService._internal();

  // ── Channel name must match CHANNEL constant in MainActivity.kt ──
  static const MethodChannel _channel =
      MethodChannel('com.driver_drowsidetection/drowsiness');

  final StreamController<String> _watchCommandController =
      StreamController<String>.broadcast();

  Stream<String> get watchCommands => _watchCommandController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  String _watchName = 'Smart Watch';
  String get watchName => _watchName;

  /// Call once at app start
  Future<void> initialize() async {
    _channel.setMethodCallHandler(_handleWatchMessage);
    await _checkConnection();
    await _fetchWatchName(); // ← fetch real BT name on init
  }

  /// Handles incoming messages FROM the watch
  Future<dynamic> _handleWatchMessage(MethodCall call) async {
    switch (call.method) {
      case 'onWatchCommand':
        final command = call.arguments as String;
        _watchCommandController.add(command);
        break;
      case 'onConnectionChanged':
        _isConnected = call.arguments as bool;
        break;
    }
  }

  Future<void> _checkConnection() async {
    try {
      _isConnected =
          await _channel.invokeMethod('checkConnection') ?? false;
    } catch (_) {
      _isConnected = false;
    }
  }

  /// Fetches the Bluetooth display name of the paired watch from Android
  Future<void> _fetchWatchName() async {
    try {
      final name = await _channel.invokeMethod<String>('getWatchName');
      if (name != null && name.isNotEmpty) {
        _watchName = name;
      }
    } catch (_) {
      _watchName = 'Smart Watch'; // fallback if watch not paired via Wear OS
    }
  }

  /// Public method — call this to manually refresh the watch name
  Future<String> getWatchName() async {
    await _fetchWatchName();
    return _watchName;
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
    } catch (_) {
      // Watch not connected — ignore silently
    }
  }

  Future<void> sendMonitoringStatus({required bool isActive}) async {
    try {
      await _channel.invokeMethod('sendStatus', {'isMonitoring': isActive});
    } catch (_) {
      // Watch not connected — ignore silently
    }
  }

  Future<void> sendHeartRate(int bpm) async {
    try {
      await _channel.invokeMethod('sendHeartRate', {'bpm': bpm});
    } on PlatformException catch (e) {
      print('WatchService sendHeartRate error: ${e.toString()}');
    }
  }

  void dispose() {
    _watchCommandController.close();
  }
}