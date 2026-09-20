; NSIS installer for the NyaSmsForward Windows client.
;
; NOTE: this file must stay UTF-8 *with BOM* (see .editorconfig): NSIS reads a BOM-less file as the system code page
; and rejects the Chinese strings below as "Bad text encoding".
;
; Build (scripts/build-release.ps1 does this for you):
;   makensis /DVERSION=0.1.0 /DSOURCE_DIR=<flutter Release dir> /DOUTFILE=<installer.exe> /DICON=<app_icon.ico> installer\nyasmsforward-client.nsi
;
; The installer is per-machine (needs admin), 64-bit only, and upgrades in place: it reuses the previous install
; folder and asks the user to quit a running instance first. User data (settings, token) lives in the user profile
; and is deliberately left alone by the uninstaller.

Unicode true
ManifestDPIAware true
SetCompressor /SOLID lzma

!ifndef VERSION
  !error "Pass /DVERSION=MAJOR.MINOR.PATCH"
!endif
!ifndef SOURCE_DIR
  !error "Pass /DSOURCE_DIR=<Flutter Release output directory>"
!endif
!ifndef OUTFILE
  !define OUTFILE "NyaSmsForward-Client_${VERSION}_x64-setup.exe"
!endif

!define APP_NAME "NyaSmsForward"
!define APP_EXE "NyaSmsForward.exe"
!define COMPANY "NyaSmsForward"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "WinVer.nsh"

Name "${APP_NAME}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\${APP_NAME}"
InstallDirRegKey HKLM "${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel admin
ShowInstDetails show
BrandingText "${APP_NAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIFileVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "CompanyName" "${COMPANY}"
VIAddVersionKey "LegalCopyright" "Copyright (C) 2026 ${COMPANY}"
VIAddVersionKey "FileDescription" "${APP_NAME} Installer"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"

!ifdef ICON
  !define MUI_ICON "${ICON}"
  !define MUI_UNICON "${ICON}"
!endif
!define MUI_ABORTWARNING
; The installer runs elevated; launching the app directly would start it as administrator too. Going through
; explorer.exe starts it with the normal user's rights (and the normal user's credential store).
!define MUI_FINISHPAGE_RUN ""
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchAsUser
!define MUI_FINISHPAGE_RUN_TEXT "$(RunAppText)"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

LangString RunAppText ${LANG_SIMPCHINESE} "立即运行 ${APP_NAME}"
LangString RunAppText ${LANG_ENGLISH} "Run ${APP_NAME} now"
LangString NeedWin10 ${LANG_SIMPCHINESE} "${APP_NAME} 需要 64 位 Windows 10 或更高版本。"
LangString NeedWin10 ${LANG_ENGLISH} "${APP_NAME} requires 64-bit Windows 10 or later."
LangString AppRunning ${LANG_SIMPCHINESE} "${APP_NAME} 正在运行。请先退出它（也要退出系统托盘里的图标），然后点击“重试”继续。"
LangString AppRunning ${LANG_ENGLISH} "${APP_NAME} is running. Please quit it (including its tray icon) and click Retry to continue."

Function LaunchAsUser
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\${APP_EXE}"'
FunctionEnd

; 0 when the app is running.
Function IsAppRunning
  nsExec::Exec 'cmd /c tasklist /FI "IMAGENAME eq ${APP_EXE}" /NH | find /I "${APP_EXE}"'
FunctionEnd

Function EnsureAppClosed
  ${Do}
    Call IsAppRunning
    Pop $0
    ${If} $0 != 0
      ${Break}
    ${EndIf}
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "$(AppRunning)" IDRETRY +2
    Abort
  ${Loop}
FunctionEnd

Function .onInit
  ${IfNot} ${RunningX64}
  ${OrIfNot} ${AtLeastWin10}
    MessageBox MB_OK|MB_ICONSTOP "$(NeedWin10)"
    Abort
  ${EndIf}
  SetRegView 64
FunctionEnd

Function un.onInit
  SetRegView 64
FunctionEnd

Section "Install"
  Call EnsureAppClosed

  SetOutPath "$INSTDIR"
  ; On upgrade, drop files of the previous version first so nothing stale (old DLLs, old assets) is left behind.
  RMDir /r "$INSTDIR\data"
  File /r "${SOURCE_DIR}\*.*"

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk" "$INSTDIR\uninstall.exe"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "${COMPANY}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Call un.EnsureAppClosed

  Delete "$DESKTOP\${APP_NAME}.lnk"
  RMDir /r "$SMPROGRAMS\${APP_NAME}"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "${UNINST_KEY}"
  ; The app can register itself to start with Windows (settings page); do not leave that behind.
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "NyaSmsForward"
SectionEnd

; The uninstaller needs its own copy of the helpers (NSIS keeps install and uninstall functions separate).
Function un.IsAppRunning
  nsExec::Exec 'cmd /c tasklist /FI "IMAGENAME eq ${APP_EXE}" /NH | find /I "${APP_EXE}"'
FunctionEnd

Function un.EnsureAppClosed
  ${Do}
    Call un.IsAppRunning
    Pop $0
    ${If} $0 != 0
      ${Break}
    ${EndIf}
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "$(AppRunning)" IDRETRY +2
    Abort
  ${Loop}
FunctionEnd
