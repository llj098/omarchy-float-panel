CXX ?= c++
CPPFLAGS += $(shell pkg-config --cflags hyprland lua)
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++23 -fPIC -Wall -Wextra -Wpedantic
LDFLAGS += -shared
LDLIBS += $(shell pkg-config --libs lua)

TARGET := build/float-panel-native.so
SOURCE := src/main.cpp
HEADERS := src/window_policy.hpp
POLICY_TEST := build/test-window-policy

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SOURCE) $(HEADERS)
	@mkdir -p $(@D)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) $(SOURCE) -o $@ $(LDLIBS)

$(POLICY_TEST): tests/test_window_policy.cpp $(HEADERS)
	@mkdir -p $(@D)
	$(CXX) -std=c++23 -O2 -Wall -Wextra -Wpedantic -Isrc $< -o $@

test: $(POLICY_TEST)
	./$(POLICY_TEST)

clean:
	rm -rf build
