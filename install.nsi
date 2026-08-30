; SyphonNov2 Windows installer script (NSIS 3.x, ASCII only)
; Build: makensis install.nsi  ->  dist\SyphonNov2_Setup.exe
Unicode True

!include "MUI2.nsh"

Name "SyphonNov2"
OutFile "dist\SyphonNov2_Setup.exe"
InstallDir "$PROGRAMFILES64\SyphonNov2"
InstallDirRegKey HKCU "Software\SyphonNov2" "InstallDir"
RequestExecutionLevel admin

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\syphon_nov.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Run SyphonNov2 now"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

Section "Install" SEC_MAIN
  SetOutPath "$INSTDIR"
  ; Deploy all Flutter Release artifacts (exe/dll/data recursive)
  File /r "build\windows\x64\runner\Release\*.*"

  ; Start menu and desktop shortcuts
  CreateDirectory "$SMPROGRAMS\SyphonNov2"
  CreateShortcut "$SMPROGRAMS\SyphonNov2\SyphonNov2.lnk" "$INSTDIR\syphon_nov.exe"
  CreateShortcut "$DESKTOP\SyphonNov2.lnk" "$INSTDIR\syphon_nov.exe"

  ; Uninstaller and registry uninstall info
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\SyphonNov2" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov2" "DisplayName" "SyphonNov2"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov2" "DisplayVersion" "1.0.0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov2" "Publisher" "Syphon"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov2" "DisplayIcon" "$INSTDIR\syphon_nov.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov2" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov2" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov2" "NoRepair" 1
SectionEnd

Section "Uninstall" SEC_UNINSTALL
  ; Kill running app first to avoid locked files
  nsExec::Exec 'taskkill /f /im syphon_nov.exe'
  Sleep 500

  Delete "$DESKTOP\SyphonNov2.lnk"
  Delete "$SMPROGRAMS\SyphonNov2\SyphonNov2.lnk"
  RMDir "$SMPROGRAMS\SyphonNov2"

  Delete "$INSTDIR\uninstall.exe"
  RMDir /r "$INSTDIR"

  DeleteRegKey HKCU "Software\SyphonNov2"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov2"
SectionEnd
