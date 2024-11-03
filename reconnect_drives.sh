#!/bin/bash

# Instructions - How to gather the required information:
# 1. NETWORK_DRIVES: You need the network path (e.g., smb://server/share) and the local mount point (e.g., /Volumes/share). Make sure you have proper permissions.
#    - Example: "smb://server1/share1 /Volumes/share1 username password"
#    - Replace 'username' and 'password' with the credentials for accessing the network share.
# 2. USERNAME and PASSWORD: These are the credentials for accessing the network shares. If you need different credentials for different drives,
#    you can modify the NETWORK_DRIVES array accordingly or hardcode a single set of credentials here.
# 3. Mount Points: If the laptop is on a different network and cannot connect, the mount points won't be accessible.
#    - In this case, the script will automatically create the mount point directory if it doesn't exist.
#    - However, if the network is unavailable, the script will skip attempting to mount until the network is accessible again.
#
# Where to keep this script and how to set it up:
# - Save this script in a secure location on your machine, such as:
#   - ~/reconnect_drives.sh
# - Make the script executable by running:
#   - chmod +x ~/reconnect_drives.sh
# - Ensure you have a directory for logs by creating it if it doesn't exist:
#   - mkdir -p ~/logs
# - To run the script automatically at startup, you can add it to your crontab or include it in your system's startup scripts.
#   - Example crontab entry (edit with crontab -e):
#     @reboot ~/reconnect_drives.sh &
#
# - Alternatively, you can use the following methods:
#   1. Run the script in the background using `nohup`:
#      - nohup /path/to/reconnect_drives.sh > ~/logs/reconnect_drives.log 2>&1 &
#        This will run the script in the background and store all logs in the specified file for easy debugging.
#
#   2. Set up a LaunchAgent to run the script automatically on startup for macOS:
#      - To create the .plist file in one step, use the following command:
#        cat <<EOF > ~/Library/LaunchAgents/com.user.reconnectdrives.plist
#        <?xml version="1.0" encoding="UTF-8"?>
#        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
#        <plist version="1.0">
#        <dict>
#            <key>Label</key>
#            <string>com.user.reconnectdrives</string>
#            <key>ProgramArguments</key>
#            <array>
#                <string>/path/to/reconnect_drives.sh</string>
#            </array>
#            <key>RunAtLoad</key>
#            <true/>
#            <key>KeepAlive</key>
#            <true/>
#        </dict>
#        </plist>
#        EOF
#      - Load the LaunchAgent using:
#        launchctl load ~/Library/LaunchAgents/com.user.reconnectdrives.plist
#      - To prevent potential issues with repeated failures, consider adding a delay or condition in the script to ensure it runs only when necessary.

# Configuration - Let's keep everything up here so it's easy to tweak when needed
NETWORK_DRIVES=(
    "smb://server1/share1 /Volumes/share1 username password"
    "smb://server2/share2 /Volumes/share2 username password"
)

# Settings for handling disconnects and retries
max_disconnects=10          # Max number of disconnects before we call it quits
threshold_disconnects=5     # Number of retries before we decide it's time to stop trying
max_sleep_time=300          # Cap sleep time at 5 minutes, no need to wait forever
initial_sleep_time=30       # Start with a 30-second wait period
adaptive_threshold=3        # Number of adaptive disconnect attempts for more granular recovery handling
failed_attempts=0           # Count how many times we fail
disconnect_count=0          # Count consecutive disconnects
network_errors=0            # Track specific network errors
mount_errors=0              # Track specific mount errors
manual_exit_flag=false      # Flag to allow manual intervention for stopping the script

# Function to check if a mount point is already mounted
# Only mount drives that aren't already mounted - no double work
check_mount() {
    mount_point=$1
    if ! mount | grep -q "$mount_point"; then
        return 1  # Nope, not mounted
    fi
    return 0  # Yep, it's mounted
}

# Function to check network accessibility before trying to mount
# Saves time by avoiding mount attempts if there's no network
check_network_access() {
    server_path=$1
    server=${server_path#*//}  # Strip off 'smb://' part
    server=${server%%/*}       # Just get the server address

    # Check if the SMB port (port 445) is open on the server
    if nc -z -w 2 "$server" 445 > /dev/null 2>&1; then
        return 0  # Server is reachable
    else
        return 1  # No luck reaching the server
    fi
}

# Function to mount a network drive
# Create the mount point if it doesn't exist and then mount the drive securely
mount_drive() {
    server_path=$1
    mount_point=$2
    username=$3
    password=$4

    # Make the mount point if it doesn't already exist
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
    fi

    # Use a credentials file temporarily to avoid exposing passwords in process lists
    credentials_file="/tmp/smb_credentials"
    echo "username=$username" > "$credentials_file"
    echo "password=$password" >> "$credentials_file"
    chmod 600 "$credentials_file"

    # Go ahead and mount the drive using the temporary credentials file
    mount_smbfs -o credentials="$credentials_file" "$server_path" "$mount_point" > /dev/null 2>&1

    # Clean up the credentials file
    rm -f "$credentials_file"
}

# Function to handle manual exit
# This allows for graceful termination if the script needs to be stopped manually
check_manual_exit() {
    if [ -f "/tmp/stop_network_mount" ]; then
        echo "$(date): Manual exit flag detected. Exiting..."
        rm -f /tmp/stop_network_mount
        exit 0
    fi
}

# Main loop - Keep checking and reconnecting if needed
# This loop runs forever but tries not to be too wasteful on resources
while (( disconnect_count <= max_disconnects )); do
    check_manual_exit  # Check if manual exit is requested

    # Adaptive exit strategy based on error type
    if (( network_errors > adaptive_threshold )); then
        echo "$(date): Too many network errors. Exiting..."
        exit 1
    elif (( mount_errors > adaptive_threshold )); then
        echo "$(date): Too many mount errors. Exiting..."
        exit 1
    elif (( disconnect_count > threshold_disconnects )); then
        echo "$(date): Too many disconnects. Exiting..."
        exit 1
    fi

    for drive in "${NETWORK_DRIVES[@]}"; do
        read -r server_path mount_point username password <<< "$drive"

        # Check if we can reach the network before trying to mount
        if ! check_network_access "$server_path"; then
            echo "$(date): Network inaccessible for $server_path, skipping..."
            ((disconnect_count++))
            ((network_errors++))
            continue
        fi

        disconnect_count=0  # Reset disconnect count if the network is accessible

        # If the drive isn't mounted, try to mount it
        if ! check_mount "$mount_point"; then
            echo "$(date): $mount_point is not mounted. Attempting to reconnect..."
            mount_drive "$server_path" "$mount_point" "$username" "$password"

            # Check if the mount succeeded
            if check_mount "$mount_point"; then
                echo "$(date): Successfully reconnected $mount_point"
                failed_attempts=0  # Reset failed attempts counter after success
                mount_errors=0     # Reset mount errors after success
            else
                echo "$(date): Failed to reconnect $mount_point"
                ((failed_attempts++))
                ((mount_errors++))
            fi
        fi
    done

    # Adjust sleep time if we keep failing
    if (( failed_attempts > 0 )); then
        sleep_time=$((initial_sleep_time * failed_attempts))
        if (( sleep_time > max_sleep_time )); then
            sleep_time=$max_sleep_time  # Cap the sleep time so we don't wait too long
        fi
        echo "$(date): Waiting for $sleep_time seconds due to repeated failures..."
        sleep "$sleep_time"
    else
        sleep $initial_sleep_time  # Default wait time of 5 minutes if all is well
    fi

done

# If we hit the max disconnects, log it and exit
echo "$(date): Maximum disconnect attempts reached. Script exiting."
