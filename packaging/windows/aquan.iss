; 阿圈短剧 Windows 安装包（Inno Setup 6）
; 构建：ISCC.exe /DVersion=0.4.0 packaging\windows\aquan.iss
; 产物：build\aquan-windows-x64-<版本>-setup.exe

#ifndef Version
  #define Version "0.0.0-dev"
#endif

#define AppName "阿圈短剧"
#define AppExe "aquan_duanju.exe"
#define AppPublisher "阿圈短剧"
#define AppId "{{7F2A9C1E-4B3D-4E8A-9C5F-1D2E3F4A5B6C}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#Version}
AppVerName={#AppName} {#Version}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\aquan-duanju
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..\build
OutputBaseFilename=aquan-windows-x64-{#Version}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\{#AppExe}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "运行 {#AppName}"; Flags: nowait postinstall skipifsilent
