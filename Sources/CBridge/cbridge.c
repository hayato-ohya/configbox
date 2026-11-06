#include "cbridge.h"
#include <dlfcn.h>

typedef CFMutableArrayRef (*fn_MTDeviceCreateList)(void);
typedef void (*fn_MTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
typedef void (*fn_MTUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
typedef int  (*fn_MTDeviceStart)(MTDeviceRef, int);
typedef int  (*fn_MTDeviceStop)(MTDeviceRef);
typedef bool (*fn_MTDeviceIsBuiltIn)(MTDeviceRef);

static void *g_handle = NULL;
static fn_MTDeviceCreateList               p_CreateList;
static fn_MTRegisterContactFrameCallback   p_Register;
static fn_MTUnregisterContactFrameCallback p_Unregister;
static fn_MTDeviceStart                    p_Start;
static fn_MTDeviceStop                     p_Stop;
static fn_MTDeviceIsBuiltIn                p_IsBuiltIn;

static int load(void) {
    if (g_handle) return 1;
    g_handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!g_handle) return 0;
    p_CreateList = (fn_MTDeviceCreateList)dlsym(g_handle, "MTDeviceCreateList");
    p_Register   = (fn_MTRegisterContactFrameCallback)dlsym(g_handle, "MTRegisterContactFrameCallback");
    p_Unregister = (fn_MTUnregisterContactFrameCallback)dlsym(g_handle, "MTUnregisterContactFrameCallback");
    p_Start      = (fn_MTDeviceStart)dlsym(g_handle, "MTDeviceStart");
    p_Stop       = (fn_MTDeviceStop)dlsym(g_handle, "MTDeviceStop");
    p_IsBuiltIn  = (fn_MTDeviceIsBuiltIn)dlsym(g_handle, "MTDeviceIsBuiltIn");
    if (!p_CreateList || !p_Register || !p_Start || !p_Stop) { g_handle = NULL; return 0; }
    return 1;
}

int cb_mt_available(void) { return load(); }

CFArrayRef cb_mt_create_device_list(void) {
    if (!load()) return NULL;
    return p_CreateList();
}
void cb_mt_register(MTDeviceRef dev, MTContactCallback cb)   { if (load()) p_Register(dev, cb); }
void cb_mt_unregister(MTDeviceRef dev, MTContactCallback cb) { if (load() && p_Unregister) p_Unregister(dev, cb); }
int  cb_mt_start(MTDeviceRef dev)  { return load() ? p_Start(dev, 0) : -1; }
int  cb_mt_stop(MTDeviceRef dev)   { return load() ? p_Stop(dev) : -1; }
int  cb_mt_is_builtin(MTDeviceRef dev) { return (load() && p_IsBuiltIn) ? (int)p_IsBuiltIn(dev) : 0; }

extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outID);
AXError cb_ax_window_id(AXUIElementRef element, CGWindowID *outID) {
    return _AXUIElementGetWindow(element, outID);
}

// ---- SkyLight ---------------------------------------------------------------
#include <string.h>
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);

int cb_focus_window(pid_t pid, CGWindowID wid) {
    ProcessSerialNumber psn = {0, 0};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(pid, &psn) != noErr) return -1;
#pragma clang diagnostic pop
    // kCPSUserGenerated = 0x200
    CGError err = _SLPSSetFrontProcessWithOptions(&psn, wid, 0x200);
    // Tell the app which of its windows should become key (undocumented event record).
    uint8_t bytes[0xf8];
    memset(bytes, 0, sizeof(bytes));
    bytes[0x04] = 0xF8;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &wid, sizeof(wid));
    memset(bytes + 0x20, 0xFF, 0x10);
    bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(&psn, bytes);
    bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(&psn, bytes);
    return (int)err;
}

// ---- IOHIDEventSystemClient -------------------------------------------------
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator, int type, CFDictionaryRef attributes);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern Boolean IOHIDEventSystemClientSetProperty(IOHIDEventSystemClientRef client, CFStringRef key, CFTypeRef value);
extern CFTypeRef IOHIDEventSystemClientCopyProperty(IOHIDEventSystemClientRef client, CFStringRef key);
extern Boolean IOHIDServiceClientSetProperty(IOHIDServiceClientRef service, CFStringRef key, CFTypeRef value);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);

void *cb_hid_client_create(void) {
    // 2 = kIOHIDEventSystemClientTypePassive: may read and set properties without an entitlement.
    return (void *)IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 2, NULL);
}
CFArrayRef cb_hid_client_copy_services(void *client) { return IOHIDEventSystemClientCopyServices((IOHIDEventSystemClientRef)client); }
CFTypeRef cb_hid_service_copy_property(void *service, CFStringRef key) { return IOHIDServiceClientCopyProperty((IOHIDServiceClientRef)service, key); }
int cb_hid_service_set_property(void *service, CFStringRef key, CFTypeRef value) { return IOHIDServiceClientSetProperty((IOHIDServiceClientRef)service, key, value) ? 1 : 0; }
int cb_hid_client_set_property(void *client, CFStringRef key, CFTypeRef value) { return IOHIDEventSystemClientSetProperty((IOHIDEventSystemClientRef)client, key, value) ? 1 : 0; }
CFTypeRef cb_hid_client_copy_property(void *client, CFStringRef key) { return IOHIDEventSystemClientCopyProperty((IOHIDEventSystemClientRef)client, key); }
