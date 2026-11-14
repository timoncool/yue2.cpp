@echo off
setlocal

rem Native Windows ROCm HIP build (gfx1100). Requires the HIP SDK, CMake,
rem Ninja and MSVC C++ Build Tools. The Studio runtime is native C++ only.
rem Locate the host toolchain: a VCVARS64 pointing at vcvars64.bat wins,
rem then a shell that already has cl.exe on PATH, then the Visual Studio
rem Installer's vswhere.

if not defined VCVARS64 goto vswhere_lookup
if not exist "%VCVARS64%" goto bad_vcvars_env
set "VCVARS=%VCVARS64%"
goto call_vcvars

:bad_vcvars_env
echo VCVARS64 is set but "%VCVARS64%" does not exist. 1>&2
exit /b 1

:vswhere_lookup
where cl >nul 2>nul
if not errorlevel 1 goto toolchain_ready
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo No Visual Studio Installer ^(vswhere.exe^) and no cl.exe on PATH. 1>&2
    echo Install Visual Studio C++ Build Tools, build from a developer prompt, or set VCVARS64 to vcvars64.bat. 1>&2
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

:call_vcvars
call "%VCVARS%"
if errorlevel 1 exit /b 1

:toolchain_ready

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

rem The host clang ships beside hipcc in official SDKs; TheRock-style dists
rem keep it under lib\llvm\bin. Resolve it so a bare "clang.exe" on PATH is
rem never required.
if exist "%ROCM_PATH%\bin\clang.exe" set "HIP_CLANG=%ROCM_PATH%\bin\clang.exe"
if not defined HIP_CLANG if exist "%ROCM_PATH%\lib\llvm\bin\clang.exe" set "HIP_CLANG=%ROCM_PATH%\lib\llvm\bin\clang.exe"
if not defined HIP_CLANG (
    echo clang.exe not found in "%ROCM_PATH%\bin" or "%ROCM_PATH%\lib\llvm\bin". 1>&2
    exit /b 1
)

rem The ggml HIP backend drives hipcc directly on Windows, so the gfx target
rem must be passed explicitly. Minimal TheRock dists also need the device
rem library path pointed out; official SDK layouts resolve it themselves.
if not defined HIP_ARCHS set "HIP_ARCHS=gfx1100"
set "HIP_CXX_FLAGS=--offload-arch=%HIP_ARCHS%"
if exist "%ROCM_PATH%\lib\llvm\amdgcn\bitcode" set "HIP_CXX_FLAGS=%HIP_CXX_FLAGS% --rocm-device-lib-path=%ROCM_PATH%/lib/llvm/amdgcn/bitcode"

set "CC=%HIP_CLANG%"
set "CXX=%ROCM_PATH%\bin\hipcc.exe"
rem OpenMP off: the dist's clang is newer than GGML_OPENMP_FETCH supports, so
rem the CPU backend would link the MSVC toolset's libomp import and need the
rem libomp140 runtime DLL beside the engine. ggml's own thread pool drives
rem the CPU side; every heavy stage runs on the HIP device anyway.
cmake --fresh -S . -B build-hip -G Ninja -DCMAKE_BUILD_TYPE=Release ^
    -DGGML_HIP=ON -DGGML_CUDA=OFF -DGGML_VULKAN=OFF ^
    -DGGML_NATIVE=OFF -DGGML_HIP_RCCL=OFF -DGGML_BACKEND_DL=ON ^
    -DGGML_OPENMP=OFF ^
    "-DCMAKE_CXX_FLAGS=%HIP_CXX_FLAGS%"
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
