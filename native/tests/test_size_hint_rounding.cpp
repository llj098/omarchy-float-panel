#include <cassert>
#include <iostream>
#include <limits>

#include "size_hint_rounding.hpp"

int main() {
    using FloatPanel::hasFiniteXWaylandMaximum;
    using FloatPanel::logicalMaximumComponent;
    using FloatPanel::logicalMinimumComponent;

    assert(logicalMinimumComponent(776.01) == 777);
    assert(logicalMinimumComponent(0.8) == 1);
    assert(!logicalMinimumComponent(0));
    assert(!logicalMinimumComponent(std::numeric_limits<double>::infinity()));

    assert(logicalMaximumComponent(776.99) == 776);
    assert(!logicalMaximumComponent(0.8));
    assert(!logicalMaximumComponent(std::numeric_limits<double>::infinity()));

    assert(!hasFiniteXWaylandMaximum(4));
    assert(hasFiniteXWaylandMaximum(5));

    std::cout << "SIZE_HINT_ROUNDING_TEST_OK\n";
}
