@echo off
rem Native Windows HIP build (AMD ROCm, gfx1100-class cards).
rem Requires the ROCm Windows SDK (HIP_PATH or ROCM_PATH pointing at it,
rem e.g. the TheRock gfx110X dist) and the MSVC Build Tools for the host
rem link step, like the CUDA build. GGML_BACKEND_DL keeps ggml-hip as a
rem runtime-loaded backend next to the executable, mirroring buildall.cmd.

call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

if not defined ROCM_PATH (
    if defined HIP_PATH (
        set "ROCM_PATH=%HIP_PATH%"
    ) else (
        echo ROCm not found: set ROCM_PATH or HIP_PATH to the SDK root 1>&2
        exit /b 1
    )
)
set "PATH=%ROCM_PATH%\bin;%PATH%"

rem rd /s /q build-hip 2>nul
mkdir build-hip 2>nul
cd build-hip

set "CC=clang.exe"
set "CXX=hipcc.exe"
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON -DGGML_CUDA=OFF -DGGML_VULKAN=OFF ^
    -DGGML_BACKEND_DL=ON -DGGML_NATIVE=OFF -DGGML_HIP_RCCL=OFF
cmake --build . --parallel %NUMBER_OF_PROCESSORS%

cd ..
