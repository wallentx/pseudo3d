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
# Precomputed ANSI escape sequences for 256-color mode
declare -a FG256 BG256
# Precomputed truecolor escape sequences per shaded color (color_index * 7 + shade_level)
declare -a FG_TRUE_SHADES BG_TRUE_SHADES
# Precomputed repeated shading for 256-color (shade_level * 256 + color_index)
declare -a SHADE_N
# Precomputed sky/grass escape sequences
declare SKY_FG SKY_BG GRASS_FG GRASS_BG

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

# Pre-calculate truecolor shading tables (0..6 levels to allow side-dimming)
for i in {0..255}; do
    r=${XTERM_R[i]}
    g=${XTERM_G[i]}
    b=${XTERM_B[i]}
    for s in {0..6}; do
        SHADE_R[i*7+s]=$r
        SHADE_G[i*7+s]=$g
        SHADE_B[i*7+s]=$b
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

# Precompute 256-color FG/BG escape sequences
for ((i=0; i<=255; i++)); do
    FG256[i]=$'\e[38;5;'"$i"$'m'
    BG256[i]=$'\e[48;5;'"$i"$'m'
done

# Precompute multi-step shading for 256-color (levels 0..6)
for ((s=0; s<=6; s++)); do
    for ((i=0; i<=255; i++)); do
        val=$i
        for ((t=0; t<s; t++)); do
            val=${SHADE_TABLE[val]}
        done
        SHADE_N[s*256 + i]=$val
    done
done

# Precompute truecolor FG/BG escape sequences per shade level (levels 0..6)
for ((i=0; i<=255; i++)); do
    for ((s=0; s<=6; s++)); do
        idx=$((i*7+s))
        r=${SHADE_R[idx]}
        g=${SHADE_G[idx]}
        b=${SHADE_B[idx]}
        FG_TRUE_SHADES[idx]=$'\e[38;2;'"$r;$g;$b"$'m'
        BG_TRUE_SHADES[idx]=$'\e[48;2;'"$r;$g;$b"$'m'
    done
done

# Precompute sky/grass escape sequences
if ((truecolor)); then
    SKY_FG=$'\e[38;2;'"$sky"$'m'
    SKY_BG=$'\e[48;2;'"$sky"$'m'
    GRASS_FG=$'\e[38;2;'"$grass"$'m'
    GRASS_BG=$'\e[48;2;'"$grass"$'m'
else
    SKY_FG=$'\e[38;5;'"$sky"$'m'
    SKY_BG=$'\e[48;5;'"$sky"$'m'
    GRASS_FG=$'\e[38;5;'"$grass"$'m'
    GRASS_BG=$'\e[48;5;'"$grass"$'m'
fi
