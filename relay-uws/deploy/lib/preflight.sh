#!/bin/bash
# Can this machine host a relay? Reads only, changes nothing. Sourced.

# ip4_class <address>: public, private, cgnat, loopback, linklocal or invalid.
ip4_class() {
    local a=$1 o1 o2 o3 o4 rest
    [[ "$a" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { echo invalid; return; }
    IFS=. read -r o1 o2 o3 o4 rest <<<"$a"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ "$((10#$o))" -le 255 ] || { echo invalid; return; }
    done
    o1=$((10#$o1)); o2=$((10#$o2))
    if [ "$o1" = 10 ] || { [ "$o1" = 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; } ||
       { [ "$o1" = 192 ] && [ "$o2" = 168 ]; }; then
        echo private
    elif [ "$o1" = 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; then
        echo cgnat
    elif [ "$o1" = 127 ]; then
        echo loopback
    elif [ "$o1" = 169 ] && [ "$o2" = 254 ]; then
        echo linklocal
    elif [ "$o1" = 0 ] || [ "$o1" -ge 224 ]; then
        echo invalid
    else
        echo public
    fi
}

# ip6_class <address>: global, ula, linklocal, loopback or invalid. Only the
# leading group is read, which is all the classes need.
ip6_class() {
    local a=${1,,} g
    if [[ "$a" != *:* ]] || ! [[ "$a" =~ ^[0-9a-f:]+$ ]]; then echo invalid; return; fi
    [ "$a" = ::1 ] && { echo loopback; return; }
    g=${a%%:*}
    [ -z "$g" ] && { echo invalid; return; }
    g=$((16#$g))
    if [ "$g" -ge $((16#fe80)) ] && [ "$g" -le $((16#febf)) ]; then echo linklocal
    elif [ "$g" -ge $((16#fc00)) ] && [ "$g" -le $((16#fdff)) ]; then echo ula
    elif [ "$g" -ge $((16#2000)) ] && [ "$g" -le $((16#3fff)) ]; then echo global
    else echo invalid
    fi
}

# os_supported <id> <version_id>: Ubuntu 22.04 or newer, Debian 12 or newer.
os_supported() {
    local id=$1 ver=$2 major minor
    major=${ver%%.*}; minor=${ver#*.}; [ "$minor" = "$ver" ] && minor=0
    [[ "$major" =~ ^[0-9]+$ ]] && [[ "$minor" =~ ^[0-9]+$ ]] || return 1
    case "$id" in
    ubuntu) [ "$major" -gt 22 ] || { [ "$major" = 22 ] && [ "$((10#$minor))" -ge 4 ]; } ;;
    debian) [ "$major" -ge 12 ] ;;
    *) return 1 ;;
    esac
}

arch_supported() {
    case "$1" in x86_64|aarch64) return 0 ;; *) return 1 ;; esac
}

# The address this machine sends from on its default route.
local_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1 || true
}

local_ipv6() {
    ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/temporary|deprecated|tentative/ {print $2}' |
        cut -d/ -f1 | head -n 1 || true
}

# What the internet sees. Two services, so one being down does not decide.
public_ipv4() {
    local u a
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        a=$(net_get -4 "$u" 6 | tr -d '[:space:]') || continue
        [ "$(ip4_class "$a")" = public ] && { printf '%s' "$a"; return 0; }
    done
    return 1
}

public_ipv6() {
    local u a
    for u in https://api6.ipify.org https://ipv6.icanhazip.com; do
        a=$(net_get -6 "$u" 6 | tr -d '[:space:]') || continue
        [ "$(ip6_class "$a")" = global ] && { printf '%s' "$a"; return 0; }
    done
    return 1
}

# The program listening on a TCP port, empty when it is free.
port_owner() {
    ss -Hltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1 || true
}

port_busy() {
    [ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]
}

clock_synced() {
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]
}

mem_mb() { awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo; }
disk_free_mb() { df -Pm "${1:-/}" | awk 'NR == 2 {print $4}'; }

# Sets PF_VERDICT (ok, steps or no), PF_HEAD (the verdict and what needs doing),
# PF_FOUND (what was found, one line each), PF_TEXT (both, for one screen),
# PF_PUBLIC_IP, PF_LOCAL_IP, PF_BEHIND_NAT and PF_PUBLIC_IPV6. Each screen fits
# an 80x24 terminal for the usual results.
preflight_run() {
    local id="" ver="" pretty="" arch mem cpus virt lines=() steps=() stops=() sys_ok=1
    PF_VERDICT=ok PF_PUBLIC_IP="" PF_LOCAL_IP="" PF_BEHIND_NAT=0 PF_PUBLIC_IPV6=""
    if [ -r /etc/os-release ]; then
        id=$(kv_get /etc/os-release ID)
        ver=$(kv_get /etc/os-release VERSION_ID)
        pretty=$(kv_get /etc/os-release PRETTY_NAME)
    fi
    arch=$(uname -m)
    if ! os_supported "$id" "$ver"; then
        sys_ok=0
        stops+=("This is ${pretty:-an unknown system}. The setup supports Ubuntu 22.04 or newer and Debian 12 or newer.")
    fi
    if ! arch_supported "$arch"; then
        sys_ok=0
        stops+=("The processor is $arch. The relay runs on x86_64 and aarch64 (ARM64) only.")
    fi
    [ "$sys_ok" = 1 ] && lines+=("System: $pretty on $arch, which is supported.")
    virt=$(systemd-detect-virt 2>/dev/null || true)
    case "$virt" in
    openvz)
        stops+=("This is an OpenVZ container, whose kernel cannot run the relay's sandbox. Ask your provider for a KVM VPS.") ;;
    lxc|lxc-libvirt)
        steps+=("This is an LXC container. Some sandbox settings may not work in it, and the final check says which.") ;;
    esac

    mem=$(mem_mb); cpus=$(nproc)
    if [ "$mem" -lt 450 ]; then
        stops+=("The machine has ${mem} MB of memory. The system and certbot need at least 512 MB.")
    elif [ "$mem" -lt 1800 ]; then
        lines+=("Memory: ${mem} MB, ${cpus} CPU. Plenty for the relay, though a build from source would be slow.")
    else
        lines+=("Memory: ${mem} MB, ${cpus} CPU. Plenty.")
    fi

    local disk vgfree
    disk=$(disk_free_mb /)
    vgfree=$(vgs --noheadings --units m -o vg_free 2>/dev/null | awk '{s += $1} END {print int(s)}' || true)
    if [ "${vgfree:-0}" -gt 2048 ] && [ "$disk" -lt 8192 ]; then
        lines+=("Disk: $((disk / 1024)) GB free, and $((vgfree / 1024)) GB more that Ubuntu's installer left unused. Only a build from source might need it, and sudo lvextend -r -l +100%FREE $(findmnt -no SOURCE /) adds it.")
    else
        lines+=("Disk: $((disk / 1024)) GB free.")
    fi

    PF_LOCAL_IP=$(local_ipv4)
    PF_PUBLIC_IP=$(public_ipv4 || true)
    PF_PUBLIC_IPV6=$(public_ipv6 || true)
    local lclass
    lclass=$(ip4_class "${PF_LOCAL_IP:-none}")
    if ! net_tool >/dev/null; then
        stops+=("This machine has none of curl, wget or python3, so I cannot ask the internet for its public address. Install one first, for example with: sudo apt install curl")
    elif [ -z "$PF_PUBLIC_IP" ]; then
        stops+=("I could not reach the internet over IPv4. A relay needs a public IPv4, and the setup needs the internet for its downloads.")
    elif [ "$lclass" = public ] && [ "$PF_LOCAL_IP" = "$PF_PUBLIC_IP" ]; then
        lines+=("Public address: $PF_PUBLIC_IP, this machine's own.")
    elif [ "$lclass" = public ]; then
        lines+=("Public address: the internet sees $PF_PUBLIC_IP, and this machine has $PF_LOCAL_IP. If people should use $PF_LOCAL_IP, give it when the setup asks.")
    elif [ "$lclass" = cgnat ]; then
        PF_BEHIND_NAT=1
        stops+=("This machine's address, $PF_LOCAL_IP, is in the range for carrier-grade NAT, where many customers share one public address and nobody outside can reach you. A small VPS for 3 to 5 euros a month works instead.")
    elif [ "$lclass" = private ]; then
        PF_BEHIND_NAT=1
        lines+=("Public address: $PF_PUBLIC_IP, reached through a router or the provider's network.")
        steps+=("This machine's own address, $PF_LOCAL_IP, is private. The internet sees $PF_PUBLIC_IP.
- On a cloud server (AWS, Google Cloud, Oracle) that is normal. Open the ports in the provider's firewall. The list comes at the end.
- At home, forward those ports on your router to $PF_LOCAL_IP.
- If your router's status page shows a WAN address other than $PF_PUBLIC_IP, your provider uses carrier-grade NAT and forwarding cannot work. You would need a VPS.")
    else
        stops+=("I could not tell which address this machine uses to reach the internet.")
    fi
    if [ -n "$PF_PUBLIC_IPV6" ]; then
        lines+=("IPv6: $PF_PUBLIC_IPV6, which calls through TURN can use too.")
    fi

    local owner p80="free" p443="free"
    if port_busy 443; then
        owner=$(port_owner 443)
        case "$owner" in
        hollow-relay|docker-proxy) p443="the Hollow relay already here" ;;
        *) p443="in use by ${owner:-another program}"
            steps+=("Port 443 is in use by ${owner:-another program}, and the relay needs it. Stop that program, or use a machine where 443 is free.") ;;
        esac
    fi
    if port_busy 80; then
        owner=$(port_owner 80)
        p80="in use by ${owner:-another program}, which matters only for a bare IP address or your own domain"
    fi
    if [ "$p443" = free ] && [ "$p80" = free ]; then
        lines+=("Ports 443 and 80: free.")
    else
        lines+=("Port 443: $p443." "Port 80: $p80.")
    fi
    if clock_synced; then
        lines+=("Clock: synchronised.")
    else
        steps+=("The clock is not synchronised yet, and logins to the relay must be within 60 seconds. The setup turns synchronisation on.")
    fi

    PF_FOUND=$(printf '%s\n' "${lines[@]}")
    if [ ${#stops[@]} -gt 0 ]; then
        PF_VERDICT=no
        PF_HEAD="A relay cannot work on this machine:

$(printf '%s\n\n' "${stops[@]}")"
    elif [ ${#steps[@]} -gt 0 ]; then
        PF_VERDICT=steps
        PF_HEAD="A relay works here, with a step or two from you:

$(printf '%s\n\n' "${steps[@]}")"
    else
        PF_HEAD="A relay works on this machine."
    fi
    PF_TEXT="$PF_HEAD

What I found:
$PF_FOUND"
}
