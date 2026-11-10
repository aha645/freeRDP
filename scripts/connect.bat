@echo off
chcp 65001 >nul
setlocal
rem 빌드한 sdl-freerdp.exe로 원격 데스크톱에 접속합니다.
rem   사용법: connect.bat <사용자ID> [서버주소:포트]
rem   예:     connect.bat aha
rem           connect.bat aha 127.0.0.1:13389
rem 서버 기본값은 SSH 터널 주소 127.0.0.1:13389 입니다. 비밀번호는 실행 중 입력합니다.

set "USER_ID=%~1"
set "SERVER=%~2"
if "%SERVER%"=="" set "SERVER=127.0.0.1:13389"
if "%USER_ID%"=="" (
  echo 사용법: connect.bat ^<사용자ID^> [서버주소:포트]
  exit /b 1
)

rem sdl-freerdp.exe 는 이 파일과 같은 폴더에 있어야 합니다.
set "EXE=%~dp0sdl-freerdp.exe"
if not exist "%EXE%" (
  echo 실행 파일이 없습니다: %EXE%
  echo connect.bat 과 sdl-freerdp.exe 를 같은 폴더에 두세요.
  exit /b 1
)

for /f "tokens=1,2 delims=:" %%a in ("%SERVER%") do (
  set "HOST=%%a"
  set "PORT=%%b"
)

rem 서버 포트가 열려 있는지 먼저 확인 (SSH 터널이 꺼져 있으면 바로 알림)
powershell -NoProfile -Command "$c=New-Object Net.Sockets.TcpClient; try { if ($c.ConnectAsync('%HOST%',%PORT%).Wait(3000) -and $c.Connected) { exit 0 } else { exit 1 } } catch { exit 1 } finally { $c.Close() }"
if errorlevel 1 (
  echo %SERVER% 에 연결할 수 없습니다.
  echo 다른 명령 프롬프트에서 아래 명령을 입력하여 터널링을 준비해주세요.
  echo.
  echo   ssh -N -i key_ed25519 -L %HOST%:%PORT%:127.0.0.1:3389 ^<서버사용자^>@^<서버주소^>
  echo.
  echo 터널이 열린 상태에서 다시 실행하세요.
  exit /b 1
)

rem /cert:ignore: SSH 터널(127.0.0.1)로 암호화된 연결에서 인증서 확인 질문으로 멈추는 것을 방지
"%EXE%" /v:%SERVER% /u:%USER_ID% /dynamic-resolution /cert:ignore
