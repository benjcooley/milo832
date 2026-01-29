# Milo832 Shader Compiler Makefile

CC = gcc
CFLAGS = -Wall -Wextra -std=c11 -O2 -g
LDFLAGS = -lm

# Common source files
COMMON_SRCS = milo_glsl.c milo_asm.c milo_vm.c
COMMON_OBJS = $(COMMON_SRCS:.c=.o)

# Targets
MILOC = miloc
SHADER_TEST = shader_test

# Default target
all: $(MILOC) $(SHADER_TEST)

# Compiler
$(MILOC): miloc.o $(COMMON_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

# Test program
$(SHADER_TEST): shader_test.o $(COMMON_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Dependencies
miloc.o: miloc.c milo_glsl.h milo_asm.h
shader_test.o: shader_test.c milo_glsl.h milo_asm.h milo_vm.h
milo_glsl.o: milo_glsl.c milo_glsl.h milo_asm.h
milo_asm.o: milo_asm.c milo_asm.h
milo_vm.o: milo_vm.c milo_vm.h milo_asm.h

# Test
test: $(SHADER_TEST)
	@echo "Running shader tests..."
	./$(SHADER_TEST)

# Compile test
compile-test: $(MILOC)
	@echo "Testing compiler..."
	./$(MILOC) test_shader.glsl

# Clean
clean:
	rm -f *.o $(MILOC) $(SHADER_TEST) test_*.ppm test_*.png

# Install
PREFIX ?= /usr/local
install: $(MILOC)
	install -d $(PREFIX)/bin
	install -m 755 $(MILOC) $(PREFIX)/bin/

.PHONY: all clean test compile-test install
