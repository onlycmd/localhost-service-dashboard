#!/usr/bin/env bash
set -Eeuo pipefail

# Localhost Service Dashboard (LSD)
# Lists listening services (ports, PIDs), detects common HTTP/HTTPS/DB services,
# displays a colored table, and offers an interactive menu to manage processes.

# --------------------------- Config & Globals ---------------------------
REFRESH_INTERVAL_SECONDS=${REFRESH_INTERVAL_SECONDS:-2}
SHOW_UDP=${SHOW_UDP:-0}
FILTER_QUERY=${FILTER_QUERY:-}
NO_COLOR=${NO_COLOR:-}
LOG_DIR=${LSD_LOG_DIR:-/tmp/lsd-logs}
PAUSED=${PAUSED:-0}
declare -a RECORDS_BUFFER=()

# --------------------------- Utils ---------------------------
command_exists() {
	command -v "$1" >/dev/null 2>&1
}

is_tty() {
	[ -t 1 ]
}

# Colors
if is_tty && [ -z "${NO_COLOR}" ]; then
	CLR_RESET="\033[0m"
	CLR_DIM="\033[2m"
	CLR_BOLD="\033[1m"
	CLR_GRAY="\033[90m"
	CLR_RED="\033[31m"
	CLR_GREEN="\033[32m"
	CLR_YELLOW="\033[33m"
	CLR_BLUE="\033[34m"
	CLR_MAGENTA="\033[35m"
	CLR_CYAN="\033[36m"
	CLR_WHITE="\033[37m"
	CLR_BRIGHT_GREEN="\033[92m"
	CLR_BRIGHT_BLUE="\033[94m"
	CLR_BRIGHT_MAGENTA="\033[95m"
	CLR_BRIGHT_CYAN="\033[96m"
	CLR_BRIGHT_YELLOW="\033[93m"
else
	CLR_RESET=""
	CLR_DIM=""
	CLR_BOLD=""
	CLR_GRAY=""
	CLR_RED=""
	CLR_GREEN=""
	CLR_YELLOW=""
	CLR_BLUE=""
	CLR_MAGENTA=""
	CLR_CYAN=""
	CLR_WHITE=""
	CLR_BRIGHT_GREEN=""
	CLR_BRIGHT_BLUE=""
	CLR_BRIGHT_MAGENTA=""
	CLR_BRIGHT_CYAN=""
	CLR_BRIGHT_YELLOW=""
fi

cols() {
	local c
	c=$(tput cols 2>/dev/null || echo 120)
	if [ -z "$c" ]; then echo 120; else echo "$c"; fi
}

repeat_char() {
	local char="$1" count="$2"
	printf "%${count}s" "" | tr ' ' "$char"
}

truncate_str() {
	local s="$1" width="$2"
	local len=${#s}
	if (( len <= width )); then
		printf "%s" "$s"
	else
		local cut=$(( width-1 ))
		[ $cut -lt 1 ] && cut=1
		printf "%s" "${s:0:cut}…"
	fi
}

# --------------------------- Service Classification ---------------------------
normalize_proc() {
	local p="$1"
	printf "%s" "${p,,}"
}

port_service_type() {
	local proto="$1" port="$2" proc="$3"
	local p
	p=$(normalize_proc "$proc")

	# HTTPS strict
	if [ "$port" = "443" ]; then echo "HTTPS"; return; fi

	# HTTP-ish ports
	case "$port" in
		80|8080|8000|8008|8081|8888|5000|3000|3001|3002|5173|4200)
			echo "HTTP"; return ;;
	esac

	# Databases and infra
	case "$port" in
		3306) echo "MySQL/MariaDB"; return ;;
		5432) echo "PostgreSQL"; return ;;
		27017) echo "MongoDB"; return ;;
		6379) echo "Redis"; return ;;
		11211) echo "Memcached"; return ;;
		9200|9300) echo "Elasticsearch"; return ;;
		5601) echo "Kibana"; return ;;
		5672|15672) echo "RabbitMQ"; return ;;
		9042) echo "Cassandra"; return ;;
		1433) echo "MSSQL"; return ;;
		1521) echo "Oracle"; return ;;
		27015) echo "ValveSRCDS"; return ;;
	esac

	# Heuristic by process
	case "$p" in
		nginx|apache2|httpd|caddy|traefik|lighttpd)
			echo "HTTP"; return ;;
		node|nodejs|deno|bun|vite|vite-node|next|nuxt)
			echo "HTTP"; return ;;
		python|gunicorn|uvicorn|daphne|quart|flask|django|fastapi)
			echo "HTTP"; return ;;
		java|kotlin|spring|tomcat|jetty|wildfly)
			echo "HTTP"; return ;;
		mysqld|mariadbd) echo "MySQL/MariaDB"; return ;;
		postgres|postgresql|postmaster) echo "PostgreSQL"; return ;;
		mongod) echo "MongoDB"; return ;;
		redis-server) echo "Redis"; return ;;
		es|elasticsearch) echo "Elasticsearch"; return ;;
		rabbitmq*|beam.smp) echo "RabbitMQ"; return ;;
	esac

	echo "Other"
}

service_color() {
	case "$1" in
		HTTP) printf "%s" "$CLR_BRIGHT_GREEN" ;;
		HTTPS) printf "%s" "$CLR_BRIGHT_BLUE" ;;
		MySQL/MariaDB|PostgreSQL|MongoDB|Elasticsearch|Cassandra|MSSQL|Oracle)
			printf "%s" "$CLR_BRIGHT_MAGENTA" ;;
		Redis|Memcached) printf "%s" "$CLR_BRIGHT_YELLOW" ;;
		RabbitMQ|MQTT) printf "%s" "$CLR_BRIGHT_CYAN" ;;
		*) printf "%s" "$CLR_WHITE" ;;
	esac
}

# --------------------------- Data Collection ---------------------------
# Output format per record:
# port|proto|type|pid|proc|user|cmd

collect_with_lsof() {
	local proto="$1" # tcp or udp
	local args=( -nP -F pcPnTuL )
	if [ "$proto" = "tcp" ]; then
		args+=( -iTCP -sTCP:LISTEN )
	else
		args+=( -iUDP )
	fi

	lsof "${args[@]}" 2>/dev/null |
	awk -v proto="$proto" '
		/^p/ { pid=substr($0,2); next }
		/^c/ { cmd=substr($0,2); proc=cmd; next }
		/^L/ { user=substr($0,2); next }
		/^P/ { next } # protocol from lsof not used
		/^T/ { next } # state fields, already filtered by args
		/^n/ {
			name=substr($0,2)
			# Expect name like *:80 or 0.0.0.0:80 or [::]:80
			port=""
			# Extract port after last colon or closing bracket
			# Handle IPv6
			i = match(name, /]:[0-9]+$/)
			if (i) {
				port=substr(name, RSTART+2)
			} else {
				j = match(name, /:[0-9]+$/)
				if (j) { port=substr(name, RSTART+1) }
			}
			if (port != "") {
				# Some UDP entries are not strictly listening; we still show
				type="Other"
				if (cmd == "") cmd="?"
				if (proc == "") proc=cmd
				if (user == "") user="?"
				printf "%s|%s|%s|%s|%s|%s|%s\n", port, proto, type, pid, proc, user, cmd
			}
		}
	'
}

collect_with_ss() {
	local proto="$1" # tcp or udp
	local ss_args=( -H -l -n )
	if [ "$proto" = "tcp" ]; then ss_args+=( -t ) ; else ss_args+=( -u ) ; fi
	# -p for process info may require elevated privileges
	ss "${ss_args[@]}" -p 2>/dev/null |
	awk -v proto="$proto" '
		{
			# Example: LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=123,fd=7))
			local_addr_port=$4
			port=""
			i = match(local_addr_port, /]:[0-9]+$/)
			if (i) {
				port=substr(local_addr_port, RSTART+2)
			} else {
				j = match(local_addr_port, /:[0-9]+$/)
				if (j) { port=substr(local_addr_port, RSTART+1) }
			}
			if (port == "") next
			# Process extraction
			pid="?"; proc="?"; user="?"
			# Combine the rest of the columns to search users:(()) blob
			for (k=5; k<=NF; k++) {
				blob = blob $k " "
			}
			if (match(blob, /users:\(\("[^\"]+",pid=[0-9]+/)) {
				m=substr(blob, RSTART, RLENGTH)
				gsub(/users:\(\("/, "", m)
				split(m, parts, ",")
				proc=parts[1]
				sub(/"/, "", proc)
				sub(/"/, "", proc)
				sub(/pid=/, "", parts[2])
				pid=parts[2]
			}
			printf "%s|%s|%s|%s|%s|%s|%s\n", port, proto, "Other", pid, proc, user, proc
			blob=""
		}
	'
}

collect_with_netstat() {
	local proto="$1" # tcp or udp
	local flags=( -l -n -p )
	if [ "$proto" = "tcp" ]; then
		netstat "${flags[@]}" -t 2>/dev/null |
		awk -v proto="$proto" 'NR>2 {
			local_addr=$4
			pidprog=$7
			port=""
			i = match(local_addr, /]:[0-9]+$/)
			if (i) {
				port=substr(local_addr, RSTART+2)
			} else {
				j = match(local_addr, /:[0-9]+$/)
				if (j) { port=substr(local_addr, RSTART+1) }
			}
			if (port == "") next
			pid="?"; proc="?"; user="?"
			if (pidprog != "-") {
				split(pidprog, a, "/"); pid=a[1]; proc=a[2]
			}
			printf "%s|%s|%s|%s|%s|%s|%s\n", port, proto, "Other", pid, proc, user, proc
		}'
	else
		netstat "${flags[@]}" -u 2>/dev/null |
		awk -v proto="$proto" 'NR>2 {
			local_addr=$4
			pidprog=$7
			port=""
			i = match(local_addr, /]:[0-9]+$/)
			if (i) {
				port=substr(local_addr, RSTART+2)
			} else {
				j = match(local_addr, /:[0-9]+$/)
				if (j) { port=substr(local_addr, RSTART+1) }
			}
			if (port == "") next
			pid="?"; proc="?"; user="?"
			if (pidprog != "-") {
				split(pidprog, a, "/"); pid=a[1]; proc=a[2]
			}
			printf "%s|%s|%s|%s|%s|%s|%s\n", port, proto, "Other", pid, proc, user, proc
		}'
	fi
}

collect_listeners() {
	RECORDS_BUFFER=()
	local have_lsof=0 have_ss=0 have_netstat=0
	if command_exists lsof; then have_lsof=1; fi
	if command_exists ss; then have_ss=1; fi
	if command_exists netstat; then have_netstat=1; fi

	local tmp
	if [ $have_lsof -eq 1 ]; then
		tmp=$(collect_with_lsof tcp || true)
		if [ -n "$tmp" ]; then mapfile -t RECORDS_BUFFER < <(printf "%s\n" "$tmp"); fi
		if [ "${SHOW_UDP}" = "1" ]; then
			tmp=$(collect_with_lsof udp || true)
			if [ -n "$tmp" ]; then while IFS= read -r line; do RECORDS_BUFFER+=("$line"); done <<< "$tmp"; fi
		fi
	elif [ $have_ss -eq 1 ]; then
		tmp=$(collect_with_ss tcp || true)
		if [ -n "$tmp" ]; then mapfile -t RECORDS_BUFFER < <(printf "%s\n" "$tmp"); fi
		if [ "${SHOW_UDP}" = "1" ]; then
			tmp=$(collect_with_ss udp || true)
			if [ -n "$tmp" ]; then while IFS= read -r line; do RECORDS_BUFFER+=("$line"); done <<< "$tmp"; fi
		fi
	elif [ $have_netstat -eq 1 ]; then
		tmp=$(collect_with_netstat tcp || true)
		if [ -n "$tmp" ]; then mapfile -t RECORDS_BUFFER < <(printf "%s\n" "$tmp"); fi
		if [ "${SHOW_UDP}" = "1" ]; then
			tmp=$(collect_with_netstat udp || true)
			if [ -n "$tmp" ]; then while IFS= read -r line; do RECORDS_BUFFER+=("$line"); done <<< "$tmp"; fi
		fi
	else
		echo "Neither lsof nor ss nor netstat found. Please install lsof or iproute2 (ss) or net-tools (netstat)." >&2
		exit 1
	fi
}

# --------------------------- Rendering ---------------------------
render_header() {
	local width=$(cols)
	local title=" Localhost Service Dashboard "
	local bar
	bar=$(repeat_char "═" "$width")
	printf "%b%s%b\n" "$CLR_DIM" "$bar" "$CLR_RESET"
	printf "%b%s%b\n" "$CLR_BOLD" "${title}" "$CLR_RESET"
	printf "%b%s%b\n" "$CLR_DIM" "$bar" "$CLR_RESET"
}

render_table() {
	local width=$(cols)
	local col_idx=4
	local col_port=6
	local col_proto=6
	local col_type=16
	local col_proc=18
	local col_pid=7
	local col_user=12
	local remaining=$(( width - col_idx - col_port - col_proto - col_type - col_proc - col_pid - col_user - 8 ))
	if (( remaining < 10 )); then remaining=10; fi
	local col_cmd=$remaining

	printf "%b%3s%b  %-5s %-5s %-15s %-17s %6s %-10s %-s\n" \
		"$CLR_BOLD" "#" "$CLR_RESET" "PORT" "PR" "TYPE" "PROCESS" "PID" "USER" "COMMAND"
	printf "%b%s%b\n" "$CLR_DIM" "$(repeat_char "-" "$width")" "$CLR_RESET"

	local i=0
	for rec in "${RECORDS_BUFFER[@]}"; do
		IFS='|' read -r port proto _type pid proc user cmd <<< "$rec"
		# Classify type (override placeholder)
		local t
		t=$(port_service_type "$proto" "$port" "$proc")
		local color
		color=$(service_color "$t")

		# Filter
		if [ -n "$FILTER_QUERY" ]; then
			local haystack
			haystack="${port} ${proto} ${t} ${pid} ${proc} ${user} ${cmd}"
			if ! grep -i -q -- "$FILTER_QUERY" <<< "$haystack"; then
				continue
			fi
		fi

		# Display
		printf "%b%3d%b  %-5s %-5s %b%-15s%b %-17s %6s %-10s %-s\n" \
			"$CLR_CYAN" $((++i)) "$CLR_RESET" \
			"$(truncate_str "$port" "$col_port")" \
			"$(truncate_str "$proto" "$col_proto")" \
			"$color$(truncate_str "$t" "$col_type")$CLR_RESET" \
			"$(truncate_str "$proc" "$col_proc")" \
			"$(truncate_str "$pid" "$col_pid")" \
			"$(truncate_str "$user" "$col_user")" \
			"$(truncate_str "$cmd" "$col_cmd")"
	done

	[ "$i" -eq 0 ] && printf "%b%s%b\n" "$CLR_DIM" "No matching services." "$CLR_RESET"
}

render_footer() {
	local width=$(cols)
	printf "%b%s%b\n" "$CLR_DIM" "$(repeat_char "-" "$width")" "$CLR_RESET"
	printf "%b%s%b\n" "$CLR_BOLD" "[k] Kill PID  [p] Kill by Port  [s] Start Cmd  [f] Filter  [u] Toggle UDP  [t] Interval  [d] Details  [r] Refresh  [space] Pause/Resume  [q] Quit" "$CLR_RESET"
	if [ -n "$FILTER_QUERY" ]; then
		if [ "$PAUSED" = "1" ]; then
			printf "%b%s%b\n" "$CLR_DIM" "Filter: '$FILTER_QUERY' • Interval: ${REFRESH_INTERVAL_SECONDS}s • Status: Paused" "$CLR_RESET"
		else
			printf "%b%s%b\n" "$CLR_DIM" "Filter: '$FILTER_QUERY' • Interval: ${REFRESH_INTERVAL_SECONDS}s" "$CLR_RESET"
		fi
	else
		if [ "$PAUSED" = "1" ]; then
			printf "%b%s%b\n" "$CLR_DIM" "Status: Paused • Interval: ${REFRESH_INTERVAL_SECONDS}s" "$CLR_RESET"
		else
			printf "%b%s%b\n" "$CLR_DIM" "Interval: ${REFRESH_INTERVAL_SECONDS}s" "$CLR_RESET"
		fi
	fi
}

clear_screen() {
	printf "\033[2J\033[H"
}

# --------------------------- Actions ---------------------------
kill_pid() {
	local pid="$1"
	if [ -z "$pid" ]; then return; fi
	if kill -0 "$pid" 2>/dev/null; then
		if ! kill "$pid" 2>/dev/null; then
			if command_exists sudo; then sudo kill "$pid" || true; fi
		fi
		# If still alive, force
		sleep 0.3
		if kill -0 "$pid" 2>/dev/null; then
			if ! kill -9 "$pid" 2>/dev/null; then
				if command_exists sudo; then sudo kill -9 "$pid" || true; fi
			fi
		fi
	fi
}

kill_by_port() {
	local port="$1"
	[ -z "$port" ] && return
	local pids
	pids=$(lsof -nP -i :"$port" -sTCP:LISTEN -t 2>/dev/null || true)
	if [ -z "$pids" ]; then
		pids=$(ss -H -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p { if (match($0, /pid=[0-9]+/)) { s=substr($0, RSTART+4, RLENGTH-4); print s } }' || true)
	fi
	if [ -n "$pids" ]; then
		while IFS= read -r pid; do kill_pid "$pid"; done <<< "$pids"
	fi
}

start_command() {
	mkdir -p "$LOG_DIR"
	local cmd="$1"
	[ -z "$cmd" ] && return
	# Run in background, disown, and log
	local ts
	ts=$(date +%Y%m%d-%H%M%S)
	local log_out="$LOG_DIR/cmd-$ts.out"
	local log_err="$LOG_DIR/cmd-$ts.err"
	( nohup bash -lc "$cmd" >>"$log_out" 2>>"$log_err" & disown ) >/dev/null 2>&1 || true
}

show_details_for_index() {
	local idx="$1"
	local i=0
	for rec in "${RECORDS_BUFFER[@]}"; do
		IFS='|' read -r port proto _type pid proc user cmd <<< "$rec"
		if [ -n "$FILTER_QUERY" ]; then
			local haystack
			haystack="${port} ${proto} $(port_service_type "$proto" "$port" "$proc") ${pid} ${proc} ${user} ${cmd}"
			if ! grep -i -q -- "$FILTER_QUERY" <<< "$haystack"; then
				continue
			fi
		fi
		i=$((i+1))
		if [ "$i" = "$idx" ]; then
			printf "%b%s%b\n" "$CLR_BOLD" "Details for index #$idx (PID $pid)" "$CLR_RESET"
			printf "%s\n" "Port: $port  Proto: $proto  Type: $(port_service_type "$proto" "$port" "$proc")"
			printf "%s\n" "Process: $proc  User: $user  Command: $cmd"
			printf "%b%s%b\n" "$CLR_DIM" "— Process Stats —" "$CLR_RESET"
			ps -o pid,ppid,pcpu,pmem,etime,state,comm,args -p "$pid" | sed 1q; ps -o pid,ppid,pcpu,pmem,etime,state,comm,args -p "$pid" | sed -n '2p'
			printf "%b%s%b\n" "$CLR_DIM" "— Open Files —" "$CLR_RESET"
			( lsof -p "$pid" 2>/dev/null | wc -l | awk '{print $1" open files"}' ) || true
			printf "%b%s%b\n" "$CLR_DIM" "— Recent Logs (if started via LSD) —" "$CLR_RESET"
			ls -1t "$LOG_DIR" 2>/dev/null | head -3 | sed 's/^/  /'
			return
		fi
	done
	printf "%b%s%b\n" "$CLR_RED" "Invalid index" "$CLR_RESET"
}

# --------------------------- Input Helpers ---------------------------
prompt() {
	local message="$1"
	printf "%b?%b %s " "$CLR_BRIGHT_CYAN" "$CLR_RESET" "$message"
}

read_input() {
	local var_name="$1"
	local value
	IFS= read -r value || true
	eval "$var_name=\"\$value\""
}

# --------------------------- Main Loop ---------------------------
main_loop() {
	while true; do
		clear_screen
		collect_listeners
		render_header
		render_table
		render_footer

		# Non-blocking single key read with timeout (disabled when paused)
		local key=""
		if [ "$PAUSED" = "1" ]; then
			IFS= read -rsn1 key || true
		else
			IFS= read -rsn1 -t "$REFRESH_INTERVAL_SECONDS" key || true
		fi
		case "$key" in
			k)
				prompt "Enter PID to kill:"
				read_input pid
				kill_pid "$pid"
				;;
			p)
				prompt "Enter port to kill (e.g., 3000):"
				read_input port
				kill_by_port "$port"
				;;
			s)
				prompt "Enter command to start (runs in background):"
				read_input cmd
				start_command "$cmd"
				;;
			f)
				prompt "Enter filter (empty to clear):"
				read_input filt
				FILTER_QUERY="$filt"
				;;
			u)
				if [ "${SHOW_UDP}" = "1" ]; then SHOW_UDP=0; else SHOW_UDP=1; fi
				;;
			t)
				prompt "Refresh interval seconds (e.g., 1..10):"
				read_input iv
				if [[ "$iv" =~ ^[0-9]+$ ]] && [ "$iv" -ge 1 ] && [ "$iv" -le 60 ]; then
					REFRESH_INTERVAL_SECONDS="$iv"
				fi
				;;
			d)
				prompt "Enter index number from the table:"
				read_input idx
				clear_screen
				collect_listeners
				render_header
				show_details_for_index "$idx"
				printf "\nPress Enter to return..."
				read -r _ || true
				;;
			r)
				: # just refresh
				;;
			" ")
				if [ "${PAUSED}" = "1" ]; then PAUSED=0; else PAUSED=1; fi
				;;
			q)
				break
				;;
			*)
				# timeout or unrecognized; just refresh
				:
				;;
		esac
	done
}

# --------------------------- Entry ---------------------------
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
	echo "Localhost Service Dashboard"
	echo "Usage: $0 [--help]"
	echo "Keys: k=kill pid, p=kill by port, s=start cmd, f=filter, u=toggle UDP, t=interval, d=details, r=refresh, q=quit"
	exit 0
fi

main_loop 