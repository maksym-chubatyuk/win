// Starts Wine inside this app. The order matters: executable memory has to be
// authorized while the debugger is attached, and Wine only starts after it detaches.

#import <Foundation/Foundation.h>

#include "WineHost.h"
#include "IOSDisplayShim.h"
#include "JITAllocator.h"
#include "WineProcessBridge.h"
#include "WineServerBridge.h"

#include <fcntl.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000u
// Authorizing costs about 1.4 s per 16 MiB through the Mac-side host, so a larger pool
// starts more slowly. FEX's code cache comes out of this pool too, and small pools make
// it restart often. Madeira's own floor is 256 MiB; WIN_POOL_MB overrides the default.
// The pool and its writable alias both take address space, which is scarce here.
static size_t g_pool_size = 256u * 1024u * 1024u;

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static int64_t g_jit_write_offset = 0;
static volatile int g_exit_code = 0;
static volatile bool g_finished = false;

// Wine's process bridge publishes this to the FEX module, which is not loaded for
// native ARM64 programs. Without native FEX linked, it is just the pool's alias distance.
int64_t fex_get_jit_write_offset(void) {
    return g_jit_write_offset;
}

bool win_jit_debugger_flag(void) {
    uint32_t flags = 0;
    return csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED);
}

bool win_wine_finished(int *exit_code) {
    if (g_finished && exit_code) *exit_code = g_exit_code;
    return g_finished;
}

static void finish(FILE *output, int code, const char *reason) {
    if (output) {
        fprintf(output, "[win] wine finished: %s, exit code %d\n", reason, code);
        fflush(output);
    }
    g_exit_code = code;
    g_finished = true;
}

// Fills free address ranges below `limit` that would take the pool's allocation. The
// debugger's allocator is first-fit, so this makes it land at `limit`. Returns how many
// it filled.
static int plug_low_holes(vm_address_t limit, vm_address_t plugs[], vm_size_t sizes[], int max) {
    int count = 0;
    vm_address_t cursor = 0x100000000ul;
    while (cursor < limit && count < max) {
        vm_address_t address = cursor;
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t info_count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                                                (vm_region_recurse_info_t)&info, &info_count);
        vm_address_t hole_end = kr == KERN_SUCCESS && address < limit ? address : limit;
        // A free range running up to `limit` has to be filled whatever its size: it joins
        // the landing site, so the debugger's allocation would start inside it instead.
        if (hole_end > cursor && (hole_end == limit || hole_end - cursor >= g_pool_size)) {
            vm_address_t plug = cursor;
            if (vm_allocate(mach_task_self(), &plug, hole_end - cursor, VM_FLAGS_FIXED) == KERN_SUCCESS) {
                plugs[count] = plug;
                sizes[count] = hole_end - cursor;
                count++;
            }
        }
        if (kr != KERN_SUCCESS || address >= limit) break;
        cursor = address + size;
    }
    return count;
}

// FEX needs the pool at or above this address (see StikJITHelper.swift in Madeira).
#define JIT_POOL_LOW_BOUND 0x119000000ul

// The lowest free range at or above the bound that fits the pool, or 0. The executable
// window is mapped while it is held, so it is never reported as free.
static vm_address_t find_pool_hole(void) {
    vm_address_t cursor = JIT_POOL_LOW_BOUND;
    while (true) {
        vm_address_t address = cursor;
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t info_count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                                                (vm_region_recurse_info_t)&info, &info_count);
        if (kr != KERN_SUCCESS) return 0;
        if (address > cursor && address - cursor >= g_pool_size) return cursor;
        cursor = address + size;
    }
}

static void *allocate_placed_rx(FILE *output) {
    // JITAllocator.c reserves the x64 executable window and, when the space is free at
    // launch, a placeholder above it. Address layout varies between launches, so the
    // placeholder is only the preferred landing site.
    if (madeira_early_window_base) {
        char window[48];
        snprintf(window, sizeof(window), "%lx:%lx", madeira_early_window_base, madeira_early_window_size);
        setenv("WINE_IOS_EXE_WINDOW", window, 1);
    }
    vm_address_t landing = madeira_early_pool_base;
    if (landing) vm_deallocate(mach_task_self(), landing, madeira_early_pool_size);
    // WIN_NO_PLACEHOLDER tests the search below, which a normal launch rarely needs.
    if (!landing || madeira_early_pool_size < g_pool_size || getenv("WIN_NO_PLACEHOLDER")) {
        fprintf(output, "[win] no placeholder at launch (size 0x%lx, first mapping above the window 0x%lx+0x%lx), searching\n",
                madeira_early_pool_size, madeira_early_intruder_base, madeira_early_intruder_size);
        landing = find_pool_hole();
        fprintf(output, "[win] searched for a landing site: 0x%lx\n", (unsigned long)landing);
    }
    if (!landing) {
        fprintf(output, "[win] no free range fits the pool\n");
        return NULL;
    }

    vm_address_t plugs[16];
    vm_size_t sizes[16];
    int plug_count = plug_low_holes(landing, plugs, sizes, 16);
    void *rx = jit26_prepare_region(NULL, g_pool_size);
    for (int i = 0; i < plug_count; i++) vm_deallocate(mach_task_self(), plugs[i], sizes[i]);

    vm_address_t address = (vm_address_t)rx;
    bool overlaps_window = madeira_early_window_base &&
        address < madeira_early_window_base + madeira_early_window_size &&
        address + g_pool_size > madeira_early_window_base;
    if (!rx || address < JIT_POOL_LOW_BOUND || overlaps_window) {
        fprintf(output, "[win] unusable pool placement %p (%d holes plugged)\n", rx, plug_count);
        return NULL;
    }
    return rx;
}

static bool make_jit_pool(FILE *output) {
    const char *megabytes = getenv("WIN_POOL_MB");
    if (megabytes && atoi(megabytes) >= 256) g_pool_size = (size_t)atoi(megabytes) * 1024 * 1024;

    void *rx = allocate_placed_rx(output);
    if (!rx) {
        fprintf(output, "[win] debugger returned no usable executable memory\n");
        return false;
    }

    vm_address_t rw = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, g_pool_size, 0, VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr == KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), rw, g_pool_size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    }
    if (kr != KERN_SUCCESS) {
        fprintf(output, "[win] cannot map writable alias: %s\n", mach_error_string(kr));
        return false;
    }

    // Authorizing dirties every page, which would otherwise count against the app's
    // memory limit. Best effort: this is a private call, and the pool works without it.
    // It has to be applied to the writable alias; the debugger's mapping is refused.
    bool exempt = jit_make_region_no_footprint((void *)rw, g_pool_size, "win pool");
    fprintf(output, "[win] pool exempt from memory limit: %s\n", exempt ? "yes" : "no");

    char value[32];
    snprintf(value, sizeof(value), "%lx", (unsigned long)rx);
    setenv("WINE_IOS_JIT_RX", value, 1);
    snprintf(value, sizeof(value), "%lx", (unsigned long)rw);
    setenv("WINE_IOS_JIT_RW", value, 1);
    snprintf(value, sizeof(value), "%lx", (unsigned long)g_pool_size);
    setenv("WINE_IOS_JIT_SIZE", value, 1);
    g_jit_write_offset = (int64_t)rw - (int64_t)rx;
    fprintf(output, "[win] JIT pool: %zu MiB, RX %p, RW 0x%lx\n",
            g_pool_size / (1024 * 1024), rx, (unsigned long)rw);
    return true;
}

static void pump_guest_stdout(FILE *output) {
    char buffer[4096];
    while (true) {
        long count = madeira_stdout_is_open() ? madeira_stdout_read(buffer, sizeof(buffer)) : -1;
        if (count > 0) {
            fwrite(buffer, 1, (size_t)count, output);
            fflush(output);
            continue;
        }
        if (!wine_process_is_running()) return;
        usleep(50 * 1000);
    }
}

// A desktop session runs the program under Wine's explorer.exe, whose desktop window
// is what the compositor shows.
static void set_program_environment(NSString *exe, NSString *arguments, NSString *folder, int width, int height) {
    if (folder) {
        setenv("MADEIRA_WORKDIR", folder.UTF8String, 1);
    } else {
        unsetenv("MADEIRA_WORKDIR");
    }
    if (width <= 0 || height <= 0) {
        setenv("MADEIRA_EXE", exe.UTF8String, 1);
        if (arguments) setenv("MADEIRA_ARGS", arguments.UTF8String, 1);
        setenv("MADEIRA_DESKTOP", "0", 1);
        return;
    }
    setenv("MADEIRA_SCREEN_W", @(width).stringValue.UTF8String, 1);
    setenv("MADEIRA_SCREEN_H", @(height).stringValue.UTF8String, 1);
    winios_display_mode_changed(width, height);

    // Programs run on their own, with no Wine desktop. WIN_DESKTOP brings the desktop
    // back, which is mainly useful for comparing behavior while debugging.
    if (!getenv("WIN_DESKTOP")) {
        setenv("MADEIRA_EXE", exe.UTF8String, 1);
        if (arguments) setenv("MADEIRA_ARGS", arguments.UTF8String, 1);
        setenv("MADEIRA_DESKTOP", "0", 1);
        // With no explorer, nothing else gives the program's window the foreground, and
        // Wine discards a mouse press when its window cannot become foreground.
        setenv("MADEIRA_INPUT_FOREGROUND", "1", 1);
        return;
    }
    NSString *path = [exe containsString:@"\\"] ? exe : [@"C:\\windows\\system32\\" stringByAppendingString:exe];
    NSString *command = [NSString stringWithFormat:@"/desktop=shell,%dx%d \"%@\"%@%@",
                         width, height, path, arguments ? @" " : @"", arguments ?: @""];
    setenv("MADEIRA_EXE", "explorer.exe", 1);
    setenv("MADEIRA_ARGS", command.UTF8String, 1);
    setenv("MADEIRA_DESKTOP", "1", 1);
}

void win_wine_prepare_prefix(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    madeira_seed_prefix_if_needed([documents stringByAppendingPathComponent:@"wine"].UTF8String);
}

void win_wine_start(const char *exe, const char *args, const char *folder, int desktop_width, int desktop_height) {
    NSString *exeName = @(exe);
    NSString *arguments = args ? @(args) : nil;
    NSString *workingFolder = folder ? @(folder) : nil;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *prefix = [documents stringByAppendingPathComponent:@"wine"];
        NSString *runtimeLog = [documents stringByAppendingPathComponent:@"madeira-log.txt"];
        [[NSFileManager defaultManager] removeItemAtPath:runtimeLog error:nil];

        NSString *outputPath = [documents stringByAppendingPathComponent:@"wine-output.txt"];
        FILE *output = fopen(outputPath.UTF8String, "w");
        if (!output) {
            finish(NULL, -1, "cannot open output file");
            return;
        }
        setvbuf(output, NULL, _IOLBF, 0);

        // WIN_STDERR=1 keeps the runtime's own messages (Wine, DXMT, FEX), which otherwise
        // go nowhere on the phone, in Documents/wine-stderr.txt.
        if (getenv("WIN_STDERR")) {
            NSString *errorPath = [documents stringByAppendingPathComponent:@"wine-stderr.txt"];
            if (freopen(errorPath.UTF8String, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
        }

        bool poolReady = make_jit_pool(output);
        jit26_detach();
        setenv("MADEIRA_DETACHED", "1", 1);
        if (!poolReady) {
            finish(output, -1, "no JIT pool");
            return;
        }

        set_program_environment(exeName, arguments, workingFolder, desktop_width, desktop_height);
        // Madeira reserves a 4 GB arena for FEX by default. Unity reserves memory in 512 MB
        // blocks and ran out of room with it in a 13 GiB address map; the run that worked had
        // the arena off and the Increased Memory Limit entitlement, which also raised the map
        // to 63 GB on this iPhone, so the arena may be affordable again. Kept off because
        // that is the tested setup. MADEIRA_FEX_ARENA set in the environment still wins.
        setenv("MADEIRA_FEX_ARENA", "0", 0);

        // Vulkan for Windows programs: winevulkan on MoltenVK (the same MoltenVK the
        // desktop OpenGL stack, Mesa's Zink, runs on). Madeira keeps it off unless
        // madeira.cfg says otherwise; here it is on whenever the app bundles MoltenVK, and
        // a `vulkan` line in madeira.cfg still wins. 64-bit programs only for now.
        setenv("MADEIRA_VULKAN_DEFAULT", "moltenvk", 0);

        // Controllers for DirectInput games. The on-screen and physical controllers reach
        // Windows as an XInput pad; a game that reads only DirectInput (most older games,
        // e.g. Neptunia Re;Birth1) saw no controller at all, because Madeira hides its
        // DirectInput pad (wine/dlls/dinput/joystick_ios.c) unless asked. On Windows an
        // Xbox controller is visible through both APIs too, with the same Xbox-style layout
        // that device reports, so it is on here. MADEIRA_DINPUT_PAD=0 hides it again, for a
        // game that reads both APIs and would treat the one pad as two.
        setenv("MADEIRA_DINPUT_PAD", "1", 0);

        // Launchers start the real program and exit (Superposition.exe starts
        // bin\launcher.exe). Without this the session ends with the launcher. Madeira
        // keeps it opt-in because a child that ends oddly can keep a session waiting;
        // with one program per launch here, that is the better failure.
        setenv("MADEIRA_WAIT_CHILDREN", "1", 0);

        // Madeira's always-on profilers pause every thread, the game's included, several
        // times a second, and the cheap counters still log 4 times a second. All off by
        // default; WIN_DIAG=1 restores them.
        // DXMT's memory census walks every live buffer and logs ~30 lines several times a
        // second on the thread that encodes GPU work; the throttle keeps one report per
        // 10 s, and its log goes nowhere unless asked for. WIN_DIAG=1 keeps everything.
        if (!getenv("WIN_DIAG")) {
            setenv("MADEIRA_PROBES", "0", 0);
            setenv("MADEIRA_LEAN_DIAG", "1", 0);
            setenv("DXMT_CENSUS_THROTTLE", "1", 0);
            setenv("DXMT_LOG_LEVEL", "none", 0);
        }
        setenv("MADEIRA_STDOUT_PIPE", "1", 1);

        if (wineserver_start(prefix.UTF8String) != 0) {
            finish(output, -1, "wineserver did not start");
            return;
        }
        fprintf(output, "[win] wineserver thread started\n");

        for (int waited = 0; !wineserver_is_ready() && wineserver_is_running() && waited < 1000; waited++) {
            usleep(10 * 1000);
        }
        if (!wineserver_is_ready()) {
            finish(output, -1, "wineserver not ready after 10 s");
            return;
        }
        fprintf(output, "[win] wineserver ready, starting %s\n", exeName.UTF8String);

        if (wine_process_start(prefix.UTF8String) != 0) {
            finish(output, -1, "wine process did not start");
            return;
        }
        pump_guest_stdout(output);
        finish(output, wine_process_exit_code(), "process ended");
        fclose(output);
    });
}
