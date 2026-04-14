# Multi-Container Runtime + Kernel Memory Monitor

## 1) Team Information

- Member 1: Ananya Ratnaparkhi (PES2UG24CS058)
- Member 2: Andey Hemanth (PES2UG24CS061)

## 2) Build, Load, and Run Instructions

### Environment

- Ubuntu 22.04/24.04 VM
- Secure Boot OFF
- No WSL

Install dependencies:

```bash
sudo apt update
sudo apt install -y build-essential linux-headers-$(uname -r)
```

### Build

```bash
cd boilerplate
make
```

CI-safe compile only:

```bash
make -C boilerplate ci
```

### Load kernel module

```bash
cd boilerplate
sudo insmod monitor.ko
ls -l /dev/container_monitor
```

### Prepare rootfs

```bash
mkdir -p rootfs-base
wget https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz
tar -xzf alpine-minirootfs-3.20.3-x86_64.tar.gz -C rootfs-base
cp -a ./rootfs-base ./rootfs-alpha
cp -a ./rootfs-base ./rootfs-beta
```

### Start supervisor and use CLI

Terminal 1:

```bash
cd boilerplate
sudo ./engine supervisor ../rootfs-base
```

Terminal 2:

```bash
cd boilerplate
sudo ./engine start alpha ../rootfs-alpha /bin/sh --soft-mib 48 --hard-mib 80 --nice 5
sudo ./engine start beta ../rootfs-beta /bin/sh --soft-mib 64 --hard-mib 96 --nice 0
sudo ./engine ps
sudo ./engine logs alpha
sudo ./engine stop alpha
sudo ./engine stop beta
```

Foreground execution:

```bash
sudo ./engine run gamma ../rootfs-alpha /bin/sh --soft-mib 40 --hard-mib 64
echo $?
```

### Run workloads

Copy workload binaries into each container rootfs:

```bash
cp ./boilerplate/cpu_hog ./rootfs-alpha/
cp ./boilerplate/io_pulse ./rootfs-beta/
cp ./boilerplate/memory_hog ./rootfs-alpha/
```

Then launch via `start`/`run` using those paths as command (for example `/cpu_hog`).

### Unload module and cleanup

```bash
sudo rmmod monitor
make -C boilerplate clean
```

## 3) Demo with Screenshots

Add annotated screenshots for:

1. Multi-container supervision
2. Metadata tracking (`engine ps`)
3. Bounded-buffer logging and log files
4. CLI request/response IPC
5. Soft-limit warning (`dmesg`)
6. Hard-limit enforcement (`dmesg` + `ps` state)
7. Scheduling experiment results
8. Clean teardown and no zombies

## 4) Engineering Analysis

### Isolation Mechanisms

Each container is created with `clone()` using new PID, UTS, and mount namespaces. The child changes hostname, chroots into its assigned rootfs, and mounts `/proc` inside the container namespace. This isolates process IDs and filesystem view, while still sharing the same host kernel (scheduler, memory manager, and global kernel resources).

### Supervisor and Process Lifecycle

A long-running supervisor coordinates all container lifecycle events instead of tying control to one shell process. It tracks metadata (ID, PID, state, limits, exit fields, rootfs, command, logs), receives CLI commands over a control channel, reaps children through `waitpid(..., WNOHANG)`, and transitions states on normal exit, stop, or signal-kill.

### IPC, Threads, and Synchronization

Two IPC paths are used:

- Path A (logging): container stdout/stderr pipe to supervisor
- Path B (control): UNIX domain socket (`/tmp/mini_runtime.sock`) between CLI client and supervisor

The logging path uses producer-consumer buffering:

- producer threads read container pipe output and push into a bounded ring buffer
- one logger consumer thread pops records and appends per-container log files

Synchronization:

- bounded buffer protected by mutex + condition variables (`not_full`, `not_empty`)
- metadata linked list protected by a separate mutex

Without these locks/conditions, races can corrupt queue indices, drop log entries, and cause stale/unsafe metadata reads.

### Memory Management and Enforcement

The kernel module tracks registered container host PIDs in a lock-protected linked list. A periodic timer checks RSS using `get_mm_rss()`:

- soft-limit: emit a warning once on first crossing
- hard-limit: send `SIGKILL` and remove the tracked entry

RSS covers resident anonymous/file-backed pages in memory and does not directly represent all virtual memory mappings. Enforcement is in kernel space so checks remain authoritative and race-resistant even if user-space supervisor misbehaves.

For list synchronization inside `monitor.c`, we use a `mutex` (not a `spinlock`). The timer callback and ioctl paths can do non-trivial work (RSS lookup, allocation/free, and signal operations), so sleeping lock semantics are safer and simpler. A spinlock would risk long busy-wait hold times and is better suited to very short, strictly atomic critical sections.

### Scheduling Behavior

Experiments should compare at least two concurrent workloads and two scheduling setups (for example, different `nice` values for CPU-bound jobs, or CPU-bound vs I/O-bound workloads). Observe completion times and responsiveness to explain fairness/throughput behavior of CFS under those configurations.

## 5) Design Decisions and Tradeoffs

- Namespace isolation: `chroot` + namespace clone is simpler than `pivot_root`; tradeoff is weaker filesystem-hardening.
- Control-plane IPC: UNIX socket is straightforward and bi-directional; tradeoff is requiring socket lifecycle cleanup.
- Logging architecture: bounded queue with dedicated consumer avoids direct blocking file writes from producer threads; tradeoff is queue sizing/tuning.
- Kernel monitor: timer-based polling is simple and deterministic; tradeoff is coarse-grained reaction interval.
- State attribution: supervisor-side termination classification keeps stop/kill outcomes explicit; tradeoff is extra lifecycle bookkeeping.

## 6) Scheduler Experiment Results

Populate this section with measured data from your VM runs.

Suggested table:

| Experiment | Workload A | Workload B | Config | Metric | Observation |
| --- | --- | --- | --- | --- | --- |
| Exp 1 | CPU hog | CPU hog | A nice=0, B nice=10 | completion time | A gets larger CPU share |
| Exp 2 | CPU hog | IO pulse | both nice=0 | responsiveness | IO workload remains responsive |

Also attach raw command outputs used to compute results.
