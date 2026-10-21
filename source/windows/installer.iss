[Setup]
AppId=NightwellMusicNative
AppName=Nightwell Music Native Preview
AppVersion=1.1.1
DefaultDirName={localappdata}\Programs\Nightwell Music Native
DefaultGroupName=Nightwell Music Native
PrivilegesRequired=lowest
OutputDir=output
OutputBaseFilename=Nightwell-Music-Native-Setup-1.1.1
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\Nightwell Music.exe
[Files]
Source: "publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Nightwell Music Native"; Filename: "{app}\Nightwell Music.exe"
Name: "{autodesktop}\Nightwell Music Native"; Filename: "{app}\Nightwell Music.exe"
[Run]
Filename: "{app}\Nightwell Music.exe"; Description: "Открыть Nightwell Music"; Flags: nowait postinstall skipifsilent
