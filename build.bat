@echo off
setlocal

set "ROOT_DIR=%~dp0"
pushd "%ROOT_DIR%" >NUL || exit /b 1

if /I "%~1"=="help" goto usage_ok
if "%~1"=="/?" goto usage_ok
if /I "%~1"=="-h" goto usage_ok
if /I "%~1"=="--help" goto usage_ok

set "FLAVOR=%~1"
set "BUILD_TYPE=%~2"

if "%FLAVOR%"=="" set "FLAVOR=ststable"
if "%BUILD_TYPE%"=="" set "BUILD_TYPE=release"

if /I "%FLAVOR%"=="stable" set "FLAVOR=ststable"
if /I "%FLAVOR%"=="beta" set "FLAVOR=stbeta"
if /I "%FLAVOR%"=="fdroid" set "FLAVOR=stfdroid"

if /I "%FLAVOR%"=="ststable" (
    set "TASK_FLAVOR=Ststable"
) else if /I "%FLAVOR%"=="stbeta" (
    set "TASK_FLAVOR=Stbeta"
) else if /I "%FLAVOR%"=="stfdroid" (
    set "TASK_FLAVOR=Stfdroid"
) else (
    echo Unknown flavor: %FLAVOR%
    echo.
    goto usage_fail
)

if /I "%BUILD_TYPE%"=="release" (
    set "TASK_BUILD_TYPE=Release"
) else if /I "%BUILD_TYPE%"=="debug" (
    set "TASK_BUILD_TYPE=Debug"
) else (
    echo Unknown build type: %BUILD_TYPE%
    echo.
    goto usage_fail
)

shift /1
shift /1

set "TASK=:smarttubetv:assemble%TASK_FLAVOR%%TASK_BUILD_TYPE%"

echo Building %TASK% ...
call "%ROOT_DIR%gradlew.bat" %TASK% %*
set "EXIT_CODE=%ERRORLEVEL%"

if "%EXIT_CODE%"=="0" (
    echo.
    echo Build finished. APK files are in smarttubetv\build\outputs\apk\%FLAVOR%\%BUILD_TYPE%\
) else (
    echo.
    echo Build failed with exit code %EXIT_CODE%.
)

popd >NUL
exit /b %EXIT_CODE%

:usage_ok
set "USAGE_EXIT_CODE=0"
goto usage

:usage_fail
set "USAGE_EXIT_CODE=1"

:usage
echo Usage:
echo   build.bat [stable^|beta^|fdroid] [debug^|release] [extra Gradle args]
echo.
echo Examples:
echo   build.bat
echo   build.bat beta debug
echo   build.bat fdroid release --stacktrace
echo.
echo Defaults: stable release
popd >NUL
exit /b %USAGE_EXIT_CODE%