#!/usr/bin/env bash
# VM .108: make every netbpfload/bpfloader message visible inside the LXC CT.
# Android KernelLogger/liblog cannot reach /dev/kmsg (host device, not passed
# into the CT) and early-boot logd delivery is unreliable here, so all prior
# ALOGE output was silently lost. Changes (LXC diagnostic build):
# 1) NetBpfLoad.cpp: file logger + redefine ALOGD/E/I/V/W -> append to
#    /redroid-lxc-netbpfload.log; mirror fd 1/2 there in main() (fds survive
#    the execve into the Rust bpfloader); SetLogger for libbase LOG(); print
#    the raw ro.boot.redroid_lxc_mode value at startup AND in both gate
#    branches.
# 2) bpfloader.rs: missing kmsg fd -> /redroid-lxc-bpfloader.log, else stderr.
# Does NOT grant the container any host device, sysctl, or bpffs access.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
runuser -u aosp -- python3 - <<'PY'
from pathlib import Path

net = Path('/work/aosp/source/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp')
s = net.read_text()

# 1) File logger + ALOG* redirection (placed after all #include lines).
old = '''#include "BpfSyscallWrappers.h"
#include "bpf/BpfUtils.h"
#include "bpf_map_def.h"
'''
new = old + '''
// ---- redroid16 LXC diagnostic file logger (script 15) ----
#include <stdarg.h>
#include <time.h>

static void LxcNetBpfLog(char prio, const char* fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    const int fd = open("/redroid-lxc-netbpfload.log",
                        O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd >= 0) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        char line[1200];
        int n = snprintf(line, sizeof(line), "%lld.%03ld %c NetBpfLoad: %s\\n",
                         (long long)ts.tv_sec, ts.tv_nsec / 1000000, prio, msg);
        if (n > 0) {
            if (n >= (int)sizeof(line)) n = (int)sizeof(line) - 1;
            (void)write(fd, line, (size_t)n);
        }
        close(fd);
    }
}

#undef ALOGD
#define ALOGD(...) LxcNetBpfLog('D', __VA_ARGS__)
#undef ALOGE
#define ALOGE(...) LxcNetBpfLog('E', __VA_ARGS__)
#undef ALOGI
#define ALOGI(...) LxcNetBpfLog('I', __VA_ARGS__)
#undef ALOGV
#define ALOGV(...) LxcNetBpfLog('V', __VA_ARGS__)
#undef ALOGW
#define ALOGW(...) LxcNetBpfLog('W', __VA_ARGS__)
// ---- end diagnostic file logger ----
'''
if s.count(old) != 1:
    raise SystemExit('Refusing unexpected NetBpfLoad include context or repeat')
s = s.replace(old, new, 1)

# 2) Gate: print the raw property value in BOTH branches (inner block only;
#    the outer if/else indentation differs across AOSP branches).
old = '''            if (android::base::GetBoolProperty("ro.boot.redroid_lxc_mode", false)) {
                ALOGE("LXC mode: ignoring unprivileged_bpf_disabled write failure");
            } else {
                return 1;
            }
'''
new = '''            const std::string lxcMode = GetProperty("ro.boot.redroid_lxc_mode", "<unset>");
            if (android::base::GetBoolProperty("ro.boot.redroid_lxc_mode", false)) {
                ALOGE("LXC mode: ignoring unprivileged_bpf_disabled write failure "
                      "(ro.boot.redroid_lxc_mode=%s)",
                      lxcMode.c_str());
            } else {
                ALOGE("LXC mode gate FALSE (ro.boot.redroid_lxc_mode=%s) -> return 1",
                      lxcMode.c_str());
                return 1;
            }
'''
if s.count(old) != 1:
    raise SystemExit('Refusing unexpected NetBpfLoad gate context or repeat')
s = s.replace(old, new, 1)

# 3) main(): mirror fd 1/2 to the log file, SetLogger, startup banner with raw prop.
old = '''int main(int argc, char** argv, char * const envp[]) {
    if (android::bpf::isAtLeastT) {
        InitLogging(argv, &KernelLogger);
    } else {
        // S lacks the sepolicy to make non-root uid KernelLogger viable
        InitLogging(argv);
    }
'''
new = '''int main(int argc, char** argv, char * const envp[]) {
    // LXC: mirror stdout/stderr into the CT-local log. These fds survive the
    // execve into /system/bin/bpfloader, so the Rust loader lands here too.
    {
        const int lfd = open("/redroid-lxc-netbpfload.log",
                             O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (lfd >= 0) {
            dup2(lfd, 1);
            dup2(lfd, 2);
            if (lfd > 2) close(lfd);
        }
    }
    if (android::bpf::isAtLeastT) {
        InitLogging(argv, &KernelLogger);
    } else {
        // S lacks the sepolicy to make non-root uid KernelLogger viable
        InitLogging(argv);
    }
    // libbase LOG() -> same file (KernelLogger needs /dev/kmsg, unavailable).
    android::base::SetLogger([](android::base::LogId, android::base::LogSeverity sev,
                                const char* tag, const char*, unsigned int,
                                const char* message) {
        LxcNetBpfLog(sev >= android::base::LogSeverity::WARNING ? 'W' : 'I',
                     "%s: %s", tag ? tag : "?", message);
    });
    ALOGI("main: argc=%d argv1=%s ro.boot.redroid_lxc_mode=%s",
          argc, argc > 1 ? argv[1] : "(none)",
          GetProperty("ro.boot.redroid_lxc_mode", "<unset>").c_str());
'''
if s.count(old) != 1:
    raise SystemExit('Refusing unexpected NetBpfLoad main context or repeat')
s = s.replace(old, new, 1)
net.write_text(s)

# 4) Rust bpfloader: file log instead of bare stderr.
rs = Path('/work/aosp/source/system/bpf/loader/bpfloader.rs')
t = rs.read_text()
old = '''        None => {
            // No init-provided kmsg fd (e.g. LXC without /dev/kmsg): log to stderr.
            eprintln!("bpfloader: ANDROID_FILE__dev_kmsg missing; logging to stderr");
            2
        }
'''
new = '''        None => {
            // No init-provided kmsg fd (LXC without /dev/kmsg): prefer a CT-local
            // file, fall back to stderr (netbpfload redirected fd 2 to its log).
            match fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open("/redroid-lxc-bpfloader.log")
            {
                Ok(f) => {
                    use std::os::fd::IntoRawFd;
                    f.into_raw_fd()
                }
                Err(e) => {
                    eprintln!("bpfloader: no kmsg fd, file log failed: {e}; using stderr");
                    2
                }
            }
        }
'''
if t.count(old) != 1:
    raise SystemExit('Refusing unexpected bpfloader.rs kmsg context or repeat')
rs.write_text(t.replace(old, new, 1))
PY
runuser -u aosp -- git -C /work/aosp/source/packages/modules/Connectivity diff --check
runuser -u aosp -- git -C /work/aosp/source/system/bpf diff --check
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4 netbpfload bpfloader
' > /work/aosp/netbpfload-filelog-build.log 2>&1
echo 'File-logging netbpfload+bpfloader compiled; no CT updated.'
ls -l /work/aosp/source/out/target/product/redroid_x86_64/apex/com.android.tethering/bin/netbpfload \
      /work/aosp/source/out/target/product/redroid_x86_64/system/bin/bpfloader
