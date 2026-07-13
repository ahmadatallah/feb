#!/bin/bash

# =============================================================================
# free-expo-builds
# =============================================================================
# Build your Expo app locally with `eas build --local` — no build queue,
# no EAS build credits, no cloud. This script handles:
# - Installing build dependencies (eas-cli, cocoapods, fastlane, ios-deploy)
# - Building for iOS and/or Android with any profile from your eas.json
# - Optional device deployment (ios-deploy / adb)
# - Optional artifact upload to any WebDAV server (Fastmail Files, Nextcloud, ...)
# - Optional store submission via `eas submit` (TestFlight / Google Play)
#
# Usage:
#   ./build.sh <platform> <profile> [--non-interactive]
#
# Arguments:
#   platform: ios | android | all
#   profile:  any build profile defined in your eas.json
#
# Examples:
#   ./build.sh ios staging
#   ./build.sh android production
#   ./build.sh all preview --non-interactive
#
# Environment Variables (all optional):
#   APP_NAME              - Artifact name prefix (default: app.json / package.json name)
#   EXPO_TOKEN            - Expo access token (otherwise `eas login` prompts)
#   PRE_BUILD_COMMAND     - Command to run after install, before build
#                           (e.g. "pnpm --filter @myorg/lib build" in a monorepo)
#   WEBDAV_BASE_URL       - WebDAV endpoint for artifact uploads
#                           (e.g. "https://webdav.fastmail.com/files")
#   WEBDAV_USERNAME       - WebDAV username
#   WEBDAV_PASSWORD       - WebDAV password / app-specific password
#
# Note: Credentials are handled interactively when not set as env vars.
#       `eas submit` prompts for Apple/Google credentials as needed.
# =============================================================================

set -e # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory = project directory (script lives in the Expo project root
# or a scripts/ folder inside it; PROJECT_DIR is wherever eas.json lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/eas.json" ]]; then
    PROJECT_DIR="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../eas.json" ]]; then
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
elif [[ -f "$PWD/eas.json" ]]; then
    PROJECT_DIR="$PWD"
else
    echo -e "${RED}✗${NC} Could not find eas.json (looked in script dir, its parent, and \$PWD)"
    exit 1
fi

# Build output directory
BUILD_OUTPUT_DIR="$PROJECT_DIR/build-output"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}▶${NC} $1"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

check_command() {
    if command -v "$1" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Read a value out of a JSON file with node (node is required for Expo anyway)
json_get() {
    local file="$1"
    local expr="$2"
    node -e "
        const j = JSON.parse(require('fs').readFileSync('$file', 'utf8'));
        const v = (() => { try { return $expr } catch { return undefined } })();
        if (v !== undefined && v !== null) process.stdout.write(String(v));
    " 2>/dev/null || true
}

# Read a field from the selected build profile, resolving the 'extends' chain
# so inherited fields (buildType, distribution, simulator) are picked up
profile_get() {
    local expr="$1"
    node -e "
        const j = JSON.parse(require('fs').readFileSync('$EAS_JSON', 'utf8'));
        const resolve = (name, seen = new Set()) => {
            const raw = (j.build || {})[name];
            if (!raw || seen.has(name)) return {};
            seen.add(name);
            const base = raw.extends ? resolve(raw.extends, seen) : {};
            return {
                ...base, ...raw,
                ios: { ...base.ios, ...raw.ios },
                android: { ...base.android, ...raw.android },
            };
        };
        const p = resolve('$PROFILE');
        const v = (() => { try { return $expr } catch { return undefined } })();
        if (v !== undefined && v !== null) process.stdout.write(String(v));
    " 2>/dev/null || true
}

# =============================================================================
# Argument Parsing
# =============================================================================

PLATFORM="${1:-}"
PROFILE="${2:-}"
INTERACTIVE=true
if [[ "${3:-}" == "--non-interactive" ]] || [[ -n "${CI:-}" ]]; then
    INTERACTIVE=false
fi

usage() {
    echo "Usage: ./build.sh <platform> <profile> [--non-interactive]"
    echo ""
    echo "Arguments:"
    echo "  platform: ios | android | all"
    echo "  profile:  any build profile defined in your eas.json"
    echo ""
    echo "Examples:"
    echo "  ./build.sh ios staging"
    echo "  ./build.sh android production"
    echo "  ./build.sh all preview --non-interactive"
}

if [[ -z "$PLATFORM" ]] || [[ -z "$PROFILE" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo ""
    usage
    exit 1
fi

# Validate platform
if [[ "$PLATFORM" != "ios" ]] && [[ "$PLATFORM" != "android" ]] && [[ "$PLATFORM" != "all" ]]; then
    log_error "Invalid platform: $PLATFORM"
    echo "Valid options: ios, android, all"
    exit 1
fi

# Validate profile against eas.json
EAS_JSON="$PROJECT_DIR/eas.json"
AVAILABLE_PROFILES=$(json_get "$EAS_JSON" "Object.keys(j.build || {}).join(', ')")
PROFILE_EXISTS=$(json_get "$EAS_JSON" "j.build && j.build['$PROFILE'] ? 'yes' : ''")
if [[ -z "$PROFILE_EXISTS" ]]; then
    log_error "Profile '$PROFILE' not found in eas.json"
    echo "Available profiles: ${AVAILABLE_PROFILES:-none}"
    exit 1
fi

# Check if on macOS for iOS builds
if [[ "$PLATFORM" == "ios" ]] || [[ "$PLATFORM" == "all" ]]; then
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "iOS builds require macOS"
        exit 1
    fi
fi

# App name for artifact filenames: APP_NAME > app.json name > package.json name
if [[ -z "${APP_NAME:-}" ]]; then
    if [[ -f "$PROJECT_DIR/app.json" ]]; then
        APP_NAME=$(json_get "$PROJECT_DIR/app.json" "j.expo?.name || j.name")
    fi
    if [[ -z "${APP_NAME:-}" ]] && [[ -f "$PROJECT_DIR/package.json" ]]; then
        APP_NAME=$(json_get "$PROJECT_DIR/package.json" "j.name")
    fi
    APP_NAME="${APP_NAME:-app}"
fi
# Sanitize for filenames (lowercase, alphanumeric + dashes)
APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')

BOX_WIDTH=50
print_centered() {
    local text="$1"
    local width=$BOX_WIDTH
    local text_len=${#text}
    local padding=$(((width - text_len) / 2))
    local right_padding=$((width - text_len - padding))
    printf "${GREEN}║${NC}%*s%s%*s${GREEN}║${NC}\n" $padding "" "$text" $right_padding ""
}

print_row() {
    local label="$1"
    local value="$2"
    local content="$label $value"
    local width=$BOX_WIDTH
    local content_len=${#content}
    local right_padding=$((width - content_len - 2))
    printf "${GREEN}║${NC}  %s ${YELLOW}%s${NC}%*s${GREEN}║${NC}\n" "$label" "$value" $right_padding ""
}

echo ""
echo -e "${GREEN}╔$(printf '═%.0s' $(seq 1 $BOX_WIDTH))╗${NC}"
print_centered "free-expo-builds"
echo -e "${GREEN}╠$(printf '═%.0s' $(seq 1 $BOX_WIDTH))╣${NC}"
print_row "App:" "$APP_NAME"
print_row "Platform:" "$PLATFORM"
print_row "Profile:" "$PROFILE"
echo -e "${GREEN}╚$(printf '═%.0s' $(seq 1 $BOX_WIDTH))╝${NC}"
echo ""

# =============================================================================
# Step 1: Install Build Dependencies
# =============================================================================

log_step "Step 1: Installing Build Dependencies"

# Check and install Homebrew (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
    if ! check_command brew; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        log_success "Homebrew is installed"
    fi
fi

# Check Node.js
if ! check_command node; then
    log_error "Node.js is not installed. Please install Node.js 22.x LTS"
    exit 1
else
    NODE_VERSION=$(node -v)
    log_success "Node.js $NODE_VERSION is installed"
fi

# Check and install EAS CLI
if ! check_command eas; then
    log_info "Installing EAS CLI..."
    npm install -g eas-cli
else
    EAS_VERSION=$(eas --version 2>/dev/null || echo "unknown")
    log_success "EAS CLI $EAS_VERSION is installed"
fi

# iOS-specific dependencies
if [[ "$PLATFORM" == "ios" ]] || [[ "$PLATFORM" == "all" ]]; then
    log_info "Checking iOS build dependencies..."

    # Check Xcode
    if ! check_command xcodebuild; then
        log_error "Xcode is not installed. Please install Xcode from the App Store."
        exit 1
    else
        XCODE_VERSION=$(xcodebuild -version | head -n1)
        log_success "$XCODE_VERSION is installed"
    fi

    # Check and install CocoaPods
    if ! check_command pod; then
        log_info "Installing CocoaPods..."
        brew install cocoapods
    else
        POD_VERSION=$(pod --version)
        log_success "CocoaPods $POD_VERSION is installed"
    fi

    # Check and install Fastlane
    if ! check_command fastlane; then
        log_info "Installing Fastlane..."
        brew install fastlane
    else
        FASTLANE_VERSION=$(fastlane --version 2>/dev/null | tail -n1)
        log_success "Fastlane $FASTLANE_VERSION is installed"
    fi

    # Check and install ios-deploy (for device deployment)
    if ! check_command ios-deploy; then
        log_info "Installing ios-deploy..."
        brew install ios-deploy
    else
        log_success "ios-deploy is installed"
    fi
fi

# Android-specific dependencies
if [[ "$PLATFORM" == "android" ]] || [[ "$PLATFORM" == "all" ]]; then
    log_info "Checking Android build dependencies..."

    # Check ANDROID_HOME
    if [[ -z "${ANDROID_HOME:-}" ]]; then
        # Try common locations
        if [[ -d "$HOME/Library/Android/sdk" ]]; then
            export ANDROID_HOME="$HOME/Library/Android/sdk"
        elif [[ -d "$HOME/Android/Sdk" ]]; then
            export ANDROID_HOME="$HOME/Android/Sdk"
        else
            log_warning "ANDROID_HOME is not set. Android builds may fail."
        fi
    fi

    if [[ -n "${ANDROID_HOME:-}" ]]; then
        log_success "ANDROID_HOME is set to $ANDROID_HOME"
    fi

    # Check Java
    if ! check_command java; then
        log_warning "Java is not installed. Installing OpenJDK 17..."
        if [[ "$(uname)" == "Darwin" ]]; then
            brew install openjdk@17
        else
            log_error "Please install OpenJDK 17 and re-run."
            exit 1
        fi
    else
        JAVA_VERSION=$(java -version 2>&1 | head -n1)
        log_success "Java is installed: $JAVA_VERSION"
    fi
fi

# =============================================================================
# Step 2: Install Project Dependencies
# =============================================================================

log_step "Step 2: Installing Project Dependencies"

cd "$PROJECT_DIR"

# Detect package manager from lockfile (checks parent dirs for monorepos)
detect_package_manager() {
    local dir="$PROJECT_DIR"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/pnpm-lock.yaml" ]]; then
            echo "pnpm|$dir"
            return
        elif [[ -f "$dir/yarn.lock" ]]; then
            echo "yarn|$dir"
            return
        elif [[ -f "$dir/bun.lockb" ]] || [[ -f "$dir/bun.lock" ]]; then
            echo "bun|$dir"
            return
        elif [[ -f "$dir/package-lock.json" ]]; then
            echo "npm|$dir"
            return
        fi
        dir="$(dirname "$dir")"
    done
    echo "npm|$PROJECT_DIR"
}

PM_INFO=$(detect_package_manager)
PACKAGE_MANAGER="${PM_INFO%%|*}"
INSTALL_DIR="${PM_INFO##*|}"

if [[ "$PACKAGE_MANAGER" == "pnpm" ]] && ! check_command pnpm; then
    log_info "Installing pnpm..."
    npm install -g pnpm
fi

log_info "Running $PACKAGE_MANAGER install in $INSTALL_DIR..."
cd "$INSTALL_DIR"
case "$PACKAGE_MANAGER" in
pnpm) pnpm install --frozen-lockfile ;;
yarn) yarn install --frozen-lockfile ;;
bun) bun install --frozen-lockfile ;;
npm) npm ci ;;
esac
log_success "Project dependencies installed"

# Optional pre-build hook (e.g. build a shared workspace library in a monorepo)
if [[ -n "${PRE_BUILD_COMMAND:-}" ]]; then
    log_info "Running pre-build command: $PRE_BUILD_COMMAND"
    bash -c "$PRE_BUILD_COMMAND"
    log_success "Pre-build command completed"
fi

# =============================================================================
# Step 3: EAS Authentication
# =============================================================================

log_step "Step 3: Authenticating with Expo"

if [[ -z "${EXPO_TOKEN:-}" ]]; then
    log_warning "EXPO_TOKEN not set. Checking if already logged in..."
    if ! eas whoami &>/dev/null; then
        log_info "Please log in to Expo:"
        eas login
    fi
else
    log_success "Using EXPO_TOKEN for authentication"
fi

# Verify authentication
EXPO_USER=$(eas whoami 2>/dev/null || echo "")
if [[ -n "$EXPO_USER" ]]; then
    log_success "Authenticated as: $EXPO_USER"
else
    log_error "Failed to authenticate with Expo"
    exit 1
fi

# =============================================================================
# Step 4: Build
# =============================================================================

log_step "Step 4: Building Application"

cd "$PROJECT_DIR"

# Create build output directory
mkdir -p "$BUILD_OUTPUT_DIR"

# Track built artifacts
IOS_ARTIFACT=""
ANDROID_ARTIFACT=""
BUILD_TIMESTAMP=$(date +%s)

# Build iOS
if [[ "$PLATFORM" == "ios" ]] || [[ "$PLATFORM" == "all" ]]; then
    log_info "Building iOS ($PROFILE profile)..."

    # Simulator builds produce .app archives, device builds produce .ipa
    IOS_SIMULATOR=$(json_get "$EAS_JSON" "j.build['$PROFILE'].ios?.simulator ? 'yes' : ''")
    if [[ -n "$IOS_SIMULATOR" ]]; then
        IOS_EXT="tar.gz"
    else
        IOS_EXT="ipa"
    fi

    IOS_ARTIFACT="$BUILD_OUTPUT_DIR/$APP_NAME-$PROFILE-$BUILD_TIMESTAMP.$IOS_EXT"

    # Run the build
    eas build \
        --platform ios \
        --profile "$PROFILE" \
        --local \
        --output "$IOS_ARTIFACT"

    if [[ -f "$IOS_ARTIFACT" ]]; then
        log_success "iOS build completed: $IOS_ARTIFACT"
    else
        # EAS might output to a different location, find it
        IOS_ARTIFACT=$(find "$PROJECT_DIR" -maxdepth 1 -name "*.$IOS_EXT" -newer "$BUILD_OUTPUT_DIR" 2>/dev/null | head -1 || echo "")
        if [[ -n "$IOS_ARTIFACT" ]]; then
            mv "$IOS_ARTIFACT" "$BUILD_OUTPUT_DIR/"
            IOS_ARTIFACT="$BUILD_OUTPUT_DIR/$(basename "$IOS_ARTIFACT")"
            log_success "iOS build completed: $IOS_ARTIFACT"
        else
            log_error "iOS build failed or artifact not found"
        fi
    fi
fi

# Build Android
if [[ "$PLATFORM" == "android" ]] || [[ "$PLATFORM" == "all" ]]; then
    log_info "Building Android ($PROFILE profile)..."

    # Artifact extension follows the profile's buildType (default: app-bundle)
    ANDROID_BUILD_TYPE=$(json_get "$EAS_JSON" "j.build['$PROFILE'].android?.buildType")
    if [[ "$ANDROID_BUILD_TYPE" == "apk" ]]; then
        ANDROID_EXT="apk"
    else
        ANDROID_EXT="aab"
    fi

    ANDROID_ARTIFACT="$BUILD_OUTPUT_DIR/$APP_NAME-$PROFILE-$BUILD_TIMESTAMP.$ANDROID_EXT"

    # Run the build
    eas build \
        --platform android \
        --profile "$PROFILE" \
        --local \
        --output "$ANDROID_ARTIFACT"

    if [[ -f "$ANDROID_ARTIFACT" ]]; then
        log_success "Android build completed: $ANDROID_ARTIFACT"
    else
        # EAS might output to a different location, find it
        ANDROID_ARTIFACT=$(find "$PROJECT_DIR" -maxdepth 1 -name "*.$ANDROID_EXT" -newer "$BUILD_OUTPUT_DIR" 2>/dev/null | head -1 || echo "")
        if [[ -n "$ANDROID_ARTIFACT" ]]; then
            mv "$ANDROID_ARTIFACT" "$BUILD_OUTPUT_DIR/"
            ANDROID_ARTIFACT="$BUILD_OUTPUT_DIR/$(basename "$ANDROID_ARTIFACT")"
            log_success "Android build completed: $ANDROID_ARTIFACT"
        else
            log_error "Android build failed or artifact not found"
        fi
    fi
fi

# =============================================================================
# Step 5: Post-Build Actions (interactive only)
# =============================================================================

if [[ "$INTERACTIVE" == "true" ]]; then
    log_step "Step 5: Post-Build Actions"

    # Internal-distribution builds: offer device deployment
    DISTRIBUTION=$(json_get "$EAS_JSON" "j.build['$PROFILE'].distribution")

    # iOS: Offer to install on connected device (device builds only)
    if [[ -n "$IOS_ARTIFACT" ]] && [[ -f "$IOS_ARTIFACT" ]] && [[ "$IOS_ARTIFACT" == *.ipa ]]; then
        echo ""
        echo -e "${YELLOW}iOS Build Available: $(basename "$IOS_ARTIFACT")${NC}"
        echo ""
        read -p "Do you want to install on a connected iOS device? (y/n): " INSTALL_IOS

        if [[ "$INSTALL_IOS" == "y" ]] || [[ "$INSTALL_IOS" == "Y" ]]; then
            echo ""
            echo "Select installation method:"
            echo "  1) USB (ios-deploy)"
            echo "  2) Network/WiFi (ios-deploy -w)"
            echo "  3) Skip"
            echo ""
            read -p "Choice (1/2/3): " INSTALL_METHOD

            case $INSTALL_METHOD in
            1)
                log_info "Installing via USB..."
                ios-deploy --bundle "$IOS_ARTIFACT"
                log_success "App installed on device"
                ;;
            2)
                log_info "Installing via WiFi (make sure device is on same network)..."
                ios-deploy --bundle "$IOS_ARTIFACT" -w
                log_success "App installed on device"
                ;;
            *)
                log_info "Skipping device installation"
                ;;
            esac
        fi
    fi

    # Android: Offer to install APK on connected device/emulator via adb
    if [[ -n "$ANDROID_ARTIFACT" ]] && [[ -f "$ANDROID_ARTIFACT" ]] && [[ "$ANDROID_ARTIFACT" == *.apk ]]; then
        if check_command adb || [[ -x "${ANDROID_HOME:-}/platform-tools/adb" ]]; then
            ADB_BIN=$(command -v adb || echo "$ANDROID_HOME/platform-tools/adb")
            echo ""
            echo -e "${YELLOW}Android Build Available: $(basename "$ANDROID_ARTIFACT")${NC}"
            echo ""
            read -p "Do you want to install on a connected Android device/emulator? (y/n): " INSTALL_ANDROID

            if [[ "$INSTALL_ANDROID" == "y" ]] || [[ "$INSTALL_ANDROID" == "Y" ]]; then
                log_info "Installing via adb..."
                "$ADB_BIN" install -r "$ANDROID_ARTIFACT"
                log_success "App installed on device"
            fi
        fi
    fi

    # Upload artifacts to a WebDAV server (Fastmail Files, Nextcloud, etc.)
    echo ""
    read -p "Do you want to upload artifacts to a WebDAV server? (y/n): " UPLOAD_WEBDAV

    if [[ "$UPLOAD_WEBDAV" == "y" ]] || [[ "$UPLOAD_WEBDAV" == "Y" ]]; then
        log_info "Uploading to WebDAV..."

        # Check for credentials
        if [[ -z "${WEBDAV_BASE_URL:-}" ]]; then
            read -p "Enter WebDAV base URL (e.g. https://webdav.fastmail.com/files): " WEBDAV_BASE_URL
        fi
        if [[ -z "${WEBDAV_USERNAME:-}" ]] || [[ -z "${WEBDAV_PASSWORD:-}" ]]; then
            read -p "Enter WebDAV username: " WEBDAV_USERNAME
            read -sp "Enter WebDAV password: " WEBDAV_PASSWORD
            echo ""
        fi

        WEBDAV_FOLDER="$APP_NAME-builds/$PROFILE/$(date +%Y-%m-%d)"
        WEBDAV_URL="${WEBDAV_BASE_URL%/}/$WEBDAV_FOLDER"

        # Create folder hierarchy (MKCOL is not recursive)
        curl -s -X MKCOL \
            -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
            "${WEBDAV_BASE_URL%/}/$APP_NAME-builds" 2>/dev/null || true
        curl -s -X MKCOL \
            -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
            "${WEBDAV_BASE_URL%/}/$APP_NAME-builds/$PROFILE" 2>/dev/null || true
        curl -s -X MKCOL \
            -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
            "$WEBDAV_URL" 2>/dev/null || true

        # Upload iOS artifact
        if [[ -n "$IOS_ARTIFACT" ]] && [[ -f "$IOS_ARTIFACT" ]]; then
            log_info "Uploading iOS artifact..."
            curl -T "$IOS_ARTIFACT" \
                -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
                "$WEBDAV_URL/$(basename "$IOS_ARTIFACT")"
            log_success "iOS artifact uploaded"
        fi

        # Upload Android artifact
        if [[ -n "$ANDROID_ARTIFACT" ]] && [[ -f "$ANDROID_ARTIFACT" ]]; then
            log_info "Uploading Android artifact..."
            curl -T "$ANDROID_ARTIFACT" \
                -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
                "$WEBDAV_URL/$(basename "$ANDROID_ARTIFACT")"
            log_success "Android artifact uploaded"
        fi

        echo ""
        log_success "Files uploaded to: $WEBDAV_URL"
    fi

    # Store-distribution builds: offer store submission
    if [[ "$DISTRIBUTION" != "internal" ]]; then
        # iOS: Submit to TestFlight
        if [[ -n "$IOS_ARTIFACT" ]] && [[ -f "$IOS_ARTIFACT" ]] && [[ "$IOS_ARTIFACT" == *.ipa ]]; then
            echo ""
            read -p "Submit iOS build to TestFlight? (y/n): " SUBMIT_IOS

            if [[ "$SUBMIT_IOS" == "y" ]] || [[ "$SUBMIT_IOS" == "Y" ]]; then
                log_info "Submitting to TestFlight..."
                log_info "EAS will prompt for Apple credentials if not configured..."
                echo ""

                # Use EAS Submit (interactive - will prompt for Apple credentials)
                eas submit \
                    --platform ios \
                    --path "$IOS_ARTIFACT"

                log_success "iOS build submitted to TestFlight"
            fi
        fi

        # Android: Submit to Google Play
        if [[ -n "$ANDROID_ARTIFACT" ]] && [[ -f "$ANDROID_ARTIFACT" ]]; then
            echo ""
            read -p "Submit Android build to Google Play? (y/n): " SUBMIT_ANDROID

            if [[ "$SUBMIT_ANDROID" == "y" ]] || [[ "$SUBMIT_ANDROID" == "Y" ]]; then
                log_info "Submitting to Google Play..."
                log_info "EAS will prompt for Google Play credentials if not configured..."
                echo ""

                # Use EAS Submit (interactive - will prompt for service account key)
                eas submit \
                    --platform android \
                    --path "$ANDROID_ARTIFACT"

                log_success "Android build submitted to Google Play"
            fi
        fi
    fi
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo -e "${GREEN}╔$(printf '═%.0s' $(seq 1 $BOX_WIDTH))╗${NC}"
print_centered "Build Complete!"
echo -e "${GREEN}╠$(printf '═%.0s' $(seq 1 $BOX_WIDTH))╣${NC}"

if [[ -n "$IOS_ARTIFACT" ]] && [[ -f "$IOS_ARTIFACT" ]]; then
    print_row "iOS:" "$(basename "$IOS_ARTIFACT")"
fi

if [[ -n "$ANDROID_ARTIFACT" ]] && [[ -f "$ANDROID_ARTIFACT" ]]; then
    print_row "Android:" "$(basename "$ANDROID_ARTIFACT")"
fi

printf "${GREEN}║${NC}%*s${GREEN}║${NC}\n" $BOX_WIDTH ""
print_row "Output:" "$BUILD_OUTPUT_DIR"
echo -e "${GREEN}╚$(printf '═%.0s' $(seq 1 $BOX_WIDTH))╝${NC}"
echo ""
