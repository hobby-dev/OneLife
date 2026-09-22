#!/bin/bash
#
# Login regression tests: the paths a new connection can take in the
# server, from the first message to a spawned, reconnected or rejected
# player.
#
# Usage: runLoginTest.sh functional|leaks [case ...]
#
#   functional  run the cases against the server
#   leaks       run the cases with the server under valgrind, then stop
#               the server cleanly with connections still waiting, and
#               also fail on leaked memory ("definitely lost"); invalid
#               memory use (invalid read/write/free, mismatched free) is
#               shown as a warning
#   case ...    run only these cases (default: all), plus the final
#               checks
#
# Builds OneLifeServer, runs one server in a temporary directory, and
# plays the cases below against it with /dev/tcp clients.  Each case uses
# its own emails and twin codes.  A case checks the replies its clients
# get (ACCEPTED, REJECTED, game data, connection closed) and the server
# log lines it expects.  After all cases, every client is closed and the
# test checks that the server is still running, is idle (below
# CPU_THRESHOLD) and has no sockets left in CLOSE-WAIT.
#
# Cases (name: what is sent -> what is expected):
#   solo                LOGIN -> new life, game data
#   rlogin              RLOGIN -> handled like LOGIN
#   tutorial            LOGIN, tutorial 1 -> tutorial loaded, game data
#   emailCase           LOGIN MiXeD@... -> email lowercased
#   seed                LOGIN email|seed -> seeded Eve, seed cut from email
#   seedOnly            LOGIN |seed -> email becomes blank_email
#   famTargetUnknown    LOGIN email:family, no such family -> ACCEPTED,
#                       then REJECTED
#   badFormat           LOGIN with 3 or 6 fields -> REJECTED
#   notLogin            first message not LOGIN -> closed, no REJECTED
#   garbage             no # terminator, not LOGIN -> closed, no REJECTED
#   loginTimeout        nothing sent -> REJECTED after 10 seconds
#   playerList          PLAYER_LIST secret -> player list, closed after
#                       10 seconds
#   playerListBadSecret PLAYER_LIST wrong -> REJECTED
#   reconnect           disconnect, LOGIN again -> same life
#   reconnectConnected  LOGIN again while connected -> same life, old
#                       connection closed
#   twin2, twin3, twin4 twin party of 2, 3, 4 -> all spawn
#   twinCountClamped    twin count 5 -> treated as maxTwinPartySize (4)
#   twinCountMismatch   same twin code, different counts -> no party
#   twinLeaveWaiting    a twin leaves while waiting -> party needs
#                       someone else to complete it
#   twinFamTarget       twin party with unknown family -> all REJECTED
#   twinOldLifeFirst    first twin to join has a disconnected life -> old
#                       life killed, party spawns
#   twinOldLifeConnected  twin still connected to an old life -> same,
#                       old connection closed
#   twinDropReconnect   spawned twin drops, LOGIN without twin code ->
#                       same twin life
#   twinTutorial        twin party in the tutorial -> both tutorials load
#   eveName             Eve says "I AM name" -> named after the eveName
#                       setting plus a family name
#   famTargetExisting   LOGIN email:family, family has a fertile Eve ->
#                       born into it
#   famTargetOnly       LOGIN :family -> email becomes blank_email, born
#                       into the family (or, if a blank_email life from
#                       an earlier case is still alive, reconnected to it)
#   twinFamTargetExisting  twin party with email:family -> all born into
#                       it
#
# The famTarget*Existing/Only cases need a fertile Eve: the first of them
# spawns one named Eve per case at age 14.9 and waits until they are 15.
#
# Not covered (need other settings or outside servers): client password,
# ticket server, shutdown mode / server full.
#
# Exit codes:
#   0  PASS: all cases and final checks passed
#   1  FAIL: at least one case or final check failed
#   2  setup error (build, game data, server start, client connection,
#      an error in this script) or bad usage
#
# Environment:
#   ONELIFE_DATA_DIR   OneLifeData7 checkout, default ../OneLifeData7 next
#                      to the OneLife repo (needs objects, transitions,
#                      categories, tutorialMaps, dataVersionNumber.txt)
#   KEEP_RUN_DIR=1     keep the server run directory afterwards
#   STARTUP_TIMEOUT    seconds to wait for the server to start (default 600)
#   VERBOSE=1          show every step and check as it happens; by default
#                      a case that passes is one line, and only a case that
#                      fails shows its steps and checks
#   CPU_SAMPLE         seconds per CPU measurement (default 5)
#   CPU_THRESHOLD      CPU usage, in % of one core, that fails (default 80)
#
# Requires: g++, make, ss (iproute2), and valgrind for leaks


set -u


usage() {
    echo "Usage: $( basename "$0" ) functional|leaks [case ...]"
    echo
    echo "  functional  run the login cases against the server"
    echo "  leaks       run them with the server under valgrind and also fail"
    echo "              on leaked memory"
    echo "  case ...    run only these cases (default: all)"
    echo
    echo "Cases and environment variables are listed at the top of $0"
}

case "${1:-}" in
    functional|leaks)
        MODE=$1
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

# the famTarget cases with an existing family go last: they wait for
# their Eves to become fertile, and other logins could be born to them
ALL_CASES="solo rlogin tutorial emailCase seed seedOnly famTargetUnknown
    badFormat notLogin garbage loginTimeout playerList playerListBadSecret
    reconnect reconnectConnected twin2 twin3 twin4 twinCountClamped
    twinCountMismatch twinLeaveWaiting twinFamTarget twinOldLifeFirst
    twinOldLifeConnected twinDropReconnect twinTutorial eveName
    famTargetExisting famTargetOnly twinFamTargetExisting"

CASES="${*:-$ALL_CASES}"

for c in $CASES; do
    if [[ " $( echo $ALL_CASES ) " != *" $c "* ]]; then
        echo "Unknown case: $c" >&2
        echo "Cases: $( echo $ALL_CASES )" >&2
        exit 2
    fi
done


# Details of the running case (what clients send, each check), shown
# only if the case fails, or at once with VERBOSE=1.
VERBOSE="${VERBOSE:-0}"
CASE=""
CASE_OUT=""

say() {
    if [ "$VERBOSE" = "1" ]; then
        echo "$*"
    else
        CASE_OUT="$CASE_OUT$*"$'\n'
    fi
}

# on a setup error in the middle of a case, show how far the case got
showCaseOut() {
    if [ -n "$CASE" ] && [ "$VERBOSE" != "1" ]; then
        echo "SETUP ERROR" >&2
        printf "%s" "$CASE_OUT" >&2
    fi
    CASE=""
    CASE_OUT=""
}

fail_setup() {
    showCaseOut
    echo "SETUP ERROR: $*" >&2
    exit 2
}


# Only finish() exits with 0 or 1.  Any other exit (fail_setup, a set -u
# error, a failed command) becomes exit 2.
RESULT=""

finish() {
    RESULT=$1
    exit "$1"
}

# replaced below once there is a server and run directory to clean up
cleanup() {
    :
}

onExit() {
    local status=$?
    cleanup
    if [ -z "$RESULT" ] && [ "$status" -ne 2 ]; then
        showCaseOut
        echo "SETUP ERROR: test script stopped unexpectedly" \
             "(exit $status)" >&2
        exit 2
    fi
}
trap onExit EXIT


SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SERVER_DIR="$( cd "$SCRIPT_DIR/../.." && pwd )"
REPO_DIR="$( cd "$SERVER_DIR/.." && pwd )"

STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-600}"
CPU_SAMPLE="${CPU_SAMPLE:-5}"
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"

PLAYER_LIST_SECRET="loginTestSecret"
EVE_NAME="TESTEVE"


TOOLS="make g++ ss"
[ "$MODE" = "leaks" ] && TOOLS="$TOOLS valgrind"
for tool in $TOOLS; do
    command -v "$tool" > /dev/null || fail_setup "$tool not found"
done



# ---- build ----------------------------------------------------------------

echo "== Building OneLifeServer"
(
    cd "$SERVER_DIR" || exit 1
    if [ ! -f Makefile ]; then
        ./configure 1 > /dev/null || exit 1
    fi
    make -j"$( nproc )" > /dev/null
) || fail_setup "server build failed"

SERVER_BIN="$SERVER_DIR/OneLifeServer"
[ -x "$SERVER_BIN" ] || fail_setup "no server binary at $SERVER_BIN"



# ---- game data ------------------------------------------------------------

DATA_ITEMS="objects transitions categories tutorialMaps dataVersionNumber.txt"

dataDirOk() {
    for item in $DATA_ITEMS; do
        [ -e "$1/$item" ] || return 1
    done
    return 0
}

ONELIFE_DATA_DIR="${ONELIFE_DATA_DIR:-$REPO_DIR/../OneLifeData7}"

dataDirOk "$ONELIFE_DATA_DIR" || \
    fail_setup "no game data in $ONELIFE_DATA_DIR (set ONELIFE_DATA_DIR to an OneLifeData7 checkout)"

ONELIFE_DATA_DIR="$( cd "$ONELIFE_DATA_DIR" && pwd )"
echo "== Using game data from $ONELIFE_DATA_DIR"



# ---- run directory --------------------------------------------------------

RUN_DIR="$( mktemp -d "${TMPDIR:-/tmp}/loginTest.XXXXXX" )"
SERVER_PID=""

# client name -> socket fd, reader pid
declare -A CLIENT_FD
declare -A READER_PID

cleanup() {
    local name
    for name in "${!CLIENT_FD[@]}"; do
        closeClient "$name"
    done

    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2> /dev/null; then
        kill -KILL "$SERVER_PID" 2> /dev/null
    fi
    if [ "${KEEP_RUN_DIR:-0}" = "1" ]; then
        echo "== Run directory kept: $RUN_DIR"
    else
        rm -rf "$RUN_DIR"
    fi
}

cp -r "$SERVER_DIR/settings" "$RUN_DIR/"
cp "$SERVER_DIR/firstNames.txt" "$SERVER_DIR/lastNames.txt" "$RUN_DIR/"
for item in $DATA_ITEMS; do
    ln -s "$ONELIFE_DATA_DIR/$item" "$RUN_DIR/$item"
done

# no outside servers, no passwords
for setting in requireTicketServerCheck requireClientPassword \
               useCurseServer useStatsServer useLifeTokenServer \
               useFitnessServer; do
    echo 0 > "$RUN_DIR/settings/$setting.ini"
done
echo "$PLAYER_LIST_SECRET" > "$RUN_DIR/settings/playerListSecret.ini"

# the cases rely on these defaults
echo 1 > "$RUN_DIR/settings/forceEveOnSeededSpawn.ini"
echo 4 > "$RUN_DIR/settings/maxTwinPartySize.ini"
# not the default EVE, so eveName can tell the setting is used
echo "$EVE_NAME" > "$RUN_DIR/settings/eveName.ini"

# first free port from 18005 up
PORT=18005
while [ -n "$( ss -Htan "sport = :$PORT" )" ]; do
    PORT=$(( PORT + 1 ))
done
echo "$PORT" > "$RUN_DIR/settings/port.ini"



# ---- start server ---------------------------------------------------------

VG_LOG="$RUN_DIR/valgrind.txt"

if [ "$MODE" = "leaks" ]; then
    echo "== Starting server under valgrind on port $PORT (startup is slow)"
    (
        cd "$RUN_DIR" || exit 1
        exec valgrind --leak-check=full \
            --show-leak-kinds=definite \
            --log-file="$VG_LOG" \
            "$SERVER_BIN" > "$RUN_DIR/serverOut.txt" 2>&1
    ) &
else
    echo "== Starting server on port $PORT"
    (
        cd "$RUN_DIR" || exit 1
        exec "$SERVER_BIN" > "$RUN_DIR/serverOut.txt" 2>&1
    ) &
fi
SERVER_PID=$!

waited=0
until grep -q "Listening for connection on port" "$RUN_DIR/log.txt" 2> /dev/null; do
    if ! kill -0 "$SERVER_PID" 2> /dev/null; then
        tail -20 "$RUN_DIR/log.txt" "$RUN_DIR/serverOut.txt" 2> /dev/null
        fail_setup "server exited during startup"
    fi
    if [ "$waited" -ge "$STARTUP_TIMEOUT" ]; then
        fail_setup "server did not start within ${STARTUP_TIMEOUT}s"
    fi
    sleep 1
    waited=$(( waited + 1 ))
done
echo "== Server listening after ~${waited}s"



# ---- clients --------------------------------------------------------------

# Clients are /dev/tcp connections, named by the case.  After connecting
# and reading the server greeting, a background cat copies everything
# the server sends to $RUN_DIR/client_<name>.bin.  When the server
# closes the connection, that cat exits.

# openClient name
openClient() {
    local name=$1 fd reply
    exec {fd}<>"/dev/tcp/127.0.0.1/$PORT" ||
        fail_setup "$name: can't connect to port $PORT"
    CLIENT_FD[$name]=$fd

    IFS= read -r -d '#' -t 60 -u "$fd" reply
    [[ "$reply" == SN* ]] || fail_setup "$name: unexpected greeting '$reply'"

    # the reader must not hold other clients' sockets, or closing those
    # clients would not close their connections
    (
        for other in "${CLIENT_FD[@]}"; do
            [ "$other" = "$fd" ] || eval "exec $other>&-"
        done
        exec cat <&"$fd"
    ) > "$RUN_DIR/client_$name.bin" &
    READER_PID[$name]=$!
}

# sendRaw name text
sendRaw() {
    say "  $1 sends $( show "$2" )"
    echo -n "$2" >&"${CLIENT_FD[$1]}"
}

# login name email [tutorial [twinCode twinCount]]
# email may carry |seed or :famTarget
login() {
    local name=$1 msg="LOGIN $2 aaaa aaaa"
    [ $# -ge 3 ] && msg="$msg $3"
    [ $# -ge 5 ] && msg="$msg $4 $5"
    openClient "$name"
    sendRaw "$name" "$msg#"
}

# hangUp name: the client closes its connection, as part of a case
hangUp() {
    say "  $1 closes its connection"
    closeClient "$1"
}

# the reader holds a copy of the socket, so it has to go too
closeClient() {
    local name=$1
    [ -n "${CLIENT_FD[$name]:-}" ] || return 0
    kill "${READER_PID[$name]}" 2> /dev/null
    wait "${READER_PID[$name]}" 2> /dev/null
    eval "exec ${CLIENT_FD[$name]}>&-"
    unset "CLIENT_FD[$name]" "READER_PID[$name]"
}

# printable start of what the client received, for messages
received() {
    head -c 200 "$RUN_DIR/client_$1.bin" 2> /dev/null | tr -d "\\000"
}

receivedBytes() {
    stat -c %s "$RUN_DIR/client_$1.bin" 2> /dev/null || echo 0
}

# true once the server has closed the connection
isClosed() {
    ! kill -0 "${READER_PID[$1]:-}" 2> /dev/null
}

# show text: text quoted on one line, newlines as \n, cut after 60 chars
show() {
    local s=${1//$'\n'/\\n}
    [ "${#s}" -gt 60 ] && s="${s:0:60}..."
    echo "'$s'"
}

# clientState name: what the client got so far and whether it is open
clientState() {
    local bytes state="connection still open"
    bytes="$( receivedBytes "$1" )"
    isClosed "$1" && state="connection closed by server"
    if [ "$bytes" -eq 0 ]; then
        echo "nothing received, $state"
    else
        echo "$bytes bytes, starting $( show "$( received "$1" )" ), $state"
    fi
}



# ---- server log -----------------------------------------------------------

# log lines of the current case only
CASE_LOG_START=0

caseLog() {
    tail -n +$(( CASE_LOG_START + 1 )) "$RUN_DIR/log.txt"
}

# player id from "New player <email> connected as player <id>", or
# "<no id>" if there is no such line (the check for it has failed already)
playerId() {
    local id
    id="$( caseLog | grep -F "New player $1 connected as player " | tail -1 |
           sed 's/.* connected as player \([0-9]*\).*/\1/' )"
    echo "${id:-<no id>}"
}

# lastLogLines n: the last n log lines of the case, indented, for
# messages; once per case, they would be the same lines again
LOG_LINES_SHOWN=0
lastLogLines() {
    if [ "$LOG_LINES_SHOWN" -eq 1 ]; then
        say "                   (log lines shown above)"
        return
    fi
    LOG_LINES_SHOWN=1
    say "$( caseLog | tail -n "$1" | cut -c 1-120 |
            sed 's/^/                   | /' )"
}



# ---- checks ---------------------------------------------------------------

# Every check adds one line to the case details: "ok" and what was seen,
# or "FAIL", what was expected and what actually happened.

CASE_FAILED=0
FAILED_CASES=""
FAILURES=""

ok() {
    say "  ok    $*"
}

# fail check expected actual
fail() {
    say "  FAIL  $1"
    say "          expected: $2"
    say "          actual:   $3"
    CASE_FAILED=1
    FAILURES="$FAILURES
  $CASE: $1"
}

# pause seconds why
pause() {
    say "  (waiting ${1}s: $2)"
    sleep "$1"
}

# waitFor timeout command...
# runs command every 0.1s until it succeeds or timeout seconds pass
waitFor() {
    local limit=$(( $1 * 10 )) n=0
    shift
    until "$@"; do
        n=$(( n + 1 ))
        [ "$n" -ge "$limit" ] && return 1
        sleep 0.1
    done
    return 0
}

logHas() {
    caseLog | grep -q -F -- "$1"
}

# logCount text: number of case log lines containing text
logCount() {
    caseLog | grep -c -F -- "$1"
}

# logCountAtLeast text n
logCountAtLeast() {
    [ "$( logCount "$1" )" -ge "$2" ]
}

replyStartsWith() {
    [ "$( head -c "${#2}" "$RUN_DIR/client_$1.bin" 2> /dev/null )" = "$2" ]
}

replyHas() {
    grep -a -q -F -- "$2" "$RUN_DIR/client_$1.bin" 2> /dev/null
}

# game data = anything after the ACCEPTED message
hasGameData() {
    local accepted=$'ACCEPTED\n#'
    replyStartsWith "$1" "$accepted" &&
        [ "$( receivedBytes "$1" )" -gt "${#accepted}" ]
}

expectLog() {
    local t=${2:-15}
    if waitFor "$t" logHas "$1"; then
        ok "log: $1"
    else
        fail "log: $1" \
             "a server log line containing this within ${t}s" \
             "no such line; last log lines of this case:"
        lastLogLines 5
    fi
}

expectNoLog() {
    if logHas "$1"; then
        fail "no log: $1" \
             "no server log line containing this" \
             "$( caseLog | grep -F -m1 -- "$1" | cut -c 1-120 )"
    else
        ok "no log: $1"
    fi
}

# expectLogCount text n: at least n log lines containing text
expectLogCount() {
    if waitFor 15 logCountAtLeast "$1" "$2"; then
        ok "log, $2 times: $1"
    else
        fail "log, $2 times: $1" \
             "at least $2 server log lines containing this within 15s" \
             "$( logCount "$1" ) lines"
    fi
}

expectReply() {
    local t=${3:-15}
    if waitFor "$t" replyStartsWith "$1" "$2"; then
        ok "$1 got reply $( show "$2" )"
    else
        fail "$1 reply" \
             "reply starting with $( show "$2" ) within ${t}s" \
             "$( clientState "$1" )"
    fi
}

expectReplyHas() {
    local t=${3:-15}
    if waitFor "$t" replyHas "$1" "$2"; then
        ok "$1 got $( show "$2" ) in its reply"
    else
        fail "$1 reply" \
             "$( show "$2" ) somewhere in the reply within ${t}s" \
             "$( clientState "$1" )"
    fi
}

expectGameData() {
    local t=${2:-15}
    if waitFor "$t" hasGameData "$1"; then
        ok "$1 got game data after ACCEPTED ($( receivedBytes "$1" ) bytes so far)"
    else
        fail "$1 game data" \
             "'ACCEPTED\n#' followed by game data within ${t}s" \
             "$( clientState "$1" )"
    fi
}

expectNoGameData() {
    if hasGameData "$1"; then
        fail "$1 no game data" \
             "nothing after 'ACCEPTED\n#'" \
             "$( clientState "$1" )"
    else
        ok "$1 got no game data"
    fi
}

expectClosed() {
    local t=${2:-15}
    if waitFor "$t" isClosed "$1"; then
        ok "$1 connection closed by server"
    else
        fail "$1 closed" \
             "server closes the connection within ${t}s" \
             "$( clientState "$1" )"
    fi
}

expectOpen() {
    if isClosed "$1"; then
        fail "$1 open" \
             "connection still open" \
             "$( clientState "$1" )"
    else
        ok "$1 connection still open"
    fi
}

expectEmpty() {
    if [ "$( receivedBytes "$1" )" -eq 0 ]; then
        ok "$1 got no reply"
    else
        fail "$1 no reply" \
             "nothing sent to the client" \
             "$( clientState "$1" )"
    fi
}

# expectNewLife email: a life was born for email in this case
expectNewLife() {
    expectLog "New player $1 connected as player" "${2:-15}"
}

# waitDisconnected email
waitDisconnected() {
    expectLog "($1) marked as disconnected" 30
}



# ---- cases ----------------------------------------------------------------

case_solo() {
    login solo solo@test.com
    expectReply solo $'ACCEPTED\n#'
    expectNewLife solo@test.com
    expectGameData solo
}

case_rlogin() {
    openClient rlogin
    sendRaw rlogin "RLOGIN rlogin@test.com aaaa aaaa#"
    expectReply rlogin $'ACCEPTED\n#'
    expectNewLife rlogin@test.com
    expectGameData rlogin
}

case_tutorial() {
    login tutorial tutorial@test.com 1
    expectReply tutorial $'ACCEPTED\n#'
    expectLog "New player tutorial@test.com tutorial loaded after" 60
    expectGameData tutorial 60
}

case_emailCase() {
    login emailCase MiXeD@Test.COM
    expectReply emailCase $'ACCEPTED\n#'
    expectNewLife mixed@test.com
}

case_seed() {
    login seed "seed@test.com|someSeed"
    expectReply seed $'ACCEPTED\n#'
    expectLog "Player seed@test.com seed evaluated to"
    expectNewLife seed@test.com
    expectGameData seed
}

case_seedOnly() {
    login seedOnly "|otherSeed"
    expectReply seedOnly $'ACCEPTED\n#'
    expectNewLife blank_email
}

case_famTargetUnknown() {
    login famTarget "famtarget@test.com:noSuchFamily"
    expectReply famTarget $'ACCEPTED\n#'
    expectReplyHas famTarget "REJECTED"
    expectLog "cause: Target family is not found"
    expectClosed famTarget
    expectNoLog "New player famtarget@test.com"
}

case_badFormat() {
    openClient badFormat3
    sendRaw badFormat3 "LOGIN badformat3@test.com aaaa#"
    openClient badFormat6
    sendRaw badFormat6 "LOGIN badformat6@test.com aaaa aaaa 0 code#"
    expectReply badFormat3 "REJECTED"
    expectReply badFormat6 "REJECTED"
    expectLogCount "LOGIN message has wrong format" 2
    expectClosed badFormat3
    expectClosed badFormat6
}

case_notLogin() {
    openClient notLogin
    sendRaw notLogin "HELLO#"
    expectLog "Client's first message not LOGIN"
    expectClosed notLogin
    expectEmpty notLogin
}

case_garbage() {
    openClient garbage
    sendRaw garbage "GARBAGE_WITHOUT_TERMINATOR"
    expectLog "with no LOGIN or RLOGIN present"
    expectClosed garbage
    expectEmpty garbage
}

case_loginTimeout() {
    openClient loginTimeout
    say "  loginTimeout sends nothing"
    expectLog "Client failed to LOGIN after 10 seconds" 20
    expectReply loginTimeout "REJECTED"
    expectClosed loginTimeout
}

case_playerList() {
    login plSolo playerlist@test.com
    expectNewLife playerlist@test.com

    openClient playerList
    sendRaw playerList "PLAYER_LIST $PLAYER_LIST_SECRET#"
    expectLog "PLAYER_LIST response-message sent"
    expectReplyHas playerList "#"
    local count
    count="$( received playerList | head -1 )"
    if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -ge 1 ]; then
        ok "playerList first line is a player count: $count"
    else
        fail "playerList player count" \
             "first line of the reply is a player count of 1 or more" \
             "$( show "$count" )"
    fi
    expectLog "for PLAYER_LIST request after 10 seconds" 20
    expectClosed playerList
}

case_playerListBadSecret() {
    openClient playerListBad
    sendRaw playerListBad "PLAYER_LIST wrongSecret#"
    expectLog "Invalid secret for request PLAYER_LIST"
    expectReply playerListBad "REJECTED"
    expectClosed playerListBad
}

case_reconnect() {
    login reconnect1 reconnect@test.com
    expectNewLife reconnect@test.com
    expectGameData reconnect1
    local id
    id="$( playerId reconnect@test.com )"
    hangUp reconnect1
    waitDisconnected reconnect@test.com

    login reconnect2 reconnect@test.com
    expectReply reconnect2 $'ACCEPTED\n#'
    expectLog "Player $id (reconnect@test.com) has reconnected."
    expectGameData reconnect2
}

case_reconnectConnected() {
    login reconnectConn1 reconnectconn@test.com
    expectNewLife reconnectconn@test.com
    expectGameData reconnectConn1
    local id
    id="$( playerId reconnectconn@test.com )"

    login reconnectConn2 reconnectconn@test.com
    expectLog "Player $id (reconnectconn@test.com) marked as disconnected (Authentic reconnect received)"
    expectLog "Player $id (reconnectconn@test.com) has reconnected."
    expectGameData reconnectConn2
    expectClosed reconnectConn1
}

# twinParty case code count size [email prefix]
# size clients log in with twin code and count; all must spawn
twinParty() {
    local c=$1 code=$2 count=$3 size=$4 i
    for (( i = 1; i <= size; i++ )); do
        login "$c$i" "$c$i@test.com" 0 "$code" "$count"
    done
    expectLog "Found $size other people waiting for twin party of"
    for (( i = 1; i <= size; i++ )); do
        expectReply "$c$i" $'ACCEPTED\n#'
        expectNewLife "$( echo "$c$i" | tr 'A-Z' 'a-z' )@test.com"
        expectGameData "$c$i"
    done
}

case_twin2() {
    twinParty twin2p twin2Code 2 2
}

case_twin3() {
    twinParty twin3p twin3Code 3 3
}

case_twin4() {
    twinParty twin4p twin4Code 4 4
}

case_twinCountClamped() {
    twinParty clampp clampCode 5 4
}

case_twinCountMismatch() {
    login mismatch2 mismatch2@test.com 0 mismatchCode 2
    login mismatch3 mismatch3@test.com 0 mismatchCode 3
    expectReply mismatch2 $'ACCEPTED\n#'
    expectReply mismatch3 $'ACCEPTED\n#'
    pause 3 "different twin counts must not form a party"
    expectNoLog "waiting for twin party of mismatch"
    expectNoLog "New player mismatch"
    expectNoGameData mismatch2
    expectNoGameData mismatch3
    expectOpen mismatch2
    expectOpen mismatch3

    hangUp mismatch2
    hangUp mismatch3
    expectLogCount "Failed to read from twin-waiting client socket" 2
}

case_twinLeaveWaiting() {
    login leaveA leavea@test.com 0 leaveCode 2
    expectReply leaveA $'ACCEPTED\n#'
    hangUp leaveA
    expectLog "Failed to read from twin-waiting client socket"

    login leaveB leaveb@test.com 0 leaveCode 2
    expectReply leaveB $'ACCEPTED\n#'
    pause 3 "leaveA left, so leaveB alone must not complete the party"
    expectNoLog "New player leaveb@test.com"
    expectNoGameData leaveB

    login leaveC leavec@test.com 0 leaveCode 2
    expectLog "Found 2 other people waiting for twin party of leavec@test.com"
    expectNewLife leaveb@test.com
    expectNewLife leavec@test.com
    expectGameData leaveB
    expectGameData leaveC
    expectNoLog "New player leavea@test.com"
}

case_twinFamTarget() {
    login twinFamA "twinfama@test.com:noSuchFamily" 0 twinFamCode 2
    login twinFamB "twinfamb@test.com:noSuchFamily" 0 twinFamCode 2
    expectReply twinFamA $'ACCEPTED\n#'
    expectReply twinFamB $'ACCEPTED\n#'
    expectReplyHas twinFamA "REJECTED"
    expectReplyHas twinFamB "REJECTED"
    expectClosed twinFamA
    expectClosed twinFamB
    expectNoLog "New player twinfam"
}

# oldLifeParty case: A has a disconnected life, then A and B form a twin
# party; $2 = "last" or "first" says when A joins
oldLifeParty() {
    local c=$1 order=$2 a b id
    a="${c,,}a@test.com"
    b="${c,,}b@test.com"

    login "${c}Solo" "$a"
    expectNewLife "$a"
    expectGameData "${c}Solo"
    id="$( playerId "$a" )"
    hangUp "${c}Solo"
    waitDisconnected "$a"

    if [ "$order" = "last" ]; then
        login "${c}B" "$b" 0 "${c}Code" 2
        login "${c}A" "$a" 0 "${c}Code" 2
    else
        login "${c}A" "$a" 0 "${c}Code" 2
        login "${c}B" "$b" 0 "${c}Code" 2
    fi
    expectLog "Found 2 other people waiting for twin party of"
    expectGameData "${c}A"
    expectGameData "${c}B"
    expectNewLife "$b"
    expectLog "for player $id ($a) took"
    expectNoLog "Player $id ($a) has reconnected."
    local lives
    lives="$( logCount "New player $a connected as player" )"
    if [ "$lives" -eq 2 ]; then
        ok "$a got a new life besides player $id"
    else
        fail "$a lives" \
             "2 'New player $a' log lines (old player $id, then the twin)" \
             "$lives"
    fi
}

case_twinOldLifeFirst() {
    oldLifeParty oldFirst first
}

case_twinOldLifeConnected() {
    local a=oldconna@test.com b=oldconnb@test.com id
    login oldConnSolo "$a"
    expectNewLife "$a"
    expectGameData oldConnSolo
    id="$( playerId "$a" )"

    login oldConnB "$b" 0 oldConnCode 2
    login oldConnA "$a" 0 oldConnCode 2
    expectLog "Player $id ($a) marked as disconnected (Authentic reconnect received)"
    expectGameData oldConnA
    expectGameData oldConnB
    expectLog "for player $id ($a) took"
    expectNoLog "Player $id ($a) has reconnected."
    expectClosed oldConnSolo
}

case_twinDropReconnect() {
    twinParty dropp dropCode 2 2
    local id
    id="$( playerId dropp1@test.com )"
    hangUp dropp1
    waitDisconnected dropp1@test.com

    login dropAgain dropp1@test.com
    expectReply dropAgain $'ACCEPTED\n#'
    expectLog "Player $id (dropp1@test.com) has reconnected."
    expectGameData dropAgain
}

case_twinTutorial() {
    login twinTutA twintuta@test.com 1 twinTutCode 2
    login twinTutB twintutb@test.com 1 twinTutCode 2
    expectLog "Found 2 other people waiting for twin party of"
    expectLog "tutorial loaded after" 60
    expectLog "Twin twintutb@test.com tutorial loaded too" 60
    expectGameData twinTutA 60
    expectGameData twinTutB 60
}


# ---- cases with an existing family ----------------------------------------

# namedEve client email word: client logs in as an Eve (a seeded login,
# forceEveOnSeededSpawn is on) and says "I AM word"; sets EVE_ID to her
# player id and EVE_FAMILY to her family name, empty if she got no name
EVE_ID=""
EVE_FAMILY=""

namedEve() {
    local name=$1 email=$2 word=$3 nameLine
    login "$name" "$email"
    expectNewLife "${email%%|*}"
    expectGameData "$name"
    EVE_ID="$( playerId "${email%%|*}" )"
    # a SAY within minSayGapInSeconds (1s) of the spawn is ignored
    pause 2 "a new player can't talk in their first second"
    sendRaw "$name" "SAY 0 0 I AM $word#"

    # the NM message has a line "<id> <eveName> <family>"
    hasName() {
        grep -a -q -E "^$EVE_ID $EVE_NAME [^ ]+" "$RUN_DIR/client_$name.bin"
    }
    EVE_FAMILY=""
    if waitFor 15 hasName; then
        nameLine="$( grep -a -o -E "^$EVE_ID $EVE_NAME [^ ]+" \
                     "$RUN_DIR/client_$name.bin" | tail -1 )"
        EVE_FAMILY="${nameLine##* }"
        ok "$name is named '$EVE_NAME $EVE_FAMILY'"
    else
        fail "$name named" \
             "a name '$EVE_NAME <family>' for player $EVE_ID within 15s" \
             "$( clientState "$name" )"
    fi
}

# Eves spawn at 14 and are fertile at 15, one year is 60 seconds, but an
# idle player starves after about 90 seconds (sooner in a cold spot of the
# random map).  So these Eves spawn at 14.9 (forceEveAge, which the
# server reads again for every Eve) and are fertile 6 seconds later.  The
# first case that needs a family spawns all three Eves, so there is only
# one wait.  Case name -> family name, and player id of its Eve.
declare -A FAMILY
declare -A FAMILY_EVE
FAMILIES_BORN=0

fertileFamily() {
    local c
    if [ "$FAMILIES_BORN" -eq 0 ]; then
        say "  (spawning a named Eve, age 14.9, for each famTarget case)"
        local ageFile="$RUN_DIR/settings/forceEveAge.ini" oldAge
        oldAge="$( cat "$ageFile" )"
        echo 14.9 > "$ageFile"
        for c in famTargetExisting famTargetOnly twinFamTargetExisting; do
            namedEve "${c}Eve" "${c,,}eve@test.com|${c}Seed" "${c^^}"
            FAMILY[$c]=$EVE_FAMILY
            FAMILY_EVE[$c]=$EVE_ID
        done
        echo "$oldAge" > "$ageFile"
        FAMILIES_BORN=$SECONDS
    fi
    local left=$(( FAMILIES_BORN + 8 - SECONDS ))
    [ "$left" -gt 0 ] && pause "$left" "the Eves become fertile"
    [ -n "${FAMILY[$CASE]}" ] ||
        fail_setup "$CASE: its Eve has no family name"
}

# expectMother email: the life log has a birth of email to the Eve of
# this case
expectMother() {
    local eve=${FAMILY_EVE[$CASE]}
    bornTo() {
        cat "$RUN_DIR"/lifeLog/*.txt 2> /dev/null |
            grep -a -q -E "^B [0-9]+ [0-9]+ $1 .* parent=$eve,"
    }
    if waitFor 15 bornTo "$1"; then
        ok "lifeLog: $1 born to player $eve (family ${FAMILY[$CASE]})"
    else
        fail "lifeLog: $1 mother" \
             "a birth line for $1 with parent=$eve within 15s" \
             "$( cat "$RUN_DIR"/lifeLog/*.txt 2> /dev/null |
                 grep -a -F " $1 " | tail -1 | cut -c 1-100 )"
    fi
}

case_eveName() {
    namedEve eveNameEve "evenameeve@test.com|eveNameSeed" SOMENAME
}

case_famTargetExisting() {
    fertileFamily
    login famKid "famkid@test.com:${FAMILY[$CASE],,}"
    expectReply famKid $'ACCEPTED\n#'
    expectNewLife famkid@test.com
    expectGameData famKid
    expectMother famkid@test.com
    expectNoLog "Target family is not found"
}

# blank_email is one account for every login without an email: if the
# seedOnly life is still alive, this login reconnects to it
case_famTargetOnly() {
    fertileFamily
    login famOnly ":${FAMILY[$CASE]}"
    expectReply famOnly $'ACCEPTED\n#'
    bornOrReconnected() {
        logHas "New player blank_email connected as player" ||
            logHas "(blank_email) has reconnected."
    }
    if waitFor 15 bornOrReconnected; then
        ok "log: blank_email born or reconnected"
    else
        fail "log: blank_email" \
             "'New player blank_email' or '(blank_email) has reconnected'" \
             "neither; last log lines of this case:"
        lastLogLines 5
    fi
    expectGameData famOnly
    logHas "New player blank_email" && expectMother blank_email
    expectNoLog "Target family is not found"
}

case_twinFamTargetExisting() {
    fertileFamily
    local fam="${FAMILY[$CASE]}"
    login twinFamExA "twinfamexa@test.com:$fam" 0 twinFamExCode 2
    login twinFamExB "twinfamexb@test.com:$fam" 0 twinFamExCode 2
    expectLog "Found 2 other people waiting for twin party of"
    expectNewLife twinfamexa@test.com
    expectNewLife twinfamexb@test.com
    expectGameData twinFamExA
    expectGameData twinFamExB
    expectMother twinfamexa@test.com
    expectMother twinfamexb@test.com
    expectNoLog "Target family is not found"
}


# shown when a case starts, same as the list at the top
declare -A CASE_DESC=(
    [solo]="LOGIN -> new life, game data"
    [rlogin]="RLOGIN -> handled like LOGIN"
    [tutorial]="LOGIN, tutorial 1 -> tutorial loaded, game data"
    [emailCase]="LOGIN MiXeD@... -> email lowercased"
    [seed]="LOGIN email|seed -> seeded Eve, seed cut from email"
    [seedOnly]="LOGIN |seed -> email becomes blank_email"
    [famTargetUnknown]="LOGIN email:family, no such family -> ACCEPTED, then REJECTED"
    [badFormat]="LOGIN with 3 or 6 fields -> REJECTED"
    [notLogin]="first message not LOGIN -> closed, no REJECTED"
    [garbage]="no # terminator, not LOGIN -> closed, no REJECTED"
    [loginTimeout]="nothing sent -> REJECTED after 10 seconds"
    [playerList]="PLAYER_LIST secret -> player list, closed after 10 seconds"
    [playerListBadSecret]="PLAYER_LIST wrong -> REJECTED"
    [reconnect]="disconnect, LOGIN again -> same life"
    [reconnectConnected]="LOGIN again while connected -> same life, old connection closed"
    [twin2]="twin party of 2 -> all spawn"
    [twin3]="twin party of 3 -> all spawn"
    [twin4]="twin party of 4 -> all spawn"
    [twinCountClamped]="twin count 5 -> treated as maxTwinPartySize (4)"
    [twinCountMismatch]="same twin code, different counts -> no party"
    [twinLeaveWaiting]="a twin leaves while waiting -> party needs someone else"
    [twinFamTarget]="twin party with unknown family -> all REJECTED"
    [twinOldLifeFirst]="first twin to join has a disconnected life -> old life killed, party spawns"
    [twinOldLifeConnected]="twin still connected to an old life -> party spawns, old connection closed"
    [twinDropReconnect]="spawned twin drops, LOGIN without twin code -> same twin life"
    [twinTutorial]="twin party in the tutorial -> both tutorials load"
    [eveName]="Eve says \"I AM name\" -> named after the eveName setting"
    [famTargetExisting]="LOGIN email:family, family has a fertile Eve -> born into it"
    [famTargetOnly]="LOGIN :family -> email becomes blank_email, born into the family"
    [twinFamTargetExisting]="twin party with email:family -> all born into it"
)

for c in $CASES; do
    declare -F "case_$c" > /dev/null || fail_setup "no function for case: $c"
done



# ---- run ------------------------------------------------------------------

# startCase name description
startCase() {
    CASE=$1
    CASE_FAILED=0
    CASE_OUT=""
    LOG_LINES_SHOWN=0
    CASE_START=$SECONDS
    if [ "$VERBOSE" = "1" ]; then
        echo
        echo "== $1: $2"
    else
        # the result goes on the same line when the case ends
        printf "%-22s" "$1"
    fi
}

# endCase description
endCase() {
    local result=PASS
    if [ "$CASE_FAILED" -eq 1 ]; then
        result=FAIL
        FAILED_CASES="$FAILED_CASES $CASE"
    fi
    if [ "$VERBOSE" = "1" ]; then
        echo "== $CASE: $result ($(( SECONDS - CASE_START ))s)"
    else
        echo "$result ($(( SECONDS - CASE_START ))s)"
        if [ "$CASE_FAILED" -eq 1 ]; then
            echo "  case: $1"
            printf "%s" "$CASE_OUT"
        fi
    fi
    CASE=""
    CASE_OUT=""
}

sleep 2
[ "$VERBOSE" = "1" ] || echo

for c in $CASES; do
    startCase "$c" "${CASE_DESC[$c]}"
    CASE_LOG_START="$( wc -l < "$RUN_DIR/log.txt" )"
    "case_$c"
    endCase "${CASE_DESC[$c]}"
done



# ---- final checks ---------------------------------------------------------

FINAL_DESC="all clients closed -> server running, idle, no CLOSE-WAIT"
startCase final "$FINAL_DESC"
for name in "${!CLIENT_FD[@]}"; do
    closeClient "$name"
done
pause 3 "server notices the closed clients"

if ! kill -0 "$SERVER_PID" 2> /dev/null; then
    fail "server running" "server still running" "server has exited"
    say "$( tail -20 "$RUN_DIR/log.txt" "$RUN_DIR/serverOut.txt" 2> /dev/null )"
else
    ok "server still running"

    # server CPU time used so far, in clock ticks (utime + stime)
    cpuTicks() {
        sed 's/.*) //' "/proc/$SERVER_PID/stat" | awk '{ print $12 + $13 }'
    }
    say "  (measuring server CPU for ${CPU_SAMPLE}s)"
    hz="$( getconf CLK_TCK )"
    c0="$( cpuTicks )"; t0="$( date +%s.%N )"
    sleep "$CPU_SAMPLE"
    c1="$( cpuTicks )"; t1="$( date +%s.%N )"
    cpu="$( awk -v c0="$c0" -v c1="$c1" -v t0="$t0" -v t1="$t1" -v hz="$hz" \
            'BEGIN { printf "%.1f", 100 * ( c1 - c0 ) / hz / ( t1 - t0 ) }' )"
    if awk -v c="$cpu" -v t="$CPU_THRESHOLD" 'BEGIN { exit !( c >= t ) }'
    then
        fail "server CPU" \
             "below $CPU_THRESHOLD% of one core with no clients" \
             "$cpu% (busy loop, e.g. a closed socket still in sockPoll)"
    else
        ok "server CPU $cpu% of one core (below $CPU_THRESHOLD%)"
    fi

    closeWait="$( ss -Htn state close-wait "sport = :$PORT" | wc -l )"
    if [ "$closeWait" -eq 0 ]; then
        ok "no server sockets in CLOSE-WAIT"
    else
        fail "CLOSE-WAIT sockets" \
             "0 server sockets in CLOSE-WAIT (every closed client released)" \
             "$closeWait socket(s) the server never closed"
    fi
fi
endCase "$FINAL_DESC"



# ---- leaks: shutdown and valgrind report ----------------------------------

# With connections still waiting, the server is stopped cleanly, so that
# valgrind can tell memory the server forgot to free from memory still
# in use.  Every "definitely lost" block in the valgrind log fails.
# Invalid memory use (invalid read/write/free, mismatched free) is only
# shown as a warning: master already has such bugs outside the login
# code (see the known server bugs list).

# valgrindRecords regex: valgrind log records whose first line matches
# regex, as that line and a "fn (file:line)" stack, then a last line
# "<records> <bytes definitely lost>"
valgrindRecords() {
    awk -v re="$1" '
        { sub( /^==[0-9]+== ?/, "" ) }

        $0 ~ re {
            inRecord = 1
            records++
            if( / are definitely lost / ) {
                bytes += $1
                }
            print "  " $0
            next
            }

        inRecord && /^ *(at|by) 0x/ {
            sub( /^ *(at|by) 0x[0-9A-Fa-f]+: /, "" )
            print "      " $0
            next
            }

        inRecord {
            inRecord = 0
            print ""
            }

        END { printf "%d %d\n", records, bytes }
        ' "$VG_LOG"
}

INVALID_REPORT=""
INVALID_RECORDS=0

if [ "$MODE" = "leaks" ]; then
    LEAKS_DESC="connections waiting, server stopped -> no definitely lost memory"
    startCase leaks "$LEAKS_DESC"

    # a twin with a famTarget waiting for its party, a login waiting for
    # its message
    login pendingTwin "pendingtwin@test.com:pendingFamily" 0 pendingCode 2
    expectReply pendingTwin $'ACCEPTED\n#'
    openClient pendingLogin

    say "  server gets SIGTSTP, its clean quit signal"
    kill -TSTP "$SERVER_PID"
    serverGone() {
        ! kill -0 "$SERVER_PID" 2> /dev/null
    }
    if waitFor 300 serverGone; then
        ok "server quit"
    else
        fail "server quit" "server quits within 300s of SIGTSTP" \
             "still running"
    fi
    wait "$SERVER_PID" 2> /dev/null
    SERVER_PID=""

    if ! grep -q "HEAP SUMMARY" "$VG_LOG" 2> /dev/null; then
        fail "valgrind report" "a leak report in $VG_LOG" \
             "no HEAP SUMMARY (server did not quit cleanly?)"
    else
        report="$( valgrindRecords " are definitely lost in loss record " )"
        read -r records bytes <<< "$( echo "$report" | tail -n 1 )"
        if [ "$records" -eq 0 ]; then
            ok "valgrind: no definitely lost blocks"
        else
            fail "valgrind" "no definitely lost blocks" \
                 "$records leak record(s), $bytes bytes definitely lost:"
            say "$( echo "$report" | sed '$d' )"
        fi

        INVALID_REPORT="$( valgrindRecords \
                           "^(Invalid (read|write|free)|Mismatched free)" )"
        read -r INVALID_RECORDS bytes <<< \
            "$( echo "$INVALID_REPORT" | tail -n 1 )"
    fi
    endCase "$LEAKS_DESC"

    # shown whether the leak check passed or not
    if [ "$INVALID_RECORDS" -gt 0 ]; then
        echo
        echo "WARNING: valgrind found $INVALID_RECORDS invalid memory" \
             "use record(s) (not counted as a failure):"
        echo
        echo "$INVALID_REPORT" | sed '$d'
    fi
fi



# ---- result ---------------------------------------------------------------

# final checks, and leak checks
NUM_EXTRA=1
[ "$MODE" = "leaks" ] && NUM_EXTRA=2

echo
if [ -n "$FAILED_CASES" ]; then
    echo "FAIL: $( echo $FAILED_CASES | wc -w ) of" \
         "$(( $( echo $CASES | wc -w ) + NUM_EXTRA ))" \
         "cases failed (counting final and leak checks):$FAILED_CASES"
    # without VERBOSE each failed case already showed its failed checks
    [ "$VERBOSE" = "1" ] && echo "Failed checks:$FAILURES"
    if [ "${KEEP_RUN_DIR:-0}" != "1" ]; then
        echo "Rerun with KEEP_RUN_DIR=1 to keep the server log," \
             "or name cases after $MODE to run only some."
    fi
    finish 1
fi

if [ "$MODE" = "leaks" ]; then
    echo "PASS: $( echo $CASES | wc -w ) cases, final and leak checks"
else
    echo "PASS: $( echo $CASES | wc -w ) cases and final checks"
fi
finish 0
