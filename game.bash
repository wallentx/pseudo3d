#!/usr/bin/env bash

[[ -e .config ]] && source ./.config

# bash calls REAP unconditionally after executing the command in every loop construct
# https://git.savannah.gnu.org/cgit/bash.git/tree/execute_cmd.c?id=c5c97b371044a44b701b6efa35984a3e1956344e#n3702
# #define REAP() \
#   do \
#     { \
#       if (job_control == 0 || interactive_shell == 0) \
#         reap_dead_jobs (); \
#     } \
#   while (0)
#
# reap_dead_jobs calls mark_dead_jobs_as_notified
#
# result: if you've ever forked in this shell session, bash will block sigchld
# after executing the body of every loop, and likely unblock it immediately after
#
# the only way to avoid this is to be in an interactive shell with job control
# note: replacing loops with recursion makes things a *lot* slower
#
# this should be safe/correct, but i'm not fully sure
# it is faster in benchmarks so it stays
#
# this is the dumbest thing i've ever written
[[ $- = *i* && $- = *m* ]] || exec "$BASH" --norc --noediting --noprofile -im +H +o history ./game.bash

mapselect=${mapselect-4}
source ./maths.bash
source ./maps.bash
source ./util.bash
source ./dispatch.bash
source ./textures.bash

NTHR=${NTHR:-$(nproc)}


LANG=C LC_ALL=C
shopt -s extglob globasciiranges expand_aliases

declare -a zBuffer

# for the basic bash game loop: https://gist.github.com/izabera/5e0cc5fcd598f866eb7c6cc955ef3409

FPS=${FPS-30}
TEXTURE_SCALE=4
RESOLUTION_SCALE=2


gamesetup () {
    if [[ ! ( $TERM && -t 0 && -t 1 ) ]]; then
        echo you need a terminal to run this >&2
        exit 1
    fi

    stty -echo raw

    # this expects a bunch of modes to always be supported, and queries support for some less common ones
    printf %b%.b \
        '\e[?1049h'         'alt screen on'        \
        '\e[?25l'           'cursor off'           \
        '\e[?1004h'         'report focus'         \
        '\e[?7l'            'autowrap off'         \
        '\e[m'              'reset colours'        \
        '\e[2J'             'erase screen'         \
        '\e[?u'             'kitty kbd proto'      \
        '\e[?2026$p'        'synchronised output'  \
        '\e[38;5;123m'      '256 colour fg'        \
        '\e[38;2;45;67;89m' 'truecolor fg'         \
        '\eP$qm\x1b\\'      'decrqss m'            \
        '\e[9999;9999H'     'move to bottom right'

    # this used to query da1 as a flush, intended to get the terminal to reply
    # *something*, but alacritty 0.15 on windows sometimes replies with da1
    # before csi?u, which messes everything else up, so some some small delay
    # was added as a workaround.  unfortunately it really just seems to be slow
    # at replying to csi?u.  we can even query dsr multiple times after csi?u,
    # and get both replies before dsr, so the delay stays
    sleep .05

    printf %b%.b \
        '\e[6n'             'query position'       \
        '\e[m'              'reset colours again'

    read -rdR
    # see tests in https://gist.github.com/izabera/3d1e5dfabbe80b3f5f2e50ec6f56eadb
    ! [[ $REPLY = *u* && ! $NOKITTY ]]; kitty=$?
    ! [[ $REPLY = *'2026;2'* ]]; sync=$?
    ! [[ $COLORTERM = *@(24bit|truecolor)* || $REPLY = *38*2*45*67*89*m* ]]; truecolor=$?

    # disambiguate   1
    # eventtypes     2
    # altkeys        4
    # allescapes     8
    # associatedtext 16
    ((kitty)) && printf '\e[>11u'

    exitfunc () {
        dispatch exit
        wait

        ((kitty)) && printf '\e[<u' >/dev/tty
        printf %b%.b >/dev/tty \
            '\e[?1004l' 'focus off' \
            '\e[?25h'   'cursor on' \
            '\e[?7h'    'autowrap on' \
            '\e[?1049l' 'alt screen off'

        stty echo sane
        dumpstats
    }
    trap exitfunc exit

    declare -g hblock_fill sblock_fill reposition_row
    printf -v hblock_fill '%*s' "$RESOLUTION_SCALE" ''
    hblock_fill=${hblock_fill// /▀}
    printf -v sblock_fill '%*s' "$RESOLUTION_SCALE" ''
    reposition_row=$'\e['"$RESOLUTION_SCALE"$'D\e[B'

    declare -gA column
    # size-dependent vars
    update_sizes () {
        # see dumbdrawcol
        for ((i=1;i<=rows;i++)) do column[$i]=${column[$((i-1))]}$' \e[D\e[B'; done
    }

    get_term_size() {
        __winch=0
        rows=${1%;*} cols=${1#*;}
        dispatch "${rows@A} ${cols@A}"
        update_sizes
        dispatch update_sizes
    }

    REPLY=${REPLY%%R*} REPLY=${REPLY##*$'\e['}
    get_term_size "$REPLY"
    trap __winch=1 WINCH

    declare -gA __keys=(
        [A]=UP [B]=DOWN [C]=RIGHT [D]=LEFT
        [1A]=UP [1B]=DOWN [1C]=RIGHT [1D]=LEFT # makes kitty slightly easier
        [' ']=SPACE [$'\t']=TAB
        [$'\n']=ENTER [$'\r']=ENTER
        [$'\177']=BACKSLASH [$'\b']=BACKSLASH
    )
    for i in {32..126}; do
        printf -v oct %03o "$i"
        printf -v "__keys[${i}u]" "\\$oct"
    done
    declare -gA PRESSED=()
    FRAME=0 START=${EPOCHREALTIME/.} TOTALSKIPPED=0 FOCUS=1

    # somehow the least painful way to parse this stuff
    __kittyregex='^..([0-9]*)(;(([^:]*)(:([0-9]*))?))?(.)(.*)'
    #                <--1--->                                 key code
    #                        <--------2------------->?
    #                          <-------3----------->
    #                           <--4-->                       modifier
    #                                  <----5---->?
    #                                    <---6-->             event type
    #                                                 <7>     final character
    #                                                    <8-> rest
    deltat=$((1000000/FPS))
    nextframe() {
        local deadline now tmout tmp
        if ((__winch)); then printf '\e[9999;9999H\e[6n'; fi
        if ((SKIPPED=0,(now=${EPOCHREALTIME/.})>=(deadline=START+ ++FRAME*deltat))); then
            # you fucked up, your game logic can't run at $FPS
            ((deadline=START+(FRAME+=(SKIPPED=(now-deadline+deltat-1)/deltat))*deltat,TOTALSKIPPED+=SKIPPED))
        fi
        while ((now<deadline)); do
            printf -v tmout 0.%06d "$((deadline-now))"
            read -t "$tmout" -n1 -d '' -r
            __input+=$REPLY now=${EPOCHREALTIME/.}
        done
        INPUT=()
        ((kitty)) || PRESSED=()
        while [[ $__input ]]; do
            case $__input in
                [$' \t\n\r\b\177']*) INPUT+=("${__keys[${__input::1}]}") __input=${__input:1} ;;
                [[:alnum:][:punct:]]*) INPUT+=("${__input::1}") __input=${__input:1} ;;
                $'\e['+([0-9])\;+([0-9])R*) tmp=${__input#$'\e['}; get_term_size "${tmp%%R*}"; __input=${__input#*R} ;;
                $'\e['*([^ABCDEFGHPQSu~])[ABCDEFGHPQSu~]*)
                    if ((kitty)); then
                        [[ $__input =~ $__kittyregex ]]
                        __input=${BASH_REMATCH[8]}
                        tmp=${__keys[${BASH_REMATCH[1]}${BASH_REMATCH[7]}]}
                        [[ $tmp ]] || continue
                        [[ $tmp = c && "(${BASH_REMATCH[4]}-1)&4" -ne 0 ]] && exit
                        ((BASH_REMATCH[6]==3)) && unset 'PRESSED[$tmp]' || PRESSED[$tmp]=1
                        continue
                    fi ;;&
                $'\e['I*) __input=${__input:3} FOCUS=1 PRESSED=() ;;
                $'\e['O*) __input=${__input:3} FOCUS=0 PRESSED=() ;;
                $'\e'[[O][ABCD]*) INPUT+=("${__keys[${__input:2:1}]}") __input=${__input:3} ;; # arrow keys
                $'\e['*([0-?])*([ -/])[@-~]*) __input=${__input##$'\e['*([0-?])*([ -/])[@-~]} ;; # unsupported csi sequence
                $'\e'[^[]*) __input=${__input:2} ;; # something went super wrong and we got an unrecognised sequence
                $'\e'*) break ;; # assume incomplete csi, hopefully it will be resolved by the next read
                $'\3'*) exit ;; #^C
                *) __input=${__input:1} # this was some non ascii unicode character (unsupported for now) or some weird ctrl character
            esac
        done
        INPUT+=("${!PRESSED[@]}")
    }
}

gamesetup
source ./colours.bash

# this code is horrible because this function is more performance-intensive than it looks like,
# and it takes a ridiculous % of the time if you write it in a less atrocious way
#
# what                 | max size
# ---------------------+-----------
# ceiling to horizon   | (rows+1)/2
# wall                 | rows
# horizon to floor     | (rows+1)/2
#
# in ${var:start:len} bash will copy the string before extracting the substring
# so this could use a long string of $'▀\e[D\e[B' as tall as the screen, but that'd be slower
# instead we use a specialised version that's shorter

drawtexturedcol () {
    local x=$1 h=$2 side=$3 rdx=$4 rdy=$5 dist=$6 w=$7
    local wallX texX texY_top texY_bottom
    local -i drawStart_half drawEnd_half
    local ESC=$'\e'

    ((drawStart_half = rows - h / 2))
    ((drawEnd_half = rows + h / 2))

    if ((side == 0)); then ((wallX = my + dist * rdy / fov)); else ((wallX = mx + dist * rdx / fov)); fi
    ((wallX %= scale))

    ((texX = (wallX * TEXTURE_SCALE * TEX_W / scale) & (TEX_W - 1)))
    ((side == 0 && rdx > 0)) && ((texX = TEX_W - 1 - texX))
    ((side == 1 && rdy < 0)) && ((texX = TEX_W - 1 - texX))

    local tex_id=$(((w-1) % 4))
    local tex_name="TEX_WALL_$tex_id"
    declare -n tex="$tex_name"

    local shade_level=$((dist * 10 / far))
    ((shade_level > 5)) && shade_level=5
    local shade_side=$((shade_level + (side==1)))
    ((shade_side > 6)) && shade_side=6

    local -i y rows_out=0
    local top_seq bottom_seq
    local colbuf="${ESC}[1;${x}H"

    # Fixed-point accumulator for texture Y (avoid per-row division)
    local -i FP_SHIFT=16
    local -i step_fp acc_top
    if ((h>0)); then
        step_fp=$(( (TEXTURE_SCALE * TEX_H << FP_SHIFT) / h ))
    else
        step_fp=0
    fi
    acc_top=$(( -drawStart_half * step_fp ))

    # Precompute shaded wall sequences for this column (all texY for this texX)
    local -a FG_WALL_SEQ BG_WALL_SEQ
    for ((y=0; y<TEX_H; y++)); do
        local color=${tex[y*TEX_W + texX]}
        if ((truecolor)); then
            local idx=$((color*7 + shade_side))
            FG_WALL_SEQ[y]=${FG_TRUE_SHADES[idx]}
            BG_WALL_SEQ[y]=${BG_TRUE_SHADES[idx]}
        else
            local shaded=${SHADE_N[shade_side*256 + color]}
            FG_WALL_SEQ[y]=${FG256[shaded]}
            BG_WALL_SEQ[y]=${BG256[shaded]}
        fi
    done

    # Calculate spans
    local -i ceil_rows wall_half_count wall_full_rows floor_rows
    local -i top_boundary bottom_boundary
    ceil_rows=$((drawStart_half/2))
    top_boundary=$((drawStart_half & 1))
    bottom_boundary=$((drawEnd_half & 1))
    wall_half_count=$((drawEnd_half - drawStart_half))
    ((wall_half_count<0)) && wall_half_count=0
    wall_full_rows=$((wall_half_count/2))
    floor_rows=$((rows - ceil_rows - wall_full_rows - top_boundary - bottom_boundary))
    ((floor_rows<0)) && floor_rows=0

    # Emit ceiling full rows using relative reposition with autowrap disabled
    colbuf+="${SKY_FG}${SKY_BG}"
    for ((y=0; y<ceil_rows && rows_out<rows; y++)); do
        if ((rows_out+1<rows)); then
            colbuf+="${hblock_fill}${reposition_row}"
        else
            colbuf+="${hblock_fill}"
        fi
        rows_out+=1
        acc_top=$((acc_top + (step_fp<<1)))
    done

    # Top boundary mixed row (top sky, bottom wall)
    if ((top_boundary && rows_out<rows)); then
        # top is sky
        top_seq=$SKY_FG
        # bottom is first wall half
        ((texY_bottom = (((acc_top + step_fp) >> FP_SHIFT) & (TEX_H - 1))))
        local index=$((texY_bottom*TEX_W + texX))
        local color=${tex[index]}
        if ((truecolor)); then
            local idx=$((color*7 + shade_side))
            bottom_seq=${BG_TRUE_SHADES[idx]}
        else
            local shaded=${SHADE_N[shade_side*256 + color]}
            bottom_seq=${BG256[shaded]}
        fi
        colbuf+="${top_seq}${bottom_seq}"
        if ((rows_out+1<rows)); then
            colbuf+="${hblock_fill}${reposition_row}"
        else
            colbuf+="${hblock_fill}"
        fi
        rows_out+=1
        acc_top=$((acc_top + (step_fp<<1)))
    fi

    # Full wall rows (both halves wall)
    for ((y=0; y<wall_full_rows && rows_out<rows; y++)); do
        ((texY_top = ((acc_top >> FP_SHIFT) & (TEX_H - 1))))
        ((texY_bottom = (((acc_top + step_fp) >> FP_SHIFT) & (TEX_H - 1))))
        top_seq=${FG_WALL_SEQ[texY_top]}
        bottom_seq=${BG_WALL_SEQ[texY_bottom]}

        colbuf+="${top_seq}${bottom_seq}"
        if ((rows_out+1<rows)); then
            colbuf+="${hblock_fill}${reposition_row}"
        else
            colbuf+="${hblock_fill}"
        fi
        rows_out+=1
        acc_top=$((acc_top + (step_fp<<1)))
    done

    # Bottom boundary mixed row (top wall, bottom grass)
    if ((bottom_boundary && rows_out<rows)); then
        # top is last wall half
        ((texY_top = ((acc_top >> FP_SHIFT) & (TEX_H - 1))))
        top_seq=${FG_WALL_SEQ[texY_top]}
        bottom_seq=$GRASS_BG
        colbuf+="${top_seq}${bottom_seq}"
        if ((rows_out+1<rows)); then
            colbuf+="${hblock_fill}${reposition_row}"
        else
            colbuf+="${hblock_fill}"
        fi
        rows_out+=1
        acc_top=$((acc_top + (step_fp<<1)))
    fi

    # Emit floor full rows
    colbuf+="${GRASS_FG}${GRASS_BG}"
    for ((y=0; y<floor_rows && rows_out<rows; y++)); do
        if ((rows_out+1<rows)); then
            colbuf+="${hblock_fill}${reposition_row}"
        else
            colbuf+="${hblock_fill}"
        fi
        rows_out+=1
        acc_top=$((acc_top + (step_fp<<1)))
    done

    # Print the entire column at once
    printf "%b" "$colbuf"
}


# the wall hit calculation is a horrible recursive expansion
# it is a lot faster than a loop
# when displaying colours, it also stores the right colour in the variable w
hit='(side=sdx<sdy)?(sdx+=dx,mapX+=sx):(sdy+=dy,mapY+=sy),'

if [[ $DEPTH ]]; aliasing "$?" depthmap; then
    hit+='(w=map[mapX/scale*mapw+mapY/scale])||hit'
else
    hit+='(w=map[mapX/scale*mapw+mapY/scale])||hit'
fi

far=$((scale*23/2)) # 11.5 steps away is too far too see
fov=$scale
drawrays () {
    # fov depends on aspect ratio
    ((planeX=sin*fov*cols/(rows*4*scale),planeY=-cos*fov*cols/(rows*4*scale),begin=cols*tid/NTHR,end=cols*(tid+1)/NTHR))

    for ((x=begin;x<end;x+=RESOLUTION_SCALE)) do
((cameraX=2*x*scale/cols-scale,
mapX=mx&maskf0,mapY=my&maskf0,
rdx=cos+planeX*cameraX/scale,
rdy=sin+planeY*cameraX/scale,
adX=rdx<0?-rdx:rdx,
adY=rdy<0?-rdy:rdy,
dx=rdx?scale*scale/adX:inf,
dy=rdy?scale*scale/adY:inf,
rdx<0?(sx=-scale,sdx=(mx-mapX)*dx/scale):(sx=scale,sdx=(mapX+scale-mx)*dx/scale),
rdy<0?(sy=-scale,sdy=(my-mapY)*dy/scale):(sy=scale,sdy=(mapY+scale-my)*dy/scale),
hit,
dist=(side?sdx-dx:sdy-dy)*fov/scale,h=dist<scale?rows*2:rows*2*scale/dist,fdist=far-(dist>far?far:dist)))

        zBuffer[x]=$dist
        drawtexturedcol "$((x+1))" "$h" "$side" "$rdx" "$rdy" "$dist" "$w"
    done
}

[[ $UNBUFFERED ]]; aliasing "$?" unbuffered buffered
((sync)); aliasing "$?" sync
((NTHR>1)); aliasing "$?" multithread singlethread

# maybe this should be disabled if sync is off and we're in multithreaded mode
[[ $MINIMAP ]]; aliasing "$?" minimap

declare -a mapc
if ((truecolor)); then
    cellfmt=$'\e[38;2;%d;%d;%d;48;2;%d;%d;%dm▀'
    for ((i=0; i<mapw*maph; i++)); do
        # Each map cell is one character wide. We use half-blocks, so we can show two cells vertically.
        # FG is the current row, BG is the row below.
        r1=${wallsr[mapt[i]]} g1=${wallsg[mapt[i]]} b1=${wallsb[mapt[i]]}
        next_row_i=$((i+mapw))
        ((next_row_i >= mapw*maph)) && next_row_i=$i # Use same cell if we're on the last row.
        r2=${wallsr[mapt[next_row_i]]} g2=${wallsg[mapt[next_row_i]]} b2=${wallsb[mapt[next_row_i]]}
        mapc+=($r1 $g1 $b1 $r2 $g2 $b2)
    done
else
    cellfmt=$'\e[38;5;%dm\e[48;5;%dm▀'
    for ((i=0; i<mapw*maph; i++)); do
        # In 256-color mode, wallsr is the color index.
        fg_idx=${wallsr[mapt[i]]}
        next_row_i=$((i+mapw))
        ((next_row_i >= mapw*maph)) && next_row_i=$i
        bg_idx=${wallsr[mapt[next_row_i]]}
        mapc+=($fg_idx $bg_idx)
    done
fi

printf -v mapfmt '%*s' "$mapw"
mapfmt=${mapfmt// /$cellfmt}$'\r\e[B'
printf -v mapcache "$mapfmt" "${mapc[@]}"

minimap='row=mx/scale,odd=row%2,row=row/2*2,col=my/scale,
fgidx=row*mapw+col,bgidx=(row+1)*mapw+col,
fgr=wallsr[odd?map[fgidx]:2],fgg=wallsg[odd?map[fgidx]:2],fgb=wallsb[odd?map[fgidx]:2],
bgr=wallsr[odd?2:map[bgidx]],bgg=wallsg[odd?2:map[bgidx]],bgb=wallsb[odd?2:map[bgidx]]'
minimapfmt="%s\e[%dA\e[%dC$cellfmt\e[m"

exec {outfile}>"${OUTFILE-/dev/tty}"
declare -A frametimes
drawframe () {
    frame_start=${EPOCHREALTIME/.}
    sync printf '\e[?2026h'

    multithread buffered dispatch 'drawrays > buffered."$tid"; printf x'
    multithread unbuffered dispatch 'drawrays >&"$outfile"; printf x'

    minimap ((minimap))

    multithread for ((t=0;t<NTHR;t++)) do
    multithread     read -rn1 -u"${notify[t]}"
    multithread     buffered read -rd '' 'buffered[t]' < buffered."$t"
    multithread done
    multithread buffered printf %b "${buffered[@]}"

    singlethread drawrays

    minimap printf "\e[1;1H$minimapfmt" "$mapcache" "$(((maph-row)/2))" "$col" "$fgr" "$fgg" "$fgb" "$bgr" "$bgg" "$bgb"

    sync printf '\e[?2026l'
    ((frametimes[$((${EPOCHREALTIME/.}-frame_start))]++))
}

run_listeners

if ((BENCHMARK)); then
    sincos "$angle"
    START=${EPOCHREALTIME/.}
    while ((FRAME++<BENCHMARK)); do drawframe; done >&"$outfile"
    ((FRAME--))
    exit
fi

speed=0 rspeed=0


bomb=4
addstate walls{r,g,b}\[{"$bomb","$((wallcount+bomb))"}]{,}
addstate fov

collision='(map[mx/scale*mapw+my/scale]|1)==1'
move='t=pos*speed*deltat/scale**2'
smoothing='speed=speed*3**(deltat/15000)/4**(deltat/15000)'

printf -v movement %s, \
    "${move//pos/mx+cos}" "${collision/mx/t}&&(mx=t)" \
    "${move//pos/my+sin}" "${collision/my/t}&&(my=t)" \
    "$smoothing" "${smoothing//speed/rspeed}"
movement=${movement%,}

bombtimer='wallsg[bomb]=wallsg[bomb+wallcount]=(FRAME*deltat/2500)%255'
bombtimer+=,${bombtimer//wallsg/wallsb}
bombtimer+=,'wallsr[bomb]=200,wallsr[bomb+wallcount]=250'

((
scale_2=scale/2,
scale_5=scale/5,
scale_10=scale/10,
scale_100=scale/100,
scale2=scale*2,
scale5=scale*5,
scale10=scale*10,
scale100=scale*100
))
while nextframe; do
    for k in "${INPUT[@]}"; do
        case $k in
            q) break 2 ;;
            LEFT)  rspeed=$scale_5;;
            RIGHT) rspeed=-$scale_5;;
            UP)   speed=$scale_2;;
            DOWN) speed=-$scale_2;;
            j) ((fov<scale2&&(fov=fov*105/100))); oneshot fov ;;
            k) ((fov>scale_5&&(fov=fov*95/100))); oneshot fov ;;
        esac
    done

    ((angle+=rspeed*deltat/scale,angle>=pi2&&(angle-=pi2),angle<0&&(angle+=pi2)))
    sincos "$angle"

    ((movement,bombtimer))

    drawframe >&"$outfile"
done
