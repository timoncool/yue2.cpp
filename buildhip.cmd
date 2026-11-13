@echo off
setlocal

rem Native Windows ROCm HIP build (gfx1100). Requires the HIP SDK, CMake,
rem Ninja and MSVC C++ Build Tools. The Studio runtime is native C++ only.
rem Use the installed Visual Studio toolchain instead of a fixed machine path.

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo Visual Studio Installer vswhere.exe not found. Install Visual Studio C++ Build Tools. 1>&2
    exit /b 1
)
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS_ROOT=%%I"
if not defined VS_ROOT (
    echo No Visual Studio C++ toolchain found. 1>&2
    exit /b 1
)
set "VCVARS=%VS_ROOT%\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
    echo vcvars64.bat not found under "%VS_ROOT%". 1>&2
    exit /b 1
)
call "%VCVARS%"
if errorlevel 1 exit /b 1

if not defined ROCM_PATH (
    if defined HIP_PATH (
        set "ROCM_PATH=%HIP_PATH%"
    ) else (
        echo Set ROCM_PATH or HIP_PATH to the Windows ROCm SDK root. 1>&2
        exit /b 1
    )
)
if not exist "%ROCM_PATH%\bin\hipcc.exe" (
    echo hipcc.exe not found in "%ROCM_PATH%\bin". 1>&2
    exit /b 1
)
set "PATH=%ROCM_PATH%\bin;%PATH%"
where cmake >nul 2>nul
if errorlevel 1 (echo CMake is required. 1>&2 & exit /b 1)
where ninja >nul 2>nul
if errorlevel 1 (echo Ninja is required. 1>&2 & exit /b 1)

set "CC=clang.exe"
set "CXX=hipcc.exe"
cmake --fresh -S . -B build-hip -G Ninja -DCMAKE_BUILD_TYPE=Release ^
    -DGGML_HIP=ON -DGGML_CUDA=OFF -DGGML_VULKAN=OFF ^
    -DGGML_NATIVE=OFF -DGGML_HIP_RCCL=OFF -DGGML_BACKEND_DL=ON
if errorlevel 1 exit /b 1

cmake --build build-hip --parallel %NUMBER_OF_PROCESSORS%
if errorlevel 1 exit /b 1

if not exist "build-hip\ggml-hip.dll" (
    echo ggml-hip.dll was not built; native HIP inference is unavailable. 1>&2
    exit /b 1
)
if not exist "build-hip\yue-server.exe" (
    echo yue-server.exe was not built. 1>&2
    exit /b 1
)
echo Native HIP engine and GGML backend built successfully.
