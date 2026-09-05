// 应用设置存储(由 React 版 utils/settings.ts 移植)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../i18n.dart';

enum AppTheme { light, dark }

class AppSettings {
  bool autoRun;
  AppTheme theme;
  String locale;

  AppSettings({
    this.autoRun = true,
    this.theme = AppTheme.light,
    this.locale = 'zh',
  });
}

class SettingsStore extends ChangeNotifier {
  bool autoRun = true;
  AppTheme theme = AppTheme.light;
  String locale = 'zh';
  bool loaded = false;
  bool demoLoaded = false;

  static final SettingsStore instance = SettingsStore._();
  SettingsStore._();

  Future<void> init() async {
    if (loaded) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/settings.json');
      if (await file.exists()) {
        final raw = await file.readAsString();
        final j = jsonDecode(raw);
        if (j is Map) {
          if (j['autoRun'] is bool) autoRun = j['autoRun'] as bool;
          final t = '${j['theme'] ?? ''}';
          if (t == 'dark') theme = AppTheme.dark;
          final l = '${j['locale'] ?? ''}';
          if (l.isNotEmpty) locale = l;
          if (j['demoLoaded'] == true) demoLoaded = true;
        }
      }
    } catch (e) {
      debugPrint('读取设置失败: $e');
    }
    loaded = true;
    L.load(locale);
    _write();
    notifyListeners();
  }

  void setAutoRun(bool v) {
    autoRun = v;
    _write();
    notifyListeners();
  }

  void setTheme(AppTheme t) {
    theme = t;
    _write();
    notifyListeners();
  }

  void setLocale(String l) {
    locale = l;
    L.load(l);
    _write();
    notifyListeners();
  }

  void setDemoLoaded() {
    if (demoLoaded) return;
    demoLoaded = true;
    _write();
    notifyListeners();
  }

  void _write() {
    final json = jsonEncode({
      'autoRun': autoRun,
      'theme': theme == AppTheme.dark ? 'dark' : 'light',
      'locale': locale,
      'demoLoaded': demoLoaded,
    });
    try {
      getApplicationSupportDirectory()
          .then((dir) async {
            final file = File('${dir.path}/settings.json');
            await file.writeAsString(json);
          })
          .catchError((e) {
            debugPrint('保存设置失败: $e');
          });
    } catch (_) {
      /* ignore */
    }
  }
}
