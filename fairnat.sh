#!/bin/bash
# Use !/bin/bash -x instead if you want to know what the script does.
# -------------------------------------------------------------------------
# File:         fairnat.sh
# Version:      v0.80 (2005-08-21 01:09 CEST)
# Description:  Traffic Shaping for multiple users on a dedicated linux router
#               using a HTB queue. Please note that this script cannot be run
#               before the internet connection is available (for dialup users)
# Licence:      GPL-2
# Author:       Andreas Klauer <Andreas.Klauer@metamorpher.de>
# Project page: http://www.metamorpher.de/fairnat/
#

# === Variables: ===

# Change this if your file is located elsewhere.
FAIRNAT_CONFIG="/etc/ppp/fairnat.config"

# Please note: There are much more variables, but they are defined in
#              the FAIRNAT_CONFIG file. See example file.

# Workaround for localized (i18ned) binaries:
LC_ALL=C
LANG=C

# === Functions: ===

# -----------------------------------------------------------------------------
# FUNCTION:    rate
# DESCRIPTION:
#   This function takes a rate argument (<number><unit>) and converts it
#   to bps which is used internally for rate calculations. If no unit is
#   specified, 'kbit' is assumed to be compatible with older versions of
#   Fair NAT, where you could specify rates as kbit/s only.
# SEE ALSO:
# -----------------------------------------------------------------------------
function rate
{
    RATE=0
    R_RATE=$1
    R_NUMBER=`$BIN_ECHO "$R_RATE" | $BIN_SED -e "s/[^0-9]//g"`
    R_UNIT=`$BIN_ECHO "$R_RATE" | $BIN_SED -e "s/[0-9]//g"`

    if [ "$R_UNIT" == "" ];
    then
        R_UNIT="kbit"
    fi

    # Let's see which unit we have...
    if [ "$R_UNIT" == "kbps" ]
    then
        R_RATE=$(($R_NUMBER * 1024))
    elif [ "$R_UNIT" == "mbps" ]
    then
        R_RATE=$(($R_NUMBER * 1024 * 1024))
    elif [ "$R_UNIT" == "mbit" ]
    then
        R_RATE=$(($R_NUMBER * 1024 * 1024 / 8))
    elif [ "$R_UNIT" == "kbit" ]
    then
        R_RATE=$(($R_NUMBER * 1024 / 8))
    elif [ "$R_UNIT" == "bps" ]
    then
        R_RATE=$R_NUMBER
    else
        echo "Unknown unit '$R_UNIT'. I only know mbps, mbit, kbit, bps."
    fi

    RATE="$R_RATE"
}

# -----------------------------------------------------------------------------
# FUNCTION:    configure
# DESCRIPTION:
#   This function sets default values for all variables.
#   It has only one parameter: The path/filename for the configuration file.
#   If this configuration file exists, it will be loaded afterwards to replace
#   the default values with the user's own settings.
#
#   The variables are explained in the example fairnat configuration file.
#   Do not modify values here, do it in the config file instead.
#
#   There are also some variables which can't be configured - stuff like your
#   current IP (especially for dynamic IP dialups), subnet, MTU, etc. will be
#   configured automatically. This is done after the config file was loaded.
# SEE ALSO:
# -----------------------------------------------------------------------------
function configure
{
    C_CONFIG_FILE=$1

# System settings:
    BIN_TC=`which tc`
    BIN_IPT=`which iptables`
    BIN_IFC=`which ifconfig`
    BIN_GREP=`which grep`
    BIN_SED=`which sed`
    BIN_ECHO=`which echo`
    BIN_MODPROBE=`which modprobe`

# FEATURES settings:
    FEATURES="PROC MODULES IPT_RESET IPT_NAT IPT_FORWARD QOS_DOWN QOS_UP"

# LAN settings:
    DEV_LAN=eth0
    RATE_LAN=5000

# User settings:
    USERS="1 2 3"
    PORTS=""
    CLASS_MODE="default"
    BORROW=1
    CEIL_USER_UP=0
    CEIL_USER_DOWN=0

# Internet settings:
    DEV_NET=ppp0
    RATE_UP=128
    RATE_DOWN=768
    RATE_SUB_PERCENT=5
    RATE_LOCAL_PERCENT=5

# IPP2P support (experimental)
    IPP2P_ENABLE=0
    IPP2P_DROP_ALL=0
    IPP2P_DROP_MARKED=0
    IPP2P_OPTIONS="--ipp2p --apple --bit"
    IPP2P_UDP=0

# Hacks
    MSS_CLAMPING=0
    TTL_SET=0
    HTB_MPU=0
    HTB_OVERHEAD=0
    FAIRNAT_PREFIX="FAIRNAT"

# Now that all variables have default values set, replace the ones
# defined by the user in the configuration file:
    [ -f $C_CONFIG_FILE ] && source $C_CONFIG_FILE

# Enable desired features
    for f in $FEATURES;
    do
        eval FEATURE_$f=1
    done;

# Now comes the part that can't be configured by the user:

# Get size of USERS and PORTS. Temporarily convert to Array to do this.
    NUM_USERS=($USERS)
    NUM_USERS=${#NUM_USERS[*]}
    NUM_PORTS=($PORTS)
    NUM_PORTS=${#NUM_PORTS[*]}

# Get some additional stuff from the devices:
    DEV_LAN_IP=`$BIN_IFC $DEV_LAN | \
                $BIN_GREP 'inet addr' | \
                $BIN_SED -e s/^.*inet\ addr://g -e s/\ .*$//g`
    DEV_LAN_SUBNET=`$BIN_ECHO $DEV_LAN_IP | $BIN_SED -e s/\.[0-9]*$//g`
    DEV_NET_IP=`$BIN_IFC $DEV_NET | \
                $BIN_GREP 'inet addr:' | \
                $BIN_SED -e s/^.*inet\ addr://g -e s/\ .*$//g`
    DEV_NET_MTU=`$BIN_IFC $DEV_NET | \
                 $BIN_GREP 'MTU:' | \
                 $BIN_SED -e s/^.*MTU://g -e s/\ .*$//g`

# Convert all rates from KBit to bps.
# Also substract the percentage defined.
    rate "$RATE_UP"
    RATE_UP=$RATE
    RATE_UP=$(($RATE_UP * (100-$RATE_SUB_PERCENT) / 100))
    rate "$RATE_DOWN"
    RATE_DOWN=$RATE
    RATE_DOWN=$(($RATE_DOWN * (100-$RATE_SUB_PERCENT) / 100))
    rate "$RATE_LAN"
    RATE_LAN=$RATE

# Rates per User / Local.
# RATE_LOCAL_PERCENT of bandwidth reserved for local upload.
# We don't shape local download as of yet, so no reservation here.
    RATE_USER_DOWN=$(($RATE_DOWN/$NUM_USERS))
    RATE_USER_UP=$((((100-$RATE_LOCAL_PERCENT)*$RATE_UP)/($NUM_USERS*100)))
    RATE_LOCAL_UP=$(($RATE_LOCAL_PERCENT*$RATE_UP/100))

# Calculate ceiling rate per user.
    if [ "$CEIL_USER_UP" == "0" ];
    then
        CEIL_USER_UP=$RATE_UP;
    else
        rate "$CEIL_USER_UP"
        CEIL_USER_UP=$RATE
    fi

    if [ "$CEIL_USER_DOWN" == "0" ];
    then
        CEIL_USER_DOWN=$RATE_DOWN;
    else
        rate "$CEIL_USER_DOWN"
        CEIL_USER_DOWN=$RATE
    fi

# If the CEIL_USERs are lower than the RATE_USERs, lower the rates.
# This is bad because the user class rates will not add up anymore.
# If this happens the line will never be fully utilized by the users.
    if [ $CEIL_USER_UP -lt $RATE_USER_UP ]
    then
        echo "Warning: Specified CEIL_USER_UP is lower than RATE_UP / Number of Users. Underfull link."
        RATE_USER_UP=$CEIL_USER_UP;
    fi

    if [ $CEIL_USER_DOWN -lt $RATE_USER_DOWN ]
    then
        echo "Warning: Specified CEIL_USER_DOWN is lower than RATE_DOWN / Number of Users. Underfull link."
        RATE_USER_DOWN=$CEIL_USER_DOWN;
    fi

# MARK offset:
# Makes sure that class names per user are unique. Leave this value alone
# unless you really have to create 10 or more subclasses per user. Currently,
# the script uses about 5. Since TC does not accept handles above 4 digits
# and I'm too lazy to implement hexadecimal notation, using values >= 40 may
# lead to weird error messages.
    MARK_OFFSET=10

# Hacks:
    if [ $HTB_MPU != 0 ];
    then
        HTB_OPT="$HTB_OPT mpu $HTB_MPU"
    fi

    if [ $HTB_OVERHEAD != 0 ];
    then
        HTB_OPT="$HTB_OPT overhead $HTB_OVERHEAD"
    fi

# Some abbreviations:
    FN_FORWARD="$FAIRNAT_PREFIX"_FORWARD
    FN_PREROUTING="$FAIRNAT_PREFIX"_PREROUTING
    FN_POSTROUTING="$FAIRNAT_PREFIX"_POSTROUTING
    FN_CHK_TOS="$FAIRNAT_PREFIX"_CHK_TOS
    FN_ACK_TOS="$FAIRNAT_PREFIX"_ACK_TOS
    FN_IPP2PMARK="$FAIRNAT_PREFIX"_IPP2PMARK
    FN_ALL="$FN_FORWARD $FN_PREROUTING $FN_POSTROUTING $FN_CHK_TOS $FN_ACK_TOS $FN_IPP2PMARK"
}

# -----------------------------------------------------------------------------
# FUNCTION:    modules
# DESCRIPTION:
#   This function loads some modules. We don't need them all. But I'm too
#   lazy to sort them out right now. But anyway, nobody in their right mind
#   would use modules for traffic shaping on a router that requires the
#   functionality 24/7.
# SEE ALSO:
# -----------------------------------------------------------------------------
function modules
{
# Load some modules...
# TODO:  Most of them are not required. Needs a cleanup.
    $BIN_MODPROBE ip_tables 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_conntrack 2> /dev/null > /dev/null
    $BIN_MODPROBE iptable_nat 2> /dev/null > /dev/null
    $BIN_MODPROBE ipt_MASQUERADE 2> /dev/null > /dev/null
    $BIN_MODPROBE iptable_filter 2> /dev/null > /dev/null
    $BIN_MODPROBE ipt_state 2> /dev/null > /dev/null
    $BIN_MODPROBE ipt_limit 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_conntrack_ftp 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_conntrack_irc 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_nat_ftp 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_nat_irc 2> /dev/null > /dev/null
    $BIN_MODPROBE ip_queue 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_api 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_atm 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_cbq 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_csz 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_dsmark 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_fifo 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_generic 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_gred 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_htb 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_ingress 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_sfq 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_red 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_sfq 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_tbf 2> /dev/null > /dev/null
    $BIN_MODPROBE sch_teql 2> /dev/null > /dev/null

#   Experimental IPP2P support:
    if [ "$IPP2P_ENABLE" == "1" ];
    then
        $BIN_MODPROBE ipt_ipp2p 2> /dev/null > /dev/null
    fi
}

# -----------------------------------------------------------------------------
# FUNCTION:    iptables
# DESCRIPTION:
#   This sets all IPTables rules that are not user-specific.
#   So all the general IPTables stuff goes here.
# SEE ALSO:
# -----------------------------------------------------------------------------
function iptables
{
# Set TOS for several stuff.
    if [ "$FEATURE_TOS" == "1" ]
    then
        # TODO: Anything missing here? Tell me about it.
        $BIN_IPT -t mangle -A $FN_PREROUTING -p icmp -j TOS --set-tos Minimize-Delay
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp --sport telnet -j TOS --set-tos Minimize-Delay
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp --sport ssh -j TOS --set-tos Minimize-Delay
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp --sport ftp -j TOS --set-tos Minimize-Delay
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp --sport ftp-data -j TOS --set-tos Maximize-Throughput
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp --dport telnet -j TOS --set-tos Minimize-Delay
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp --dport ssh -j TOS --set-tos Minimize-Delay
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp --dport ftp -j TOS --set-tos Minimize-Delay
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp --dport ftp-data -j TOS --set-tos Maximize-Throughput

        # Correcting TOS for large packets with Minimize-Delay-TOS
        $BIN_IPT -t mangle -A $FN_CHK_TOS -p tcp -m length --length 0:512  -j RETURN
        $BIN_IPT -t mangle -A $FN_CHK_TOS -p udp -m length --length 0:1024 -j RETURN
        $BIN_IPT -t mangle -A $FN_CHK_TOS -j TOS --set-tos Maximize-Throughput
        $BIN_IPT -t mangle -A $FN_CHK_TOS -j RETURN

        $BIN_IPT -t mangle -A $FN_PREROUTING -m tos --tos Minimize-Delay -j $FN_CHK_TOS

        # Modifying TOS for TCP control packets: (from www.docum.org / Stef Coene)
        $BIN_IPT -t mangle -A $FN_ACK_TOS -m tos ! --tos Normal-Service -j RETURN
        $BIN_IPT -t mangle -A $FN_ACK_TOS -p tcp -m length --length 0:256 -j TOS --set-tos Minimize-Delay
        $BIN_IPT -t mangle -A $FN_ACK_TOS -p tcp -m length --length 256: -j TOS --set-tos Maximize-Throughput
        $BIN_IPT -t mangle -A $FN_ACK_TOS -j RETURN
        $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp -m tcp --tcp-flags SYN,RST,ACK ACK -j $FN_ACK_TOS
    fi

# Hacks.
    # Read about MSS Clamping in the LARTC Howto.
    if [ "$MSS_CLAMPING" != "0" ];
    then
        $BIN_IPT -A $FN_FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS $MSS_CLAMPING
    fi

    # Set TTL to a specific value. This hack requires a kernel patch.
    # See fairnat.config, Hacks section for details.
    if [ "$TTL_SET" != "0" ]
    then
        $BIN_IPT -t mangle -A $FN_PREROUTING -j TTL --ttl-set $TTL_SET
    fi

# IPP2P support (experimental)
    if [ "$IPP2P_ENABLE" == "1" ];
    then
        if [ "$IPP2P_DROP_ALL" == "1" ];
        then
# P2P traffic should be forbidden in general.
            if [ "$IPP2P_UDP" == "1" ]
            then
                $BIN_IPT -A $FN_FORWARD -m ipp2p $IPP2P_OPTIONS -j DROP
            else
                $BIN_IPT -A $FN_FORWARD -p tcp -m ipp2p $IPP2P_OPTIONS -j DROP
            fi

            if [ "$IPP2P_DROP_MARKED" == "1" ];
            then
# Drop previously marked connections, too.
                $BIN_IPT -t mangle -A $FN_PREROUTING -j CONNMARK --restore-mark
                $BIN_IPT -t mangle -A $FN_PREROUTING -m mark --mark 1 -j DROP
            fi
        else
# P2P should be allowed, but with low prio.

# Create a new chain for IPP2P connection marking:
            $BIN_IPT -t mangle -A $FN_IPP2PMARK -j CONNMARK --restore-mark
            $BIN_IPT -t mangle -A $FN_IPP2PMARK -m mark --mark 1 -j RETURN
            $BIN_IPT -t mangle -A $FN_IPP2PMARK -m ipp2p $IPP2P_OPTIONS -j MARK --set-mark 1
            $BIN_IPT -t mangle -A $FN_IPP2PMARK -m mark --mark 1 -j CONNMARK --save-mark

# Let all tcp packets run through the IPP2P chain:
            $BIN_IPT -t mangle -A $FN_PREROUTING -p tcp -j $FN_IPP2PMARK

# UDP packets as well if enabled:
            if [ "$IPP2P_UDP" == "1" ]
            then
                $BIN_IPT -t mangle -A $FN_PREROUTING -p udp -j $FN_IPP2PMARK
            fi

# NOTE: The mark will be modified again later in the user rules.
        fi
    fi
# End of experimental IPP2P support.
}
# End of iptables.

# -----------------------------------------------------------------------------
# FUNCTION:    parent_class(dev, rate, user_rate, user_ceil, local_rate, local_ceil)
# DESCRIPTION:
#   This function sets up the parent qdisc / class / filter structure.
#   In short, it does everything that does not depend on users.
#
#   Parameters:
#
#   dev:         The device to attach the parent qdisc/class structure to.
#   rate:        The maximum rate the device can do.
#   user_rate:   The rate that should be reserved for users.
#   user_ceil:   The maximum rate users should be allowed to use.
#   local_rate:  The rate that should be reserved for local traffic.
#   local_ceil:  The maximum rate that the local box should be allowed to use.
#
#   The default function creates this structure:
#
#   HTB qdisc
#    |
#    \--- 1:2 Main HTB class ($dev_rate $dev_rate), default 3
#          |
#          \--- 1:3 Local class ($local_rate $dev_rate)
#          \--- 1:1 User class ($net_rate $dev_rate)
#
#   The function user_class will later add further child classes to 1:1.
#
#   If you want a different class structure, you can replace this function
#   by writing a new one (parent_class_foobar). Set CLASS_MODE to "foobar"
#   in fairnat.config and your function will be used instead of the default
#   one. You also need a user_class_foobar function then. Look below for
#   some examples.
#
# SEE ALSO:    user_class
# -----------------------------------------------------------------------------

function parent_class_default
{
    PC_DEV=$1
    PC_RATE=$2
    PC_USER_RATE=$3
    PC_CEIL_USER=$4
    PC_LOCAL_RATE=$5
    PC_LOCAL_CEIL=$6

    # Root QDisc:
    $BIN_TC qdisc add dev $PC_DEV root handle 1: htb default 3

    # Main (fat) device class:
    $BIN_TC class add dev $PC_DEV parent 1: classid 1:2 \
                  htb rate $(($PC_RATE))bps ceil $(($PC_RATE))bps \
                  quantum $DEV_NET_MTU $HTB_OPT

    # Local traffic class with lower prio:
    $BIN_TC class add dev $PC_DEV parent 1:2 classid 1:3 \
                  htb rate $(($PC_LOCAL_RATE))bps ceil $(($PC_LOCAL_CEIL))bps \
                  quantum $DEV_NET_MTU $HTB_OPT prio 5

    # Put PRIO and SFQ on top of local traffic class:
    $BIN_TC qdisc add dev $PC_DEV parent 1:3 handle 2: prio
    $BIN_TC qdisc add dev $PC_DEV parent 2:1 handle 3: sfq perturb 9
    $BIN_TC qdisc add dev $PC_DEV parent 2:2 handle 4: sfq perturb 10
    $BIN_TC qdisc add dev $PC_DEV parent 2:3 handle 5: sfq perturb 11

    # Parent class for user classes:
    $BIN_TC class add dev $PC_DEV parent 1:2 classid 1:1 \
                  htb rate $(($PC_USER_RATE))bps ceil $(($PC_CEIL_USER))bps \
                  quantum $DEV_NET_MTU $HTB_OPT
}

# Wondershaper uses the default parent class structure.
function parent_class_wonder
{
    parent_class_default $*
}

# -----------------------------------------------------------------------------
# FUNCTION:    user_class(device, mark, rate, ceil)
# DESCRIPTION:
#   This function creates the class structure for a single user.
#   All users have the same class structure for up- and download.
#   This ensures that the sharing is fair between users.
#
#   At the moment, the class setup looks about like this:
#
#    HTB class (for bandwidth sharing)
#    |
#    \-- PRIO (for prioritizing interactive traffic)
#        |
#        \--- Interactive:  SFQ (to treat concurrenct connections fairly)
#        \--- Normal:       SFQ
#        \--- High-Traffic: SFQ
#      [ \--- Filesharing:  SFQ (only if IPP2P is enabled) ]
#
#   However, it is possible to treat multiple IPs as a single user (if one
#   guy got more than one machine). So, one user class does not necessarily
#   serve just one IP. See example config file for details.
#
# SEE ALSO:    parent_class
# -----------------------------------------------------------------------------

# The default structure, as described above.
function user_class_default
{
# Make the positional parameters more readable.
# Use UC_ prefix to make sure that these variables belong to User_Class.
    UC_DEV=$1
    UC_MARK=$2
    UC_RATE=$3
    UC_CEIL=$4

# Add filter for this user.
    $BIN_TC filter add dev $UC_DEV parent 1: protocol ip \
                   handle $UC_MARK fw flowid 1:$UC_MARK


# Add HTB class:
    $BIN_TC class add dev $UC_DEV parent 1:1 classid 1:$UC_MARK \
                  htb rate $(($UC_RATE))bps ceil $(($UC_CEIL))bps \
                  quantum $DEV_NET_MTU $HTB_OPT

# Add PRIO qdisc on top of HTB:
    if [ "$IPP2P_ENABLE" == "0" -o "$IPP2P_DROP_ALL" == "1" ];
    then
# Default: IPP2P disabled. Create 3 bands.
        $BIN_TC qdisc add dev $UC_DEV parent 1:$UC_MARK handle $UC_MARK: prio
    else
# Experimental IPP2P support:

# Add another filter to parent QDisc if IPP2P is active:
        $BIN_TC filter add dev $UC_DEV parent 1: protocol ip \
                       handle $(($UC_MARK+1)) fw flowid 1:$UC_MARK

# Create a prio qdisc with 4 classes. All P2P traffic goes into class 4.
        $BIN_TC qdisc add dev $UC_DEV parent 1:$UC_MARK handle $UC_MARK: prio \
                          bands 4

# Add a filter for IPP2P to this qdisc. The rest depends on TOS.
        $BIN_TC filter add dev $UC_DEV parent $UC_MARK: protocol ip \
                       handle $(($UC_MARK+1)) fw flowid $UC_MARK:4

# Add SFQ QDisc on 4th Prio band.
        $BIN_TC qdisc add dev $UC_DEV parent $UC_MARK:4 handle $(($UC_MARK+4)): \
                      sfq perturb 12

# End of experimental IPP2P support
    fi

# Put SFQ qdisc on top of the prio classes:
    $BIN_TC qdisc add dev $UC_DEV parent $UC_MARK:1 handle $(($UC_MARK+1)): \
                      sfq perturb 9
    $BIN_TC qdisc add dev $UC_DEV parent $UC_MARK:2 handle $(($UC_MARK+2)): \
                      sfq perturb 10
    $BIN_TC qdisc add dev $UC_DEV parent $UC_MARK:3 handle $(($UC_MARK+3)): \
                      sfq perturb 11
}

function user_class_wonder
{
# Make the positional parameters more readable.
# Use UC_ prefix to make sure that these variables belong to User_Class.
    UC_DEV=$1
    UC_MARK=$2
    UC_RATE=$3
    UC_CEIL=$4

# Add filter for this user.
    $BIN_TC filter add dev $UC_DEV parent 1: protocol ip \
                   handle $UC_MARK fw flowid 1:$UC_MARK


# Add HTB class:
    $BIN_TC class add dev $UC_DEV parent 1:1 classid 1:$UC_MARK \
                  htb rate $(($UC_RATE))bps ceil $(($UC_CEIL))bps \
                  quantum $DEV_NET_MTU $HTB_OPT

# Wonder-Shaper classes are following:

# high prio class 1:10:

    $BIN_TC class add dev $UC_DEV parent 1:$UC_MARK classid 1:$(($UC_MARK+1)) \
                  htb rate $(($UC_CEIL))bps burst 6k prio 1 \
                  quantum $DEV_NET_MTU $HTB_OPT
    $BIN_TC class add dev $UC_DEV parent 1:$UC_MARK classid 1:$(($UC_MARK+2)) \
                  htb rate $((9*$UC_CEIL/10))bps burst 6k prio 2 \
                  quantum $DEV_NET_MTU $HTB_OPT

# all get Stochastic Fairness:
    $BIN_TC qdisc add dev $UC_DEV parent 1:$(($UC_MARK+1)) handle $(($UC_MARK+1)): \
                  sfq perturb 10
    $BIN_TC qdisc add dev $UC_DEV parent 1:$(($UC_MARK+2)) handle $(($UC_MARK+2)): \
                  sfq perturb 10

# TOS Minimum Delay (ssh, NOT scp) in 1:10:

    $BIN_TC filter add dev $UC_DEV parent 1:$UC_MARK protocol ip prio 10 \
                   u32 match ip tos 0x10 0xff flowid 1:$(($UC_MARK+1))

# ICMP (ip protocol 1) in the interactive class 1:10 so we
# can do measurements & impress our friends:

    $BIN_TC filter add dev $UC_DEV parent 1:$UC_MARK protocol ip prio 10 \
                   u32 match ip protocol 1 0xff flowid 1:$(($UC_MARK+1))


# To speed up downloads while an upload is going on, put ACK packets in
# the interactive class:

    $BIN_TC filter add dev $UC_DEV parent 1:$UC_MARK protocol ip prio 10 \
                   u32 match ip protocol 6 0xff \
                       match u8 0x05 0x0f at 0 \
                       match u16 0x0000 0xffc0 at 2 \
                       match u8 0x10 0xff at 33 \
                       flowid 1:$(($UC_MARK+1))

# Default: Put stuff in class 2.

    $BIN_TC filter add dev $UC_DEV parent 1:$UC_MARK prio 100 \
                   protocol ip handle $UC_MARK fw flowid 1:$(($UC_MARK+2))

# In case of IPP2P: Put it in class 3.

    if [ "$IPP2P_ENABLE" == "1" -a "$IPP2P_DROP_ALL" == "0" ];
    then
        $BIN_TC class add dev $UC_DEV parent 1:$UC_MARK classid 1:$(($UC_MARK+3)) \
                      htb rate $((8*$UC_CEIL/10))bps burst 6k prio 3 \
                      quantum $DEV_NET_MTU $HTB_OPT
        $BIN_TC qdisc add dev $UC_DEV parent 1:$(($UC_MARK+3)) handle $(($UC_MARK+3)): \
                      sfq perturb 10
        $BIN_TC filter add dev $UC_DEV parent 1: prio 1 \
                       protocol ip handle $(($UC_MARK+1)) fw flowid 1:$(($UC_MARK+3))
    fi
}

# -----------------------------------------------------------------------------
# FUNCTION:    fair_nat(ip, mark)
# DESCRIPTION:
#   This function sets up Fair NAT for this ip.
#   mark is the identifier for the user's class this ip belongs to.
#   Packages of this user are marked, so that the Traffic Shaping knows to
#   which User this traffic belongs to.
# SEE ALSO:    forward
# -----------------------------------------------------------------------------
function fair_nat
{
# make positional parameters more readable
    FN_IP=$1

# Add IPTables rules for NAT:
    if [ "$FEATURE_NAT" == "1" ]
    then
        $BIN_IPT -t nat -A $FN_POSTROUTING -o $DEV_NET -s $FN_IP -j MASQUERADE
    fi

# Mark packages (if IPP2P is disabled)
    if [ "$IPP2P_ENABLE" == "0" -o "$IPP2P_DROP_ALL" == "1" ];
    then
        if [ "$FEATURE_QOS_UP" == "1" ]
        then
            $BIN_IPT -t mangle -A $FN_FORWARD -i $DEV_LAN -o $DEV_NET -s $FN_IP \
                     -j MARK --set-mark $MARK
        fi

        if [ "$FEATURE_QOS_DOWN" == "1" ]
        then
            $BIN_IPT -t mangle -A $FN_FORWARD -i $DEV_NET -o $DEV_LAN -d $FN_IP \
                     -j MARK --set-mark $MARK
        fi

# Mark packages (if IPP2P is enabled)
# IPP2P packages will get MARK+1.
# Too bad that there's no --add-mark, it would've made things so much easier.
    else
        if [ "$FEATURE_QOS_UP" == "1" ]
        then
            $BIN_IPT -t mangle -A $FN_FORWARD -i $DEV_LAN -o $DEV_NET -s $FN_IP \
                     -m mark --mark 0 -j MARK --set-mark $MARK
            $BIN_IPT -t mangle -A $FN_FORWARD -i $DEV_LAN -o $DEV_NET -s $FN_IP \
                     -m mark --mark 1 -j MARK --set-mark $(($MARK+1))
        fi

        if [ "$FEATURE_QOS_DOWN" == "1" ]
        then
            $BIN_IPT -t mangle -A $FN_FORWARD -i $DEV_NET -o $DEV_LAN -d $FN_IP \
                     -m mark --mark 0 -j MARK --set-mark $MARK
            $BIN_IPT -t mangle -A $FN_FORWARD -i $DEV_NET -o $DEV_LAN -d $FN_IP \
                     -m mark --mark 1 -j MARK --set-mark $(($MARK+1))
        fi
    fi
}

# -----------------------------------------------------------------------------
# FUNCTION:    forward(ip, port)
# DESCRIPTION:
#   This function sets up port forwarding (DNAT).
#   port is either a single port (a number) or a port range like 1000:2000.
#   Multiple port ranges (like 1000-2000,3100-3200) require multiple calls.
#   Port forwarding will always be done for TCP and UDP.
# SEE ALSO:    nat
# -----------------------------------------------------------------------------
function forward
{
# make positional parameters more readable
    F_IP=$1
    F_PORT=$2

# Add IPTables rules for DNAT:
    $BIN_IPT -t nat -A $FN_PREROUTING -i $DEV_NET -p tcp --dport $PORT -j DNAT --to-destination $F_IP
    $BIN_IPT -t nat -A $FN_PREROUTING -i $DEV_NET -p udp --dport $PORT -j DNAT --to-destination $F_IP

# Marking these packets:

}

# -----------------------------------------------------------------------------
# FUNCTION:    stop_fairnat
# DESCRIPTION:
#   This function will stop everything. It will delete all IPTables rules,
#   all TC qdiscs and classes.
# SEE ALSO:    start_fairnat
# -----------------------------------------------------------------------------
function stop_fairnat
{
# reset qdisc

    if [ "$FEATURE_QOS_UP" == "1" ]
    then
        $BIN_TC qdisc del dev $DEV_NET root 2> /dev/null > /dev/null
        $BIN_TC qdisc del dev $DEV_NET ingress 2> /dev/null > /dev/null
    fi

    if [ "$FEATURE_QOS_DOWN" == "1" ]
    then
        $BIN_TC qdisc del dev $DEV_LAN root 2> /dev/null > /dev/null
        $BIN_TC qdisc del dev $DEV_LAN ingress 2> /dev/null > /dev/null
    fi

# reset iptables:
    if [ "$FEATURE_RESET" == "1" ]
    then
        # reset the default policies in the filter table.
        $BIN_IPT -P INPUT ACCEPT
        $BIN_IPT -P FORWARD ACCEPT
        $BIN_IPT -P OUTPUT ACCEPT

        # reset the default policies in the nat table.
        $BIN_IPT -t nat -P PREROUTING ACCEPT
        $BIN_IPT -t nat -P POSTROUTING ACCEPT
        $BIN_IPT -t nat -P OUTPUT ACCEPT

        # reset the default policies in the mangle table.
        $BIN_IPT -t mangle -P PREROUTING ACCEPT
        $BIN_IPT -t mangle -P OUTPUT ACCEPT

        # flush all the rules in the filter and nat tables.
        $BIN_IPT -F
        $BIN_IPT -t nat -F
        $BIN_IPT -t mangle -F

        # erase all chains that's not default in filter and nat table.
        $BIN_IPT -X
        $BIN_IPT -t nat -X
        $BIN_IPT -t mangle -X
    fi

    # reset only Fair NAT rules here.
    for table in "" "-t nat" "-t mangle";
    do
        for chain in $FN_ALL;
        do
            # create chain
            $BIN_IPT $table -N $chain 2> /dev/null > /dev/null

            # flush chain (in case it already existed)
            $BIN_IPT $table -F $chain 2> /dev/null > /dev/null
        done;
    done;

# If we just reset, add required references to Fair NAT chains.
    if [ "$FEATURE_RESET" == "1" ]
    then
        $BIN_IPT -t nat -A PREROUTING -j $FN_PREROUTING
        $BIN_IPT -t mangle -A PREROUTING -j $FN_PREROUTING
        $BIN_IPT -A FORWARD -j $FN_FORWARD
        $BIN_IPT -t mangle -A FORWARD -j $FN_FORWARD
        $BIN_IPT -t nat -A POSTROUTING -j $FN_POSTROUTING
        $BIN_IPT -t mangle -A POSTROUTING -j $FN_POSTROUTING
    fi
}

# -----------------------------------------------------------------------------
# FUNCTION:    start_fairnat
# DESCRIPTION:
#   This function starts Fair NAT. It configures your linux box to act as
#   router for the users you specified and sets up Traffic Shaping accordingly.
#   Various subroutines are called to accomplish that.
# SEE ALSO:    stop_fairnat
# -----------------------------------------------------------------------------
function start_fairnat
{
# Fair NAT only works if devices and iptables are 'clean'.
# The function stop_fairnat takes care of that.
    stop_fairnat

# Load some modules.
    if [ "$FEATURE_MODULES" == "1" ]
    then
        modules
    fi

# Make sure /proc is set up all right.
    if [ "$FEATURE_PROC" == "1" ]
    then
        # TODO: Anything else required?
        echo 1 > /proc/sys/net/ipv4/ip_forward
    fi

# --- Basic IPTables Setup: ---
    iptables

# --- Traffic Shaping: ---

# User independent class structure for DEV_NET:
    if [ "$FEATURE_QOS_UP" == "1" ]
    then
        parent_class_$CLASS_MODE $DEV_NET $RATE_UP \
            $(($RATE_USER_UP*$NUM_USERS)) $RATE_UP \
            $RATE_LOCAL_UP $RATE_UP
    fi

# User independent class structure for DEV_LAN:
    if [ "$FEATURE_QOS_DOWN" == "1" ]
    then
        parent_class_$CLASS_MODE $DEV_LAN $RATE_LAN \
            $(($RATE_USER_DOWN*$NUM_USERS)) $RATE_DOWN \
            $(($RATE_LAN-($RATE_USER_DOWN*$NUM_USERS))) $RATE_LAN
    fi

# Please see parent_class documentation above for explanation of the parameters
# the first line gives the function name, the device and the device rate
# the second line gives user rate and user ceil
# the third line gives local rate and local ceil.

# --- Fair NAT: ---

# We have to parse a list like "1 2 3 5:6:7 8:9" whereas 1 2 3 are users
# with single IPs and 5 6 7 belong to a single user and 8 9 belong to
# another single user.

    MARK=0
    for user in $USERS;
    do
# user = "1", "2", "3", "5:6:7", "8:9", "1@500kbit", "5:6:7@400kbit|80kbit"

# Set MARK to $user*$MARK_OFFSET. For groups (5:6:7), use the first IP (5).
# This makes it easier to create per-user statistics, since the class numbers
# now resemble the User IPs. Thanks to Udo for this suggestion.
        MARK=`$BIN_ECHO $user | $BIN_SED -e "s/[^0-9].*//g"`
        MARK=$(($MARK*$MARK_OFFSET));

# Check for custom ceil settings of this user
        CUSTOM_USER_DOWN=$CEIL_USER_DOWN
        CUSTOM_USER_UP=$CEIL_USER_UP
        CUSTOM_TEST=`$BIN_ECHO $user | $BIN_SED -e "s/[^@]//g"`

        if [ "$CUSTOM_TEST" != "" ];
        then
            # a custom rate is set, we need to evaluate this now...
            CUSTOM_CHECK=`$BIN_ECHO $user | $BIN_SED -e "s/.*@//"`

            CUSTOM_CHECK_DOWN=`$BIN_ECHO $CUSTOM_CHECK | $BIN_SED -e "s/|.*//"`
            CUSTOM_CHECK_UP=`$BIN_ECHO $CUSTOM_CHECK | $BIN_SED -e "s/.*|//"`

            if [ "$CUSTOM_CHECK_DOWN" != "" ];
            then
                rate $CUSTOM_CHECK_DOWN
                CUSTOM_USER_DOWN=$RATE
            fi

            if [ "$CUSTOM_CHECK_UP" != "" ];
            then
                rate $CUSTOM_CHECK_UP
                CUSTOM_USER_UP=$RATE
            fi
        fi

# Create classes for this user:
        if [ "$BORROW" == "1" ];
        then
            if [ "$FEATURE_QOS_UP" == "1" ]
            then
                user_class_$CLASS_MODE $DEV_NET $MARK $RATE_USER_UP $CUSTOM_USER_UP
            fi

            if [ "$FEATURE_QOS_DOWN" == "1" ]
            then
                user_class_$CLASS_MODE $DEV_LAN $MARK $RATE_USER_DOWN $CUSTOM_USER_DOWN
            fi
        else
            if [ "$FEATURE_QOS_UP" == "1" ]
            then
                 user_class_$CLASS_MODE $DEV_NET $MARK $RATE_USER_UP $RATE_USER_UP
            fi

            if [ "$FEATURE_QOS_DOWN" == "1" ]
            then
                user_class_$CLASS_MODE $DEV_LAN $MARK $RATE_USER_DOWN $RATE_USER_DOWN
            fi
        fi

# If a user has more than one IP, get the single IPs now.
# This sed converts "5:6:7" to "5 6 7" and removes rate-addons (@) and other junk.
        IP_LIST=`$BIN_ECHO $user | $BIN_SED -e "s/:/ /g" -e "s/[^0-9 ].*//"`

# This can now be used in for loop:
        for ip in $IP_LIST;
        do
# Expand IP by adding subnet:
            ip=$DEV_LAN_SUBNET.$ip

# Subroutine fair_nat does the rest.
            fair_nat $ip $MARK
        done;
    done;

# --- Port Forwarding: ---
    if [ "$FEATURE_FORWARD" == 1 ]
    then
        PORT_ARRAY=($PORTS)

        for ((i=0; i<$NUM_PORTS; i+=2));
        do
            IP=$DEV_LAN_SUBNET.${PORT_ARRAY[$i]};
            PORT=${PORT_ARRAY[$i+1]}

            forward $IP $PORT
        done;
    fi
}
# end of start_fairnat

# === Main: ===

# First, we need to configure our script:
CONFIG_CALLED=0

# Maybe the user gave us some config parameter:
for arg in $*
do
# Is the argument a file? Load it as configuration.
    if [ -f $arg ];
    then
        configure $arg
        CONFIG_CALLED=1
        break
    fi
done;

# Otherwise just use the standard config.
if [ "$CONFIG_CALLED" == "0" ];
then
    configure $FAIRNAT_CONFIG
fi

# Does the user want something special?
for arg in $*
do
    case "${arg}" in
        help)
                echo "usage: fairnat.sh [<file>] [info|stop|version]"
                echo "       <file>:   alternative configuration file to use"
                echo "       info:     give info about configuration file"
                echo "       stop:     stop Fair NAT iptables + shaping rules"
                echo "       version:  print version"
                exit 0
                ;;

        version)
                echo "Fair NAT v0.80 maintained by <Andreas.Klauer@metamorpher.de>."
                exit 0
                ;;

        stop)
# The user wants us to stop fairnat and exit.
                stop_fairnat
                echo "Fair NAT stopped."
                exit 0
                ;;

        info)
# Give some information about our config.
                echo "--- FEATURES ---"
                echo "$FEATURES"
                echo "--- LAN ---"
                echo "DEV:        $DEV_LAN"
                echo "IP:         $DEV_LAN_IP"
                echo "SUBNET:     $DEV_LAN_SUBNET"
                echo "RATE:       $RATE_LAN"
                echo "USERS:      $USERS"
                echo "NUM_USERS:  $NUM_USERS"
                echo "PORTS:      $PORTS"
                echo "NUM_PORTS:  $NUM_PORTS"
                echo "CLASS_MODE: $CLASS_MODE"
                echo "--- NET ---"
                echo "DEV:              $DEV_NET"
                echo "IP:               $DEV_NET_IP"
                echo "RATE_SUB_PERCENT: $RATE_SUB_PERCENT"
                echo "RATE_UP:          $RATE_UP ($RATE_USER_UP per user)"
                echo "CEIL_USER_UP:     $CEIL_USER_UP"
                echo "RATE_DOWN:        $RATE_DOWN ($RATE_USER_DOWN per user)"
                echo "CEIL_USER_DOWN:   $CEIL_USER_DOWN"
                echo "RATE_LOCAL_UP:    $RATE_LOCAL_UP ($RATE_LOCAL_PERCENT%)"
                echo "--- IPP2P ---"
                echo "IPP2P_ENABLE:      $IPP2P_ENABLE"
                echo "IPP2P_UDP:         $IPP2P_UDP"
                echo "IPP2P_DROP_ALL:    $IPP2P_DROP_ALL"
                echo "IPP2P_DROP_MARKED: $IPP2P_DROP_MARKED"
                echo "--- HACKS ---"
                echo "MSS_CLAMPING:   $MSS_CLAMPING"
                echo "HTB_MPU:        $HTB_MPU"
                echo "HTB_OVERHEAD:   $HTB_OVERHEAD"
                echo "FAIRNAT_PREFIX: $FAIRNAT_PREFIX"
                echo "--- BINARIES ---"
                echo "iptables: $BIN_IPT"
                echo "tc:       $BIN_TC"
                echo "ifconfig: $BIN_IFC"
                echo "grep:     $BIN_GREP"
                echo "sed:      $BIN_SED"
                echo "echo:     $BIN_ECHO"
                echo "modprobe: $BIN_MODPROBE"
                exit 0
                ;;
    esac
done;

# We are ready to start Fair NAT now.
start_fairnat

# === End of file. ===
