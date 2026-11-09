"""Mac-side JIT host, loaded inside lldb. Attaches to the app on a connected iPhone
and serves its `brk #0xf00d` requests, standing in for StikDebug during development.

On iOS 26 with TXM, a page only becomes executable once a debugger has written to it,
so the allocate command writes at least one byte in every 16 KB page.

Protocol (see win/JITProbe.c): x16=0 detach, x16=1 allocate, x16=2 print string.
"""

import time

import lldb

BRK_F00D = 0xD43E01A0
JIT_PAGE_SIZE = 0x4000
MAX_REPEATED_STOPS = 50


def log(message):
    print(f"[jit-host] {message}", flush=True)


def register(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def set_x0(frame, value):
    error = lldb.SBError()
    frame.FindRegister("x0").SetValueFromCString(hex(value), error)
    if error.Fail():
        raise RuntimeError(f"cannot set x0: {error}")


def allocate(process, size):
    error = lldb.SBError()
    permissions = lldb.ePermissionsReadable | lldb.ePermissionsExecutable
    address = process.AllocateMemory(size, permissions, error)
    if error.Fail():
        log(f"allocation failed: {error}")
        return 0

    # Each write covers the last byte of one page and the first byte of the next, so one
    # round trip to the device authorizes two pages. Round trips dominate the cost.
    start = time.monotonic()
    for offset in range(0, size, 2 * JIT_PAGE_SIZE):
        if offset + JIT_PAGE_SIZE < size:
            target, data = address + offset + JIT_PAGE_SIZE - 1, b"\x69\x69"
        else:
            target, data = address + offset, b"\x69"
        process.WriteMemory(target, data, error)
        if error.Fail():
            log(f"write at {target:#x} failed: {error}")
            return 0
    pages = size // JIT_PAGE_SIZE
    log(f"authorized {pages} pages at {address:#x} in {time.monotonic() - start:.2f}s")
    return address


def stopped_thread(process):
    for thread in process:
        if thread.GetStopReason() not in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
            return thread
    return None


def serve(process):
    """Returns once the app asks to detach or the process ends."""
    error = lldb.SBError()
    other_stops = 0
    last_other_pc = None

    while True:
        process.Continue()
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
            log(f"process ended: {lldb.SBDebugger.StateAsCString(state)}, "
                f"exit status {process.GetExitStatus()}")
            return

        thread = stopped_thread(process)
        if thread is None:
            continue

        frame = thread.GetFrameAtIndex(0)
        pc = frame.GetPC()
        instruction = process.ReadUnsignedFromMemory(pc, 4, error)

        if error.Fail() or instruction != BRK_F00D:
            # The app can sit in the library for a long time before a program is chosen,
            # so only the same stop repeating is treated as a failure.
            other_stops = other_stops + 1 if pc == last_other_pc else 1
            last_other_pc = pc
            log(f"other stop at {pc:#x}: {thread.GetStopDescription(200)}")
            if other_stops > MAX_REPEATED_STOPS:
                raise RuntimeError("the same stop keeps repeating")
            continue

        command = register(frame, "x16")
        x0 = register(frame, "x0")
        x1 = register(frame, "x1")
        frame.SetPC(pc + 4)

        if command == 0:
            log("app asked to detach")
            process.Detach()
            return
        if command == 1:
            set_x0(frame, allocate(process, x1))
        elif command == 2:
            text = process.ReadMemory(x0, x1, error)
            log(f"app: {text.decode('utf-8', 'replace') if error.Success() else error}")
        else:
            log(f"unknown command {command}")
            set_x0(frame, 0)


def jit_host(debugger, command, result, internal_dict):
    device, pid = command.split()
    debugger.SetAsync(False)
    interpreter = debugger.GetCommandInterpreter()

    # `device select` reports no success status from the API, so these commands are
    # judged by whether they end with a live process.
    # Right after a launch, Core Device lookups sometimes time out for a while, so the
    # device lookup is retried for up to about a minute.
    errors = []
    for attempt in range(8):
        errors = []
        for line in ("device list", f"device select {device}", f"device process attach --pid {pid}"):
            output = lldb.SBCommandReturnObject()
            interpreter.HandleCommand(line, output)
            if output.GetError():
                errors.append(f"{line}: {output.GetError().strip()}")
        process = debugger.GetSelectedTarget().GetProcess()
        if process.IsValid() and process.GetProcessID() == int(pid):
            break
        log(f"attach attempt {attempt + 1} failed: {' | '.join(errors)}")
        time.sleep(5)

    process = debugger.GetSelectedTarget().GetProcess()
    if not process.IsValid() or process.GetProcessID() != int(pid):
        result.SetError("attach failed. " + " | ".join(errors))
        return
    log(f"attached to pid {process.GetProcessID()}")
    serve(process)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.jit_host jit_host")
