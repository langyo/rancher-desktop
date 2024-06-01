wait_for_shell() {
    if is_windows; then
        try --max 48 --delay 5 rdctl shell true
    else
        # Be at the root directory to avoid issues with limactl automatic
        # changing to the current directory, which might not exist.
        pushd /
        try --max 24 --delay 5 rdctl shell test -f /var/run/lima-boot-done
        # wait until sshfs mounts are done
        try --max 12 --delay 5 rdctl shell test -d "$HOME/.rd"
        popd || :
    fi
}

pkill_by_path() {
    local arg
    arg=$(readlink -f "$1")
    if [[ -n $arg ]]; then
        pkill -f "$arg"
    fi
}

clear_iptables_chain() {
    local chain=$1
    local rule
    wsl sudo iptables -L | awk '/^Chain ${chain}/ {print $2}' | while IFS= read -r rule; do
        wsl sudo iptables -X "$rule"
    done
}

flush_iptables() {
    # reset default policies
    wsl sudo iptables -P INPUT ACCEPT
    wsl sudo iptables -P FORWARD ACCEPT
    wsl sudo iptables -P OUTPUT ACCEPT
    wsl sudo iptables -t nat -F
    wsl sudo iptables -t mangle -F
    wsl sudo iptables -F
    wsl sudo iptables -X
}

# Helper to eject all existing ramdisk instances on macOS
macos_eject_ramdisk() {
    local mount="$1"
    run hdiutil info -plist
    assert_success
    # shellcheck disable=2154 # $output set by `run`
    run plutil -convert json -o - - <<<"$output"
    assert_success
    # shellcheck disable=2016 # $mount is interpreted by jq, not shell.
    local expr='.images[]."system-entities"[] | select(."mount-point" == $mount) | ."dev-entry"'
    run jq_output --arg mount "$mount" "$expr"
    assert_success
    if [[ -z $output ]]; then
        return
    fi
    # We don't need to worry about splitting here, it's all /dev/disk*
    # However, we do need to ensure $output isn't clobbered.
    # shellcheck disable=2206
    local disks=($output)
    local disk
    for disk in "${disks[@]}"; do
        CALLER="$(calling_function):umount" trace "$(umount "$disk" 2>&1 || :)"
    done
    for disk in "${disks[@]}"; do
        CALLER="$(calling_function):hdiutil" trace "$(hdiutil eject "$disk" 2>&1 || :)"
    done
}

# Set up the use of a ramdisk for application data, to make things faster.
setup_ramdisk() {
    if ! using_ramdisk; then
        return
    fi

    # Force eject any existing disks.
    if is_macos; then
        # Try to eject the disk, if it already exists.
        macos_eject_ramdisk "$LIMA_HOME"
    fi

    local ramdisk_size="${RD_RAMDISK_SIZE}"
    if ((ramdisk_size < ${RD_FILE_RAMDISK_SIZE:-0})); then
        local fmt='%s requires %dGB of ramdisk; disabling ramdisk for this file'
        # shellcheck disable=SC2059 # The string is set the line above.
        printf -v fmt "$fmt" "$BATS_TEST_FILENAME" "$RD_FILE_RAMDISK_SIZE"
        printf "RD:   %s\n" "$fmt" >>"$BATS_WARNING_FILE"
        printf "# WARN: %s\n" "$fmt" >&3
        return
    fi

    if is_macos; then
        local sectors=$((ramdisk_size * 1024 * 1024 * 1024 / 512)) # Size, in sectors.
        # hdiutil space-pads the output; strip it.
        disk="$(hdiutil attach -nomount "ram://$sectors" | xargs echo)"
        newfs_hfs -v 'Rancher Desktop BATS' "$disk"
        mkdir -p "$LIMA_HOME"
        mount -t hfs "$disk" "$LIMA_HOME"
        CALLER="$(this_function):hdiutil" trace "$(hdiutil info)"
        CALLER="$(this_function):df" trace "$(df -h)"
    fi
}

# Remove any ramdisks
teardown_ramdisk() {
    # We run this even if ramdisk is not in use, in case a previous run had
    # used ramdisk.
    if is_macos; then
        CALLER="$(this_function):hdiutil" trace "$(hdiutil info)"
        CALLER="$(this_function):df" trace "$(df -h)"
        macos_eject_ramdisk "$LIMA_HOME"
    fi
}

factory_reset() {
    if [ "$BATS_TEST_NUMBER" -gt 1 ]; then
        capture_logs
    fi

    if using_dev_mode; then
        if is_unix; then
            rdctl shutdown || :
            pkill_by_path "$PATH_REPO_ROOT/node_modules" || :
            pkill_by_path "$PATH_RESOURCES" || :
            pkill_by_path "$LIMA_HOME" || :
        else
            # TODO: kill `yarn dev` instance on Windows
            true
        fi
    fi
    if is_windows && wsl true >/dev/null; then
        wsl sudo ip link delete docker0 || :
        wsl sudo ip link delete nerdctl0 || :
        # reset iptables to original state
        flush_iptables
        clear_iptables_chain "CNI"
        clear_iptables_chain "KUBE"
    fi
    rdctl factory-reset "$@"
    setup_ramdisk
}

# Turn `rdctl start` arguments into `yarn dev` arguments
apify_arg() {
    # TODO this should be done via autogenerated code from command-api.yaml
    perl -w - "$1" <<'EOF'
# don't modify the value part after the first '=' sign
($_, my $value) = split /=/, shift, 2;
if (/^--/) {
    # turn "--virtual-machine.memory-in-gb" into "--virtualMachine.memoryInGb"
    s/(\w)-(\w)/$1\U$2/g;
    # fixup acronyms
    s/memoryInGb/memoryInGB/;
    s/numberCpus/numberCPUs/;
    s/--wsl/--WSL/;
}
print;
print "=$value" if $value;
EOF
}

start_container_engine() {
    local args=(
        --application.debug
        --application.updater.enabled=false
        --kubernetes.enabled=false
    )
    local admin_access=false

    if [ -n "$RD_CONTAINER_ENGINE" ]; then
        args+=(--container-engine.name="$RD_CONTAINER_ENGINE")
    fi
    if is_unix; then
        args+=(
            --application.admin-access="$admin_access"
            --application.path-management-strategy rcfiles
            --virtual-machine.memory-in-gb 6
            --experimental.virtual-machine.mount.type="$RD_MOUNT_TYPE"
        )
    fi
    if [ "$RD_MOUNT_TYPE" = "9p" ]; then
        args+=(
            --experimental.virtual-machine.mount.9p.cache-mode="$RD_9P_CACHE_MODE"
            --experimental.virtual-machine.mount.9p.msize-in-kib="$RD_9P_MSIZE"
            --experimental.virtual-machine.mount.9p.protocol-version="$RD_9P_PROTOCOL_VERSION"
            --experimental.virtual-machine.mount.9p.security-model="$RD_9P_SECURITY_MODEL"
        )
    fi
    if is_windows; then
        args+=("--experimental.virtual-machine.networking-tunnel=$(bool using_networking_tunnel)")
    fi
    if using_vz_emulation; then
        args+=(--experimental.virtual-machine.type vz)
        if is_macos aarch64; then
            args+=(--experimental.virtual-machine.use-rosetta)
        fi
    fi

    # TODO containerEngine.allowedImages.patterns and WSL.integrations
    # TODO cannot be set from the commandline yet
    image_allow_list="$(bool using_image_allow_list)"
    registry="docker.io"
    if using_ghcr_images; then
        registry="ghcr.io"
    fi
    if is_true "${RD_USE_PROFILE:-}"; then
        if ! profile_exists; then
            create_profile
        fi
        add_profile_int "version" 7
        if is_windows; then
            # Translate any dots in the distro name into $RD_PROTECTED_DOT (e.g. "Ubuntu-22.04")
            # so that they are not treated as setting separator characters.
            add_profile_bool "WSL.integrations.${WSL_DISTRO_NAME//./$RD_PROTECTED_DOT}" true
        fi
        # TODO Figure out the interaction between RD_USE_PROFILE and RD_USE_IMAGE_ALLOW_LIST!
        # TODO For now we need to avoid overwriting settings that may already exist in the profile.
        # add_profile_bool containerEngine.allowedImages.enabled "$image_allow_list"
        # add_profile_list containerEngine.allowedImages.patterns "$registry"
    else
        local wsl_integrations="{}"
        if is_windows; then
            wsl_integrations="{\"$WSL_DISTRO_NAME\":true}"
        fi
        create_file "$PATH_CONFIG_FILE" <<EOF
{
  "version": 7,
  "WSL": { "integrations": $wsl_integrations },
  "containerEngine": {
    "allowedImages": {
      "enabled": $image_allow_list,
      "patterns": ["$registry"]
    }
  }
}
EOF
    fi
    args+=("$@")
    launch_the_application "${args[@]}"
}

# shellcheck disable=SC2120
start_kubernetes() {
    start_container_engine \
        --kubernetes.enabled \
        --kubernetes.version "$RD_KUBERNETES_PREV_VERSION" \
        "$@"
}

start_application() {
    start_kubernetes
    wait_for_kubelet

    # the docker context "rancher-desktop" may not have been written
    # even though the apiserver is already running
    if using_docker; then
        wait_for_container_engine
    fi
}

launch_the_application() {
    local args=("$@")
    trace "$*"

    if using_dev_mode; then
        # translate args back into the internal API format
        local api_args=()
        for arg in "${args[@]}"; do
            api_args+=("$(apify_arg "$arg")")
        done
        if suppressing_modal_dialogs; then
            # Don't apify this option
            api_args+=(--no-modal-dialogs)
        fi

        yarn dev "${api_args[@]}" &
    else
        # Detach `rdctl start` because on Windows the process may not exit until
        # Rancher Desktop itself quits.
        if suppressing_modal_dialogs; then
            args+=(--no-modal-dialogs)
        fi
        RD_TEST=bats rdctl start "${args[@]}" &
    fi
}

# Write a provisioning script that will be executed during VM startup.
# Only a single script can be defined, and scripts are deleted by factory-reset.
# The script must be provided via STDIN and not as a parameter.
provisioning_script() {
    if is_windows; then
        mkdir -p "$PATH_APP_HOME/provisioning"
        cat >"$PATH_APP_HOME/provisioning/bats.start"
    else
        mkdir -p "$LIMA_HOME/_config"
        cat <<EOF >"$LIMA_HOME/_config/override.yaml"
provision:
- mode: system
  script: |
$(sed 's/^/    /')
EOF
    fi
}

get_container_engine_info() {
    run ctrctl info
    echo "$output"
    assert_success || return
    assert_output --partial "Server Version:"
}

docker_context_exists() {
    # We don't use docker contexts on Windows
    if is_windows; then
        return
    fi
    run docker_exe context ls -q
    assert_success || return
    assert_line "$RD_DOCKER_CONTEXT"
    # Ensure that the context actually exists by reading from the file.
    run docker_exe context inspect "$RD_DOCKER_CONTEXT" --format '{{ .Name }}'
    assert_success || return
    assert_output "$RD_DOCKER_CONTEXT"
}

get_service_pid() {
    local service_name=$1
    RD_TIMEOUT=10s run rdshell sh -c "RC_SVCNAME=$service_name /lib/rc/bin/service_get_value pidfile"
    assert_success || return
    RD_TIMEOUT=10s rdshell cat "$output"
}

assert_service_pid() {
    local service_name=$1
    local expected_pid=$2
    run get_service_pid "$service_name"
    assert_success
    assert_output "$expected_pid"
}

# Check that the given service does not have the given PID.  It is acceptable
# for the service to not be running.
refute_service_pid() {
    local service_name=$1
    local unexpected_pid=$2
    run get_service_pid "$service_name"
    if [ "$status" -eq 0 ]; then
        refute_output "$unexpected_pid"
    fi
}

assert_service_status() {
    local service_name=$1
    local expect=$2

    RD_TIMEOUT=10s run rdsudo rc-service "$service_name" status
    # rc-service report non-zero status (3) when the service is stopped
    if [[ $expect == started ]]; then
        assert_success || return
    fi
    assert_output --partial "status: ${expect}"
}

wait_for_service_status() {
    local service_name=$1
    local expect=$2

    trace "waiting for VM to be available"
    wait_for_shell

    trace "waiting for ${service_name} to be ${expect}"
    try --max 30 --delay 5 assert_service_status "$service_name" "$expect"
}

wait_for_container_engine() {
    local CALLER
    CALLER=$(this_function)

    trace "waiting for api /settings to be callable"
    RD_TIMEOUT=10s try --max 30 --delay 5 rdctl api /settings

    if using_docker; then
        wait_for_service_status docker started
        trace "waiting for docker context to exist"
        try --max 30 --delay 10 docker_context_exists
    else
        wait_for_service_status buildkitd started
    fi

    trace "waiting for container engine info to be available"
    try --max 12 --delay 10 get_container_engine_info
}

# Wait fot the extension manager to be initialized.
wait_for_extension_manager() {
    trace "waiting for extension manager to be ready"
    # We want to match specific error strings, so we can't use try() directly.
    local count=0 max=30 message
    while true; do
        run --separate-stderr rdctl api /extensions
        if ((status == 0 || ++count >= max)); then
            break
        fi
        message=$(jq_output .message)
        output="$message" assert_output "503 Service Unavailable"
        sleep 10
    done
    trace "$count/$max tries: wait_for_extension_manager"
}

# See definition of `State` in
# pkg/rancher-desktop/backend/backend.ts for an explanation of each state.
assert_backend_available() {
    RD_TIMEOUT=10s run rdctl api /v1/backend_state
    if ((status == 0)); then
        run jq_output .vmState
        case "$output" in
        ERROR) return 0 ;;
        STARTED) return 0 ;;
        DISABLED) return 0 ;;
        esac
    fi
    return 1
}

wait_for_backend() {
    trace "waiting for backend to be available"
    try --max 60 --delay 10 assert_backend_available
}
