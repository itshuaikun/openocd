#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)
REPO_ROOT="$SCRIPT_DIR"
if [[ -d "$REPO_ROOT/tcl" ]]; then
	TCL_DIR="$REPO_ROOT/tcl"
elif [[ -d "$SCRIPT_DIR/../share/openocd/scripts" ]]; then
	REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
	TCL_DIR="$REPO_ROOT/share/openocd/scripts"
else
	TCL_DIR="$REPO_ROOT/tcl"
fi

DEFAULT_ADAPTER_SPEED=1000
DEFAULT_R908_GDB_PORT=4440
DEFAULT_A55_GDB_PORT_BASE=3330
PROBE_TIMEOUT_SECONDS=6
CACHE_STALE_AFTER_SECONDS=30
RUNTIME_DIR="${TMPDIR:-/tmp}/rhea_gdb_server"
TOPOLOGY_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rhea_gdb_server/topology"

MODE="list"
CPU_ARG=""
ADAPTER_SERIAL=""
ADAPTER_SPEED="$DEFAULT_ADAPTER_SPEED"
GDB_PORT=""
OPENOCD_BIN=""
REFRESH_DISCOVERY=0

declare -a PROBE_TYPES=()
declare -a PROBE_SERIALS=()
declare -a PROBE_USB_PATHS=()
declare -a PROBE_BACKENDS=()
declare -a PROBE_CPUS=()
declare -a PROBE_BUSY=()
declare -a PROBE_LOCK_DIRS=()

HELD_LOCK_DIR=""
OPENOCD_CHILD_PID=""

usage() {
	cat <<'EOF'
Usage:
  ./rhea_gdb_server.sh
  ./rhea_gdb_server.sh --list
  ./rhea_gdb_server.sh --cpu a55:N [--adapter-serial SERIAL] [--adapter-speed KHZ] [--gdb-port PORT] [--openocd PATH]
  ./rhea_gdb_server.sh --cpu r908 [--adapter-serial SERIAL] [--adapter-speed KHZ] [--gdb-port PORT] [--openocd PATH]

Options:
  --list                    List connected probes and detected CPUs.
  --cpu a55:N|r908          Start gdbserver for the selected CPU target.
  --adapter-serial SERIAL   Use the specific debugger serial number.
  --adapter-speed KHZ       Set adapter speed in kHz. Default: 1000.
  --gdb-port PORT           GDB port. Default: 3330 for A55, 4440 for R908.
  --openocd PATH            OpenOCD binary path. Defaults to ./rhea_gdb_server.sh sibling openocd, then PATH.
  --refresh-discovery       Ignore cached topology and probe targets again.
  -h, --help                Show this help.
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

require_linux() {
	[[ "$(uname -s)" == "Linux" ]] || die "rhea_gdb_server.sh only supports Linux hosts"
}

require_tool() {
	local tool="$1"
	command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
}

is_pid_running() {
	local pid="$1"

	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null
}

probe_lock_key() {
	local adapter_type="$1"
	local serial="$2"
	local usb_path="$3"
	local raw_key

	raw_key="${adapter_type}_${serial:-$usb_path}"
	raw_key="${raw_key//[^A-Za-z0-9._-]/_}"
	printf '%s' "$raw_key"
}

probe_lock_dir() {
	local adapter_type="$1"
	local serial="$2"
	local usb_path="$3"
	local key

	key="$(probe_lock_key "$adapter_type" "$serial" "$usb_path")"
	printf '%s/%s' "$RUNTIME_DIR" "$key"
}

probe_cache_file() {
	local adapter_type="$1"
	local serial="$2"
	local usb_path="$3"
	local key

	key="$(probe_lock_key "$adapter_type" "$serial" "$usb_path")"
	printf '%s/%s.cache' "$TOPOLOGY_DIR" "$key"
}

read_lock_value() {
	local lock_dir="$1"
	local key="$2"
	local value

	value="$(sed -n "s/^${key}=//p" "$lock_dir/metadata" 2>/dev/null | head -n 1)"
	printf '%s' "$value"
}

read_cache_value() {
	local cache_file="$1"
	local key="$2"
	local value

	value="$(sed -n "s/^${key}=//p" "$cache_file" 2>/dev/null | head -n 1)"
	printf '%s' "$value"
}

ensure_lock_is_fresh() {
	local lock_dir="$1"
	local owner_pid

	[[ -d "$lock_dir" ]] || return 1
	owner_pid="$(read_lock_value "$lock_dir" "owner_pid")"
	if is_pid_running "$owner_pid"; then
		return 0
	fi

	rm -rf "$lock_dir"
	return 1
}

release_probe_lock() {
	if [[ -n "$HELD_LOCK_DIR" && -d "$HELD_LOCK_DIR" ]]; then
		rm -rf "$HELD_LOCK_DIR"
	fi
	HELD_LOCK_DIR=""
}

valid_detected_cpu() {
	case "$1" in
		a55|r908|unknown)
			return 0
			;;
	esac
	return 1
}

valid_cmsis_dap_backend() {
	case "$1" in
		""|auto|hid|usb_bulk)
			return 0
			;;
	esac
	return 1
}

get_cached_probe_info() {
	local adapter_type="$1"
	local serial="$2"
	local usb_path="$3"
	local current_busnum="$4"
	local current_devnum="$5"
	local -n out_cpu_ref="$6"
	local -n out_backend_ref="$7"
	local cache_file detected_cpu cached_backend updated_at cached_busnum cached_devnum now

	out_cpu_ref=""
	out_backend_ref=""

	cache_file="$(probe_cache_file "$adapter_type" "$serial" "$usb_path")"
	[[ -f "$cache_file" ]] || return 1

	detected_cpu="$(read_cache_value "$cache_file" "detected_cpu")"
	valid_detected_cpu "$detected_cpu" || return 1

	updated_at="$(read_cache_value "$cache_file" "updated_at")"
	[[ "$updated_at" =~ ^[0-9]+$ ]] || return 1

	now="$(date +%s)"
	if ((now - updated_at > CACHE_STALE_AFTER_SECONDS)); then
		return 1
	fi

	cached_busnum="$(read_cache_value "$cache_file" "busnum")"
	cached_devnum="$(read_cache_value "$cache_file" "devnum")"
	if [[ -n "$current_busnum" && -n "$cached_busnum" && "$current_busnum" != "$cached_busnum" ]]; then
		return 1
	fi
	if [[ -n "$current_devnum" && -n "$cached_devnum" && "$current_devnum" != "$cached_devnum" ]]; then
		return 1
	fi

	cached_backend="$(read_cache_value "$cache_file" "backend")"
	valid_cmsis_dap_backend "$cached_backend" || cached_backend=""

	out_cpu_ref="$detected_cpu"
	out_backend_ref="$cached_backend"
	return 0
}

write_probe_cache() {
	local adapter_type="$1"
	local serial="$2"
	local usb_path="$3"
	local detected_cpu="$4"
	local backend="$5"
	local busnum="$6"
	local devnum="$7"
	local cache_file

	cache_file="$(probe_cache_file "$adapter_type" "$serial" "$usb_path")"
	mkdir -p "$TOPOLOGY_DIR"
	cat >"$cache_file" <<EOF
updated_at=$(date +%s)
detected_cpu=$detected_cpu
backend=$backend
busnum=$busnum
devnum=$devnum
EOF
}

forward_signal_to_child() {
	local signal="$1"

	if [[ -n "$OPENOCD_CHILD_PID" ]] && is_pid_running "$OPENOCD_CHILD_PID"; then
		kill -"$signal" "$OPENOCD_CHILD_PID" 2>/dev/null || true
	fi
}

wait_for_child_exit() {
	local timeout_seconds="$1"
	local deadline

	[[ -n "$OPENOCD_CHILD_PID" ]] || return 0
	deadline=$((SECONDS + timeout_seconds))
	while is_pid_running "$OPENOCD_CHILD_PID"; do
		if ((SECONDS >= deadline)); then
			return 1
		fi
		sleep 0.1
	done

	return 0
}

terminate_child_process() {
	[[ -n "$OPENOCD_CHILD_PID" ]] || return 0
	if ! is_pid_running "$OPENOCD_CHILD_PID"; then
		return 0
	fi

	forward_signal_to_child INT
	if wait_for_child_exit 2; then
		return 0
	fi

	forward_signal_to_child TERM
	if wait_for_child_exit 2; then
		return 0
	fi

	kill -KILL "$OPENOCD_CHILD_PID" 2>/dev/null || true
	wait_for_child_exit 1 || true
}

cleanup_and_exit() {
	local rc="$1"

	terminate_child_process
	release_probe_lock
	exit "$rc"
}

resolve_openocd() {
	if [[ -n "$OPENOCD_BIN" ]]; then
		[[ -x "$OPENOCD_BIN" ]] || die "OpenOCD binary is not executable: $OPENOCD_BIN"
		return
	fi

	if [[ -x "$SCRIPT_DIR/openocd" ]]; then
		OPENOCD_BIN="$SCRIPT_DIR/openocd"
		return
	fi

	OPENOCD_BIN="$(command -v openocd || true)"
	[[ -n "$OPENOCD_BIN" ]] || die "OpenOCD not found; use --openocd PATH, place openocd next to rhea_gdb_server.sh, or add it to PATH"
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--list)
				MODE="list"
				shift
				;;
			--cpu)
				[[ $# -ge 2 ]] || die "--cpu requires a value"
				MODE="start"
				CPU_ARG="$2"
				shift 2
				;;
			--adapter-serial)
				[[ $# -ge 2 ]] || die "--adapter-serial requires a value"
				ADAPTER_SERIAL="$2"
				shift 2
				;;
			--adapter-speed)
				[[ $# -ge 2 ]] || die "--adapter-speed requires a value"
				ADAPTER_SPEED="$2"
				shift 2
				;;
			--gdb-port)
				[[ $# -ge 2 ]] || die "--gdb-port requires a value"
				GDB_PORT="$2"
				shift 2
				;;
			--openocd)
				[[ $# -ge 2 ]] || die "--openocd requires a value"
				OPENOCD_BIN="$2"
				shift 2
				;;
			--refresh-discovery)
				REFRESH_DISCOVERY=1
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "unknown argument: $1"
				;;
		esac
	done
}

validate_number() {
	local label="$1"
	local value="$2"
	[[ "$value" =~ ^[0-9]+$ ]] || die "$label must be a positive integer"
}

validate_cpu_arg() {
	if [[ "$MODE" != "start" ]]; then
		return
	fi

	if [[ "$CPU_ARG" == "r908" ]]; then
		:
	elif [[ "$CPU_ARG" =~ ^a55:([1-8])$ ]]; then
		:
	else
		die "unsupported --cpu value: $CPU_ARG"
	fi

	validate_number "adapter speed" "$ADAPTER_SPEED"
	if [[ -n "$GDB_PORT" ]]; then
		validate_number "GDB port" "$GDB_PORT"
	fi
}

build_openocd_match_args() {
	local serial="$1"
	local usb_path="$2"
	local -n out_ref="$3"

	out_ref=()
	if [[ -n "$serial" ]]; then
		out_ref+=(-c "adapter serial $serial")
	elif [[ -n "$usb_path" ]]; then
		out_ref+=(-c "adapter usb location $usb_path")
	fi
}

read_sysfs_value() {
	local path="$1"
	local value

	[[ -f "$path" ]] || return 1
	value="$(<"$path")"
	printf '%s' "$value"
}

probe_type_from_text() {
	local text="$1"
	local lc

	lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

	if [[ "$lc" == *"cmsis-dap"* ]] || [[ "$lc" == *"daplink"* ]]; then
		printf '%s' "cmsis-dap"
		return
	fi

	if [[ "$lc" == *"j-link"* ]] || [[ "$lc" == *"segger"* ]]; then
		printf '%s' "jlink"
		return
	fi

	printf '%s' ""
}

probe_type_from_usb() {
	local line="$1"
	local verbose="$2"
	local combined lc

	combined="$line
$verbose"
	lc="$(printf '%s' "$combined" | tr '[:upper:]' '[:lower:]')"

	if [[ "$lc" == *"cmsis-dap"* ]]; then
		printf '%s' "cmsis-dap"
		return
	fi

	if [[ "$lc" == *"j-link"* ]] || [[ "$lc" == *"segger"* ]]; then
		printf '%s' "jlink"
		return
	fi

	printf '%s' ""
}

serial_from_verbose() {
	local verbose="$1"
	local serial

	serial="$(printf '%s\n' "$verbose" | sed -n 's/^[[:space:]]*iSerial[[:space:]]*[0-9]\+[[:space:]]*\(.*\)$/\1/p' | head -n 1)"
	serial="$(trim "$serial")"
	if [[ "$serial" == "0" ]]; then
		serial=""
	fi
	printf '%s' "$serial"
}

probe_backend_from_usb() {
	local adapter_type="$1"
	local verbose="$2"
	local lc

	if [[ "$adapter_type" != "cmsis-dap" ]]; then
		printf '%s' ""
		return
	fi

	lc="$(printf '%s' "$verbose" | tr '[:upper:]' '[:lower:]')"

	if [[ "$lc" == *"human interface device"* && "$lc" == *"cmsis-dap"* ]]; then
		printf '%s' "hid"
		return
	fi

	if [[ "$lc" == *"vendor specific class"* && "$lc" == *"cmsis-dap"* ]]; then
		printf '%s' "usb_bulk"
		return
	fi

	printf '%s' "auto"
}

probe_backend_from_sysfs() {
	local adapter_type="$1"
	local dev_dir="$2"
	local iface_dir interface_name interface_class lc
	local has_hid=0
	local has_bulk=0

	if [[ "$adapter_type" != "cmsis-dap" ]]; then
		printf '%s' ""
		return
	fi

	for iface_dir in "$dev_dir":*; do
		[[ -d "$iface_dir" ]] || continue
		interface_name="$(read_sysfs_value "$iface_dir/interface" || true)"
		interface_class="$(read_sysfs_value "$iface_dir/bInterfaceClass" || true)"
		lc="$(printf '%s' "$interface_name" | tr '[:upper:]' '[:lower:]')"
		case "$interface_class:$lc" in
			03:*cmsis-dap*|03:*daplink*)
				has_hid=1
				;;
			ff:*cmsis-dap*|ff:*daplink*)
				has_bulk=1
				;;
		esac
	done

	if ((has_hid)); then
		printf '%s' "hid"
	elif ((has_bulk)); then
		printf '%s' "usb_bulk"
	else
		printf '%s' "auto"
	fi
}

enumerate_probes() {
	local dev_dir dev_name manufacturer product serial vendor_id product_id probe_hint
	local probe_type usb_path backend detected_cpu lock_dir busy lock_cpu cached_cpu cached_backend
	local verbose busnum devnum lsusb_busnum lsusb_devnum
	local has_lsusb=0

	if command -v lsusb >/dev/null 2>&1; then
		has_lsusb=1
	fi

	PROBE_TYPES=()
	PROBE_SERIALS=()
	PROBE_USB_PATHS=()
	PROBE_BACKENDS=()
	PROBE_CPUS=()
	PROBE_BUSY=()
	PROBE_LOCK_DIRS=()

	for dev_dir in /sys/bus/usb/devices/*; do
		[[ -f "$dev_dir/idVendor" ]] || continue
		dev_name="$(basename "$dev_dir")"
		[[ "$dev_name" == *-* ]] || continue

		vendor_id="$(read_sysfs_value "$dev_dir/idVendor" || true)"
		product_id="$(read_sysfs_value "$dev_dir/idProduct" || true)"
		manufacturer="$(read_sysfs_value "$dev_dir/manufacturer" || true)"
		product="$(read_sysfs_value "$dev_dir/product" || true)"
		serial="$(read_sysfs_value "$dev_dir/serial" || true)"
		busnum="$(read_sysfs_value "$dev_dir/busnum" || true)"
		devnum="$(read_sysfs_value "$dev_dir/devnum" || true)"
		usb_path="$dev_name"

		probe_hint="$vendor_id:$product_id
$manufacturer
$product"
		probe_type="$(probe_type_from_text "$probe_hint")"
		backend="$(probe_backend_from_sysfs "$probe_type" "$dev_dir")"

		if [[ -z "$probe_type" && "$has_lsusb" == "1" ]]; then
			if [[ "$busnum" =~ ^[0-9]+$ && "$devnum" =~ ^[0-9]+$ ]]; then
				printf -v lsusb_busnum '%03d' "$busnum"
				printf -v lsusb_devnum '%03d' "$devnum"
				verbose="$(lsusb -v -s "${lsusb_busnum}:${lsusb_devnum}" 2>/dev/null || true)"
				probe_type="$(probe_type_from_usb "$product" "$verbose")"
				if [[ -z "$serial" ]]; then
					serial="$(serial_from_verbose "$verbose")"
				fi
				if [[ "$probe_type" == "cmsis-dap" && ( -z "$backend" || "$backend" == "auto" ) ]]; then
					backend="$(probe_backend_from_usb "$probe_type" "$verbose")"
				fi
			fi
		fi
		[[ -n "$probe_type" ]] || continue
		lock_dir="$(probe_lock_dir "$probe_type" "$serial" "$usb_path")"
		busy=0
		detected_cpu="unknown"

		if ensure_lock_is_fresh "$lock_dir"; then
			busy=1
			lock_cpu="$(read_lock_value "$lock_dir" "cpu")"
			if [[ -n "$lock_cpu" ]]; then
				detected_cpu="$lock_cpu"
			fi
		elif [[ "$REFRESH_DISCOVERY" != "1" ]] && get_cached_probe_info "$probe_type" "$serial" "$usb_path" "$busnum" "$devnum" cached_cpu cached_backend; then
			detected_cpu="$cached_cpu"
			if [[ "$probe_type" == "cmsis-dap" && "$backend" == "auto" && -n "$cached_backend" ]]; then
				backend="$cached_backend"
			fi
		else
			detected_cpu="$(discover_probe_cpu "$probe_type" "$serial" "$usb_path" "$backend" "$busnum" "$devnum")"
		fi

		PROBE_TYPES+=("$probe_type")
		PROBE_SERIALS+=("$serial")
		PROBE_USB_PATHS+=("$usb_path")
		PROBE_BACKENDS+=("$backend")
		PROBE_CPUS+=("$detected_cpu")
		PROBE_BUSY+=("$busy")
		PROBE_LOCK_DIRS+=("$lock_dir")
	done
}

probe_target() {
	local adapter_type="$1"
	local serial="$2"
	local usb_path="$3"
	local backend="$4"
	local cpu="$5"
	local interface_cfg target_cfg
	local -a match_args cmd
	local output

	case "$adapter_type" in
		jlink)
			interface_cfg="interface/jlink.cfg"
			;;
		cmsis-dap)
			interface_cfg="interface/cmsis-dap.cfg"
			;;
		*)
			return 1
			;;
	esac

	case "$cpu" in
		a55)
			target_cfg="target/agic/rhea/a55.discovery.cfg"
			;;
		r908)
			target_cfg="target/agic/rhea/r908.discovery.cfg"
			;;
		*)
			return 1
			;;
	esac

	build_openocd_match_args "$serial" "$usb_path" match_args
	cmd=(
		"$OPENOCD_BIN"
		-s "$TCL_DIR"
		-c "noinit"
		-f "$interface_cfg"
		"${match_args[@]}"
		-c "adapter speed $ADAPTER_SPEED"
	)
	if [[ "$adapter_type" == "cmsis-dap" && -n "$backend" && "$backend" != "auto" ]]; then
		cmd+=(-c "cmsis-dap backend $backend")
	fi
	cmd+=(
		-f "$target_cfg"
		-c "init"
	)

	if [[ "$cpu" == "a55" ]]; then
		cmd+=(-c "dap info 0")
	fi
	cmd+=(-c "shutdown")

	set +e
	output="$(
		timeout "${PROBE_TIMEOUT_SECONDS}s" "${cmd[@]}" 2>&1
	)"
	set -e

	case "$cpu" in
		a55)
			if grep -Fq "SWD DPIDR 0x2ba01477" <<<"$output"; then
				return 0
			fi
			;;
		r908)
			if grep -Fq "JTAG tap: riscv_xuantie_cpu.cpu tap/device found: 0x10000b6f" <<<"$output"; then
				return 0
			fi
			;;
	esac

	return 1
}

discover_probe_cpu() {
	local adapter_type="$1"
	local serial="$2"
	local usb_path="$3"
	local backend="$4"
	local busnum="$5"
	local devnum="$6"
	local preferred_cpu="${7:-}"
	local detected_cpu="unknown"
	local fallback_cpu=""

	if [[ -n "$preferred_cpu" ]]; then
		if probe_target "$adapter_type" "$serial" "$usb_path" "$backend" "$preferred_cpu"; then
			detected_cpu="$preferred_cpu"
		else
			case "$preferred_cpu" in
				a55)
					fallback_cpu="r908"
					;;
				r908)
					fallback_cpu="a55"
					;;
			esac
			if [[ -n "$fallback_cpu" ]] && probe_target "$adapter_type" "$serial" "$usb_path" "$backend" "$fallback_cpu"; then
				detected_cpu="$fallback_cpu"
			fi
		fi
	else
		if probe_target "$adapter_type" "$serial" "$usb_path" "$backend" "a55"; then
			detected_cpu="a55"
		elif probe_target "$adapter_type" "$serial" "$usb_path" "$backend" "r908"; then
			detected_cpu="r908"
		fi
	fi

	write_probe_cache "$adapter_type" "$serial" "$usb_path" "$detected_cpu" "$backend" "$busnum" "$devnum"
	printf '%s' "$detected_cpu"
}

refresh_probe_cpu_for_index() {
	local index="$1"
	local preferred_cpu="${2:-}"
	local adapter_type serial usb_path backend dev_dir busnum devnum detected_cpu live_backend

	adapter_type="${PROBE_TYPES[index]}"
	serial="${PROBE_SERIALS[index]}"
	usb_path="${PROBE_USB_PATHS[index]}"
	backend="${PROBE_BACKENDS[index]}"
	dev_dir="/sys/bus/usb/devices/$usb_path"
	busnum="$(read_sysfs_value "$dev_dir/busnum" || true)"
	devnum="$(read_sysfs_value "$dev_dir/devnum" || true)"

	if [[ "$adapter_type" == "cmsis-dap" ]]; then
		live_backend="$(probe_backend_from_sysfs "$adapter_type" "$dev_dir")"
		if [[ -n "$live_backend" && "$live_backend" != "auto" ]]; then
			backend="$live_backend"
			PROBE_BACKENDS[index]="$backend"
		fi
	fi

	detected_cpu="$(discover_probe_cpu "$adapter_type" "$serial" "$usb_path" "$backend" "$busnum" "$devnum" "$preferred_cpu")"
	PROBE_CPUS[index]="$detected_cpu"
	printf '%s' "$detected_cpu"
}

print_probe_table() {
	local -a all_indexes=()
	local index

	for ((index = 0; index < ${#PROBE_TYPES[@]}; index++)); do
		all_indexes+=("$index")
	done

	print_probe_rows "${all_indexes[@]}"
}

print_probe_rows() {
	local -a row_indexes=("$@")
	local index type serial usb_path cpu
	local index_w adapter_w serial_w usb_path_w cpu_w

	index_w=5
	adapter_w=7
	serial_w=6
	usb_path_w=8
	cpu_w=12

	for index in "${row_indexes[@]}"; do
		type="${PROBE_TYPES[index]}"
		serial="${PROBE_SERIALS[index]}"
		usb_path="${PROBE_USB_PATHS[index]}"
		cpu="${PROBE_CPUS[index]}"

		[[ -n "$serial" ]] || serial="-"
		[[ -n "$usb_path" ]] || usb_path="-"

		((${#index} > index_w)) && index_w=${#index}
		((${#type} > adapter_w)) && adapter_w=${#type}
		((${#serial} > serial_w)) && serial_w=${#serial}
		((${#usb_path} > usb_path_w)) && usb_path_w=${#usb_path}
		((${#cpu} > cpu_w)) && cpu_w=${#cpu}
	done

	printf "%-${index_w}s  %-${adapter_w}s  %-${serial_w}s  %-${usb_path_w}s  %-${cpu_w}s\n" \
		"INDEX" "ADAPTER" "SERIAL" "USB_PATH" "DETECTED_CPU"
	for index in "${row_indexes[@]}"; do
		type="${PROBE_TYPES[index]}"
		serial="${PROBE_SERIALS[index]}"
		usb_path="${PROBE_USB_PATHS[index]}"
		cpu="${PROBE_CPUS[index]}"

		[[ -n "$serial" ]] || serial="-"
		[[ -n "$usb_path" ]] || usb_path="-"

		printf "%-${index_w}s  %-${adapter_w}s  %-${serial_w}s  %-${usb_path_w}s  %-${cpu_w}s\n" \
			"$index" "$type" "$serial" "$usb_path" "$cpu"
	done
}

port_in_use() {
	local port="$1"

	if command -v ss >/dev/null 2>&1; then
		ss -H -ltn "( sport = :$port )" 2>/dev/null | grep -q .
		return
	fi

	if command -v netstat >/dev/null 2>&1; then
		netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
		return
	fi

	die "missing required tool: ss or netstat"
}

check_ports_available() {
	local start_port="$1"
	local count="$2"
	local port

	for ((port = start_port; port < start_port + count; port++)); do
		if port_in_use "$port"; then
			die "port $port is already in use"
		fi
	done
}

select_probe_interactively() {
	local -a candidate_indexes=("$@")
	local idx choice

	[[ -t 0 && -t 1 ]] || die "multiple matching probes found; rerun with --adapter-serial"

	echo "Multiple matching probes found:"
	print_probe_rows "${candidate_indexes[@]}"

	while true; do
		read -r -p "Select probe index: " choice
		[[ "$choice" =~ ^[0-9]+$ ]] || {
			echo "Invalid index: $choice" >&2
			continue
		}
		for idx in "${candidate_indexes[@]}"; do
			if [[ "$idx" == "$choice" ]]; then
				printf '%s' "$choice"
				return
			fi
		done
		echo "Index not in candidate list: $choice" >&2
	done
}

find_selected_probe() {
	local wanted_cpu="$1"
	local -a scope_indexes=()
	local -a candidate_indexes=()
	local -a verified_indexes=()
	local index selected_count busy_match=0 busnum devnum

	for ((index = 0; index < ${#PROBE_TYPES[@]}; index++)); do
		if [[ -n "$ADAPTER_SERIAL" && "${PROBE_SERIALS[index]}" != "$ADAPTER_SERIAL" ]]; then
			continue
		fi

		if [[ "${PROBE_BUSY[index]}" == "1" ]]; then
			if [[ "${PROBE_CPUS[index]}" == "$wanted_cpu" ]]; then
				busy_match=1
			fi
			continue
		fi

		scope_indexes+=("$index")
		if [[ "${PROBE_CPUS[index]}" == "$wanted_cpu" ]]; then
			candidate_indexes+=("$index")
		fi
	done

	if [[ "${#candidate_indexes[@]}" -eq 0 ]]; then
		for index in "${scope_indexes[@]}"; do
			if [[ "$(refresh_probe_cpu_for_index "$index" "$wanted_cpu")" == "$wanted_cpu" ]]; then
				candidate_indexes+=("$index")
			fi
		done
	fi

	if [[ "${#candidate_indexes[@]}" -gt 0 ]]; then
		for index in "${candidate_indexes[@]}"; do
			if probe_target "${PROBE_TYPES[index]}" "${PROBE_SERIALS[index]}" "${PROBE_USB_PATHS[index]}" "${PROBE_BACKENDS[index]}" "$wanted_cpu"; then
				busnum="$(read_sysfs_value "/sys/bus/usb/devices/${PROBE_USB_PATHS[index]}/busnum" || true)"
				devnum="$(read_sysfs_value "/sys/bus/usb/devices/${PROBE_USB_PATHS[index]}/devnum" || true)"
				write_probe_cache "${PROBE_TYPES[index]}" "${PROBE_SERIALS[index]}" "${PROBE_USB_PATHS[index]}" "$wanted_cpu" "${PROBE_BACKENDS[index]}" "$busnum" "$devnum"
				PROBE_CPUS[index]="$wanted_cpu"
				verified_indexes+=("$index")
			else
				refresh_probe_cpu_for_index "$index" "$wanted_cpu" >/dev/null
			fi
		done
		candidate_indexes=("${verified_indexes[@]}")
	fi

	if [[ "${#candidate_indexes[@]}" -eq 0 ]]; then
		for index in "${scope_indexes[@]}"; do
			if [[ "${PROBE_CPUS[index]}" == "$wanted_cpu" ]]; then
				candidate_indexes+=("$index")
				continue
			fi
			if [[ "$(refresh_probe_cpu_for_index "$index" "$wanted_cpu")" == "$wanted_cpu" ]]; then
				candidate_indexes+=("$index")
			fi
		done
	fi

	selected_count="${#candidate_indexes[@]}"
	if [[ "$selected_count" -eq 0 ]]; then
		if [[ -n "$ADAPTER_SERIAL" ]]; then
			for ((index = 0; index < ${#PROBE_TYPES[@]}; index++)); do
				if [[ "${PROBE_SERIALS[index]}" == "$ADAPTER_SERIAL" && "${PROBE_BUSY[index]}" == "1" ]]; then
					die "probe $ADAPTER_SERIAL is already in use"
				fi
			done
		fi

		if [[ "$busy_match" == "1" ]]; then
			die "all matching probes for cpu $wanted_cpu are already in use"
		fi

		if [[ -n "$ADAPTER_SERIAL" ]]; then
			die "no matching probe found for serial $ADAPTER_SERIAL and cpu $wanted_cpu"
		fi
		die "no matching probe found for cpu $wanted_cpu"
	fi

	if [[ "$selected_count" -eq 1 ]]; then
		printf '%s' "${candidate_indexes[0]}"
		return
	fi

	if [[ -n "$ADAPTER_SERIAL" ]]; then
		die "multiple probes matched serial $ADAPTER_SERIAL and cpu $wanted_cpu"
	fi

	select_probe_interactively "${candidate_indexes[@]}"
}

acquire_probe_lock() {
	local selected_index="$1"
	local target_cpu="$2"
	local gdb_start="$3"
	local gdb_end="$4"
	local adapter_type serial usb_path lock_dir owner_pid

	adapter_type="${PROBE_TYPES[selected_index]}"
	serial="${PROBE_SERIALS[selected_index]}"
	usb_path="${PROBE_USB_PATHS[selected_index]}"
	lock_dir="${PROBE_LOCK_DIRS[selected_index]}"

	mkdir -p "$RUNTIME_DIR"

	if ensure_lock_is_fresh "$lock_dir"; then
		die "probe ${serial:-$usb_path} is already in use"
	fi

	if ! mkdir "$lock_dir" 2>/dev/null; then
		if ensure_lock_is_fresh "$lock_dir"; then
			die "probe ${serial:-$usb_path} is already in use"
		fi
		if ! mkdir "$lock_dir" 2>/dev/null; then
			die "failed to lock probe ${serial:-$usb_path}"
		fi
	fi

	HELD_LOCK_DIR="$lock_dir"
	cat >"$lock_dir/metadata" <<EOF
owner_pid=$$
adapter_type=$adapter_type
serial=$serial
usb_path=$usb_path
cpu=$target_cpu
gdb_port_start=$gdb_start
gdb_port_end=$gdb_end
EOF
}

launch_openocd() {
	local selected_index="$1"
	local target_cpu="$2"
	local core_count="$3"
	local gdb_start="$4"
	local adapter_type serial usb_path backend interface_cfg target_cfg port_count port_end
	local -a match_args cmd

	adapter_type="${PROBE_TYPES[selected_index]}"
	serial="${PROBE_SERIALS[selected_index]}"
	usb_path="${PROBE_USB_PATHS[selected_index]}"
	backend="${PROBE_BACKENDS[selected_index]}"

	case "$adapter_type" in
		jlink)
			interface_cfg="interface/jlink.cfg"
			;;
		cmsis-dap)
			interface_cfg="interface/cmsis-dap.cfg"
			;;
		*)
			die "unsupported adapter type: $adapter_type"
			;;
	esac

	case "$target_cpu" in
		a55)
			target_cfg="target/agic/rhea/a55.Xcore.cfg"
			port_count="$core_count"
			;;
		r908)
			target_cfg="target/agic/rhea/r908.cfg"
			port_count=1
			;;
		*)
			die "unsupported target cpu: $target_cpu"
			;;
	esac

	port_end=$((gdb_start + port_count - 1))
	build_openocd_match_args "$serial" "$usb_path" match_args

	echo "Selected probe:"
	echo "  adapter_type: $adapter_type"
	echo "  serial: ${serial:-<none>}"
	echo "  usb_path: ${usb_path:-<none>}"
	echo "  cpu: $target_cpu"
	echo "  adapter_speed: ${ADAPTER_SPEED} kHz"
	if [[ "$port_count" -eq 1 ]]; then
		echo "  gdb_port: $gdb_start"
	else
		echo "  gdb_ports: $gdb_start-$port_end"
		echo "  a55_core_count: $core_count"
	fi

	cmd=(
		"$OPENOCD_BIN"
		-s "$TCL_DIR"
		-f "$interface_cfg"
		"${match_args[@]}"
		-c "adapter speed $ADAPTER_SPEED"
		-c "gdb port $gdb_start"
	)
	if [[ "$adapter_type" == "cmsis-dap" && -n "$backend" && "$backend" != "auto" ]]; then
		cmd+=(-c "cmsis-dap backend $backend")
	fi

	if [[ "$target_cpu" == "a55" ]]; then
		cmd+=(-c "set CORE_COUNT $core_count; puts -nonewline \"\"")
	fi
	cmd+=(-f "$target_cfg")

	acquire_probe_lock "$selected_index" "$target_cpu" "$gdb_start" "$port_end"

	trap 'forward_signal_to_child TERM; cleanup_and_exit 143' TERM
	trap 'forward_signal_to_child INT; cleanup_and_exit 130' INT
	trap 'forward_signal_to_child HUP; cleanup_and_exit 129' HUP
	trap 'release_probe_lock' EXIT

	"${cmd[@]}" &
	OPENOCD_CHILD_PID="$!"
	printf 'openocd_pid=%s\n' "$OPENOCD_CHILD_PID" >>"$HELD_LOCK_DIR/metadata"

	set +e
	wait "$OPENOCD_CHILD_PID"
	rc=$?
	set -e

	OPENOCD_CHILD_PID=""
	cleanup_and_exit "$rc"
}

main() {
	local wanted_cpu selected_index core_count port_count launch_port

	parse_args "$@"
	require_linux
	require_tool timeout
	validate_cpu_arg
	resolve_openocd

	enumerate_probes

	if [[ "$MODE" == "list" ]]; then
		print_probe_table
		exit 0
	fi

	if [[ "$CPU_ARG" == "r908" ]]; then
		wanted_cpu="r908"
		core_count=1
		launch_port="${GDB_PORT:-$DEFAULT_R908_GDB_PORT}"
		check_ports_available "$launch_port" 1
	else
		wanted_cpu="a55"
		core_count="${CPU_ARG#a55:}"
		port_count="$core_count"
		launch_port="${GDB_PORT:-$DEFAULT_A55_GDB_PORT_BASE}"
		check_ports_available "$launch_port" "$port_count"
	fi

	selected_index="$(find_selected_probe "$wanted_cpu")"
	launch_openocd "$selected_index" "$wanted_cpu" "$core_count" "$launch_port"
}

main "$@"
