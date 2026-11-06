#ifndef CBRIDGE_H
#define CBRIDGE_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>

// ---- MultitouchSupport.framework (private) --------------------------------
// Struct layout as reverse-engineered and used by many open-source tools.

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;

typedef struct {
    int32_t   frame;
    double    timestamp;
    int32_t   identifier;
    int32_t   state;      // 1 start, 2 hover, 3 make touch, 4 touching, 5 break, 6 lingering, 7 out of range
    int32_t   fingerId;
    int32_t   handId;
    MTReadout normalized; // 0..1, origin bottom-left
    float     size;
    int32_t   zero1;
    float     angle;
    float     majorAxis;
    float     minorAxis;
    MTReadout mm;
    int32_t   zero2[2];
    float     unknown;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef device, MTTouch *touches, int32_t count, double timestamp, int32_t frame);

int        cb_mt_available(void);
CFArrayRef cb_mt_create_device_list(void) CF_RETURNS_RETAINED;
void       cb_mt_register(MTDeviceRef dev, MTContactCallback cb);
void       cb_mt_unregister(MTDeviceRef dev, MTContactCallback cb);
int        cb_mt_start(MTDeviceRef dev);
int        cb_mt_stop(MTDeviceRef dev);
int        cb_mt_is_builtin(MTDeviceRef dev);

// ---- Accessibility private helper ----------------------------------------
AXError cb_ax_window_id(AXUIElementRef element, CGWindowID *outID);



// ---- IOHIDEventSystemClient (private) --------------------------------------
// Used to read / write per-device pointer properties (resolution = speed, acceleration),
// the same mechanism LinearMouse and similar tools use. All calls are user-level.
void      *cb_hid_client_create(void);                       // CFRetain'ed; release with CFRelease
CFArrayRef cb_hid_client_copy_services(void *client) CF_RETURNS_RETAINED;
CFTypeRef  cb_hid_service_copy_property(void *service, CFStringRef key) CF_RETURNS_RETAINED;
int        cb_hid_service_set_property(void *service, CFStringRef key, CFTypeRef value);
int        cb_hid_client_set_property(void *client, CFStringRef key, CFTypeRef value);
CFTypeRef  cb_hid_client_copy_property(void *client, CFStringRef key) CF_RETURNS_RETAINED;

// ---- SkyLight private window focusing (same approach as AltTab / yabai) -----
// Brings a specific window of another process to the front, including from a background app
// where NSRunningApplication.activate() is refused by cooperative activation on macOS 14+.
int cb_focus_window(pid_t pid, CGWindowID wid);
#endif
