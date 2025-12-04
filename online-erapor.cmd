@echo off
setlocal EnableDelayedExpansion

REM Enable break handling
break on

REM Set up handler for Ctrl+C
if not defined HANDLER_SET (
    set HANDLER_SET=1
    REM When Ctrl+C is pressed, call :on_break
    set "SCRIPT_PATH=%~f0"
    REM Start a new cmd session with break enabled
    start "" /wait cmd /c ""%SCRIPT_PATH%" child"
)

:: Check for administrative privileges
@REM net session >nul 2>&1
@REM if %errorlevel% neq 0 (
@REM     echo This script requires administrative privileges.
@REM     echo Please run as administrator.
@REM     pause
@REM     exit /b
@REM )

REM Start Cloudflare tunnel in the background
echo Starting Cloudflare tunnel...
start "Cloudflare Tunnel" cmd /c "cloudflared tunnel --url localhost:8535 > cf_tunnel.log 2>&1"

REM Get the PID
set "CF_TUNNEL_PID="
for /f "skip=3 tokens=2" %%p in (
    'tasklist /fi "imagename eq cloudflared.exe" /fo table'
) do (
    set "CF_TUNNEL_PID=%%p"
    echo Cloudflare tunnel started with PID: !CF_TUNNEL_PID!
)

:: Ensure the tunnel process is killed when this script exits
if defined CF_TUNNEL_PID (
    ::goto :SetExitHandler
    rem Set up a handler to kill cloudflared when exiting
    rem Register a label to be called on script exit
    rem (Batch does not support true exit traps, so we handle it before every exit)
)

:: Try to extract the public URL, retry up to 3 times with 5 seconds wait
set "CF_URL="
set "RETRIES=3"
for /l %%r in (1,1,%RETRIES%) do (
    echo Attempt %%r of %RETRIES% to get tunnel URL...
    set "CF_URL="
    for /l %%a in (1,1,5) do (
        ping -n 3 127.0.0.1 >nul
        for /f "delims=" %%i in (
            'findstr /r /c:"https:\/\/.*\.trycloudflare\.com" cf_tunnel.log'
        ) do (
            for %%u in (%%i) do (
                echo %%u | findstr /b /c:"https://" >nul
                if !errorlevel! == 0 (
                    if /i "!CF_URL!"=="" (
                        set "CF_URL=%%u"
                        goto :found_url
                    )
                )
            )
        )
    )
    if not defined CF_URL (
        echo Tunnel URL not found, retrying in 5 seconds...
        ping -n 6 127.0.0.1 >nul
    ) else (
        goto :found_url
    )
)

:GetUnixTime
setlocal enableextensions
for /f %%x in ('wmic path win32_utctime get /format:list ^| findstr "="') do (
    set %%x)
set /a z=(14-100%Month%%%100)/12, y=10000%Year%%%10000-z
set /a ut=y*365+y/4-y/100+y/400+(153*(100%Month%%%100+12*z-3)+2)/5+Day-719469
set /a ut=ut*86400+100%Hour%%%100*3600+100%Minute%%%100*60+100%Second%%%100
endlocal & set "%1=%ut%" & goto :EOF

:found_url
echo Tunnel URL extraction complete.
if defined CF_URL (
    echo Tunnel URL: !CF_URL!
    
    REM Create backup of App.php with current timestamp using script folder as root
    set "SCRIPT_DIR=%~dp0"
    set "SCRIPT_DIR=!SCRIPT_DIR:~0,-1!"
    set "CONFIG_DIR=!SCRIPT_DIR!\wwwroot\app\Config"
    set "CONFIG_FILE=App.php"
    set "DATETIME="
    call :GetUnixTime UNIX_TIME
    set "TIMESTAMP=!UNIX_TIME!"
    set "BACKUP_FILE=!CONFIG_DIR!\App_!TIMESTAMP!.php"

    if exist "!CONFIG_DIR!\!CONFIG_FILE!" (
        copy "!CONFIG_DIR!\!CONFIG_FILE!" "!BACKUP_FILE!" >nul
        echo Backup created: !BACKUP_FILE!
    ) else (
        echo Config file not found: !CONFIG_DIR!\!CONFIG_FILE!
    )

    REM Modify the existing config file (App.php) to update the tunnel URL

    set "NEW_URL=!CF_URL!"
    set "CONFIG_PATH=!CONFIG_DIR!\!CONFIG_FILE!"

    REM Use a temporary file for safe editing
    set "TEMP_FILE=!CONFIG_DIR!\App_temp.php"

    REM Replace the line containing 'public $baseURL' with the new tunnel URL
    REM Launch a new terminal shell to perform the config file update
    setlocal EnableDelayedExpansion
    null > "!TEMP_FILE!"
    for /f "delims=" %%a in ('type "!CONFIG_PATH!"') do (
        @echo %%a | findstr /c:"public string $baseURL" >nul 2>&1
        if !errorlevel! == 0 (
            @echo     public string $baseURL = '!NEW_URL!'; >> "!TEMP_FILE!" 2>nul
        ) else (
            @echo %%a >> "!TEMP_FILE!" 2>nul
        )
    )
    move /y "!TEMP_FILE!" "!CONFIG_PATH!" >nul
    endlocal

    echo Updated !CONFIG_FILE! with new tunnel URL.

    echo The new URL is: !NEW_URL!
    echo You can access your application at: !NEW_URL!
    start "" "!NEW_URL!"
    echo Press any key to exit...
    pause >nul
) else (
    echo Tunnel URL not found.
)
pause


:on_break
echo Ctrl+C detected! Cleaning up...
if defined CF_TUNNEL_PID (
    goto :SetExitHandler
)

:SetExitHandler
:: Set up a trap to kill the cloudflared process on exit
set "EXIT_HANDLER="
for /f "tokens=2" %%i in ('tasklist ^| findstr /i "cloudflared.exe"') do (
    set "EXIT_HANDLER=taskkill /F /PID %CF_TUNNEL_PID%"
)
if defined EXIT_HANDLER (
    echo Setting up exit handler to kill cloudflared process...
    call :trap_exit
) else (
    echo No cloudflared process found to kill.
)
goto :eof

:trap_exit
REM Kill the cloudflared process if running
if defined CF_TUNNEL_PID (
    echo Killing cloudflared process with PID: %CF_TUNNEL_PID%
    taskkill /F /PID %CF_TUNNEL_PID% >nul 2>&1
)
:: Wait for user input before exiting
echo Press any key to exit...
pause >nul
exit /b
