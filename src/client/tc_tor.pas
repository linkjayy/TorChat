{ TorChat - TTor manages TorChat's own Tor process

  Copyright (C) 2012 Bernd Kreuss <prof7bit@gmail.com>

  This source is free software; you can redistribute it and/or modify it under
  the terms of the GNU General Public License as published by the Free
  Software Foundation; either version 3 of the License, or (at your option)
  any later version.

  This code is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
  details.

  A copy of the GNU General Public License is available on the World Wide Web
  at <http://www.gnu.org/copyleft/gpl.html>. You can also obtain it by writing
  to the Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
  MA 02111-1307, USA.
}
unit tc_tor;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  process,
  tc_interface;

type

  { TTor represents the tor proxy that we are using. It
    will either start its own tor process and via the
    functions TorHost and TorPort and HiddenServiceName
    we can access what we need to know about it or
    (depending on configuration) it will not start a tor
    process and instead do pretty much nothing except
    returning the configured values for the external tor
    proxy through the above mentioned functions.}
  TTor = class(TProcess)
  public
    constructor Create(AOwner: TComponent; AClient: IClient;
      AClientPort: DWord); reintroduce;
    destructor Destroy; override;
    function TorHost: String;
    function TorPort: DWord;
    function HiddenServiceName: String;
    procedure CleanShutdown;
  strict protected
    FClient: IClient;
    FClientListenPort: DWord;
    FSocksPort: DWord;
    procedure GenerateTorrc;
    procedure StartTorProcess;
    procedure KillIfAlreadyRunning;
  end;

implementation
uses
  {$ifdef unix}
  baseunix,
  {$endif}
  {$ifdef windows}
  windows,
  {$endif}
  sysutils,
  tc_misc;

{ TTor }

constructor TTor.Create(AOwner: TComponent; AClient: IClient;
  AClientPort: DWord);
begin
  inherited Create(AOwner);
  FClient := AClient;
  FClientListenPort := AClientPort;
  FSocksPort := FClient.Config.TorPort;
  StartTorProcess;
end;

destructor TTor.Destroy;
begin
  WriteLn('TTor.Destroy()');
  CleanShutdown;
  inherited Destroy;
end;

procedure TTor.GenerateTorrc;
var
  FileName: String;
  FOut: TFileStream = nil;
  FIn: TFileStream = nil;
  CustomSize : UInt64;
  Buffer: PChar = nil;

  procedure Line(L: String);
  begin
    L := L + LineEnding;
    FOut.WriteBuffer(L[1], Length(L));
  end;

begin
  FileName := ConcatPaths([CurrentDirectory, 'torrc.generated.txt']);
  try
    FOut := TFileStream.Create(FileName, fmCreate);
    Line('######################################################');
    Line('#                                                    #');
    Line('#   This file is auto-generated by TorChat.          #');
    Line('#   To change ports use the TorChat configuration.   #');
    Line('#                                                    #');
    Line('#   To add additional .torrc options like bridges    #');
    Line('#   etc. you can put them into torrc.in.txt and      #');
    Line('#   they will be automatically appended to the end   #');
    Line('#   of this file.                                    #');
    Line('#                                                    #');
    Line('######################################################');
    Line('PidFile tor.pid');
    Line('DataDirectory tor_data');
    Line('HiddenServiceDir hidden_service');
    Line(Format('SocksPort %d', [FSocksPort]));
    Line(Format('HiddenServicePort 11009 127.0.0.1:%d', [FClientListenPort]));
    Line('LongLivedPorts 11009');
    Line('AvoidDiskWrites 1');

    FileName := ConcatPaths([CurrentDirectory, 'torrc.in.txt']);
    try
      FIn := TFileStream.Create(FileName, fmOpenRead);
      CustomSize := FIn.Size;
      if CustomSize > 0 then begin
        Line('');
        Line('##');
        Line('## begin custom options copied from torrc.in.txt');
        Line('##');
        Line('');
        Buffer := GetMem(CustomSize);
        FIn.Read(Buffer[0], CustomSize);
        FOut.Write(Buffer[0], CustomSize);
      end;
    except
      WriteLn('I could not find or open '+ FileName
        + ' (this is ok if you don''t need custom torrc options)');
    end;
  except
    on E: Exception do begin
      WriteLn('E could not generate ' + FileName + ': ' + E.Message);
    end;
  end;

  if Assigned(FOut) then
    FreeAndNil(FOut);
  if Assigned(FIn) then
    FreeAndNil(FIn);
  if Assigned(Buffer) then
    FreeMem(Buffer);
end;

procedure TTor.StartTorProcess;
begin
  // it will automatically cd before starting the process if we set
  // the property 'CurrentDirectory' to a path:
  CurrentDirectory := ConcatPaths([FClient.Config.DataDir, 'tor']);
  WriteLn(_F('I profile "%s": Tor will be started in folder: %s',
    [FClient.ProfileName, CurrentDirectory]));
  KillIfAlreadyRunning;

  FSocksPort := FClient.Config.TorPort;
  while not IsPortAvailable(FSocksPort) do
    Dec(FSocksPort);
  WriteLn(_F('I profile "%s": Tor will open port %d for socks proxy',
    [FClient.ProfileName, FSocksPort]));

  Options := [poNewProcessGroup];
  Executable := FClient.Config.PathTorExe;
  GenerateTorrc;
  Parameters.Add('-f');
  Parameters.Add('torrc.generated.txt');
  try
    Execute;
  except
    on E: Exception do begin
      writeln('E could not start Tor process: ' + Executable);
      writeln('E ' + E.Message);
    end;
  end;
end;

procedure TTor.KillIfAlreadyRunning;
var
  FileSize: UInt64;
  Pid: THandle;
  HProc: THandle;
  PidStr: String;
  PidFile: TFileStream = nil;
  PidFileName: String;
begin
  PidFileName := ConcatPaths([CurrentDirectory, 'tor.pid']);
  if FileExists(PidFileName) then begin
    WriteLn('W old Tor process might still be running (tor.pid detected), trying to kill it');
    try
      PidFile := TFileStream.Create(PidFileName, fmOpenRead);
      FileSize := PidFile.Size;
      SetLength(PidStr, FileSize);
      PidFile.Read(PidStr[1], FileSize);
      FreeAndNil(PidFile);
      Pid := StrToInt64(Trim(PidStr));
      WriteLn('I sending kill signlal to PID ', Pid);
      {$ifdef windows}
        HProc := OpenProcess(PROCESS_TERMINATE, False, Pid);
        TerminateProcess(HProc, 0);
      {$else}
        FpKill(Pid, SIGKILL);
      {$endif}
      DeleteFile(PidFileName);
      Sleep(500);
    except
      WriteLn('E existing pid file could not be read');
    end;
    if Assigned(PidFile) then
      PidFile.Free;
  end;
end;

function TTor.TorHost: String;
begin
  Result := FClient.Config.TorHostName;
end;

function TTor.TorPort: DWord;
begin
  Result := FSocksPort;
end;

function TTor.HiddenServiceName: String;
var
  FileName: String;
  HostnameFile: TFileStream = nil;
const
  OnionLength = 16;
begin
  FileName := ConcatPaths([CurrentDirectory, 'hidden_service', 'hostname']);
  SetLength(Result, OnionLength);
  try
    HostnameFile := TFileStream.Create(FileName, fmOpenRead);
    if HostnameFile.Read(Result[1], OnionLength) < OnionLength then
      Result := '';
  except
    Result := '';
  end;
  if Assigned(HostnameFile) then FreeAndNil(HostnameFile);
end;

procedure TTor.CleanShutdown;
begin
  {$ifdef unix}
    FpKill(Handle, SIGINT); // Tor will exit cleanly on SIGINT
  {$else}
    // there are no signals in windows, they also forgot to
    // implement any other mechanism for sending Ctrl-C to
    // another process. We have to kill it.
    Terminate(0);
    DeleteFile(ConcatPaths([CurrentDirectory, 'tor.pid']));
  {$endif}
end;

end.

