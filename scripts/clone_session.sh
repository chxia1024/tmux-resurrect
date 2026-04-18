#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/process_restore_helpers.sh"
source "$CURRENT_DIR/spinner_helpers.sh"

# delimiters
d=$'\t'
delimiter=$'\t'

pane_format() {
	local format
	format+="pane"
	format+="${delimiter}"
	format+="#{session_name}"
	format+="${delimiter}"
	format+="#{window_index}"
	format+="${delimiter}"
	format+=":#{window_name}"
	format+="${delimiter}"
	format+="#{window_active}"
	format+="${delimiter}"
	format+=":#{window_flags}"
	format+="${delimiter}"
	format+="#{pane_index}"
	format+="${delimiter}"
	format+=":#{pane_current_path}"
	format+="${delimiter}"
	format+="#{pane_active}"
	format+="${delimiter}"
	format+="#{pane_current_command}"
	format+="${delimiter}"
	format+="#{pane_pid}"
	format+="${delimiter}"
	format+="#{history_size}"
	echo "$format"
}

window_format() {
	local format
	format+="window"
	format+="${delimiter}"
	format+="#{session_name}"
	format+="${delimiter}"
	format+="#{window_index}"
	format+="${delimiter}"
	format+="#{window_active}"
	format+="${delimiter}"
	format+=":#{window_flags}"
	format+="${delimiter}"
	format+="#{window_layout}"
	echo "$format"
}

list_all_panes() {
	tmux list-panes -a -F "$(pane_format)"
}

list_all_windows(){
	tmux list-windows -a -F "$(window_format)"
}

toggle_window_zoom() {
	local target="$1"
	tmux resize-pane -Z -t "$target"
}

pane_full_command() {
	local pane_pid="$1"
	local strategy_file="$(_save_command_strategy_file)"
	# execute strategy script to get pane full command
	$strategy_file "$pane_pid"
}

_save_command_strategy_file() {
	local save_command_strategy="$(get_tmux_option "$save_command_strategy_option" "$default_save_command_strategy")"
	local strategy_file="$CURRENT_DIR/../save_command_strategies/${save_command_strategy}.sh"
	local default_strategy_file="$CURRENT_DIR/../save_command_strategies/${default_save_command_strategy}.sh"
	if [ -e "$strategy_file" ]; then # strategy file exists?
		echo "$strategy_file"
	else
		echo "$default_strategy_file"
	fi
}

clone_all_panes() {
	local source_session=$1
	local dest_session=$2
	local full_command
	list_all_panes |
	while IFS=$d read line_type session_name window_number window_name window_active window_flags pane_index dir pane_active pane_command pane_pid history_size; do
		if [ $session_name == $source_session ] ; then
			full_command="$(pane_full_command $pane_pid)"
			clone_pane ${dest_session} ${window_number} ${window_name} ${window_active} ${window_flags} ${pane_index} ${dir} ${pane_active} ${pane_command} ":${full_command}"
		fi
	done
}

clone_window_layout() {
	source_session=$1
	dest_session=$2
	list_all_windows |
	while IFS=$d read line_type session_name window_index window_active window_flags window_layout; do
		if [ $session_name == $source_session ] ; then
			# window_layout is not correct for zoomed windows
			if [[ "$window_flags" == *Z* ]]; then
				# unmaximize the window
				toggle_window_zoom "${session_name}:${window_index}"
				# get correct window layout
				window_layout="$(tmux display-message -p -t "${session_name}:${window_index}" -F "#{window_layout}")"
				# sleep required otherwise vim does not redraw correctly, issue #112
				sleep 0.1 || sleep 1 # portability hack
				# maximize window again
				toggle_window_zoom "${session_name}:${window_index}"
			fi
			# reset layout based on source
			reset_pane_layout_for_window ${dest_session} ${window_index} ${window_layout}
		fi
	done
}

pane_exists() {
	local session_name="$1"
	local window_number="$2"
	local pane_index="$3"
	tmux list-panes -t "${session_name}:${window_number}" -F "#{pane_index}" 2>/dev/null |
	\grep -q "^$pane_index$"
}

window_exists() {
	local session_name="$1"
	local window_number="$2"
	tmux list-windows -t "$session_name" -F "#{window_index}" 2>/dev/null |
	\grep -q "^$window_number$"
}

session_exists() {
	local session_name="$1"
	tmux has-session -t "$session_name" 2>/dev/null
}

first_window_num() {
	tmux show -gv base-index
}

tmux_socket() {
	echo $TMUX | cut -d',' -f1
}

new_window() {
	local session_name="$1"
	local window_number="$2"
	local window_name="$3"
	local dir="$4"
	local pane_index="$5"
	local pane_id="${session_name}:${window_number}.${pane_index}"
	tmux new-window -d -t "${session_name}:${window_number}" -n "$window_name" -c "$dir"
}

new_session() {
	local session_name="$1"
	local window_number="$2"
	local window_name="$3"
	local dir="$4"
	local pane_index="$5"
	local pane_id="${session_name}:${window_number}.${pane_index}"
	TMUX="" tmux -S "$(tmux_socket)" new-session -d -s "$session_name" -n "$window_name" -c "$dir"
	# change first window number if necessary
	local created_window_num="$(first_window_num)"
	if [ $created_window_num -ne $window_number ]; then
		tmux move-window -s "${session_name}:${created_window_num}" -t "${session_name}:${window_number}"
	fi
}

new_pane() {
	local session_name="$1"
	local window_number="$2"
	local window_name="$3"
	local dir="$4"
	local pane_index="$5"
	local pane_id="${session_name}:${window_number}.${pane_index}"
	tmux split-window -t "${session_name}:${window_number}" -c "$dir"
	# minimize window so more panes can fit
	tmux resize-pane  -t "${session_name}:${window_number}" -U "999"
}

clone_pane() {
	local session_name="$1" #dest session to clone to
	local window_number="$2"
	local window_name="$3"
	local window_active="$4"
	local window_flags="$5"
	local pane_index="$6"
	local dir="$7"
	local pane_active="$8"
	local pane_command="$9"
	local pane_full_command="${10}"
	dir="$(remove_first_char "$dir")"
	window_name="$(remove_first_char "$window_name")"
	pane_full_command="$(remove_first_char "$pane_full_command")"
	# new pane
	if pane_exists "$session_name" "$window_number" "$pane_index"; then
		# Pane exists, no need to create it!
		# Pane existence is registered. Later, its process also won't be restored.
		register_existing_pane "$session_name" "$window_number" "$pane_index"
	elif window_exists "$session_name" "$window_number"; then
		new_pane "$session_name" "$window_number" "$window_name" "$dir" "$pane_index"
	elif session_exists "$session_name"; then
		new_window "$session_name" "$window_number" "$window_name" "$dir" "$pane_index"
	else
		new_session "$session_name" "$window_number" "$window_name" "$dir" "$pane_index"
	fi
	# restore process
	restore_pane_process "$pane_full_command" "$session_name" "$window_number" "$pane_index" "$dir"
}

reset_pane_layout_for_window() {
	local session_name=$1 #dest session
	local window_number=$2
	local window_layout=$3
	tmux select-layout -t "${session_name}:${window_number}" "$window_layout"
}

clone_session() {
	local source_session=$1
	local dest_session=$2
	start_spinner "Clone a session $dest_session based on panes and layout of $source_session"
	clone_all_panes $source_session $dest_session
	clone_window_layout $source_session $dest_session
	stop_spinner
	display_message "New session "$dest_session" cloned!"
}

main() {
	local source_session=$1
	local dest_session=$2

	if ! session_exists ${source_session}; then
		display_message "Source session "$source_session" does not exist"
		exit 1
	fi

	if session_exists ${dest_session}; then
		display_message "Dest session "$dest_session" already exists"
		exit 1
	fi

	if supported_tmux_version_ok ; then
		clone_session $source_session $dest_session
	fi
}

if [ $# -ne 2 ] ; then
	echo -e "\n\
	Usage: $# $(basename $0) source_session dest_session \n"
	exit 1
fi
main $1 $2
