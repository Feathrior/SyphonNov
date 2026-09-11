; SyphonNov Windows installer script (NSIS 3.x, ASCII only)
; Build: makensis install.nsi  ->  dist\SyphonNov-0.5.2-Setup.exe
Unicode True

!include "MUI2.nsh"

Name "SyphonNov"
OutFile "dist\SyphonNov-0.5.2-Setup.exe"
InstallDir "$PROGRAMFILES64\SyphonNov"
InstallDirRegKey HKCU "Software\SyphonNov" "InstallDir"
RequestExecutionLevel admin

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\syphon_nov.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Run SyphonNov now"

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
  CreateDirectory "$SMPROGRAMS\SyphonNov"
  CreateShortcut "$SMPROGRAMS\SyphonNov\SyphonNov.lnk" "$INSTDIR\syphon_nov.exe"
  CreateShortcut "$DESKTOP\SyphonNov.lnk" "$INSTDIR\syphon_nov.exe"

  ; Uninstaller and registry uninstall info
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\SyphonNov" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov" "DisplayName" "SyphonNov"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov" "DisplayVersion" "0.5.2"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov" "Publisher" "Feathrior"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov" "DisplayIcon" "$INSTDIR\syphon_nov.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov" "NoRepair" 1
SectionEnd

Section "Uninstall" SEC_UNINSTALL
  ; Kill running app first to avoid locked files
  nsExec::Exec 'taskkill /f /im syphon_nov.exe'
  Sleep 500

  Delete "$DESKTOP\SyphonNov.lnk"
  Delete "$SMPROGRAMS\SyphonNov\SyphonNov.lnk"
  RMDir "$SMPROGRAMS\SyphonNov"

  Delete "$INSTDIR\uninstall.exe"
  RMDir /r "$INSTDIR"

  DeleteRegKey HKCU "Software\SyphonNov"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SyphonNov"
SectionEnd
