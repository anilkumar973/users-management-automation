#!/usr/bin/env bash
#
# create_users.sh
#
# Purpose: Read a file with lines of the form:
#    username;group1,group2
# and ensure each user exists, is added to the listed groups,
# has a home directory, a generated 12-char password, and that
# credentials are saved securely. Actions are logged.
#
# Usage: sudo ./create_users.sh users.txt
#
# Notes:
# - Lines starting with '#' or blank lines are skipped.
# - Whitespace around tokens is ignored.
# - Run as root (script checks for this).
#
set -o errexit
set -o nounset
set -o pipefail

INPUT_FILE="${1:-}"

# Files/directories used
PW_DIR="/mnt/c/Users/anil 1/OneDrive/Desktop/user management automation"
PW_FILE="${PW_DIR}/user_passwords.txt"
LOG_FILE="/mnt/c/Users/anil 1/OneDrive/Desktop/user management automation/user_management.log"



# Utilities
TIMESTAMP() { date '+%Y-%m-%d %H:%M:%S'; }

log_info() {
  local msg="$1"
  echo "$(TIMESTAMP) [INFO] ${msg}" | tee -a "$LOG_FILE"
}

log_error() {
  local msg="$1"
  echo "$(TIMESTAMP) [ERROR] ${msg}" | tee -a "$LOG_FILE" >&2
}

log_skip() {
  local msg="$1"
  echo "$(TIMESTAMP) [SKIP] ${msg}" | tee -a "$LOG_FILE"
}

# Ensure we are root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Use sudo." >&2
  exit 2
fi

# Validate input
if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
  echo "Usage: $0 /path/to/users_file" >&2
  exit 3
fi

# Ensure directories/files exist with secure permissions
mkdir -p "$PW_DIR"
chown root:root "$PW_DIR"
chmod 700 "$PW_DIR"

touch "$PW_FILE"
chown root:root "$PW_FILE"
chmod 600 "$PW_FILE"

touch "$LOG_FILE"
chown root:root "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Function: trim leading/trailing whitespace
trim() {
  local var="$*"
  # remove leading/trailing whitespace
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

# Function: generate a random 12-character password (alphanumeric)
generate_password() {
  # use /dev/urandom and restrict to alphanumeric to avoid shell/log issues
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || head -c 12 </dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12
}

# Process the input file line by line
while IFS= read -r rawline || [ -n "$rawline" ]; do
  # Remove leading/trailing whitespace for the whole line
  line="$(trim "$rawline")"

  # Skip empty lines and comments
  if [ -z "$line" ]; then
    continue
  fi
  case "$line" in
    \#*) log_skip "Line skipped (comment): $line"; continue ;;
  esac

  # Split into username and groups by first ';'
  IFS=';' read -r user part_groups <<<"$line"

  user="$(trim "$user")"
  part_groups="${part_groups:-}"    # may be empty
  # Remove spaces around commas and around names, then remove stray spaces
  # Transform " sudo, dev " -> "sudo,dev"
  groups="$(echo "$part_groups" | tr -d '[:space:]' | sed 's/^,//; s/,$//')"

  # Validate username (non-empty)
  if [ -z "$user" ]; then
    log_error "Empty username in line: $rawline"
    continue
  fi

  # If groups field ends up as empty string, set to empty
  if [ -z "$groups" ] || [ "$groups" = "" ]; then
    group_list=()
  else
    # Convert comma-separated string into array
    IFS=',' read -r -a group_list <<<"$groups"
  fi

  # Create any missing groups first
  for grp in "${group_list[@]:-}"; do
    if getent group "$grp" >/dev/null; then
      log_info "Group exists: $grp"
    else
      if groupadd "$grp" 2>/dev/null; then
        log_info "Created group: $grp"
      else
        log_error "Failed to create group: $grp (continuing)"
      fi
    fi
  done

  # Check if user exists
  if id -u "$user" >/dev/null 2>&1; then
    log_info "User already exists: $user"
    # Ensure home exists
    HOME_DIR="/home/$user"
    if [ ! -d "$HOME_DIR" ]; then
      if mkdir -p "$HOME_DIR" && chown "$user":"$user" "$HOME_DIR" && chmod 700 "$HOME_DIR"; then
        log_info "Created missing home dir for existing user: $HOME_DIR"
      else
        log_error "Failed to create home dir $HOME_DIR for existing user $user"
      fi
    fi

    # Add to groups (append)
    if [ "${#group_list[@]}" -gt 0 ]; then
      # usermod -aG expects comma separated
      comma_groups="$(IFS=, ; echo "${group_list[*]}")"
      if usermod -a -G "$comma_groups" "$user" 2>/dev/null; then
        log_info "Added user $user to groups: $comma_groups"
      else
        log_error "Failed to add user $user to groups: $comma_groups"
      fi
    fi

  else
    # Build useradd command
    if [ "${#group_list[@]}" -gt 0 ]; then
      comma_groups="$(IFS=, ; echo "${group_list[*]}")"
      if useradd -m -s /bin/bash -G "$comma_groups" "$user" 2>/dev/null; then
        log_info "Created user: $user (groups: $comma_groups)"
      else
        log_error "Failed to create user $user with groups $comma_groups"
        continue
      fi
    else
      if useradd -m -s /bin/bash "$user" 2>/dev/null; then
        log_info "Created user: $user"
      else
        log_error "Failed to create user $user"
        continue
      fi
    fi

    # Set home permissions
    HOME_DIR="/home/$user"
    if [ -d "$HOME_DIR" ]; then
      chown "$user":"$user" "$HOME_DIR" || log_error "chown failed on $HOME_DIR"
      chmod 700 "$HOME_DIR" || log_error "chmod failed on $HOME_DIR"
    else
      log_error "Home directory $HOME_DIR missing after creation for $user"
    fi
  fi

  # Generate password and set it
  pw="$(generate_password)"
  if printf '%s:%s\n' "$user" "$pw" | chpasswd 2>/dev/null; then
    # Save username:password to password store (append; keep secure perms)
    printf '%s:%s\n' "$user" "$pw" >>"$PW_FILE"
    chown root:root "$PW_FILE"
    chmod 600 "$PW_FILE"
    log_info "Password set and stored for user: $user"
  else
    log_error "Failed to set password for user: $user"
    continue
  fi

done <"$INPUT_FILE"

log_info "Processing complete for file: $INPUT_FILE"
exit 0
