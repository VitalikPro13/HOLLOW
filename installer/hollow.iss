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

[InstallDelete]
; The anti-censorship tunnel client, removed in 0.12. [Files] never deletes, so
; an upgrade would otherwise leave the old binary next to the app.
Type: files; Name: "{app}\shoes.exe"

[Files]
; Bundle the signed Release folder (exe, dlls, data/, etc.).
; Exclude build/link artifacts and any local debug log that must NOT ship to users,
; and any profile data or portable marker: one moves every install onto it (#155).
; build_release.ps1 refuses a Release folder holding them before this runs. No
; createallsubdirs: it still creates an EXCLUDED folder, empty (seen with hollow_data).
Source: "{#SourceDir}\*"; DestDir: "{app}"; \
    Excludes: "*.lib,*.exp,*.pdb,hollow_debug.log,hollow_crash.log,*.log,\hollow_data\,\hollow_data\*,*.db,*.db-wal,*.db-shm,hollow.lock,identity.*,portable,portable.txt,portable.txt.txt"; \
    Flags: ignoreversion recursesubdirs

[Registry]
; hollow:// URL protocol — per-user (HKCU, no admin needed). Lets browsers and
; other apps open Hollow deep links (server invites, shares, recovery links).
; The app also self-heals these keys at startup (deep_link_service.dart), which
; covers portable-zip users; the installer entries make the handler exist before
; first launch and get cleaned up on uninstall.
Root: HKCU; Subkey: "Software\Classes\hollow"; ValueType: string; ValueData: "URL:Hollow Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\hollow"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\hollow\DefaultIcon"; ValueType: string; ValueData: """{app}\{#AppExeName}"",0"
Root: HKCU; Subkey: "Software\Classes\hollow\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExeName}"" ""%1"""

[Icons]
; AppUserModelID must match desktop_notification_service.dart, or Windows
; toasts lose the app name and grouping.
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; AppUserModelID: "com.anonlisten.hollow"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; AppUserModelID: "com.anonlisten.hollow"; Tasks: desktopicon

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

{ ---- #155: profile data beside the exe ----
  Setups 0.12.1 to 0.14.1 shipped the build machine's hollow_data\messages.db and
  hollow.lock, and their uninstall logs (unins000.dat) still name both: an uninstall
  would delete the database of anyone whose own profile now lives in that folder. }

const
  StrayDbSize = 475136;
  StrayDbSha256 = 'c69bfe5028c930ad5e69fab0ae3977f45d269ea758437473707d728d0b0e7499';
  StrayLockSha256 = '9614e2d3d87b46db466fc1ee4d7cbe57ee95a24458c311796db423364a54eff1';
  KeptSuffix = '.kept-by-uninstall';

var
  { Where the uninstall set a profile aside, '' when it did not. }
  KeptDir: String;

function PortableDir: String;
begin
  Result := ExpandConstant('{app}\hollow_data');
end;

{ Any identity.* file: a key, a device, a locked or wrapped copy. }
function HoldsIdentity(Dir: String): Boolean;
var
  F: TFindRec;
begin
  Result := FindFirst(AddBackslash(Dir) + 'identity.*', F);
  if Result then
    FindClose(F);
end;

{ True only for the exact bytes the old setups shipped: same size and SHA-256. }
function IsShippedFile(Path: String; Size: Integer; Sha256: String): Boolean;
var
  Actual: Integer;
begin
  Result := False;
  if not FileExists(Path) then
    exit;
  if not FileSize(Path, Actual) then
    exit;
  if Actual <> Size then
    exit;
  try
    Result := CompareText(GetSHA256OfFile(Path), Sha256) = 0;
  except
    Result := False;
  end;
end;

function IsShippedDb(Path: String): Boolean;
begin
  Result := IsShippedFile(Path, StrayDbSize, StrayDbSha256);
end;

{ Removes what the old setups shipped, from a folder holding no identity; a
  database that differs is someone's and stays. RemoveDir only takes an empty folder. }
procedure RemoveShippedStray;
var
  Dir: String;
  Removed: Boolean;
begin
  Dir := PortableDir;
  if not DirExists(Dir) or HoldsIdentity(Dir) then
    exit;
  Removed := False;
  if IsShippedDb(Dir + '\messages.db') then
    Removed := DeleteFile(Dir + '\messages.db') or Removed;
  if IsShippedFile(Dir + '\hollow.lock', 5, StrayLockSha256) then
    Removed := DeleteFile(Dir + '\hollow.lock') or Removed;
  if Removed then
    RemoveDir(Dir);
end;

{ A folder that is someone's profile: an identity, or a database that is not the
  shipped one. }
function IsSomeonesProfile(Dir: String): Boolean;
begin
  Result := DirExists(Dir) and (HoldsIdentity(Dir) or
    (FileExists(Dir + '\messages.db') and not IsShippedDb(Dir + '\messages.db')));
end;

{ ---- Install side: close a running instance before copying files (upgrades) ---- }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  KillHollow;
  RemoveShippedStray;
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
  N: Integer;
begin
  { Before the logged files go: a profile in <app>\hollow_data steps aside, so the
    old setups' log entries find nothing to delete, and comes back afterwards. }
  if CurUninstallStep = usUninstall then
  begin
    KeptDir := '';
    if IsSomeonesProfile(PortableDir) then
    begin
      KeptDir := PortableDir + KeptSuffix;
      N := 2;
      while DirExists(KeptDir) or FileExists(KeptDir) do
      begin
        KeptDir := PortableDir + KeptSuffix + '-' + IntToStr(N);
        N := N + 1;
      end;
      if not RenameFile(PortableDir, KeptDir) then
      begin
        Log('#155: could not set the profile in ' + PortableDir + ' aside');
        KeptDir := '';
      end;
    end;
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    if (KeptDir <> '') and not DirExists(PortableDir) then
      if not RenameFile(KeptDir, PortableDir) then
        Log('#155: the profile stays in ' + KeptDir);
    DataDir := ExpandConstant('{userappdata}\Hollow');
    if DirExists(DataDir) then
    begin
      { Default is "No" — never delete identity/messages by accident. A plain MsgBox
        ignores /SUPPRESSMSGBOXES and hung every silent uninstall here. }
      if SuppressibleMsgBox('Do you also want to permanently delete your Hollow data and identity?' #13#10 #13#10
                + 'This removes your account key, messages, and all local data in:' #13#10
                + DataDir + #13#10 #13#10
                + 'This CANNOT be undone. Choose No to keep your data for a future reinstall.',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
      begin
        DelTree(DataDir, True, True, True);
      end;
    end;
  end;
end;
