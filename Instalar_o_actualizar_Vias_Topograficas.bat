@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar_o_actualizar_Vias_Topograficas.ps1"
if errorlevel 1 (
    echo.
    echo La instalacion fallo. Revisa el mensaje anterior.
    pause
    exit /b 1
)
echo.
pause
endlocal
