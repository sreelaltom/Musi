import 'dart:async';

import 'package:flutter/material.dart';

import '../database/settings_dao.dart';

/// Small persisted UI preferences shared by every route in the app.
class UiPreferences extends ChangeNotifier {
  UiPreferences._();

  static final UiPreferences instance = UiPreferences._();

  final SettingsDao _settingsDao = SettingsDao();
  double _textScale = 1.0;
  Timer? _saveTimer;

  double get textScale => _textScale;

  Future<void> load() async {
    try {
      final stored = await _settingsDao.getSetting('ui_text_scale');
      final value = double.tryParse(stored ?? '');
      if (value != null) _textScale = value.clamp(0.85, 1.25).toDouble();
    } catch (error) {
      debugPrint('UiPreferences: could not load text size: $error');
    }
  }

  Future<void> setTextScale(double value) async {
    final normalized = value.clamp(0.85, 1.25).toDouble();
    if (_textScale != normalized) {
      _textScale = normalized;
      notifyListeners();
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), _persistTextScale);
  }

  Future<void> _persistTextScale() async {
    try {
      await _settingsDao.setSetting('ui_text_scale', _textScale.toString());
    } catch (error) {
      debugPrint('UiPreferences: could not save text size: $error');
    }
  }
}
