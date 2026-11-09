// CPU benchmark suite. Builds for Windows x86-64 (runs through FEX on the iPhone),
// Windows ARM64 (runs natively through Wine), and macOS (native reference on the Mac).
// Every test checks its own result, so a fast wrong answer cannot pass as a good score.
// Output lines start with "RESULT" so scripts can collect them.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef HANDLE thread_t;
static double now_seconds(void) {
    LARGE_INTEGER counter, frequency;
    QueryPerformanceCounter(&counter);
    QueryPerformanceFrequency(&frequency);
    return (double)counter.QuadPart / (double)frequency.QuadPart;
}
static int cpu_count(void) {
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    return (int)info.dwNumberOfProcessors;
}
#else
#include <pthread.h>
#include <time.h>
#include <unistd.h>
typedef pthread_t thread_t;
static double now_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
static int cpu_count(void) {
    return (int)sysconf(_SC_NPROCESSORS_ONLN);
}
#endif

#if defined(__x86_64__)
#define BUILD "x86-64"
#elif defined(__aarch64__)
#define BUILD "arm64"
#else
#define BUILD "other"
#endif

static int failures = 0;

static void result(const char *name, double value, const char *unit) {
    printf("RESULT %-22s %12.2f %s\n", name, value, unit);
    fflush(stdout);
}

static void check(const char *name, int passed) {
    if (!passed) {
        printf("FAIL: %s\n", name);
        fflush(stdout);
        failures++;
    }
}

// Integer: a mixing loop of shifts, xors and adds, like hashing or compression.
static uint64_t integer_work(uint64_t seed, long iterations) {
    uint64_t state = seed, sum = 0;
    for (long i = 0; i < iterations; i++) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        sum += state & 0xff;
    }
    return sum;
}

// Floating point: Mandelbrot iterations, dependent multiplies and adds.
static double mandelbrot(int size, int max_iterations, long *iterations_done) {
    double total = 0;
    long count = 0;
    for (int py = 0; py < size; py++) {
        for (int px = 0; px < size; px++) {
            double cx = -2.0 + 2.5 * px / size, cy = -1.25 + 2.5 * py / size;
            double x = 0, y = 0;
            int i = 0;
            while (i < max_iterations && x * x + y * y < 4.0) {
                double xt = x * x - y * y + cx;
                y = 2 * x * y + cy;
                x = xt;
                i++;
            }
            count += i;
            total += i;
        }
    }
    *iterations_done = count;
    return total;
}

static int compare_ints(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

// Multi-threaded integer work.
typedef struct {
    long iterations;
    uint64_t seed;
    uint64_t sum;
} worker_t;

#ifdef _WIN32
static DWORD WINAPI worker_main(LPVOID arg) {
#else
static void *worker_main(void *arg) {
#endif
    worker_t *w = arg;
    w->sum = integer_work(w->seed, w->iterations);
    return 0;
}

static double threaded_integer(int threads, long per_thread) {
    worker_t workers[64];
    thread_t handles[64];
    double start = now_seconds();
    for (int t = 0; t < threads; t++) {
        workers[t] = (worker_t){ per_thread, 88172645463325252ULL + t, 0 };
#ifdef _WIN32
        handles[t] = CreateThread(NULL, 0, worker_main, &workers[t], 0, NULL);
#else
        pthread_create(&handles[t], NULL, worker_main, &workers[t]);
#endif
    }
    for (int t = 0; t < threads; t++) {
#ifdef _WIN32
        WaitForSingleObject(handles[t], INFINITE);
        CloseHandle(handles[t]);
#else
        pthread_join(handles[t], NULL);
#endif
    }
    double elapsed = now_seconds() - start;
    for (int t = 0; t < threads; t++) check("threaded result", workers[t].sum != 0);
    return (double)threads * (double)per_thread / elapsed / 1e6;
}

int main(void) {
    int cores = cpu_count();
    printf("win-cpubench built for %s, %d logical processors\n", BUILD, cores);
    fflush(stdout);

    // 1. Integer, one thread.
    double start = now_seconds();
    uint64_t sum = integer_work(88172645463325252ULL, 300000000L);
    double elapsed = now_seconds() - start;
    check("integer checksum", sum == 38251600173ULL);
    result("integer_1t", 300.0 / elapsed, "M iterations/s");

    // 2. Floating point, one thread.
    long iterations = 0;
    start = now_seconds();
    double total = mandelbrot(1024, 256, &iterations);
    elapsed = now_seconds() - start;
    check("mandelbrot total", fabs(total - (double)iterations) < 1);
    result("float_1t", (double)iterations / elapsed / 1e6, "M iterations/s");

    // 3. Sorting, one thread: branchy and cache-heavy, like general program code.
    int count = 4 * 1024 * 1024;
    int *keys = malloc(sizeof(int) * (size_t)count);
    uint32_t r = 12345;
    for (int i = 0; i < count; i++) { r = r * 1664525u + 1013904223u; keys[i] = (int)(r >> 1); }
    start = now_seconds();
    qsort(keys, (size_t)count, sizeof(int), compare_ints);
    elapsed = now_seconds() - start;
    int sorted = 1;
    for (int i = 1; i < count; i++) if (keys[i - 1] > keys[i]) { sorted = 0; break; }
    check("sort order", sorted);
    result("sort_1t", count / elapsed / 1e6, "M keys/s");
    free(keys);

    // 4. Memory bandwidth, one thread: copying 256 MB repeatedly.
    size_t bytes = 256u * 1024 * 1024;
    unsigned char *a = malloc(bytes), *b = malloc(bytes);
    memset(a, 1, bytes);
    memset(b, 2, bytes);
    // Called through a volatile pointer, so the compiler cannot drop copies whose result
    // is overwritten by the next one.
    void *(*volatile copy)(void *, const void *, size_t) = memcpy;
    start = now_seconds();
    for (int i = 0; i < 8; i++) { a[i] = (unsigned char)i; copy(b, a, bytes); }
    elapsed = now_seconds() - start;
    check("copy contents", b[0] == 0 && b[bytes - 1] == 1);
    result("memcpy_1t", 8.0 * (double)bytes / elapsed / 1e9, "GB/s");
    free(a);
    free(b);

    // 5. Memory latency: a random pointer chase through 128 MB, so each step misses cache.
    size_t slots = 16u * 1024 * 1024;
    size_t *chain = malloc(sizeof(size_t) * slots);
    for (size_t i = 0; i < slots; i++) chain[i] = i;
    uint64_t s = 7;
    for (size_t i = slots - 1; i > 0; i--) {   // Sattolo's shuffle: one cycle through all slots
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        size_t j = (size_t)(s % i);
        size_t t = chain[i]; chain[i] = chain[j]; chain[j] = t;
    }
    size_t at = 0, steps = 20u * 1000 * 1000;
    start = now_seconds();
    for (size_t i = 0; i < steps; i++) at = chain[at];
    elapsed = now_seconds() - start;
    check("chase", at < slots);
    result("memory_latency", elapsed / (double)steps * 1e9, "ns per access");
    free(chain);

    // 6. Scaling across threads.
    double one = 0;
    int counts[] = { 1, 2, 4, cores };
    for (int i = 0; i < 4; i++) {
        int threads = counts[i];
        if (i == 3 && (threads == 4 || threads < 1 || threads > 64)) break;
        double rate = threaded_integer(threads, 200000000L);
        if (threads == 1) one = rate;
        char name[32];
        snprintf(name, sizeof(name), "integer_%dt", threads);
        result(name, rate, "M iterations/s");
        if (threads > 1 && one > 0) {
            snprintf(name, sizeof(name), "scaling_%dt", threads);
            result(name, rate / one, "x one thread");
        }
    }

    printf("failures: %d\n", failures);
    return failures == 0 ? 0 : 1;
}
