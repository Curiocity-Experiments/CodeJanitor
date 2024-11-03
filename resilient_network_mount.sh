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

# Configuration - Let's keep everything up here so it's easy to tweak when needed
NETWORK_DRIVES=(
    "smb://server1/share1 /Volumes/share1 username password"
    "smb://server2/share2 /Volumes/share2 username password"
)

# Credentials (hardcoded for a fully self-contained solution - change these as needed)
USERNAME="your_username_here"
PASSWORD="your_password_here"

# Settings for handling disconnects and retries
max_disconnects=10          # Max number of disconnects before we call it quits
threshold_disconnects=5     # Number of retries before we decide it's time to stop trying
max_sleep_time=1800         # Cap sleep time at 30 minutes, no need to wait forever
initial_sleep_time=300      # Start with a 5-minute wait period

failed_attempts=0           # Count how many times we fail
disconnect_count=0          # Count consecutive disconnects

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
        return 0  # Server's reachable
    else
        return 1  # No luck reaching the server
    fi
}

# Function to mount a network drive
# Create the mount point if it doesn't exist and then mount the drive
mount_drive() {
    server_path=$1
    mount_point=$2

    # Make the mount point if it doesn't already exist
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
    fi

    # Go ahead and mount the drive using the given credentials
    mount -t smbfs "//$USERNAME:$PASSWORD@${server_path#*//}" "$mount_point"
}

# Main loop - Keep checking and reconnecting if needed
# This loop runs forever but tries not to be too wasteful on resources
while (( disconnect_count <= max_disconnects )); do
    if (( disconnect_count > threshold_disconnects )); then
        echo "$(date): Too many disconnects. Exiting..."
        exit 1  # If we keep failing, time to gracefully shut it down
    fi

    for drive in "${NETWORK_DRIVES[@]}"; do
        read -r server_path mount_point username password <<< "$drive"

        # Check if we can reach the network before trying to mount
        if ! check_network_access "$server_path"; then
            echo "$(date): Network inaccessible for $server_path, skipping..."
            ((disconnect_count++))
            continue
        fi

        disconnect_count=0  # Reset disconnect count if the network is accessible

        # If the drive isn't mounted, try to mount it
        if ! check_mount "$mount_point"; then
            echo "$(date): $mount_point is not mounted. Attempting to reconnect..."
            mount_drive "$server_path" "$mount_point"
            
            # Check if the mount succeeded
            if check_mount "$mount_point"; then
                echo "$(date): Successfully reconnected $mount_point"
                failed_attempts=0  # Reset failed attempts counter after success
            else
                echo "$(date): Failed to reconnect $mount_point"
                ((failed_attempts++))
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

