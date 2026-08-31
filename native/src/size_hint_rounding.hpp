#pragma once

#include <cmath>
#include <optional>

namespace FloatPanel {

inline std::optional<double> logicalMinimumComponent(double converted) {
    if (!std::isfinite(converted) || converted <= 0)
        return std::nullopt;
    return std::ceil(converted);
}

inline std::optional<double> logicalMaximumComponent(double converted) {
    if (!std::isfinite(converted) || converted <= 0)
        return std::nullopt;

    const auto rounded = std::floor(converted);
    if (rounded < 1)
        return std::nullopt;
    return rounded;
}

inline bool hasFiniteXWaylandMaximum(double raw) {
    // Matches CWindow::maxSize(): XWayland maximum components below 5 mean
    // that the corresponding axis has no maximum.
    return raw >= 5;
}

} // namespace FloatPanel
