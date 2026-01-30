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
SHADER_VERIFY = shader_verify

# Default target
all: $(MILOC) $(SHADER_TEST) $(SHADER_VERIFY)

# Compiler
$(MILOC): miloc.o $(COMMON_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

# Test program
$(SHADER_TEST): shader_test.o $(COMMON_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

# Verification tool
$(SHADER_VERIFY): shader_verify.o $(COMMON_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Dependencies
miloc.o: miloc.c milo_glsl.h milo_asm.h
shader_test.o: shader_test.c milo_glsl.h milo_asm.h milo_vm.h
shader_verify.o: shader_verify.c milo_glsl.h milo_asm.h milo_vm.h
milo_glsl.o: milo_glsl.c milo_glsl.h milo_asm.h
milo_asm.o: milo_asm.c milo_asm.h
milo_vm.o: milo_vm.c milo_vm.h milo_asm.h

# Test
test: $(SHADER_TEST)
	@echo "Running shader tests..."
	./$(SHADER_TEST)

# Generate verification test files
verify-gen: $(SHADER_VERIFY)
	@echo "Generating verification test files..."
	mkdir -p verify_tests
	./$(SHADER_VERIFY) generate verify_tests

# Compare VHDL output with VM (after running VHDL sim)
verify-compare: $(SHADER_VERIFY)
	@echo "Comparing VHDL output with VM..."
	./$(SHADER_VERIFY) verify verify_tests 0.0001

# Compile test
compile-test: $(MILOC)
	@echo "Testing compiler..."
	./$(MILOC) test_shader.glsl

# Clean
clean:
	rm -f *.o $(MILOC) $(SHADER_TEST) $(SHADER_VERIFY) test_*.ppm test_*.png

# Clean verification files
clean-verify:
	rm -rf verify_tests

# Install
PREFIX ?= /usr/local
install: $(MILOC)
	install -d $(PREFIX)/bin
	install -m 755 $(MILOC) $(PREFIX)/bin/

.PHONY: all clean clean-verify test compile-test verify-gen verify-compare install
