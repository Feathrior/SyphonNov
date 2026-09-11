# Flutter SDK 路径迁移验证

日期：2026-09-09。

- 原路径：`C:\Users\wsqq2\Documents\ChatGPT\Obsidian++\.syphon-tools\flutter`
- 新路径：`C:\Users\wsqq2\develop\flutter`
- Flutter：3.47.2 stable，revision `d3b14c8769`
- Dart：3.13.2
- DevTools：2.60.0
- 项目 Pub 缓存：`C:\Users\wsqq2\Documents\ChatGPT\Obsidian++\.syphon-tools\pub-cache`

迁移前确认新目录不存在，解析并核对了源路径和目标路径；SDK 在同一磁盘卷内移动。迁移后确认旧目录不存在、新目录含 `bin/flutter.bat`。`C:\Users\wsqq2\develop\flutter\bin` 已放在当前用户 PATH 首位；重新读取用户和机器 PATH 后，`where flutter` 同时找到无扩展名入口和 `flutter.bat`，均位于新目录。

项目 `scripts/verify.ps1` 已改为优先检测 `%USERPROFILE%\develop\flutter`，并与工作区 Pub 缓存解耦；仍接受 `-FlutterRoot` / `SYPHON_FLUTTER_ROOT`，也保留旧路径和系统 PATH 的兼容回退。脚本保留 UTF-8 BOM，Windows PowerShell 5.1 解析错误数为 0。

迁移后实际运行：

```powershell
./scripts/verify.ps1 -Build
```

结果：依赖解析成功，静态分析无问题，**111/111 测试通过**，Windows Release 构建成功，编译阶段报告 38.0 秒，产物为 `build/windows/x64/runner/Release/syphon_nov.exe`。

用户 PATH 的永久修改只会由新启动的终端和编辑器自动继承；已经打开的终端需要关闭后重新打开。项目验证脚本不依赖终端刷新，因为它会直接发现新 SDK 路径。

