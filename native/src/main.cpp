#include <array>
#include <cstdint>
#include <format>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include <src/desktop/state/WindowState.hpp>
#include <src/desktop/view/Window.hpp>
#include <src/event/EventBus.hpp>
#include <src/plugins/PluginAPI.hpp>
#include <src/protocols/XDGShell.hpp>
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
CHyprSignalListener                                configPreReloadListener;
CHyprSignalListener                                configReloadedListener;
CHyprSignalListener                                windowCreateListener;
CHyprSignalListener                                windowDestroyListener;
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

void forwardMaximizeRequest(const PHLWINDOWREF& reference) {
    const auto window = reference.lock();
    if (!window || !maximizeRequestEvent)
        return;

    const auto request = window->m_isX11 && window->m_xwaylandSurface ? window->m_xwaylandSurface->m_state.requestsMaximize :
                                                                      window->m_xdgSurface->m_toplevel->m_state.requestsMaximize;
    if (!request.has_value())
        return;

    const auto result = maximizeRequestEvent->emit({PHLWINDOWREF(window), *request});
    (void)result;
}

void trackMaximizeRequests(const PHLWINDOW& window) {
    if (!window)
        return;

    const auto reference = PHLWINDOWREF(window);
    const auto listener  = window->m_isX11 && window->m_xwaylandSurface ?
         window->m_xwaylandSurface->m_events.stateChanged.listen([reference] { forwardMaximizeRequest(reference); }) :
         window->m_xdgSurface->m_toplevel->m_events.stateChanged.listen([reference] { forwardMaximizeRequest(reference); });
    maximizeRequestListeners[reinterpret_cast<uintptr_t>(window.get())] = listener;
}

int luaCapabilities(lua_State* state) {
    lua_newtable(state);
    setBoolean(state, "maximize_request_event", true);
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

    // Lua rebuilds its event handler on every config reload, after this plugin
    // event already exists. Re-announce it once per reload so the new handler
    // attaches to the standard custom event before clients can issue requests.
    configPreReloadListener = Event::bus()->m_events.config.preReload.listen([] {
        ++configReloadGeneration;
        Event::bus()->m_events.pluginEventRemoved.emit("float_panel.maximize_request");
    });
    configReloadedListener  = Event::bus()->m_events.config.reloaded.listen([] {
        if (!maximizeRequestEvent || announcedReloadGeneration == configReloadGeneration)
            return;
        announcedReloadGeneration = configReloadGeneration;
        Event::bus()->m_events.pluginEventAdded.emit(maximizeRequestEvent);
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
        "0.5.1",
    };
}

APICALL EXPORT void PLUGIN_EXIT() {
    configPreReloadListener.reset();
    configReloadedListener.reset();
    windowCreateListener.reset();
    windowDestroyListener.reset();
    maximizeRequestListeners.clear();
    if (pluginHandle) {
        HyprlandAPI::removeEvent(pluginHandle, "float_panel.maximize_request");
        HyprlandAPI::removeLuaFunction(pluginHandle, "float_panel", "capabilities");
        HyprlandAPI::removeLuaFunction(pluginHandle, "float_panel", "window_semantics");
    }
    maximizeRequestEvent.reset();
    pluginHandle = nullptr;
}
