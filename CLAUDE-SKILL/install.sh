#!/bin/bash

# vibenotes skill installer for Claude Code
# This script installs the vibenotes skill to your personal Claude skills directory

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Personal Claude skills directory
PERSONAL_SKILLS_DIR="${HOME}/.claude/skills"

# Target directory for vibenotes skill
TARGET_DIR="${PERSONAL_SKILLS_DIR}/vibenotes"

echo -e "${GREEN}==> Installing vibenotes skill for Claude Code${NC}"
echo ""

# Check if Claude skills directory exists, create if not
if [ ! -d "${PERSONAL_SKILLS_DIR}" ]; then
    echo -e "${YELLOW}Creating Claude skills directory: ${PERSONAL_SKILLS_DIR}${NC}"
    mkdir -p "${PERSONAL_SKILLS_DIR}"
fi

# Check if vibenotes skill already exists
if [ -d "${TARGET_DIR}" ]; then
    echo -e "${YELLOW}Warning: vibenotes skill already exists at ${TARGET_DIR}${NC}"
    read -p "Do you want to overwrite it? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Installation cancelled${NC}"
        exit 1
    fi
    rm -rf "${TARGET_DIR}"
fi

# Create target directory
echo -e "${GREEN}Creating skill directory: ${TARGET_DIR}${NC}"
mkdir -p "${TARGET_DIR}"

# Copy skill files
echo -e "${GREEN}Copying skill files...${NC}"
cp -r "${SCRIPT_DIR}"/* "${TARGET_DIR}"/ 2>/dev/null || true

# Remove the install script itself from target (optional)
rm -f "${TARGET_DIR}/install.sh"

# Verify SKILL.md exists
if [ ! -f "${TARGET_DIR}/SKILL.md" ]; then
    echo -e "${RED}Error: SKILL.md not found in source directory${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}==> vibenotes skill installed successfully!${NC}"
echo ""
echo "Skill location: ${TARGET_DIR}"
echo ""
echo "To verify the installation, ask Claude:"
echo "  'What Skills are available?'"
echo ""
echo "To use the skill, simply ask Claude something like:"
echo "  '/vibenote --dir ~/source/vibenotes'"
echo ""
