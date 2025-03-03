#!/bin/sh

###
### Log helpers
###

_NORMAL="$(printf "\033[0m")"
_RED="$(printf "\033[0;31m")"
_YELLOW="$(printf "\033[0;33m")"
_CYAN="$(printf "\033[0;36m")"

# Set COLOUR is stdout is tty by default
if [ -t 1 ]; then
    COLOUR="${COLOUR:-1}"
else
    COLOUR=
fi

fatal() {
    local _msg="$@"
    printf '%s' "${COLOUR:+${_RED}}" >&2
    printf '%s %s\n' "$(date '+%b %d %T')" "FATAL: $_msg" >&2
    printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    exit 1
}

info() {
    local _msg="$@"
    printf '%s' "${COLOUR:+${_YELLOW}}" >&2
    printf '%s %s\n' "$(date '+%b %d %T')" "INFO: $_msg" >&2
    printf '%s' "${COLOUR:+${_NORMAL}}" >&2
}


debug() {
    if [ -n "$DEBUG" ]
    then
        local _msg="$@"
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s %s\n' "$(date '+%b %d %T')" "DEBUG: $_msg" >&2
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    fi
}

###
### Utilities
###

check_path() { # [-drwx] <file>
    set -- $(getopt drwx $@)
    # Hack to get file before evaluating args 
    # so that we can just process inline 
    local _nr="$#"
    eval local _name="\$$#"
    if [ -z "${_name}" ]
    then
        fatal "Usage: check_path -drwx <path>"
    fi

    while [ $# -ne 0 ]
    do
        case "$1" in
            -d) if ! [ -d "${_name}" ]
                then
                    fatal "Directory not found: $_name"
                fi
                shift;;
            -r) if ! [ -r "${_name}" ]
                then
                    fatal "Path not readable: $_name"
                fi
                shift;;
            -w) if ! [ -w "${_name}" ]
                then
                    fatal "Path not writeable: $_name"
                fi
                shift;;
            -x) if ! [ -d "${_name}" ]
                then
                    fatal "Path not executable: $_name"
                fi
                shift;;
            --) shift; break;;
        esac
    done

}

# Increment counter from file
increment_counter() { # <file> [<min>] [<max>]
    local _file="${1:-}"
    local _min="${2:-0}"
    local _max="${3:-4294967296}"
    if [ -z "${_file}" ]
    then
        fatal "Usage: increment_counter <file> [<min>] [<max>] "
    fi

    # We dont have lockf or equivalent on OpenBSD so use lock simple file 
    if [ -f "${_file}.lock" ] && kill -0 $(cat "${_file}.lock") 2>/dev/null ; then
        fatal "${_file} Locked [PID: $(cat ${_file}.lock)]"
    else
        printf '%d' $$ > "${_file}.lock"
        local _next=$(( $(cat "${_file}" 2>/dev/null || echo 0) + 1 ))
        if [ $_next -lt $_min ]
        then
            _next=$_min
        fi
        if [ $_next -gt $_max ]
        then
            rm "${_file}.lock"
            fatal "Counter greater than max [$_next/$_max]"
        fi
        echo $_next | tee "${_file}"
        rm "${_file}.lock"
    fi
}

# Set counter (only set forwards)
set_counter() { # <file> <value> 
    local _file="${1:-}"
    local _value="${2:-}"
    if [ -z "${_file}" ]
    then
        fatal "Usage: set_counter <file> <value>"
    fi

    # We dont have lockf or equivalent on OpenBSD so use lock simple file 
    if [ -f "${_file}.lock" ] && kill -0 $(cat "${_file}.lock")  2>/dev/null; then
        fatal "${_file} Locked [PID: $(cat "${_file}.lock")]"
    else
        printf '%d' $$ > "${_file}.lock"
        local _current=$(cat "${_file}" 2>/dev/null || echo 0) 
        if [ ${_value} -gt ${_current} ]; then
            echo ${_value} | tee "${_file}"
            rm "${_file}.lock"
        else
            rm "${_file}.lock"
            fatal "Cant set counter [${_value}]"
        fi
    fi
}

get_default_ipv4() {
    route get -inet default | awk '/if address:/ { print $NF }'
}

get_default_ipv6() {
    # Get interface and find address in case default address is link-local
    local _if=$(route get -inet6 default | awk '/interface:/ { print $NF }')
    ifconfig igc0 inet6 | awk '/inet6/ && substr($2,0,4) != "fe80" { print $2; exit }'
}

get_ipv4_template() { # <interface>
    # Assume /24 based on base address of interface (set IPV4_TEMPLATE if not)
    local _if="${1:-}"
    if [ -z "${_if}" ]
    then
        fatal "Usage: get_ipv4_template <interface>"
    fi
    ifconfig $_if inet | awk '/inet/ { split($2,a,".");printf("%d.%d.%d.%%d/32\n",a[1],a[2],a[3]); exit }'
}

get_ipv6_template() { # <interface>
    # Assume /64 based on base address of interface (set IPV4_TEMPLATE if not)
    local _if="${1:-}"
    if [ -z "${_if}" ]
    then
        fatal "Usage: get_ipv6_template <interface>"
    fi
    ifconfig ${_if} inet6 | awk '/inet6/ && substr($2,0,4) != "fe80" { split($2,a,"::"); printf("%s::%%d/128\n",a[1]); exit }'
}

get_interface_addresses() { # -46l <interfaces>
    local _ipv4=
    local _ipv6=
    local _ll=

    set -- $(getopt 46l $@)
    while [ $# -ne 0 ]
    do
        case "$1" in
            -4) _ipv4=1 ; shift;;
            -6) _ipv6=1 ; shift;;
            -l) _ll=1; shift;;
            --) shift; break;;
        esac
    done
    local _if="${1:-}"
    if [ -z "${_if}" ]
    then
        fatal "Usage: get_interface_addresses -46l <interface>"
    fi

    if [ -z "${_ipv4}" -a -z "${_ipv6}" -a -z "${_ll}" ]
    then
        fatal "Usage: get_interface_addresses -46l <interface> [No address types specifiied]"
    fi

    if [ -n "${_ipv4}" ]
    then
        ifconfig ${_if} | awk '$1 == "inet" { print $2 }' 
    fi
    if [ -n "${_ipv6}" ]
    then
        ifconfig ${_if} | awk '$1 == "inet6" && substr($2,0,4) != "fe80" { sub(/%.*/,"",$2); print $2 }'
    fi
    if [ -n "${_ll}" ]
    then
        ifconfig ${_if} | awk '$1 == "inet6" && substr($2,0,4) == "fe80" { sub(/%.*/,"",$2); print $2 }'
    fi

}

###
### Commands
###


config() {
    cat <<EOM

Default Config: ${WG_INTERFACE}

WG_BASE        : ${WG_BASE}
WG_INTERFACE   : ${WG_INTERFACE}
WG_ENDPOINT    : ${WG_ENDPOINT:-$(get_default_ipv4):${WG_PORT:-51820}}
WG_MTU         : ${WG_MTU:-1420}
WG_DNS         : ${WG_DNS:-$(get_interface_addresses -46 $WG_INTERFACE | paste -sd, -)}
WG_KEEPALIVE   : ${WG_KEEPALIVE:-}

IPV4_TEMPLATE        : ${IPV4_TEMPLATE}
IPV6_TEMPLATE        : ${IPV6_TEMPLATE}
IPV6_LOCAL_TEMPLATE  : ${IPV6_LOCAL_TEMPLATE}

EOM
}

get_id() { # <client>
    local _client="${1:-}"
    if [ -z "${_client}" ]
    then
        fatal "Usage: get_id <client>"
    fi
    find "${WG_BASE}/${WG_INTERFACE}" -name "client*" | xargs grep -hl "^# CLIENT: ${_client}$" 
}

get_client() { # <client>
    local _client="${1:-}"
    if [ -z "${_client}" ]
    then
        fatal "Usage: get_client <client>"
    fi
    local _config="$(get_id ${_client})"
    if [ -z "${_config}" ]
    then
        fatal "Client ${_client} not found"
    fi
    cat "${_config}"
    qrencode -t ansiutf8 < "${_config}"
}

rm_client() { # <client>
    local _client="${1:-}"
    if [ -z "${_client}" ]
    then
        fatal "Usage: get_client <client>"
    fi

    local _config="$(get_id ${_client})"
    if [ -z "${_config}" ]
    then
        fatal "Client ${_client} not found"
    fi

    local _server="$(echo ${_config} | sed -e 's/client\(...\).conf$/server\1.conf/')"

    rm "${_config}" "${_server}" && info "Client ${_client} removed"
}

setconf() {
    local _conf=$(mktemp)
    trap "rm -f ${_conf}" EXIT
    ( 
        cat "${WG_BASE}/${WG_INTERFACE}.conf"
        find "${WG_BASE}/${WG_INTERFACE}" -name "server*" | xargs cat
    ) > "${_conf}"
    /usr/local/bin/wg syncconf ${WG_INTERFACE} "${_conf}"
    rm -f "${_conf}"
    /usr/local/bin/wg show ${WG_INTERFACE}
}

syncconf() {
    local _conf=$(mktemp)
    trap "rm -f ${_conf}" EXIT
    ( 
        cat "${WG_BASE}/${WG_INTERFACE}.conf"
        find "${WG_BASE}/${WG_INTERFACE}" -name "server*" | xargs cat
    ) > "${_conf}"
    /usr/local/bin/wg syncconf ${WG_INTERFACE} "${_conf}"
    rm -f "${_conf}"
    /usr/local/bin/wg show ${WG_INTERFACE}
}

list_clients() {
    find "${WG_BASE}/${WG_INTERFACE}" -name "client*" | xargs -n1 awk '
        /^# CLIENT:/    { client=$NF }
        /Address =/     { sub(/Address = /,""); address=$0 }
        END             { printf("%-16s : %s\n",client,address) }'
}

add_client() { # [-4] [-6] [-e eg_endpoint] [-p wg_port] [-m wg_mtu] [-d wg_dns] <name>
    # By default enable both ipv4 and ipv6 if interface configured
    local _ipv4=1
    local _ipv6=1
    if [ -z "${IPV4_TEMPLATE}" ]
    then
        _ipv4=
    fi
    if [ -z "${IPV6_TEMPLATE}" ]
    then
        _ipv6=
    fi

    # -4/-6 options enable ipv4 and ipv6 only 
    set -- $(getopt 46p:m:d:e:k: $@)
    while [ $# -ne 0 ]
    do
        case "$1" in
            -4) _ipv6= ; shift;;
            -6) _ipv4= ; shift;;
            -e) WG_ENDPOINT="$2"; shift; shift;;
            -p) WG_PORT="$2"; shift; shift;;
            -m) WG_MTU="$2"; shift; shift;;
            -d) WG_DNS="$2"; shift; shift;;
            -k) WG_KEEPALIVE="$2"; shift; shift;;
            --) shift; break;;
        esac
    done

    WG_PORT="${WG_PORT:-51820}" 
    WG_MTU="${WG_MTU:-1420}" 
    # If WG_ENDPOINT isnt defined we use default IPv4 address
    WG_ENDPOINT="${WG_ENDPOINT:-$(get_default_ipv4):${WG_PORT}}"
    # If WG_DNS isnt set we use the addresses of the wg interface
    WG_KEEPALIVE="${WG_KEEPALIVE:-}"

    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        fatal "Usage: $0 [-4] [-6] <name>"
    fi

    if [ -n "$(get_id ${_name})" ]
    then
        fatal "Client: ${_name} exists"
    fi

    if [ -z "${_ipv4}" ] && [ -z "${_ipv6}" ] 
    then
        fatal "No valid IP configuration"
    fi

    if [ -n "${_ipv4}" -a -n "${_ipv6}" ]
    then
        WG_DNS="${WG_DNS:-$(get_interface_addresses -46 $WG_INTERFACE | paste -sd, -)}" 
    elif [ -n "${_ipv4}" ]
    then
        WG_DNS="${WG_DNS:-$(get_interface_addresses -4 $WG_INTERFACE | paste -sd, -)}" 
    elif [ -n "${_ipv6}" ]
    then
        WG_DNS="${WG_DNS:-$(get_interface_addresses -6 $WG_INTERFACE | paste -sd, -)}" 
    fi

    # Get next_client_id
    local id=$(increment_counter ${NEXT_CLIENT_ID} ${CLIENT_MIN_ID} ${CLIENT_MAX_ID})

    local client="$(printf ${CLIENT_TEMPLATE} ${id})"
    local server="$(printf ${SERVER_TEMPLATE} ${id})"

    if [ -f "${client}" ]
    then
        fatal "Client: ${client} exists"
    fi

    if [ -f "${server}" ]
    then
        fatal "Server: ${server} exists"
    fi

    local client_privkey=$(wg genkey)
    local client_pubkey=$(echo ${client_privkey} | wg pubkey)
    local client_psk=$(wg genpsk)

    # Generate client config file
    (
        printf "# CLIENT: %s\n[Interface]\n" "${_name}"
        printf "PrivateKey = %s\n" "${client_privkey}"
        if [ -n "${_ipv4}" -a -n "${_ipv6}" ]
        then
            printf "Address = %s, %s, %s\n" $(printf $IPV4_TEMPLATE $id) $(printf $IPV6_TEMPLATE $id) $(printf $IPV6_LOCAL_TEMPLATE $id)
        elif [ -n "${_ipv4}" ]
        then
            printf "Address = %s\n" $(printf $IPV4_TEMPLATE $id)
        elif [ -n "${_ipv6}" ]
        then
            printf "Address = %s, %s\n" $(printf $IPV6_TEMPLATE $id) $(printf $IPV6_LOCAL_TEMPLATE $id)
        fi
        printf "DNS = %s\n" "${WG_DNS}"
        printf "MTU = %s\n" "${WG_MTU}"

        printf "\n[Peer]\n"
        printf "Endpoint = %s\n" ${WG_ENDPOINT}
        printf "PublicKey = %s\n" $(awk '/PrivateKey/ { print $NF }' "${WG_BASE}/${WG_INTERFACE}.conf" | wg pubkey)
        printf "PresharedKey = %s\n" ${client_psk}
        if [ -n "${_ipv4}" -a -n "${_ipv6}" ]
        then
            printf "AllowedIPs = 0.0.0.0/0, ::/0, fe80::/64\n" 
        elif [ -n "${_ipv4}" ]
        then
            printf "AllowedIPs = 0.0.0.0/0\n" 
        elif [ -n "${_ipv6}" ]
        then
            printf "AllowedIPs = ::/0, fe80::/64\n" 
        fi
        if [ -n "${WG_KEEPALIVE}" ]
        then
            printf "PersistentKeepalive = %d\n" "${WG_KEEPALIVE}"
        fi

    ) | ( echo "\n----- Client Config -----"; tee "${client}" )

    # Generate server config file
    (
        printf "# CLIENT: %s\n" "${_name}"
        if [ -n "${_ipv4}" -a -n "${_ipv6}" ]
        then
            printf "# Client Address: %s, %s, %s\n" $(printf $IPV4_TEMPLATE $id) $(printf $IPV6_TEMPLATE $id) $(printf $IPV6_LOCAL_TEMPLATE $id)
        elif [ -n "${_ipv4}" ]
        then
            printf "# Client Address: %s\n" $(printf $IPV4_TEMPLATE $id)
        elif [ -n "${_ipv6}" ]
        then
            printf "# Client Address: %s, %s\n" $(printf $IPV6_TEMPLATE $id) $(printf $IPV6_LOCAL_TEMPLATE $id)
        fi
        printf "[Peer]\n"
        printf "PublicKey = %s\n" "${client_pubkey}"
        printf "PresharedKey = %s\n" ${client_psk}
        if [ -n "${_ipv4}" -a -n "${_ipv6}" ]
        then
            printf "AllowedIPs = %s, %s, %s\n" $(printf $IPV4_TEMPLATE $id) $(printf $IPV6_TEMPLATE $id) $(printf $IPV6_LOCAL_TEMPLATE $id)
        elif [ -n "${_ipv4}" ]
        then
            printf "AllowedIPs = %s\n" $(printf $IPV4_TEMPLATE $id) 
        elif [ -n "${_ipv6}" ]
        then
            printf "AllowedIPs = %s, %s\n" $(printf $IPV6_TEMPLATE $id) $(printf $IPV6_LOCAL_TEMPLATE $id)
        fi
    ) | ( echo "\n----- Server Config -----"; tee "${server}"; echo )

}


####
#### Main program
####

set -o pipefail
set -o errexit

umask 077

# Parse global options
#
# -b <wg_base>
# -i <wg_interface>
#
set -- $(getopt b:i: $@)
while [ $# -ne 0 ]
do
    case "$1" in
        -b) WG_BASE="$2"; shift; shift;;
        -i) WG_INTERFACE="$2"; shift; shift;;
        --) shift; break;;
    esac
done

# Set directories
WG_BASE="${WG_BASE:-/etc/wireguard}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"

# Check WG_BASE and WG_INTERFACE are valid
if [ ! -d "${WG_BASE}" ] 
then
    fatal "WG_BASE: ${WG_BASE} not found"
fi

if [ ! -w "${WG_BASE}" ]
then
    fatal "WG_BASE: ${WG_BASE} not writeable"
fi

if ! ifconfig ${WG_INTERFACE} >/dev/null 2>&1
then
    fatal "WG_INTERFACE: ${WG_INTERFACE} not found"
fi

# Make sure we have a valid conf file
if ! (grep -qs PrivateKey "${WG_BASE}/${WG_INTERFACE}.conf" && grep -qs ListenPort "${WG_BASE}/${WG_INTERFACE}.conf")
then
    fatal "${WG_BASE}/${WG_INTERFACE}.conf invalid"
fi

# Create client config directory if needed
if [ ! -d "${WG_BASE}/${WG_INTERFACE}" ]
then
    mkdir "${WG_BASE}/${WG_INTERFACE}"
fi

# Look for an env file in WG_BASE/WG_INTERFACE/ENV
# This should contain configuration as env values 
# which are sourced here.
#
# e.g. WG_ENDPOINT=....
if [ -f "${WG_BASE}/${WG_INTERFACE}/ENV" ]
then
    . "${WG_BASE}/${WG_INTERFACE}/ENV"
fi

# Client Id
NEXT_CLIENT_ID="${WG_BASE}/${WG_INTERFACE}/next_client_id"
CLIENT_MIN_ID=10
CLIENT_MAX_ID=250
CLIENT_MTU=1420

# Templates
IPV4_TEMPLATE="${IPV4_TEMPLATE:-$(get_ipv4_template $WG_INTERFACE)}"
IPV6_TEMPLATE="${IPV6_TEMPLATE:-$(get_ipv6_template $WG_INTERFACE)}"
IPV6_LOCAL_TEMPLATE="fe80::%d/128"
CLIENT_TEMPLATE="${WG_BASE}/${WG_INTERFACE}/client%03.3d.conf"
SERVER_TEMPLATE="${WG_BASE}/${WG_INTERFACE}/server%03.3d.conf"

if [ $# -gt 0 ]
then
    cmd="${1}"
    shift
    ${cmd} "$@"
fi
