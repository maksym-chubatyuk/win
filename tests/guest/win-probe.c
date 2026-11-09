// Windows test program for the win app. Builds for x86-64 (runs through FEX) and for
// ARM64 (runs natively), so the two can be compared. Exits 0 only if every check passes.

#include <windows.h>
#include <intrin.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;

static void check(const char *name, int passed) {
    printf("%s: %s\n", passed ? "PASS" : "FAIL", name);
    fflush(stdout);
    if (!passed) failures++;
}

static double seconds_since(LARGE_INTEGER start) {
    LARGE_INTEGER now, frequency;
    QueryPerformanceCounter(&now);
    QueryPerformanceFrequency(&frequency);
    return (double)(now.QuadPart - start.QuadPart) / (double)frequency.QuadPart;
}

#if defined(__x86_64__) || defined(__i386__)
static void check_x86_instructions(void) {
    int regs[4];
    char vendor[13] = {0};
    __cpuid(regs, 0);
    memcpy(vendor, &regs[1], 4);
    memcpy(vendor + 4, &regs[3], 4);
    memcpy(vendor + 8, &regs[2], 4);
    printf("cpuid vendor: %s\n", vendor);
    check("cpuid returns a vendor", vendor[0] != 0);

    // rol and xchg are x86 instructions, so a correct answer means they were translated.
#if defined(__x86_64__)
    uint64_t rotated = 0x0123456789abcdefULL, swapped = 7;
    __asm__ volatile("rolq $8, %0\n\txchgq %0, %1" : "+r"(rotated), "+r"(swapped));
    check("x86 rol and xchg", rotated == 7 && swapped == 0x23456789abcdef01ULL);
#else
    uint32_t rotated = 0x01234567u, swapped = 7;
    __asm__ volatile("roll $8, %0\n\txchgl %0, %1" : "+r"(rotated), "+r"(swapped));
    check("x86 rol and xchg", rotated == 7 && swapped == 0x23456701u);
#endif
}
#endif

static void check_system_info(void) {
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    printf("reported architecture: %u, processors: %lu, page size: %lu\n",
           info.wProcessorArchitecture, info.dwNumberOfProcessors, info.dwPageSize);
    check("Windows page size is 4 KB", info.dwPageSize == 4096);
}

static DWORD WINAPI add_many(LPVOID arg) {
    for (int i = 0; i < 1000000; i++) InterlockedIncrement((volatile LONG *)arg);
    return 0;
}

static void check_threads(void) {
    enum { THREADS = 4 };
    volatile LONG counter = 0;
    HANDLE threads[THREADS];
    int started = 0;
    for (int i = 0; i < THREADS; i++) {
        threads[i] = CreateThread(NULL, 0, add_many, (LPVOID)&counter, 0, NULL);
        if (threads[i]) started++;
    }
    check("threads start", started == THREADS);
    if (started != THREADS) return;
    WaitForMultipleObjects(THREADS, threads, TRUE, 30000);
    for (int i = 0; i < THREADS; i++) CloseHandle(threads[i]);
    printf("counter from %d threads: %ld\n", THREADS, counter);
    check("atomic counter is exact", counter == THREADS * 1000000);
}

static void check_files(void) {
    static const char path[] = "C:\\win-probe-test.txt";
    static const char text[] = "written from a Windows program";
    char back[64] = {0};
    DWORD count = 0;

    HANDLE file = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    check("create file on C:", file != INVALID_HANDLE_VALUE);
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile(file, text, sizeof(text), &count, NULL);
    CloseHandle(file);

    file = CreateFileA(path, GENERIC_READ, 0, NULL, OPEN_EXISTING, 0, NULL);
    ReadFile(file, back, sizeof(back), &count, NULL);
    CloseHandle(file);
    check("read file back", strcmp(back, text) == 0);
    check("delete file", DeleteFileA(path));
}

static void check_memory(void) {
    SIZE_T size = 64 * 1024 * 1024;
    unsigned char *memory = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    check("VirtualAlloc 64 MiB", memory != NULL);
    if (!memory) return;
    memset(memory, 0x5a, size);
    check("memory holds its contents", memory[0] == 0x5a && memory[size - 1] == 0x5a);
    VirtualFree(memory, 0, MEM_RELEASE);
}

// Generates code at runtime, which is how many real programs and engines behave.
static void check_generated_code(void) {
#if defined(__x86_64__) || defined(__i386__)
    static const unsigned char code[] = { 0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3 };  // mov eax, 42; ret
#else
    static const unsigned char code[] = { 0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6 };  // mov w0, #42; ret
#endif
    void *memory = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    check("VirtualAlloc executable memory", memory != NULL);
    if (!memory) return;
    memcpy(memory, code, sizeof(code));
    FlushInstructionCache(GetCurrentProcess(), memory, sizeof(code));
    int result = ((int (*)(void))memory)();
    printf("generated code returned %d\n", result);
    check("run generated code", result == 42);
    VirtualFree(memory, 0, MEM_RELEASE);
}

static void run_benchmark(void) {
    LARGE_INTEGER start;

    // Integer work: same fixed mixing loop on both builds.
    QueryPerformanceCounter(&start);
    uint64_t state = 88172645463325252ULL, sum = 0;
    for (int i = 0; i < 200000000; i++) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        sum += state & 0xff;
    }
    double integer_time = seconds_since(start);
    printf("benchmark integer: %.3f s (checksum %llu)\n", integer_time, (unsigned long long)sum);
    check("integer checksum", sum == BENCHMARK_INTEGER_CHECKSUM);

    // Floating point work.
    QueryPerformanceCounter(&start);
    volatile double value = 0.0;
    for (int i = 1; i <= 100000000; i++) value = value + 1.0 / ((double)i * (double)i);
    printf("benchmark float: %.3f s (result %.6f)\n", seconds_since(start), value);
    check("float result", value > 1.6449 && value < 1.6450);

    // Memory work.
    QueryPerformanceCounter(&start);
    SIZE_T size = 32 * 1024 * 1024;
    unsigned char *a = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    unsigned char *b = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (a && b) {
        for (int i = 0; i < 40; i++) {
            memset(a, i, size);
            memcpy(b, a, size);
        }
    }
    printf("benchmark memory: %.3f s\n", seconds_since(start));
    VirtualFree(a, 0, MEM_RELEASE);
    VirtualFree(b, 0, MEM_RELEASE);
}

int main(void) {
#if defined(__x86_64__)
    printf("win-probe built for x86-64\n");
    check_x86_instructions();
#elif defined(__i386__)
    printf("win-probe built for 32-bit x86\n");
    check_x86_instructions();
#else
    printf("win-probe built for ARM64\n");
#endif
    check_system_info();
    check_threads();
    check_files();
    check_memory();
    run_benchmark();
    // Last, because this is the check most likely to bring the program down.
    check_generated_code();
    printf("failures: %d\n", failures);
    fflush(stdout);
    return failures == 0 ? 0 : 1;
}
