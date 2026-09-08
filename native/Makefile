CXX ?= c++
# InputCapture.hpp includes Eis.hpp; Hyprland's .pc omits this existing dependency's include path.
CPPFLAGS += $(shell pkg-config --cflags hyprland lua libeis-1.0)
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++23 -fPIC -Wall -Wextra -Wpedantic
LDFLAGS += -shared
LDLIBS += $(shell pkg-config --libs lua)

TARGET := build/float-panel-native.so
SOURCE := src/main.cpp src/drag_strip.cpp

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SOURCE) src/drag_strip.hpp
	@mkdir -p $(@D)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) $(SOURCE) -o $@ $(LDLIBS)

test:
	@:

clean:
	rm -rf build
