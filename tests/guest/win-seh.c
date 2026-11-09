// Structured exception handling checks, written for 32-bit x86 (WoW64) where the
// handler chain lives on the thread's stack (fs:[0]) and RtlDispatchException walks it,
// checking each frame against the stack limits. Also builds for x86-64, where only the
// vectored-handler checks run.
//
// Prints one "ok"/"FAIL" line per check and "checks: N, failures: M".

#include <windows.h>
#include <stdio.h>

static int checks, failures;
static void check(const char *name, int ok, const char *detail) {
    printf("%-4s %2d %-50s %s\n", ok ? "ok" : "FAIL", checks++, name, detail ? detail : "");
    if (!ok) failures++;
}

static volatile LONG vectored_seen;
static LONG CALLBACK vectored(EXCEPTION_POINTERS *info) {
    if (info->ExceptionRecord->ExceptionCode == 0xE0000001) {
        vectored_seen++;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

#if defined(__i386__)
// A stack-based SEH frame (EXCEPTION_REGISTRATION_RECORD), as MSVC's __try builds one.
static volatile int frame_seen;
static volatile DWORD seen_code;
static void *resume_at;
static NT_TIB *tib(void) { NT_TIB *t; __asm__ volatile("movl %%fs:0x18, %0" : "=r"(t)); return t; }

static EXCEPTION_DISPOSITION __cdecl frame_handler(EXCEPTION_RECORD *record, void *frame, CONTEXT *context, void *dispatcher) {
    (void)frame; (void)dispatcher;
    if (record->ExceptionFlags & 6) return ExceptionContinueSearch;  // unwinding
    frame_seen++;
    seen_code = record->ExceptionCode;
    if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) context->Eip = (DWORD)resume_at;
    return ExceptionContinueExecution;
}

struct registration { struct registration *next; void *handler; };

static void seh_raise(void) {
    struct registration reg;
    NT_TIB *t = tib();
    reg.next = (struct registration *)t->ExceptionList;
    reg.handler = (void *)frame_handler;
    t->ExceptionList = (void *)&reg;
    RaiseException(0xE0000002, 0, 0, NULL);  // continuable: the handler returns and so does this
    t->ExceptionList = (void *)reg.next;
}

static void seh_fault(void);

/* Unwinding, as MSVC's __except and C++ catch do it: the outer frame's handler calls
 * RtlUnwind, which calls the inner frame's handler with EXCEPTION_UNWINDING and drops it
 * from the chain, then resumes after the RaiseException call. */
static volatile int inner_unwound, outer_seen;
static void *unwind_resume;
static DWORD unwind_esp, unwind_ebp;

static EXCEPTION_DISPOSITION __cdecl inner_handler(EXCEPTION_RECORD *record, void *frame, CONTEXT *context, void *dispatcher) {
    (void)frame; (void)context; (void)dispatcher;
    if (record->ExceptionFlags & 2) inner_unwound++;  // EXCEPTION_UNWINDING
    return ExceptionContinueSearch;
}

static EXCEPTION_DISPOSITION __cdecl outer_handler(EXCEPTION_RECORD *record, void *frame, CONTEXT *context, void *dispatcher) {
    (void)dispatcher;
    if (record->ExceptionFlags & 6) return ExceptionContinueSearch;
    outer_seen++;
    RtlUnwind(frame, NULL, record, 0);
    context->Eip = (DWORD)unwind_resume;
    context->Esp = unwind_esp;
    context->Ebp = unwind_ebp;
    return ExceptionContinueExecution;
}

/* Raises code from inside an asm block whose end is the resume point,
 * so the stack pointer there is the one recorded before the call. */
static void raise_with_resume(DWORD code) {
    void *raise = (void *)RaiseException;
    __asm__ volatile(
        "movl %[code], %%eax\n\t"   // operands first: they may be addressed relative to esp
        "movl %[raise], %%ecx\n\t"
        "movl $1f, %[res]\n\t"
        "movl %%esp, %[sp]\n\t"
        "movl %%ebp, %[bp]\n\t"
        "pushl $0\n\t"
        "pushl $0\n\t"
        "pushl $0\n\t"          // flags: continuable, so the handler may resume with a new context
        "pushl %%eax\n\t"
        "call *%%ecx\n\t"
        "1:\n\t"
        : [res] "=m"(unwind_resume), [sp] "=m"(unwind_esp), [bp] "=m"(unwind_ebp)
        : [code] "m"(code), [raise] "m"(raise)
        : "eax", "ecx", "edx", "esi", "edi", "memory");
}

/* The inner frame lives in a deeper call, so it is below the outer one on the stack
 * (RtlUnwind rejects a chain that is not, as Windows does). */
static __attribute__((noinline)) void seh_unwind_inner(struct registration *outer) {
    struct registration inner;
    NT_TIB *t = tib();
    inner.next = outer;
    inner.handler = (void *)inner_handler;
    t->ExceptionList = (void *)&inner;
    raise_with_resume(0xE0000003);
    t->ExceptionList = (void *)outer;  // RtlUnwind already dropped the inner frame
}

static void seh_unwind(void) {
    struct registration outer;
    NT_TIB *t = tib();
    void *saved = t->ExceptionList;
    outer.next = (struct registration *)saved;
    outer.handler = (void *)outer_handler;
    t->ExceptionList = (void *)&outer;
    seh_unwind_inner(&outer);
    t->ExceptionList = saved;
}

/* An exception raised inside a handler, caught by the next frame out. */
static volatile int nested_inner, nested_outer;
static EXCEPTION_DISPOSITION __cdecl nesting_handler(EXCEPTION_RECORD *record, void *frame, CONTEXT *context, void *dispatcher) {
    (void)frame; (void)context; (void)dispatcher;
    if (record->ExceptionFlags & 6) return ExceptionContinueSearch;
    if (record->ExceptionCode == 0xE0000004) {
        nested_inner++;
        RaiseException(0xE0000005, 0, 0, NULL);  // continuable, handled outside
        return ExceptionContinueExecution;
    }
    return ExceptionContinueSearch;
}
static EXCEPTION_DISPOSITION __cdecl catch_nested(EXCEPTION_RECORD *record, void *frame, CONTEXT *context, void *dispatcher) {
    (void)frame; (void)context; (void)dispatcher;
    if (record->ExceptionFlags & 6) return ExceptionContinueSearch;
    if (record->ExceptionCode == 0xE0000005) { nested_outer++; return ExceptionContinueExecution; }
    return ExceptionContinueSearch;
}
static __attribute__((noinline)) void seh_nested_inner(struct registration *outer) {
    struct registration inner;
    NT_TIB *t = tib();
    inner.next = outer;
    inner.handler = (void *)nesting_handler;
    t->ExceptionList = (void *)&inner;
    RaiseException(0xE0000004, 0, 0, NULL);
    t->ExceptionList = (void *)outer;
}

static void seh_nested(void) {
    struct registration outer;
    NT_TIB *t = tib();
    void *saved = t->ExceptionList;
    outer.next = (struct registration *)saved;
    outer.handler = (void *)catch_nested;
    t->ExceptionList = (void *)&outer;
    seh_nested_inner(&outer);
    t->ExceptionList = saved;
}

/* The same on a fiber's stack and on a second thread. */
static void *main_fiber;
static volatile int fiber_ok, thread_ok;
static void WINAPI fiber_proc(void *arg) {
    (void)arg;
    NT_TIB *t = tib();
    int in_limits = (char *)&t > (char *)t->StackLimit && (char *)&t < (char *)t->StackBase;
    frame_seen = 0; seh_raise();
    int raised = frame_seen == 1;
    inner_unwound = outer_seen = 0; seh_unwind();
    fiber_ok = in_limits && raised && inner_unwound == 1 && outer_seen == 1;
    SwitchToFiber(main_fiber);
}
static DWORD WINAPI thread_proc(void *arg) {
    (void)arg;
    frame_seen = 0; seh_fault();
    int faulted = frame_seen == 1;
    inner_unwound = outer_seen = 0; seh_unwind();
    thread_ok = faulted && inner_unwound == 1 && outer_seen == 1;
    return 0;
}

static void seh_fault(void) {
    struct registration reg;
    NT_TIB *t = tib();
    reg.next = (struct registration *)t->ExceptionList;
    reg.handler = (void *)frame_handler;
    t->ExceptionList = (void *)&reg;
    __asm__ volatile(
        "movl $1f, %0\n\t"
        "movl $0, %%eax\n\t"
        "movl %%eax, (%%eax)\n\t"   // write to address 0: access violation
        "1:\n\t"
        : "=m"(resume_at) : : "eax", "memory");
    t->ExceptionList = (void *)reg.next;
}
#endif

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
#if defined(__i386__)
    printf("win-seh built for 32-bit x86\n");
#else
    printf("win-seh built for x86-64\n");
#endif
    char detail[128];
    PVOID handle = AddVectoredExceptionHandler(1, vectored);
    RaiseException(0xE0000001, 0, 0, NULL);
    check("vectored handler sees RaiseException", vectored_seen == 1, NULL);
    RemoveVectoredExceptionHandler(handle);

#if defined(__i386__)
    NT_TIB *t = tib();
    snprintf(detail, sizeof detail, "esp %p, stack %p..%p", (void *)&detail, t->StackLimit, t->StackBase);
    check("stack pointer inside the TEB stack limits",
          (char *)&detail > (char *)t->StackLimit && (char *)&detail < (char *)t->StackBase, detail);

    frame_seen = 0;
    seh_raise();
    snprintf(detail, sizeof detail, "handler calls %d, code %#lx", frame_seen, seen_code);
    check("stack SEH frame handles RaiseException", frame_seen == 1 && seen_code == 0xE0000002, detail);

    frame_seen = 0;
    seh_fault();
    snprintf(detail, sizeof detail, "handler calls %d, code %#lx", frame_seen, seen_code);
    check("stack SEH frame handles an access violation", frame_seen == 1 && seen_code == EXCEPTION_ACCESS_VIOLATION, detail);

    inner_unwound = outer_seen = 0;
    seh_unwind();
    snprintf(detail, sizeof detail, "outer handler %d, inner unwound %d", outer_seen, inner_unwound);
    check("RtlUnwind through two frames, then resume", outer_seen == 1 && inner_unwound == 1, detail);

    nested_inner = nested_outer = 0;
    seh_nested();
    snprintf(detail, sizeof detail, "inner %d, outer %d", nested_inner, nested_outer);
    check("exception raised inside a handler", nested_inner == 1 && nested_outer == 1, detail);

    main_fiber = ConvertThreadToFiber(NULL);
    void *fiber = CreateFiber(0, fiber_proc, NULL);
    if (main_fiber && fiber) SwitchToFiber(fiber);
    check("raise and unwind on a fiber stack", fiber_ok, NULL);
    if (fiber) DeleteFiber(fiber);

    HANDLE thread = CreateThread(NULL, 0, thread_proc, NULL, 0, NULL);
    WaitForSingleObject(thread, 10000);
    check("fault and unwind on a second thread", thread_ok, NULL);
#endif
    printf("checks: %d, failures: %d\n", checks, failures);
    return failures;
}
