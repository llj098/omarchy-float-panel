CXX ?= c++
CPPFLAGS += $(shell pkg-config --cflags hyprland lua)
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++23 -fPIC -Wall -Wextra -Wpedantic
LDFLAGS += -shared
LDLIBS += $(shell pkg-config --libs lua)

TARGET := build/float-panel-native.so
SOURCE := src/main.cpp

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCE)
	@mkdir -p $(@D)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) $(SOURCE) -o $@ $(LDLIBS)

clean:
	rm -rf build
