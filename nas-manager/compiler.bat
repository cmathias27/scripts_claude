@echo off
rem Compile NAS Manager (necessite Rust : https://rustup.rs)
cd /d "%~dp0"
where cargo >nul 2>nul
if errorlevel 1 (
  echo Rust n'est pas installe : https://rustup.rs
  pause
  exit /b 1
)
cargo build --release
if errorlevel 1 (
  echo.
  echo ECHEC de la compilation.
  pause
  exit /b 1
)
copy /y target\release\nas-manager.exe . >nul
echo.
echo OK : nas-manager.exe est pret dans ce dossier.
pause
