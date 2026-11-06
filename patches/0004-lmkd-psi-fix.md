# lmkd PSI binary patch (x86_64)

`lmkd` in Android 16 registers PSI (Pressure Stall Information) watchers at
boot. Under LXC the PSI file descriptors can be unavailable, and lmkd would
take the error path and exit, killing early boot.

## Patch

In the x86_64 `lmkd` binary, at file offset `0xe338`:

    before: 31 db          (xor ebx, ebx)  ->  PSI register failure path
    after:  b3 01          (mov bl, 1)     ->  treat as success, continue

This makes lmkd skip the fatal PSI registration check and continue running,
which is required for `sys.boot_completed=1` under LXC.

## Apply

    # copy lmkd out of the built rootfs, patch in place, copy back
    printf "\x31\xdb" -> "\xb3\x01" at offset 0xe338
