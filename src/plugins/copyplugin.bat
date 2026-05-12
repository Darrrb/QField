@echo off
REM Copy QField plugin to tracking folder

set SOURCE=C:\Users\damie\Documents\GitHub\QField\src\plugins\QGC_Yepppon_Qfield_cloud.qml
set DEST=D:\_Tracking\QGC_Yepppon_Qfield\QGC_Yepppon_Qfield.qml

echo Copying QField plugin...
echo From: %SOURCE%
echo To: %DEST%

copy "%SOURCE%" "%DEST%"

if %ERRORLEVEL% EQU 0 (
    echo.
    echo Copy successful!
) else (
    echo.
    echo Copy failed with error code %ERRORLEVEL%
)

