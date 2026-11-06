#!/usr/bin/env bash
# VM .108: avoid logwrap's PTY for linkerconfig in explicit LXC boot mode.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
runuser -u aosp -- python3 - <<'PY'
from pathlib import Path
p = Path('/work/aosp/source/system/core/init/builtins.cpp')
s = p.read_text()
old = '''    if (logwrap_fork_execvp(arraysize(arguments), arguments, nullptr, false, LOG_KLOG, false,
                            nullptr) != 0) {
        return ErrnoError() << "failed to execute linkerconfig";
    }'''
new = '''    if (android::base::GetBoolProperty("ro.boot.redroid_lxc_mode", false)) {
        // logwrap requires a PTY that is not reliably usable during early LXC boot.
        // Keep logs inside this container; never expose host /dev/kmsg.
        pid_t child = fork();
        if (child < 0) return ErrnoError() << "failed to fork linkerconfig";
        if (child == 0) {
            int fd = open("/redroid-lxc-linkerconfig.log",
                          O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
            if (fd >= 0) {
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
                if (fd > STDERR_FILENO) close(fd);
            }
            execl(linkerconfig_binary, linkerconfig_binary, "--target", linkerconfig_target,
                  static_cast<char*>(nullptr));
            PLOG(ERROR) << "failed to exec linkerconfig";
            _exit(127);
        }
        int status = 0;
        pid_t waited;
        do {
            waited = waitpid(child, &status, 0);
        } while (waited == -1 && errno == EINTR);
        if (waited == -1) return ErrnoError() << "failed to wait for linkerconfig";
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            return Error() << "linkerconfig failed, wait status " << status;
        }
    } else if (logwrap_fork_execvp(arraysize(arguments), arguments, nullptr, false, LOG_KLOG,
                                   false, nullptr) != 0) {
        return ErrnoError() << "failed to execute linkerconfig";
    }'''
if s.count(old) != 1:
    raise SystemExit('Refusing unexpected linkerconfig context or repeat')
p.write_text(s.replace(old, new, 1))
PY
runuser -u aosp -- git -C /work/aosp/source/system/core diff --check
runuser -u aosp -- bash -c '
    set -eo pipefail
    cd /work/aosp/source
    source build/envsetup.sh
    lunch redroid_x86_64-bp2a-userdebug
    m -j4 init_second_stage
' > /work/aosp/init-lxc-linkerconfig-build.log 2>&1
echo 'LXC linkerconfig build finished; no CT updated.'
