#!/bin/bash

THIS_SCRIPT=$(basename $0)
THIS_DIR=$(pwd)
TODAY=$(date +'%Y%m%d')

# default options that can be set by command line parameters (see usage)
COMP_TYPE=OHS            # component - WLS or OHS
ORA_VER=12.1.3.0         # version   - only 12.1.3.0 accepted
PSU_VER=180717           # PSU       - only 180717 accepted
DEBUG_LEVEL=0            # debug     - the default is for no additional debug output
DRY_RUN=FALSE            # dryRun    - the default is to not perform a dry run
NO_PROMPT=FALSE          # noPrompt  - the default is to prompt the user if run interactively
NM_UNAME="weblogic"      # NMUname   - the default NM and Admin Server username
NM_PWORD="weblog1c"      # NMPword   - this is the default for most dev/test Node Managers and Admin Servers
#NM_PWORD="Log1cweb!"    # NMPword   - alternative default

# default Admin Server and Node Manager usernames and passwords (normally there is no difference between the 2)
AS_UNAME=""              # ASUname   - by default this is the same as NM_UNAME but if not then it can be manually set here
AS_PWORD="Log1cweb"      # ASPword   - by default this is the same as NM_PWORD but if not then it can be manually set here
NM_PWORD_DEV="weblog1c"  # NMPword   - this is used for any 2nd attempts to connect to the Node Manager (useful if the Admin Server password is 

# other defaults
MIN_OPATCH_VER=13.2.0.0.0
RETURN_CODE=0
WAIT_SECS=120                       # how long to wait for a Node Manager to restart (until it is listening on the set TCP port)
WAIT_MSECS=$(( WAIT_SECS * 1000 ))  # how long to wait for an Admin Server command (WLST connect command option timeout)
SECS=0
IS_ADMIN_SERVER=FALSE
CMD_REDIR=" > /dev/null 2>&1"

# minimum amount of free space required for file system storing $ORACLE_HOME in MBytes
FREE_SPACE_MIN=800
# minimum amount of free space required in /tmp in MBytes
TEMP_SPACE_MIN=500

# default location to look for the patches to apply unless input parameter -stageDir given
BASE_DIR=/share/dbadir/PSU_deploy

#LOG_DIR=$HOME
LOG_DIR=/tmp
LOG_FILE=$LOG_DIR/$(echo $THIS_SCRIPT|cut -d. -f1)_${TODAY}_$(hostname|cut -d. -f1).log
if [[ -r $LOG_FILE ]]; then
  COUNT=$(ls -1 ${LOG_FILE}*|wc -l)
  mv $LOG_FILE ${LOG_FILE}_$COUNT
fi

touch $LOG_FILE > /dev/null 2>&1
if [[ ! -r $LOG_FILE ]]; then
  echo -e "\nWARNING: Could not create $LOG_FILE"
fi

# append all output to LOG_FILE
{
echo "INFO: $(date)"
echo "INFO: Start of $THIS_SCRIPT"
echo "INFO: Log file $LOG_FILE"

WHOAMI=$(whoami)
if [[ ! "$WHOAMI" =~ ^ora* ]]; then
  echo -e "\nFATAL: $WHOAMI is not a supported user to execute this script, expecting something like oracle, oracleas, oraweb or similar"
  exit 1
fi

# other defaults
MIN_OPATCH_VER=13.2.0.0.0
DRY_RUN=FALSE
RETURN_CODE=0
WAIT_SECS=120                       # how long to wait for a Node Manager to restart (until it is listening on the set TCP port)
WAIT_MSECS=$(( WAIT_SECS * 1000 ))  # how long to wait for an Admin Server command (WLST connect command option timeout)
SECS=0
IS_ADMIN_SERVER=FALSE
CMD_REDIR=" > /dev/null 2>&1"

# default location to look for the patches to apply unless input parameter -stageDir given
BASE_DIR=/share/dbadir/PSU_deploy 

# minimum amount of free space required for file system storing $ORACLE_HOME in MBytes
FREE_SPACE_MIN=800
# minimum amount of free space required in /tmp in MBytes
TEMP_SPACE_MIN=500

##
# --- Start Functions ---
##

function usage()
{
  echo
  echo "Usage:"
  echo "$THIS_SCRIPT [-component=COMP_TYPE] [-version=ORA_VER] [-PSU=PSU_VER] {-NMUname=NM_UNAME} {-NMPword=NM_PWORD} {-stageDir=BASE_DIR} {-noPrompt} {-debug} {-dryRun} {-help} "
  echo
  echo "Where:"
  echo "  -component|-c    - Required. Specify the Oracle component to stop and apply patches to (either WLS or OHS)"
  echo "  -version|-v      - Required. Specify the Oracle 12c WLS/OHS version (currently only 12.1.3.0 is valid)"
  echo "  -PSU|-psu        - Required. Specify the Oracle PSU date to apply to the Oracle Home (format must be YYMMDD and currently only 180717 is valid)"
  echo "  -NMUname|-u      - Optional. Node Manager / Admin Server username (usually the same for both)"
  echo "  -NMPword|-p      - Optional. Node Manager / Admin Server password (usually the same for both)"
  echo "  -stageDir|-s     - Optional. Staging directory with all unzipped patches (default is under $BASE_DIR/psu)"
  echo "  -noPrompt|-np    - Optional. Do not prompt the user (not set by default)"
  echo "  -dryRun|-dr      - Optional. Do not apply any patches but attempt to restart services (not set by default)"
  echo "  -debug|-d        - Optional. Display additional debug output to screen (not set by default)"
  echo "  -help|-h         - Optional. Display this usage message and exit"
  echo
  echo "Examples:"
  echo "  $THIS_SCRIPT -component=WLS -version=12.1.3.0 -PSU=180717 -noPrompt -dryRun"
  echo "  $THIS_SCRIPT -c=OHS -v=12.1.3.0 -psu=180717 -d -np -s=/u01/oracle/software/OHS_12.1.3.0_180717"

  # remove any log file created
  rm $LOG_FILE > /dev/null 2>&1
}

function prompt_if_interactive(){
fd=0
if [[ -t "$fd" || -p /dev/stdin ]] && [[ ! "$NO_PROMPT" == "TRUE" ]]; then
  echo -e "\nPress Y to continue or any other key to break and exit\n"
  read -n 1 -p "Do you wish to continue (y/n)? " answer
  case ${answer:0:1} in
    y|Y )
        echo -e "\nYes"
    ;;
    * )
        echo -e "\nNo\nExiting...."
        exit 255
    ;;
  esac
fi
} # function prompt_if_interactive

function start_NM(){
  echo -e "\nINFO: Starting the Node Manager..."
  echo -e "\nCMD: cd ${DOMAIN_HOME}/bin; nohup ./startNodeManager.sh > startNodeManager_$TODAY.out &"
  cd ${DOMAIN_HOME}/bin
  nohup ./startNodeManager.sh > startNodeManager_$TODAY.out &
  echo -e "\nINFO: Waiting up to $WAIT_SECS seconds for the Node Manager to startup and listen on port $NM_PORT"
  while [[ $(netstat -nlt | awk {'print$4'} | grep -c "$NM_ADDRESS_IP:$NM_PORT") -eq 0 ]] && [[ $SECS -lt $WAIT_SECS ]]
  do
    sleep 1
    ((SECS++))
    #echo -e "INFO: waited $SECS seconds"
    printf .
  done
  if [[ $(netstat -nlt | awk {'print$4'} | grep -c "$NM_ADDRESS_IP:$NM_PORT") -eq 0 ]]; then
    echo -e "\nERROR: Node Manager is not listening on port $NM_PORT after waiting $SECS seconds"
    #exit 1
  else
    echo -e "\nINFO: Node Manager is now listening on port $NM_PORT after waiting $SECS seconds"
  fi
}

# declare some WLST functions to control WLS via the Node Manager

function wlst_status_WLS_NM() {
echo -e "\nINFO: Checking the status of the WLS $WLS_NAME using WLST and the Node Manager..."

export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
nmUsername='$NM_UNAME'
nmPword='$NM_PWORD'
nmVerbose='true'
admin_server_url='t3s://$WLS_AS_HOST_IP:$WLS_AS_PORT'
wlsName='$WLS_NAME'
exitCode=1

#dumpStack()
#dumpVariables()
#listServerGroups()
#getNodeManagerHome()

try:
  nmConnect(nmUsername,nmPword,nmAddress,nmPort,domainName,domainHome,nmSSL,nmVerbose)
except:
  print 'Attempting to connect to the Node Manager again'
  nmConnect(username='$NM_UNAME',password='$NM_PWORD_DEV',host='$NM_ADDRESS_IP',port='$NM_PORT',domainName='$NM_DOMAIN_NAME',domainDir='$DOMAIN_HOME',nmType='$NM_SSL',verbose='true')

if nm():
  print 'WLS status: $WLS_NAME'
  print wlsName
  wlsServerStatus = nmServerStatus(serverName=wlsName)
  if not wlsServerStatus == 'RUNNING':
    print 'WLS $WLS_NAME is not RUNNING'
    exitCode=100
  else:
    print 'WLS $WLS_NAME is RUNNING'
    exitCode=0
  nmDisconnect()
else:
  exitCode=1
  print 'ERROR: Failed to connect to the Node Manager'

exit(exitcode=exitCode)

EOF
}

function wlst_stop_WLS_NM() {
echo -e "\nINFO: stop WLS $WLS_NAME using WLST and the Node Manager..."

export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
nmUsername='$NM_UNAME'
nmPword='$NM_PWORD'
nmVerbose='true'
admin_server_url='t3s://$WLS_AS_HOST_IP:$WLS_AS_PORT'
wlsName='$WLS_NAME'
exitCode=1

#dumpStack()
#dumpVariables()
#listServerGroups()
#getNodeManagerHome()

try:
  nmConnect(nmUsername,nmPword,nmAddress,nmPort,domainName,domainHome,nmSSL,nmVerbose)
except:
  print 'Attempting to connect to the Node Manager again'
  nmConnect(username='$NM_UNAME',password='$NM_PWORD_DEV',host='$NM_ADDRESS_IP',port='$NM_PORT',domainName='$NM_DOMAIN_NAME',domainDir='$DOMAIN_HOME',nmType='$NM_SSL',verbose='true')

if nm():
  print 'WLS status: $WLS_NAME'
  print wlsName
  wlsServerStatus = nmServerStatus(serverName=wlsName)
  if not wlsServerStatus == 'RUNNING':
    print 'WLS $WLS_NAME is not RUNNING'
    exitCode=100
  else:
    print 'WLS $WLS_NAME is RUNNING'
    nmKill(serverName=wlsName)
    nmServerStatus(serverName=wlsName)
    exitCode=0
  nmDisconnect()
else:
  exitCode=1
  print 'ERROR: Failed to connect to the Node Manager'

exit(exitcode=exitCode)

EOF
}

function wlst_start_WLS_NM() {
echo -e "\nINFO: start WLS $WLS_NAME using WLST and the Node Manager..."

export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
nmUsername='$NM_UNAME'
nmPword='$NM_PWORD'
nmVerbose='true'
admin_server_url='t3s://$WLS_AS_HOST_IP:$WLS_AS_PORT'
wlsName='$WLS_NAME'
exitCode=1

#dumpStack()
#dumpVariables()
#listServerGroups()
#getNodeManagerHome()

try:
  nmConnect(nmUsername,nmPword,nmAddress,nmPort,domainName,domainHome,nmSSL,nmVerbose)
except:
  print 'Attempting to connect to the Node Manager again'
  nmConnect(username='$NM_UNAME',password='$NM_PWORD_DEV',host='$NM_ADDRESS_IP',port='$NM_PORT',domainName='$NM_DOMAIN_NAME',domainDir='$DOMAIN_HOME',nmType='$NM_SSL',verbose='true')

if nm():
  print 'WLS status: $WLS_NAME'
  print wlsName
  state(wlsName,returnMap='true')
  wlsServerStatus = nmServerStatus(serverName=wlsName)
  if not wlsServerStatus == 'RUNNING':
    print 'WLS $WLS_NAME is not RUNNING'
    nmStart(serverName=wlsName,domainDir=domainHome)
    nmServerStatus(serverName=wlsName)
    exitCode=0
  else:
    print 'WLS $WLS_NAME is RUNNING'
    exitCode=0
  nmDisconnect()
else:
  print 'ERROR: Failed to connect to the Node Manager'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

# declare some WLST functions to control WLS via the Admin Server

function wlst_status_WLS_AS() {
echo -e "\nINFO: Checking the status of the WLS $WLS_NAME via WLST and the Admin Server..."

export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
#nmSSL='plain'
ASUname='$AS_UNAME'
ASPword='$AS_PWORD'
nmVerbose='true'
admin_server_url='t3s://$WLS_AS_HOST_IP:$WLS_AS_PORT'
wlsName='$WLS_NAME'
timeout='$WAIT_MSECS'
exitCode=1

#dumpStack()
#dumpVariables()
#listServerGroups()
#getNodeManagerHome()

print 'INFO: Attempting to connect to the Admin Server...'
connect(username=ASUname,password=ASPword,url=admin_server_url,timeout=timeout)
print serverName
#state(serverName,returnMap='true')
#print isAdminServer
if isAdminServer:
  print 'INFO: List of all Clusters'
  ls('Clusters')
  print 'INFO: List of all Servers'
  ls('Servers')
  print 'INFO: Checking the state of the WLS $WLS_NAME'
  state(wlsName,returnMap='true')
  exitCode=0
  disconnect()
else:
  print 'ERROR: Not connected to the Admin Server'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

function wlst_stop_WLS_AS() {
echo -e "\nINFO: Stopping WLS $WLS_NAME via WLST and the Admin Server..."

export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
#nmSSL='plain'
ASUname='$AS_UNAME'
ASPword='$AS_PWORD'
nmVerbose='true'
admin_server_url='t3s://$WLS_AS_HOST_IP:$WLS_AS_PORT'
wlsName='$WLS_NAME'
timeout='$WAIT_MSECS'
exitCode=1

print 'INFO: Attempting to connect to the Admin Server...'
connect(username=ASUname,password=ASPword,url=admin_server_url,timeout=timeout)
print serverName
state(serverName,returnMap='true')
#print isAdminServer
if isAdminServer:
  print 'INFO: Checking the state of the WLS $WLS_NAME'
  state(wlsName,returnMap='true')
  shutdown(wlsName,'Server',force='true',timeOut=10000)
  state(wlsName,returnMap='true')
  disconnect()
  exitCode=0
else:
  print 'ERROR: Not connected to the Admin Server'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

function wlst_start_WLS_AS() {
echo -e "\nINFO: Starting WLS $WLS_NAME via WLST and the Admin Server..."

export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
#nmSSL='plain'
ASUname='$AS_UNAME'
ASPword='$AS_PWORD'
nmVerbose='true'
admin_server_url='t3s://$WLS_AS_HOST_IP:$WLS_AS_PORT'
wlsName='$WLS_NAME'
timeout='$WAIT_MSECS'
exitCode=1

print 'INFO: Attempting to connect to the Admin Server...'
connect(username=ASUname,password=ASPword,url=admin_server_url,timeout=timeout)
print serverName
state(serverName,returnMap='true')
#print isAdminServer
if isAdminServer:
  print 'INFO: Checking the state of the WLS $WLS_NAME'
  state(wlsName,returnMap='true')
  #start(wlsName,'Server')
  start(wlsName,'Server',block='false')
  state(wlsName,returnMap='true')
  exitCode=0
  disconnect()
else:
  print 'ERROR: Not connected to the Admin Server'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

# declare some WLST functions to control the Admin Server

function wlst_stop_AS() {
echo -e "\nINFO: Stopping WLS Admin Server via WLST..."

export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

adminServerName='$WLS_AS_NAME'
domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
#nmSSL='plain'
ASUname='$AS_UNAME'
ASPword='$AS_PWORD'
nmVerbose='true'
admin_server_url='t3s://$WLS_AS_HOST_IP:$WLS_AS_PORT'
wlsName='$WLS_AS_NAME'
timeout='$WAIT_MSECS'
exitCode=1

print 'INFO: Attempting to connect to the Admin Server...'
connect(username=ASUname,password=ASPword,url=admin_server_url,timeout=timeout)
print serverName
state(serverName,returnMap='true')
#print isAdminServer
if isAdminServer:
  print 'INFO: Checking the state of WLS $WLS_AS_NAME'
  state(serverName,returnMap='true')
  print 'INFO: Stopping WLS $WLS_AS_NAME'
  shutdown(serverName,'Server',force='true',timeOut=10000)
  disconnect()
  exitCode=0
else:
  print 'ERROR: Not connected to the Admin Server'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

function wlst_start_AS() {
echo -e "\nINFO: Starting WLS Admin Server via WLST..."

export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

adminServerName='$WLS_AS_NAME'
domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
#nmSSL='plain'
nmUsername='$NM_UNAME'
nmPword='$NM_PWORD'
nmVerbose='true'
admin_server_url='t3s://$WLS_AS_HOST_IP:$WLS_AS_PORT'
wlsName='$WLS_AS_NAME'
exitCode=1

print 'INFO: Attempting to connect to the Node Manager...'
try:
  nmConnect(nmUsername,nmPword,nmAddress,nmPort,domainName,domainHome,nmSSL,nmVerbose)
except:
  print 'Attempting to connect to the Node Manager again'
  nmConnect(username='$NM_UNAME',password='$NM_PWORD_DEV',host='$NM_ADDRESS_IP',port='$NM_PORT',domainName='$NM_DOMAIN_NAME',domainDir='$DOMAIN_HOME',nmType='$NM_SSL',verbose='true')

if nm():
  print 'WLS status: $WLS_AS_NAME'
  print wlsName
  #state(wlsName,returnMap='true')
  wlsServerStatus = nmServerStatus(serverName=wlsName)
  if not wlsServerStatus == 'RUNNING':
    print 'WLS $WLS_AS_NAME is not RUNNING'
    nmStart(serverName=wlsName,domainDir=domainHome)
    nmServerStatus(serverName=wlsName)
  else:
    print 'WLS $WLS_AS_NAME is RUNNING'
  nmDisconnect()
  exitCode=0
else:
  print 'ERROR: Failed to connect to the Node Manager'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

# declare some WLST functions to control OHS via the Node Manager

function wlst_status_OHS_NM() {
echo -e "\nINFO: Checking the status of OHS via WLST and the Node Manager..."

#export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
nmUsername='$NM_UNAME'
nmPword='$NM_PWORD'
nmVerbose='true'
ohsName='$OHS_NAME'
exitCode=1

try:
  nmConnect(nmUsername,nmPword,nmAddress,nmPort,domainName,domainHome,nmSSL,nmVerbose)
except:
  print 'Attempting to connect to Node Manager again'
  nmConnect(username='$NM_UNAME',password='$NM_PWORD_DEV',host='$NM_ADDRESS_IP',port='$NM_PORT',domainName='$NM_DOMAIN_NAME',domainDir='$DOMAIN_HOME',nmType='$NM_SSL',verbose='true')

if nm():
  print 'OHS status:'
  ohsServerStatus = nmServerStatus(serverName=ohsName, serverType='OHS')
  if not ohsServerStatus == 'RUNNING':
    print 'OHS not RUNNING'
    exitCode=100
  else:
    print 'OHS is RUNNING'
    exitCode=0
  nmDisconnect()
else:
  print 'Failed to connect to the Node Manager'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

function wlst_start_OHS_NM() {
echo -e "\nINFO: Starting OHS via WLST and the Node Manager..."

#export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
nmUsername='$NM_UNAME'
nmPword='$NM_PWORD'
nmVerbose='true'
ohsName='$OHS_NAME'
exitCode=1

try:
  nmConnect(nmUsername,nmPword,nmAddress,nmPort,domainName,domainHome,nmSSL,nmVerbose)
except:
  print 'Attempting to connect to Node Manager again'
  nmConnect(username='$NM_UNAME',password='$NM_PWORD_DEV',host='$NM_ADDRESS_IP',port='$NM_PORT',domainName='$NM_DOMAIN_NAME',domainDir='$DOMAIN_HOME',nmType='$NM_SSL',verbose='true')


if nm():
  print 'OHS status:'
  ohsServerStatus = nmServerStatus(serverName=ohsName, serverType='OHS')
  if ohsServerStatus == 'RUNNING':
    print 'OHS is RUNNING already'
    exitCode=0
  else:
    print 'OHS is not RUNNING so will attempt to start'
    nmStart(serverName=ohsName, serverType='OHS')
    exitCode=0
  nmDisconnect()
else:
  print 'Failed to connect to the Node Manager'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

function wlst_stop_OHS_NM() {
echo -e "\nINFO: Stopping OHS via WLST and the Node Manager..."

#export WLST_PROPERTIES="-Dweblogic.security.SSL.ignoreHostnameVerification=true -Dweblogic.security.TrustKeyStore=CustomTrust -Dweblogic.security.CustomTrustKeyStoreFileName=$KEYSTORE"

$WLST_SCRIPT << EOF

domainHome='$DOMAIN_HOME'
domainName='$NM_DOMAIN_NAME'
nmAddress='$NM_ADDRESS_IP'
nmPort='$NM_PORT'
nmSSL='$NM_SSL'
nmUsername='$NM_UNAME'
nmPword='$NM_PWORD'
nmVerbose='true'
ohsName='$OHS_NAME'
exitCode=1

try:
  nmConnect(nmUsername,nmPword,nmAddress,nmPort,domainName,domainHome,nmSSL,nmVerbose)
except:
  print 'Attempting to connect to Node Manager again'
  nmConnect(username='$NM_UNAME',password='$NM_PWORD_DEV',host='$NM_ADDRESS_IP',port='$NM_PORT',domainName='$NM_DOMAIN_NAME',domainDir='$DOMAIN_HOME',nmType='$NM_SSL',verbose='true')

if nm():
  print 'OHS status:'
  ohsServerStatus = nmServerStatus(serverName=ohsName, serverType='OHS')
  if ohsServerStatus == 'RUNNING':
    print 'OHS is RUNNING so will attempt to kill'
    nmKill(serverName=ohsName, serverType='OHS')
    exitCode=0
  else:
    print 'OHS is not RUNNING'
    exitCode=0
  nmDisconnect()
else:
  print 'Failed to connect to the Node Manager'
  exitCode=1

exit(exitcode=exitCode)

EOF
}

# --- End Functions ---

##
# Main
##

# check for at least 3 input parameters
if [[ $# -lt 3 ]]; then
  usage $0
  exit 1
fi

# check the OS type
if [[ $(uname) == 'SunOS' ]]; then
  ORA_INV_PTR=/var/opt/oracle/oraInst.loc
elif [[ $(uname) == 'Linux' ]]; then
  ORA_INV_PTR=/etc/oraInst.loc
else
  echo -e "\nFATAL: unsupported OS type $(uname)"
  exit 1
fi

# read in users bash_profile
. ~/.bash_profile $CMD_REDIR
# if set unset LD_BIND_NOW
unset LD_BIND_NOW

# check that the environment variable DOMAIN_HOME is set
if [[ -z $DOMAIN_HOME ]]; then
  echo -e "\nFATAL: Cannot determine the environment variable DOMAIN_HOME"
  exit 1
fi

# check that the either the environment variable WL_HOME or WLS_HOME is set
if [[ -z $WL_HOME ]] && [[ -z $WLS_HOME ]]; then
  echo -e "\nFATAL: Could not determine either of the environment variables WL_HOME or WLS_HOME"
  exit 1
else
  WLS_HOME=$(dirname $(env|grep WL.*_HOME|cut -d= -f2|tail -1))
  export ORACLE_HOME=$WLS_HOME
fi

# check that the ORACLE_HOME directory exists
if [[ ! -d $ORACLE_HOME ]]; then
  echo -e "\nFATAL: Cannot access the Oracle Home directory $ORACLE_HOME"
  exit 1
else
  chmod g+rx $ORACLE_HOME
  ORA_INV_PTR=$ORACLE_HOME/oraInst.loc
  ORA_INV_DIR=$(grep ^inventory_loc $ORA_INV_PTR|cut -d= -f2)
  if [[ ! -d $ORA_INV_DIR ]]; then
    echo -e "\nFATAL: Cannot find Oracle Inventory directory $ORA_INV_DIR"
    exit 1
  fi
fi

# read each input parameter
while [[ $# -gt 0 ]]
do
  param=$(echo $1|cut -d= -f1)
  value=$(echo $1|cut -d= -f2)
  #echo param = $param
  #echo value = $value
  case $param in
        -help|-h)
                #doUsage="true"
                usage $0
                exit
                ;;
        -debug|-d)
                #DEBUG_LEVEL="$value"
                DEBUG_LEVEL=1
                ;;
        -noPrompt|-np)
                NO_PROMPT=TRUE
                ;;
        -dryRun|-dr)
                DRY_RUN=TRUE
                ;;
        -component|-c)
                COMP_TYPE="$value"
                ;;
        -version|-v)
                ORA_VER="$value"
                ;;
        -PSU|-psu)
                PSU_VER="$value"
                ;;
        -NMUname|-u)
                NM_UNAME="$value"
                ;;
        -NMPword|-p)
                NM_PWORD="$value"
                ;;
        -stageDir|-s)
                STAGE_DIR="$value"
                ;;
        *)
                echo "Invalid parameter: $param"
                usage $0
                exit 255
                ;;
  esac
  shift
done

if [[ "$DEBUG" == "TRUE" ]]; then
  unset CMD_REDIR
  echo -e "\nDEBUG: The debug option is enabled"
  echo -e "\nDEBUG: CMD_REDIR is unset"
fi

if [[ -z $COMP_TYPE ]]; then
  echo -e "\nFATAL: component type is required\n"
  usage $0
  exit 1
elif [[ "$COMP_TYPE" != "WLS" ]] && [[ "$COMP_TYPE" != "OHS" ]]; then
  echo -e "\nFATAL: component type $COMP_TYPE is unsupported"
  usage $0
  exit 1
else
  echo -e "\nINFO: component type $COMP_TYPE is supported"
fi

if [[ -z $ORA_VER ]]; then
  echo -e "\nFATAL: version is required\n"
  usage $0
  exit 1
elif [[ "$ORA_VER" != "12.1.3.0" ]]; then
  echo -e "\nFATAL: version $ORA_VER is unsupported"
  usage $0
  exit 1
else
  echo -e "\nINFO: version $ORA_VER is supported"
fi

if [[ -z $PSU_VER ]]; then
  echo -e "\nFATAL: PSU version is required\n"
  usage $0
  exit 1
elif [[ "$PSU_VER" != "180717" ]]; then
  echo -e "\nFATAL: PSU $PSU_VER is unsupported"
  usage $0
  exit 1
else
  echo -e "\nINFO: PSU $PSU_VER is supported"
fi

# if not set by the "-stageDir" option then the location to find all patches to apply needs to be defined
if [[ -z $STAGE_DIR ]]; then
  STAGE_DIR=${BASE_DIR}/psu/${COMP_TYPE}_${ORA_VER}_${PSU_VER}
fi

# check the STAGE_DIR driectory is accessible 
if [[ ! -d $STAGE_DIR ]]; then
  echo -e "\nFATAL: Cannot access directory $STAGE_DIR"
  usage $0
  exit 1
else
  echo -e "\nINFO: Found directory $STAGE_DIR"
fi

# set the path to the WLST script
if [[ $COMP_TYPE == "WLS" ]]; then
  WLST_SCRIPT=$WLS_HOME/wlserver/common/bin/wlst.sh
else
  WLST_SCRIPT=$WLS_HOME/oracle_common/common/bin/wlst.sh
fi

if [[ ! -r $WLST_SCRIPT ]]; then
  echo -e "\nFATAL: Cannot find the WLST script $WLST_SCRIPT"
  exit 1
fi

# check OPatch
if [[ ! -r $ORACLE_HOME/OPatch/opatch ]]; then
  echo -e "\nFATAL: Cannot find $ORACLE_HOME/OPatch/opatch"
  exit 1
else
  echo -e "\nINFO: OPatch version "$($ORACLE_HOME/OPatch/opatch version|head -1|awk {'print$3'})
  OPATCH_VER=$($ORACLE_HOME/OPatch/opatch version |head -1|awk {'print$3'}|cut -d. -f1,2,3,4|sed -e's/\.//g')
  if [[ ! $OPATCH_VER -ge $(echo $MIN_OPATCH_VER|cut -d. -f1,2,3,4|sed -e's/\.//g') ]]; then
    echo -e "\nFATAL: OPatch version must be $MIN_OPATCH_VER or greater"
    exit 1
  else
    echo -e "\nINFO: OPatch version OK"
  fi
fi

# if AS_UNAME (WLS Admin Server username) has not yet been set then make it the same as NM_UNAME (WLS Node Manager username)
if [[ -z $AS_UNAME ]]; then
  AS_UNAME=$NM_UNAME
fi

# if AS_PWORD (WLS Admin Server password) has not yet been set then make it the same as NM_PWROD (WLS Node Manager password)
if [[ -z $AS_PWORD ]]; then
  AS_PWORD=$NM_PWORD
fi

echo -e "\nINFO: Running processes owned by $WHOAMI"
ps -fu $WHOAMI
prompt_if_interactive

# get a list of all patches directories within STAGE_DIR
CMD="cd $STAGE_DIR"
eval "$CMD $CMD_REDIR"
if [[ ! $? -eq 0 ]]; then
  echo -e "\nFATAL: Could not enter directory $STAGE_DIR"
  exit 1
else
  PATCH_LIST=$(ls -l |grep ^d|awk {'print$9'}|grep ^[0-9]*$)
fi

if [[ ! "$DRY_RUN" == "TRUE" ]]; then

  # if there are no unzipped patches to apply then exit before stopping any services
  if [[ -z $PATCH_LIST ]]; then
    echo -e "\nFATAL: Did not find any unzipped Oracle patches to apply in directory $STAGE_DIR"
    exit 1
  else
    echo -e "\nINFO: The list of patches to be applied is: "$PATCH_LIST
  fi

  # check for free disk space
  if [[ $(df -m $ORACLE_HOME |tail -1|awk {'print$3'}) -lt $FREE_SPACE_MIN ]]; then
    echo -e "\nFATAL: $ORACLE_HOME has less than $FREE_SPACE_MIN MBytes of free space available\n"
    df -h $ORACLE_HOME
    exit 1
  fi

  echo -e "\nINFO: Patches installed in Oracle Home ${ORACLE_HOME}"
  CMD="$ORACLE_HOME/OPatch/opatch lspatches -invPtrLoc $ORA_INV_PTR -oh $ORACLE_HOME"
  echo -e "\nCMD: $CMD"
  $CMD
  if [[ ! $? -eq 0 ]]; then
    echo -e "\nFATAL: problem executing OPatch for Oracle Home $ORACLE_HOME"
    exit 1
  fi

  CMD="tar zcfpP $ORA_INV_DIR/ContentsXML_${TODAY}.tar.gz $ORA_INV_DIR/ContentsXML"
  echo -e "\nCMD: $CMD"
  $CMD > /dev/null 2>&1
  if [[ ! $? -eq 0 ]]; then
    echo -e "\nFATAL: Problem backing up the Oracle Inventory $ORA_INV_DIR for Oracle Home $ORACLE_HOME"
    exit 1
  else
    echo -e "\nINFO: Oracle Inventory $ORA_INV_DIR/ContentsXML backed up to $ORA_INV_DIR/ContentsXML_${TODAY}.tar.gz"
  fi

  prompt_if_interactive
fi

DOMAIN_CONFIG_FILE=$DOMAIN_HOME/config/config.xml
NM_PROP_FILE=$DOMAIN_HOME/nodemanager/nodemanager.properties
NM_DOMAINS_FILE=$(grep ^DomainsFile= $NM_PROP_FILE|cut -d= -f2|tail -1)
NM_DOMAIN_NAME=$(grep -v ^# $NM_DOMAINS_FILE | grep =${DOMAIN_HOME}$ | cut -d= -f1|tail -1)
NM_PORT=$(grep ^ListenPort $NM_PROP_FILE|cut -d= -f2|tail -1)
NM_ADDRESS=$(grep ^ListenAddress $NM_PROP_FILE|cut -d= -f2|tail -1)
NM_ADDRESS_IP=$(ping -c 1 $NM_ADDRESS | head -1 | awk {'print$3'} | sed -e 's/[()]//g')
NM_PORT=$(grep ^ListenPort $NM_PROP_FILE|cut -d= -f2|tail -1)
NM_SSL=$(grep ^SecureListener= $NM_PROP_FILE|cut -d= -f2|tail -1)
OHS_LIST=$(ps -fu $WHOAMI|grep -v grep|grep "httpd.worker"|grep -oE "instances/.*/httpd.conf"$|cut -d/ -f2|sort -u)

if [[ ! -r $DOMAIN_CONFIG_FILE ]]; then
  echo -e "\nFATAL: Cannot read Domain config file $DOMAIN_CONFIG_FILE"
  exit 1
fi

if [[ ! -r $NM_PROP_FILE ]]; then
  echo -e "\nFATAL: Cannot read Node Manager properties file $NM_PROP_FILE"
  exit 1
fi

if [[ ! -r $NM_DOMAINS_FILE ]]; then
  echo -e "\nFATAL: Cannot read Node Manager DomainsFile $NM_DOMAINS_FILE"
  exit 1
fi

if [[ "$NM_SSL" == "true" ]]; then
  NM_SSL="ssl"
else
  NM_SSL="plain"
fi

# for WLS only gather and check info about the WLS Admin Server 
if [[ $COMP_TYPE == "WLS" ]]; then
  KEYSTORE=$(ls -1 ${DOMAIN_HOME}/security/keystore/$(hostname|cut -d. -f1)*-trust.jks|tail -1)
  WLS_AS_PORT=$(grep -A1 administration-port-enabled $DOMAIN_CONFIG_FILE |tail -1|cut -d'>' -f2|cut -d'<' -f1)
  WLS_AS_NAME=$(grep -i '<admin-server-name>' $DOMAIN_CONFIG_FILE | tail -1|cut -d'>' -f2|cut -d'<' -f1)

  if [[ ! -r $KEYSTORE ]]; then
    echo -e "\nWARNING: Cannot read WLS keystore file: $KEYSTORE"
  fi

  if [[ -z $WLS_AS_PORT ]]; then
    echo -e "\nWARNING: Cannot determine the WLS Admin Server TCP port from $DOMAIN_CONFIG_FILE"
    #exit 1
  fi

  if [[ -z $WLS_AS_NAME ]]; then
    echo -e "\nWARNING: Cannot determine the WLS Admin Server name from $DOMAIN_CONFIG_FILE"
    #exit 1
  fi

  # check if the WLS Admin Server is running on this host
  WLS_AS_STATUS=$(ps -fu $WHOAMI|grep -v grep|grep "weblogic.Server"$|grep -c "Dweblogic.Name=$WLS_AS_NAME")
  WLS_AS_PORT_STATUS=$(netstat -nlt | awk {'print$4'} | grep -c ":$WLS_AS_PORT"$)

  ADMIN_URL=$(ps -fu $WHOAMI|grep -v grep|grep -oE "Dweblogic.management.server=.{0,100}"|awk {'print$1'}|cut -d= -f2|tail -1)
  if [[ -z $ADMIN_URL ]]; then
    echo -e "\nERROR: Cannot determine the WLS Admin Server URL from any running managed WLS"
    #exit 1
    if [[ $WLS_AS_STATUS -gt 0 ]] && [[ $WLS_AS_PORT_STATUS -gt 0 ]]; then
      echo -e "\nINFO: The WLS Admin Server appears to be running on this host"
      WLS_AS_HOST_IP=$(netstat -nlt | awk {'print$4'} | grep ":$WLS_AS_PORT"$ | cut -d: -f1)
      WLS_AS_HOST=$WLS_AS_HOST_IP
      ADMIN_URL="https://$WLS_AS_HOST_IP:$WLS_AS_PORT"
    else
      echo -e "\nFATAL: Cannot determine the WLS Admin Server URL"
      exit 1
    fi
  else
    WLS_AS_HOST=$(echo $ADMIN_URL|cut -d/ -f3|cut -d: -f1)
    WLS_AS_HOST_IP=$(ping -c 1 $WLS_AS_HOST | head -1 | awk {'print$3'} | sed -e 's/[()]//g')
  fi

  echo -e "\nINFO: WLS Admin Server URL is $ADMIN_URL"

  WLS_LIST=$(ps -fu $WHOAMI|grep -v grep|grep -oE "Dweblogic.Name=.{0,100}"|awk {'print$1'}|cut -d= -f2|sort -u|grep -v $WLS_AS_NAME)

  # check if the WLS Admin Server is running on this host
  WLS_AS_STATUS=$(ps -fu $WHOAMI|grep -v grep|grep "weblogic.Server"$|grep -c "Dweblogic.Name=$WLS_AS_NAME")
  WLS_AS_IP_STATUS=$(/sbin/ifconfig |grep -A1 "inet addr:$WLS_AS_HOST_IP " | grep -c ^' *UP')
  WLS_AS_PORT_STATUS=$(netstat -nlt | awk {'print$4'} | grep -c ":$WLS_AS_PORT"$)

  # test if the WLS Admin Server is meant to be running on this host by checking the IP
  if [[ $WLS_AS_IP_STATUS -gt 0 ]]; then
    IS_ADMIN_SERVER=TRUE
    if [[ $WLS_AS_STATUS -gt 0 ]]; then
      echo -e "\nINFO: WLS $WLS_AS_NAME is running on this host and IP $WLS_AS_HOST_IP is UP (Admin URL $ADMIN_URL)"
    else
      echo -e "\nINFO: WLS $WLS_AS_NAME is not running on this host IP $WLS_AS_HOST_IP is UP (Admin URL $ADMIN_URL)"
    fi
  else
    echo -e "\nINFO: The WLS Admin Server IP $WLS_AS_HOST_IP is not UP on this host (Admin URL $ADMIN_URL)"
  fi

  # check if this host is running the Admin Server and also listening on the expected TCP port
  if [[ "$IS_ADMIN_SERVER" == "TRUE" ]]; then
    if [[ $WLS_AS_STATUS -eq 0 ]]; then
      WLS_NAME=$WLS_AS_NAME
      echo -e "\nINFO: WLS $WLS_AS_NAME is not running on this host so will attempt to restart the Admin Server"
      prompt_if_interactive
      wlst_stop_AS $CMD_REDIR
      wlst_start_AS $CMD_REDIR
      WLS_AS_STATUS=$(ps -fu $WHOAMI|grep -v grep|grep "weblogic.Server"$|grep -c "Dweblogic.Name=$WLS_AS_NAME")
      WLS_AS_PORT_STATUS=$(netstat -nlt | awk {'print$4'} | grep -c ":$WLS_AS_PORT"$)
      if [[ $WLS_AS_STATUS -gt 0 ]]; then
        if  [[ $WLS_AS_PORT_STATUS -gt 0 ]]; then
          echo -e "\nINFO: WLS $WLS_AS_NAME is running on this host and listening on TCP port $WLS_AS_PORT"
        else
          echo -e "\nINFO: WLS $WLS_AS_NAME is running on this host but NOT listening on TCP port $WLS_AS_PORT so will attempt another restart of the Admin Server"
          prompt_if_interactive
          wlst_stop_AS $CMD_REDIR
          wlst_start_AS $CMD_REDIR
          WLS_AS_STATUS=$(ps -fu $WHOAMI|grep -v grep|grep "weblogic.Server"$|grep -c "Dweblogic.Name=$WLS_AS_NAME")
          WLS_AS_PORT_STATUS=$(netstat -nlt | awk {'print$4'} | grep -c ":$WLS_AS_PORT"$)
          if [[ $WLS_AS_PORT_STATUS -eq 0 ]]; then
            echo -e "\nERROR: WLS $WLS_AS_NAME is running on this host but is not listening on TCP port $WLS_AS_PORT"
          fi
        fi
      fi
    else
      echo -e "\nINFO: WLS $WLS_AS_NAME is running on this host"
      if [[ $WLS_AS_PORT_STATUS -gt 0 ]]; then
        echo -e "\nINFO: WLS $WLS_AS_NAME is running on this host and listening on TCP port $WLS_AS_PORT"
      else
        echo -e "\nINFO: WLS $WLS_AS_NAME is running on this host but NOT listening on TCP port $WLS_AS_PORT so will attempt another restart of the Admin Server"
        prompt_if_interactive
        wlst_stop_AS $CMD_REDIR
        wlst_start_AS $CMD_REDIR
        WLS_AS_STATUS=$(ps -fu $WHOAMI|grep -v grep|grep "weblogic.Server"$|grep -c "Dweblogic.Name=$WLS_AS_NAME")
        WLS_AS_PORT_STATUS=$(netstat -nlt | awk {'print$4'} | grep -c ":$WLS_AS_PORT"$)
        if [[ $WLS_AS_STATUS -gt 0 ]]; then
          if [[ $WLS_AS_PORT_STATUS -gt 0 ]]; then
            echo -e "\nINFO: WLS $WLS_AS_NAME is running on this host and listening on TCP port $WLS_AS_PORT"
          else
            echo -e "\nERROR: WLS $WLS_AS_NAME is running on this host but is not listening on TCP port $WLS_AS_PORT"
          fi
        else
          echo -e "\nERROR: WLS $WLS_AS_NAME failed to start on this host"
        fi
      fi
    fi
  fi # if IS_ADMIN_SERVER is TRUE

fi # if COMP_TYPE=WLS

if [[ ! $DEBUG_LEVEL -eq 0 ]]; then
  echo
  echo "DEBUG: ORACLE_HOME=$ORACLE_HOME"
  echo "DEBUG: WLS_HOME=$WLS_HOME"
  echo "DEBUG: DOMAIN_CONFIG_FILE=$DOMAIN_CONFIG_FILE"
  echo "DEBUG: NM_DOMAIN_NAME=$NM_DOMAIN_NAME"
  echo "DEBUG: NM_ADDRESS=$NM_ADDRESS"
  echo "DEBUG: NM_ADDRESS_IP=$NM_ADDRESS_IP"
  echo "DEBUG: AS_UNAME=$AS_UNAME"
  echo "DEBUG: AS_PWORD=$AS_PWORD"
  echo "DEBUG: NM_UNAME=$NM_UNAME"
  echo "DEBUG: NM_PWORD=$NM_PWORD"
  echo "DEBUG: NM_PORT=$NM_PORT"
  echo "DEBUG: NM_SSL=$NM_SSL"
  echo "DEBUG: IS_ADMIN_SERVER=$IS_ADMIN_SERVER"
  echo "DEBUG: WLS_AS_NAME=$WLS_AS_NAME"
  echo "DEBUG: ADMIN_URL=$ADMIN_URL"
  echo "DEBUG: WLS_AS_HOST=$WLS_AS_HOST"
  echo "DEBUG: WLS_AS_HOST_IP=$WLS_AS_HOST_IP"
  echo "DEBUG: WLS_AS_PORT=$WLS_AS_PORT"
  echo "DEBUG: WLS_LIST="$WLS_LIST
  echo "DEBUG: OHS_LIST="$OHS_LIST
  echo "DEBUG: PATCH_LIST="$PATCH_LIST
  echo "DEBUG: WAIT_SECS=$WAIT_SECS"
  echo "DEBUG: WAIT_MSECS=$WAIT_MSECS"
  echo
  CMD_REDIR=" "
fi

if [[ $COMP_TYPE == "WLS" ]]; then
  # check the status of the WLS Admin Server (password test)
  echo -e "\nINFO: Attempting to connect to the WLS Admin Server ${WLS_AS_NAME}... "
  WLS_NAME=$WLS_AS_NAME
  eval "wlst_status_WLS_AS $CMD_REDIR"
  RETURN_CODE=$?
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME is running"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME is not running"
  else
    echo -e "\nFATAL: Cannot connect to the WLS Admin Server using WLST"
    exit 1
  fi
fi

# check the Node Manager is running
if [[ ! $(ps -fu $WHOAMI|grep -v grep|grep -c weblogic.NodeManager) -eq 0 ]]; then
  echo -e "\nINFO: The Node Manager is running"
else
  echo -e "\nERROR: The Node Manager is not running so will attempt to start it"
  #eval "start_NM $CMD_REDIR"
  start_NM
  if [[ ! $(ps -fu $WHOAMI|grep -v grep|grep -c weblogic.NodeManager) -eq 0 ]]; then
    echo -e "\nINFO: The Node Manager is now running"
  else
   echo -e "\nFATAL: The Node Manager would not start"
   exit 1
  fi
fi

prompt_if_interactive


# loop through all OHS running on the host and check their status before stopping
for OHS_NAME in $OHS_LIST
do
  echo -e "\nINFO: Checking OHS $OHS_NAME using the Node Manager..."
  eval "wlst_status_OHS_NM $CMD_REDIR"
  RETURN_CODE=$?
  #echo RETURN_CODE = $RETURN_CODE
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: The Node Manager and Oracle HTTP Server $OHS_NAME are both running"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: Oracle HTTP Server $OHS_NAME is not running"
  else
    echo -e "\nERROR: Cannot connect to the Node Manager using WLST"
    exit 1
  fi

  echo -e "\nINFO: Stopping OHS $OHS_NAME using the Node Manager..."
  eval "wlst_stop_OHS_NM $CMD_REDIR"
  RETURN_CODE=$?
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: Oracle HTTP Server $OHS_NAME successfully stopped"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: Oracle HTTP Server $OHS_NAME failed to stop"
  else
    echo -e "\nERROR: Cannot connect to the Node Manager using WLST"
    exit 1
  fi
done

# loop through all WLS running on the host and check their status before stopping
for WLS_NAME in $WLS_LIST
do
  echo -e "\nINFO: Checking WLS $WLS_NAME using the Admin Server..."
  eval "wlst_status_WLS_AS $CMD_REDIR"
  RETURN_CODE=$?
  #echo RETURN_CODE = $RETURN_CODE
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: The Admin Server and WebLogic Server $WLS_NAME are both running"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME is not running"
  else
    echo -e "\nERROR: Cannot connect to the Admin Server using WLST"
  fi

  echo -e "\nINFO: Stopping WLS $WLS_NAME using the Admin Server..."
  eval "wlst_stop_WLS_AS $CMD_REDIR"
  RETURN_CODE=$?
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME successfully stopped"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME failed to stop"
  else
    echo -e "\nERROR: Cannot connect to the Admin Server using WLST"
  fi
done

echo -e "\nINFO: Stopping the Node Manager..."
prompt_if_interactive
CMD="${DOMAIN_HOME}/bin/stopNodeManager.sh"
echo -e "\nCMD: $CMD"
eval "$CMD $CMD_REDIR"
# pause 1 second
sleep 1

if [[ $(ps -fu $WHOAMI|grep -v grep|grep -c weblogic.NodeManager) -ne 0 ]]; then
  echo -e "\nERROR: The Node Manager is still running"
  exit 1
else
  echo -e "\nINFO: Node Manager stopped"
fi

if [[ "$IS_ADMIN_SERVER" == "TRUE" ]]; then
  echo -e "\nINFO: The WLS Admin Server on this host will be stopped then restarted after patching"
  prompt_if_interactive

  WLS_NAME=$WLS_AS_NAME

  #echo wlst_status_WLS_AS $CMD_REDIR
  eval "wlst_status_WLS_AS $CMD_REDIR"
  RETURN_CODE=$?
  #echo RETURN_CODE = $RETURN_CODE
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME is running"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME is not running"
  else
    echo -e "\nERROR: Cannot connect to the WLS Admin Server using WLST"
    exit 1
  fi

  echo -e "\nINFO: Stopping WLS Admin Server..."
  #echo wlst_stop_AS $CMD_REDIR
  eval "wlst_stop_AS $CMD_REDIR"
  RETURN_CODE=$?
  #echo RETURN_CODE = $RETURN_CODE
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME stopped"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME failed to stop"
  else
    echo -e "\nERROR: Cannot connect to the WLS Admin Server using WLST"
    exit 1
  fi
fi

echo -e "\nINFO: Running processes owned by $WHOAMI"
ps -fu $WHOAMI
prompt_if_interactive

# backup the existing ORACLE_HOME directory
if [[ "$DRY_RUN" == "TRUE" ]]; then
  echo -e "\nINFO: The dry run option was specified so no backup of the existing ORACLE_HOME is required"
  RETURN_CODE=0
else
  CMD="tar zcfpP ${ORACLE_HOME}_${TODAY}.tar.gz $ORACLE_HOME"
  echo -e "\nCMD: $CMD"
  $CMD 1> /dev/null
  RETURN_CODE=$?
  if [[ ! $RETURN_CODE -eq 0 ]]; then
    echo -e "\nFATAL: Could not execute: $CMD"
    exit 1
  else 
    prompt_if_interactive
  fi
fi



for PATCH_ID in $PATCH_LIST
do
  cd $STAGE_DIR/$PATCH_ID
  if [[ ! $? -eq 0 ]]; then
    echo -e "\nWARNING: Could not enter directory $STAGE_DIR/$PATCH_ID"
    #exit 1
  else
    echo -e "\nINFO: Current directory is: $(pwd)"
  fi
  echo -e "\nINFO: About to apply patch $PATCH_ID to $ORACLE_HOME"
  CMD="$ORACLE_HOME/OPatch/opatch apply -silent -force -invPtrLoc $ORA_INV_PTR -oh $ORACLE_HOME"
  #CMD="$ORACLE_HOME/OPatch/opatch rollback -id $PATCH_ID -silent -force -invPtrLoc $ORA_INV_PTR -oh $ORACLE_HOME"
  echo -e "\nCMD: $CMD"
  if [[ "$DRY_RUN" == "TRUE" ]]; then
    echo -e "\nINFO: The dry run option was specified so no patches will be applied"
    RETURN_CODE=0
  else
    eval "$CMD $CMD_REDIR"
    RETURN_CODE=$?
    if [[ ! $RETURN_CODE -eq 0 ]]; then
      echo -e "\nWARNING: OPatch reported a problem applying $PATCH_ID"
      echo -e "\nINFO: Patches installed in Oracle Home ${ORACLE_HOME}"
      CMD="$ORACLE_HOME/OPatch/opatch lspatches -invPtrLoc $ORA_INV_PTR -oh $ORACLE_HOME"
      echo -e "\nCMD: $CMD"
      eval "$CMD"
      RETURN_CODE=$?
      #exit 1
    else
      echo -e "\nINFO: OPatch reported no problems with patch $PATCH_ID"
    fi
  fi
  prompt_if_interactive
done


# restart Node Manager and then WLS
start_NM
if [[ ! $(ps -fu $WHOAMI|grep -v grep|grep -c weblogic.NodeManager) -eq 0 ]]; then
  echo -e "\nINFO: The Node Manager is now running"
else
 echo -e "\nFATAL: The Node Manager would not start"
 exit 1
fi


# restart the WLS Admin Server if it was running before
if [[ "$IS_ADMIN_SERVER" == "TRUE" ]]; then
  echo -e "\nINFO: The WLS Admin Server on this host will be restarted"

  eval "wlst_start_AS $CMD_REDIR"
  RETURN_CODE=$?
  #echo RETURN_CODE = $RETURN_CODE
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_AS_NAME is running"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_AS_NAME is not running"
  else
    echo -e "\nFATAL: Problem restarting WLS Admin Server $WLS_AS_NAME using WLST"
    exit 1
  fi
fi


# loop through all OHS that were previusly running on the host and restart
for OHS_NAME in $OHS_LIST
do
  echo -e "\nINFO: Starting OHS $OHS_NAME using the Node Manager..."
  eval "wlst_start_OHS_NM $CMD_REDIR"
  RETURN_CODE=$?
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: Oracle HTTP Server $OHS_NAME successfully started"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: Oracle HTTP Server $OHS_NAME failed to start"
  else
    echo -e "\nERROR: Cannot connect to the Node Manager using WLST"
  fi
done

# loop through all WLS that was previously running on the host and restart
for WLS_NAME in $WLS_LIST
do
  echo -e "\nINFO: Starting WLS ${WLS_NAME} using the Admin Server..."
  eval "wlst_start_WLS_AS $CMD_REDIR"
  RETURN_CODE=$?
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME successfully started"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME failed to start"
  else
    echo -e "\nERROR: Cannot connect to the Admin Server using WLST"
  fi

  eval "wlst_status_WLS_AS $CMD_REDIR"
  RETURN_CODE=$?
  #echo RETURN_CODE = $RETURN_CODE
  if [[ $RETURN_CODE -eq 0 ]]; then
    echo -e "\nINFO: The Admin Server and WebLogic Server $WLS_NAME are both running"
  elif [[ $RETURN_CODE -eq 100 ]]; then
    echo -e "\nINFO: WebLogic Server $WLS_NAME is not running"
  else
    echo -e "\nERROR: Cannot connect to the Admin Server using WLST"
  fi
done

echo -e "\nINFO: Running processes owned by $WHOAMI"
ps -fu $WHOAMI

if [[ ! "$DRY_RUN" == "TRUE" ]]; then
  echo -e "\nINFO: Patches installed in Oracle Home ${ORACLE_HOME}"
  CMD="$ORACLE_HOME/OPatch/opatch lspatches -invPtrLoc $ORA_INV_PTR -oh $ORACLE_HOME"
  echo -e "\nCMD: $CMD"
  $CMD
  if [[ ! $? -eq 0 ]]; then
    echo -e "\nFATAL: problem executing OPatch for Oracle Home $ORACLE_HOME"
    exit 1
  fi
fi


echo
echo "INFO: $(date)"
echo "INFO: End of $THIS_SCRIPT on $(hostname) as $WHOAMI"
echo "INFO: Log file $LOG_FILE"
echo "INFO: Done!"
exit 0

} | tee -a $LOG_FILE
exit ${PIPESTATUS[0]}
