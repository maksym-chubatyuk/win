// Vulkan through winevulkan for the iOS port: load vulkan-1.dll, create an instance and a
// device on the first GPU, and round-trip data through mapped device memory. 64-bit
// only (winevulkan has no 32-bit unix table here). The toolchain has no Vulkan headers,
// so the few structures used are declared below with the Vulkan C layout.

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct VkApplicationInfo { int sType; const void *pNext; const char *pApplicationName; uint32_t applicationVersion;
    const char *pEngineName; uint32_t engineVersion; uint32_t apiVersion; } VkApplicationInfo;
typedef struct VkInstanceCreateInfo { int sType; const void *pNext; uint32_t flags; const VkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount; const char *const *ppEnabledLayerNames; uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames; } VkInstanceCreateInfo;
typedef struct VkDeviceQueueCreateInfo { int sType; const void *pNext; uint32_t flags; uint32_t queueFamilyIndex;
    uint32_t queueCount; const float *pQueuePriorities; } VkDeviceQueueCreateInfo;
typedef struct VkDeviceCreateInfo { int sType; const void *pNext; uint32_t flags; uint32_t queueCreateInfoCount;
    const VkDeviceQueueCreateInfo *pQueueCreateInfos; uint32_t enabledLayerCount; const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount; const char *const *ppEnabledExtensionNames; const void *pEnabledFeatures; } VkDeviceCreateInfo;
typedef struct VkBufferCreateInfo { int sType; const void *pNext; uint32_t flags; uint64_t size; uint32_t usage;
    uint32_t sharingMode; uint32_t queueFamilyIndexCount; const uint32_t *pQueueFamilyIndices; } VkBufferCreateInfo;
typedef struct VkMemoryRequirements { uint64_t size, alignment; uint32_t memoryTypeBits; } VkMemoryRequirements;
typedef struct VkMemoryType { uint32_t propertyFlags, heapIndex; } VkMemoryType;
typedef struct VkMemoryHeap { uint64_t size; uint32_t flags; } VkMemoryHeap;
typedef struct VkPhysicalDeviceMemoryProperties { uint32_t memoryTypeCount; VkMemoryType memoryTypes[32];
    uint32_t memoryHeapCount; VkMemoryHeap memoryHeaps[16]; } VkPhysicalDeviceMemoryProperties;
typedef struct VkMemoryAllocateInfo { int sType; const void *pNext; uint64_t allocationSize; uint32_t memoryTypeIndex; } VkMemoryAllocateInfo;
typedef struct VkQueueFamilyProperties { uint32_t queueFlags, queueCount, timestampValidBits; uint32_t granularity[3]; } VkQueueFamilyProperties;

typedef void *VkHandle;
typedef void (*PFN_void)(void);
typedef PFN_void (*PFN_vkGetInstanceProcAddr)(VkHandle, const char *);

static int checks, failures;
static void check(const char *name, int ok, const char *detail) {
    printf("%-4s %2d %-40s %s\n", ok ? "ok" : "FAIL", checks++, name, detail ? detail : "");
    if (!ok) failures++;
}

int main(void) {
    char detail[300];
    HMODULE vulkan = LoadLibraryA("vulkan-1.dll");
    check("LoadLibrary vulkan-1.dll", vulkan != NULL, NULL);
    if (!vulkan) goto done;
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)(void *)GetProcAddress(vulkan, "vkGetInstanceProcAddr");
    check("vkGetInstanceProcAddr", gipa != NULL, NULL);
    if (!gipa) goto done;

    int (*enumerate_version)(uint32_t *) = (void *)gipa(NULL, "vkEnumerateInstanceVersion");
    uint32_t api = 0;
    if (enumerate_version) enumerate_version(&api);
    snprintf(detail, sizeof detail, "%u.%u.%u", api >> 22, (api >> 12) & 0x3ff, api & 0xfff);
    check("vkEnumerateInstanceVersion", api >= (1u << 22), detail);

    VkApplicationInfo app = { 0, NULL, "win-vulkan", 1, "none", 1, (1u << 22) | (1u << 12) };
    VkInstanceCreateInfo instance_info = { 1, NULL, 0, &app, 0, NULL, 0, NULL };
    VkHandle instance = NULL;
    int (*create_instance)(const VkInstanceCreateInfo *, const void *, VkHandle *) = (void *)gipa(NULL, "vkCreateInstance");
    int result = create_instance ? create_instance(&instance_info, NULL, &instance) : -1;
    snprintf(detail, sizeof detail, "result %d", result);
    check("vkCreateInstance", result == 0 && instance, detail);
    if (result) goto done;

#define LOAD(name) void *name = (void *)gipa(instance, #name)
    LOAD(vkEnumeratePhysicalDevices); LOAD(vkGetPhysicalDeviceProperties); LOAD(vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD(vkGetPhysicalDeviceMemoryProperties); LOAD(vkCreateDevice); LOAD(vkCreateBuffer); LOAD(vkGetBufferMemoryRequirements);
    LOAD(vkAllocateMemory); LOAD(vkBindBufferMemory); LOAD(vkMapMemory); LOAD(vkUnmapMemory); LOAD(vkDestroyBuffer);
    LOAD(vkFreeMemory); LOAD(vkDestroyDevice); LOAD(vkDestroyInstance);

    uint32_t count = 0;
    ((int (*)(VkHandle, uint32_t *, VkHandle *))vkEnumeratePhysicalDevices)(instance, &count, NULL);
    VkHandle gpus[8] = {0};
    if (count > 8) count = 8;
    ((int (*)(VkHandle, uint32_t *, VkHandle *))vkEnumeratePhysicalDevices)(instance, &count, gpus);
    check("a Vulkan GPU is listed", count > 0, NULL);
    if (!count) goto done;

    unsigned char props[1024] = {0};  // VkPhysicalDeviceProperties: name at offset 20
    ((void (*)(VkHandle, void *))vkGetPhysicalDeviceProperties)(gpus[0], props);
    uint32_t gpu_api;
    memcpy(&gpu_api, props, 4);
    snprintf(detail, sizeof detail, "%s, Vulkan %u.%u", (const char *)props + 20, gpu_api >> 22, (gpu_api >> 12) & 0x3ff);
    check("GPU properties", props[20] != 0, detail);

    VkQueueFamilyProperties families[8];
    uint32_t family_count = 8;
    ((void (*)(VkHandle, uint32_t *, VkQueueFamilyProperties *))vkGetPhysicalDeviceQueueFamilyProperties)(gpus[0], &family_count, families);
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = { 2, NULL, 0, 0, 1, &priority };
    VkDeviceCreateInfo device_info = { 3, NULL, 0, 1, &queue, 0, NULL, 0, NULL, NULL };
    VkHandle device = NULL;
    result = ((int (*)(VkHandle, const VkDeviceCreateInfo *, const void *, VkHandle *))vkCreateDevice)(gpus[0], &device_info, NULL, &device);
    snprintf(detail, sizeof detail, "result %d, %u queue families", result, family_count);
    check("vkCreateDevice", result == 0 && device, detail);
    if (result) goto done;

    // A host-visible buffer: write through one mapping, read back through another.
    VkBufferCreateInfo buffer_info = { 12, NULL, 0, 4096, 0x1 /* TRANSFER_SRC */, 0, 0, NULL };
    uint64_t buffer = 0, memory = 0;
    result = ((int (*)(VkHandle, const VkBufferCreateInfo *, const void *, uint64_t *))vkCreateBuffer)(device, &buffer_info, NULL, &buffer);
    VkMemoryRequirements requirements = {0};
    ((void (*)(VkHandle, uint64_t, VkMemoryRequirements *))vkGetBufferMemoryRequirements)(device, buffer, &requirements);
    VkPhysicalDeviceMemoryProperties memory_props;
    ((void (*)(VkHandle, VkPhysicalDeviceMemoryProperties *))vkGetPhysicalDeviceMemoryProperties)(gpus[0], &memory_props);
    uint32_t type = 0;
    while (type < memory_props.memoryTypeCount &&
           (!(requirements.memoryTypeBits & (1u << type)) || (memory_props.memoryTypes[type].propertyFlags & 0x6) != 0x6))
        type++;  // HOST_VISIBLE | HOST_COHERENT
    VkMemoryAllocateInfo allocate = { 5, NULL, requirements.size, type };
    int allocated = ((int (*)(VkHandle, const VkMemoryAllocateInfo *, const void *, uint64_t *))vkAllocateMemory)(device, &allocate, NULL, &memory);
    int bound = ((int (*)(VkHandle, uint64_t, uint64_t, uint64_t))vkBindBufferMemory)(device, buffer, memory, 0);
    void *mapped = NULL;
    ((int (*)(VkHandle, uint64_t, uint64_t, uint64_t, uint32_t, void **))vkMapMemory)(device, memory, 0, 4096, 0, &mapped);
    if (mapped) memset(mapped, 0x5a, 4096);
    ((void (*)(VkHandle, uint64_t))vkUnmapMemory)(device, memory);
    mapped = NULL;
    ((int (*)(VkHandle, uint64_t, uint64_t, uint64_t, uint32_t, void **))vkMapMemory)(device, memory, 0, 4096, 0, &mapped);
    int intact = mapped && ((unsigned char *)mapped)[0] == 0x5a && ((unsigned char *)mapped)[4095] == 0x5a;
    snprintf(detail, sizeof detail, "create %d, memory type %u, allocate %d, bind %d", result, type, allocated, bound);
    check("mapped device memory round trip", result == 0 && allocated == 0 && bound == 0 && intact, detail);
    ((void (*)(VkHandle, uint64_t))vkUnmapMemory)(device, memory);
    ((void (*)(VkHandle, uint64_t, const void *))vkDestroyBuffer)(device, buffer, NULL);
    ((void (*)(VkHandle, uint64_t, const void *))vkFreeMemory)(device, memory, NULL);
    ((void (*)(VkHandle, const void *))vkDestroyDevice)(device, NULL);
    ((void (*)(VkHandle, const void *))vkDestroyInstance)(instance, NULL);

done:
    printf("checks: %d, failures: %d\n", checks, failures);
    return failures;
}
