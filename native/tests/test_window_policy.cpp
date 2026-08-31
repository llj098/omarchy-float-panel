#include <cassert>
#include <iostream>

#include "window_policy.hpp"

int main() {
    using FloatPanel::persistentCandidate;

    assert(persistentCandidate(false, false, false, false, "wayland"));
    assert(!persistentCandidate(false, true, false, false, "wayland"));

    assert(persistentCandidate(true, false, false, false, "normal"));
    assert(persistentCandidate(true, false, false, false, "dialog"));
    assert(!persistentCandidate(true, true, false, false, "normal"));
    assert(!persistentCandidate(true, false, true, false, "normal"));
    assert(!persistentCandidate(true, false, false, true, "normal"));

    for (const auto* type : {
             "utility", "toolbar", "splash", "menu", "dropdown_menu", "popup_menu",
             "tooltip", "notification", "combo", "dnd", "desktop", "dock", "unknown",
         }) {
        assert(!persistentCandidate(true, false, false, false, type));
    }

    std::cout << "NATIVE_POLICY_TEST_OK\n";
}
