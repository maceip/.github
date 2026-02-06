#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Android CI Emulator Service — Full Setup
# =============================================================================
# Creates a persistent, snapshot-accelerated, headless Android emulator
# for use with GitHub Actions self-hosted runner smoke/E2E tests.
#
# Machine requirements: x86_64, KVM (/dev/kvm), 8+ GB RAM, 20+ GB disk
#
# Usage:
#   sudo ./setup-emulator.sh              # Full setup (deps + SDK + AVD + services)
#   sudo ./setup-emulator.sh --deps       # Install system dependencies only
#   sudo ./setup-emulator.sh --sdk        # Install SDK + system image only
#   sudo ./setup-emulator.sh --avd        # Create AVD only
#   sudo ./setup-emulator.sh --snapshot   # Boot, create quickboot snapshot, shut down
#   sudo ./setup-emulator.sh --service    # Install systemd emulator service only
#   sudo ./setup-emulator.sh --runner     # Install GitHub Actions runner only
#   sudo ./setup-emulator.sh --status     # Show current status of everything
# =============================================================================

ANDROID_HOME="/opt/android-sdk"
JAVA_HOME="/opt/jdk-22"
AVD_NAME="ci-emulator"
API_LEVEL="34"
SYSTEM_IMAGE="system-images;android-${API_LEVEL};google_apis_playstore;x86_64"
DEVICE_PROFILE="pixel_6"
RUNNER_USER="devuser"
RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"
EMULATOR_RAM_MB=4096
EMULATOR_HEAP_MB=576
DATA_PARTITION="8G"

export ANDROID_HOME JAVA_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# 1. System Dependencies
# ---------------------------------------------------------------------------
install_deps() {
  info "Installing system dependencies..."

  apt-get update -qq

  apt-get install -y --no-install-recommends \
    libpulse0 \
    libgl1 \
    libgl1-mesa-glx \
    libnss3 \
    libxcomposite1 \
    libxcursor1 \
    libxi6 \
    libxtst6 \
    libxrandr2 \
    libxss1 \
    libasound2t64 \
    libatk1.0-0t64 \
    libatk-bridge2.0-0t64 \
    libgdk-pixbuf-2.0-0 \
    libgtk-3-0t64 \
    libgbm1 \
    bridge-utils \
    unzip \
    curl \
    jq \
    bc \
    2>/dev/null || true

  # Ensure KVM is accessible
  if [ ! -e /dev/kvm ]; then
    err "/dev/kvm not found — KVM not available"
    exit 1
  fi

  # Make sure runner user can access KVM
  if ! groups "$RUNNER_USER" | grep -q kvm; then
    usermod -aG kvm "$RUNNER_USER" 2>/dev/null || true
  fi
  chmod 666 /dev/kvm

  ok "System dependencies installed"
}

# ---------------------------------------------------------------------------
# 2. SDK + System Image
# ---------------------------------------------------------------------------
install_sdk() {
  info "Installing API ${API_LEVEL} Google Play system image..."

  # Accept licenses
  yes | sdkmanager --licenses 2>/dev/null || true

  sdkmanager \
    "platforms;android-${API_LEVEL}" \
    "system-images;android-${API_LEVEL};google_apis_playstore;x86_64"

  ok "System image installed: ${SYSTEM_IMAGE}"
}

# ---------------------------------------------------------------------------
# 3. Create AVD (optimized for CI)
# ---------------------------------------------------------------------------
create_avd() {
  info "Creating AVD: ${AVD_NAME} (API ${API_LEVEL}, Google Play, x86_64)..."

  # Run as the runner user so AVD lives in their home
  su - "$RUNNER_USER" -c "
    export ANDROID_HOME=$ANDROID_HOME
    export ANDROID_SDK_ROOT=$ANDROID_HOME
    export JAVA_HOME=$JAVA_HOME
    export PATH=$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:\$PATH

    # Delete existing AVD
    avdmanager delete avd -n $AVD_NAME 2>/dev/null || true

    # Create AVD — no interactive prompts
    echo 'no' | avdmanager create avd \
      --name $AVD_NAME \
      --package '$SYSTEM_IMAGE' \
      --device '$DEVICE_PROFILE' \
      --force
  "

  # Patch config.ini for CI performance
  AVD_DIR="/home/${RUNNER_USER}/.android/avd/${AVD_NAME}.avd"
  cat >> "${AVD_DIR}/config.ini" << AVDCFG

# === CI Performance Tuning ===
hw.ramSize=${EMULATOR_RAM_MB}
vm.heapSize=${EMULATOR_HEAP_MB}
disk.dataPartition.size=${DATA_PARTITION}
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
hw.audioInput=no
hw.audioOutput=no
hw.camera.back=none
hw.camera.front=none
hw.sensors.proximity=no
hw.sensors.magnetic_field=no
hw.sensors.orientation=no
hw.sensors.temperature=no
hw.sensors.light=no
hw.sensors.pressure=no
hw.sensors.humidity=no
hw.sensors.rgbcSensor=no
hw.sensors.hinge=no
hw.lcd.density=420
hw.lcd.width=1080
hw.lcd.height=2400
fastboot.forceColdBoot=no
fastboot.forceFastBoot=yes
AVDCFG

  ok "AVD created and tuned for CI: ${AVD_NAME}"
  info "  RAM: ${EMULATOR_RAM_MB}MB, Heap: ${EMULATOR_HEAP_MB}MB, Data: ${DATA_PARTITION}"
  info "  AVD path: ${AVD_DIR}"
}

# ---------------------------------------------------------------------------
# 4. Create Quickboot Snapshot (boot once, save state, kill)
# ---------------------------------------------------------------------------
create_snapshot() {
  info "Creating quickboot snapshot (this boots the emulator once)..."

  # Run emulator as runner user, save snapshot on exit
  su - "$RUNNER_USER" -c "
    export ANDROID_HOME=$ANDROID_HOME
    export ANDROID_SDK_ROOT=$ANDROID_HOME
    export JAVA_HOME=$JAVA_HOME
    export PATH=$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:\$PATH

    # Cold boot the emulator
    nohup emulator \
      -avd $AVD_NAME \
      -no-window \
      -no-audio \
      -no-boot-anim \
      -gpu swiftshader_indirect \
      -memory $EMULATOR_RAM_MB \
      -no-snapshot-load \
      -wipe-data \
      > /tmp/emulator-snapshot-boot.log 2>&1 &
    EMU_PID=\$!
    echo \"Emulator PID: \$EMU_PID\"

    # Wait for full boot
    echo 'Waiting for boot_completed...'
    TIMEOUT=300
    ELAPSED=0
    while [ \"\$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')\" != '1' ]; do
      if [ \$ELAPSED -ge \$TIMEOUT ]; then
        echo 'ERROR: Boot timeout'
        kill \$EMU_PID 2>/dev/null || true
        exit 1
      fi
      sleep 3
      ELAPSED=\$((ELAPSED + 3))
      echo \"  Waiting... (\${ELAPSED}s)\"
    done
    echo 'Boot complete!'

    # Disable animations
    adb shell settings put global window_animation_scale 0
    adb shell settings put global transition_animation_scale 0
    adb shell settings put global animator_duration_scale 0

    # Let system settle
    sleep 10

    # Save quickboot snapshot and kill
    echo 'Saving snapshot...'
    adb emu avd snapshot save default_boot
    sleep 5

    # Graceful shutdown (saves quickboot snapshot)
    adb emu kill
    sleep 5

    # Ensure dead
    kill \$EMU_PID 2>/dev/null || true
    echo 'Snapshot saved.'
  "

  ok "Quickboot snapshot created — subsequent boots will be near-instant"
}

# ---------------------------------------------------------------------------
# 5. Systemd: Android Emulator Service
# ---------------------------------------------------------------------------
install_emulator_service() {
  info "Installing android-emulator systemd service..."

  cat > /etc/systemd/system/android-emulator.service << SVCEOF
[Unit]
Description=Android CI Emulator (API ${API_LEVEL}, Google Play, Quickboot)
After=network.target
Wants=network.target

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}

Environment="ANDROID_HOME=${ANDROID_HOME}"
Environment="ANDROID_SDK_ROOT=${ANDROID_HOME}"
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="PATH=${JAVA_HOME}/bin:${ANDROID_HOME}/emulator:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/cmdline-tools/latest/bin:/usr/local/bin:/usr/bin:/bin"
Environment="DISPLAY=:0"
Environment="QTWEBENGINE_CHROMIUM_FLAGS=--no-sandbox"

# Use quickboot snapshot for fast start (~5s vs ~60s cold boot)
ExecStart=${ANDROID_HOME}/emulator/emulator \
    -avd ${AVD_NAME} \
    -no-window \
    -no-audio \
    -no-boot-anim \
    -gpu swiftshader_indirect \
    -memory ${EMULATOR_RAM_MB} \
    -snapshot default_boot \
    -no-snapshot-save \
    -read-only \
    -partition-size 8192

# Graceful shutdown
ExecStop=${ANDROID_HOME}/platform-tools/adb -s emulator-5554 emu kill

# Restart policy
Restart=on-failure
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=30

# Resource limits
LimitNOFILE=65536
Nice=-5

[Install]
WantedBy=multi-user.target
SVCEOF

  # Also install a companion health-check timer that ensures emulator is responsive
  cat > /etc/systemd/system/android-emulator-health.service << 'HCEOF'
[Unit]
Description=Android Emulator Health Check
After=android-emulator.service
Requires=android-emulator.service

[Service]
Type=oneshot
User=devuser
Environment="ANDROID_HOME=/opt/android-sdk"
Environment="PATH=/opt/android-sdk/platform-tools:/usr/local/bin:/usr/bin:/bin"
ExecStart=/bin/bash -c '\
  if ! adb devices | grep -q "emulator-5554"; then \
    echo "Emulator not connected, restarting service..."; \
    systemctl restart android-emulator; \
  elif [ "$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d "\\r")" != "1" ]; then \
    echo "Emulator not booted, restarting service..."; \
    systemctl restart android-emulator; \
  else \
    echo "Emulator healthy"; \
  fi'
HCEOF

  cat > /etc/systemd/system/android-emulator-health.timer << 'TMEOF'
[Unit]
Description=Android Emulator Health Check Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
TMEOF

  systemctl daemon-reload
  systemctl enable android-emulator.service
  systemctl enable android-emulator-health.timer

  ok "Emulator systemd service installed"
  info "  Start:   sudo systemctl start android-emulator"
  info "  Status:  sudo systemctl status android-emulator"
  info "  Logs:    journalctl -u android-emulator -f"
  info "  Health timer also installed (checks every 5m, auto-restarts if dead)"
}

# ---------------------------------------------------------------------------
# 6. GitHub Actions Self-Hosted Runner
# ---------------------------------------------------------------------------
install_runner() {
  info "Installing GitHub Actions self-hosted runner..."

  # Get the latest runner version
  RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
  info "Latest runner version: ${RUNNER_VERSION}"

  mkdir -p "$RUNNER_DIR"
  cd "$RUNNER_DIR"

  # Download
  RUNNER_ARCHIVE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  if [ ! -f "$RUNNER_ARCHIVE" ]; then
    curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}" -o "$RUNNER_ARCHIVE"
  fi
  tar -xzf "$RUNNER_ARCHIVE"

  chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"

  # Get registration token from the org-level .github repo
  info ""
  info "========================================================="
  info " Runner registration requires a GitHub token."
  info " Generate one at: https://github.com/organizations/maceip/settings/actions/runners/new"
  info " Or run:  gh api -X POST orgs/maceip/actions/runners/registration-token -q '.token'"
  info "========================================================="
  info ""

  # Try to get a registration token via gh CLI
  REG_TOKEN=""
  if command -v gh &>/dev/null; then
    REG_TOKEN=$(su - "$RUNNER_USER" -c "gh api -X POST orgs/maceip/actions/runners/registration-token -q '.token'" 2>/dev/null || true)
  fi

  if [ -n "$REG_TOKEN" ]; then
    info "Got registration token via gh CLI"

    su - "$RUNNER_USER" -c "
      cd $RUNNER_DIR
      ./config.sh \
        --url https://github.com/maceip \
        --token '$REG_TOKEN' \
        --name 'android-emulator-$(hostname)' \
        --labels 'self-hosted,linux,x64,android,emulator' \
        --work '_work' \
        --runnergroup 'Default' \
        --unattended \
        --replace
    "
    ok "Runner configured"
  else
    warn "Could not get registration token automatically."
    warn "Run this manually after the script completes:"
    warn "  TOKEN=\$(gh api -X POST orgs/maceip/actions/runners/registration-token -q '.token')"
    warn "  cd $RUNNER_DIR && ./config.sh --url https://github.com/maceip --token \$TOKEN --name android-emulator-$(hostname) --labels self-hosted,linux,x64,android,emulator --work _work --unattended --replace"
  fi

  # Install systemd service for the runner
  cat > /etc/systemd/system/github-runner.service << RNEOF
[Unit]
Description=GitHub Actions Self-Hosted Runner
After=network.target android-emulator.service
Wants=android-emulator.service

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}
WorkingDirectory=${RUNNER_DIR}

Environment="ANDROID_HOME=${ANDROID_HOME}"
Environment="ANDROID_SDK_ROOT=${ANDROID_HOME}"
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="PATH=${JAVA_HOME}/bin:${ANDROID_HOME}/emulator:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/cmdline-tools/latest/bin:/usr/local/bin:/usr/bin:/bin"
Environment="RUNNER_ALLOW_RUNASROOT=0"

ExecStart=${RUNNER_DIR}/run.sh
Restart=on-failure
RestartSec=5
TimeoutStopSec=60

# Security hardening
ProtectSystem=false
ProtectHome=false
NoNewPrivileges=false

# Resource limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
RNEOF

  systemctl daemon-reload
  systemctl enable github-runner.service

  ok "GitHub Actions runner service installed"
  info "  Start:  sudo systemctl start github-runner"
  info "  Status: sudo systemctl status github-runner"
  info "  Logs:   journalctl -u github-runner -f"
}

# ---------------------------------------------------------------------------
# Status Check
# ---------------------------------------------------------------------------
show_status() {
  echo ""
  echo "=============================="
  echo "  Android CI Infrastructure"
  echo "=============================="
  echo ""

  # KVM
  if [ -e /dev/kvm ]; then
    ok "KVM: available ($(stat -c '%a' /dev/kvm))"
  else
    err "KVM: not available"
  fi

  # Java
  if command -v java &>/dev/null; then
    ok "Java: $(java -version 2>&1 | head -1)"
  else
    err "Java: not found"
  fi

  # Android SDK
  if [ -d "$ANDROID_HOME/emulator" ]; then
    ok "Android SDK: $ANDROID_HOME"
    if [ -d "$ANDROID_HOME/system-images/android-${API_LEVEL}/google_apis_playstore/x86_64" ]; then
      ok "System image: API ${API_LEVEL} Google Play x86_64"
    else
      warn "System image: API ${API_LEVEL} Google Play x86_64 NOT installed"
    fi
  else
    err "Android SDK: not found at $ANDROID_HOME"
  fi

  # AVD
  AVD_DIR="/home/${RUNNER_USER}/.android/avd/${AVD_NAME}.avd"
  if [ -d "$AVD_DIR" ]; then
    ok "AVD: $AVD_NAME"
    if [ -d "$AVD_DIR/snapshots/default_boot" ]; then
      ok "Quickboot snapshot: present"
    else
      warn "Quickboot snapshot: not created yet"
    fi
  else
    warn "AVD: not created yet"
  fi

  # Emulator service
  if systemctl is-active android-emulator.service &>/dev/null; then
    ok "Emulator service: running"
  elif systemctl is-enabled android-emulator.service &>/dev/null; then
    warn "Emulator service: enabled but not running"
  else
    warn "Emulator service: not installed"
  fi

  # ADB check
  if command -v adb &>/dev/null; then
    DEVICES=$(adb devices 2>/dev/null | grep -c "emulator-" || true)
    if [ "$DEVICES" -gt 0 ]; then
      BOOT=$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
      if [ "$BOOT" = "1" ]; then
        ok "Emulator: online and booted"
        API=$(adb -s emulator-5554 shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
        DEVICE=$(adb -s emulator-5554 shell getprop ro.product.model 2>/dev/null | tr -d '\r')
        info "  API: $API | Device: $DEVICE"
      else
        warn "Emulator: connected but not fully booted"
      fi
    else
      warn "Emulator: not connected to adb"
    fi
  fi

  # Runner service
  if systemctl is-active github-runner.service &>/dev/null; then
    ok "GitHub Runner: running"
  elif systemctl is-enabled github-runner.service &>/dev/null; then
    warn "GitHub Runner: enabled but not running"
  else
    warn "GitHub Runner: not installed"
  fi

  # Health timer
  if systemctl is-active android-emulator-health.timer &>/dev/null; then
    ok "Health timer: active"
  else
    warn "Health timer: not active"
  fi

  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
  --deps)
    install_deps
    ;;
  --sdk)
    install_sdk
    ;;
  --avd)
    create_avd
    ;;
  --snapshot)
    create_snapshot
    ;;
  --service)
    install_emulator_service
    ;;
  --runner)
    install_runner
    ;;
  --status)
    show_status
    ;;
  ""|--full)
    echo ""
    echo "======================================"
    echo "  Android CI Emulator — Full Setup"
    echo "======================================"
    echo ""
    echo "This will:"
    echo "  1. Install system dependencies (libpulse, etc.)"
    echo "  2. Download API ${API_LEVEL} Google Play x86_64 system image"
    echo "  3. Create AVD '${AVD_NAME}' optimized for CI"
    echo "  4. Cold-boot once to create quickboot snapshot"
    echo "  5. Install systemd emulator service (auto-start, health checks)"
    echo "  6. Install GitHub Actions self-hosted runner"
    echo ""

    install_deps
    echo ""
    install_sdk
    echo ""
    create_avd
    echo ""
    create_snapshot
    echo ""
    install_emulator_service
    echo ""
    install_runner
    echo ""

    echo "======================================"
    echo "  Setup Complete! Starting services..."
    echo "======================================"
    systemctl start android-emulator.service
    systemctl start android-emulator-health.timer

    # Wait for emulator to be ready
    info "Waiting for emulator quickboot..."
    TIMEOUT=60
    ELAPSED=0
    while [ "$(su - "$RUNNER_USER" -c "adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r'")" != "1" ]; do
      if [ $ELAPSED -ge $TIMEOUT ]; then
        warn "Emulator took longer than ${TIMEOUT}s — check logs: journalctl -u android-emulator"
        break
      fi
      sleep 2
      ELAPSED=$((ELAPSED + 2))
    done

    if [ $ELAPSED -lt $TIMEOUT ]; then
      ok "Emulator booted in ~${ELAPSED}s via quickboot"
    fi

    echo ""
    show_status
    echo ""
    info "Next steps:"
    info "  1. If runner registration failed, run manually:"
    info "     TOKEN=\$(gh api -X POST orgs/maceip/actions/runners/registration-token -q '.token')"
    info "     cd $RUNNER_DIR && ./config.sh --url https://github.com/maceip --token \$TOKEN --name android-emulator-\$(hostname) --labels self-hosted,linux,x64,android,emulator --work _work --unattended --replace"
    info "  2. Start the runner: sudo systemctl start github-runner"
    info "  3. Verify on GitHub: https://github.com/organizations/maceip/settings/actions/runners"
    ;;
  *)
    echo "Usage: sudo $0 [--deps|--sdk|--avd|--snapshot|--service|--runner|--status|--full]"
    echo ""
    echo "  (no args)   Full setup (all steps)"
    echo "  --deps      Install system dependencies"
    echo "  --sdk       Install API ${API_LEVEL} Google Play system image"
    echo "  --avd       Create CI-optimized AVD"
    echo "  --snapshot  Boot once and create quickboot snapshot"
    echo "  --service   Install emulator systemd service"
    echo "  --runner    Install GitHub Actions runner"
    echo "  --status    Show current status"
    exit 1
    ;;
esac
