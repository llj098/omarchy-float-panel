#include "drag_strip.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <format>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <src/desktop/state/FocusState.hpp>
#include <src/desktop/state/ViewHitTester.hpp>
#include <src/managers/input/InputManager.hpp>
#include <src/managers/fullscreen/FullscreenController.hpp>
#include <src/protocols/XDGShell.hpp>
#include <src/protocols/core/Compositor.hpp>
#include <src/desktop/state/WindowState.hpp>
#include <src/desktop/view/Window.hpp>
#include <src/render/pass/SurfacePassElement.hpp>
#include <src/event/EventBus.hpp>
#include <src/plugins/PluginAPI.hpp>
#include <src/version.h>
#include <src/xwayland/XWayland.hpp>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}


namespace {

HANDLE pluginHandle = nullptr;

using CustomEvent = Event::CEventBus::CCustomEvent;

SP<CustomEvent>                                    maximizeRequestEvent;
SP<CustomEvent>                                    minimizeRequestEvent;
SP<CustomEvent>                                    focusReasonEvent;
SP<CustomEvent>                                    pointerButtonEvent;
CHyprSignalListener                                configPreReloadListener;
CHyprSignalListener                                configReloadedListener;
CHyprSignalListener                                windowCreateListener;
CHyprSignalListener                                windowDestroyListener;
CHyprSignalListener                                focusReasonListener;
CHyprSignalListener                                pointerButtonListener;
CFunctionHook*                                     setMaximizedHook = nullptr;
std::unordered_map<uintptr_t, CHyprSignalListener> maximizeRequestListeners;
uint64_t                                           configReloadGeneration    = 0;
uint64_t                                           announcedReloadGeneration = 0;

std::string windowAddress(const PHLWINDOW& window) {
    return std::format("0x{:x}", reinterpret_cast<uintptr_t>(window.get()));
}

PHLWINDOW windowFromAddress(std::string_view address) {
    for (const auto& window : Desktop::windowState()->windows()) {
        if (window && windowAddress(window) == address)
            return window;
    }
    return nullptr;
}

std::string x11WindowType(const PHLWINDOW& window) {
    if (!window || !window->m_isX11 || !window->m_xwaylandSurface)
        return "wayland";

    static constexpr std::array<std::pair<std::string_view, std::string_view>, 14> types = {{
        {"_NET_WM_WINDOW_TYPE_NORMAL", "normal"},
        {"_NET_WM_WINDOW_TYPE_DIALOG", "dialog"},
        {"_NET_WM_WINDOW_TYPE_UTILITY", "utility"},
        {"_NET_WM_WINDOW_TYPE_TOOLBAR", "toolbar"},
        {"_NET_WM_WINDOW_TYPE_SPLASH", "splash"},
        {"_NET_WM_WINDOW_TYPE_MENU", "menu"},
        {"_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", "dropdown_menu"},
        {"_NET_WM_WINDOW_TYPE_POPUP_MENU", "popup_menu"},
        {"_NET_WM_WINDOW_TYPE_TOOLTIP", "tooltip"},
        {"_NET_WM_WINDOW_TYPE_NOTIFICATION", "notification"},
        {"_NET_WM_WINDOW_TYPE_COMBO", "combo"},
        {"_NET_WM_WINDOW_TYPE_DND", "dnd"},
        {"_NET_WM_WINDOW_TYPE_DESKTOP", "desktop"},
        {"_NET_WM_WINDOW_TYPE_DOCK", "dock"},
    }};

    // Preserve the application's EWMH preference order when multiple types
    // are present. A missing or unknown type defaults to NORMAL per EWMH.
    for (const auto atom : window->m_xwaylandSurface->m_atoms) {
        for (const auto& [atomName, typeName] : types) {
            const auto known = HYPRATOMS.find(std::string{atomName});
            if (known != HYPRATOMS.end() && known->second == atom)
                return std::string{typeName};
        }
    }
    return "normal";
}

void setBoolean(lua_State* state, const char* key, bool value) {
    lua_pushboolean(state, value);
    lua_setfield(state, -2, key);
}

void setString(lua_State* state, const char* key, std::string_view value) {
    lua_pushlstring(state, value.data(), value.size());
    lua_setfield(state, -2, key);
}

bool hasStateSurface(const PHLWINDOW& window) {
    if (!window)
        return false;
    if (window->m_isX11)
        return window->m_xwaylandSurface != nullptr;
    return window->m_xdgSurface && window->m_xdgSurface->m_toplevel;
}

void forwardMaximizeRequest(const PHLWINDOWREF& reference) {
    const auto window = reference.lock();
    if (!window || !maximizeRequestEvent || !hasStateSurface(window))
        return;

    const auto request = window->m_isX11 ? window->m_xwaylandSurface->m_state.requestsMaximize :
                                           window->m_xdgSurface->m_toplevel->m_state.requestsMaximize;
    if (!request.has_value())
        return;

    const auto result = maximizeRequestEvent->emit({PHLWINDOWREF(window), *request});
    (void)result;
}

void forwardMinimizeRequest(const PHLWINDOWREF& reference) {
    const auto window = reference.lock();
    if (!window || !minimizeRequestEvent || !hasStateSurface(window))
        return;

    const auto request = window->m_isX11 ? window->m_xwaylandSurface->m_state.requestsMinimize :
                                           window->m_xdgSurface->m_toplevel->m_state.requestsMinimize;
    if (!request.has_value())
        return;

    const auto result = minimizeRequestEvent->emit({PHLWINDOWREF(window), *request});
    (void)result;
}

void trackMaximizeRequests(const PHLWINDOW& window) {
    if (!hasStateSurface(window))
        return;

    const auto reference = PHLWINDOWREF(window);
    const auto listener  = window->m_isX11 ?
         window->m_xwaylandSurface->m_events.stateChanged.listen([reference] { forwardMaximizeRequest(reference); forwardMinimizeRequest(reference); }) :
         window->m_xdgSurface->m_toplevel->m_events.stateChanged.listen([reference] { forwardMaximizeRequest(reference); forwardMinimizeRequest(reference); });
    maximizeRequestListeners[reinterpret_cast<uintptr_t>(window.get())] = listener;
}

int luaCapabilities(lua_State* state) {
    lua_newtable(state);
    setBoolean(state, "maximize_request_event", true);
    setBoolean(state, "focus_reason_event", true);
    setBoolean(state, "pointer_button_event", true);
    setBoolean(state, "truthful_maximize_state", setMaximizedHook != nullptr);
    setBoolean(state, "minimize_request_event", true);
    setBoolean(state, "decoration_input_v1", DragStrip::ready());
    setBoolean(state, "drag_lifecycle_v1", DragStrip::ready());
    return 1;
}

void pushTruthfulMaximizeState(PHLWINDOW window);

// Push the window's current box and state list to its client once. A state-only
// change (the float-panel split keeps the box) never crosses setSize on its own,
// so the client would keep drawing the glyph of the previous state.
int luaPushWindowState(lua_State* state) {
    const std::string_view address = luaL_checkstring(state, 1);
    const auto             window  = windowFromAddress(address);
    if (window)
        pushTruthfulMaximizeState(window);
    return 0;
}

bool               clientReportsDecorationMargins(CXDGToplevelResource* self);
Vector2D           decorationRing(CXDGToplevelResource* self);

int luaWindowSemantics(lua_State* state) {
    const std::string_view address = luaL_checkstring(state, 1);
    const auto             window  = windowFromAddress(address);

    lua_newtable(state);
    if (!window) {
        setBoolean(state, "found", false);
        return 1;
    }

    const auto parent           = window->parent();
    const bool hasParent        = static_cast<bool>(parent);
    const bool transient        = window->m_isX11 && window->m_xwaylandSurface && window->m_xwaylandSurface->m_transient;
    const bool overrideRedirect = window->m_isX11 && window->isX11OverrideRedirect();
    const auto type             = x11WindowType(window);
    const auto* sizeHints       = window->m_isX11 && window->m_xwaylandSurface ? window->m_xwaylandSurface->m_sizeHints.get() : nullptr;
    const bool pPosition        = sizeHints && (sizeHints->flags & XCB_ICCCM_SIZE_HINT_P_POSITION);
    const bool usPosition       = sizeHints && (sizeHints->flags & XCB_ICCCM_SIZE_HINT_US_POSITION);

    // Expose compositor facts only. Persistence and placement policies belong
    // to the Lua consumer so they can change without rebuilding this bridge.
    setBoolean(state, "found", true);
    lua_pushinteger(state, window->getRealBorderSize());
    lua_setfield(state, -2, "border_size");
    setBoolean(state, "xwayland", window->m_isX11);
    setBoolean(state, "has_parent", hasParent);
    if (parent)
        setString(state, "parent_address", windowAddress(parent));
    setBoolean(state, "transient", transient);
    setBoolean(state, "override_redirect", overrideRedirect);
    setString(state, "window_type", type);
    setBoolean(state, "program_position", pPosition);
    setBoolean(state, "user_position", usPosition);
    setBoolean(state, "position_specified", pPosition || usPosition);
    // Compositor maximize facts. A window can be maximized for its client while
    // the compositor holds no internal maximize state (the float-panel split).
    if (Fullscreen::controller()) {
        const auto modes = Fullscreen::controller()->getFullscreenModes(window);
        setBoolean(state, "maximize_internal", modes.internal == Fullscreen::FSMODE_MAXIMIZED);
        setBoolean(state, "maximize_client", modes.client == Fullscreen::FSMODE_MAXIMIZED);
    } else {
        setBoolean(state, "maximize_internal", false);
        setBoolean(state, "maximize_client", false);
    }
    // Size limits the client itself declares. A client may pin its window to one
    // size (min == max); every resize the compositor applies is then clamped away,
    // so a placement that resizes and moves would drag the window around without
    // ever changing its size.
    // The rule-adjusted accessors are not the truth here: this plugin itself
    // relaxes a window's min size with a rule, while the compositor keeps clamping
    // every resize to what the client declared on the toplevel. Read the client's
    // own numbers so a pinned window is recognised as pinned.
    Vector2D minSize{};
    Vector2D maxSize{};
    bool     haveLimits = false;
    if (window->m_isX11 && window->m_xwaylandSurface && window->m_xwaylandSurface->m_sizeHints) {
        const auto* hints = window->m_xwaylandSurface->m_sizeHints.get();
        minSize           = Vector2D{static_cast<double>(hints->min_width), static_cast<double>(hints->min_height)};
        maxSize           = Vector2D{static_cast<double>(hints->max_width), static_cast<double>(hints->max_height)};
        haveLimits        = true;
    } else if (window->m_xdgSurface && window->m_xdgSurface->m_toplevel) {
        minSize    = window->m_xdgSurface->m_toplevel->layoutMinSize();
        maxSize    = window->m_xdgSurface->m_toplevel->layoutMaxSize();
        haveLimits = true;
    }
    if (haveLimits && maxSize.x >= 5 && maxSize.y >= 5) {
        const bool pinned = minSize.x >= maxSize.x && minSize.y >= maxSize.y;
        setBoolean(state, "size_pinned", pinned);
        lua_pushinteger(state, static_cast<lua_Integer>(minSize.x));
        lua_setfield(state, -2, "min_size_width");
        lua_pushinteger(state, static_cast<lua_Integer>(minSize.y));
        lua_setfield(state, -2, "min_size_height");
        lua_pushinteger(state, static_cast<lua_Integer>(maxSize.x));
        lua_setfield(state, -2, "max_size_width");
        lua_pushinteger(state, static_cast<lua_Integer>(maxSize.y));
        lua_setfield(state, -2, "max_size_height");
    } else {
        setBoolean(state, "size_pinned", false);
    }
    // Raw surface facts, for diagnosing a client that lays its page out for a
    // different size than the box it was given: the compositor box, the size it
    // last reported to the client, the buffer the client actually committed and
    // the buffer scale it committed with. Purely factual, no policy here.
    const auto reported = window->m_reportedSize;
    lua_pushinteger(state, static_cast<lua_Integer>(reported.x));
    lua_setfield(state, -2, "reported_width");
    lua_pushinteger(state, static_cast<lua_Integer>(reported.y));
    lua_setfield(state, -2, "reported_height");
    if (window->m_xdgSurface && window->m_xdgSurface->m_surface) {
        const auto& surface = window->m_xdgSurface->m_surface->m_current;
        lua_pushinteger(state, static_cast<lua_Integer>(surface.size.x));
        lua_setfield(state, -2, "surface_width");
        lua_pushinteger(state, static_cast<lua_Integer>(surface.size.y));
        lua_setfield(state, -2, "surface_height");
        lua_pushinteger(state, static_cast<lua_Integer>(surface.bufferSize.x));
        lua_setfield(state, -2, "buffer_width");
        lua_pushinteger(state, static_cast<lua_Integer>(surface.bufferSize.y));
        lua_setfield(state, -2, "buffer_height");
        lua_pushinteger(state, surface.scale);
        lua_setfield(state, -2, "buffer_scale");
        // The window geometry the client set on its toplevel and the ring it
        // therefore reserves around it. Raw compositor facts; the policy stays in
        // Lua.
        lua_pushinteger(state, static_cast<lua_Integer>(window->m_xdgSurface->m_current.geometry.w));
        lua_setfield(state, -2, "geometry_width");
        lua_pushinteger(state, static_cast<lua_Integer>(window->m_xdgSurface->m_current.geometry.h));
        lua_setfield(state, -2, "geometry_height");
        setBoolean(state, "reserves_margins", clientReportsDecorationMargins(window->m_xdgSurface->m_toplevel.get()));
    }
    return 1;
}

// A client that draws its own frame reports it as a symmetric ring: the window
// geometry sits inside the surface with the same margin on every side (the drop
// shadow, the clear margin a resize grip needs, the rounded corners). The
// geometry is the window; the ring is the client's frame around it.
//
// A surface that is merely a different size than the geometry is not a ring: it
// is a client that has not yet committed a frame for the box it was just given,
// or one that is mid-resize. That happens for every window at map time, and
// placing a surface by a ring that does not exist yet would shift the window.
Vector2D decorationRing(CXDGToplevelResource* self) {
    if (!self || !self->m_owner)
        return Vector2D{};

    const auto& geometry = self->m_owner->m_current.geometry;
    if (geometry.w <= 0 || geometry.h <= 0)
        return Vector2D{};

    const auto surface = self->m_owner->m_surface ? self->m_owner->m_surface->m_current.size : Vector2D{};
    const auto margin  = geometry.pos();
    const auto ring    = surface - geometry.size();
    if (margin.x <= 0 || margin.y <= 0)
        return Vector2D{};

    if (std::abs(ring.x - margin.x * 2) > 1 || std::abs(ring.y - margin.y * 2) > 1)
        return Vector2D{};

    return margin;
}

bool clientReportsDecorationMargins(CXDGToplevelResource* self) {
    const auto ring = decorationRing(self);
    return ring.x > 0 && ring.y > 0;
}

Vector2D windowDecorationRing(PHLWINDOW window) {
    if (!window || window->m_isX11 || !window->m_xdgSurface || !window->m_xdgSurface->m_toplevel)
        return Vector2D{};
    return decorationRing(window->m_xdgSurface->m_toplevel.get());
}

// Placement. A Wayland client's window geometry is the window: the surface may
// reach past it with the client's own frame. Hyprland places the surface at the
// box origin and sizes its destination box to the box, which draws that frame
// inside the window instead of around it: the content ends up inset by the
// frame margin, its right and bottom edge is cut, and the app's own controls sit
// away from where they are drawn. Here the surface keeps the size it committed
// and is placed so that the geometry lands exactly on the window box; the frame
// then falls outside it, over the gap.
//
// The margin comes from the client's own commit, so nothing here needs state, a
// configuration value, or knowledge of any application.
CFunctionHook* surfaceCtorHook = nullptr;
using SurfaceCtorFn = void (*)(CSurfacePassElement*, const CSurfacePassElement::SRenderData&);

void hookSurfaceCtor(CSurfacePassElement* self, const CSurfacePassElement::SRenderData& data) {
    const auto original = reinterpret_cast<SurfaceCtorFn>(surfaceCtorHook->m_original);
    // Popups carry no window geometry of their own, and Hyprland already places
    // them against the geometry of the window they belong to.
    const auto ring = data.popup ? Vector2D{} : windowDecorationRing(data.pWindow);
    if (ring.x <= 0 || ring.y <= 0) {
        original(self, data);
        return;
    }

    auto placed = data;
    placed.pos  = data.pos - ring;
    if (data.mainSurface) {
        // The surface covers the box plus its frame; a subsurface is placed by
        // the same origin shift and keeps its own size.
        placed.w = data.w + ring.x * 2;
        placed.h = data.h + ring.y * 2;
    }
    original(self, placed);
}

// Pointer coordinates are measured from the same origin the surface is placed
// at, otherwise every click inside such a window would land one frame margin
// away from the point it was aimed at.
CFunctionHook* windowSurfaceAtHook = nullptr;
using WindowSurfaceAtFn = SP<CWLSurfaceResource> (*)(Desktop::CViewHitTester*, const Vector2D&, PHLWINDOW, Vector2D&);

SP<CWLSurfaceResource> hookWindowSurfaceAt(Desktop::CViewHitTester* self, const Vector2D& pos, PHLWINDOW window, Vector2D& surfaceLocal) {
    const auto original = reinterpret_cast<WindowSurfaceAtFn>(windowSurfaceAtHook->m_original);
    const auto ring     = windowDecorationRing(window);
    if (ring.x <= 0 || ring.y <= 0)
        return original(self, pos, window, surfaceLocal);
    return original(self, pos + ring, window, surfaceLocal);
}

// The size limits a client declares are content sizes. Hyprland reports them
// with the frame margin added, so the compositor would refuse to make a window
// narrower or shorter than the client allows by that margin, and would clamp a
// window whose client pins its own size to a box larger than the size it pinned.
CFunctionHook* layoutMinSizeHook = nullptr;
CFunctionHook* layoutMaxSizeHook = nullptr;
using LayoutSizeFn = Vector2D (*)(CXDGToplevelResource*);

Vector2D hookLayoutSize(CFunctionHook* hook, CXDGToplevelResource* self) {
    const auto original = reinterpret_cast<LayoutSizeFn>(hook->m_original);
    const auto size     = original(self);
    const auto ring     = decorationRing(self);
    if (ring.x <= 0 || ring.y <= 0)
        return size;
    return {std::max(0.0, size.x - ring.x), std::max(0.0, size.y - ring.y)};
}

Vector2D hookLayoutMinSize(CXDGToplevelResource* self) {
    return hookLayoutSize(layoutMinSizeHook, self);
}

Vector2D hookLayoutMaxSize(CXDGToplevelResource* self) {
    return hookLayoutSize(layoutMaxSizeHook, self);
}

// A floating window's maximize truth is the window's own bit. A window can be
// maximized for the client (its own chrome then draws "restore") while the
// compositor holds no internal maximize state: the internal state makes
// Hyprland stop drawing every other window of the workspace, which is not what
// a float workspace wants, because there the maximizing window is only supposed
// to cover its peers. So both state sources are honoured here, and the plugin
// keeps the box.
bool floatingMaximizeState(PHLWINDOW window) {
    const auto modes = Fullscreen::controller()->getFullscreenModes(window);
    return modes.internal == Fullscreen::FSMODE_MAXIMIZED || modes.client == Fullscreen::FSMODE_MAXIMIZED;
}

// Hyprland suppresses client-side decorations by handing the maximize hint to
// every window as it maps. The hint is never withdrawn once the window starts
// floating, so the application believes it is maximized forever: its own window
// controls keep drawing "restore" and a click can only ever send an unmaximize
// request. Floating windows get the truthful state instead; tiled windows keep
// Hyprland's own behaviour.
uint32_t hookSetMaximized(CXDGToplevelResource* self, bool maximized) {
    const auto original = reinterpret_cast<uint32_t (*)(CXDGToplevelResource*, bool)>(setMaximizedHook->m_original);
    if (!self)
        return original(self, maximized);

    const auto window = self->m_window.lock();
    if (!window || !Fullscreen::controller())
        return original(self, maximized);

    if (!window->m_isFloating)
        return original(self, maximized);

    return original(self, floatingMaximizeState(window));
}

CFunctionHook* setSizeHook = nullptr;

// The configure carries the box and the state list in one message, so a floating
// window's maximize bit is corrected here rather than in a separate state-only
// configure: a lone state change makes toolkits re-lay themselves out while they
// still hold the previous box, which pushes the surface past the window and
// misaligns the frame. Doing it here also notifies the client about a maximize
// the compositor started on its own (a startup maximize, or the panel's dispatch).
uint32_t hookSetSize(CXDGToplevelResource* self, const Vector2D& size) {
    const auto original = reinterpret_cast<uint32_t (*)(CXDGToplevelResource*, const Vector2D&)>(setSizeHook->m_original);
    const auto window = self ? self->m_window.lock() : nullptr;

    if (self && window && Fullscreen::controller()) {
        const bool reallyMaximized = window->m_isFloating && floatingMaximizeState(window);
        auto& states = self->m_pendingApply.states;
        const bool hasMaximized = std::ranges::find(states, XDG_TOPLEVEL_STATE_MAXIMIZED) != states.end();
        if (reallyMaximized && !hasMaximized)
            states.push_back(XDG_TOPLEVEL_STATE_MAXIMIZED);
        else if (!reallyMaximized && hasMaximized)
            std::erase(states, XDG_TOPLEVEL_STATE_MAXIMIZED);
    }

    // The configure carries the box, which is the content size: the client adds
    // its own frame around it and the surface is placed accordingly.
    return original(self, size);
}

// A maximize that does not change the box (the window already fills the work
// area) never reaches the client through setSize, so re-send the current box
// once when the maximize state changes.
CHyprSignalListener truthfulMaximizeListener;
void pushTruthfulMaximizeState(PHLWINDOW window) {
    if (!window || !window->m_isMapped || !window->m_isFloating)
        return;
    window->sendWindowSize(true);
}

// Every symbol is looked up by its own name and its own signature, so a
// compositor that changed one of them refuses to load the plugin instead of
// being patched at a wrong offset.
void* requireSymbol(HANDLE handle, const std::string& name, std::string_view mangled, const char* what) {
    auto matches = HyprlandAPI::findFunctionsByName(handle, name);
    std::erase_if(matches, [&](const auto& match) { return match.demangled.find(mangled) == std::string::npos; });
    // One symbol can be listed twice: a constructor has a complete-object and a
    // base-object entry, both at the same address.
    std::vector<void*> addresses;
    for (const auto& match : matches) {
        if (std::ranges::find(addresses, match.address) == addresses.end())
            addresses.push_back(match.address);
    }
    if (addresses.size() != 1)
        throw std::runtime_error(std::format("float-panel: ambiguous/missing native symbol {}", what));
    return addresses.front();
}

CFunctionHook* installHook(HANDLE handle, const std::string& name, const std::string& mangled, const char* what, void* replacement) {
    auto* hook = HyprlandAPI::createFunctionHook(handle, requireSymbol(handle, name, mangled, what), replacement);
    if (!hook || !hook->hook())
        throw std::runtime_error(std::format("float-panel: cannot hook {}", what));
    return hook;
}

void installStateHooks(HANDLE handle) {
    setMaximizedHook = installHook(handle, "setMaximized", "CXDGToplevelResource::setMaximized(bool)", "CXDGToplevelResource::setMaximized",
                                   reinterpret_cast<void*>(hookSetMaximized));
    setSizeHook = installHook(handle, "setSize", "CXDGToplevelResource::setSize(", "CXDGToplevelResource::setSize", reinterpret_cast<void*>(hookSetSize));
}

void installPlacementHooks(HANDLE handle) {
    surfaceCtorHook = installHook(handle, "CSurfacePassElement", "CSurfacePassElement::CSurfacePassElement(",
                                  "CSurfacePassElement::CSurfacePassElement", reinterpret_cast<void*>(hookSurfaceCtor));
    windowSurfaceAtHook =
        installHook(handle, "windowSurfaceAt", "Desktop::CViewHitTester::windowSurfaceAt(", "Desktop::CViewHitTester::windowSurfaceAt",
                    reinterpret_cast<void*>(hookWindowSurfaceAt));
    layoutMinSizeHook =
        installHook(handle, "layoutMinSize", "CXDGToplevelResource::layoutMinSize()", "CXDGToplevelResource::layoutMinSize",
                    reinterpret_cast<void*>(hookLayoutMinSize));
    layoutMaxSizeHook =
        installHook(handle, "layoutMaxSize", "CXDGToplevelResource::layoutMaxSize()", "CXDGToplevelResource::layoutMaxSize",
                    reinterpret_cast<void*>(hookLayoutMaxSize));
}

} // namespace

// Every registration and every hook has to come back out on the same paths that
// put it in: a Lua function or a patched function that outlives the unloaded
// library is a dangling pointer in the compositor. Unloading and reloading this
// plugin is part of the normal deploy loop, so the list lives in one place.
void unregisterLuaFunctions(HANDLE handle) {
    HyprlandAPI::removeLuaFunction(handle, "float_panel", "push_state");
    HyprlandAPI::removeLuaFunction(handle, "float_panel", "capabilities");
    HyprlandAPI::removeLuaFunction(handle, "float_panel", "window_semantics");
}

void removeFunctionHooks(HANDLE handle) {
    if (!handle)
        return;
    if (setMaximizedHook) {
        HyprlandAPI::removeFunctionHook(handle, setMaximizedHook);
        setMaximizedHook = nullptr;
    }
    if (setSizeHook) {
        HyprlandAPI::removeFunctionHook(handle, setSizeHook);
        setSizeHook = nullptr;
    }
    if (surfaceCtorHook) {
        HyprlandAPI::removeFunctionHook(handle, surfaceCtorHook);
        surfaceCtorHook = nullptr;
    }
    if (windowSurfaceAtHook) {
        HyprlandAPI::removeFunctionHook(handle, windowSurfaceAtHook);
        windowSurfaceAtHook = nullptr;
    }
    if (layoutMinSizeHook) {
        HyprlandAPI::removeFunctionHook(handle, layoutMinSizeHook);
        layoutMinSizeHook = nullptr;
    }
    if (layoutMaxSizeHook) {
        HyprlandAPI::removeFunctionHook(handle, layoutMaxSizeHook);
        layoutMaxSizeHook = nullptr;
    }
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    const auto running = HyprlandAPI::getHyprlandVersion(handle);
    if (running.hash != GIT_COMMIT_HASH)
        throw std::runtime_error(std::format("float-panel native bridge was built for Hyprland {}, running {}", GIT_COMMIT_HASH, running.hash));

    if (!HyprlandAPI::addLuaFunction(handle, "float_panel", "window_semantics", luaWindowSemantics))
        throw std::runtime_error("failed to register hl.plugin.float_panel.window_semantics");
    if (!HyprlandAPI::addLuaFunction(handle, "float_panel", "push_state", luaPushWindowState)) {
        unregisterLuaFunctions(handle);
        throw std::runtime_error("failed to register hl.plugin.float_panel.push_state");
    }
    if (!HyprlandAPI::addLuaFunction(handle, "float_panel", "capabilities", luaCapabilities)) {
        unregisterLuaFunctions(handle);
        throw std::runtime_error("failed to register hl.plugin.float_panel.capabilities");
    }

    maximizeRequestEvent = makeShared<CustomEvent>(
        "float_panel.maximize_request", std::vector{CustomEvent::TYPE_WINDOW, CustomEvent::TYPE_BOOL});
    if (!HyprlandAPI::addEvent(handle, maximizeRequestEvent)) {
        unregisterLuaFunctions(handle);
        maximizeRequestEvent.reset();
        throw std::runtime_error("failed to register float_panel.maximize_request");
    }

    minimizeRequestEvent = makeShared<CustomEvent>(
        "float_panel.minimize_request", std::vector{CustomEvent::TYPE_WINDOW, CustomEvent::TYPE_BOOL});
    if (!HyprlandAPI::addEvent(handle, minimizeRequestEvent)) {
        HyprlandAPI::removeEvent(handle, "float_panel.maximize_request");
        unregisterLuaFunctions(handle);
        maximizeRequestEvent.reset();
        minimizeRequestEvent.reset();
        throw std::runtime_error("failed to register float_panel.minimize_request");
    }

    focusReasonEvent = makeShared<CustomEvent>(
        "float_panel.focus_changed", std::vector{CustomEvent::TYPE_WINDOW, CustomEvent::TYPE_INT});
    if (!HyprlandAPI::addEvent(handle, focusReasonEvent)) {
        HyprlandAPI::removeEvent(handle, "float_panel.minimize_request");
        HyprlandAPI::removeEvent(handle, "float_panel.maximize_request");
        unregisterLuaFunctions(handle);
        maximizeRequestEvent.reset();
        minimizeRequestEvent.reset();
        focusReasonEvent.reset();
        throw std::runtime_error("failed to register float_panel.focus_changed");
    }
    focusReasonListener = Event::bus()->m_events.window.active.listen([](PHLWINDOW window, Desktop::eFocusReason reason) {
        if (!focusReasonEvent || !window)
            return;
        focusReasonEvent->emit({PHLWINDOWREF(window), static_cast<int>(reason)});
    });

    pointerButtonEvent = makeShared<CustomEvent>(
        "float_panel.pointer_button", std::vector{CustomEvent::TYPE_WINDOW, CustomEvent::TYPE_INT, CustomEvent::TYPE_BOOL});
    if (!HyprlandAPI::addEvent(handle, pointerButtonEvent)) {
        HyprlandAPI::removeEvent(handle, "float_panel.focus_changed");
        HyprlandAPI::removeEvent(handle, "float_panel.minimize_request");
        HyprlandAPI::removeEvent(handle, "float_panel.maximize_request");
        unregisterLuaFunctions(handle);
        maximizeRequestEvent.reset();
        minimizeRequestEvent.reset();
        focusReasonEvent.reset();
        pointerButtonEvent.reset();
        throw std::runtime_error("failed to register float_panel.pointer_button");
    }
    pointerButtonListener = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent event, Event::SCallbackInfo& info) {
        (void)info;
        if (!pointerButtonEvent)
            return;
        const auto window = g_pInputManager ? g_pInputManager->m_lastMouseFocus.lock() : nullptr;
        pointerButtonEvent->emit({PHLWINDOWREF(window), static_cast<int>(event.button),
                                  event.state == WL_POINTER_BUTTON_STATE_PRESSED});
    });

    try {
        installStateHooks(handle);
        installPlacementHooks(handle);
    } catch (...) {
        removeFunctionHooks(handle);
        focusReasonListener.reset();
        pointerButtonListener.reset();
        HyprlandAPI::removeEvent(handle, "float_panel.pointer_button");
        HyprlandAPI::removeEvent(handle, "float_panel.focus_changed");
        HyprlandAPI::removeEvent(handle, "float_panel.minimize_request");
        HyprlandAPI::removeEvent(handle, "float_panel.maximize_request");
        unregisterLuaFunctions(handle);
        maximizeRequestEvent.reset();
        minimizeRequestEvent.reset();
        focusReasonEvent.reset();
        pointerButtonEvent.reset();
        throw;
    }
    truthfulMaximizeListener = Event::bus()->m_events.window.fullscreen.listen([](PHLWINDOW window) {
        pushTruthfulMaximizeState(window);
    });

    try {
        DragStrip::init(handle);
    } catch (...) {
        focusReasonListener.reset();
        pointerButtonListener.reset();
        truthfulMaximizeListener.reset();
        removeFunctionHooks(handle);
        HyprlandAPI::removeEvent(handle, "float_panel.pointer_button");
        HyprlandAPI::removeEvent(handle, "float_panel.focus_changed");
        HyprlandAPI::removeEvent(handle, "float_panel.minimize_request");
        HyprlandAPI::removeEvent(handle, "float_panel.maximize_request");
        unregisterLuaFunctions(handle);
        maximizeRequestEvent.reset();
        minimizeRequestEvent.reset();
        focusReasonEvent.reset();
        pointerButtonEvent.reset();
        throw;
    }

    // Lua rebuilds its event handler on every config reload, after this plugin
    // event already exists. Re-announce it once per reload so the new handler
    // attaches to the standard custom event before clients can issue requests.
    configPreReloadListener = Event::bus()->m_events.config.preReload.listen([] {
        ++configReloadGeneration;
        DragStrip::reset();
        DragStrip::announce(false);
        Event::bus()->m_events.pluginEventRemoved.emit("float_panel.maximize_request");
        Event::bus()->m_events.pluginEventRemoved.emit("float_panel.minimize_request");
        Event::bus()->m_events.pluginEventRemoved.emit("float_panel.focus_changed");
        Event::bus()->m_events.pluginEventRemoved.emit("float_panel.pointer_button");
    });
    configReloadedListener  = Event::bus()->m_events.config.reloaded.listen([] {
        if (!maximizeRequestEvent || announcedReloadGeneration == configReloadGeneration)
            return;
        announcedReloadGeneration = configReloadGeneration;
        Event::bus()->m_events.pluginEventAdded.emit(maximizeRequestEvent);
        Event::bus()->m_events.pluginEventAdded.emit(minimizeRequestEvent);
        Event::bus()->m_events.pluginEventAdded.emit(focusReasonEvent);
        Event::bus()->m_events.pluginEventAdded.emit(pointerButtonEvent);
        DragStrip::announce(true);
    });

    windowCreateListener = Event::bus()->m_events.window.create.listen([](PHLWINDOW window) { trackMaximizeRequests(window); });
    windowDestroyListener = Event::bus()->m_events.window.destroy.listen([](PHLWINDOWREF window) {
        maximizeRequestListeners.erase(reinterpret_cast<uintptr_t>(window.get()));
    });

    pluginHandle = handle;
    return {
        "float-panel-native",
        "Raw window semantics and request bridge for fatlj.float-panel",
        "fatlj",
        "0.7.0",
    };
}

APICALL EXPORT void PLUGIN_EXIT() {
    DragStrip::stop();
    configPreReloadListener.reset();
    configReloadedListener.reset();
    windowCreateListener.reset();
    windowDestroyListener.reset();
    focusReasonListener.reset();
    pointerButtonListener.reset();
    truthfulMaximizeListener.reset();
    removeFunctionHooks(pluginHandle);
    maximizeRequestListeners.clear();
    if (pluginHandle) {
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.maximize_request");
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.minimize_request");
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.focus_changed");
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.pointer_button");
        unregisterLuaFunctions(pluginHandle);
    }
    maximizeRequestEvent.reset();
    minimizeRequestEvent.reset();
    focusReasonEvent.reset();
    pointerButtonEvent.reset();
    pluginHandle = nullptr;
}
