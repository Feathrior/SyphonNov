// 应用设置存储(由 React 版 utils/settings.ts 移植)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../i18n.dart';

enum AppTheme { light, dark }

enum MotionMode { full, reduced, off }

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
  MotionMode motionMode = MotionMode.full;
  bool snapNodePlacement = false;
  List<String> favoriteNodeIds = [];
  List<String> recentNodeIds = [];

  /// 最近打开/保存的画布文件路径(新→旧,去重,最多 10 条)
  List<String> recentFiles = [];

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
          motionMode = MotionMode.values.firstWhere(
            (value) => value.name == j['motionMode'],
            orElse: () => MotionMode.full,
          );
          snapNodePlacement = j['snapNodePlacement'] == true;
          favoriteNodeIds = _stringList(j['favoriteNodeIds'], 24);
          recentNodeIds = _stringList(j['recentNodeIds'], 8);
          final rf = j['recentFiles'];
          if (rf is List) {
            recentFiles = rf.whereType<String>().take(10).toList();
          }
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

  void setMotionMode(MotionMode value) {
    motionMode = value;
    _write();
    notifyListeners();
  }

  void setSnapNodePlacement(bool value) {
    snapNodePlacement = value;
    _write();
    notifyListeners();
  }

  void toggleFavoriteNode(String configId) {
    favoriteNodeIds = favoriteNodeIds.contains(configId)
        ? favoriteNodeIds.where((id) => id != configId).toList()
        : [...favoriteNodeIds, configId];
    _write();
    notifyListeners();
  }

  void recordNodeUse(String configId) {
    recentNodeIds = [
      configId,
      ...recentNodeIds.where((id) => id != configId),
    ].take(8).toList();
    _write();
    notifyListeners();
  }

  static List<String> _stringList(dynamic value, int limit) => value is List
      ? value.whereType<String>().toSet().take(limit).toList()
      : <String>[];

  /// 记录最近文件:置顶去重,超出 10 条截断
  void addRecentFile(String path) {
    recentFiles = [
      path,
      ...recentFiles.where((p) => p != path),
    ].take(10).toList();
    _write();
    notifyListeners();
  }

  void _write() {
    final json = jsonEncode({
      'autoRun': autoRun,
      'theme': theme == AppTheme.dark ? 'dark' : 'light',
      'locale': locale,
      'demoLoaded': demoLoaded,
      'recentFiles': recentFiles,
      'motionMode': motionMode.name,
      'snapNodePlacement': snapNodePlacement,
      'favoriteNodeIds': favoriteNodeIds,
      'recentNodeIds': recentNodeIds,
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
