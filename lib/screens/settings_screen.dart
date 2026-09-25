import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../database/settings_dao.dart';
import '../services/download_service.dart';
import '../services/music_provider_manager.dart';
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
  bool _jamendoEnabled = true;
  bool _youtubeEnabled = true;
  bool _openLicensedEnabled = true;
  String _cacheSizeFormatted = 'Calculating...';
  String _downloadsSizeFormatted = 'Calculating...';

  @override
  void initState() {
    super.initState();
    _loadSettingsAndStorageSizes();
  }

  void _loadSettingsAndStorageSizes() async {
    await _providerManager.initialize();
    final quality = await _settingsDao.getAudioQuality();
    final offline = await _settingsDao.getOfflineMode();
    final volume = await _settingsDao.getNormalizeVolume();

    final cacheBytes = await _calculateCacheBytes();
    final downloadBytes = await _downloadService.getDownloadedBytes();

    if (mounted) {
      setState(() {
        _audioQuality = quality;
        _offlineModeOnly = offline;
        _normalizeVolume = volume;
        _jamendoEnabled = _providerManager.isProviderEnabled('jamendo');
        _youtubeEnabled = _providerManager.isProviderEnabled('youtube');
        _openLicensedEnabled = _providerManager.isProviderEnabled('mock');
        _cacheSizeFormatted = _formatBytes(cacheBytes);
        _downloadsSizeFormatted = _formatBytes(downloadBytes);
      });
    }
  }

  Future<void> _setProviderEnabled(String providerId, bool enabled) async {
    setState(() {
      if (providerId == 'jamendo') _jamendoEnabled = enabled;
      if (providerId == 'youtube') _youtubeEnabled = enabled;
      if (providerId == 'mock') _openLicensedEnabled = enabled;
    });
    try {
      if (providerId == 'youtube') {
        await _providerManager.setYouTubeEnabled(enabled);
      } else {
        await _providerManager.setProviderEnabled(providerId, enabled);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save source settings.'),
            backgroundColor: AppTheme.surfaceCard,
          ),
        );
      }
    }
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
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        children: [
          // Section: Audio & Playback
          _buildSectionHeader('AUDIO & PLAYBACK'),
          _buildSettingsTile(
            icon: Icons.high_quality_rounded,
            title: 'Streaming Quality',
            subtitle: _audioQuality,
            onTap: _showQualityPicker,
          ),
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
              setState(() => _normalizeVolume = val);
              _settingsDao.setNormalizeVolume(val);
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
              setState(() => _offlineModeOnly = val);
              _settingsDao.setOfflineMode(val);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    val ? 'Offline Mode enabled' : 'Offline Mode disabled',
                  ),
                  backgroundColor: AppTheme.surfaceCard,
                  duration: const Duration(milliseconds: 1500),
                ),
              );
            },
          ),

          const SizedBox(height: 20),

          // Section: Music Sources
          _buildSectionHeader('MUSIC SOURCES'),
          SwitchListTile(
            secondary: const Icon(
              Icons.library_music_rounded,
              color: AppTheme.textPrimary,
            ),
            title: const Text(
              'Jamendo',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
            subtitle: const Text(
              'Creative Commons music discovery and playback',
              style: TextStyle(color: AppTheme.textMuted),
            ),
            value: _jamendoEnabled,
            activeThumbColor: AppTheme.accent,
            onChanged: (value) => _setProviderEnabled('jamendo', value),
          ),
          SwitchListTile(
            secondary: const Icon(
              Icons.video_library_rounded,
              color: AppTheme.textPrimary,
            ),
            title: const Text(
              'YouTube',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
            subtitle: Text(
              'YouTube Music search and playback (Android-only, Python bridge)',
              style: const TextStyle(color: AppTheme.textMuted),
            ),
            value: _youtubeEnabled,
            activeThumbColor: AppTheme.accent,
            onChanged: (value) => _setProviderEnabled('youtube', value),
          ),
          SwitchListTile(
            secondary: const Icon(
              Icons.shield_moon_rounded,
              color: AppTheme.textPrimary,
            ),
            title: const Text(
              'Open Licensed Sources',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
            subtitle: const Text(
              'Built-in public domain and Creative Commons catalog',
              style: TextStyle(color: AppTheme.textMuted),
            ),
            value: _openLicensedEnabled,
            activeThumbColor: AppTheme.accent,
            onChanged: (value) => _setProviderEnabled('mock', value),
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
            subtitle: '$_downloadsSizeFormatted stored in app-private storage',
            onTap: () {},
          ),

          const SizedBox(height: 20),

          // Section: About & Compliance
          _buildSectionHeader('ABOUT MUSI'),
          _buildSettingsTile(
            icon: Icons.verified_user_rounded,
            title: 'Legal & Permitted Sources',
            subtitle: 'Musi strictly uses Creative Commons and open-source APIs. No DRM circumvention or unauthorized scraping.',
            onTap: () {},
          ),
          _buildSettingsTile(
            icon: Icons.info_outline_rounded,
            title: 'App Version',
            subtitle: 'Musi v1.0.0 (Production Release)',
            onTap: () {},
          ),

          const SizedBox(height: 90),
        ],
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
    required VoidCallback onTap,
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
          trailing: const Icon(
            Icons.chevron_right_rounded,
            color: AppTheme.textMuted,
          ),
          onTap: onTap,
        ),
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
                    setState(() => _audioQuality = q);
                    _settingsDao.setAudioQuality(q);
                    Navigator.pop(ctx);
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
