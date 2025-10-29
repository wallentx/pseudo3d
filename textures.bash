#!/bin/bash

# Texture dimensions (power of two for performance)
readonly TEX_W=32
readonly TEX_H=32

# TEX_WALL_0: Checkerboard pattern (Light Grey / Dark Grey)
TEX_WALL_0=()
for ((y=0; y<TEX_H; y++)); do
    for ((x=0; x<TEX_W; x++)); do
        xy=$(( (y/16) + (x/16) ))
        if (( xy % 2 == 0 )); then
            TEX_WALL_0[(y*TEX_W + x)]=250 # Light grey
        else
            TEX_WALL_0[(y*TEX_W + x)]=240 # Dark grey
        fi
    done
done

# TEX_WALL_1: Brick pattern
TEX_WALL_1=()
for ((y=0; y<TEX_H; y++)); do
    for ((x=0; x<TEX_W; x++)); do
        color=0
        brick_height=8
        mortar_thickness=1
        brick_width=16

        row=$((y / brick_height))
        y_in_brick=$((y % brick_height))

        if (( y_in_brick < mortar_thickness )); then
            color=235 # Dark grey for horizontal mortar
        else
            if (( row % 2 == 0 )); then # Even rows: normal brick pattern
                col=$((x / brick_width))
                x_in_brick=$((x % brick_width))
                if (( x_in_brick < mortar_thickness )); then
                    color=235 # Dark grey for vertical mortar
                else
                    if (( col % 2 == 0 )); then color=130; else color=131; fi # Brick colors (brown/red)
                fi
            else # Odd rows: staggered brick pattern (half offset)
                offset_x=$((x - brick_width / 2))
                if (( offset_x < 0 )); then # Leftmost half-brick
                    x_in_half_brick=$((x % (brick_width / 2)))
                    if (( x_in_half_brick < mortar_thickness )); then
                        color=235
                    else
                        color=130
                    fi
                else
                    col=$((offset_x / brick_width))
                    x_in_brick=$((offset_x % brick_width))
                    if (( x_in_brick < mortar_thickness )); then
                        color=235
                    else
                        if (( col % 2 == 0 )); then color=131; else color=130; fi # Brick colors (brown/red)
                    fi
                fi
            fi
        fi
        TEX_WALL_1[(y*TEX_H + x)]=$color
    done
done

# TEX_WALL_2: Vertical Stripes (Blue / Cyan)
TEX_WALL_2=()
for ((y=0; y<TEX_H; y++)); do
    for ((x=0; x<TEX_W; x++)); do
        if (( x % 8 < 4 )); then # 4 pixels blue, 4 pixels cyan
            TEX_WALL_2[(y*TEX_W + x)]=21 # Blue
        else
            TEX_WALL_2[(y*TEX_W + x)]=45 # Cyan
        fi
    done
done

# TEX_WALL_3: Horizontal Stripes (Green / Yellow)
TEX_WALL_3=()
for ((y=0; y<TEX_H; y++)); do
    for ((x=0; x<TEX_W; x++)); do
        if (( y % 8 < 4 )); then # 4 pixels green, 4 pixels yellow
            TEX_WALL_3[(y*TEX_W + x)]=22 # Green
        else
            TEX_WALL_3[(y*TEX_W + x)]=185 # Yellow
        fi
    done
done