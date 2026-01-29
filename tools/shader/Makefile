# Milo832 Shader Compiler Makefile

CC = gcc
CFLAGS = -Wall -Wextra -std=c11 -O2 -g
LDFLAGS =

# Source files
SRCS = miloc.c milo_glsl.c milo_asm.c
OBJS = $(SRCS:.c=.o)

# Output
TARGET = miloc

# Default target
all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Dependencies
miloc.o: miloc.c milo_glsl.h milo_asm.h
milo_glsl.o: milo_glsl.c milo_glsl.h milo_asm.h
milo_asm.o: milo_asm.c milo_asm.h

# Test
test: $(TARGET)
	@echo "Testing with sample shader..."
	./$(TARGET) test_shader.glsl

# Clean
clean:
	rm -f $(OBJS) $(TARGET)

# Install
PREFIX ?= /usr/local
install: $(TARGET)
	install -d $(PREFIX)/bin
	install -m 755 $(TARGET) $(PREFIX)/bin/

.PHONY: all clean test install
