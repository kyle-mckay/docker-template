#!/bin/bash
#
# Script Name: template_bootstrap.sh
# Purpose: This is a placeholder script. Its sole function is to download
#          the full 'template.sh' from the kyle-mckay/docker-compose-templates
#          repository and replace itself, effectively initializing the tool.
#
# Usage:
#   1. Make this script executable: chmod +x template_bootstrap.sh
#   2. Run the initialization command: ./template_bootstrap.sh init

# --- Configuration ---
REPO_URL="https://raw.githubusercontent.com/kyle-mckay/docker-compose-templates/main/template.sh"
# Use $0 to get the name of the script currently being executed, ensuring it replaces itself.
CURRENT_SCRIPT_PATH="$0"
TEMP_FILE="/tmp/template_download_$$" # Use $$ for a unique process ID in the temporary filename

# Function to display error and usage instructions
display_usage_and_exit() {
    echo "ERROR: Missing required argument."
    echo ""
    echo "Usage: ${CURRENT_SCRIPT_PATH} init"
    echo ""
    echo "This is the initial bootstrap script. Run with 'init' to download the full, functional version."
    exit 1
}

# --- Main Logic ---

# 1. Force the use of 'init' argument
if [ "$1" != "init" ]; then
    display_usage_and_exit
fi

echo "Starting initialization process..."
echo "Downloading the full script from the repository..."
echo "Target URL: ${REPO_URL}"

# 2. Download the full script using curl or wget
if command -v curl >/dev/null 2>&1; then
    # Use curl if available
    if ! curl -fsSL "${REPO_URL}" -o "${TEMP_FILE}"; then
        echo "ERROR: Failed to download the file using curl."
        rm -f "${TEMP_FILE}"
        exit 2
    fi
elif command -v wget >/dev/null 2>&1; then
    # Use wget if curl is not available
    if ! wget -qO "${TEMP_FILE}" "${REPO_URL}"; then
        echo "ERROR: Failed to download the file using wget."
        rm -f "${TEMP_FILE}"
        exit 2
    fi
else
    # Neither curl nor wget found
    echo "ERROR: Neither 'curl' nor 'wget' could be found. Cannot download the script."
    exit 3
fi

# 3. Replace the current script with the newly downloaded file
echo "Replacing ${CURRENT_SCRIPT_PATH} with the new content..."
if mv "${TEMP_FILE}" "${CURRENT_SCRIPT_PATH}"; then
    # 4. Ensure the replacement script is executable
    chmod +x "${CURRENT_SCRIPT_PATH}"

    echo ""
    echo "--------------------------------------------------------"
    echo "SUCCESS: Initialization complete!"
    echo "The full 'template.sh' script has been downloaded and now replaces this bootstrap script."
    echo ""
    echo "You can now run it without the 'init' argument (e.g., './${CURRENT_SCRIPT_PATH} help')."
    echo "--------------------------------------------------------"
    exit 0
else
    echo "ERROR: Failed to replace the current script (${CURRENT_SCRIPT_PATH})."
    echo "The downloaded file is still available at ${TEMP_FILE}."
    exit 4
fi
