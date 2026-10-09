#!/bin/sh
# Run as root to set password for 'chris' post-rebuild

USERNAME="chris"
PASSWORD_FILE="/home/$USERNAME/.config/chris-password"

sudo chown -R  chris:chris /home/chris/.config/

# Check if password file exists
if [ ! -f "$PASSWORD_FILE" ]; then
    echo "Error: Password file $PASSWORD_FILE not found!"
    exit 1
fi


# Read the hashed password from the file
HASHED_PASSWORD=$(cat "$PASSWORD_FILE")

# Verify the hash format (starts with $6$)
if ! echo "$HASHED_PASSWORD" | grep -q '^\$6\$'; then
    echo "Error: Password file does not contain a valid SHA-512 hash!"
    exit 1
fi

# Update the password in /etc/shadow
echo "$USERNAME:$HASHED_PASSWORD" | sudo chpasswd -e && \
    echo "Password updated successfully for $USERNAME." || \
    echo "Error: Failed to set password."
