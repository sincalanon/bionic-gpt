; Inno Setup script for the Bionic Windows installer.
; Built by .github/workflows/windows-installer.yml:
;   ISCC.exe /DAppVersion=1.13.8 /DStageDir=C:\stage packaging\windows\bionic.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #define StageDir "..\..\stage"
#endif

[Setup]
AppId={{6C1B3B8E-2D3F-4E61-9C55-B10A1C0B1E01}
AppName=Bionic
AppVersion={#AppVersion}
AppPublisher=Bionic (bionic-gpt.com)
AppPublisherURL=https://bionic-gpt.com
DefaultDirName={autopf}\Bionic
DefaultGroupName=Bionic
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=Bionic-Setup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
LicenseFile={#StageDir}\LICENCE.txt
UninstallDisplayName=Bionic {#AppVersion}

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Start Bionic"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\start-bionic.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\bionic.ico"
Name: "{group}\Stop Bionic"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\stop-bionic.ps1"""; WorkingDir: "{app}"
Name: "{group}\选择 GGUF 模型"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\start-bionic.ps1"" -PickModel"; WorkingDir: "{app}"; IconFilename: "{app}\bionic.ico"
Name: "{group}\Bionic logs"; Filename: "{commonappdata}\Bionic\logs"
Name: "{group}\Uninstall Bionic"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Bionic"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\start-bionic.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\bionic.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\start-bionic.ps1"""; WorkingDir: "{app}"; Description: "Start Bionic now"; Flags: postinstall nowait skipifsilent runhidden

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\stop-bionic.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "StopBionic"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  { Stop a running copy before files are replaced on upgrade. }
  if (CurStep = ssInstall) and FileExists(ExpandConstant('{app}\stop-bionic.ps1')) then
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\stop-bionic.ps1') + '"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
