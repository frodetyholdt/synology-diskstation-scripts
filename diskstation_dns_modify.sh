#!/bin/ash
# These settings should be edited to match the settings of your existing DNS server configuration on your synology server (Main Menu -> DNS Server -> Zones)
#
# Single-zone (legacy): set YourNetworkName, ForwardMasterFile, ReverseMasterFile
# Multi-zone: set NUM_ZONES and for each zone N=1,2,... set ZONE_N_NAME, ZONE_N_FORWARD, ZONE_N_REVERSE, ZONE_N_SUBNET
#   ZONE_N_SUBNET = first three octets of the subnet (e.g. 10.14.15 or 10.20.30) so DHCP records are filtered per zone
YourNetworkName=home.lan
ForwardMasterFile=home.lan
ReverseMasterFile=1.168.192.in-addr.arpa
NUM_ZONES=0

LOG_CONTEXT="-"  #override to add extra stuff to log messages
date_echo(){
    datestamp=$(date +%F_%T)
    echo "${datestamp} ${LOG_CONTEXT} $*"
}

overridesettings(){
  # $1 is both script global variable name and the parameter name in settings file
  settingsfile=$(dirname $0)/settings

  if [ -r $settingsfile ]; then
    if ignoredresult=$(cat $settingsfile | grep "^$1="); then
      value=$(cat $settingsfile | grep "^$1=" | head -1 | cut -f2- -d"=")
      eval "$1=\"$value\""
      date_echo "[overriding] $1=$value"
    fi
  else
    date_echo "WARNING: no settings file found.  Using default settings for $1"
  fi
}
date_echo " $0 starting..."
# user specific settings are loaded from settings file, if present.  This makes upgrading this script easier.
overridesettings YourNetworkName
overridesettings ForwardMasterFile
overridesettings ReverseMasterFile
overridesettings NUM_ZONES
n=1
while [ $n -le 10 ]; do
  overridesettings "ZONE_${n}_NAME"
  overridesettings "ZONE_${n}_FORWARD"
  overridesettings "ZONE_${n}_REVERSE"
  overridesettings "ZONE_${n}_SUBNET"
  n=$(( n + 1 ))
done

#Note: the remainder of this script should not need to be modified
# Note that backup path is also used as a temp folder.
BackupPath=/var/services/homes/admin/scripts/dns_backups
ZoneRootDir=/var/packages/DNSServer/target
ZonePath=$ZoneRootDir/named/etc/zone/master
DHCPAssigned=/etc/dhcpd/dhcpd.conf

NetworkInterfaces=",`ip -o link show | awk -F': ' '{printf $2","}'`"

date_echo "Network interfaces:"
date_echo $NetworkInterfaces

# An address may not have been assigned yet so verify
# the leases log file exists before assigning.
DHCPLeases=/etc/dhcpd/dhcpd-leases.log
[ -f $DHCPLeases ] && DHCPAssigned="$DHCPAssigned $DHCPLeases"

DHCPStatic=/etc/dhcpd/dhcpd-static-static.conf
# this file may not exist if you haven't configured anything in the dhcp static reservations list (mac addr -> ip addr)
[ -f $DHCPStatic ] && DHCPAssigned="$DHCPAssigned $DHCPStatic"

DHCPeth0=/etc/dhcpd/dhcpd-eth0-static.conf
[ -f $DHCPeth0 ] && DHCPAssigned="$DHCPAssigned $DHCPeth0"
# DSM 7+ uses ovs_eth0 / ovs_eth1 for multiple interfaces (e.g. VLAN 1 and VLAN 30)
DHCPovs_eth0=/etc/dhcpd/dhcpd-ovs_eth0-static.conf
[ -f $DHCPovs_eth0 ] && DHCPAssigned="$DHCPAssigned $DHCPovs_eth0"
DHCPovs_eth1=/etc/dhcpd/dhcpd-ovs_eth1-static.conf
[ -f $DHCPovs_eth1 ] && DHCPAssigned="$DHCPAssigned $DHCPovs_eth1"

DHCPLeaseFile=/etc/dhcpd/dhcpd.conf.leases
[ -f $DHCPLeaseFile ] && DHCPAssigned="$DHCPAssigned $DHCPLeaseFile"

##########################################################################
# Verify files exist and appropriate rights are granted
# Fail if environment is not set up correctly.
#TODO

##########################################################################
# Back up the forward and reverse master files
# Two options: a) One backup which is overwritten each time
# or b) file is backed up once each day... but only the first use and
# retained for one year.
#
if ! mkdir -p ${BackupPath}; then
  date_echo "Error: cannot create backup directory"
  exit 3
fi

# Process one zone: backup, regenerate forward and reverse from DHCP, then overwrite zone files.
# Uses globals: ZonePath, BackupPath, DHCPAssigned, NetworkInterfaces
# $1=YourNetworkName $2=ForwardMasterFile $3=ReverseMasterFile $4=SubnetPrefix (optional)
process_zone() {
  zone_name="$1"
  zone_forward="$2"
  zone_reverse="$3"
  zone_subnet="$4"
  tmpPrefix=$BackupPath/DNS_Backup_$(date +%m%d)
  date_echo "Backing up zone $zone_name ($zone_forward / $zone_reverse)"
  [ -f $tmpPrefix.$zone_forward ] && date_echo "INFO: Forward master already backed up for today." || cp -a $ZonePath/$zone_forward $tmpPrefix.$zone_forward
  [ -f $tmpPrefix.$zone_reverse ] && date_echo "INFO: Reverse master already backed up for today." || cp -a $ZonePath/$zone_reverse $tmpPrefix.$zone_reverse

  date_echo "Regenerating forward master file $zone_forward (subnet $zone_subnet)"
  PARTIAL="$(printPartialDNSFile $ZonePath/$zone_forward)"
  date_echo "forward master file static DNS addresses:"
  echo "$PARTIAL"
  echo
  STATIC=$(echo "$PARTIAL"|awk '{if(NF>3 && NF<6) print $1}'| tr '\n' ',')
  echo "$PARTIAL"  > $BackupPath/$zone_forward.new
  date_echo "adding these DHCP leases to DNS forward master file:"
  YourNetworkName="$zone_name" printDhcpAsRecords "A" "$STATIC" "$zone_subnet"
  echo
  YourNetworkName="$zone_name" printDhcpAsRecords "A" "$STATIC" "$zone_subnet" >> $BackupPath/$zone_forward.new

  incrementSerial $BackupPath/$zone_forward.new > $BackupPath/$zone_forward.bumped

  date_echo "Regenerating reverse master file $zone_reverse"
  PARTIAL="$(printPartialDNSFile $ZonePath/$zone_reverse)"
  STATIC=$(echo "$PARTIAL"|awk '{if(NF>3 && NF<6) print $1}'| tr '\n' ',')
  date_echo "Reverse master file static DNS addresses:"
  echo "$PARTIAL"
  echo
  echo "$PARTIAL" > $BackupPath/$zone_reverse.new
  date_echo "adding these DHCP leases to DNS reverse master file: "
  YourNetworkName="$zone_name" printDhcpAsRecords "PTR" "$STATIC" "$zone_subnet"
  echo
  YourNetworkName="$zone_name" printDhcpAsRecords "PTR" "$STATIC" "$zone_subnet" >> $BackupPath/$zone_reverse.new
  incrementSerial $BackupPath/$zone_reverse.new > $BackupPath/$zone_reverse.bumped

  if ! chown nobody:nobody $BackupPath/$zone_forward.bumped $BackupPath/$zone_reverse.bumped ; then
    date_echo "Error:  Cannot change file ownership for zone $zone_name"
    date_echo "Try running this script as root for correct permissions"
    exit 4
  fi
  chmod 644 $BackupPath/$zone_forward.bumped $BackupPath/$zone_reverse.bumped
  mv -f $BackupPath/$zone_forward.bumped $ZonePath/$zone_forward
  mv -f $BackupPath/$zone_reverse.bumped $ZonePath/$zone_reverse
}

# Declare reusable functions.  Logic is pretty much the same for forward and reverse files.
printPartialDNSFile () {
   # Pass in the DNS file to process (forward or reverse master)
   # Print everything except for PTR and A records.
   # The only exception are "ns.domain" records.  We keep those.
   #Assumptions:
   # PTR and A records should be removed unless they contain "ns.<YourNetworkName>."
   awk '
      {
		if ($5 != ";dynamic") {
			PrintThis=1;
		} else{
			PrintThis=0;
		}
      }
      (PrintThis == 1) {print $0 }
   ' $1
}

printDhcpAsRecords () {
	# Pass in "A" for A records and "PTR" for PTR records.
	# $2 = StaticRecords, $3 = SubnetPrefix (e.g. 10.14.15 or empty for no filter)
	# Process the DHCP static and dynamic records; only output records for IPs in SubnetPrefix when set.
	# Logic is the same for PTR and A records.  Just a different print output.
	# Sorts and remove duplicates. Filters records you don't want.
	SubnetPrefix=${3:-}
    awk -v YourNetworkName="$YourNetworkName" -v RecordType=$1 -v StaticRecords="$2" -v adapters="$NetworkInterfaces" -v subnet="$SubnetPrefix" '
        BEGIN {
           FS="[\t =,]";
        }
        {IP=""} # clear out variables
        # Leases start with numbers. Do not use if column 4 is an interface
        $1 ~ /^[0-9]/ {  if(NF>4 || index(adapters, "," $4 "," ) == 0) { IP=$3; NAME=$4; RENEW=86400 } }
        # Static assignments start with dhcp-host
        $1 == "dhcp-host" {IP=$4; NAME=$3; RENEW=$5}
        # If we have an IP and a NAME (and if name is not a placeholder)
        (IP != "" && NAME!="*" && NAME!="") {
           if (subnet != "" && index(IP, subnet ".") != 1) { IP=""; next; }
           split(IP,arr,".");
           ReverseIP = arr[4] "." arr[3] "." arr[2] "." arr[1];
           if(RecordType == "PTR" && index(StaticRecords, ReverseIP ".in-addr.arpa.," ) > 0) {IP="";}
           if(RecordType == "A" && index(StaticRecords, NAME "." YourNetworkName ".," ) > 0) {IP="";}
           gsub(/([^a-zA-Z0-9-]*|^[-]*|[-]*$)/,"",NAME)
           if(IP != "" && NAME!="*" && NAME!="") {
               if (RecordType == "PTR") {print 1000 + arr[4] "\t" ReverseIP ".in-addr.arpa.\t" RENEW "\tPTR\t" NAME "." YourNetworkName ".\t;dynamic"}
               if (RecordType == "A") print 2000 + arr[4] "\t" NAME "." YourNetworkName ".\t" RENEW "\tA\t" IP "\t;dynamic"
           }
        }
    ' $DHCPAssigned | sort | cut -f 2- | uniq
}

incrementSerial () {
# serial number must be incremented in SOA record when DNS changes are made so that slaves will recognize a change
  ser=$(sed -e '1,/.*SOA/d' $1 | sed -e '2,$d' -e 's/;.*//' )  #isolate DNS serial from first line following SOA
  comments=$(sed -e '1,/.*SOA/d' $1 | sed -e '2,$d' | sed -n '/;/p' |sed -e 's/.*;//' )  #preserve any comments, if any exist
  bumpedserial=$(( $ser +1 ))

  sed -n '1,/.*SOA/p' $1
  echo -e "\t$bumpedserial ;$comments"
  sed -e '1,/.*SOA/d' $1 | sed -n '2,$p'


}
##########################################################################
# Process zones: multi-zone (NUM_ZONES >= 1) or legacy single zone
#
if [ -n "$NUM_ZONES" ] && [ "$NUM_ZONES" -ge 1 ] 2>/dev/null; then
  n=1
  while [ $n -le $NUM_ZONES ]; do
    eval "zone_name=\"\${ZONE_${n}_NAME}\""
    eval "zone_forward=\"\${ZONE_${n}_FORWARD}\""
    eval "zone_reverse=\"\${ZONE_${n}_REVERSE}\""
    eval "zone_subnet=\"\${ZONE_${n}_SUBNET}\""
    if [ -z "$zone_forward" ] || [ -z "$zone_reverse" ]; then
      date_echo "WARNING: ZONE_${n}_FORWARD or ZONE_${n}_REVERSE not set, skipping zone $n"
    else
      date_echo "Processing zone $n: $zone_name ($zone_forward / $zone_reverse) subnet $zone_subnet"
      process_zone "$zone_name" "$zone_forward" "$zone_reverse" "$zone_subnet"
    fi
    n=$(( n + 1 ))
  done
else
  # Legacy single-zone: no subnet filter (all DHCP records go into this zone)
  date_echo "Processing single zone (legacy): $YourNetworkName"
  process_zone "$YourNetworkName" "$ForwardMasterFile" "$ReverseMasterFile" ""
fi

##########################################################################
# Reload the server config after modifications
$ZoneRootDir/script/reload.sh

date_echo "$0 complete."
exit 0
