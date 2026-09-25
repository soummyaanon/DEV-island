// window-pin.node — one AppKit call Electron doesn't expose.
//
// macOS's "click wallpaper to reveal desktop", Show Desktop, Stage Manager and
// Mission Control slide every ordinary window out of the way. That shove
// happens in the window server, so the window's own frame never changes —
// Electron sees no move and can't put it back, and the island ended up at the
// bottom of the screen. NSWindowCollectionBehaviorStationary is exactly the
// "don't move me" flag the desktop itself uses, so we set it.
//
// Node-API (ABI-stable), so the same binary loads in any Electron without a
// rebuild. Built by scripts/build-native.sh; optional — main falls back to
// the snap-back timer when it's missing.

#import <AppKit/AppKit.h>
#include <node_api.h>

// setStationary(handle: Buffer) -> boolean
// `handle` is BrowserWindow.getNativeWindowHandle(): the window's NSView*.
static napi_value SetStationary(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_value result;
  bool ok = false;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) == napi_ok && argc == 1) {
    void *data = NULL;
    size_t length = 0;
    if (napi_get_buffer_info(env, argv[0], &data, &length) == napi_ok && length >= sizeof(void *)) {
      NSView *view = (__bridge NSView *)(*(void **)data);
      NSWindow *window = [view isKindOfClass:[NSView class]] ? view.window : nil;
      if (window != nil) {
        NSWindowCollectionBehavior behavior = window.collectionBehavior;
        // Stationary and Managed/Transient are mutually exclusive "Exposé"
        // behaviours; clear the others before setting it.
        behavior &= ~(NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorTransient);
        behavior |= NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces |
                    NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
        window.collectionBehavior = behavior;
        ok = (window.collectionBehavior & NSWindowCollectionBehaviorStationary) != 0;
      }
    }
  }
  napi_get_boolean(env, ok, &result);
  return result;
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_value fn;
  napi_create_function(env, "setStationary", NAPI_AUTO_LENGTH, SetStationary, NULL, &fn);
  napi_set_named_property(env, exports, "setStationary", fn);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
