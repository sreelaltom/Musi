import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../database/settings_dao.dart';
import '../services/download_service.dart';
import '../services/music_provider_manager.dart';
import '../services/player_service.dart';
import '../services/ui_preferences.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsDao _settingsDao = SettingsDao();
  final DownloadService _downloadService = DownloadService();
  final MusicProviderManager _providerManager = MusicProviderManager();

  String _audioQuality = 'High (256 kbps)';
  bool _offlineModeOnly = false;
  bool _normalizeVolume = true;
  bool _youtubeEnabled = true;
  String _cacheSizeFormatted = 'Calculating...';
  String _downloadsSizeFormatted = 'Calculating...';

  @override
  void initState() {
    super.initState();
    _loadSettingsAndStorageSizes();
  }

  void _loadSettingsAndStorageSizes() async {
    try {
      // Provider bootstrap may include database migrations and API setup. It
      // should not block rendering local playback preferences.
      unawaited(_providerManager.initialize());
      final values = await Future.wait<Object>([
        _settingsDao.getAudioQuality(),
        _settingsDao.getOfflineMode(),
        _settingsDao.getNormalizeVolume(),
        _settingsDao.getYouTubeEnabled(),
      ]);

      if (mounted) {
        setState(() {
          _audioQuality = values[0] as String;
          _offlineModeOnly = values[1] as bool;
          _normalizeVolume = values[2] as bool;
          _youtubeEnabled = values[3] as bool;
        });
        unawaited(_refreshStorageSizes());
      }
    } catch (error) {
      debugPrint('SettingsScreen: unable to load settings: $error');
      if (mounted) setState(() {});
      _showSettingsError('Could not load your settings. Please try again.');
    }
  }

  Future<void> _refreshStorageSizes() async {
    try {
      final sizes = await Future.wait<int>([
        _calculateCacheBytes(),
        _downloadService.getDownloadedBytes(),
      ]);
      if (!mounted) return;
      setState(() {
        _cacheSizeFormatted = _formatBytes(sizes[0]);
        _downloadsSizeFormatted = _formatBytes(sizes[1]);
      });
    } catch (error) {
      debugPrint('SettingsScreen: unable to calculate storage usage: $error');
    }
  }

  Future<void> _setYouTubeEnabled(bool enabled) async {
    final oldValue = _youtubeEnabled;
    setState(() => _youtubeEnabled = enabled);
    try {
      await _providerManager.setYouTubeEnabled(enabled);
    } catch (_) {
      if (mounted) setState(() => _youtubeEnabled = oldValue);
      _showSettingsError('Could not save source settings.');
    }
  }

  Future<void> _setOfflineMode(bool enabled) async {
    final oldValue = _offlineModeOnly;
    setState(() => _offlineModeOnly = enabled);
    try {
      await _settingsDao.setOfflineMode(enabled);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabled ? 'Offline mode enabled' : 'Offline mode disabled',
            ),
            duration: const Duration(milliseconds: 1400),
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _offlineModeOnly = oldValue);
      _showSettingsError('Could not save offline mode.');
    }
  }

  Future<void> _setNormalizeVolume(bool enabled) async {
    final oldValue = _normalizeVolume;
    setState(() => _normalizeVolume = enabled);
    try {
      await _settingsDao.setNormalizeVolume(enabled);
    } catch (_) {
      if (mounted) setState(() => _normalizeVolume = oldValue);
      _showSettingsError('Could not save the volume preference.');
    }
  }

  void _showSettingsError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppTheme.surfaceCard),
    );
  }

  Future<int> _calculateCacheBytes() async {
    try {
      final tempDir = await getTemporaryDirectory();
      int total = 0;
      if (await tempDir.exists()) {
        await for (final file in tempDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (file is File) {
            total += await file.length();
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0.0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb < 1.0) {
      final kb = bytes / 1024;
      return '${kb.toStringAsFixed(1)} KB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  void _clearTemporaryCache() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        await for (final file in tempDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (file is File) {
            try {
              await file.delete();
            } catch (_) {}
          }
        }
      }

      final newBytes = await _calculateCacheBytes();
      if (mounted) {
        setState(() {
          _cacheSizeFormatted = _formatBytes(newBytes);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Temporary audio cache cleared (downloads preserved)',
            ),
            backgroundColor: AppTheme.surfaceCard,
          ),
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF35230A), AppTheme.surfaceCard],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.tune_rounded, color: AppTheme.accent, size: 28),
                    SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Make Musi yours',
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Playback, sources, and storage preferences',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _buildSectionHeader('DISPLAY'),
              ListenableBuilder(
                listenable: UiPreferences.instance,
                builder: (context, _) {
                  final textScale = UiPreferences.instance.textScale;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceCard,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.format_size_rounded,
                              color: AppTheme.textPrimary,
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Text size',
                                style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              '${(textScale * 100).round()}%',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Reset text size',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  UiPreferences.instance.setTextScale(1.0),
                              icon: const Icon(Icons.restart_alt_rounded),
                            ),
                          ],
                        ),
                        const Text(
                          'Adjust text throughout Musi. Your choice is saved.',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        Slider(
                          value: textScale,
                          min: 0.85,
                          max: 1.25,
                          divisions: 8,
                          label: '${(textScale * 100).round()}%',
                          onChanged: UiPreferences.instance.setTextScale,
                        ),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Smaller', style: TextStyle(fontSize: 11)),
                            Text('Larger', style: TextStyle(fontSize: 11)),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              // Section: Audio & Playback
              _buildSectionHeader('AUDIO & PLAYBACK'),
              _buildSettingsTile(
                icon: Icons.high_quality_rounded,
                title: 'Streaming Quality',
                subtitle: _audioQuality,
                onTap: _showQualityPicker,
              ),
              _buildSleepTimerTile(),
              SwitchListTile(
                secondary: const Icon(
                  Icons.equalizer_rounded,
                  color: AppTheme.textPrimary,
                ),
                title: const Text(
                  'Normalize Volume',
                  style: TextStyle(color: AppTheme.textPrimary),
                ),
                subtitle: const Text(
                  'Set consistent volume across songs',
                  style: TextStyle(color: AppTheme.textMuted),
                ),
                value: _normalizeVolume,
                activeThumbColor: AppTheme.accent,
                onChanged: (val) {
                  _setNormalizeVolume(val);
                },
              ),
              SwitchListTile(
                secondary: const Icon(
                  Icons.wifi_off_rounded,
                  color: AppTheme.textPrimary,
                ),
                title: const Text(
                  'Offline Mode Only',
                  style: TextStyle(color: AppTheme.textPrimary),
                ),
                subtitle: const Text(
                  'Only play downloaded tracks without network requests',
                  style: TextStyle(color: AppTheme.textMuted),
                ),
                value: _offlineModeOnly,
                activeThumbColor: AppTheme.accent,
                onChanged: (val) {
                  _setOfflineMode(val);
                },
              ),

              const SizedBox(height: 20),

              // Section: Music Sources
              _buildSectionHeader('MUSIC SOURCES'),
              SwitchListTile(
                secondary: const Icon(
                  Icons.video_library_rounded,
                  color: AppTheme.textPrimary,
                ),
                title: const Text(
                  'YouTube',
                  style: TextStyle(color: AppTheme.textPrimary),
                ),
                // Describes what the source is without exposing the underlying
                // bridge implementation details.
                subtitle: const Text(
                  'YouTube Music search and playback',
                  style: TextStyle(color: AppTheme.textMuted),
                ),
                value: _youtubeEnabled,
                activeThumbColor: AppTheme.accent,
                onChanged: _setYouTubeEnabled,
              ),

              const SizedBox(height: 20),

              // Section: Storage & Cache
              _buildSectionHeader('STORAGE & DOWNLOADS'),
              _buildSettingsTile(
                icon: Icons.storage_rounded,
                title: 'Clear Temporary Cache',
                subtitle:
                    'Temporary playback cache: $_cacheSizeFormatted (Preserves downloaded songs)',
                onTap: _clearTemporaryCache,
              ),
              _buildSettingsTile(
                icon: Icons.folder_open_rounded,
                title: 'Downloaded Music Storage',
                subtitle:
                    '$_downloadsSizeFormatted stored in app-private storage',
                onTap: _showDownloadStorageInfo,
              ),

              const SizedBox(height: 20),

              // Section: About & Compliance
              _buildSectionHeader('ABOUT MUSI'),
              _buildSettingsTile(
                icon: Icons.verified_user_rounded,
                title: 'Legal & Permitted Sources',
                subtitle: 'Musi strictly uses Creative Commons and open-source APIs. No DRM circumvention or unauthorized scraping.',
                onTap: _showLegalInfo,
              ),
              _buildSettingsTile(
                icon: Icons.info_outline_rounded,
                title: 'App Version',
                subtitle: 'Musi v1.0.0 (Production Release)',
                onTap: _showVersionInfo,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: AppTheme.primaryLight,
        ),
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: Icon(icon, color: AppTheme.textPrimary),
          title: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
          trailing: onTap == null
              ? null
              : const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.textMuted,
                ),
          onTap: onTap,
        ),
      ),
    );
  }

  Widget _buildSleepTimerTile() {
    final playerService = PlayerService();
    return ListenableBuilder(
      listenable: playerService,
      builder: (context, _) {
        final remaining = playerService.sleepTimerRemaining;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: AppTheme.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(
                Icons.bedtime_outlined,
                color: AppTheme.textPrimary,
              ),
              title: const Text(
                'Sleep Timer',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              subtitle: Text(
                remaining == null
                    ? 'Pause playback after a set time'
                    : 'Playback pauses in ${_formatSleepDuration(remaining)}',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
              trailing: remaining == null
                  ? const Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.textMuted,
                    )
                  : IconButton(
                      tooltip: 'Cancel sleep timer',
                      onPressed: playerService.cancelSleepTimer,
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.primaryLight,
                      ),
                    ),
              onTap: _showCustomSleepTimerDialog,
            ),
          ),
        );
      },
    );
  }

  String _formatSleepDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainder = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${remainder.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }

  Future<void> _showCustomSleepTimerDialog() async {
    final minutesController = TextEditingController(text: '30');
    final minutes = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surfaceCard,
        title: const Text('Custom Sleep Timer'),
        content: TextField(
          controller: minutesController,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 3,
          decoration: const InputDecoration(
            labelText: 'Minutes',
            helperText: 'Choose 1 to 720 minutes',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(minutesController.text.trim());
              if (value == null || value < 1 || value > 720) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Enter a duration from 1 to 720 minutes.'),
                    backgroundColor: AppTheme.surfaceCard,
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext, value);
            },
            child: const Text('Start'),
          ),
        ],
      ),
    );
    minutesController.dispose();
    if (!mounted || minutes == null) return;
    PlayerService().startSleepTimer(Duration(minutes: minutes));
  }

  void _showDownloadStorageInfo() {
    _showInfoDialog(
      'Downloaded music',
      '$_downloadsSizeFormatted is stored in Musi’s private app storage. Downloads are preserved when you clear the temporary playback cache.',
    );
  }

  void _showLegalInfo() {
    _showInfoDialog(
      'Music sources',
      'Musi searches supported music providers and plays the streams they make available. Availability and playback rights depend on each provider and track.',
    );
  }

  void _showVersionInfo() {
    _showInfoDialog('Musi', 'Version 1.0.0');
  }

  void _showInfoDialog(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _showQualityPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Streaming Quality',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              ...[
                'Standard (128 kbps)',
                'High (256 kbps)',
                'Extreme (320 kbps)',
              ].map(
                (q) => ListTile(
                  title: Text(q),
                  trailing: _audioQuality == q
                      ? const Icon(Icons.check, color: AppTheme.accent)
                      : null,
                  onTap: () {
                    final previousQuality = _audioQuality;
                    setState(() => _audioQuality = q);
                    _settingsDao
                        .setAudioQuality(q)
                        .then((_) {
                          if (ctx.mounted) Navigator.pop(ctx);
                        })
                        .catchError((Object _) {
                          if (!mounted) return;
                          setState(() => _audioQuality = previousQuality);
                          _showSettingsError(
                            'Could not save streaming quality.',
                          );
                        });
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
