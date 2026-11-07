#define AppVersion "1.3.5"
[Setup]
AppId=NightwellMusicNative
AppName=Nightwell Music
AppVersion={#AppVersion}
AppPublisher=Nightwell
DefaultDirName={localappdata}\Programs\Nightwell Music
DefaultGroupName=Nightwell Music
PrivilegesRequired=lowest
OutputDir=..\setup-output
OutputBaseFilename=Nightwell-Music-Setup-1.3.5
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\Nightwell Music.exe
CloseApplications=yes
RestartApplications=no
[Files]
Source: "..\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Nightwell Music"; Filename: "{app}\Nightwell Music.exe"
Name: "{autodesktop}\Nightwell Music"; Filename: "{app}\Nightwell Music.exe"
[Run]
Filename: "{app}\Nightwell Music.exe"; Description: "Открыть Nightwell Music"; Flags: nowait postinstall skipifsilent

