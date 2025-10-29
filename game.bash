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


LANG=C LC_ALL=C
shopt -s extglob globasciiranges expand_aliases

declare -a zBuffer

# for the basic bash game loop: https://gist.github.com/izabera/5e0cc5fcd598f866eb7c6cc955ef3409

FPS=${FPS-30}

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
            '\e[?1049l' 'alt screen off'

        stty echo sane
        dumpstats
    }
    trap exitfunc exit

    hblock=$'▀\e[D\e[B' # halfblock
    sblock=$' \e[D\e[B' # "space"block (yes i'm very good at naming things)
    hlen=${#hblock}

    declare -gA column
    # size-dependent vars
    update_sizes () {
        # see dumbdrawcol
        for ((i=1;i<=rows;i++)) do column[$i]=${column[$((i-1))]}$sblock; done
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
    local x=$1 h=$2 side=$3 rdx=$4 rdy=$5 dist=$6
    local wallX texX texY_top texY_bottom top_color bottom_color
    local -i drawStart_half drawEnd_half

    # Calculate start and end points of the wall slice in HALF-ROWS.
    # The horizon is at `rows`. The screen is `rows*2` half-rows high.
    ((drawStart_half = rows - h / 2))
    ((drawEnd_half = rows + h / 2))

    # Calculate where the wall was hit (as a fraction of a cell).
    if ((side == 0)); then
        ((wallX = my + dist * rdy / fov))
    else
        ((wallX = mx + dist * rdx / fov))
    fi
    ((wallX %= scale))

    # Calculate texture x-coordinate from wallX.
    ((texX = wallX * TEX_W / scale))
    # Flip texture depending on camera direction.
    ((side == 0 && rdx > 0)) && ((texX = TEX_W - 1 - texX))
    ((side == 1 && rdy < 0)) && ((texX = TEX_W - 1 - texX))

    local -i y
    local colStr=""

    # Loop for each CHARACTER row on the screen.
    for ((y=0; y<rows; y++)); do
        local current_half_row_top=$((y*2))
        local current_half_row_bottom=$((y*2+1))

        # Determine color for the top half of the character cell.
        if ((current_half_row_top < drawStart_half)); then
            top_color=$sky
        elif ((current_half_row_top >= drawEnd_half)); then
            top_color=$grass
        else
            # It's a wall part, so calculate texture y-coordinate.
            ((texY_top = (current_half_row_top - (rows - h/2)) * TEX_H / h))
            ((texY_top < 0)) && texY_top=0
            ((texY_top >= TEX_H)) && texY_top=$((TEX_H - 1))
            top_color=${TEX_WALL_0[texY_top*TEX_W + texX]}
        fi

        # Determine color for the bottom half of the character cell.
        if ((current_half_row_bottom < drawStart_half)); then
            bottom_color=$sky
        elif ((current_half_row_bottom >= drawEnd_half)); then
            bottom_color=$grass
        else
            # It's a wall part, so calculate texture y-coordinate.
            ((texY_bottom = (current_half_row_bottom - (rows - h/2)) * TEX_H / h))
            ((texY_bottom < 0)) && texY_bottom=0
            ((texY_bottom >= TEX_H)) && texY_bottom=$((TEX_H - 1))
            bottom_color=${TEX_WALL_0[texY_bottom*TEX_W + texX]}
        fi

        # Append the half-block character with FG/BG colors and cursor movement.
        colStr+=$'\e[38;5;'"$top_color"';48;5;'"$bottom_color"'m'"$hblock"
    done

    # Print the whole column string at once.
    printf "\e[1;%dH%s" "$x" "$colStr"
}


# the wall hit calculation is a horrible recursive expansion
# it is a lot faster than a loop
# when displaying colours, it also stores the right colour in the variable w
hit='(side=sdx<sdy)?(sdx+=dx,mapX+=sx):(sdy+=dy,mapY+=sy),'

if [[ $DEPTH ]]; aliasing "$?" depthmap; then
    hit+='map[mapX/scale*mapw+mapY/scale]||hit'
else
    hit+='(w=map[mapX/scale*mapw+mapY/scale])||hit'
fi

far=$((scale*23/2)) # 11.5 steps away is too far too see
fov=$scale
drawrays () {
    # fov depends on aspect ratio
    ((planeX=sin*fov*cols/(rows*4*scale),planeY=-cos*fov*cols/(rows*4*scale),begin=cols*tid/NTHR,end=cols*(tid+1)/NTHR))

    for ((x=begin;x<end;x++)) do
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
hit,w=(w+side*wallcount)&mask0f,
dist=(side?sdx-dx:sdy-dy)*fov/scale,h=dist<scale?rows*2:rows*2*scale/dist,fdist=far-(dist>far?far:dist)))

        zBuffer[x]=$dist
        drawtexturedcol "$((x+1))" "$h" "$side" "$rdx" "$rdy" "$dist"
    done
}

[[ $UNBUFFERED ]]; aliasing "$?" unbuffered buffered
((sync)); aliasing "$?" sync
((NTHR>1)); aliasing "$?" multithread singlethread

# maybe this should be disabled if sync is off and we're in multithreaded mode
[[ $MINIMAP ]]; aliasing "$?" minimap

for i in "${!map[@]}"; do
    mapc[i*3+0]=${wallsr[mapt[i]]}
    mapc[i*3+1]=${wallsg[mapt[i]]}
    mapc[i*3+2]=${wallsb[mapt[i]]}
done

cellfmt=$'\e[38;2;%d;%d;%d;48;2;%d;%d;%dm▀'
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
