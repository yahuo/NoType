# Builds the NoType fcitx5 addon against the installed Fcitx5Core headers.
CXX ?= g++
PKG_CONFIG ?= pkg-config
CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++20 -Wall -Wextra
FCITX_CFLAGS = $(shell $(PKG_CONFIG) --cflags Fcitx5Core)
FCITX_LIBS = $(shell $(PKG_CONFIG) --libs Fcitx5Core)

libnotype.so: notype.cpp triple_space.h commit_request.h
	$(CXX) $(CXXFLAGS) -fPIC -fvisibility=hidden $(FCITX_CFLAGS) -shared \
		-Wl,--no-undefined -o $@ notype.cpp $(FCITX_LIBS)

test_triple_space: test_triple_space.cpp triple_space.h
	$(CXX) $(CXXFLAGS) -o $@ test_triple_space.cpp

test_commit_request: test_commit_request.cpp commit_request.h
	$(CXX) $(CXXFLAGS) -o $@ test_commit_request.cpp

.PHONY: test clean
test: test_triple_space test_commit_request
	./test_triple_space
	./test_commit_request

clean:
	rm -f libnotype.so test_triple_space test_commit_request
