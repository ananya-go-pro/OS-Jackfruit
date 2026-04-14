# Presentation Primer: Multi-Container Runtime Project

This file is a presentation-ready companion document. It explains:

- what this project is
- why each subsystem exists
- core OS theory used
- exactly what was implemented recently in `engine.c` and `monitor.c`
- what to say in demos and viva-style questions

---

## 1) Project in One Line

A lightweight container runtime in C with:

- a **user-space supervisor** (`engine.c`) that manages container lifecycle and logging
- a **kernel module memory monitor** (`monitor.c`) that enforces soft/hard RSS limits

---

## 2) Prerequisites (Concept + Environment)

### Environment prerequisites

- Ubuntu 22.04/24.04 VM
- Secure Boot OFF (for unsigned kernel module loading)
- `build-essential`, matching kernel headers

### OS theory prerequisites

You should be comfortable with:

- process lifecycle: `fork/clone`, `waitpid`, zombies
- Linux namespaces: PID, UTS, mount
- filesystem isolation: `chroot`
- IPC: UNIX domain sockets, pipes
- thread synchronization: mutex + condition variable
- kernel-space data structures: linked list + locking
- kernel/user boundary: `ioctl`
- Linux signals: `SIGCHLD`, `SIGINT`, `SIGTERM`, `SIGKILL`

---

## 3) Architecture Overview

The runtime has two IPC paths:

1. **Control path (Path B):** CLI process -> supervisor  
   Used for commands like `start`, `run`, `ps`, `logs`, `stop`.
2. **Logging path (Path A):** container stdout/stderr -> supervisor via pipe  
   Output is pushed into a bounded buffer and written to log files.

Kernel side:

- supervisor sends PIDs + limits to `/dev/container_monitor` using `ioctl`
- module periodically checks RSS and applies policy:
  - soft-limit -> warning
  - hard-limit -> `SIGKILL`

---

## 4) What We Implemented in `engine.c` (recent work)

We completed TODO blocks one by one, minimally.

### Completed TODOs

1. `bounded_buffer_push(...)`
   - producer-side insertion into circular bounded queue
   - blocks while full
   - exits cleanly if shutdown flag is set
   - signals consumers (`not_empty`)

2. `bounded_buffer_pop(...)`
   - consumer-side removal
   - waits while empty
   - returns shutdown status when empty+shutdown
   - signals producers (`not_full`)

3. `logging_thread(...)`
   - pops log chunks from bounded buffer
   - maps `container_id` to container record under metadata lock
   - appends chunks to per-container log file
   - exits when buffer shutdown+drained

4. `child_fn(...)`
   - applies `nice`
   - sets hostname (`UTS`)
   - makes mount tree private
   - `chdir` + `chroot` into container rootfs
   - mounts `/proc`
   - redirects stdout/stderr to supervisor logging fd
   - `execlp` container command

5. `run_supervisor(...)` (minimal TODO-driven version)
   - opens `/dev/container_monitor`
   - creates and binds UNIX control socket
   - installs signal handlers (`SIGCHLD`, `SIGINT`, `SIGTERM`)
   - starts logger thread
   - runs long-lived `accept()` loop
   - reaps children on signal interruption
   - clean shutdown and resource cleanup

6. `send_control_request(...)`
   - creates UNIX socket client
   - connects to supervisor control socket
   - sends request struct
   - reads response struct
   - prints response and returns status

7. `cmd_ps()`
   - reduced to minimal proper form:
     - set request type `CMD_PS`
     - call `send_control_request`

### Why this style was chosen

Implementation was intentionally kept minimal and aligned with comment requirements, to avoid unnecessary complexity before demos and review.

---

## 5) What We Implemented in `monitor.c` (recent work)

Also completed TODO blocks one by one.

### Completed TODOs

1. **TODO 1:** monitored node struct
   - stores pid, container id, soft/hard limits, one-time soft warning flag, list link

2. **TODO 2:** shared list + lock
   - `LIST_HEAD(monitored_list)`
   - `DEFINE_MUTEX(monitored_lock)`

3. **TODO 3:** `timer_callback(...)`
   - safe list iteration with deletion support
   - remove stale/exited pids
   - hard-limit kill then remove
   - soft-limit warning only once
   - re-arm periodic timer

4. **TODO 4:** register path in `monitor_ioctl(...)`
   - validate request
   - allocate and initialize node
   - insert into list under mutex

5. **TODO 5:** unregister path in `monitor_ioctl(...)`
   - search by pid or container id
   - remove matching node safely
   - return `0` on success, `-ENOENT` if missing

6. **TODO 6:** cleanup in `monitor_exit(...)`
   - free all remaining list nodes under lock
   - leaves no stale allocation on unload

---

## 6) Why Mutex (not Spinlock) in `monitor.c`

Short viva answer:

- `ioctl` and timer paths can involve non-trivial operations (lookup, allocation/free, signaling).
- A mutex is simpler and safer for these longer critical sections.
- Spinlocks are better for very short non-sleeping sections and can waste CPU by busy-waiting.

---

## 7) Key Theory You Can Say During Presentation

### Isolation

Containers here are process-level isolation using namespaces + rootfs change, not full VMs.  
Kernel is shared across containers and host.

### Reaping/Zombies

If parent doesn’t `waitpid` exited children, zombies remain.  
Supervisor handles `SIGCHLD` and reaps to prevent zombie leaks.

### Bounded Buffer Correctness

Producer-consumer with mutex + condition vars prevents:

- queue corruption (race on head/tail/count)
- busy polling
- deadlock under full/empty conditions

### Soft vs Hard Memory Policy

- soft limit = warning signal for observability
- hard limit = enforcement action (`SIGKILL`)

This separates “observe pressure” from “enforce protection”.

---

## 8) Suggested Demo Script (Short)

1. Build user + module
2. `insmod monitor.ko`
3. start supervisor
4. start two containers
5. show `ps`
6. show logs
7. trigger memory pressure workload
8. show `dmesg` soft warning / hard kill
9. stop containers
10. unload module and show clean exit

---

## 9) What To Mention As Current Scope

- `engine.c` TODO blocks requested in the current iteration are implemented minimally.
- `monitor.c` TODO blocks are fully implemented.
- Keep discussion honest: mention incremental implementation strategy and that functionality was built according to required TODO responsibilities before adding extra polish.

---

## 10) Quick Q&A Prep

**Q: Why two IPC mechanisms?**  
A: Control path and logging path have different communication patterns and requirements.

**Q: Why kernel module for memory policy?**  
A: Kernel has authoritative process memory visibility and can enforce limits reliably.

**Q: Why not enforce everything from user space?**  
A: User-space checks are less authoritative and can race with process behavior.

**Q: Why bounded buffer instead of direct file write from producer?**  
A: Decouples pipe-read rate from disk-write rate and centralizes synchronization.

**Q: What does this project teach?**  
A: Process isolation, IPC design, synchronization, signal-driven lifecycle control, and kernel/user cooperation.
