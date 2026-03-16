// settings_page.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final FirebaseAuth     _auth      = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AudioPlayer      _previewPlayer = AudioPlayer();

  // ── Alert toggles ─────────────────────────────────────────
  bool _soundAlertEnabled     = true;
  bool _vibrationAlertEnabled = true;
  bool _smsAlertEnabled       = false;
  int  _drowsinessThreshold   = 3;

  // ── Alarm sound selection ─────────────────────────────────
  String _selectedSound = 'alert_sound.mp3'; // default
  String? _customSoundPath;                  // user picked file

  // Built-in sound options
  final List<Map<String, String>> _builtInSounds = [
    {'id': 'alert_sound.mp3',  'name': 'Default Alert',  'icon': '🔔'},
    {'id': 'alarm_beep.mp3',   'name': 'Beep Alarm',     'icon': '📢'},
    {'id': 'alarm_siren.mp3',  'name': 'Siren',          'icon': '🚨'},
    {'id': 'alarm_horn.mp3',   'name': 'Horn',           'icon': '📯'},
  ];

  bool _isLoading = true;

  static const Color kGreen = Color(0xFF78C841);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final user = _auth.currentUser;
    if (user != null) {
      try {
        final doc = await _firestore.collection('users').doc(user.uid).get();
        // Sync Firestore sound selection to SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('selectedSound', _selectedSound);
        
        if (doc.exists) {
          final data = doc.data();
          setState(() {
            _soundAlertEnabled     = data?['soundAlert']         ?? true;
            _vibrationAlertEnabled = data?['vibrationAlert']     ?? true;
            _smsAlertEnabled       = data?['smsAlert']           ?? false;
            _drowsinessThreshold   = data?['drowsinessThreshold'] ?? 3;
            _selectedSound         = data?['selectedSound']      ?? 'alert_sound.mp3';
          });
        }
      } catch (e) {
        print('Error loading settings: $e');
      }
    }

    // Load custom sound path from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _customSoundPath = prefs.getString('customSoundPath');
      _isLoading = false;
    });
  }


  Future<void> _saveSettings() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      await _firestore.collection('users').doc(user.uid).update({
        'soundAlert':          _soundAlertEnabled,
        'vibrationAlert':      _vibrationAlertEnabled,
        'smsAlert':            _smsAlertEnabled,
        'drowsinessThreshold': _drowsinessThreshold,
        'selectedSound':       _selectedSound,
      });

      // Save selected sound to SharedPreferences so home_page can read it
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selectedSound', _selectedSound);
      if (_customSoundPath != null) {
        await prefs.setString('customSoundPath', _customSoundPath!);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Settings saved successfully!'),
            backgroundColor: kGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }


  // ── Preview sound ─────────────────────────────────────────
  Future<void> _previewSound(String soundId) async {
    await _previewPlayer.stop();
    try {
      if (soundId == 'custom' && _customSoundPath != null) {
        await _previewPlayer.play(DeviceFileSource(_customSoundPath!));
      } else {
        await _previewPlayer.play(AssetSource(soundId));
      }
    } catch (e) {
      // Sound file may not exist yet — show message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Add $soundId to assets/ folder to use this sound'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  // ── Pick custom sound from device ────────────────────────
  Future<void> _pickCustomSound() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        final name = result.files.single.name;

        setState(() {
          _customSoundPath = path;
          _selectedSound   = 'custom';
        });

        // Save immediately
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('customSoundPath', path);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Custom sound selected: $name'),
              backgroundColor: kGreen,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Add file_picker to pubspec.yaml first'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: kGreen),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: kGreen,
        title: const Text('Settings',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.save, color: Colors.white),
            onPressed: _saveSettings,
            tooltip: 'Save Settings',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 8),

          // ── ALERT SETTINGS ────────────────────────────────
          _buildSectionTitle('🚨 Alert Settings'),
          const SizedBox(height: 8),

          _buildSwitchTile(
            icon: Icons.volume_up,
            title: 'Sound Alert',
            subtitle: 'Play warning sound when drowsiness detected',
            value: _soundAlertEnabled,
            onChanged: (v) => setState(() => _soundAlertEnabled = v),
          ),

          _buildSwitchTile(
            icon: Icons.vibration,
            title: 'Vibration Alert',
            subtitle: 'Vibrate phone when drowsiness detected',
            value: _vibrationAlertEnabled,
            onChanged: (v) => setState(() => _vibrationAlertEnabled = v),
          ),

          _buildSwitchTile(
            icon: Icons.sms,
            title: 'SMS Alert',
            subtitle: 'Send SMS to emergency contact when drowsy',
            value: _smsAlertEnabled,
            onChanged: (v) => setState(() => _smsAlertEnabled = v),
          ),

          const SizedBox(height: 12),

          // ── ALERT THRESHOLD ───────────────────────────────
          _buildThresholdCard(),

          const SizedBox(height: 20),

          // ── ALARM SOUND SELECTION ─────────────────────────
          _buildSectionTitle('🔊 Alarm Sound'),
          const SizedBox(height: 8),
          _buildSoundSelectionCard(),

          const SizedBox(height: 20),

          // ── ACCOUNT SETTINGS ──────────────────────────────
          _buildSectionTitle('👤 Account Settings'),
          _buildSettingsTile(
            icon: Icons.person_outline,
            title: 'Edit Profile',
            subtitle: 'Update your personal information',
            onTap: () {},
          ),
          _buildSettingsTile(
            icon: Icons.lock_outline,
            title: 'Change Password',
            subtitle: 'Update your password',
            onTap: () {},
          ),

          const SizedBox(height: 20),

          // ── PRIVACY ───────────────────────────────────────
          _buildSectionTitle('🔒 Privacy & Security'),
          _buildSettingsTile(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            subtitle: 'Read our privacy policy',
            onTap: () {},
          ),

          const SizedBox(height: 20),

          // ── ABOUT ─────────────────────────────────────────
          _buildSectionTitle('ℹ️ About'),
          _buildSettingsTile(
            icon: Icons.info_outline,
            title: 'App Version',
            subtitle: 'v1.0.0 — Driver Safety Monitor',
            onTap: () {},
          ),

          const SizedBox(height: 32),

          // ── LOGOUT ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              onPressed: () async {
                await _auth.signOut();
                Navigator.pushNamedAndRemoveUntil(
                    context, '/', (route) => false);
              },
              icon: const Icon(Icons.logout),
              label: const Text('Logout',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade400,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // SOUND SELECTION CARD
  // ══════════════════════════════════════════════════════════

  Widget _buildSoundSelectionCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGreen.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          // Built-in sounds
          ..._builtInSounds.map((sound) => _buildSoundTile(
            soundId: sound['id']!,
            name: sound['name']!,
            emoji: sound['icon']!,
          )),

          // Custom sound option
          _buildCustomSoundTile(),
        ],
      ),
    );
  }

  Widget _buildSoundTile({
    required String soundId,
    required String name,
    required String emoji,
  }) {
    final isSelected = _selectedSound == soundId;

    return InkWell(
      onTap: () => setState(() => _selectedSound = soundId),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? kGreen.withOpacity(0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: kGreen.withOpacity(0.4))
              : null,
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? kGreen : Colors.black87,
                ),
              ),
            ),
            // Preview button
            IconButton(
              icon: Icon(Icons.play_circle_outline,
                  color: isSelected ? kGreen : Colors.grey),
              onPressed: () => _previewSound(soundId),
              tooltip: 'Preview',
            ),
            // Selected indicator
            if (isSelected)
              Icon(Icons.check_circle, color: kGreen, size: 22)
            else
              const Icon(Icons.radio_button_unchecked,
                  color: Colors.grey, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomSoundTile() {
    final isSelected = _selectedSound == 'custom';
    final hasCustom  = _customSoundPath != null;

    return InkWell(
      onTap: _pickCustomSound,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? kGreen.withOpacity(0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: kGreen.withOpacity(0.4))
              : null,
        ),
        child: Row(
          children: [
            const Text('🎵', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Custom Sound',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? kGreen : Colors.black87,
                    ),
                  ),
                  if (hasCustom)
                    Text(
                      _customSoundPath!.split('/').last,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    Text(
                      'Tap to choose from your files',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500),
                    ),
                ],
              ),
            ),
            // Preview if custom selected
            if (hasCustom)
              IconButton(
                icon: Icon(Icons.play_circle_outline,
                    color: isSelected ? kGreen : Colors.grey),
                onPressed: () => _previewSound('custom'),
              ),
            Icon(
              Icons.folder_open,
              color: isSelected ? kGreen : Colors.grey,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // THRESHOLD CARD
  // ══════════════════════════════════════════════════════════

  Widget _buildThresholdCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kGreen.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: kGreen.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.timer, color: kGreen),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Alert Threshold',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 16)),
                      Text(
                        'Send SMS after $_drowsinessThreshold detections',
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _drowsinessThreshold.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    activeColor: kGreen,
                    label: '$_drowsinessThreshold times',
                    onChanged: (v) =>
                        setState(() => _drowsinessThreshold = v.toInt()),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: kGreen,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$_drowsinessThreshold',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // HELPERS
  // ══════════════════════════════════════════════════════════

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.black87),
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: kGreen.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: kGreen),
        ),
        title: Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: Text(subtitle,
            style:
            TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        trailing: Icon(Icons.chevron_right, color: Colors.grey.shade400),
        onTap: onTap,
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: kGreen.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: kGreen),
        ),
        title: Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: Text(subtitle,
            style:
            TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        value: value,
        onChanged: onChanged,
        activeColor: kGreen,
      ),
    );
  }
}