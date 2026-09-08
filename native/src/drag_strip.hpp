#pragma once
#include <src/plugins/PluginAPI.hpp>
namespace DragStrip {
void init(HANDLE);
void reset();
void announce(bool added);
void stop();
bool ready();
}
