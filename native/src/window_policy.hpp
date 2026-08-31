#pragma once

#include <string_view>

namespace FloatPanel {

inline bool persistentCandidate(bool xwayland, bool hasParent, bool transient, bool overrideRedirect, std::string_view windowType) {
    if (hasParent || transient || overrideRedirect)
        return false;

    // Wayland xdg-popup surfaces are not CWindow toplevels. A Wayland
    // xdg-toplevel with a parent has already been rejected above.
    if (!xwayland)
        return true;

    // EWMH says a missing _NET_WM_WINDOW_TYPE defaults to NORMAL. The bridge
    // normalizes that case to "normal" before applying this policy.
    return windowType == "normal" || windowType == "dialog";
}

} // namespace FloatPanel
