#!/bin/bash

THIS_SCRIPT=$(basename $0)
THIS_DIR=$(pwd)
TODAY=$(date +'%Y%m%d')

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

# set defaults
COMP_TYPE=RDBMS
ORA_VER=12.1.0.2
PSU_VER=180717
RUN_MODE=PATCH

MIN_OPATCH_VER=12.2.0.1.14
DRY_RUN=FALSE
RETURN_CODE=0
DEBUG_LEVEL=0
NO_PROMPT=FALSE
WAIT_SECS=120
SECS=0
CMD_REDIR=" > /dev/null 2>&1"

# default location to look for the patches to apply unless input parameter -stageDir given
BASE_DIR=/share/dbadir/PSU_deploy

# minimum amount of free space required for file system storing $ORACLE_HOME in MBytes
FREE_SPACE_MIN=8000
# minimum amount of free space required in /tmp in MBytes
TEMP_SPACE_MIN=500

# --- Start Functions ---

function usage()
{
  echo
  echo "Usage:"
  echo "$THIS_SCRIPT -component=\$COMP_TYPE -version=\$ORA_VER -PSU=\$PSU_VER -SID=\$SID {-PDB -stageDir=\$STAGE_DIR -doDatapatch -noGrid -noPrompt -noCleanup -noRetry -dryRun -debug -help} "
  echo
  echo "Where:"
  echo "  -component|-c    - Required. Specify the Oracle component to stop and apply patches to (only RDBMS is valid)"
  echo "  -version|-v      - Required. Specify the Oracle 12c database version (12.1.0.2 or 12.2.0.1 valid)"
  echo "  -PSU|-psu        - Required. Specify the Oracle PSU date to apply (format YYMMDD, 180717 or 181016 valid)"
  echo "  -SID|-sid        - Required. Specify the Oracle SID to lookup from the ORATAB file"
  echo "  -PDB|-pdb        - Optional. Open all pluggable databases (not set by default)"
  echo "  -stageDir|-s     - Optional. Staging directory of where to find the patches to apply" 
  echo "  -doDatapatch|-dp - Optional. Run OPatch/datapatch after attaching the new Oracle Home (not set by default)"
  echo "  -noGrid|-ng      - Optional. Do not use any Grid Infrastructure commands (ignored if RAC is detected)"
  echo "  -noPrompt|-np    - Optional. Do not prompt the user (not set by default)"
  echo "  -dryRun|-dr      - Optional. Do not apply any patches but attempt to restart services (not set by default)"
  echo "  -debug|-d        - Optional. Display additional debug output to screen (not set by default)"
  echo "  -help|-h         - Optional. Display this usage message and exit"
  echo
  echo "Examples:"
  echo "  $THIS_SCRIPT -component=RDBMS -version=12.2.0.1 -PSU=180717 -SID=ORCL -noPrompt -dryRun"
  echo "  $THIS_SCRIPT -c=RDBMS -v=12.1.0.2 -psu=180717 -sid=ORCL -d -np -s=/u01/oracle/software"
  echo "  $THIS_SCRIPT -c=RDBMS -v=12.1.0.2 -psu=180717 -sid=OEMT1 -d -dr -np -s=/share/dbadir/PSU_deploy/psu/RDBMS_12.1.0.2_180717"
  echo "  $THIS_SCRIPT -c=RDBMS -v=12.2.0.1 -psu=181016 -sid=test122 -d -dr -np -s=/share/dbadir/PSU_deploy/psu/RDBMS_12.2.0.1_181016"

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
        echo -e "\nYes\n"
    ;;
    * )
        echo -e "\nNo\nExiting...."
        exit 255
    ;;
  esac
fi
} # function prompt_if_interactive

function DB_shutdown_immediate(){
if [[ $DB_RAC -gt 0 ]]; then
  echo
  echo "As this is a RAC database you may want to use SVRCTL to relocate any running services before shutting down the other instances"
  echo "srvctl relocate service -d $DB_NAME -oldinst $ORACLE_SID -newinst <ORACLE_SID2> -service <SERVICE_NAME>"
  echo
  echo "srvctl status database -d $DB_NAME -v"
  srvctl status database -d $DB_NAME -v
  echo
  prompt_if_interactive
  echo
  echo "srvctl stop instance -d $DB_NAME -i $ORACLE_SID -o immediate"
  srvctl stop instance -d $DB_NAME -i $ORACLE_SID -o immediate
  echo
  srvctl status database -d $DB_NAME -v
elif [[ $GRID -gt 0 ]]; then
  echo "srvctl status database -d $DB_NAME -v"
  srvctl status database -d $DB_NAME -v
  echo
  srvctl stop database -d $DB_NAME -o immediate
  echo
  srvctl status database -d $DB_NAME -v
else
  sqlplus / as sysdba << EOF
  set echo on
  PROMPT shutdown immediate
  shutdown immediate
EOF
fi
}

function DB_startup_upgrade(){
# shutdown and restart in upgrade state

# if RAC then give a warning message about required database shutdown to set cluster_database=FALSE
if [[ $DB_RAC -gt 0 ]] && [[ $DO_DATAPATCH -gt 0 ]]; then
  echo -e "\nAll instances of RAC database $DB_NAME are about to be shutdown and this instance $ORACLE_SID restarted with cluster_database=FALSE\n"
  srvctl status database -d $DB_NAME -v
  echo
  prompt_if_interactive
  echo
  srvctl stop database -d $DB_NAME -o immediate
  echo
  srvctl status database -d $DB_NAME -v
  echo
  sqlplus / as sysdba << EOF
  set echo on
  PROMPT startup nomount
  startup nomount
  alter system set cluster_database=FALSE scope=spfile;
  shutdown abort
  PROMPT startup upgrade
  startup upgrade
EOF
else
  sqlplus / as sysdba << EOF
  PROMPT startup upgrade
  startup upgrade
EOF
fi
echo
}

function do_datapatch(){

if [[ $DB_RAC -gt 0 ]]; then
  echo -e "\nAs this is a RAC database then OPatch/datapatch may not do anything until all Oracle Homes have the same patches installed\n"
fi

# run OPatch/datapatch
cd $ORACLE_HOME/OPatch
./datapatch -verbose

# check dba_registry_sqlpatch
sqlplus / as sysdba << EOF
set lines 200 pages 100
col VERSION for a10
col ACTION_TIME for a30
col DESCRIPTION for a100

select PATCH_ID,VERSION,ACTION,STATUS,ACTION_TIME,DESCRIPTION from dba_registry_sqlpatch ;
exit
EOF

# run utlrp to recompile anything invalid
echo -e "\nRunning UTLRP to recompile all..."
sqlplus / as sysdba << EOF > /dev/null
@?/rdbms/admin/utlrp.sql
EOF
echo -e "\nUTLRP done"
}

function DB_startup_normal(){

echo -e "\nDatabase $DB_NAME is about to be started in NORMAL mode"

# restart the database and open normal
# if RAC and datapatch was then need to shutdown all nodes and restart with cluster_database=TRUE
if [[ $DB_RAC -gt 0 ]] && [[ $DO_DATAPATCH -gt 0 ]]; then
  echo -e "\nAll instances of RAC database $DB_NAME are about to be shutdown and restarted with cluster_database=TRUE\n"
  srvctl status database -d $DB_NAME -v
  echo
  srvctl stop database -d $DB_NAME -o immediate
  echo
  srvctl status database -d $DB_NAME -v
  echo
  sqlplus / as sysdba << EOF
  set echo on
  PROMPT startup nomount
  startup nomount
  alter system set cluster_database=TRUE scope=spfile;
  PROMPT shutdown abort
  shutdown abort
EOF
  echo -e "\nAll instances of database $DB_NAME are about to be started if they are not already running"
  echo
  srvctl status database -d $DB_NAME -v
  echo
  srvctl start database -d $DB_NAME
  echo
  srvctl status database -d $DB_NAME -v
  echo
elif [[ $GRID -gt 0 ]]; then
  echo -e "\nDatabase $DB_NAME is about to be started"
  echo
  srvctl status database -d $DB_NAME -v
  echo
  srvctl start database -d $DB_NAME
  echo
  srvctl status database -d $DB_NAME -v
  echo
else
  echo -e "\nDatabase $DB_NAME is about to be started"
  echo
  sqlplus / as sysdba << EOF
  PROMPT startup
  startup
EOF
  echo
fi

} #

# --- End Functions ---


##
## Main
##

# read in users bash_profile
if [[ -r ~/.bash_profile ]]; then
  . ~/.bash_profile $CMD_REDIR
fi
# if set unset LD_BIND_NOW
unset LD_BIND_NOW

# check for at least 4 input parameters
if [[ $# -lt 4 ]]; then
  usage $0
  exit
fi

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
        -SID|-sid)
                SID="$value"
                ;;
        -stageDir|-s)
                STAGE_DIR="$value"
                ;;
        -doDatapatch|-dp)
                DO_DATAPATCH=1
                ;;
        -noGrid|-ng)
                NO_GRID=1
                ;;
        -PDB|-pdb)
                PDB=1
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
elif [[ "$COMP_TYPE" != "RDBMS" ]]; then
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
elif [[ "$ORA_VER" != "12.1.0.2" ]] && [[ "$ORA_VER" != "12.2.0.1" ]]; then
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
elif [[ "$PSU_VER" != "180717" ]] && [[ "$PSU_VER" != "181016" ]]; then
  echo -e "\nFATAL: PSU $PSU_VER is unsupported"
  usage $0
  exit 1
else
  echo -e "\nINFO: PSU $PSU_VER is supported"
fi

if [[ -z $SID ]]; then
  echo -e "\nFATAL: SID is required\n"
  usage $0
  exit 1
fi

# if not defined by the "-stageDir" option then the location to find all patches to apply needs to be defined
if [[ -z $STAGE_DIR ]]; then
  STAGE_DIR=${BASE_DIR}/psu/${COMP_TYPE}_${ORA_VER}_${PSU_VER}
fi

if [[ ! -d $STAGE_DIR ]]; then
  echo -e "\nFATAL: Cannot find directory $STAGE_DIR"
  usage $0
  exit 1
else
  echo -e "\nINFO: Found directory $STAGE_DIR"
fi


if [[ $(uname) == 'SunOS' ]]; then
  ORATAB=/var/opt/oracle/oratab
  ORA_INV_PTR=/var/opt/oracle/oraInst.loc
elif [[ $(uname) == 'Linux' ]]; then
  ORATAB=/etc/oratab
  ORA_INV_PTR=/etc/oraInst.loc
else
  echo -e "\nFATAL: unsupported OS type $(uname)"
  exit 1
fi

if [[ ! -r $ORATAB ]]; then
  echo "ERROR: cannot read ORATAB file $ORATAB"
  exit 1
fi

# if SID has been specified then set or reset the ORACLE_SID environment variable
if [[ ! -z $SID ]]; then
  ORACLE_SID=$SID
  export ORACLE_SID
fi

# check ORACLE_SID exists in ORATAB
if [[ $(grep -v ^# $ORATAB| grep . | cut -d: -f1 | grep -c ^${ORACLE_SID}$) -eq 0 ]]; then
  echo -e "\nFATAL:  cannot find SID $ORACLE_SID in ORATAB file $ORATAB\n"
  exit 1
else
  echo -e "\nINFO: Found ORACLE_SID $ORACLE_SID in ORATAB file $ORATAB with matching line:"
  grep -v ^# $ORATAB| grep . | grep ^${ORACLE_SID}:
  #ORACLE_HOME=$(grep -v ^# $ORATAB| grep . | grep ^${ORACLE_SID}: | cut -d: -f2 | head -1)
  ORAENV_ASK=NO
  . oraenv > /dev/null
  echo -e "\nINFO: Oracle Home is set to $ORACLE_HOME"
fi

if [[ -z $ORACLE_HOME ]]; then
  echo -e "\nFATAL: Could not determine environment variable ORACLE_HOME"
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

# check OPatch
if [[ ! -r $ORACLE_HOME/OPatch/opatch ]]; then
  echo -e "\nFATAL: Cannot find $ORACLE_HOME/OPatch/opatch"
  exit 1
else
  echo -e "\nINFO: OPatch version "$($ORACLE_HOME/OPatch/opatch version|head -1|awk {'print$3'})
  OPATCH_VER=$($ORACLE_HOME/OPatch/opatch version |head -1|awk {'print$3'}|cut -d. -f1,2,3,4,5|sed -e's/\.//g')
  if [[ ! $OPATCH_VER -ge $(echo $MIN_OPATCH_VER|cut -d. -f1,2,3,4,5|sed -e's/\.//g') ]]; then
    echo -e "\nFATAL: OPatch version must be $MIN_OPATCH_VER or greater"
    exit 1
  else
    echo -e "\nINFO: OPatch version OK"
  fi
fi

# check if Grid Infrastructure running (default is GRID=0)
if [[ $NO_GRID -gt 0 ]]; then
  GRID=0
elif [[ $(ps -ef|grep ^grid|grep -v grep|grep -c ocssd.bin) -eq 1 ]]; then
  echo -e "\nGrid Infrastructure is running so will attempt to use SRVCTL commands where possible"
  GRID=1
else
  GRID=0
fi

echo -e "\nINFO: The Oracle Home to apply patches to is "$ORACLE_HOME
if [[ $(grep -v ^# $ORATAB| grep -c $ORACLE_HOME) -gt 0 ]]; then
  echo -e "\nINFO: All matching entries in $ORATAB are:"
  grep -v ^# $ORATAB | grep :${ORACLE_HOME}:
  echo
  if [[ $GRID -gt 0 ]]; then
    echo -e "\nsrvctl status database -thishome -verbose\n"
    srvctl status database -thishome -verbose
  fi
else
  echo -e "\nFATAL:  cannot find $ORACLE_HOME in $ORATAB\n"
  exit 1
fi

# determine if this is a RAC database instance (defaults are DB_RAC=0 and DB_NAME=$ORACLE_SID)
# first set DB_NAME to be ORACLE_SID less any trailing number
DB_NAME=$(echo $ORACLE_SID|sed s/[0-9]$//g)
if [[ $(ps -ef|grep ^grid|grep -v grep|grep -c ocssd.bin) -eq 1 ]]; then
  DB_INST_COUNT=$(srvctl status database -d $DB_NAME|wc -l)
  if [[ $DB_INST_COUNT -gt 1 ]]; then
    echo -e "\n$DB_NAME $DB_INST_COUNT node RAC database detected"
    echo -e "\nsrvctl status database -d $DB_NAME -v"
    srvctl status database -d $DB_NAME -v
    DB_RAC=1
    NO_GRID=0
  fi
else
  DB_RAC=0
  DB_NAME=$ORACLE_SID
fi

# if RAC then check no database service is running against this node
if [[ $DB_RAC -gt 0 ]] && [[ $(srvctl status database -d $DB_NAME -v | grep $(hostname) | grep -c "online services") -gt 0 ]]; then
  echo -e "\nFATAL:  there are online services running against this database instance\n"
  echo -e "\nAs this is a RAC database you may want to use SVRCTL to relocate any running services before shutting down the other instances"
  echo -e "\nsrvctl relocate service -d $DB_NAME -oldinst $ORACLE_SID -newinst <ORACLE_SID2> -service <SERVICE_NAME>"
  exit 1
fi

# check for other instances running from this Oracle Home
if [[ $(grep -v ^# $ORATAB|grep -v ^$DB_NAME | grep -c $ORACLE_HOME) -gt 0 ]]; then
  echo -e "\nINFO: There may be other database instances running from this Oracle Home, check these other $ORATAB entries:"
  grep -v ^# $ORATAB| grep . |grep -v ^$DB_NAME | grep $ORACLE_HOME | sort -u
  if [[ $GRID -gt 0 ]]; then
    echo -e "\nsrvctl status database -thishome -verbose\n"
    srvctl status database -thishome -verbose
  fi
fi

prompt_if_interactive

# get a list of all patches directories within STAGE_DIR
CMD="cd $STAGE_DIR"
eval "$CMD $CMD_REDIR"
if [[ ! $? -eq 0 ]]; then
  echo -e "\nFATAL: Could not enter directory $STAGE_DIR"
  exit 1
else
  PATCH_LIST=$(ls -l |grep ^d|awk {'print$9'}|grep ^[0-9]*$)
  echo -e "\nINFO: The list of patches to OPatch apply is: "$PATCH_LIST
fi

prompt_if_interactive

if [[ ! $DEBUG_LEVEL -eq 0 ]]; then
  echo
  echo "DEBUG: ORACLE_HOME=$ORACLE_HOME"
  echo "DEBUG: PATCH_LIST="$PATCH_LIST
  echo "DEBUG: WAIT_SECS=$WAIT_SECS"
  echo
  CMD_REDIR=" "
fi

if [[ ! "$DRY_RUN" == "TRUE" ]]; then

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
  #CMD="touch $ORA_INV_DIR/ContentsXML_${TODAY}.tar.gz ; tar zcfp --update $ORA_INV_DIR/ContentsXML_${TODAY}.tar.gz $ORA_INV_DIR/ContentsXML"
  echo -e "\nCMD: $CMD"
  $CMD > /dev/null 2>&1
  RETURN_CODE=$?
  if [[ ! $RETURN_CODE -eq 0 ]]; then
    echo -e "\nFATAL: Problem backing up the Oracle Inventory $ORA_INV_DIR for Oracle Home $ORACLE_HOME"
    exit 1
  else
    echo -e "\nINFO: Oracle Inventory $ORA_INV_DIR/ContentsXML backed up to $ORA_INV_DIR/ContentsXML_${TODAY}.tar.gz"
  fi

  # backup the existing ORACLE_HOME directory
  CMD="tar zcfpP ${ORACLE_HOME}_${TODAY}.tar.gz $ORACLE_HOME"
  echo -e "\nCMD: $CMD"
  $CMD 1> /dev/null
  RETURN_CODE=$?
  if [[ ! $RETURN_CODE -eq 0 ]]; then
    echo -e "\nFATAL: Could not execute: $CMD"
    exit 1
  fi
else
  echo -e "\nINFO: The dry run option was specified so no backup of the existing ORACLE_HOME is required"
  RETURN_CODE=0
fi

prompt_if_interactive

echo -e "\nINFO: Running processes owned by $WHOAMI"
ps -fu $WHOAMI

prompt_if_interactive


# start OEM blackout
OEM_BLACKOUT_NAME=${DB_NAME}_${ORACLE_SID}_${TODAY}
echo -e "\nCMD: su - oraoem -c \"emctl start blackout oracle_database ${DB_NAME}_${ORACLE_SID} $OEM_BLACKOUT_NAME\""
echo -e "\nCMD: su - oraoem -c \"emctl status blackout\""

##
## Stop services ready for patching
##

if [[ ! "$DRY_RUN" == "TRUE" ]]; then

  # stop database listeners if standalone database (not RAC)
  echo -e "\nINFO: About to stop all Listeners running from $ORACLE_HOME"
  prompt_if_interactive
  if [[ $DB_RAC -eq 0 ]] && [[ $(ps -fu $WHOAMI|grep -v grep|grep -c $ORACLE_HOME/bin/tnslsnr) -gt 0 ]]; then
    LISTENER_LIST=$(ps -fu $WHOAMI|grep -v grep|grep $ORACLE_HOME/bin/tnslsnr|awk {'print$9'})
    for LISTENER_NAME in $LISTENER_LIST
    do
      echo -e "\nINFO: About to stop Listener $LISTENER_NAME"
      if [[ $GRID -gt 0 ]]; then
        echo -e "\nCMD: srvctl stop listener -l $LISTENER_NAME"
        srvctl stop listener -l $LISTENER_NAME
      else
        echo -e "\nCMD: lsnrctl stop $LISTENER_NAME"
        lsnrctl stop $LISTENER_NAME
      fi
      if [[ ! $? -eq 0 ]]; then
        echo -e "\nWARNING: Problem stopping Listener $LISTENER_NAME for Oracle Home $ORACLE_HOME and SID $ORACLE_SID"
        #exit 1
      fi
    done
  fi


  # shutdown database (if RAC this only stops the instance on this host)
  echo -e "\nINFO: About to shutdown the database instance $ORACLE_SID running from Oracle Home $ORACLE_HOME"
  prompt_if_interactive
  DB_shutdown_immediate

  if [[ ! $? -eq 0 ]]; then
    echo "\nFATAL:  Problem stopping database instance for Oracle Home $ORACLE_HOME and SID $ORACLE_SID and Database Name $DB_NAME"
    exit 1
  fi

  # check the Oracle Instance is actually stopped
  if [[ $(ps -fu $WHOAMI | grep $ORACLE_SID | grep -c pmon) -gt 0 ]]; then
    echo "\nFATAL:  Oracle database intance for Oracle Home $ORACLE_HOME and SID $ORACLE_SID appears to be running on this host"
    echo "\nCheck the running processes owned by $WHOAMI as shown by the output of:"
    echo "ps -fu $WHOAMI"
    exit 1
  fi
fi

##
## Apply patches
##
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
      echo -e "\nINFO: OPatch reported success applying $PATCH_ID"
    fi
  fi
  prompt_if_interactive
done

if [[ ! "$DRY_RUN" == "TRUE" ]]; then

  # fix some permissions
  chmod g+rx $ORACLE_HOME
  #chmod -R g+r $ORACLE_HOME
  find $ORACLE_HOME/network/ -type d -exec chmod g+rx {} \;
  find $ORACLE_HOME/inventory/ -type d -exec chmod g+rx {} \;
  chmod -R g+r $ORACLE_HOME/network/
  chmod -R g+r $ORACLE_HOME/inventory/

  # rename the DIAG_DEST directory as it will be recreated new
  if [[ -d $ORA_BASE/diag ]]; then
    echo -e "\nCMD: mv $ORA_BASE/diag $ORA_BASE/diag_${TODAY}"
    mv $ORA_BASE/diag $ORA_BASE/diag_${TODAY}
    echo
  fi

  # check if to run OPatch/datapatch
  if [[ $DO_DATAPATCH -gt 0 ]]; then
    echo -e "\nINFO: About to restart the database in the upgrade state before running \$ORACLE_HOME/OPatch/datapatch\n"
    echo -e "\nINFO: Database $DB_NAME is about to be shutdown and restarted in UPGRADE mode on this instance $ORACLE_SID\n"
    #
    prompt_if_interactive

    # startup upgrade
    DB_startup_upgrade

    # check if -pdb option given for pluggable database
    if [[ $PDB -gt 0 ]]; then
      sqlplus / as sysdba << EOF
      PROMPT alter pluggable database all open upgrade;;
      alter pluggable database all open upgrade;
EOF
    fi

    # run OPatch/datapatch
    do_datapatch

    # shutdown database
    DB_shutdown_immediate
  fi

  # startup the database instance and open normal
  DB_startup_normal

  # check if -pdb option given for pluggable database
  if [[ $PDB -gt 0 ]]; then
    sqlplus / as sysdba << EOF
    PROMPT alter pluggable database all open;;
    alter pluggable database all open;
EOF
    if [[ ! $? -eq 0 ]]; then
      echo "\nFATAL: Problem starting database instance for Oracle Home $ORACLE_HOME and SID $ORACLE_SID"
      exit 1
    fi
  fi

  # start database listeners stopped previously
  echo -e "\nINFO: About to start all Listeners previously running from $ORACLE_HOME"
  prompt_if_interactive
  for LISTENER_NAME in $LISTENER_LIST
  do
    echo -e "\nINFO: About to start Listener $LISTENER_NAME"
    if [[ $GRID -gt 0 ]]; then
      echo -e "\nCMD: srvctl start listener -l $LISTENER_NAME"
      srvctl start listener -l $LISTENER_NAME
    else
      echo -e "\nCMD: lsnrctl start $LISTENER_NAME"
      lsnrctl start $LISTENER_NAME
    fi
    if [[ ! $? -eq 0 ]]; then
      echo -e "\nWARNING: Problem starting Listener $LISTENER_NAME for Oracle Home $ORACLE_HOME and SID $ORACLE_SID"
      #exit 1
    fi
  done

fi


# stop OEM blackout
echo -e "\nCMD: su - oraoem -c emctl status blackout"
echo -e "\nCMD: su - oraoem -c \"emctl stop blackout $OEM_BLACKOUT_NAME\""

if [[ $GRID -gt 0 ]]; then
  echo -e "\nCMD: srvctl status database -thishome -verbose\n"
  srvctl status database -thishome -verbose
fi

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
