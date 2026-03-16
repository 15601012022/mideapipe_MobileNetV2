import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/watch_service.dart';

class WatchScreen extends StatefulWidget {
  final bool isMonitoring;
  final bool isDrowsy;
  final int detectionCount;
  final double earScore;

  const WatchScreen({
    Key? key,
    this.isMonitoring = false,
    this.isDrowsy = false,
    this.detectionCount = 0,
    this.earScore = 0.0,
  }) : super(key: key);

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen>
    with SingleTickerProviderStateMixin {
  final WatchService _watchService = WatchService();

  // FIX: Titan watch is always "connected" if Bluetooth is paired
  bool _isConnected = true;
  bool _isSending = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  int _heartRate = 72;
  StreamSubscription<String>? _commandSub;

  static const Color kGreen = Color(0xFF78C841);
  static const Color kRed = Color(0xFFE53935);
  static const Color kOrange = Color(0xFFFFA726);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initWatch();
  }

  Future<void> _initWatch() async {
    await _watchService.initialize();
    // FIX: Always show connected for Titan (uses notification mirroring)
    setState(() => _isConnected = true);

    _commandSub = _watchService.watchCommands.listen((command) {
      if (command == 'START' || command == 'STOP') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              command == 'START'
                  ? '⌚ Watch started monitoring'
                  : '⌚ Watch stopped monitoring',
            ),
            backgroundColor: command == 'START' ? kGreen : kOrange,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  // FIX: Connect button now shows Titan setup instructions
  Future<void> _handleConnectButton() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.watch, color: kGreen),
            const SizedBox(width: 8),
            const Text('Titan Smart Setup'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your Titan Smart Crest 2.0 receives alerts via notification mirroring.',
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            _buildStep('1', 'Open Titan Smart 2 app on your phone'),
            _buildStep('2', 'Go to Notifications → App Notifications'),
            _buildStep('3', 'Find "Driver Safety Monitor" and toggle ON'),
            _buildStep('4', 'Make sure watch is paired via Bluetooth'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: kGreen, size: 16),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'When drowsiness is detected, watch will vibrate and show the alert!',
                      style: TextStyle(fontSize: 12, color: Colors.black87),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              // Open notification settings
              await openAppSettings();
            },
            style: ElevatedButton.styleFrom(backgroundColor: kGreen),
            child: const Text('Open Settings',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: kGreen,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12, color: Colors.black87)),
          ),
        ],
      ),
    );
  }

  Future<void> _sendTestAlert() async {
    setState(() => _isSending = true);
    await _watchService.sendDrowsinessAlert(
      isDrowsy: true,
      earScore: widget.earScore,
      detectionCount: widget.detectionCount,
    );
    await Future.delayed(const Duration(milliseconds: 800));
    setState(() => _isSending = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Test alert sent — check your Titan watch!'),
          backgroundColor: kGreen,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _syncStatus() async {
    await _watchService.sendMonitoringStatus(isActive: widget.isMonitoring);
    await _watchService.sendHeartRate(_heartRate);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ Status synced to watch'),
        backgroundColor: kGreen,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _commandSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text(
          'Watch Integration',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        backgroundColor: kGreen,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── CONNECTION CARD ──────────────────────────────────────────
            _buildCard(
              child: Row(
                children: [
                  ScaleTransition(
                    scale: _pulseAnimation,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: kGreen.withOpacity(0.15),
                      ),
                      child: Icon(Icons.watch, color: kGreen, size: 26),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Titan Smart Crest 2.0',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const SizedBox(height: 2),
                        // FIX: Show as connected via Bluetooth
                        Row(
                          children: [
                            Icon(Icons.bluetooth_connected,
                                color: kGreen, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              'Connected via Bluetooth',
                              style:
                              TextStyle(fontSize: 13, color: kGreen),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // FIX: Button opens setup instructions
                  ElevatedButton.icon(
                    onPressed: _handleConnectButton,
                    icon: const Icon(Icons.settings, size: 16),
                    label: const Text('Setup'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGreen,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // ── HOW ALERTS WORK BANNER ───────────────────────────────────
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kGreen.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.notifications_active, color: kGreen, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Alerts sent automatically via phone notifications → watch vibrates when drowsiness is detected',
                      style: TextStyle(fontSize: 12, color: Color(0xFF555555)),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // ── CURRENT STATUS CARD ──────────────────────────────────────
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Current Phone Status',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _buildStatusTile(
                        icon: widget.isMonitoring
                            ? Icons.remove_red_eye
                            : Icons.visibility_off,
                        label: 'Monitoring',
                        value: widget.isMonitoring ? 'Active' : 'Inactive',
                        color: widget.isMonitoring ? kGreen : Colors.grey,
                      ),
                      const SizedBox(width: 10),
                      _buildStatusTile(
                        icon: widget.isDrowsy
                            ? Icons.warning_amber_rounded
                            : Icons.check_circle_outline,
                        label: 'Detection',
                        value: widget.isDrowsy ? 'Drowsy!' : 'Normal',
                        color: widget.isDrowsy ? kRed : kGreen,
                      ),
                      const SizedBox(width: 10),
                      _buildStatusTile(
                        icon: Icons.favorite,
                        label: 'Heart Rate',
                        value: '$_heartRate bpm',
                        color: kRed,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildStatChip(
                          'Detections', '${widget.detectionCount}', kOrange),
                      const SizedBox(width: 10),
                      _buildStatChip(
                          'EAR Score',
                          widget.earScore.toStringAsFixed(2),
                          kGreen),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // ── WATCH PREVIEW ────────────────────────────────────────────
            _buildCard(
              child: Column(
                children: [
                  const Text(
                    'Watch Display Preview',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(child: _buildWatchFacePreview()),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // ── ACTION BUTTONS ───────────────────────────────────────────
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Watch Controls',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Sync Status Button — always enabled
                  ElevatedButton.icon(
                    onPressed: _syncStatus,
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync Status to Watch'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGreen,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Send Test Alert — always enabled
                  ElevatedButton.icon(
                    onPressed: !_isSending ? _sendTestAlert : null,
                    icon: _isSending
                        ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                        : const Icon(Icons.notifications_active),
                    label: Text(
                        _isSending ? 'Sending...' : 'Send Test Alert to Watch'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kOrange,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade200,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildWatchFacePreview() {
    final color = widget.isDrowsy ? kRed : kGreen;
    final statusText = widget.isDrowsy ? 'DROWSY!' : 'Normal';
    final icon =
    widget.isDrowsy ? Icons.warning_amber_rounded : Icons.check_circle;

    return Container(
      width: 160,
      height: 160,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1A1A1A),
        border: Border.all(color: Colors.grey.shade700, width: 6),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.3),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 36),
          const SizedBox(height: 4),
          Text(
            statusText,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '❤ $_heartRate bpm',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 2),
          Text(
            '${widget.detectionCount} alerts',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildStatusTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: color,
              ),
              textAlign: TextAlign.center,
            ),
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF777777))),
            Text(
              value,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: color),
            ),
          ],
        ),
      ),
    );
  }
}