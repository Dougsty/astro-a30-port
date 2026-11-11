; A30 Control for Windows — per-user setup (no admin rights needed).
; Built on the Mac by build.sh:  makensis -DVERSION=x.y.z -DEXE=path\to\A30Control.exe A30Control.nsi
Unicode true
!include "MUI2.nsh"
!include "Sections.nsh"

!ifndef VERSION
  !define VERSION "1.0.0"
!endif
!ifndef EXE
  !define EXE "../dist/A30Control.exe"
!endif
!define APP "A30 Control"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\A30Control"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"

Name "${APP}"
OutFile "../dist/A30Control-Setup-${VERSION}.exe"
InstallDir "$LOCALAPPDATA\Programs\${APP}"
InstallDirRegKey HKCU "${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "${APP} ${VERSION}"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "FileDescription" "${APP} setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Unofficial; not affiliated with Logitech"

!define MUI_ICON "../A30Control/Assets/app.ico"
!define MUI_UNICON "../A30Control/Assets/app.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\A30Control.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Start ${APP} now"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; The app holds the headset's control channel: close a running copy before replacing or removing it.
!macro CloseApp
  nsExec::Exec 'taskkill /F /IM A30Control.exe'
  Pop $0
  Sleep 500
!macroend

Section "${APP}" SecApp
  SectionIn RO
  !insertmacro CloseApp
  SetOutPath "$INSTDIR"
  File "/oname=A30Control.exe" "${EXE}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\${APP}.lnk" "$INSTDIR\A30Control.exe"
  ; Apps & features entry
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "Dougsty"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\A30Control.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" 80000
SectionEnd

; Same Run value the app's "Start with Windows" toggle reads and writes.
Section "Start with Windows" SecAutostart
  WriteRegStr HKCU "${RUN_KEY}" "A30Control" '"$INSTDIR\A30Control.exe" --autostart'
SectionEnd

Section /o "Desktop shortcut" SecDesktop
  CreateShortcut "$DESKTOP\${APP}.lnk" "$INSTDIR\A30Control.exe"
SectionEnd

; Silent updates (/S, started by the app) keep the user's autostart choice and restart the app.
Function .onInit
  IfSilent 0 keep
    ReadRegStr $0 HKCU "${RUN_KEY}" "A30Control"
    StrCmp $0 "" 0 keep
      !insertmacro UnselectSection ${SecAutostart}
  keep:
FunctionEnd

Function .onInstSuccess
  IfSilent 0 +2
    Exec '"$INSTDIR\A30Control.exe"'
FunctionEnd

Section "Uninstall"
  !insertmacro CloseApp
  DeleteRegValue HKCU "${RUN_KEY}" "A30Control"
  DeleteRegKey HKCU "${UNINST_KEY}"
  Delete "$SMPROGRAMS\${APP}.lnk"
  Delete "$DESKTOP\${APP}.lnk"
  Delete "$INSTDIR\A30Control.exe"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  ; Settings and the log in %APPDATA%\A30Control are kept on purpose (reinstall keeps profiles).
SectionEnd
