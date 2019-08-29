#!/bin/bash

# Copyright (C) 2018  Red Hat, Inc.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

VERSION="3.3"

# Warning! Be sure to download the latest version of this script from its primary source:
# https://access.redhat.com/security/vulnerabilities/speculativeexecution
# DO NOT blindly trust any internet sources and NEVER do `curl something | bash`!

# This script is meant for simple detection of the vulnerability. Feel free to modify it for your
# environment or needs. For more advanced detection, consider Red Hat Insights:
# https://access.redhat.com/products/red-hat-insights#getstarted


read_array() {
    # Reads lines from stdin and saves them in a global array referenced by a name.
    # Ignore empty lines.
    # It is a poor man's readarray compatible with Bash 3.1.
    #
    # Args:
    #     array_name - name of the global array
    #
    # Side effects:
    #     Overwrites content of the array 'array_name' with lines from stdin

    local array_name="$1"

    local i=0
    while IFS= read -r line; do
        if [[ "$line" ]]; then
            # shellcheck disable=SC1087
            read -r "$array_name[$(( i++ ))]" <<< "$line"
        fi
    done
}


print_array() {
    # Prints array, one element per line.
    #
    # Args:
    #     array_name - name of the global array
    #     prefix - string which should be prefixing each element
    #
    # Prints:
    #     Content of the array, one element per line.

    local array_name="$1[@]"
    local array=( "${!array_name}" )
    local prefix="$2"

    for (( i = 0; i < "${#array[@]}"; i++ )); do
        echo "$prefix${array[i]}"
    done
}


basic_args() {
    # Parses basic commandline arguments and sets basic environment.
    #
    # Args:
    #     parameters - an array of commandline arguments
    #
    # Side effects:
    #     Exits if --help parameters is used
    #     Sets COLOR constants and debug variable

    local parameters=( "$@" )

    RED="\\033[1;31m"
    YELLOW="\\033[1;33m"
    GREEN="\\033[1;32m"
    BOLD="\\033[1m"
    RESET="\\033[0m"
    for parameter in "${parameters[@]}"; do
        if [[ "$parameter" == "-h" || "$parameter" == "--help" ]]; then
            echo "Usage: $( basename "$0" ) [-n | --no-colors] [-d | --debug]"
            exit 1
        elif [[ "$parameter" == "-n" || "$parameter" == "--no-colors" ]]; then
            RED=""
            YELLOW=""
            GREEN=""
            BOLD=""
            RESET=""
        elif [[ "$parameter" == "-d" || "$parameter" == "--debug" ]]; then
            debug=true
        fi
    done
}


basic_reqs() {
    # Prints common disclaimer and checks basic requirements.
    #
    # Args:
    #     CVE - string printed in the disclaimer
    #
    # Side effects:
    #     Exits when 'rpm' command is not available

    local CVE="$1"

    # Disclaimer
    echo
    echo -e "${BOLD}This script (v$VERSION) is primarily designed to detect $CVE"
    echo -e "on supported Red Hat Enterprise Linux systems and kernel packages."
    echo -e "Result may be inaccurate for other RPM based systems.${RESET}"
    echo

    # RPM is required
    if ! command -v rpm &> /dev/null; then
        echo "'rpm' command is required, but not installed. Exiting."
        exit 1
    fi
}


require_root() {
    # Checks if user is root.
    #
    # Side effects:
    #     Exits when user is not root.
    #
    # Notes:
    #     MOCK_EUID can be used to mock EUID variable

    local euid=${MOCK_EUID:-$EUID}

    # Am I root?
    if (( euid != 0 )); then
        echo "This script must run with elevated privileges (e.g. as root)"
        exit 1
    fi
}


check_supported_kernel() {
    # Checks if running kernel is supported.
    #
    # Args:
    #     running_kernel - kernel string as returned by 'uname -r'
    #
    # Side effects:
    #     Exits when running kernel is obviously not supported

    local running_kernel="$1"

    # Check supported platform
    if [[ "$running_kernel" != *".el"[5-8]* ]]; then
        echo -e "${RED}This script is meant to be used only on RHEL 5-8.${RESET}"
        exit 1
    fi
}


get_rhel() {
    # Gets RHEL number.
    #
    # Args:
    #     running_kernel - kernel string as returned by 'uname -r'
    #
    # Prints:
    #     RHEL number, e.g. '5', '6', '7', or '8'

    local running_kernel="$1"

    local rhel
    rhel=$( sed -r -n 's/^.*el([[:digit:]]).*$/\1/p' <<< "$running_kernel" )
    echo "$rhel"
}


check_cpu_vendor() {
    # Checks for supported CPU vendor/model/architecture.
    #
    # Prints:
    #     'Intel', 'AMD', 'POWER'
    #
    # Returns:
    #     0 if supported CPU vendor found, otherwise 1
    #
    # Notes:
    #     MOCK_CPU_INFO_PATH can be used to mock /proc/cpuinfo file

    local cpuinfo_path=${MOCK_CPU_INFO_PATH:-/proc/cpuinfo}

    if grep --quiet "GenuineIntel" "$cpuinfo_path"; then
        echo "Intel"
        return 0
    fi
    if grep --quiet "AuthenticAMD" "$cpuinfo_path"; then
        echo "AMD"
        return 0
    fi
    if grep --quiet "POWER" "$cpuinfo_path"; then
        echo "POWER"
        return 0
    fi

    return 1
}


get_virtualization() {
    # Gets virtualization type.
    #
    # Prints:
    #     Virtualization type, "None", or "virt-what not available"

    local virt

    if command -v virt-what &> /dev/null; then
        virt=$( virt-what 2>&1 | tr '\n' ' ' )
        if [[ "$virt" ]]; then
            echo "$virt"
        else
            echo "None"
        fi
    else
        echo "virt-what not available"
    fi
}


set_default_values() {
    avail_vuln_spectre_v1=0
    vuln_spectre_v1_value=""
    vuln_spectre_v1_mitigation=0

    avail_vuln_spectre_v2=0
    vuln_spectre_v2_value=""
    vuln_spectre_v2_mitigation=0

    avail_vuln_meltdown=0
    vuln_meltdown_value=""
    vuln_meltdown_mitigation=0

    cmd_nopti=0
    cmd_noibrs=0
    cmd_noibpb=0
    cmd_no_rfi_flush=0
    cmd_nospectre_v2=0
    cmd_spectre_v2=0
    cmd_spectre_v2_value=""

    mounted_debugfs=0
    avail_debug_pti=0
    debug_pti=0
    avail_debug_ibpb=0
    debug_ibpb=0
    avail_debug_ibrs=0
    debug_ibrs=0
    avail_debug_retp=0
    debug_retp=0
    avail_debug_rfi_flush=0
    debug_rfi_flush=0

    dmesg_data=0
    dmesg_log_used=0
    dmesg_command_used=0
    dmesg_wrapped=0

    dmesg_pti=0
    dmesg_ibrs=0
    dmesg_not_ibrs=0
    dmesg_ibpb=0
    dmesg_not_ibpb=0
    dmesg_retpoline_tried=0

    cpu_flag_ibpb=0

    unsafe_modules_list_lsmod_modinfo=()
    unsafe_modules_list_dmesg=()

    model_number=""
    model_name=""
    arch=""
}


parse_facts() {
    # Gathers all available information and stores it in global variables. Only store facts and
    # do not draw conclusion in this function for better maintainability.
    #
    # Side effects:
    #     Sets many global boolean flags and content variables
    #
    # Notes:
    #     MOCK_DEBUG_X86_PATH can be used to mock /sys/kernel/debug/x86 directory
    #     MOCK_DEBUG_POWERPC_PATH can be used to mock /sys/kernel/debug/powerpc directory
    #     MOCK_VULNS_PATH can be used to mock /sys/devices/system/cpu/vulnerabilities directory
    #     MOCK_CMDLINE_PATH can be used to mock /proc/cmdline file
    #     MOCK_LOG_DMESG_PATH can be used to mock /var/log/dmesg
    #     MOCK_CPU_INFO_PATH can be used to mock /proc/cpuinfo file

    local debug_x86=${MOCK_DEBUG_X86_PATH:-/sys/kernel/debug/x86}
    local debug_powerpc=${MOCK_DEBUG_POWERPC_PATH:-/sys/kernel/debug/powerpc}
    local vulns=${MOCK_VULNS_PATH:-/sys/devices/system/cpu/vulnerabilities}
    local cmdline_path=${MOCK_CMDLINE_PATH:-/proc/cmdline}
    local dmesg_log_path=${MOCK_LOG_DMESG_PATH:-/var/log/dmesg}
    local cpuinfo_path=${MOCK_CPU_INFO_PATH:-/proc/cpuinfo}

    # Parse CPU vulnerability files
    if [[ -r "${vulns}/spectre_v1"  ]]; then
        avail_vuln_spectre_v1=1
        vuln_spectre_v1_value=$( <"${vulns}/spectre_v1" )
        if ! grep --quiet 'Vulnerable' <<< "$vuln_spectre_v1_value"; then
            vuln_spectre_v1_mitigation=1
        fi
    fi
    if [[ -r "${vulns}/spectre_v2" ]]; then
        avail_vuln_spectre_v2=1
        vuln_spectre_v2_value=$( <"${vulns}/spectre_v2" )
        if ! grep --quiet 'Vulnerable' <<< "$vuln_spectre_v2_value"; then
            vuln_spectre_v2_mitigation=1
        fi
    fi
    if [[ -r "${vulns}/meltdown" ]]; then
        avail_vuln_meltdown=1
        vuln_meltdown_value=$( <"${vulns}/meltdown" )
        if ! grep --quiet 'Vulnerable' <<< "$vuln_meltdown_value"; then
            vuln_meltdown_mitigation=1
        fi
    fi

    # Parse commandline
    if grep --quiet 'nopti' "$cmdline_path"; then
        cmd_nopti=1
    fi
    if grep --quiet 'noibrs' "$cmdline_path"; then
        cmd_noibrs=1
    fi
    if grep --quiet 'noibpb' "$cmdline_path"; then
        cmd_noibpb=1
    fi
    if grep --quiet 'no_rfi_flush' "$cmdline_path"; then
        cmd_no_rfi_flush=1
    fi
    if grep --quiet 'nospectre_v2' "$cmdline_path"; then
        cmd_nospectre_v2=1
    fi
    if grep --quiet '[[:space:]]spectre_v2=' "$cmdline_path"; then
        cmd_spectre_v2=1
        cmd_spectre_v2_value=$( sed -r -n 's/^.*[[:space:]]spectre_v2=([a-zA-Z]+).*$/\1/p' "$cmdline_path" )
    fi

    # Is debugfs mounted?
    if mount | grep --quiet debugfs; then
        mounted_debugfs=1
    fi

    # Parse debugfs files
    if [[ -r "${debug_x86}/pti_enabled" ]]; then
        avail_debug_pti=1
        debug_pti=$( <"${debug_x86}/pti_enabled" )
    fi
    if [[ -r "${debug_x86}/ibpb_enabled" ]]; then
        avail_debug_ibpb=1
        debug_ibpb=$( <"${debug_x86}/ibpb_enabled" )
    fi
    if [[ -r "${debug_x86}/ibrs_enabled" ]]; then
        avail_debug_ibrs=1
        debug_ibrs=$( <"${debug_x86}/ibrs_enabled" )
    fi
    if [[ -r "${debug_x86}/retp_enabled" ]]; then
        avail_debug_retp=1
        debug_retp=$( <"${debug_x86}/retp_enabled" )
    fi
    if [[ -r "${debug_powerpc}/rfi_flush" ]]; then
        avail_debug_rfi_flush=1
        debug_rfi_flush=$( <"${debug_powerpc}/rfi_flush" )
    fi

    # Parse dmesg
    # Read features from dmesg, use log file first, fallback to circular buffer
    if [[ -r "$dmesg_log_path" ]]; then
        dmesg_data=$( <"$dmesg_log_path" )
        # Variable is used for debugging only so disable warning for unused variable
        # shellcheck disable=SC2034
        dmesg_log_used=1
    else
        dmesg_data=$( dmesg )
        dmesg_command_used=1
        if ! grep --quiet 'Linux.version' <<< "$dmesg_data"; then
            dmesg_wrapped=1
        fi
    fi

    # These will not appear if disabled from commandline
    if grep --quiet -e 'x86/pti: Unmapping kernel while in userspace' \
                    -e 'x86/pti: Kernel page table isolation enabled' \
                    -e 'x86/pti: Xen PV detected, disabling' \
                    -e 'x86/pti: Xen PV detected, disabling PTI protection' \
                    -e 'Kernel page table isolation enabled' <<< "$dmesg_data"; then
        dmesg_pti=1
    fi

    # These will appear even if disabled from commandline
    line=$( grep 'FEATURE SPEC_CTRL' <<< "$dmesg_data" | tail -n 1 )  # Check last
    if [[ "$line" ]]; then
        if ! grep --quiet 'Not Present' <<< "$line"; then
            dmesg_ibrs=1
        else
            dmesg_not_ibrs=1
        fi
    fi

    line=$( grep 'FEATURE IBPB_SUPPORT' <<< "$dmesg_data" | tail -n 1 )   # Check last
    if [[ "$line" ]]; then
        if ! grep --quiet 'Not Present' <<< "$line"; then
            dmesg_ibpb=1
        else
            dmesg_not_ibpb=1
        fi
    fi

    # Was the kernel trying to use retpoline or should IBRS be used?
    if grep --quiet 'retpoline' <<< "$dmesg_data"; then
        dmesg_retpoline_tried=1
    fi

    # Check unsafe modules
    unsafe_modules_lines_lsmod_modinfo="$( lsmod | awk '{ if (NR > 1 && system("modinfo " $1 " | grep -q -e \"retpoline:[ ]*Y\"")) print $1 }' )"
    read_array unsafe_modules_list_lsmod_modinfo <<< "$unsafe_modules_lines_lsmod_modinfo"
    unsafe_modules_lines_dmesg="$( sed -r -n "s/^.*module '([^']+)' built without retpoline-enabled compiler.*/\\1/p" <<< "$dmesg_data" )"
    read_array unsafe_modules_list_dmesg <<< "$unsafe_modules_lines_dmesg"

    # Read CPU data
    if [[ "$vendor" == "Intel" || "$vendor" == "AMD" ]]; then
        model_name="$( awk '/model name/ { for(i = 4; i < NF; i++) printf "%s ", $i; print $i; exit }' "$cpuinfo_path" )"
        model_number="$( awk '/model/ && NF == 3 { print $3; exit }' "$cpuinfo_path" )"
    elif [[ "$vendor" == "POWER" ]]; then
        model_name="$( awk '/cpu/ { for(i = 3; i < NF; i++) printf "%s ", $i; print $i; exit }' "$cpuinfo_path" )"
    else
        # Fallback
        model_name="$( awk '/model name/ { for(i = 4; i < NF; i++) printf "%s ", $i; print $i; exit }' "$cpuinfo_path" )"
    fi

    # Read CPU flags
    if grep -E --quiet 'flags[[:space:]]+:.*ibpb' "$cpuinfo_path"; then
        cpu_flag_ibpb=1
    fi

    # Store architecture as `uname -r` does not contain it on RHEL5
    arch=$( uname -m )
}


draw_conclusions() {
    # Draws conclusions based on available system data.
    #
    # Side effects:
    #     Sets many global boolean flags and content variables

    (( avail_vuln_files = avail_vuln_spectre_v1 || avail_vuln_spectre_v2 || avail_vuln_meltdown ))
    (( avail_debug_files = avail_debug_pti || avail_debug_ibpb || avail_debug_ibrs || avail_debug_retp ))
    (( new_kernel = avail_vuln_files || avail_debug_files || dmesg_pti || dmesg_ibrs || dmesg_not_ibrs || dmesg_ibpb || dmesg_not_ibpb ))
    (( retpoline_kernel = avail_vuln_files ))
    (( retpoline_tried = dmesg_retpoline_tried || debug_retp ))

    # dmesg message for IBPB and IBRS does not change when disabled on runtime or using Linux commandline,
    # so it is a good indicator of updated microcode.
    # To be more robust, also if IBPB or IBRS is enabled in the debugfs the microcode is already updated.
    # It is not possible to write '1' in debugfs files without the microcode update.
    (( updated_microcode = dmesg_ibrs || dmesg_ibpb || debug_ibrs || debug_ibpb ))

    if (( ${#unsafe_modules_list_lsmod_modinfo[@]} > 0 )); then
        unsafe_modules_lsmod_modinfo=1
    else
        unsafe_modules_lsmod_modinfo=0
    fi
    if (( ${#unsafe_modules_list_dmesg[@]} > 0 )); then
        unsafe_modules_dmesg=1
    else
        unsafe_modules_dmesg=0
    fi
    (( unsafe_modules = unsafe_modules_lsmod_modinfo || unsafe_modules_dmesg ))
    if [[ "$vuln_spectre_v2_value" =~ "unsafe module" ]]; then
        # In case that detection of unsafe modules fails but vulnerability file still says so
        unsafe_modules=1
    fi

    # Spectre v1
    # ==========
    # With new kernel this mitigation cannot be turned off.
    # Except when the vulnerability file itself says it is vulnerable, then trust the vulnerability file (unsupported arch?).
    (( mitigation_spectre_v1 = vuln_spectre_v1_mitigation || new_kernel && ! (avail_vuln_spectre_v1 && ! vuln_spectre_v1_mitigation) ))
    (( vulnerable_spectre_v1 = ! mitigation_spectre_v1 ))

    # Spectre v2
    # ==========
    # For IBRS/IBPB, if debugfs is available, it won't lie even when commandline was used to disable it.
    # Otherwise we can trust dmesg but only if it was not disabled from commandline. Obviously it was not disabled
    # on runtime, as debugfs is not mounted.
    (( ibrs = avail_debug_ibrs && debug_ibrs || ! avail_debug_ibrs && dmesg_ibrs && ! cmd_noibrs && ! cmd_nospectre_v2 && ! cmd_spectre_v2 ))
    (( ibpb = avail_debug_ibpb && debug_ibpb || ! avail_debug_ibpb && dmesg_ibpb && ! cmd_noibpb && ! cmd_nospectre_v2 && ! cmd_spectre_v2 ))

    if (( avail_vuln_spectre_v2 )); then
        # With retpoline kernel vulnerability file does not lie, EXCEPT the special edge case below.
        (( mitigation_spectre_v2 = vuln_spectre_v2_mitigation ))
    else
        (( mitigation_spectre_v2 = ibrs && ibpb ))
    fi

    # Special edge case #1 for RHEL5 & RHEL6
    edge_case_1=0  # Full retpoline => Retpoline without IBPB
    if [[ "$vuln_spectre_v2_value" =~ "Full retpoline" ]]; then
        # We have to rely on either dmesg, debugfs, or CPU flags
        if (( ! ibpb && ! cpu_flag_ibpb )); then
            edge_case_1=1
            mitigation_spectre_v2=0
        fi
    fi

    # Special edge case #2, #3, and #4 for retpoline on Skylake
    # Retpoline is newly considered good enough mitigation for Spectre v2
    # Message priorities are:
    # - "Vulnerable"
    # - "Vulnerable: Minimal ASM retpoline"
    # - "Vulnerable: Retpoline without IBPB"
    # - "Vulnerable: Retpoline on Skylake+"  (older releases only)
    # - "Vulnerable: Retpoline with unsafe module(s)"
    # - "Mitigation: ..."
    #
    # "Vulnerable: Retpoline on Skylake+" basically means "Mitigation: Full retpoline"
    # However, there are catches:
    # 1) Special edge case #1 may be applicable, check for it the same way
    # 2) Unsafe modules have lower priority, check unsafe modules
    edge_case_2=0  # Retpoline on Skylake => Full retpoline
    edge_case_3=0  # Retpoline on Skylake => Retpoline without IBPB
    edge_case_4=0  # Retpoline on Skylake => Retpoline with unsafe module(s)
    if [[ "$vuln_spectre_v2_value" =~ "Retpoline on Skylake" ]]; then
        # We have to rely on either dmesg, debugfs, or CPU flags
        # We also need to check for unsafe modules
        if (( ! ibpb && ! cpu_flag_ibpb )); then
            edge_case_3=1
            mitigation_spectre_v2=0
        elif (( unsafe_modules )); then
            edge_case_4=1
            mitigation_spectre_v2=0
        else
            edge_case_2=1
            mitigation_spectre_v2=1
        fi
    fi

    (( vulnerable_spectre_v2 = ! mitigation_spectre_v2 ))

    # Meltdown
    # ========

    # For PTI, if debugfs is available, it won't lie even when commandline was used to disable it.
    # Otherwise we can trust dmesg, even when it was disabled from commandline, but rather be safe.
    (( pti = avail_debug_pti && debug_pti || ! avail_debug_pti && dmesg_pti && ! cmd_nopti ))
    (( rfi_flush = avail_debug_rfi_flush && debug_rfi_flush || ! avail_debug_rfi_flush  && ! cmd_no_rfi_flush ))

    if (( avail_vuln_meltdown )); then
        # With retpoline kernel vulnerability file is authoritative source.
        (( mitigation_meltdown = vuln_meltdown_mitigation ))
    else
        if [[ "$vendor" == "POWER" ]]; then
            mitigation_meltdown=0  # On POWER we do not know without vulnerability file
        else
            (( mitigation_meltdown = pti ))
        fi
    fi
    if [[ "$vendor" == "AMD" ]]; then
        not_affected_meltdown_amd=1
    else
        not_affected_meltdown_amd=0
    fi
    (( vulnerable_meltdown = ! mitigation_meltdown && ! not_affected_meltdown_amd ))


    # Results
    # =======

    (( result = vulnerable_spectre_v1 * 2 + vulnerable_spectre_v2 * 4 + vulnerable_meltdown * 8 ))

    # Result strings
    if (( avail_vuln_spectre_v1 )); then
        if (( mitigation_spectre_v1 )); then
            string_spectre_v1="${GREEN}$vuln_spectre_v1_value${RESET}"
        else
            string_spectre_v1="${RED}$vuln_spectre_v1_value${RESET}"
        fi
    else
        if (( mitigation_spectre_v1 )); then
            string_spectre_v1="${GREEN}Mitigated${RESET}"
        else
            string_spectre_v1="${RED}Vulnerable${RESET}"
        fi
    fi

    if (( avail_vuln_spectre_v2 )); then
        # edge_case_1 ... Full retpoline => Retpoline without IBPB
        # edge_case_2 ... Retpoline on Skylake => Full retpoline
        # edge_case_3 ... Retpoline on Skylake => Retpoline without IBPB
        # edge_case_4 ... Retpoline on Skylake => Retpoline with unsafe module(s)
        if (( mitigation_spectre_v2 )); then
            string_spectre_v2="${GREEN}$vuln_spectre_v2_value${RESET}"
            if (( edge_case_2 )); then
                string_spectre_v2="${GREEN}Mitigation: Full retpoline ***${RESET}"
            fi
        else
            string_spectre_v2="${RED}$vuln_spectre_v2_value${RESET}"
            if (( edge_case_1 || edge_case_3 )); then
                string_spectre_v2="${RED}Vulnerable: Retpoline without IBPB ***${RESET}"
            elif (( edge_case_4 )); then
                string_spectre_v2="${RED}Vulnerable: Retpoline with unsafe module(s) ***${RESET}"
            fi
        fi
    else
        if (( mitigation_spectre_v2 )); then
            string_spectre_v2="${GREEN}Mitigated${RESET}"
        else
            string_spectre_v2="${RED}Vulnerable${RESET}"
        fi
    fi

    if (( not_affected_meltdown_amd )); then
        string_meltdown="${GREEN}AMD not affected${RESET}"
    else
        if (( avail_vuln_meltdown )); then
            if (( mitigation_meltdown )); then
                string_meltdown="${GREEN}$vuln_meltdown_value${RESET}"
            else
                string_meltdown="${RED}$vuln_meltdown_value${RESET}"
            fi
        else
            if (( mitigation_meltdown )); then
                string_meltdown="${GREEN}Mitigated${RESET}"
            else
                string_meltdown="${RED}Vulnerable${RESET}"
            fi
        fi
    fi
}


debug_print() {
    # Prints selected variables when debugging is enabled.

    variables=( avail_vuln_spectre_v1 vuln_spectre_v1_value vuln_spectre_v1_mitigation
                avail_vuln_spectre_v2 vuln_spectre_v2_value vuln_spectre_v2_mitigation
                avail_vuln_meltdown vuln_meltdown_value vuln_meltdown_mitigation
                cmd_nopti cmd_noibrs cmd_noibpb cmd_no_rfi_flush cmd_nospectre_v2 cmd_spectre_v2_value
                mounted_debugfs avail_debug_pti debug_pti avail_debug_ibpb debug_ibpb
                avail_debug_ibrs debug_ibrs avail_debug_retp debug_retp
                dmesg_log_used dmesg_command_used dmesg_wrapped
                dmesg_pti dmesg_ibrs dmesg_not_ibrs dmesg_ibpb dmesg_not_ibpb dmesg_retpoline_tried
                model_number model_name cpu_flag_ibpb arch

                running_kernel rhel virtualization vendor unspecified_arch
                avail_vuln_files avail_debug_files new_kernel retpoline_kernel retpoline_tried
                mitigation_spectre_v1 mitigation_spectre_v2 mitigation_meltdown
                updated_microcode ibrs ibpb pti not_affected_meltdown_amd
                vulnerable_spectre_v1 vulnerable_spectre_v2 vulnerable_meltdown
                unsafe_modules_lsmod_modinfo unsafe_modules_dmesg unsafe_modules
                string_spectre_v1 string_spectre_v2 string_meltdown result
                edge_case_1 edge_case_2 edge_case_3 edge_case_4
               )
    for variable in "${variables[@]}"; do
        echo "$variable = *${!variable}*"
    done
    declare -p unsafe_modules_list_lsmod_modinfo
    declare -p unsafe_modules_list_dmesg
    echo
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root  # Needed for virt-what and reading debugfs
    basic_args "$@"
    basic_reqs "Spectre / Meltdown"
    running_kernel=$( uname -r )
    check_supported_kernel "$running_kernel"

    rhel=$( get_rhel "$running_kernel" )
    if (( rhel == 5 )); then
        export PATH="/sbin:/usr/sbin:$PATH"
    fi

    virtualization=$( get_virtualization )

    vendor=$( check_cpu_vendor )
    if (( $? == 1 )); then
        # Architectures other than x86_64, x86, POWER are not supported
        unspecified_arch=1
    else
        unspecified_arch=0
    fi

    set_default_values
    parse_facts
    draw_conclusions

    # Debug prints
    if [[ "$debug" ]]; then
        debug_print
    fi

    # Outputs
    echo -e "Detected CPU vendor: ${BOLD}$vendor${RESET}"
    echo -e "CPU: ${BOLD}$model_name${RESET}"
    if [[ "$model_number" ]]; then
        printf "CPU model: ${BOLD}%d${RESET} (0x%x)\\n" "$model_number" "$model_number"
    fi
    echo -e "Running kernel: ${BOLD}$running_kernel${RESET}"
    echo -e "Architecture: ${BOLD}$arch${RESET}"
    echo -e "Virtualization: ${BOLD}$virtualization${RESET}"
    echo

    # Stop unsupported architectures
    if (( ! avail_vuln_files )); then
        if [[ "$vendor" == "POWER" ]]; then
            echo "This system's kernel does not provide detailed vulnerability information."
            echo "Fallback detection is supported only on Intel/AMD x86/x86_64 for now."
            echo "To use this script on IBM POWER update your kernel."
            echo
            exit 1
        fi
    fi
    if (( unspecified_arch )); then
        echo "This system architecture is not supported by the script at the moment."
        echo "Presently, only Intel/AMD x86/x86_64 and IBM POWER are supported."
        echo
        exit 1
    fi

    # Results
    echo -e "Variant #1 (Spectre): $string_spectre_v1"
    echo -e "CVE-2017-5753 - speculative execution bounds-check bypass"

    if (( vulnerable_spectre_v1 )); then
        if (( ! new_kernel )); then
            echo -e "${YELLOW}* Kernel update not detected${RESET}"
        fi
    fi
    echo

    echo -e "Variant #2 (Spectre): $string_spectre_v2"
    echo -e "CVE-2017-5715 - speculative execution branch target injection"

    if (( vulnerable_spectre_v2 )); then
        if (( ! new_kernel )); then
            echo -e "${YELLOW}* Kernel update not detected${RESET}"
        else
            if (( ! updated_microcode )); then
                echo -e "${YELLOW}* Microcode update not detected${RESET}"
            fi
            if (( ! ibrs && ! retpoline_tried )); then
                echo -e "${YELLOW}* IBRS disabled or not supported${RESET}"
            fi
            if (( ! ibpb )); then
                echo -e "${YELLOW}* IBPB disabled or not supported${RESET}"
            fi
            if (( cmd_noibrs )); then
                echo -e "${YELLOW}* 'noibrs' commandline option${RESET}"
            fi
            if (( cmd_noibpb )); then
                echo -e "${YELLOW}* 'noibpb' commandline option${RESET}"
            fi
            if (( cmd_nospectre_v2 )); then
                echo -e "${YELLOW}* 'nospectre_v2' commandline option${RESET}"
            fi
            if (( cmd_spectre_v2 )); then
                # It is highly probable that it disabled something
                echo -e "${YELLOW}* 'spectre_v2=$cmd_spectre_v2_value' commandline option${RESET}"
            fi
            if (( retpoline_kernel && retpoline_tried )); then
                echo -e "${YELLOW}* Retpoline disabled${RESET}"
                if (( unsafe_modules )); then
                    echo -e "${YELLOW}* Kernel modules without retpoline support:${RESET}"
                    print_array unsafe_modules_list_lsmod_modinfo "  - "
                    print_array unsafe_modules_list_dmesg "  - "
                    if (( ! unsafe_modules_lsmod_modinfo && ! unsafe_modules_dmesg )); then
                        echo "  It seems that the offending module was already unloaded,"
                        echo "  try the following command:"
                        echo "    # grep 'built without retpoline-enabled compiler' /var/log/messages"
                    fi
                fi
            fi
        fi
    fi
    echo

    echo -e "Variant #3 (Meltdown): $string_meltdown"
    echo -e "CVE-2017-5754 - speculative execution permission faults handling"

    if (( vulnerable_meltdown )); then
        if (( ! new_kernel )); then
            echo -e "${YELLOW}* Kernel update not detected${RESET}"
        else
            if (( ! pti )); then
                echo -e "${YELLOW}* PTI disabled${RESET}"
            fi
            if [[ "$vendor" == "POWER" ]]; then
                if (( ! rfi_flush )); then
                    echo -e "${YELLOW}* RFI FLUSH disabled${RESET}"
                fi
            fi
            if (( cmd_no_rfi_flush )); then
                echo -e "${YELLOW}* 'no_rfi_flush' commandline option${RESET}"
            fi
            if (( cmd_nopti )); then
                echo -e "${YELLOW}* 'nopti' commandline option${RESET}"
            fi
        fi
    fi
    echo
    echo

    # Recommendations for better detection
    if (( ! mounted_debugfs || ! retpoline_kernel )); then
        echo -e "Some of the detailed system information is not available."
        echo -e "To improve mitigation detection:"
        if (( ! mounted_debugfs )); then
            echo -e "${YELLOW}* Mount debugfs which provides debugging files in the path"
            echo -e "  /sys/kernel/debug/[arch], using the following command:${RESET}"
            if (( rhel == 5 || rhel == 6 )); then
                echo -e "    # mount -t debugfs nodev /sys/kernel/debug"
            fi
            if (( rhel == 7 )); then
                echo -e "    # systemctl restart sys-kernel-debug.mount"
            fi
        fi
        if (( ! retpoline_kernel )); then
            echo -e "${YELLOW}* Install retpoline kernel which provides vulnerability files in the"
            echo -e "  following path: /sys/devices/system/cpu/vulnerabilities/*${RESET}"
        fi
        echo
    fi
    if (( dmesg_command_used && dmesg_wrapped )); then
        echo -e "${YELLOW}It seems that dmesg circular buffer already wrapped,${RESET}"
        echo -e "${YELLOW}the results may be inaccurate.${RESET}"
        echo
    fi

    # Additional information
    echo -e "For more information about the vulnerabilities see:"
    echo -e "* https://access.redhat.com/security/vulnerabilities/speculativeexecution"
    echo
    echo -e "For more information about different mitigation techniques, their performance"
    echo -e "impact, and available controls, see:"
    echo -e "* https://access.redhat.com/articles/3311301"
    echo
    echo -e "For more information about retpoline mitigation technique, see:"
    echo -e "* https://support.google.com/faqs/answer/7625886"
    echo

    # Additional conditional notes
    if [[ "$virtualization" != "None" ]]; then
        echo -e "For more information about correctly enabling mitigations in VMs, see:"
        echo -e "* https://access.redhat.com/articles/3331571"
        echo
    fi
    if [[ "$virtualization" =~ "vmware" ]]; then
        echo -e "For more information about correctly enabling mitigations in VMWare VMs, see:"
        echo -e "* https://kb.vmware.com/s/article/52085"
        echo
    fi
    if (( ! retpoline_kernel )); then
        echo -e "For more information about minimal kernel versions containing retpoline, see:"
        echo -e "* https://access.redhat.com/solutions/3424111"
        echo
    fi
    if (( unsafe_modules )); then
        echo -e "For more information about retpoline mitigation not working because"
        echo -e "kernel modules which were not compiled with retpoline support were loaded, see:"
        echo -e "* https://access.redhat.com/solutions/3399691"
        echo
    fi
    if (( ! updated_microcode )); then
        echo -e "For more information about microcode updates provided by Red Hat, see:"
        echo -e "* https://access.redhat.com/articles/3436091"
        echo
    fi

    exit "$result"
fi
