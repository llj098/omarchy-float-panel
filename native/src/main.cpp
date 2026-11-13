#include "drag_strip.hpp"
#include <array>
#include <cstdint>
#include <format>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include <src/desktop/state/FocusState.hpp>
#include <src/managers/input/InputManager.hpp>
#include <src/managers/fullscreen/FullscreenController.hpp>
#include <src/protocols/XDGShell.hpp>
#include <src/protocols/core/Compositor.hpp>
#include <src/desktop/state/WindowState.hpp>
#include <src/desktop/view/Window.hpp>
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
    return 1;
}

// A client that draws its own decorations reports the part of its surface that
// carries them as the area outside its window geometry: a transparent ring for
// the drop shadow and the resize grips. Hyprland treats the window box as the
// whole surface and draws the surface at the box origin, so the ring would push
// the content inward and clip its right and bottom edge. Shrinking the size we
// configure the client by that ring makes the surface - content plus ring - fit
// the box exactly, with the content centred and its controls intact.
struct SDecorationMargins {
    double left   = 0;
    double top    = 0;
    double right  = 0;
    double bottom = 0;

    bool   empty() const {
        return left <= 0 && top <= 0 && right <= 0 && bottom <= 0;
    }
};

SDecorationMargins decorationMargins(PHLWINDOW window) {
    SDecorationMargins margins;
    if (!window || window->m_isX11 || !window->m_xdgSurface || !window->m_xdgSurface->m_surface)
        return margins;

    const auto& geometry = window->m_xdgSurface->m_current.geometry;
    if (geometry.w <= 0 || geometry.h <= 0)
        return margins;

    const auto surface = window->m_xdgSurface->m_surface->m_current.size;
    margins.left       = geometry.x;
    margins.top        = geometry.y;
    margins.right      = surface.x - geometry.x - geometry.w;
    margins.bottom     = surface.y - geometry.y - geometry.h;
    if (margins.left < 0 || margins.top < 0 || margins.right < 0 || margins.bottom < 0)
        return SDecorationMargins{};
    return margins;
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

    const bool reallyMaximized = Fullscreen::controller()->getFullscreenModes(window).internal == Fullscreen::FSMODE_MAXIMIZED;
    return original(self, reallyMaximized);
}

CFunctionHook* setSizeHook = nullptr;
CFunctionHook* borderSizeHook = nullptr;

// The frame that the plugin draws belongs to the window box, but a client that
// reserves decoration margins keeps its own content a ring inside that box, and
// its own drop shadow fills the ring. A compositor border on the box edge would
// outline the shadow instead of the window, so it is dropped for those clients.
int hookGetRealBorderSize(Desktop::View::CWindow* self) {
    const auto original = reinterpret_cast<int (*)(const Desktop::View::CWindow*)>(borderSizeHook->m_original);
    const auto window = self ? self->m_self.lock() : nullptr;
    if (window && window->m_isFloating && !decorationMargins(window).empty())
        return 0;
    return original(self);
}

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
        const auto modes = Fullscreen::controller()->getFullscreenModes(window);
        const bool reallyMaximized = window->m_isFloating && modes.internal == Fullscreen::FSMODE_MAXIMIZED;
        auto& states = self->m_pendingApply.states;
        const bool hasMaximized = std::ranges::find(states, XDG_TOPLEVEL_STATE_MAXIMIZED) != states.end();
        if (reallyMaximized && !hasMaximized)
            states.push_back(XDG_TOPLEVEL_STATE_MAXIMIZED);
        else if (!reallyMaximized && hasMaximized)
            std::erase(states, XDG_TOPLEVEL_STATE_MAXIMIZED);
    }

    // The ring is part of the surface but not of the window: configure only the
    // content, so the whole surface lands inside the box.
    if (window && window->m_isFloating) {
        const auto margins = decorationMargins(window);
        if (!margins.empty() && (margins.left + margins.right < size.x) && (margins.top + margins.bottom < size.y))
            return original(self, size - Vector2D{margins.left + margins.right, margins.top + margins.bottom});
    }

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

void installSetMaximizedHook(HANDLE handle) {
    auto matches = HyprlandAPI::findFunctionsByName(handle, "setMaximized");
    std::erase_if(matches, [](const auto& match) {
        return match.demangled.find("CXDGToplevelResource::setMaximized(bool)") == std::string::npos;
    });
    if (matches.size() != 1)
        throw std::runtime_error("float-panel: ambiguous/missing native symbol CXDGToplevelResource::setMaximized");
    setMaximizedHook = HyprlandAPI::createFunctionHook(handle, matches[0].address, reinterpret_cast<void*>(hookSetMaximized));
    if (!setMaximizedHook || !setMaximizedHook->hook())
        throw std::runtime_error("float-panel: cannot hook CXDGToplevelResource::setMaximized");
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    const auto running = HyprlandAPI::getHyprlandVersion(handle);
    if (running.hash != GIT_COMMIT_HASH)
        throw std::runtime_error(std::format("float-panel native bridge was built for Hyprland {}, running {}", GIT_COMMIT_HASH, running.hash));

    if (!HyprlandAPI::addLuaFunction(handle, "float_panel", "window_semantics", luaWindowSemantics))
        throw std::runtime_error("failed to register hl.plugin.float_panel.window_semantics");
    if (!HyprlandAPI::addLuaFunction(handle, "float_panel", "capabilities", luaCapabilities)) {
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "window_semantics");
        throw std::runtime_error("failed to register hl.plugin.float_panel.capabilities");
    }

    maximizeRequestEvent = makeShared<CustomEvent>(
        "float_panel.maximize_request", std::vector{CustomEvent::TYPE_WINDOW, CustomEvent::TYPE_BOOL});
    if (!HyprlandAPI::addEvent(handle, maximizeRequestEvent)) {
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "capabilities");
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "window_semantics");
        maximizeRequestEvent.reset();
        throw std::runtime_error("failed to register float_panel.maximize_request");
    }

    minimizeRequestEvent = makeShared<CustomEvent>(
        "float_panel.minimize_request", std::vector{CustomEvent::TYPE_WINDOW, CustomEvent::TYPE_BOOL});
    if (!HyprlandAPI::addEvent(handle, minimizeRequestEvent)) {
        HyprlandAPI::removeEvent(handle, "float_panel.maximize_request");
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "capabilities");
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "window_semantics");
        maximizeRequestEvent.reset();
        minimizeRequestEvent.reset();
        throw std::runtime_error("failed to register float_panel.minimize_request");
    }

    focusReasonEvent = makeShared<CustomEvent>(
        "float_panel.focus_changed", std::vector{CustomEvent::TYPE_WINDOW, CustomEvent::TYPE_INT});
    if (!HyprlandAPI::addEvent(handle, focusReasonEvent)) {
        HyprlandAPI::removeEvent(handle, "float_panel.minimize_request");
        HyprlandAPI::removeEvent(handle, "float_panel.maximize_request");
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "capabilities");
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "window_semantics");
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
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "capabilities");
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "window_semantics");
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

    installSetMaximizedHook(handle);
    {
        auto borderMatches = HyprlandAPI::findFunctionsByName(handle, "getRealBorderSize");
        std::erase_if(borderMatches, [](const auto& m) { return m.demangled.find("CWindow::getRealBorderSize()") == std::string::npos; });
        if (borderMatches.size() == 1) {
            borderSizeHook = HyprlandAPI::createFunctionHook(handle, borderMatches[0].address, reinterpret_cast<void*>(hookGetRealBorderSize));
            if (borderSizeHook) borderSizeHook->hook();
        }
        auto sizeMatches = HyprlandAPI::findFunctionsByName(handle, "setSize");
        std::erase_if(sizeMatches, [](const auto& m) { return m.demangled.find("CXDGToplevelResource::setSize(") == std::string::npos; });
        if (sizeMatches.size() == 1) {
            setSizeHook = HyprlandAPI::createFunctionHook(handle, sizeMatches[0].address, reinterpret_cast<void*>(hookSetSize));
            if (setSizeHook) setSizeHook->hook();
        }
    }
    truthfulMaximizeListener = Event::bus()->m_events.window.fullscreen.listen([](PHLWINDOW window) {
        pushTruthfulMaximizeState(window);
    });

    // Windows that were mapped before this build loaded still carry whatever
    // state their previous configure gave them; send every floating window one
    // truthful configure now, so a plugin reload alone is enough to settle them.
    for (const auto& window : Desktop::windowState()->windows()) {
        if (window && window->m_isMapped && window->m_isFloating)
            window->sendWindowSize(true);
    }

    try {
        DragStrip::init(handle);
    } catch (...) {
        HyprlandAPI::removeEvent(handle, "float_panel.minimize_request");
        HyprlandAPI::removeEvent(handle, "float_panel.maximize_request");
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "capabilities");
        HyprlandAPI::removeLuaFunction(handle, "float_panel", "window_semantics");
        maximizeRequestEvent.reset();
        minimizeRequestEvent.reset();
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
    if (setMaximizedHook && pluginHandle) {
        HyprlandAPI::removeFunctionHook(pluginHandle, setMaximizedHook);
        setMaximizedHook = nullptr;
    }
    maximizeRequestListeners.clear();
    if (pluginHandle) {
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.maximize_request");
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.minimize_request");
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.focus_changed");
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.pointer_button");
        HyprlandAPI::removeLuaFunction(pluginHandle, "float_panel", "capabilities");
        HyprlandAPI::removeLuaFunction(pluginHandle, "float_panel", "window_semantics");
    }
    maximizeRequestEvent.reset();
    minimizeRequestEvent.reset();
    focusReasonEvent.reset();
    pointerButtonEvent.reset();
    pluginHandle = nullptr;
}
