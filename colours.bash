source ./maps.bash

if ((truecolor)); then
    sky='135;206;235'
    grass='0;100;0'
    wallsr=(0 139 0 0 165 255)
    wallsg=(0 0 139 0 42 215)
    wallsb=(0 0 0 139 42 0)
else
    sky=33
    grass=22
    wallsr=(0 52 18 18 130 214)
    wallsg=(0 52 52 18 130 214)
    wallsb=(0 52 52 18 42  214)
fi

# Pre-generate a lookup table for shading 256-color indices.
declare -a SHADE_TABLE
# Pre-generate lookup tables for converting xterm 256-color indices to RGB.
declare -a XTERM_R XTERM_G XTERM_B
# Pre-generate lookup tables for truecolor shading.
declare -a SHADE_R SHADE_G SHADE_B

# System colors (0-15) - these are often customized, so these are approximations.
XTERM_R+=(0 0 170 85 0 170 0 170 85 85 0 255 0 255 85 255)
XTERM_G+=(0 0 0 85 170 85 170 170 85 85 255 0 255 0 255 255)
XTERM_B+=(0 170 0 85 0 85 170 170 85 255 0 0 255 255 85 255)

# 6x6x6 color cube (16-231)
for i in {0..215}; do
    r=$((i / 36))
    g=$(((i % 36) / 6))
    b=$((i % 6))
    XTERM_R+=($((r * 40 + 55)))
    XTERM_G+=($((g * 40 + 55)))
    XTERM_B+=($((b * 40 + 55)))
done

# Grayscale ramp (232-255)
for i in {0..23}; do
    gray=$((i * 10 + 8))
    XTERM_R+=($gray)
    XTERM_G+=($gray)
    XTERM_B+=($gray)
done

# Pre-calculate truecolor shading tables
for i in {0..255}; do
    r=${XTERM_R[i]}
    g=${XTERM_G[i]}
    b=${XTERM_B[i]}
    for s in {0..5}; do
        SHADE_R[i*6+s]=$r
        SHADE_G[i*6+s]=$g
        SHADE_B[i*6+s]=$b
        # Reduce brightness for the next shade level
        r=$((r*8/10))
        g=$((g*8/10))
        b=$((b*8/10))
    done
done


for i in {0..255}; do
    # For the 6x6x6 color cube (16-231)
    if (( i >= 16 && i <= 231 )); then
        r=$(((i - 16) / 36))
        g=$((((i - 16) % 36) / 6))
        b=$(((i - 16) % 6))
        # Reduce brightness, but don't go below 0.
        ((r > 0)) && r=$((r - 1))
        ((g > 0)) && g=$((g - 1))
        ((b > 0)) && b=$((b - 1))
        SHADE_TABLE[i]=$((16 + r * 36 + g * 6 + b))
    # For the grayscale ramp (232-255)
    elif (( i >= 232 && i <= 255 )); then
        # Just step down the ramp.
        j=$((i - 232))
        ((j > 1)) && j=$((j - 2)) # Step down by 2 for a more noticeable effect
        ((j < 0)) && j=0
        SHADE_TABLE[i]=$((232 + j))
    # For the basic 16 colors (0-15)
    else
        # Map bright colors to their dark counterparts.
        case $i in
            8|9|10|11|12|13|14|15) SHADE_TABLE[i]=$((i - 8));;
            *) SHADE_TABLE[i]=$i;; # Keep dark colors as they are
        esac
    fi
done
