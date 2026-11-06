# Android 16 Redroid LXC build on VM 192.168.0.108

Build machine: Ubuntu 24.04 VM `.108`; **not** the production PVE host. The
VM's 1 TB virtual disk is backed by the PVE thin pool, not independent storage.
`/work` is a 600 GiB ext4 filesystem in `/aosp-build-volume.img`, limiting
the build's write capacity. Monitor real thin-pool free space independently.

Run scripts on `.108` as root, in numerical order. They are also copied to
`/root/redroid16-build/` on that machine:

| Script | Purpose |
| --- | --- |
| `00-prepare-storage.sh` | Create and format **only** the new sparse file; mount `/work`. One-time only. |
| `01-install-deps.sh` | Install Ubuntu packages and repo launcher from BFSU mirrors. |
| `02-sync-aosp.sh` | Shallow sync `android-16.0.0_r2` from BFSU into `/work/aosp/source`; log `/work/repo-sync.log`. |
| `03-integrate-redroid.sh` | Copy six-project export staged in `/work/redroid16-deps/`; apply official Redroid 16 patches and stop on failure. |
| `04-build-modules.sh` | Build modified `init_second_stage` and `apexd`; log `/work/aosp/module-build.log`. |
| `05-build-image.sh` | Full `redroid_x86_64-bp2a-userdebug` build; log `/work/aosp/full-build.log`. |
| `06-flatten-rootfs.sh` | Create `/work/redroid16-lxc-rootfs`; read-only ext4 APEX mounts occur **inside the build VM** only. Do not run twice. |
| `07-add-arm-bridge.sh` | Add existing private API 36 ARM64 bridge archive to rootfs. No GApps/Magisk. |
| `08-pack-rootfs.sh` | Create `/work/redroid16-lxc-arm64-buildcheck.rootfs.tar.zst`; does not deploy it. |
| `09-lxc-cgroup-init.sh` | Historical prototype: skipped cgroup setup; later superseded by delegated CT cgroup2. **Do not rerun on the modified tree.** |
| `10-enable-lxc-init-log.sh` | Add CT-only early init file logging; needs `/system/etc/redroid-lxc-debug`. One-time patch. |
| `11-lxc-skip-host-sysctls.sh` | Skip host-global `kptr_restrict` and `mmap_rnd_bits` writes in LXC mode. |
| `12-lxc-linkerconfig-no-pty.sh` | Use fork/exec instead of early-boot PTY logwrap for linkerconfig in LXC mode. |
| `13-keep-flat-apex-service.sh` | Keep Binder apexservice alive in flattened mode and report directory APEX metadata; includes no-argument guard. |

Additional input: the earlier `port-flattened-apex.py` was applied to
`system/core` and `system/apex` **after** official Redroid patches. The native
bridge archive is a private local SDK-derived artifact, not supplied by the
BFSU AOSP mirror. Do not distribute this rootfs publicly without checking the
licenses of its proprietary contents.

**State:** Module build and full Redroid 16 build succeeded; 35 APEX packages
were unpacked to directories and `ro.apex.updatable=false` was set in the
separate staged rootfs. This is not proof that Android will boot under LXC,
that ARM apps will work, or that PVE's host services are safe. Do not import
into production CT 126 or pass through the host's loop/DM control devices.
The PVE `.134` node no longer had `/etc/pve/lxc/126.conf` at last check;
do not silently recreate or overwrite another container.

## PVE CT 127 test status (2026-11-04)

An independent privileged **test-only** CT 127 was created from this archive.
It does **not** pass through the host loop or device-mapper controller; the
host `/sys` is read-only and the host FUSE connections directory is masked.
CT 122 and existing CT 123 were not modified. CT 127 is **stopped and
persistently systemd-masked** after tests. Backups of the modified CT-only init,
apexd, init.rc, cgroups.json and configuration live under PVE `/root/ct127-*`
and `/root/127.conf.before-*`; do not blindly restore backups as a complete
deployment configuration.

The modified `init` and `apexd` were compiled successfully. Actual CT startup
advanced through 35 flattened APEX bind mounts, `apexd-bootstrap`, linkerconfig
generation, Binder registration and KeyMint module hash notification. It did
**not** reach `sys.boot_completed=1`. The current fatal bootloop is
`bpfloader-failed`. The Android 16 Tethering APEX overrides the system's
fallback `bpfloader` service in `netbpfload.35rc`; it asks init for a writable
`/dev/kmsg` fd. A short CT-127-only test of device permission `c 1:11 rwm`
obtained logcat evidence: `netbpfload` reports `Unsupported kernel version
(700000e)` and attempts to write the host-global read-only sysctl
`/proc/sys/kernel/unprivileged_bpf_disabled`. **That device permission was
removed again after the test.** Android 16's loader also attempts BPF
program/map operations and `/proc/sys/net/core/bpf_jit_*` writes. Do **not**
expose host BPF control or writable sysctls merely to advance boot; do not
substitute `/system/bin/true` and claim networking works. Proper container-safe
Android 16 network/BPF adaptation and isolation testing remain open. ARM app
functionality has not been tested in CT 127. To test again, an administrator
must deliberately remove **only CT 127's** systemd masks; do not start it
without reassessing host protections.

## x86_64 final deliverable (2026-11-06)

The **x86_64** image was rebuilt and all boot-blocking fixes were compiled into
the binary (no runtime patching required). Deployed and verified:

- `boot_completed=1`, 86 processes
- `adb connect <ip>:5555` works, `pm list packages` 114
- system_server / netd / apexd / lmkd / adbd all running

### Built-in fixes (already in the image)

| Fix | File | Purpose |
| --- | --- | --- |
| FileIntegrity no-op | `frameworks/base/.../FileIntegrity.java` | skip fs-verity checks that fail under LXC |
| ZygoteInit caps | `frameworks/base/.../ZygoteInit.java` | drop capability assertions under LXC |
| ashmem memfd | `system/core/libcutils/ashmem-dev.cpp` | fall back to memfd when ashmem unavailable |
| redroid.common.rc | (build-time integration) | P8/P10/P11/P15 service startup ordering |
| netd/updatable start | `system/core/init/builtins.cpp` | fix single-mount-namespace detection so updatable services start |
| apexd init | `system/apex/apexd/apexd_main.cpp` | initialize gSessionManager in flattened mode |
| lmkd PSI | `system/core` lmkd binary | skip fatal PSI registration error (offset 0xe338) |

### Deploy on PVE (one command)

On the PVE node (`.134`), the template lives at
`/var/lib/vz/template/cache/redroid16-lxc-x86_64-rootfs.tar.zst` (1.06 GB,
packed with `--numeric-owner`, all files owned 0:0).

    bash /root/deploy-redroid.sh <ctid> <ip-suffix> [hostname]

Examples:
- `bash /root/deploy-redroid.sh 170 170 my-redroid`
- `adb connect 192.168.0.170:5555`

The script is fully automatic: create privileged CT -> network -> entrypoint +
apparmor + autodev + mount -> set guest IP -> start -> wait for
`sys.boot_completed` (auto-restarts an early init crash) -> prints
`BOOT COMPLETED`.

> Note: a bare PVE Web UI create cannot boot redroid. The Web UI cannot set
> `unprivileged=0`, `lxc.apparmor.raw`, `lxc.mount.auto` or `lxc.autodev`.
> Use `deploy-redroid.sh` or `fix-redroid-ct.sh`.

### Patches

`patches/0001-system-core-init-netd.patch` (builtins.cpp, mount_namespace.cpp,
security.cpp, util.cpp, ashmem-dev.cpp)
`patches/0002-system-apex-apexd.patch` (apexd.cpp, apexd.h, apexd_main.cpp,
apexservice.cpp)
`patches/0003-frameworks-base-zygote-fileintegrity.patch` (ZygoteInit.java,
FileIntegrity.java)
`patches/0004-lmkd-psi-fix.md` (lmkd binary offset 0xe338)

## gpu_mode=host + scrcpy VAAPI (2026-11-06)

### gpu_mode=host (use host GPU)

The host GPU can be used for rendering. The image already contains Mesa EGL/GBM
gralloc and `vulkan.radeon`. Deploy with the host entrypoint:

    androidboot.redroid_gpu_mode=host androidboot.redroid_gpu_node=/dev/dri/renderD128

Verified on an AMD Phoenix3 host (amdgpu): `ro.hardware.egl=mesa`,
`ro.hardware.gralloc=gbm`, `gralloc.gbm.device=/dev/dri/renderD128`,
`ro.hardware.vulkan=radeon`, `sys.boot_completed=1`, SurfaceFlinger renders
without errors. `/dev/dri/card0` + `renderD128` are bind-mounted by
`deploy-redroid.sh`.

`patches/0005-gpu-config-vulkan-fallback.patch` makes `gpu_config.sh` detect the
Vulkan driver from `/sys/class/drm` when `/sys/kernel/debug` is not mounted
under LXC (so `ro.hardware.vulkan` is set automatically).

### scrcpy with VAAPI hardware decode

`scrcpy-redroid.sh` is a thin wrapper that auto-detects the local VAAPI driver
(e.g. `radeonsi` on AMD) and runs `scrcpy` with hardware decode. This is a
client-side feature (decoding uses the client GPU); the redroid server encodes
with `OMX.google.h264.encoder`.

    adb connect <redroid-ip>:5555
    scrcpy-redroid -s <redroid-ip>:5555

    LIBVA_DRIVER_NAME=radeonsi scrcpy -s <redroid-ip>:5555

Verified: `scrcpy 5.0.1` -> `Video decoding: vaapi` (radeonsi, H264 VLD).
