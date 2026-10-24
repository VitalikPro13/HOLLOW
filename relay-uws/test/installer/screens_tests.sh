#!/bin/bash
# Tests for how the setup's screens look and what they name: one steady
# whiptail frame at every terminal size, long text scrolling inside it,
# command screens and inputs in plain text, and the app's screens named the
# way the app names them. Sourced by run_tests.sh, whose helpers they use.
# shellcheck disable=SC2034,SC2317,SC2016,SC2030,SC2031,SC2154

echo "one steady frame"
# A whiptail that records each call's arguments, one per line, and answers
# the first menu item.
wt_fake() { # <dir> <log>
    mkdir -p "$1"
    cat >"$1/whiptail" <<EOF
#!/bin/bash
{ printf '%s\n' "\$@"; echo ---; } >>"$2"
for a; do case "\$a" in --menu) echo a >&2 ;; --inputbox|--passwordbox) echo typed >&2 ;; esac; done
exit 0
EOF
    chmod +x "$1/whiptail"
}
LONG=$(for i in $(seq 1 40); do echo "line $i of a long text that goes on for a while"; done)
t_steady_frame() {
    local F=$TMP/wt_frame log=$TMP/wt_frame.log
    wt_fake "$F" "$log"
    PATH="$F:$PATH"
    clear() { :; }
    ui_remember() { :; }
    TC=80 TR=24
    tput() { case "$1" in cols) echo "$TC" ;; lines) echo "$TR" ;; esac; }
    ui_size "short" 7
    eq "80x24: the frame is the terminal less a margin" "$UI_W $UI_H $UI_FITS" "76 22 1"
    ui_size "$LONG" 7
    eq "80x24: a long text keeps the same frame" "$UI_W $UI_H $UI_FITS" "76 22 0"
    TC=160 TR=48
    ui_size "short" 7
    eq "160x48: width and height stop at their caps" "$UI_W $UI_H" "100 30"
    TC=100 TR=30
    ui_size "short" 7
    eq "100x30: the frame follows the terminal" "$UI_W $UI_H" "96 28"
    TC=60 TR=14
    ui_size "short" 7
    eq "a small terminal still gets a frame" "$UI_W $UI_H" "56 12"
    TC=80 TR=24
    UI_MODE=whiptail
    : >"$log"
    ui_msg "Short" "A short text."
    eq "a short message sits in the steady frame" "$(sed -n '/^--msgbox$/,/^---$/p' "$log" | tail -n 3 | head -n 2 | tr '\n' ' ')" "22 76 "
    lacks "and does not scroll" "$(cat "$log")" "--scrolltext"
    lacks "nor tells how to" "$(cat "$log")" "Scroll with the arrow keys"
    : >"$log"
    ui_msg "Long" "$LONG"
    has "a long message scrolls inside the box" "$(cat "$log")" "--scrolltext"
    has "and says how to reach the button" "$(cat "$log")" "Scroll with the arrow keys, then press Tab to reach the button."
    has "in the same frame" "$(tr '\n' ' ' <"$log")" " 22 76 ---"
    : >"$log"
    ui_yesno confirm "Long" "$LONG" yes
    has "a long question scrolls" "$(cat "$log")" "--scrolltext"
    has "and names the buttons" "$(cat "$log")" "to reach the Yes and No buttons."
    : >"$log"
    ui_yesno confirm "Short" "Go on?" no
    lacks "a short question does not" "$(cat "$log")" "--scrolltext"
    has "and keeps its default" "$(cat "$log")" "--defaultno"
    : >"$log"
    ui_menu action "Long" "$LONG" a a "First" b "Second"
    has "a long menu text scrolls" "$(cat "$log")" "--scrolltext"
    has "and names the choices" "$(cat "$log")" "to reach the choices."
    eq "the menu answers" "$UI_REPLY" a
    : >"$log"
    local many=() i
    for i in $(seq 1 14); do many+=("i$i" "item$i"); done
    ui_menu action "Many" "Pick one." a "${many[@]}"
    eq "a long list scrolls in a frame that keeps room for the text" "$(sed -n '/^--menu$/,/^---$/p' "$log" | grep -A1 -x 76 | tail -n 1)" 10
    : >"$log"
    (UI_TTY=/dev/null ui_input name "Long" "$LONG" "x") </dev/null >/dev/null 2>&1
    eq "a long text above a field is asked in plain text, never with a field that loses the focus" "$(cat "$log")" ""
    : >"$log"
    ui_input name "Short" "Your name?" "x"
    has "a short one gets the box" "$(cat "$log")" "--inputbox"
    lacks "without scrolling" "$(cat "$log")" "--scrolltext"
    : >"$log"
    (UI_TTY=/dev/null ui_secret token "Long" "$LONG") </dev/null >/dev/null 2>&1
    eq "a long text above a hidden field too" "$(cat "$log")" ""
    : >"$log"
    out=$(UI_TTY=/dev/null ui_msg_copy "Make a key" "  ssh-keygen -t ed25519")
    eq "a screen of commands to copy never draws a box" "$(cat "$log")" ""
    has "and shows them as plain text" "$out" "  ssh-keygen -t ed25519"
    UI_MODE=plain
    out=$(UI_TTY=/dev/null ui_msg "Long" "$LONG")
    lacks "plain text never tells about scrolling" "$out" "Scroll with the arrow keys"
    UI_MODE=answers
    out=$(ui_msg "Long" "$LONG")
    lacks "nor does an answer file run" "$out" "Scroll with the arrow keys"
}
in_sub t_steady_frame
copy_screens=$(grep -hE 'ui_msg[a-z_]* "(Make a key on your computer|Add another computer.s key|Log in with your key)"' "$DEPLOY/lib/ssh_keys.sh")
eq "every command-copy screen is plain text" "$(printf '%s\n' "$copy_screens" | grep -c 'ui_msg_copy ')" 5
lacks "and none draws a box" "$copy_screens" 'ui_msg "'

echo "the app's screens, named as the app names them"
load_fn "$RELAY/install.sh" summary_running
summary=$(CFG_HOST=relay.example.org CFG_TURN=yes CFG_PUSH=yes CFG_FORWARDER=yes CFG_MEMBERS_ONLY=no summary_running)
has "the summary names the relay screen's path" "$summary" "Settings > Network, press Change next to the relay, then Add a relay"
has "and the buttons after it" "$summary" "press Add, then Switch and restart (Switch and close on a phone)"
has "and the welcome screen's relay button" "$summary" "the button at the bottom that shows relay.anonlisten.com"
has "and the field it opens" "$summary" "Relay address"
push=$(sed -n '/^ask_push()/,/^}/p' "$DEPLOY/lib/questions.sh")
has "push names the app's section" "$push" "Settings > Notifications > Push delivery"
has "and its row" "$push" "Wake-up service"
keys=$(sed -n '/^manage_keys_text()/,/^}/p' "$DEPLOY/lib/manage.sh")
has "members-only keys name the app's prompt" "$keys" "This relay needs an access key"
all=$(cat "$RELAY/install.sh" "$DEPLOY"/lib/*.sh)
lacks "no Push Delivery in title case" "$all" "Push Delivery"
lacks "no Add relay without its article" "$all" "Network > Add relay"
lacks "no Advanced field" "$all" "Advanced field"
# The app's own words, read from its sources, so a rename there turns this red.
if [ -d "$REPO/lib/src/ui" ]; then
    app=$(cat "$REPO/lib/src/ui/settings/network_section.dart" "$REPO/lib/src/ui/dialogs/welcome_dialog.dart" \
        "$REPO/lib/src/ui/settings/notification_settings_section.dart" "$REPO/lib/src/ui/dialogs/license_key_dialog.dart" \
        "$REPO/lib/src/ui/settings/settings_catalog.dart" "$REPO/lib/src/core/providers/relay_domain_provider.dart" 2>/dev/null)
    for w in "'Add a relay'" "'Switch and restart'" "'Switch and close'" "'Change'" "child: const Text('Add')" "'Relay address'" \
        "'Push delivery'" "'Wake-up service'" "'This relay needs an access key'" "SettingsCategory.network => 'Network'" \
        "SettingsCategory.notifications => 'Notifications'" "kDefaultRelayDomain = 'relay.anonlisten.com'"; do
        has "the app still says $w" "$app" "$w"
    done
else
    echo "  (the app's sources are not here; the names are checked against them in a full checkout)"
fi

echo "commands stay one line"
t_commands_unfolded() {
    local long="  type \$env:USERPROFILE\\.ssh\\id_ed25519.pub | ssh someone@a-rather-long-relay-name.duckdns.org \"mkdir -p ~/.ssh && chmod 700 ~/.ssh\""
    out=$(plain_header "Make a key" "Run this on your own computer, the one you use to log in here, and not on this machine, please.
$long")
    has "a command is printed whole, for one copy" "$out" "$long"
    has "and prose still folds" "$out" "Run this on your own computer, the one you use to log in here, and not on"
}
in_sub t_commands_unfolded
