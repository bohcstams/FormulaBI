@echo off
setlocal

set "ETL_DIR=%~dp0"
if "%ETL_DIR:~-1%"=="\" set "ETL_DIR=%ETL_DIR:~0,-1%"
for %%I in ("%ETL_DIR%\..") do set "PROJECT_DIR=%%~fI"

set "KITCHEN_DIR=C:\Pentaho\data-integration\data-integration"
set "JOB_FILE=%ETL_DIR%\job_weekly_update.kjb"
set "LOG_DIR=%ETL_DIR%\logs"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%I"
set "LOG_FILE=%LOG_DIR%\weekly_update_%TS%.log"

echo [%DATE% %TIME%] Ensuring PostgreSQL container is running... > "%LOG_FILE%"
docker compose -f "%PROJECT_DIR%\db\docker-compose.yml" up -d >> "%LOG_FILE%" 2>&1

echo [%DATE% %TIME%] Starting job_weekly_update.kjb via Kitchen... >> "%LOG_FILE%"
pushd "%KITCHEN_DIR%"
call Kitchen.bat /file:"%JOB_FILE%" /level:Basic >> "%LOG_FILE%" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"
popd

echo [%DATE% %TIME%] Finished with exit code %EXIT_CODE%. >> "%LOG_FILE%"
exit /b %EXIT_CODE%
