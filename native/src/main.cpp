#include <array>
#include <cstdint>
#include <format>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

#include <src/desktop/state/WindowState.hpp>
#include <src/desktop/view/Window.hpp>
#include <src/plugins/PluginAPI.hpp>
#include <src/version.h>
#include <src/xwayland/XWayland.hpp>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include "size_hint_rounding.hpp"

namespace {

HANDLE pluginHandle = nullptr;

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

void setVector(lua_State* state, const char* key, const Vector2D& value) {
    lua_newtable(state);
    lua_pushnumber(state, value.x);
    lua_setfield(state, -2, "x");
    lua_pushnumber(state, value.y);
    lua_setfield(state, -2, "y");
    lua_setfield(state, -2, key);
}

struct SXWaylandSizeHintFacts {
    Vector2D rawMinimum;
    Vector2D logicalMinimum;
    Vector2D rawMaximum;
    Vector2D logicalMaximum = {std::numeric_limits<double>::max(), std::numeric_limits<double>::max()};
    bool     maximumXFinite = false;
    bool     maximumYFinite = false;
    bool     valid          = false;
};

std::optional<SXWaylandSizeHintFacts> xwaylandSizeHintFacts(const PHLWINDOW& window) {
    if (!window || !window->m_isX11 || !window->m_xwaylandSurface || !window->m_xwaylandSurface->m_sizeHints)
        return std::nullopt;

    const auto& hints = window->m_xwaylandSurface->m_sizeHints;

    SXWaylandSizeHintFacts facts;
    facts.rawMinimum     = {hints->min_width, hints->min_height};
    facts.rawMaximum     = {hints->max_width, hints->max_height};
    facts.maximumXFinite = FloatPanel::hasFiniteXWaylandMaximum(facts.rawMaximum.x);
    facts.maximumYFinite = FloatPanel::hasFiniteXWaylandMaximum(facts.rawMaximum.y);

    const auto convertedMinimum = window->xwaylandSizeToReal(facts.rawMinimum);
    const auto logicalMinimumX  = FloatPanel::logicalMinimumComponent(convertedMinimum.x);
    const auto logicalMinimumY  = FloatPanel::logicalMinimumComponent(convertedMinimum.y);
    if (!logicalMinimumX || !logicalMinimumY)
        return facts;
    facts.logicalMinimum = {*logicalMinimumX, *logicalMinimumY};

    if (facts.maximumXFinite || facts.maximumYFinite) {
        const auto convertedMaximum = window->xwaylandSizeToReal({facts.maximumXFinite ? facts.rawMaximum.x : 1, facts.maximumYFinite ? facts.rawMaximum.y : 1});

        if (facts.maximumXFinite) {
            const auto logical = FloatPanel::logicalMaximumComponent(convertedMaximum.x);
            if (!logical)
                return facts;
            facts.logicalMaximum.x = *logical;
        }
        if (facts.maximumYFinite) {
            const auto logical = FloatPanel::logicalMaximumComponent(convertedMaximum.y);
            if (!logical)
                return facts;
            facts.logicalMaximum.y = *logical;
        }
    }

    facts.valid = true;
    return facts;
}

void setSizeHintFacts(lua_State* state, const SXWaylandSizeHintFacts& facts) {
    setBoolean(state, "size_hints_valid", facts.valid);
    setVector(state, "xwayland_min_size_raw", facts.rawMinimum);
    setVector(state, "xwayland_max_size_raw", facts.rawMaximum);
    setBoolean(state, "xwayland_max_width_finite", facts.maximumXFinite);
    setBoolean(state, "xwayland_max_height_finite", facts.maximumYFinite);

    if (!facts.valid)
        return;

    setVector(state, "xwayland_min_size_logical", facts.logicalMinimum);
    if (facts.maximumXFinite || facts.maximumYFinite)
        setVector(state, "xwayland_max_size_logical", facts.logicalMaximum);
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
    const auto sizeFacts        = xwaylandSizeHintFacts(window);

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
    setBoolean(state, "has_xwayland_size_hints", sizeFacts.has_value());
    if (sizeFacts)
        setSizeHintFacts(state, *sizeFacts);
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

    pluginHandle = handle;
    return {
        "float-panel-native",
        "Read-only window semantics and XWayland size-hint bridge for fatlj.float-panel",
        "fatlj",
        "0.3.0",
    };
}

APICALL EXPORT void PLUGIN_EXIT() {
    if (pluginHandle)
        HyprlandAPI::removeLuaFunction(pluginHandle, "float_panel", "window_semantics");
    pluginHandle = nullptr;
}
