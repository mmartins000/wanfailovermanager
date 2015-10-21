#!/usr/bin/env bash
#
# WAN Failover Manager (WFM) 1.00
# Web: https://sourceforge.net/p/wfmwanfailovermanager/
# Copyright (C) 2014 Marcelo Martins
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Based on WFS 2.03 by Louwrentius
# https://code.google.com/p/wanfailoverscript/
#

VERSION=1.00

CONFIG=/etc/wfm
CONFIG_FILE="$CONFIG/wfm.conf"
service_name="wfm"

if [ -e "$CONFIG_FILE" ]; then
  . $CONFIG_FILE
else
  #create file with defaults
  touch $CONFIG_FILE
  echo -e "TARGETS_FILE=\"$CONFIG/targets.txt\"" >> $CONFIG_FILE
  echo -e "ROUTES_FILE=\"$CONFIG/routes.txt\"" >> $CONFIG_FILE
  echo -e PRIMARY_GW=10.0.0.1 >> $CONFIG_FILE
  echo -e SECONDARY_GW=192.168.1.1 >> $CONFIG_FILE
  echo -e MAX_LATENCY=1000 >> $CONFIG_FILE
  echo -e INTERVAL=20 >> $CONFIG_FILE
  echo -e TEST_COUNT=2 >> $CONFIG_FILE
  echo -e THRESHOLD=3 >> $CONFIG_FILE
  echo -e COOLDOWNDELAY=20 >> $CONFIG_FILE
  echo -e TTL=\"\" >> $CONFIG_FILE
  echo -e COOLDOWNDELAY01=3600 >> $CONFIG_FILE
  echo -e COOLDOWNDELAY02=600 >> $CONFIG_FILE
  echo -e MAIL_TARGET=\"\" >> $CONFIG_FILE
  echo -e DAEMON=1 >> $CONFIG_FILE
  echo -e QUIET=0 >> $CONFIG_FILE
  echo -e PIDFILE=/var/run/wfm.pid >> $CONFIG_FILE
  echo -e PPPOE1_CMD=\"\" >> $CONFIG_FILE
  echo -e PPPOE2_CMD=\"\" >> $CONFIG_FILE
  echo -e SPARE_LOG=1 >> $CONFIG_FILE
  echo -e SPLIT_TARGETS=1 >> $CONFIG_FILE
  echo -e SWITCH_ROUTES=1 >> $CONFIG_FILE
  echo -e PING=\"/bin/ping\" >> $CONFIG_FILE
  echo -e GREP=\"/bin/grep\" >> $CONFIG_FILE
  echo -e SED=\"/bin/sed\" >> $CONFIG_FILE
  echo -e AWK=\"/bin/awk\" >> $CONFIG_FILE
  echo -e PPPOE_STATUS=\"/sbin/pppoe-status\" >> $CONFIG_FILE
  echo -e ROUTE=\"/sbin/route\" >> $CONFIG_FILE
  echo -e IP=\"/sbin/ip\" >> $CONFIG_FILE
  echo -e TAIL=\"/usr/bin/tail\" >> $CONFIG_FILE
  echo -e IFCONFIG=\"/sbin/ifconfig\" >> $CONFIG_FILE
  echo -e CUT=\"/bin/cut\" >> $CONFIG_FILE
  echo -e SORT=\"/bin/sort\" >> $CONFIG_FILE
  echo -e PASTE=\"/usr/bin/paste\" >> $CONFIG_FILE
  echo -e CAT=\"/bin/cat\" >> $CONFIG_FILE
  #
  # If some command must be run after a failover or restore, please specify
  # the commands within these variables.
  #
  echo -e PRIMARY_CMD=\"\" >> $CONFIG_FILE
  echo -e SECONDARY_CMD=\"\" >> $CONFIG_FILE
fi

TARGETS_FAILED=0
S_TARGETS_FAILED=0
ACTIVE_CONNECTION=""
TEST_INTERVAL="$INTERVAL"
NO_OF_TARGETS=ERROR
PRIMARY_LINK=""
SECONDARY_LINK=""
NOW=`date`
TARGETS=`$CAT $TARGETS_FILE`

# --- do not change anything below ---

### Code below added by Marcelo Martins
# Notes to developers:
#  1. I'm not checking -x /bin/touch, /sbin/sysctl, /bin/rm,
#+    /usr/bin/wc, /bin/mv, /bin/date, /bin/sleep, /bin/logger,
#+    /bin/head, /bin/tac
#  2. I prefer to use 'route -n' because of DNS.
#  3. If it gets heavy, 3 checks on test_wan_status should be moved to
#+    init_wfm
#  4. What happens if dev is tap+, tun+ or something else? I don't know.
#  5. Failover with ethernet bonding needs more tests.
#  6. I already got an IP addr .0 on my DSL (commented on verify_ip)
#  7. I know traceroute may not be present. I'm checking.
#  8. I'm not using third party tools by design.
#  9. pppoe-status will be present if rp-pppoe was installed
#+    (usually on systems that connect via PPPoE). I'm checking.
# 10. On my Home dedicated CentOS 6.4 VM on ESXi 5.1 it takes 0.3%
#+    CPU to run the script (with an interval of 20 secs)
# 11. I tried to make it compatible with Debian/Ubuntu.
#+    But I couldn't test the script.
# 12. If this script is not enough, you should try RIP or OSPF :)
# 13. I tried to solve this problem using 'ip route global scope

check_default_gw () {
  ROUTES_DEF=`$ROUTE -n | $GREP "^0.0.0.0"`
  # Check if we have more than 1 def gw
  if [[ `echo $ROUTES_DEF | $GREP -c '^0.0.0.0'` -gt 1 ]]; then
    delete_def_routes
  fi
  
  # Let's find out which one is the def gw
  if [[ `echo $ROUTES_DEF | $GREP '^0.0.0.0' | $AWK '{ print $2; }' | $GREP -c $PRIMARY_GW` -gt 0 ]]; then
    ACTIVE_CONNECTION="PRIMARY"
  elif [[ `echo $ROUTES_DEF | $GREP '^0.0.0.0' | $AWK '{ print $2; }' | $GREP -c $SECONDARY_GW` -gt 0 ]]; then
    ACTIVE_CONNECTION="SECONDARY"
  else
    # no def gw, let's try to add primary gw as def gw
    isup=`$IP route get $PRIMARY_GW | $GREP "dev" | $CUT -d' ' -f3`
    verify_ip $isup
    if [[ $? -gt 0 ]]; then
      #we got an IP addr
      $ROUTE add default gw $PRIMARY_GW >> /dev/null 2>&1
      ACTIVE_CONNECTION="PRIMARY"
    else
      #last attempt to define def gw
      $ROUTE add default gw $SECONDARY_GW >> /dev/null 2>&1
      ACTIVE_CONNECTION="SECONDARY"
    fi
  fi
}

# Checks if it's an IP addr. (not subnet mask, or localhost)
verify_ip () {
  O1=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $1 }'`
  O2=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $2 }'`
  O3=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $3 }'`
  O4=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $4 }'`
  O5=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $5 }'`
  
  if [[ -z $1 ]]; then
     return 2
  elif [[ -z $O1 || -z $O2 || -z $O3 || -z $O4 ]]; then
     return 1
  elif [[ ! -z $(echo $O1 | $SED -e 's/[0-9]//g') || ! -z $(echo $O2 | $SED -e 's/[0-9]//g') || ! -z $(echo $O3 | $SED -e 's/[0-9]//g') || ! -z $(echo $O4 | $SED -e 's/[0-9]//g') ]]; then
     return 1
  elif [[ $O1 -lt 1 || $O2 -lt 0 || $O3 -lt 0 || $O4 -lt 0 ]]; then
     # ip addresses can be .0, i've been there.
     return 1
  elif [[ $O1 -gt 223 || $O2 -gt 255 || $O3 -gt 255 || $O4 -gt 254 ]]; then
     return 1
  elif [[ $O1 -eq 127 && $O2 -eq 0 && $O3 -eq 0 && $O4 -eq 1 ]]; then
     return 1
  elif [[ ! -z $O5 ]]; then
     return 1
  else
     return 0
  fi
}

# Checks if it's a subnet mask.
verify_netmask () {
  O1=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $1 }'`
  O2=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $2 }'`
  O3=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $3 }'`
  O4=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $4 }'`
  O5=`echo $1 | $AWK 'BEGIN { FS = "." } ; { print $5 }'`
  
  if [[ -z $O1 || -z $O2 || -z $O3 || -z $O4 ]]; then
    return 1
  elif [[ ! -z $(echo $O1 | $SED -e 's/[0-9]//g') || ! -z $(echo $O2 | $SED -e 's/[0-9]//g') || ! -z $(echo $O3 | $SED -e 's/[0-9]//g') || ! -z $(echo $O4 | $SED -e 's/[0-9]//g') ]]; then
    return 1
  elif [[ $O1 -lt 0 || $O2 -lt 0 || $O3 -lt 0 || $O4 -lt 0 ]]; then
    return 1
  elif [[ $O1 -gt 255 || $O2 -gt 255 || $O3 -gt 255 || $O4 -gt 255 ]]; then
    return 1
  elif [[ $O1 -eq 0 ]]; then
    return 1
  elif [[ $O2 -eq 0 && ( $O3 -gt 0 || $O4 -gt 0 ) ]]; then
    return 1
  elif [[ $O3 -eq 0 && $O4 -gt 0 ]]; then
    return 1
  elif [[ $O4 -ne 0 && $O4 -ne 128 && $O4 -ne 192 && $O4 -ne 224 && $O4 -ne 240 && $O4 -ne 248 && $O4 -ne 252 && $O4 -ne 254 && $O4 -ne 255 ]]; then
    return 1
  elif [[ $O3 -ne 0 && $O3 -ne 128 && $O3 -ne 192 && $O3 -ne 224 && $O3 -ne 240 && $O3 -ne 248 && $O3 -ne 252 && $O3 -ne 254 && $O3 -ne 255 ]]; then
    return 1
  elif [[ $O2 -ne 0 && $O2 -ne 128 && $O2 -ne 192 && $O2 -ne 224 && $O2 -ne 240 && $O2 -ne 248 && $O2 -ne 252 && $O2 -ne 254 && $O2 -ne 255 ]]; then
    return 1
  elif [[ $O1 -ne 0 && $O1 -ne 128 && $O1 -ne 192 && $O1 -ne 224 && $O1 -ne 240 && $O1 -ne 248 && $O1 -ne 252 && $O1 -ne 254 && $O1 -ne 255 ]]; then
    return 1
  elif [[ $O4 -eq 255 && ($O1 -ne 255 || $O2 -ne 255 || $O3 -ne 255) ]]; then
    return 1
  elif [[ $O3 -eq 255 && ($O1 -ne 255 || $O2 -ne 255) ]]; then
    return 1
  elif [[ $O2 -eq 255 && $O1 -ne 255 ]]; then
    return 1
  elif [[ ! -z $O5 ]]; then
    return 1
  else
    return 0
  fi
}

verify_dev () {
  # if $1 is a valid dev name, returns 0.
  # to check if dev is up, use check_interface_up ()
  dev=$1
  if [ -z $dev ]; then
    return 2
  fi
  
  if [[ (`$IP link | $GREP -c "^[0-9]: $dev"` -eq 1) || (`$IP link | $GREP -c "^[0-9][0-9]: $dev"` -eq 1) ]]; then
    return 0
  else
    return 1
  fi
}

# if the user entered IP addr. or ppp+ as gateway it's alright.
# I can get IP addr. from pppoe-status. But if it's a eth dev, for example,
# I can check ifcfg-dev and traceroute. Otherwise, I would have to guess
# gateway's IP addr. So, if it isn't there, the script MUST fail.
# By design I'm assuming a router doesn't get its config from DHCP server.
# (although I read GATEWAY=)

test_pppoe_gw1 () {
  # Testing if primary gw is a PPPoE interface
  if [[ `echo $PRIMARY_GW | $GREP -i -c "ppp[0-9]"` -gt 0 ]]; then
     P1=`$ROUTE -n | $GREP "$PRIMARY_GW" | $GREP "UH" | $CUT -d' ' -f1`
     verify_ip $P1
     if [[ $? -eq 0 ]]; then
        PRIMARY_IF=$PRIMARY_GW #Will be used on check_pppoe_gw1()
        PRIMARY_GW=$P1
        return 0
     else
        log INFO "Interface $PRIMARY_GW not found."
     fi
  else # it's not PPPoE
    verify_ip $PRIMARY_GW
    if [ $? -eq 0 ]; then
      # ok, it's an IP addr.
      return 0
    fi
    # it's not an IP addr. is it another type of dev?
    # if CentOS/Fedora...
    if [ -f /etc/sysconfig/network-scripts/ifcfg-$PRIMARY_GW ]; then
      getresult=`$CAT /etc/sysconfig/network-scripts/ifcfg-$PRIMARY_GW | $GREP "GATEWAY" | $CUT -d'=' -f2`
    # if Debian/Ubuntu...
    elif [ -f /etc/network/interfaces ]; then
      getresult=`$CAT /etc/network/interfaces | $SED -n "/$x.*inet/{n;p;n;p;n;p;n;p;n;p}" | $GREP "gateway" | $CUT -d' ' -f2`
    fi
    # if none of systems above, $getresult will be blank.
    
    verify_ip $getresult
    if [[ $? -eq 0 ]]; then
      # ok, it's an IP addr. in ifcfg
      PRIMARY_IF=$PRIMARY_GW #Will be used on check_pppoe_gw1()
      PRIMARY_GW=$getresult
      return 0
    else
      # it's not an IP addr. or couldn't find config file
      verify_dev $PRIMARY_GW
      devresult=$?
      if [[ -x /bin/traceroute && $devresult -eq 0 ]]; then
        traceresult=`traceroute -i $PRIMARY_GW 8.8.8.8 | $GREP " 1  " | $AWK '{print $2}'`
        verify_ip $traceresult
        if [[ $? -eq 0 ]]; then
          PRIMARY_IF=$PRIMARY_GW #Will be used on check_pppoe_gw1()
          PRIMARY_GW=$traceresult
          return 0
        fi
      fi
    fi
  fi
  # we MUST fail now.
  log INFO "FAILED. There's no way to get default gateway for $PRIMARY_GW. Link down?"
  log ECHO "FAILED. There's no way to get default gateway for $PRIMARY_GW. Link down?"
  exit 1
}

#ppppoe-status: Link is down -- could not find interface corresponding to
#pppd pid 30817

#pppoe-status: Link is attached to ppp0, but ppp0 is down

test_pppoe_gw2 () {
  # Testing if secondary gw is a PPPoE interface
  if [[ `echo $SECONDARY_GW | $GREP -i -c "ppp[0-9]"` -gt 0 ]]; then
     P2=`$ROUTE -n | $GREP "$SECONDARY_GW" | $GREP "UH" | $CUT -d' ' -f1`
     if [ ! -z $P2 ]; then
       verify_ip $P2
       if [[ $? -eq 0 ]]; then
          SECONDARY_IF=$SECONDARY_GW #Will be used on check_pppoe_gw2()
          SECONDARY_GW=$P2
          return 0
       else
          log INFO "Interface $SECONDARY_GW not found."
       fi
     else
       if [ `$PPPOE_STATUS | $GREP -c "Link.*down"` -eq 1 ]; then
         log ECHO "$SECONDARY_GW is down."
         if [ ! -z $PPPOE2_CMD ]; then
           log ECHO "Running $PPPOE2_CMD. Please wait a few seconds."
           eval $PPPOE2_GW
         fi
       fi
     fi
  else # it's not PPPoE
    verify_ip $SECONDARY_GW
    if [ $? -eq 0 ]; then
      # ok, it's an IP addr.
      return 0
    fi
    # it's not an IP addr. is it another type of dev?
    # if CentOS/Fedora...
    if [ -f /etc/sysconfig/network-scripts/ifcfg-$SECONDARY_GW ]; then
      getresult=`$CAT /etc/sysconfig/network-scripts/ifcfg-$SECONDARY_GW | $GREP "GATEWAY" | $CUT -d'=' -f2`
    # if Debian/Ubuntu...
    elif [ -f /etc/network/interfaces ]; then
      getresult=`$CAT /etc/network/interfaces | $SED -n "/$x.*inet/{n;p;n;p;n;p;n;p;n;p}" | $GREP "gateway" | $CUT -d' ' -f2`
    fi
    # if none of systems above, $getresult will be blank.

    verify_ip $getresult
    if [[ $? -eq 0 ]]; then
      # ok, it's an IP addr. in ifcfg
      SECONDARY_IF=$SECONDARY_GW #Will be used on check_pppoe_gw2()
      SECONDARY_GW=$getresult
      return 0
    else
      verify_dev $SECONDARY_GW
      devresult=$?
      if [[ -x /bin/traceroute && $devresult -eq 0 ]]; then
        traceresult=`traceroute -i $SECONDARY_GW 8.8.8.8 | $GREP " 1  " | $AWK '{print $2}'`
        verify_ip $traceresult
        if [[ $? -eq 0 ]]; then
          SECONDARY_IF=$SECONDARY_GW #Will be used on check_pppoe_gw2()
          SECONDARY_GW=$traceresult
          return 0
        fi
      fi
    fi
  fi
  # we MUST fail now.
  log INFO "FAILED. There's no way to get default gateway for $SECONDARY_GW. Link down?"
  log ECHO "FAILED. There's no way to get default gateway for $SECONDARY_GW. Link down?"
  exit 1
}

get_interface_gw () {
  dev=$1
  
  verify_ip $dev
  if [ $? -eq 0 ]; then
    #it is already an IP addr.
    return 0
  fi
  
  gwipaddr=`$IFCONFIG $dev | $GREP "inet addr" | $AWK '{print $3}' | $CUT -d':' -f2`
  if [ -z $gwipaddr ]; then
    #ip addr not found?
    exists=`$IFCONFIG $dev | $GREP -c "Link"`
    if [ $exists -gt 0 ]; then
      if [[ ( "$dev" == "$PRIMARY_GW" ) || ("$dev" == "$SECONDARY_GW") ]]; then
        log INFO "Looking up $dev IP address: device found but seems to be down."
        return 1
      else
        #dev is invalid?
        log INFO "Looking up $dev IP address: device doesn't match primary or secondary gateways."
        return 2
      fi
    else
      #inexistent
      log INFO "Looking up $dev IP address: device not found."
      return 2
    fi
  elif [ ! -z $gwipaddr ]; then
    verify_ip $gwipaddr
    if [ $? -gt 0 ]; then
      #ip addr invalid
      log INFO "Looking up $dev IP address: invalid GW IP address."
      return 2
    else
      if [ "$dev" == "$PRIMARY_GW" ]; then
        PRIMARY_IF=$PRIMARY_GW #Will be used on check_pppoe_gw1()
        PRIMARY_GW=$gwipaddr
        return 0
      elif [ "$dev" == "$SECONDARY_GW" ]; then
        SECONDARY_IF=$SECONDARY_GW #Will be used on check_pppoe_gw2()
        SECONDARY_GW=$gwipaddr
        return 0
      fi
    fi
  fi
}

# If GW1 is a PPPoE interface, is it up and running?
check_pppoe_gw1 () {
  if [ ! -x $PPPOE_STATUS ]; then
    return 1
  fi
  
  if [[ `echo $PRIMARY_IF | $GREP -i -c "ppp"` -gt 0 ]]; then
     if [[ `$PPPOE_STATUS | $GREP "pppoe-status" | $GREP "up" | $GREP -c $PRIMARY_IF` -eq 0 ]]; then
        log INFO "$PRIMARY_IF is down."
        #run pppoe-script, that should also call dynamic ip client (if it's a script)
        if [ ! -z $PPPOE1_CMD ]; then
           eval $PPPOE1_CMD
           sleep 10
        fi
     fi
  fi
}

#If GW2 is a PPPoE interface, is it up and running?
check_pppoe_gw2 () {
  if [ ! -x $PPPOE_STATUS ]; then
    return 1
  fi
  if [[ `echo $SECONDARY_IF | $GREP -i -c "ppp"` -gt 0 ]]; then
     if [[ `$PPPOE_STATUS | $GREP "pppoe-status" | $GREP "up" | $GREP -c $SECONDARY_IF` -eq 0 ]]; then
        log INFO "$SECONDARY_IF is down."
        #run pppoe-script, that should also call dynamic ip client (if it's a script)
        if [ ! -z $PPPOE2_CMD ]; then
           eval $PPPOE2_CMD
           sleep 10
        fi
     fi
  fi
}

istargetdns () {
# init_wfm creates a static route to $targets. If $target is a DNS server
# we won't talk to them if primary gw is down, because the static route
# will still be there (unless the interface is down -- check_other_interface)
  if [[ ! -z $1 ]]; then
    TESTS=$*
  else
    TESTS=`$CAT "$TARGETS_FILE"`
  fi
  
  D=""
  for x in $TESTS
  do
    F1=`$CAT /etc/resolv.conf | grep -c $x`
    F2=`$CAT /etc/named.conf | grep -c $x`
    F3=`$CAT /var/named/chroot/etc/named.conf | $GREP -c $x`
    if [[ $F1 -gt 0 || $F2 -gt 0 || $F3 -gt 0 ]]; then
      D=$D" "$x
    fi
    D=`echo $D | $SED -e 's/^ *//g' -e 's/ *$//g'`
    TMPD=( $D )
    D_COUNT=${#TMPD[@]}
  done
  
  if [[ ! -z $1 ]]; then   # Called by targets add, replace
    if [[ ! -z $D ]]; then
      log ECHO "WARNING!"
      if [[ $D_COUNT -gt 1 ]]; then
        log ECHO "Targets ($D) are configured as DNS Servers."
        log ECHO "This is a bad idea. They will be unreachable via other gateway."
      else
        log ECHO "Target ($D) is configured as a DNS Server."
        log ECHO "This is a bad idea. It will be unreachable via other gateway."
      fi
    fi
  fi
}

check_other_interface () {
# If primary interface is down, ping $target will work,
# because there will be no more route to target via primary gw.
# So, I must warn and avoid switching back to primary, for now.
  if [ "$1" == "$PRIMARY_GW" ]; then
    test_pppoe_gw2 #inverted. this is correct.
    result=$?
    TEST=$SECONDARY_GW
  else
    test_pppoe_gw1
    result=$?
    TEST=$PRIMARY_GW
  fi
  
  #below should return dev name, not IP addr.
  dev=`$IP route get $TEST | $GREP dev | $CUT -d' ' -f3`
  verify_ip $dev
   if [[ $? != 0 ]]; then
     if [ $result -eq 1 ]; then
       log INFO "Could not find interface for address $TEST"
     else
       log INFO "Could not find interface $TEST"
     fi
     return 1
   fi
}

check_interface_up () {
  dev="$1"
  # $1 should be a valid dev name. to check use verify_dev ()
  # ip link | grep -E "([0-9]|[1-9][0-9]|[1-9][0-9][0-9]): $dev"
  if [[ (`$IP link | $GREP -c -E "^0|[1-9]\d{0,3}: $dev"` -eq 1) ]]; then
    if [[ `$IP link | $GREP -E "^0|[1-9]\d{0,3}: $dev" | $GREP -c "UP"` -eq 1 ]]; then
      # it is up.
      return 0
    else
      # it is down
      return 1
    fi
  else
    # it is down or isn't present.
    return 1
  fi
}

check_interfaceip_up () {
  IPADDR=$1
  resp=`$IP route get $IPADDR | $GREP dev | $CUT -d' ' -f3`
  # resp should be dev name if route is up
  verify_ip $resp
  if [[ $? -eq 0 ]]; then
    # IP address, failed
    return 1
  elif [[ $? -eq 1 ]]; then
    # dev name, ok
    return 0
  else
    # resp is blank?
    return 2
  fi
}

check_targets_route () {
  #if interface *went* down, static routes were lost.
  #if interface *is* down, we won't find its name or add the route
  #test_pppoe_gw1
  #test_pppoe_gw2
  get_interface_gw $PRIMARY_GW
  get_interface_gw $SECONDARY_GW
  pgwisup=`$IP route get $PRIMARY_GW | $GREP dev | $CUT -d' ' -f3`
  verify_ip $pgwisup
  pgw=$?
  sgwisup=`$IP route get $SECONDARY_GW | $GREP dev | $CUT -d' ' -f3`
  verify_ip $sgwisup
  sgw=$?
  
  TARGETS=`$CAT "$TARGETS_FILE"`
  for x in $TARGETS
  do
    split_targets $x
    split=$?
    if [[ $split -eq 0 ]]; then
      #split is disabled. all targets will use primary gw
      if [[ `$ROUTE -n | $GREP -c $x` -eq 0 ]]; then
        log INFO "Adding static route for host $x"
        $ROUTE add -host "$x" gw "$PRIMARY_GW" >> /dev/null 2>&1
      fi
    elif [[ $split -eq 1 ]]; then
      #this target should use primary gw
      if [[ $pgw -gt 0 ]]; then
        if [[ `$ROUTE -n | $GREP $x | $GREP -c $SECONDARY_GW` -eq 1 ]]; then
          #this target is using the other gw. let's change it.
          $ROUTE del -host "$x"
          $ROUTE add -host "$x" gw "$PRIMARY_GW" >> /dev/null 2>&1
          log INFO "Changed static route for host $x to gateway $PRIMARY_GW"
        else
          #there is no route for this target using the other gw
          if [[ `$ROUTE -n | $GREP -c $x` -eq 0 ]]; then
            log INFO "Adding static route for host $x"
            $ROUTE add -host "$x" gw "$PRIMARY_GW" >> /dev/null 2>&1
          fi
        fi
      else
        log INFO "Could not add static route for host $x, interface to $PRIMARY_GW is down."
      fi
    else #$split == 2
      #this target should use secondary gw
      if [[ $sgw -gt 0 ]]; then
        if [[ `$ROUTE -n | $GREP $x | $GREP -c $PRIMARY_GW` -eq 1 ]]; then
          #this target is using the other gw. let's change it.
          $ROUTE del -host "$x"
          $ROUTE add -host "$x" gw "$SECONDARY_GW" >> /dev/null 2>&1
          log INFO "Changed static route for host $x to gateway $SECONDARY_GW"
        else
          #there is no route for this target using the other gw
          if [[ `$ROUTE -n | $GREP -c $x` -eq 0 ]]; then
            log INFO "Adding static route for host $x"
            $ROUTE add -host "$x" gw "$SECONDARY_GW" >> /dev/null 2>&1
          fi
        fi
      else
        log INFO "Could not add static route for host $x, interface to $SECONDARY_GW is down."
      fi
    fi
  done
  
  ### Commented out. Ends up removing routes missing in routes.txt
  #do we need to remove static routes?
  #STATICS=`$ROUTE -n | $GREP UGH | $CUT -d' ' -f1`    
  #for y in $STATICS
  #do
  #  FOUND=0
  #  for x in $TARGETS
  #  do
  #    if [ "$x" == "$y" ]; then
  #      FOUND=1
  #    fi
  #    
  #  done
  #  if [ $FOUND == "0" ]; then
  #    $ROUTE del -host $y
  #    log INFO "Deleting static route for host $y"
  #  fi
  #done
}

cmd_swap () {
  if [[ (-r $CONFIG_FILE) && (-w $CONFIG_FILE) ]]; then
    PGW=`$CAT $CONFIG_FILE | $GREP "PRIMARY_GW" | $CUT -d'=' -f2`
    SGW=`$CAT $CONFIG_FILE | $GREP "SECONDARY_GW" | $CUT -d'=' -f2`
    PRIMARY_GW=$SGW
    SECONDARY_GW=$PGW
    $SED -i "s/^\(PRIMARY_GW\s*=\s*\).*\$/\1$SGW/" $CONFIG_FILE
    $SED -i "s/^\(SECONDARY_GW\s*=\s*\).*\$/\1$PGW/" $CONFIG_FILE
    log ECHO "Primary GW is $PRIMARY_GW and Secondary GW is $SECONDARY_GW"
    log ECHO "WFM will be restarted..." 
    log INFO "Swapped gateways: Primary GW is $PRIMARY_GW and Secondary GW is $SECONDARY_GW"
    log INFO "Swapped gateways: WFM will be restarted..." 
    $0 $service_name restart
  else
    log ECHO "Request to swap gateways failed: Cannot read or write $CONFIG_FILE"
    log INFO "Request to swap gateways failed: Cannot read or write $CONFIG_FILE"
  fi
}

targets_manage () {
  case "$1" in
      "add" )
          targets_add $2 $3 $4 $5 $6 $7 $8
          ;;
      "remove" )
          targets_remove $2 $3 $4 $5 $6 $7 $8
          ;;
      "replace" )
          targets_replace $2 $3
          ;;
      "sort" )
          targets_sort
          ;;
      "shuffle" )
          targets_shuffle
          ;;
      "show" )
          targets_show
          ;;
      "split" )
          targets_split $2
          ;;
        * )
          targets_usage
          ;;
  esac
  exit 0
}

targets_usage () {
  echo -e "Usage: $0 targets [options]\n"
  echo -e "This script uses ping to determine if a target is reachable. If one (or more) targets are reachable"
  echo -e "via some gateway, we establish that the gateway is online and the link is functional."
  echo -e "On the other hand, if we ping one or more targets and we receive no ping reply, we must assume that"
  echo -e "something is wrong with that route and switch the default route to the other gateway."
  echo -e "Make sure that the targets you select are available for ping on the Internet (not dropping ICMP echo requests).\n"
  echo -e "Options:"
  echo -e "\tadd [1-8 IPs]\n\t\t\tAdds targets (IPs) to targets file and routing table."
  echo -e "\t\t\tEx: $0 targets add 1.2.3.4 4.3.2.1 (adds 2 targets to ping routine)\n"
  echo -e "\tremove [1-8 IPs]\n\t\t\tRemoves targets from targets file and routing table.\n"
  echo -e "\t\t\tEx: $0 targets remove 1.2.3.4 4.3.2.1 (removes 2 targets from ping routine)\n"
  echo -e "\treplace [2 IPs]\n\t\t\tReplaces one target for another on targets file and routing table.\n"
  echo -e "\t\t\tEx: $0 targets replace 1.2.3.4 4.3.2.1 (replaces first target for the second)\n"
  echo -e "\tshow \n\t\t\tShows targets file and routing table.\n"
  echo -e "\tshuffle \n\t\t\tShuffles targets in targets file and routing table.\n"
  echo -e "\tsort \n\t\t\tSorts target in targets file and routing table.\n"
  echo -e "\tsplit [enable/disable]\n\t\t\tEnables/disables target splitting and testing of secondary gateway.\n"
  exit 0
}

targets_split () {
  if [ -z $1 ]; then
    echo -e "Usage: $0 targets split [options]\n"
    echo -e "Enables/disables the function that splits the ping targets amongst both gateways. If splitting is disabled"
    echo -e "it will not be possible to test the secondary gateway. Requires restart.\n"
    echo -e "Options:"
    echo -e "\tenable\n\t\t\tEnables the splitting of targets amongst gateways.\n"
    echo -e "\tdisable\n\t\t\tDisables the splitting of targets and the testing the secondary gateway.\n"
    exit 0
  elif [ "$1" == "enable" ]; then
    $SED -i 's/SPLIT_TARGETS=0/SPLIT_TARGETS=1/g' $CONFIG_FILE
    log ECHO "Splitting targets amongst gateways now enabled. Restart WFM."
    log INFO "Splitting targets amongst gateways now enabled. Restart WFM."
  elif [ "$1" == "disable" ]; then
    $SED -i 's/SPLIT_TARGETS=1/SPLIT_TARGETS=0/g' $CONFIG_FILE
    log ECHO "Splitting targets amongst gateways now disabled. Restart WFM."
    log INFO "Splitting targets amongst gateways now disabled. Restart WFM."
  fi
  
}

targets_show () {
  TEMP_FILE=$TEMP_DIR/tab.$$.$RANDOM
  REACH_FILE=$TEMP_DIR/reach.$$.$RANDOM
  #TEMP_FILE="/tmp/j_t.txt"
  #REACH_FILE="/tmp/r_t.txt"
  TARGETS=`$CAT "$TARGETS_FILE"`
  TMPVAR=( $TARGETS )
  NO_OF_TARGETS=${#TMPVAR[@]}
  read_target_matrix
  for x in $TARGETS
  do
    echo -n -e "\t" >> $TEMP_FILE
    $ROUTE -n | $GREP $x >> $TEMP_FILE
    check_target_matrix $x
    matrixresult=$?
    if [ $matrixresult -eq 0 ]; then
      echo -e "[  Reachable  ]" >> $REACH_FILE
    elif [ $matrixresult -eq 1 ]; then
      echo -e "[ UNREACHABLE ]" >> $REACH_FILE
    else
      echo -e "[  Testing... ]" >> $REACH_FILE
    fi
  done
  log ECHO ""
  log ECHO " WFM Targets "
  log ECHO "-----------------------------------------------------------------------------------------------------------------"
  #check_sanity_targets
  #if [ $? -eq 0 ]; then
  if [[ ! -z $TARGETS ]]; then
    log ECHO "On file\t\tOn routing table\t\t\t\t\t\t\t\tStatus"
    log ECHO "Hosts\t\tDestination     Gateway         Genmask         Flags Metric Ref    Use Iface"
    $PASTE $TARGETS_FILE $TEMP_FILE $REACH_FILE
  else
    log ECHO "No target found."
    log ECHO "Type $0 targets to add targets or see other options."
  fi
  log ECHO "-----------------------------------------------------------------------------------------------------------------"
  split_targets
  if [ $? -eq 9 ]; then
    log ECHO " Splitting targets across gateways."
  else
    log ECHO " NOT splitting targets across gateways."
  fi
  log ECHO ""
  rm -rf $TEMP_FILE $REACH_FILE
  exit 0
}

targets_sort () {
  log INFO "Requested to sort targets file (and routes)"
  $CAT $TARGETS_FILE | $SORT -o $TARGETS_FILE
  check_targets_route
  exit 0
}

targets_shuffle () {
  log INFO "Requested to shuffle targets file (and routes)"
  $CAT $TARGETS_FILE | $SORT -R -o $TARGETS_FILE
  check_targets_route
  exit 0
}

targets_add () {
  log INFO "Requested to add static route for hosts $*"
  
  check_writeable_targets
  if [ $? -eq 1 ]; then
    log ECHO "Could not add targets. Targets file is NOT writable."
    exit 1
  fi
  
  for x in $*
  do
    verify_ip $x
    if [[ $? -gt 0 ]]; then
      log INFO "$x does not appear to be a valid IP address."
      log ECHO "$x does not appear to be a valid IP address."
      continue
    fi
    check_repeated_target $x
    if [[ $? -eq 1 ]]; then
      log INFO "Host $x is already included as a target."
      log ECHO "Host $x is already included as a target."
      continue
    fi
    istargetdns $x
    echo -e "$x" >> $TARGETS_FILE
    log INFO "Adding static route for host $x"
    log ECHO "Adding static route for host $x"
    #$ROUTE add -host $x gw $PRIMARY_GW >> /dev/null 2>&1
  done
  check_targets_route
  exit 0
}

targets_replace () {
  verify_ip $1
  if [[ $? -gt 0 ]]; then
    log ECHO "$1 does not appear to be a valid IP address."
    exit 0
  fi
  verify_ip $2
  if [[ $? -gt 0 ]]; then
    log ECHO "$2 does not appear to be a valid IP address."
    exit 0
  fi
  if [[ "$1" == "$2" ]]; then
    log ECHO "Hosts 1 and 2 are the same. ($1)"
    exit 0
  fi
  check_repeated_target $2
  if [[ $? -eq 1 ]]; then
    log ECHO "$2 is already included as a target."
    exit 0
  fi
  
  check_writeable_targets
  if [ $? -eq 1 ]; then
    log ECHO "Could not replace targets. Targets file is NOT writable."
    exit 1
  fi
  
  istargetdns $1
  log INFO "Requested to replace static route from host $1 to $2"
  $SED -i -e "s/$1/$2/" $TARGETS_FILE
  if [[ `$ROUTE -n | $GREP -c "^$1" | $GREP UGH` -eq 1 ]]; then
    log INFO "Replacing static route for host $1 to host $2"
  #  $ROUTE del -host "$1" >> /dev/null 2>&1
  #else
  #  log INFO "Tried to replace targets file, but could not find static route for host $1."
  #  log INFO "Static routes were not changed."
  #  log ECHO "Tried to replace targets file, but could not find static route for host $1."
  #  log ECHO "Static routes were not changed."
  #  exit 0
  fi
  #$ROUTE add -host "$2" gw "$PRIMARY_GW" >> /dev/null 2>&1
  check_targets_route
  exit 0
}

targets_remove () {
  log INFO "Requested to delete static route for hosts $*"

  check_writeable_targets
  if [ $? -eq 1 ]; then
    log ECHO "Could not remove targets. Targets file is NOT writable."
    exit 1
  fi
  
  for x in $*
  do
    verify_ip $x
    if [[ $? -gt 0 ]]; then
      log ECHO "$x does not appear to be a valid IP address."
      continue
    fi
    if [[ `cat $TARGETS_FILE | $GREP -c $x` -gt 0 ]]; then
      $SED -i "/$x/d" $TARGETS_FILE
    else
      log INFO "Could not find target $x in targets file."
      log ECHO "Could not find target $x in targets file."
    fi
    if [[ `$ROUTE -n | $GREP -c "^$x" | $GREP UGH` -eq 1 ]]; then
      log INFO "Deleting static route for host $x"
      #$ROUTE del -host $x >> /dev/null 2>&1
    #else
    #  log INFO "Could not find static route for host $x."
    #  log ECHO "Could not find static route for host $x."
    fi
  done
  check_targets_route
  exit 0
}

targets_delete_all () {
  #called by clean_up ()
  for x in $TARGETS
  do
    if [[ `$ROUTE -n | $GREP "^$x" | $GREP -c UGH` -eq 1 ]]; then
      $ROUTE del -host $x >> /dev/null 2>&1
      log INFO "Clean up: removed target $x"
    fi
  done
  return 0
}

check_repeated_target () {
  if [ -f $TARGETS_FILE ]; then
    if [[ `$CAT $TARGETS_FILE | $GREP -c $1` -gt 0 ]]; then
      return 1
    fi
    return 0
  else
    return 2
  fi
}

check_writeable_targets () {
  if [ -f $TARGETS_FILE ]; then
    if [[ ! -w $TARGETS_FILE ]]; then
      log INFO "Write permission is NOT granted on $TARGETS_FILE"
      return 1
    fi
  else
    return 2
  fi
}

check_sanity_targets () {
  if [ ! -f $TARGETS_FILE ]; then
    touch $TARGETS_FILE
    #no target
    log INFO "No targets in $TARGETS_FILE."
    return 1
  fi
  
  for x in $TARGETS
  do
    #repeated
    if [[ `$CAT $TARGETS_FILE | $GREP -c $x` -gt 1 ]]; then
      check_writeable_targets
      if [ $? -eq 0 ]; then
        log INFO "Found duplicated targets $x in targets file. Removing duplicates."
        TEMP_TARGET_FILE=$TEMP_DIR/rep.target.$$.$RANDOM
        $AWK '!x[$0]++' $TARGETS_FILE > $TEMP_TARGET_FILE
        mv -f $TEMP_TARGET_FILE $TARGETS_FILE
      fi
    fi
    #not valid ip addr.
    verify_ip $x
    if [[ $? -gt 0 ]]; then
      check_writeable_targets
      if [ $? -eq 0 ]; then
        log INFO "Found invalid target $x in targets file. Removing target $x."
        $SED -i "/$x/d" $TARGETS_FILE
      fi
    fi
    
    #also as host route
    HROUTE=`cat $ROUTES_FILE`
    if [[ `echo $HROUTE | $GREP -c $x` -gt 0 ]]; then
      log INFO "Found a route that may conflict with target $x. Type: $0 routes show"
    fi
  done
  
  TARGETS=`cat "$TARGETS_FILE"`
  if [[ -z $TARGETS ]]; then
    #no target left after clean up
    return 1
  else
    #at least one target after clean up
    TMPVAR=( $TARGETS )
    NO_OF_TARGETS=${#TMPVAR[@]}
    return 0
  fi
}

check_sanity_gateways () {
  for x in $*
  do
    vif=0
    vup=0
    verify_ip $x
    if [[ $? -eq 0 ]]; then
      continue
    fi
    #if [[ `$IFCONFIG $x | $GREP -c Link` -gt 0 ]]; then
    #  vif=1
    #  if [[ `$IFCONFIG $x | $GREP -c UP` -eq 1 ]]; then
    #    vup=1
    #  fi
    #fi
    verify_dev $x
    if [[ $? -eq 0 ]]; then
      continue
    else
      log INFO "GW $x does not appear to be a valid IP address or interface."
      log ECHO "GW $x does not appear to be a valid IP address or interface."
      abort=1
    fi
    
    if [[ `$IP link | grep $x | grep -c "UP"` -eq 0 ]]; then
      #found, not UP
      log INFO "GW $x appears to be a valid interface, but it is down."
      log ECHO "GW $x appears to be a valid interface, but it is down."
    fi
    
    #found and UP...
      
    #if CentOS/Fedora...
    if [ -f /etc/sysconfig/network-scripts/ifcfg-$x ]; then
      getgateway=`$CAT /etc/sysconfig/network-scripts/ifcfg-$x | $GREP "GATEWAY" | $CUT -d'=' -f2`
      getbootproto=`$CAT /etc/sysconfig/network-scripts/ifcfg-$x | $GREP "BOOTPROTO" | $CUT -d'=' -f2`
    #if Debian/Ubuntu...
    elif [ -f /etc/network/interfaces ]; then
      getgateway=`$CAT /etc/network/interfaces | $SED -n "/$x.*inet/{n;p;n;p;n;p;n;p;n;p}" | $GREP "gateway" | $CUT -d' ' -f2`
      getbootproto=`$CAT /etc/network/interfaces | $GREP "$x.*dhcp" | $CUT -d' ' -f4`
    fi
    
    #if none above, check below will fail. no problem.      
    if [[ ( -z "$getgateway" ) && ( "$getbootproto" == "dhcp" ) ]]; then
      #def gw is empty or dev is set to use DHCP
      #reminder: server could be using dhcpcd -G, which doesn't set routes
      log INFO "It seems that interface $x is configured to get its IP config. via DHCP. Possibly a bad idea."
    fi
    
    for y in $TARGETS
    do
      if [[ `$IP route get $x | $GREP "dev" | $CUT -d' ' -f3` == "$y" ]]; then
        log INFO "Primary and secondary gateways are on the same network. There's something wrong."
        log ECHO "Primary and secondary gateways are on the same network. There's something wrong."
        abort=1
        break
      fi
    done
  done
  
  if [ "$1" == "$2" ]; then
    log INFO "Primary and secondary gateways have the same address. There's something wrong."
    log ECHO "Primary and secondary gateways have the same address. There's something wrong."
    abort=1
  fi
  
  if [ "$1" == "$2" ]; then
    log INFO "Primary and secondary gateways are on the same network. There's something wrong."
    log ECHO "Primary and secondary gateways are on the same network. There's something wrong."
    abort=1
  fi
  
  if [[ $abort -eq 1 ]]; then
    log INFO "Aborting."
    log ECHO "Aborting."
    exit 1
  fi
  
  #just to let the user know...
  check_ip_forward
  if [[ $? -eq 1 ]]; then
    log INFO "IP forwarding is disabled. For a router, it should probably be enabled."
  fi
}

check_ip_forward () {
  if [ -x /sbin/sysctl ]; then
    ip_forward=`sysctl net.ipv4.ip_forward | $AWK '{print $3}'`
    if [[ $ip_forward -eq 0 ]]; then
      return 1
    fi
    return 0
  fi
  return 2
}

check_whoami () {
  if [[ `whoami` != "root" ]]; then
    #not root
    return 1
  fi
  #root
  return 0
}

viewlog () {
  logfile="/var/log/messages"
  lines=$1
  if [ -z $lines ]; then
    lines=30
  fi
  $CAT $logfile | $GREP "WFM" | $TAIL --lines $lines
  exit 0
}

check_bond () {
  if [ ! -z $1 ]; then
    if [[ -f /proc/net/bonding/$1 ]]; then
      bifs=`$CAT /proc/net/bonding/$1 | $GREP "Slave" | $SED "s/$(printf '\r')\$//" | $SED "s/Slave Interface://" | $SED -e 's/^ *//g' -e 's/ *$//g'`
      if [[ ! -z $bifs ]]; then
        BOND=`echo "[ "$bifs" ]"`
      fi
    else
      BOND=""
    fi
  else
    BOND=""
  fi
}

check_binaries () {
  for x in $*
  do
    if [[ ! -x $x ]]; then
      log ECHO "Could not find executable $x."
      log INFO "Could not find executable $x."
    fi
  done
}

locate_binaries () {
  for x in $*
  do
    if [[ ! -f $x ]]; then
      log ECHO "$x: NOT FOUND."
    else
      if [[ ! -x $x ]]; then
        log ECHO "$x: FOUND, but not executable."
      else
        log ECHO "$x: FOUND."
      fi
    fi
  done
}

div_round_up () {
  v1=$1
  v2=$2
  if [[ `expr $v1 % $v2` -gt 0 ]]; then
    ((v1++))
  fi
  result=`expr $v1 / $v2 | $AWK '{printf("%d\n",$0+=$0<0?0:0.999)}'`
  return $result
}

split_targets () {
  tosplit="$1"

  if [[ -z $tosplit ]]; then
    if [ $SPLIT_TARGETS -eq 0 ]; then
      #tells split is disabled.
      return 8
    elif [ $SPLIT_TARGETS -eq 1 ]; then
      #tells split is enabled.
      return 9
    fi
  fi
  
  if [ $SPLIT_TARGETS -eq 0 ]; then
    #should not split, 0 means primary gw
    return 0
  fi
  
  TMPVAR=( $TARGETS )
  NO_OF_TARGETS=${#TMPVAR[@]}
  div_round_up $NO_OF_TARGETS 2
  FGW=$?
  LINE=`$GREP -n $tosplit $TARGETS_FILE | $CUT -d':' -f1`
  
  if [[ $LINE -gt $FGW ]]; then
    #$1 goes to secondary gw
    return 2
  else
    #$1 goes to primary gw
    return 1
  fi
}

test_gateway () {
  TARGET="$1"
  if [ -z $TARGET ]; then
    return 2
  fi
  
  $PING -W "$MAX_LATENCY" -c "$TEST_COUNT" "$TARGET" >> /dev/null 2>&1
  if [ $? -gt 0 ]; then
    log INFO "Host $TARGET UNREACHABLE."
    return 1
  else
    if [[ ( $SPARE_LOG -eq 1 && $((`date +%-M` % 5)) -eq 0 && $((`date +%-S`)) -lt 21 ) || $SPARE_LOG -eq 0 ]]; then
      log INFO "Host $TARGET reachable."
    fi
  fi
  return 0
}

routes_manage () {
  case "$1" in
      "add" )
          routes_add $2 $3 $4
          ;;
      "remove" )
          routes_remove $2
          ;;
      "show" )
          routes_show
          ;;
        * )
          routes_usage
          ;;
  esac
  exit 0
}

routes_usage () {
  echo -e "Usage: $0 routes [options]\n"
  echo -e "When one route goes down (gw offline), WFM reads the routes file and determines if"
  echo -e "one particular route should be erased temporarily. This way, that traffic will be redirected"
  echo -e "to the default gateway (the only one working now). Then, when the offline gateway comes back,"
  echo -e "WFM will add the route back to the routing table, allowing that traffic out through its normal gw.\n"
  echo -e "Options:"
  echo -e "\tadd [network netmask gw/dev]\n\t\t\tAdds route to routes file."
  echo -e "\t\t\tEx: $0 routes add 1.0.0.0 255.0.0.0 ppp0 (ppp0 is the actual gateway for this route)\n"
  echo -e "\t\t\tEx: $0 routes add 4.3.2.1 10.10.10.1 (no need to enter netmask for a host)\n"
  echo -e "\tremove [network netmask]\n\t\t\tRemoves route from routes file."
  echo -e "\t\t\tWill not be deleted from routing table."
  echo -e "\t\t\tEx: $0 routes remove 1.0.0.0 255.0.0.0\n"
  echo -e "\tshow \n\t\t\tShows routes file.\n"
  exit 0
}

switch_routes () {
  if [[ ( $SWITCH_ROUTES -eq 0 ) || ( -z $SWITCH_ROUTES ) ]]; then
    return 1
  elif [[ $SWITCH_ROUTES -eq 1 ]]; then
    return 0
  fi
  return 2
}

check_repeated_routes () {
  network=$1
  netmask=$2
  if [ -f $TARGETS_FILE ]; then
    if [[ `$CAT $ROUTES_FILE | $GREP -c "^$network.*$netmask"` -gt 1 ]]; then
      return 1
    fi
    return 0
  else
    return 2
  fi
}

check_writeable_routes () {
  if [ -f $TARGETS_FILE ]; then
    if [[ ! -w $ROUTES_FILE ]]; then
      log INFO "Write permission is NOT granted on $ROUTES_FILE"
      return 1
    fi
    return 0
  else
    return 2
  fi
}

routes_show () {
  #ROUTES=`$CAT "$ROUTES_FILE"`
  log ECHO ""
  log ECHO " WFM Routes to be temporarily disabled on failover "
  log ECHO "-----------------------------------------------------------------------------------------------------------------"

  if [[ `wc -c < $ROUTES_FILE` -lt 5 ]]; then
    #if file size is less than 5(!) bytes. nothing is there to work with.
    log ECHO " The routes file is empty."
    log ECHO " Type $0 routes to see available options."
  else
    log ECHO "On file:"
    log ECHO "Network\t\tNetmask\t\tGateway\t\tStatus"
    while read line
    do
      network=`echo $line | $CUT -d' ' -f1`
      netmask=`echo $line | $CUT -d' ' -f2`
      gw=`echo $line | $CUT -d' ' -f3`
      
      ROUTES_ALL=`$ROUTE -n | $GREP "^$network.*$netmask" | $GREP UG`
      ROUTES_NET=`echo -e $ROUTES_ALL | $AWK '{print $1}'`
      ROUTES_MASK=`echo -e $ROUTES_ALL | $AWK '{print $3}'`
      ROUTES_GW=`echo -e $ROUTES_ALL | $AWK '{print $2}'`
      ROUTES_DEV=`echo -e $ROUTES_ALL | $AWK '{print $8}'`
      
      if [[ ("$ROUTES_NET" == "$network") && ("$ROUTES_MASK" == "$netmask") && ("$ROUTES_GW" != "$gw" && "$ROUTES_DEV" != "$gw") ]]; then
        switched="\t[SWITCHED to $ROUTES_GW on $ROUTES_DEV]"
      else
        #only tabbing
        if [ ${#gw} -gt 5 ]; then
          switched="\t[ Normal ]"
        else
          switched="\t\t[ Normal ]"
        fi
      fi
      echo -e "$line $switched\r"
    done <$ROUTES_FILE
  fi
  log ECHO "-----------------------------------------------------------------------------------------------------------------"
  switch_routes
  if [[ $? -eq 0 ]]; then
    log ECHO "Route switching is enabled."
  elif [[ $? -eq 1 ]]; then
    log ECHO "Route switching is disabled."
  fi
  log ECHO ""
}

routes_add () {
  network=$1
  netmask=$2
  gw=$3
  log INFO "Requested to add static route for network $1"
  
  check_writeable_routes
  if [ $? -eq 1 ]; then
    log ECHO "Could not add route. Routes file is NOT writable."
    exit 1
  fi
  
  verify_ip $network
  if [[ $? -gt 0 ]]; then
    log INFO "$network does not appear to be a valid network address."
    log ECHO "$network does not appear to be a valid network address."
    exit 1
  fi
  verify_netmask $netmask
  if [[ $? -gt 0 ]]; then
    log INFO "$netmask does not appear to be a valid subnet mask."
    log ECHO "$netmask does not appear to be a valid subnet mask."
    exit 1
  fi
  check_repeated_routes $network $netmask
  if [[ $? -eq 1 ]]; then
    log INFO "Route for network $network/$netmask is already included."
    log ECHO "Route for network $network/$netmask is already included."
    exit 1
  fi
  verify_dev $gw
  result=$?
  if [[ $result -eq 1 ]]; then
    verify_ip $gw
    if [[ $? -eq 0 ]]; then
      echo -e "$network\t\t$netmask\t$gw" >> $ROUTES_FILE
    else
      log INFO "$gw does not appear to be a valid IP address or dev."
      log ECHO "$gw does not appear to be a valid IP address or dev."
      exit 1
    fi
  elif [[ $result -eq 0 ]]; then
    echo -e "$network\t\t$netmask\t$gw" >> $ROUTES_FILE
  else
    log INFO "Gateway is missing or doesn't make sense: $gw"
    log ECHO "Gateway is missing or doesn't make sense: $gw"
    exit 1
  fi
  log INFO "Adding static route for network $network/$netmask via $gw"
  log ECHO "Adding static route for network $network/$netmask via $gw"
  
  switch_routes
  if [ $? -eq 1 ]; then
    log ECHO "Route switching is disabled."
  fi
  check_routes
  exit 0
}

routes_remove () {
  network=$1
  netmask=$2
  log INFO "Requested to delete static route for network $network/$netmask"
  
  check_writeable_routes
  if [ $? -eq 1 ]; then
    log ECHO "Could not remove route. Routes file is NOT writable."
    exit 1
  fi
  
  verify_ip $network
  if [[ $? -gt 0 ]]; then
    log ECHO "$network does not appear to be a valid network address."
    exit 1
  fi
  if [[ `$CAT $ROUTES_FILE | $GREP -c "^$network.*$netmask"` -gt 0 ]]; then
    $SED -i "/$network\s$netmask/d" $ROUTES_FILE
  else
    log INFO "Could not find route $network/$netmask in routes file."
    log ECHO "Could not find route $network/$netmask in routes file."
  fi
  if [[ `$ROUTE -n | $GREP -c "^$network.*$netmask"` -eq 1 ]]; then
    log INFO "Deleting static route for network $network/$netmask"
    #$ROUTE del -host $x >> /dev/null 2>&1
  #else
  #  log INFO "Could not find static route for network $network/$netmask."
  #  log ECHO "Could not find static route for network $network/$netmask."
  fi

  switch_routes
  if [ $? -eq 1 ]; then
    log ECHO "Route switching is disabled."
  fi
  check_routes
  exit 0
}

check_sanity_routes () {
  if [ ! -f $ROUTES_FILE ]; then
    touch $ROUTES_FILE
  fi

  check_writeable_routes
  if [ $? -eq 1 ]; then
    log INFO "Could not add route. Routes file is NOT writable."
    exit 1
  fi
  
  while read line           
  do           
    network=`echo $line | $CUT -d' ' -f1`
    netmask=`echo $line | $CUT -d' ' -f2`
    gw=`echo $line | $CUT -d' ' -f3`
    
    #repeated
    check_repeated_routes $network $netmask
    if [ $? -eq 1 ]; then
      check_writeable_routes
      if [ $? -eq 0 ]; then
        log INFO "Found duplicated routes for $network/$netmask in routes file. Removing duplicates."
        $AWK '!x[$0]++' $ROUTES_FILE > $CONFIG/routes.new.txt
        mv -f $CONFIG/routes.new.txt $ROUTES_FILE
      fi
    fi
    
    #not valid net addr./netmask
    verify_ip $network
    if [[ $? -gt 0 ]]; then
      check_writeable_routes
      if [ $? -eq 0 ]; then
        log INFO "$network ($netmask) does not appear to be a valid network address. Removing route."
        $SED -i "/$x/d" $ROUTES_FILE
      fi
    fi
    verify_netmask $netmask
    if [[ $? -gt 0 ]]; then
      check_writeable_routes
      if [ $? -eq 0 ]; then
        log INFO "$netmask for network $network does not appear to be a valid network address. Removing route."
        $SED -i "/$x/d" $ROUTES_FILE
      fi
    fi
  done <$ROUTES_FILE
}

check_routes () {
  switch_routes
  if [[ $? -eq 1 ]]; then
    #route switching is disabled.
    return 0
  fi
  
  check_links
  links_result=$?
  if [[ $links_result -eq 3 ]]; then
    #both links are down. life is a bitch and there's nothing I can do about it.
    log INFO "Both links are down. Cannot switch routes."
    return 2
  fi
  
  if [[ `wc -c < $ROUTES_FILE` -lt 5 ]]; then
    #file size is less than 5(!) bytes. nothing is there to work with.
    return 0
  fi
  
  #if interface *went* down, static routes were lost.
  #if interface *is* down, we won't find its name or add the route
  #test_pppoe_gw1
  #test_pppoe_gw2
  get_interface_gw $PRIMARY_GW
  get_interface_gw $SECONDARY_GW
  #pgwisup=`$IP route get $PRIMARY_GW | $GREP dev | $CUT -d' ' -f3`
  #verify_ip $pgwisup
  #pgw=$?
  #sgwisup=`$IP route get $SECONDARY_GW | $GREP dev | $CUT -d' ' -f3`
  #verify_ip $sgwisup
  #sgw=$?

  while read line           
  do           
    network=`echo $line | $CUT -d' ' -f1`
    netmask=`echo $line | $CUT -d' ' -f2`
    gw=`echo $line | $CUT -d' ' -f3`
    
    vup=0
    verify_dev $gw
    if [[ $? -eq 0 ]]; then
      check_interface_up $gw
      if [[ $? -eq 0 ]]; then
        vup=1
      fi
    elif [[ $? -eq 1 ]]; then
      check_interfaceip_up $gw
      if [[ $? -eq 0 ]]; then
        vup=1
      fi
    else
      #gw is blank or invalid. hand input?
      log INFO "Invalid GW while checking routes: $gw, network: $network, netmask: $netmask"
      continue
    fi
    
    verify_ip $network
    if [[ $? -gt 0 ]]; then
      #invalid net address, hand input?
      log INFO "Invalid network address while checking routes: $network, netmask: $netmask, gw: $gw"
      continue
    fi
    verify_netmask $netmask
    if [[ $? -gt 0 ]]; then
      #invalid netmask, hand input?
      log INFO "Invalid network mask while checking routes: $netmask, network: $network, gw: $gw"
      continue
    fi
    
    ROUTES_ALL=`$ROUTE -n | $GREP "^$network.*$netmask"`
    ROUTES_GW=`echo -e $ROUTES_ALL | $AWK '{print $2}'`
    ROUTES_DEV=`echo -e $ROUTES_ALL | $AWK '{print $8}'`
    
    if [[ $links_result -eq 0 ]]; then
      #both links are up. let's go back to normal.
      #if there is no route for this network/host using any gateway
      if [[ `$ROUTE -n | $GREP -c "^$network.*$netmask"` -eq 0 ]]; then
        #there's no route for this network. we'll add one
        verify_ip $gw
        newgateway=$?
        if [ $newgateway -eq 0 ]; then
          gw_key="gw"
        else
          verify_dev $gw
          if [ $? -eq 0 ]; then
            gw_key="dev"
          fi
        fi
        if [ "$netmask" == "255.255.255.255" ]; then
          $ROUTE add -host $network $gw_key $gw >> /dev/null 2>&1
        else
          $ROUTE add -net $network netmask $netmask $gw_key $gw >> /dev/null 2>&1
        fi
        log INFO "Adding static route for nework $network/$netmask"
      fi
    elif [[ $links_result -eq 1 ]]; then
      #only primary is up.
      if [[ ( "$gw" == "$SECONDARY_GW" ) || ( "$gw" == "$SECONDARY_IF" ) ]]; then
        #this route is set to use the other gw (secondary) as def gw
        if [[ ( "$ROUTES_GW" != "$SECONDARY_GW" ) && ( "$ROUTES_DEV" != "$SECONDARY_GW" ) ]]; then
          #and now it is using the offline gateway. let's erase it.
          $ROUTE del -net $network netmask $netmask
          log INFO "Changed static route for network $network/$netmask to gateway $PRIMARY_GW"
        else
          #there is no route for this network using the other gw (secondary, offline)
          if [[ `$ROUTE -n | $GREP -c "^$network.*$netmask"` -eq 0 ]]; then
            #there's no route for this network. we'll add one
            verify_ip $PRIMARY_GW
            newgateway=$?
            if [ $newgateway -eq 0 ]; then
              gw_key="gw"
            else
              verify_dev $PRIMARY_GW
              if [ $? -eq 0 ]; then
                gw_key="dev"
              fi
            fi
            if [ "$netmask" == "255.255.255.255" ]; then
              $ROUTE add -host $network $gw_key $PRIMARY_GW >> /dev/null 2>&1
            else
              $ROUTE add -net $network netmask $netmask $gw_key $PRIMARY_GW >> /dev/null 2>&1
            fi
            log INFO "Adding static route for nework $network/$netmask"
          fi
        fi
      fi
    elif [[ $links_result -eq 2 ]]; then
      #only secondary is up.
      if [[ ( "$gw" == "$PRIMARY_GW" ) || ( "$gw" == "$PRIMARY_IF" ) ]]; then
        #this route is set to use the other gw (primary) as def gw
        if [[ ( "$ROUTES_GW" == "$PRIMARY_GW" ) || ( "$ROUTES_DEV" == "$PRIMARY_GW" ) ]]; then
          #and now it is using the offline gateway. let's erase it.
          $ROUTE del -net $network netmask $netmask
          log INFO "Changed static route for network $network/$netmask to gateway $SECONDARY_GW"
        else
          #there is no route for this network using the other gw (primary, offline)
          if [[ `$ROUTE -n | $GREP -c "^$network.*$netmask"` -eq 0 ]]; then
            #there's no route for this network. we'll add one
            verify_ip $SECONDARY_GW
            newgateway=$?
            if [ $newgateway -eq 0 ]; then
              gw_key="gw"
            else
              verify_dev $SECONDARY_GW
              if [ $? -eq 0 ]; then
                gw_key="dev"
              fi
            fi
            if [ "$netmask" == "255.255.255.255" ]; then
              $ROUTE add -host $network $gw_key $SECONDARY_GW >> /dev/null 2>&1
            else
              $ROUTE add -net $network netmask $netmask $gw_key $SECONDARY_GW >> /dev/null 2>&1
            fi
            log INFO "Adding static route for network $network/$netmask"
          fi
        fi
      fi
    else # >= 4
      #something is wrong.
      #log INFO "It is not possible to determine which route is up for switching. Giving up."
      return 3
    fi
  done <$ROUTES_FILE

  #We do not assume every route is included in routes files.
  #If there are other routes in routing table, we'll leave them there.
}

check_links () {
  if [[ ($PRIMARY_LINK == "ACTIVE") && ( $SECONDARY_LINK == "ACTIVE" ) ]]; then
    return 0
  elif [[ ($PRIMARY_LINK == "ACTIVE") && ( $SECONDARY_LINK == "INACTIVE" ) ]]; then
    return 1
  elif [[ ($PRIMARY_LINK == "INACTIVE") && ( $SECONDARY_LINK == "ACTIVE" ) ]]; then
    return 2
  elif [[ ($PRIMARY_LINK == "INACTIVE") && ( $SECONDARY_LINK == "INACTIVE" ) ]]; then
    return 3
  else #there's something wrong.
    return 4
  fi
}

routes_undo_switch () {
  #called by clean_up ()
  if [ ! -r $CONFIG/routes.txt ]; then
    return 1
  fi
  
  while read line           
  do           
    network=`echo $line | $CUT -d' ' -f1`
    netmask=`echo $line | $CUT -d' ' -f2`
    gw=`echo $line | $CUT -d' ' -f3`

    if [[ `$ROUTE -n | $GREP -c "^$network.*$netmask"` -eq 0 ]]; then
      #there's no route for this network. we'll add one
      verify_ip $gw
      newgateway=$?
      if [ $newgateway -eq 0 ]; then
        gw_key="gw"
      else
        verify_dev $gw
        if [ $? -eq 0 ]; then
          gw_key="dev"
        fi
      fi
      if [ "$netmask" == "255.255.255.255" ]; then
        $ROUTE add -host $network $gw_key $gw >> /dev/null 2>&1
      else
        $ROUTE add -net $network netmask $netmask $gw_key $gw >> /dev/null 2>&1
      fi
    fi
  done <$ROUTES_FILE
}

#target matrix
declare -A matrix

create_target_matrix () {
  #register in array
  i=0
  for x in $TARGETS
  do
    ((i++))
    matrix[$i,1]="$x"
  done
}  

save_target_matrix () {
  mtarget="$1"
  mresult="$2"
  TMPVAR=( $TARGETS )
  NO_OF_TARGETS=${#TMPVAR[@]}

  i=0
  while [ $i -lt $NO_OF_TARGETS ]
  do
    ((i++))
    if [[ ${matrix[$i,1]} == "$mtarget" ]]; then
      matrix[$i,2]="$mresult"
    fi
  done
  print_target_matrix
}

check_target_matrix () {
  mtarget="$1"
  TMPVAR=( $TARGETS )
  NO_OF_TARGETS=${#TMPVAR[@]}
  
  i=0
  while [ $i -lt $NO_OF_TARGETS ]
  do
    ((i++))
    if [[ "${matrix[$i,1]}" == "$mtarget" ]]; then
      if [[ "${matrix[$i,2]}" == "R" ]]; then
        return 0
      elif [[ "${matrix[$i,2]}" == "U" ]]; then
        return 1
      fi
    fi
  done
  return 2
}

read_target_matrix () {
  matrix_file="$CONFIG/matrix.txt"
  i=0
  while read line
  do
    ((i++))
    mtarget=`echo $line | $CUT -d'=' -f1`
    mresult=`echo $line | $CUT -d'=' -f2`
    matrix[$i,1]="$mtarget"
    matrix[$i,2]="$mresult" 
  done <$matrix_file
}

print_target_matrix () {
  TMPVAR=( $TARGETS )
  NO_OF_TARGETS=${#TMPVAR[@]}
  matrix_file="$CONFIG/matrix.txt"
  rm -rf $matrix_file
  touch $matrix_file
  i=0
  while [ $i -lt $NO_OF_TARGETS ]
  do
    ((i++))
    echo -e "${matrix[$i,1]}=${matrix[$i,2]}" >> $matrix_file
  done
}

about () {
  echo -e "\nWAN Failover Manager (WFM) $VERSION"
  echo -e "Copyright 2014 Marcelo Martins"
  echo -e "Web: https://code.google.com/p/wanfailovermanager/"
  echo -e "License: GNU GPL v3\n"
  echo -e "Based on WFS 2.03 by Louwrentius,"
  echo -e "you can find it at https://code.google.com/p/wanfailoverscript/\n"
  exit 0
}

check_writeable_config () {
  if [ -f $CONFIG_FILE ]; then
    if [[ ! -w $CONFIG_FILE ]]; then
      log INFO "Write permission is NOT granted on $CONFIG_FILE"
      return 1
    fi
    return 0
  else
    return 2
  fi
}

config () {
  obj="$1"
  target="$2"
  if [[ ("$obj" == "gw1") || ("$obj" == "gw2") ]]; then
    if [ "$obj" == "gw1" ]; then
      gw="PRIMARY_GW"
    else #gw2
      gw="SECONDARY_GW"
    fi
    if [ ! -z $target ]; then
      verify_ip $target
      if [[ $? -gt 0 ]]; then
        verify_dev $target
        if [[ $? -gt 0 ]]; then
          log ECHO "It seems that the gateway address is not a valid IP address or interface name."
          return 1
        fi
      fi
      check_writeable_config
      if [ $? -eq 0 ]; then
        $SED -i "s/$gw=.*/$gw=$target/g" $CONFIG_FILE
        log INFO "Gateway replaced. Restart WFM."
        log ECHO "Gateway replaced. Restart WFM."
        exit 0
      fi
    else
      log ECHO "Missing IP address or interface name for gateway."
      exit 1
    fi
  elif [ -z $obj ]; then
    echo -e "Usage: $0 config [options]\n"
    echo -e "Options:"
    echo -e "\tgw1 [IP addr/dev name]\n\t\t\tReplaces info for Primary Gateway. Requires restart."
    echo -e "\t\t\tEx: $0 config gw1 10.10.10.1\n"
    echo -e "\tgw2 [IP addr/dev name]\n\t\t\tReplaces info for Secondary Gateway. Requires restart."
    echo -e "\t\t\tEx: $0 config gw2 ppp0\n"
    exit 0
  else
    log ECHO "Parameter not recognized."
    exit 2
  fi
}

delete_def_routes () {
  COUNTER=`$ROUTE -n | $GREP -c "^0.0.0.0"`
  while [ $COUNTER -gt 1 ]; do
    $ROUTE del default >> /dev/null 2>&1
  done
}

clean_up () {
  #perform program exit housekeeping
#  if [ `ps ax | $GREP -c "wfm"` -lt 3 ]; then
    #this is the only instance running, we can proceed

    #targets' route should be excluded
    targets_delete_all
    
    #temp files should be removed, if they exist
    if [ -f $matrix_file ]; then
      rm -rf $matrix_file
    fi
    if [ -f $TEMP_FILE ]; then
      rm -rf $TEMP_FILE
    fi
    if [ -f $REACH_FILE ]; then
      rm -rf $REACH_FILE
    fi
    
    #disabled (temporarily deleted) routes should be added back
    routes_undo_switch
    
    #default gateway will be switched back (only if primary gw isn't default).
    if [[ `$ROUTE -n | $GREP "^0.0.0.0" | $GREP -c $PRIMARY_GW` -eq 0 ]]; then
      #first we delete all default routes
      delete_def_routes
      
      #now, there's no default route. we'll add one
      verify_ip $PRIMARY_GW
      newgateway=$?
      if [ $newgateway -eq 0 ]; then
        gw_key="gw"
      else
        verify_dev $PRIMARY_GW
        if [ $? -eq 0 ]; then
          gw_key="dev"
        fi
      fi
      $ROUTE add default $gw_key $gw >> /dev/null 2>&1
    fi
    
    #let the log reflect that this function was executed (no SIGKILL)
    log INFO "Clean up function was executed as expected. Terminating."
#  fi
  #no explicit exit here
  exit
}

is_running () {
  if [ -e "$PIDFILE" ]; then
    pid=`$CAT $PIDFILE`
    if [[ `ps ax | $GREP "wfm" | $GREP -c $pid` -eq 1 ]]; then
      return 0
    else
      return 1
    fi
  fi
  return 2
}

log_error () {
  LASTLINE="$1"            # argument 1: last line of error occurence
  LASTERR="$2"             # argument 2: error code of last command
  log DEBUG "ERROR: line ${LASTLINE}: exit status of last command: ${LASTERR}"

  # do additional processing: send email or SNMP trap, write result to database, etc.
}

#trap 'log_error ${LINENO} ${$?}' ERR
#trap clean_up SIGHUP SIGINT SIGTERM SIGQUIT
#trap 'exit 127' INT

#From:
#unix.com/tips-tutorials/31944-simple-date-time-calulation-bash.html
date2stamp () {
  date --utc --date "$1" +%s
}

dateDiff () {
  case $1 in
    -s)   sec=1;      shift;;
    -m)   sec=60;     shift;;
    -h)   sec=3600;   shift;;
    -d)   sec=86400;  shift;;
     *)   sec=86400;;
  esac
  dte1=$(date2stamp $1)
  dte2=$(date2stamp $2)
  diffSec=$((dte2-dte1))
  if ((diffSec < 0)); then abs=-1; else abs=1; fi
  echo $((diffSec/sec*abs))
}
##
                                     
### End of code added by Marcelo Martins
### Code below comes from WFS 2.03
### Some parts were modified/included by Marcelo Martins

log () {
  TYPE="$1"
  MSG="$2"
  DATE=`date +%b\ %d\ %H:%M:%S`
  case "$TYPE" in
    "ECHO" )
      echo -e "$MSG"
      ;;
    "ERROR" )
      log2syslog "$TYPE" "$TYPE $MSG"
      ;;
    "DEBUG" )
      if [ "$DEBUG" = "1" ]; then
        if [ "$QUIET" = "0" ]; then
          echo "$DATE" "$MSG"
        fi
        log2syslog "$TYPE" "$TYPE $MSG"
      fi
      ;;
    "INFO" )
      if [ "$QUIET" = "0" ] && [ "$DEBUG" = "1" ]; then
        echo "$DATE $MSG" 
      fi
      log2syslog "$TYPE" "$TYPE $MSG"
      ;;
  esac
}

log2mail () {
  SUBJECT="$1"
  BODY="$2"
  DATE=`date +%b\ %d\ %H:%M:%S`
  if [ ! -z "$MAIL_TARGET" ]; then
    echo "$DATE - $BODY" | mail -s "$SUBJECT" "$MAIL_TARGET" &
  fi
}

log2syslog () {
  TYPE=`echo "$1" | $AWK '{print tolower($0)}'`
  MSG="$2"
  echo "$MSG" | logger -t "WFM" -p daemon."$TYPE"
}

init_wfm () {
  check_whoami
  if [ $? -eq 1 ]; then
    log INFO "WFM needs root to add and delete routes. Aborting."
    log ECHO "WFM needs root to add and delete routes. Aborting."
    exit 0
  fi
  check_binaries $PING $GREP $SED $AWK $CUT $ROUTE $IP $TAIL $IFCONFIG
  check_binaries $SORT $PASTE $CAT
  if [[ `echo $PRIMARY_GW | $GREP -c "ppp"` -eq 1 || `echo $SECONDARY_GW | $GREP -c "ppp"` -eq 1 ]]; then
    check_binaries $PPPOE_STATUS
  fi
  check_sanity_gateways $PRIMARY_GW $SECONDARY_GW
  create_target_matrix

  check_sanity_targets
  if [ $? -eq 1 ]; then
    log ERROR "No targets to test availability, targets file $TARGETS_FILE empty?"
    log INFO "To add targets and see other options type $0 targets"
    log ECHO "To add targets and see other options type $0 targets"
    exit 1
  else
    check_targets_route
  fi
}

check_for_pid () {
  if [ -e "$PIDFILE" ]; then
    log ERROR "PID file $PIDFILE exists. Aborting."
    exit 1
  fi
}

display_header () {
    verify_ip $PRIMARY_GW
    if [[ $? -eq 0 ]]; then
      DEV1=`$IP route get $PRIMARY_GW | $GREP dev | $CUT -d' ' -f3`
    else
      DEV1=$PRIMARY_GW
    fi
    verify_ip $SECONDARY_GW
    if [[ $? -eq 0 ]]; then
      DEV2=`$IP route get $SECONDARY_GW | $GREP dev | $CUT -d' ' -f3`
    else
      DEV2=$SECONDARY_GW
    fi
    
    DEST="INFO"
    if [ "$1" == "ECHO" ]; then
      get_interface_gw $PRIMARY_GW
      get_interface_gw $SECONDARY_GW
#      test_pppoe_gw1
#      test_pppoe_gw2
      DEST="ECHO"
    fi
    
    TARGETS=`$CAT "$TARGETS_FILE"`
    for x in $TARGETS
    do
      split_targets $x
      if [ $? -lt 2 ]; then
        P=$P" "$x
      else
        S=$S" "$x
      fi
    done
    TMPVAR=( $TARGETS )
    NO_OF_TARGETS=${#TMPVAR[@]}
    
    #screen blank line
    [ "$DEST" == "ECHO" ] && log $DEST "                                             "
    log $DEST "---------------------------------------------"
    log $DEST " WAN Failover Manager (WFM) $VERSION         "
    log $DEST "---------------------------------------------"
    check_bond $DEV1
    log $DEST " Primary gateway: $PRIMARY_GW via $DEV1 $BOND"
    check_bond $DEV2
    log $DEST " Secondary gateway: $SECONDARY_GW via $DEV2 $BOND"
    if [[ ! -z $PPPOE1_CMD ]]; then
      log $DEST " GW1 CMD (PPPoE): $PPPOE1_CMD"
    fi
    if [[ ! -z $PPPOE2_CMD ]]; then
      log $DEST " GW2 CMD (PPPoE): $PPPOE2_CMD"
    fi
    log $DEST " Ping max latency in secs: $MAX_LATENCY"
    log $DEST " Threshold before failover: $THRESHOLD"
    log $DEST " Number of target hosts: $NO_OF_TARGETS"
    log $DEST " Tests per host: $TEST_COUNT"
    log $DEST "---------------------------------------------"
    
    if [ $DEST == "ECHO" ]; then
      is_running || log $DEST " WFM is NOT RUNNING!"
    fi
    
    DEFGW=`$ROUTE -n | $GREP '^0.0.0.0' | $AWK '{ print "Default GW: "$2" via "$8; }'`
    [ "$DEFGW" == "" ] && DEFGW="NO DEFAULT GATEWAY SET!"
    log $DEST " $DEFGW"
    
    #need to read log to write info on secondary gateway
    if [ -r /var/log/messages ]; then
      #got root?
      result=`tac /var/log/messages | $GREP WFM | $GREP "Secondary WAN" | head -1`
      resultdate=`echo $result | $AWK '{print $3}' | head -1`
      rightnow=`echo $NOW | awk '{print $4}'`
      if [[ `echo $result | grep -c "reachable"` -eq 1 ]]; then
        if [[ `dateDiff -m "$rightnow" "$resultdate"` -lt 11 ]]; then
          log $DEST " Secondary WAN Link is reachable."
        fi
      elif [[ `echo $result | grep -c "UNREACHABLE"` -eq 1 ]]; then
        if [[ `dateDiff -m "$rightnow" "$resultdate"` -lt 11 ]]; then
          log $DEST " Secondary WAN Link is UNREACHABLE."
        fi
      fi
    fi
    
    log $DEST "---------------------------------------------"
    check_ip_forward || log $DEST "IP forwarding is disabled."
    switch_routes
    if [ $? -eq 0 ]; then
      log $DEST " Route switching is enabled."
    else
      log $DEST " Route switching is disabled."
    fi
    split_targets
    if [ $? -eq 9 ]; then
      log $DEST " Splitting targets across gateways."
    else
      log $DEST " NOT splitting targets across gateways."
    fi
    log $DEST " Ping Targets:"
    log $DEST " - Via Primary GW:$P"
    if [[ ! -z $S ]]; then
      log $DEST " - Via Secondary GW:$S"
    fi
    log $DEST "---------------------------------------------"
    
    check_whoami
    if [ $? -eq 0 ]; then
      istargetdns
      if [[ ! -z $D ]]; then
        log $DEST " WARNING!"
        if [[ $D_COUNT -gt 1 ]]; then
          log $DEST " Targets ($D) are configured as DNS Servers."
          log $DEST " They will be unreachable via other gateway."
        else
          log $DEST " Target ($D) is configured as a DNS Server."
          log $DEST " It will be unreachable via other gateway."
        fi
        log $DEST "---------------------------------------------"
      fi
    fi
    #screen blank line
    [ "$DEST" == "ECHO" ] && log $DEST "                                             "
}

#
# This route allows testing if the failed primary link
# Is available again, when in failover mode.
#

test_single_target () {
  TARGET="$1"
  log DEBUG "Test interval between hosts is $TEST_INTERVAL"

  $PING -W "$MAX_LATENCY" -c "$TEST_COUNT" "$TARGET" >> /dev/null 2>&1
  if [ ! "$?" = "0" ]; then
    log INFO "Host $TARGET UNREACHABLE"
    save_target_matrix $TARGET "U"

    if [ "$TARGETS_FAILED" -lt "$THRESHOLD" ]; then
      ((TARGETS_FAILED++)) 
    fi
    TEST_INTERVAL=1
  else
    if [ "$TARGETS_FAILED" -gt "0" ]; then
      ((TARGETS_FAILED--))
    elif [ "$TARGETS_FAILED" -eq "0" ]; then
      save_target_matrix $TARGET "R"
    fi

    log DEBUG "Host $TARGET OK"
    if [ "$ACTIVE_CONNECTION" = "PRIMARY" ]; then
      TEST_INTERVAL="$INTERVAL"
    fi
  fi
}

test_wan_status () {
  #test_pppoe_gw1
  #test_pppoe_gw2
  get_interface_gw $PRIMARY_GW
  get_interface_gw $SECONDARY_GW
  #maybe the next 3 checks below should happen only on init_wfm (). only time will tell.
  check_default_gw
  check_sanity_targets
  check_sanity_routes
  
  check_targets_route
  check_routes
  
  for x in $TARGETS
  do
    split_targets $x
    if [[ $? -lt 2 ]]; then
      #split == 0 || 1, test target using primary gw
      test_single_target $x
      if [ "$TARGETS_FAILED" -gt "0" ]; then
        log INFO "Failed targets testing primary gw is $TARGETS_FAILED, threshold is $THRESHOLD."
      fi
      check_wan_status
      #sleep "$TEST_INTERVAL"
    else
      #split == 2, test target using secondary gw
      test_single_target $x
      if [ "$S_TARGETS_FAILED" -gt "0" ]; then
        log INFO "Failed targets testing secondary gw is $S_TARGETS_FAILED, threshold is $THRESHOLD."
      fi
      check_sgw_status
      sleep "$TEST_INTERVAL"
    fi
  done
}

switch_to_primary () {
  $ROUTE del default gw "$SECONDARY_GW" >> /dev/null 2>&1
  $ROUTE add default gw "$PRIMARY_GW" >> /dev/null 2>&1
  if [[ `$ROUTE -n | $GREP '^0.0.0.0' | $AWK '{ print $2; }'` == "$PRIMARY_GW" ]]; then
    ACTIVE_CONNECTION="PRIMARY"
    PRIMARY_LINK="ACTIVE"
    return 0
  else
    log INFO "Could not switch back to primary."
    return 1
  fi
}

switch_to_secondary () {
  $ROUTE del default gw "$PRIMARY_GW" >> /dev/null 2>&1
  $ROUTE add default gw "$SECONDARY_GW" >> /dev/null 2>&1
  PRIMARY_LINK="INACTIVE"
  if [[ `$ROUTE -n | $GREP '^0.0.0.0' | $AWK '{ print $2; }'` == "$SECONDARY_GW" ]]; then
    ACTIVE_CONNECTION="SECONDARY"
    SECONDARY_LINK="ACTIVE"
    return 0
  else
    log INFO "Could not switch to secondary."
    return 1
  fi
}

check_wan_status () {
  if [ "$TARGETS_FAILED" -ge "$THRESHOLD" ] && [ "$ACTIVE_CONNECTION" = "PRIMARY" ]; then
    log INFO "WAN Link: $ACTIVE_CONNECTION"
    PRIMARY_LINK="INACTIVE"
    test_gateway $PRIMARY_GW
    switch
  elif [ "$ACTIVE_CONNECTION" = "SECONDARY" ]; then
    log INFO "WAN Link: $ACTIVE_CONNECTION"
    PRIMARY_LINK="INACTIVE"
    SECONDARY_LINK="ACTIVE"
    #check_pppoe_gw1
    if [ "$TARGETS_FAILED" = "0" ]; then
      switch
    fi
  else
    if [[ ( $SPARE_LOG -eq 1 && $((`date +%-M` % 5)) -eq 0 && $((`date +%-S`)) -lt 21 ) || $SPARE_LOG -eq 0 ]]; then
      log INFO "WAN Link: $ACTIVE_CONNECTION"
    fi
    PRIMARY_LINK="ACTIVE"
    #ACTIVE_CONNECTION == PRIMARY, no failure: let's make sure GW2 is alright.
    check_pppoe_gw2
  fi
}

check_sgw_status () {
  if [ "$S_TARGETS_FAILED" -ge "$THRESHOLD" ] && [ "$ACTIVE_CONNECTION" = "PRIMARY" ]; then
    log INFO "Secondary WAN Link is UNREACHABLE."
    SECONDARY_LINK="INACTIVE"
    test_gateway $SECONDARY_GW
    #switch
  elif [ "$ACTIVE_CONNECTION" = "SECONDARY" ]; then
    SECONDARY_LINK="ACTIVE"
    #log INFO "WAN Link: $ACTIVE_CONNECTION"
    check_pppoe_gw1
    #if [ "$S_TARGETS_FAILED" = "0" ] 
    #then
    #  switch
    #fi
  elif [ "$S_TARGETS_FAILED" -le "$THRESHOLD" ]; then
    if [[ ( $SPARE_LOG -eq 1 && $((`date +%-M` % 5)) -eq 0 && $((`date +%-S`)) -lt 21 ) || $SPARE_LOG -eq 0 ]]; then
      log INFO "Secondary WAN Link is reachable."
    fi
    SECONDARY_LINK="ACTIVE"
  #  check_pppoe_gw2
  fi
}

switch () {
  if [ "$ACTIVE_CONNECTION" = "PRIMARY" ]; then
    switch_to_secondary
    if [ $? -eq 0 ]; then
      if [ ! -z "$SECONDARY_CMD" ]; then
        eval "$SECONDARY_CMD"
      fi
      sleep "5"
      MSG="Primary WAN link failed. Switched to secondary link."
      BODY=`$ROUTE -n`
      log2mail "$MSG" "$BODY"
      log INFO "$MSG"
      log DEBUG "Failover Cooldown started, sleeping for $COOLDOWNDELAY01 seconds."
      sleep "$COOLDOWNDELAY01"
    fi
  elif [ "$ACTIVE_CONNECTION" = "SECONDARY" ]; then
    switch_to_primary
    if [ $? -eq 0 ]; then
      if [ ! -z "$PRIMARY_CMD" ]; then
        eval "$PRIMARY_CMD"
      fi
      sleep "10"
      MSG="Primary WAN link OK. Switched back to primary link."
      BODY=`$ROUTE -n`
      #log2mail "$MSG" "$BODY"
      log INFO "$MSG"
      log DEBUG "Failback Cooldown started, sleeping for $COOLDOWNDELAY02 seconds."
      sleep "$COOLDOWNDELAY02"
    fi
  fi
}

start_wfm () {
  #test_pppoe_gw1
  #test_pppoe_gw2
  get_interface_gw $PRIMARY_GW
  get_interface_gw $SECONDARY_GW
  init_wfm
  display_header
  
  log INFO "Starting monitoring of WAN link."
  
  while true
  do
    trap 'log_error ${LINENO} ${$?}' ERR
    trap clean_up SIGHUP SIGINT SIGTERM SIGQUIT
    test_wan_status
  done
}

case "$1" in
  routes)
    routes_manage $2 $3 $4 $5
    exit 0
    ;;
  status)
    display_header ECHO
    exit 0
    ;;
  swap)
    cmd_swap
    exit 0
    ;;
  targets)
    targets_manage $2 $3 $4 $5 $6 $7 $8 $9
    exit 0
    ;;
  viewlog)
    viewlog $2
    exit 0
    ;;
  about)
    about
    exit 0
    ;;
  config)
    config $2 $3 $4
    exit 0
    ;;
  locate_binaries)
    locate_binaries $PING $GREP $SED $AWK $CUT $ROUTE $IP $TAIL $IFCONFIG
    locate_binaries $SORT $PASTE $CAT
    exit 0
    ;;
  clean_up)
    clean_up
    exit 0
    ;;
esac

if [ "$DAEMON" = "0" ]; then
  check_for_pid
  start_wfm
else
  check_for_pid
  start_wfm &
  echo "$!" > "$PIDFILE"
fi
#EOF
