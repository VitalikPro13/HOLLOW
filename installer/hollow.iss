; Inno Setup script for Hollow — per-user install, no admin required.
;
; Build:   ISCC.exe installer\hollow.iss
;   (or pass /DAppVersion=x.y.z to override the version)
;
; This script bundles the ALREADY-SIGNED build output from
;   build\windows\x64\runner\Release
; Sign the payload binaries FIRST (scripts\sign_release.ps1), then compile this,
; then sign the resulting setup.exe (scripts\sign_file.ps1).
;
; The full pipeline is automated by scripts\build_release.ps1.

#ifndef AppVersion
  #define AppVersion "0.5.0"
#endif

#define AppName "Hollow"
#define AppPublisher "AnonListen"
#define AppURL "https://anonlisten.com"
#define AppExeName "hollow.exe"
#define SourceDir "..\build\windows\x64\runner\Release"

[Setup]
; A stable AppId GUID — keep this CONSTANT across versions so upgrades/uninstall work.
AppId={{8F3A2C71-5E4D-4B9A-9C6E-1A7B2D8F0E33}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoProductName={#AppName}

; --- Per-user install, no admin/UAC ---
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#AppName}
DisableProgramGroupPage=yes
DefaultGroupName={#AppName}
; Show the branded Welcome page (off by default in modern style) so the banner has a home.
DisableWelcomePage=no

; --- Output ---
OutputDir=Output
OutputBaseFilename=hollow-{#AppVersion}-win64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

; --- Appearance / behavior ---
WizardStyle=modern
; Large banner: a fully OPAQUE bitmap that already contains its own dark gradient +
; glow. It is stretched to fill the whole left panel edge-to-edge (no seams, no
; floating box). Do NOT make this transparent — the backdrop is baked in.
WizardImageFile=assets\wizard_banner.bmp
; Small header logo: a TRANSPARENT H-mark. BackColor=none keeps the PNG's alpha so
; the wizard's own (white) header shows through instead of a dark square behind it.
; Two sizes for crisp multi-DPI.
WizardSmallImageBackColor=none
WizardSmallImageFile=assets\wizard_small.png,assets\wizard_small@2x.png
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ShowLanguageDialog=no
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; Bundle the signed Release folder (exe, dlls, data/, etc.).
; Exclude build/link artifacts and any local debug log that must NOT ship to users.
Source: "{#SourceDir}\*"; DestDir: "{app}"; \
    Excludes: "*.lib,*.exp,*.pdb,hollow_debug.log,hollow_crash.log,*.log"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
; "Launch Hollow now" checkbox at the end of the installer
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
{ Hollow runs in the system tray; its process keeps the install DLLs and the
  %APPDATA%\Hollow\hollow.lock file open. Both install (upgrade) and uninstall
  must terminate it first, otherwise files stay locked and removal is partial. }

procedure KillHollow;
var
  ResultCode: Integer;
begin
  { /F force, /IM by image name; /T also kills child processes. Ignore failure
    (process may not be running). Brief wait lets the OS release file handles. }
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM {#AppExeName}', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(700);
end;

{ ---- Install side: close a running instance before copying files (upgrades) ---- }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  KillHollow;
  Result := '';
end;

{ ---- Uninstall side ---- }
function InitializeUninstall(): Boolean;
begin
  { Close the tray app first so its DLLs / hollow.lock are released. }
  KillHollow;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{userappdata}\Hollow');
    if DirExists(DataDir) then
    begin
      { Default is "No" — never delete identity/messages by accident. }
      if MsgBox('Do you also want to permanently delete your Hollow data and identity?' #13#10 #13#10
                + 'This removes your account key, messages, and all local data in:' #13#10
                + DataDir + #13#10 #13#10
                + 'This CANNOT be undone. Choose No to keep your data for a future reinstall.',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      begin
        DelTree(DataDir, True, True, True);
      end;
    end;
  end;
end;
