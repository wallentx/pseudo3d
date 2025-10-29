#!/bin/bash

# Texture dimensions (power of two for performance)
readonly TEX_W=32
readonly TEX_H=32

# A single hardcoded texture for Phase 1.
# This is a simple checkerboard pattern using xterm 256-color indices.
TEX_WALL_0=()
for ((y=0; y<TEX_H; y++)); do
    for ((x=0; x<TEX_W; x++)); do
        # Integer division creates blocks of 16x16
        xy=$(( (y/16) + (x/16) ))
        if (( xy % 2 == 0 )); then
            TEX_WALL_0[(y*TEX_W + x)]=250 # Light grey
        else
            TEX_WALL_0[(y*TEX_W + x)]=240 # Dark grey
        fi
    done
done
