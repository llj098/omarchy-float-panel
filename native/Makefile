CXX ?= c++
CPPFLAGS += $(shell pkg-config --cflags hyprland lua)
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++23 -fPIC -Wall -Wextra -Wpedantic
LDFLAGS += -shared
LDLIBS += $(shell pkg-config --libs lua)

TARGET := build/float-panel-native.so
SOURCE := src/main.cpp
HEADERS := src/size_hint_rounding.hpp
CONTRACT_TEST := build/test-size-hint-rounding

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SOURCE) $(HEADERS)
	@mkdir -p $(@D)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) $(SOURCE) -o $@ $(LDLIBS)

$(CONTRACT_TEST): tests/test_size_hint_rounding.cpp $(HEADERS)
	@mkdir -p $(@D)
	$(CXX) -std=c++23 -O2 -Wall -Wextra -Wpedantic -Isrc $< -o $@

test: $(CONTRACT_TEST)
	./$(CONTRACT_TEST)

clean:
	rm -rf build
