#!/bin/bash
#
# Script Name: get-tempaltes.sh
# Purpose: Its sole function is to download a copy of my personal compose templates
#          from kyle-mckay/docker-compose-templates
#
# Usage:
#   1. Make this script executable: chmod +x tempaltes.sh
#   2. Run the initialization command: ./tempaltes.sh

# --- Configuration ---
REPO_URL="https://raw.githubusercontent.com/kyle-mckay/docker-compose-templates/main/template.sh"

git clone https://github.com/kyle-mckay/docker-compose-templates.git .templates