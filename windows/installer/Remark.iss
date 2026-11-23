; Remark for Windows — Inno Setup script.
; Built by .github/workflows/windows.yml:
;   ISCC /DAppVersion=0.4.0 /DSourceDir=<publish dir> /DOutputDir=<dist dir> Remark.iss

#ifndef AppVersion
  #define AppVersion "0.4.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\publish\win-x64"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={{6C2F0B7E-4A1D-4C8E-9E3B-7A5D2F8C1B90}
AppName=Remark
AppVersion={#AppVersion}
AppVerName=Remark {#AppVersion}
AppPublisher=Ezinne Kalu
AppPublisherURL=https://github.com/zikk090/remark
AppSupportURL=https://github.com/zikk090/remark/issues
DefaultDirName={localappdata}\Programs\Remark
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=Remark-Setup-{#AppVersion}
SetupIconFile=..\Remark\Assets\Remark.ico
UninstallDisplayIcon={app}\Remark.exe
UninstallDisplayName=Remark
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "autostart"; Description: "Open Remark when I sign in"
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Remark"; Filename: "{app}\Remark.exe"
Name: "{autodesktop}\Remark"; Filename: "{app}\Remark.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Remark"; \
  ValueData: """{app}\Remark.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\Remark.exe"; Description: "Launch Remark"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM Remark.exe /F"; Flags: runhidden; RunOnceId: "StopRemark"
