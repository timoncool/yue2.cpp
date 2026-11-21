"""Assemble the Windows YuE2 HIP runtime for one AMD device without installing ROCm."""
import argparse
import hashlib
import json
import io
import re
import shutil
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

# Official AMD 10.1.0 Windows wheels. The core DLLs come from the matching SDK.
DEVICE = {
    "gfx1036": "1126d3b9f16f61cd47ff89b83af9b72f5d5ef53704e83a1a7b2d329999176e2c",
    "gfx1100": "89b6fc9b76c0ea8cbf437e53c5bf0cd992a2f642ec6ddd34829a94f07f89b0b0",
}
LIBRARIES = "0c34bafbb4aa626cc710d8b130bb314f591194c3d79eeb5892b755ea0be06159"
CORE = {
    "amd_comgr.dll": "da9527847c99efd3df99bd46fe24abae7920b04df0f51e7c677abcccd4924e58",
    "amdhip64_7.dll": "f20e2065cee5889789bf73df0c2d1f4efb481e74ade30488c352fd65ad80ac83",
    "hiprtc-builtins0716.dll": "ad40c1bec5fbeb8b9f1f765207d0301982e674766bf86fb0a82fe4b3d7ea9653",
    "hiprtc0716.dll": "ee7d306880167ae3c0cec7e27953d14ec14d75576d3ba6fab43497dfa873cde3",
    "rocm_kpack.dll": "2e9734ffe6f6eefe1ff660a55dc85fffbcd2d66f794fce4878c6d95a55787b48",
}


def verify(file, expected):
    with file.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != expected:
        raise ValueError(f"Wrong SHA-256 for {file.name}: {actual}")


def add_stream(archive, name, source):
    # Identical component inputs must have the same update digest on any host.
    entry = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    entry.create_system = 3
    entry.external_attr = 0o100644 << 16
    entry.compress_type = ZIP_DEFLATED
    with archive.open(entry, "w") as dest:
        shutil.copyfileobj(source, dest)


def add_file(archive, file, name):
    with file.open("rb") as source:
        add_stream(archive, name, source)


def pack(args, target):
    verify(args.libraries, LIBRARIES)
    verify(args.device, DEVICE[args.arch])
    for name, digest in CORE.items():
        verify(args.sdk / "bin" / name, digest)
    cpus = sorted(args.engine.glob("ggml-cpu-*.dll"))
    for name in ("x64", "sse42", "haswell", "skylakex"):
        if args.engine / f"ggml-cpu-{name}.dll" not in cpus:
            raise ValueError(f"Missing CPU fallback: {name}")
    lib_names = ("hipblas.dll", "rocblas.dll", "rocsolver.dll", "libhipblaslt.dll", "origami.dll")
    with ZipFile(target, "w", compression=ZIP_DEFLATED, compresslevel=3) as out:
        for p in cpus + [args.engine / n for n in ("ggml.dll", "ggml-base.dll", "ggml-hip.dll", "yue-server.exe")]:
            add_file(out, p, "bin/" + p.name)
        add_file(out, args.openmp / "libomp140.x86_64.dll", "bin/libomp140.x86_64.dll")
        add_file(out, args.openmp / "LICENSE-LLVM-OpenMP.txt", "licenses/LICENSE-LLVM-OpenMP.txt")
        add_file(out, Path(__file__).resolve().parents[1] / "LICENSE", "licenses/LICENSE-YuE2")
        add_file(out, Path(__file__).with_name("windows-hip-notices.txt"), "licenses/THIRD-PARTY-NOTICES.txt")
        for name in ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"):
            add_file(out, args.crt / name, "bin/" + name)
        for name in CORE:
            add_file(out, args.sdk / "bin" / name, "bin/" + name)
        # Preserve the SDK layout: the driver locates .kpack relative to bin.
        with ZipFile(args.libraries) as libs:
            for name in lib_names:
                with libs.open("_rocm_sdk_libraries/bin/" + name) as src:
                    add_stream(out, "bin/" + name, src)
        with ZipFile(args.device) as device:
            prefix = "_rocm_sdk_libraries/"
            kpack = f".kpack/blas_lib_{args.arch}.kpack"
            for entry in device.infolist():
                rel = entry.filename.removeprefix(prefix)
                if not entry.is_dir() and (rel == kpack or rel.startswith(("bin/rocblas/library/", "bin/hipblaslt/library/"))):
                    with device.open(entry) as src:
                        add_stream(out, rel, src)
            if kpack not in out.namelist() or not any(n.startswith("bin/rocblas/library/") for n in out.namelist()):
                raise ValueError(f"Incomplete BLAS device files for {args.arch}")
        for p in sorted((args.sdk / "share/doc").rglob("*")):
            if p.is_file() and any(tag in p.name.lower() for tag in ("license", "notice", "copying")):
                add_file(out, p, "licenses/rocm/" + p.relative_to(args.sdk / "share/doc").as_posix())
        manifest = {"gpu_target": args.arch, "rocm": "10.1.0", "engine_revision": args.engine_revision,
                    "engine_sha256": hashlib.sha256((args.engine / "yue-server.exe").read_bytes()).hexdigest()}
        add_stream(out, "BUILD.json", io.BytesIO(json.dumps(manifest, indent=2).encode()))


if __name__ == "__main__":
    import tempfile
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("engine", "sdk", "openmp", "crt", "libraries", "device", "out"):
        parser.add_argument("--" + key, type=Path, required=True)
    parser.add_argument("--arch", choices=DEVICE, required=True)
    parser.add_argument("--engine-revision", required=True, help="Full Git SHA of the prebuilt engine")
    a = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", a.engine_revision):
        parser.error("--engine-revision must be the 40-character source SHA")
    a.out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=a.out.parent, delete=False, suffix=".zip") as handle:
        temp = Path(handle.name)
    try:
        pack(a, temp)
        temp.replace(a.out)
    finally:
        temp.unlink(missing_ok=True)
