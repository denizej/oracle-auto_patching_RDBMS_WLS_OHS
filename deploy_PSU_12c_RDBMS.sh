#!/bin/bash

THIS_SCRIPT=$(basename $0)
THIS_DIR=$(dirname $0)
TODAY=$(date +'%Y%m%d')

BASE_DIR=/share/dbadir/PSU_deploy
BIN_DIR=$BASE_DIR/bin
PSU_DIR=$BASE_DIR/psu
PATCH_DIR=$BASE_DIR/patches
LOG_DIR=$BASE_DIR/log

# set defaults
COMP_TYPE=RDBMS
ORA_VER=12.1.0.2
PSU_VER=180717

DRY_RUN=FALSE
TEST_RUN=FALSE
DEBUG=FALSE
NO_PROMPT=FALSE
MAX_ATTEMPTS_PER_HOST=2
SSH_USER_DEF=oracle

CMD_REDIR=" > /dev/null 2>&1"

APPLY_PSU_SCRIPT=apply_PSU_12c_RDBMS.sh

if [[ ! -d $LOG_DIR ]]; then
  echo -e "\nFATAL: Cannot find directory $LOG_DIR"
  exit 1
else
  MAIN_LOG_FILE=$LOG_DIR/$(echo -e $THIS_SCRIPT|cut -d. -f1)_$TODAY.log
  TEMP_LOG_FILE=$(echo $MAIN_LOG_FILE|cut -d. -f1)_$$.tmp
  if [[ -r $MAIN_LOG_FILE ]]; then
    COUNT=$(ls -1 ${MAIN_LOG_FILE}*|wc -l)
    mv $MAIN_LOG_FILE ${MAIN_LOG_FILE}_$COUNT
  fi
  rm $TEMP_LOG_FILE > /dev/null 2>&1
  touch $TEMP_LOG_FILE > /dev/null 2>&1
  if [[ ! -r $TEMP_LOG_FILE ]]; then
    echo -e "\nERROR: Cannot write temp log file $TEMP_LOG_FILE"
    exit 1
  fi
fi

##
## start logging to MAIN_LOG_FILE from here
##
{
echo "INFO: $(date)"
echo "INFO: Start of $THIS_SCRIPT"
echo "INFO: Main log file $MAIN_LOG_FILE"

WHOAMI=$(whoami)
if [[ ! "$WHOAMI" =~ ^oraoem ]]; then
  echo -e "\nFATAL: $WHOAMI is not a supported user to execute this script, expecting oraoem"
  exit 1
fi

if [[ ! -d $BIN_DIR ]]; then
  echo -e "\nFATAL: Cannot find directory $BIN_DIR"
  exit 1
fi

if [[ ! -d $PSU_DIR ]]; then
  echo -e "\nFATAL: Cannot find directory $PSU_DIR"
  exit 1
fi

if [[ ! -d $PATCH_DIR ]]; then
  echo -e "\nFATAL: Cannot find directory $PATCH_DIR"
  exit 1
fi

if [[ ! -r $BIN_DIR/$APPLY_PSU_SCRIPT ]]; then
  echo -e "\nFATAL: Cannot find script $BIN_DIR/$APPLY_PSU_SCRIPT"
  exit 1
fi


# --- Start Functions ---

function usage()
{
  echo
  echo "Usage:"
  echo "$THIS_SCRIPT [-hostList=HOST_LIST_FILE] [-component=COMP_TYPE] [-version=ORA_VER] [-PSU=PSU_VER] {-doDatapatch} {-noGrid} {-pdb} {-noPrompt} {-debug} {-dryRun} {-testRun} {-help} "
  echo
  echo "Where:"
  echo "  -hostList|-hl    - Required. Full path to a file listing all hosts to apply patches to and Oracle SIDs (format per line is 'hostname:SID:SSH_USER'"
  echo "  -component|-c    - Required. Specify the Oracle component to stop and apply patches to (only RDBMS is valid)"
  echo "  -version|-v      - Required. Specify the Oracle 12c database version (12.1.0.2 or 12.2.0.1)"
  echo "  -PSU|-psu        - Required. Specify the Oracle PSU date to apply to the Oracle Home (format must be YYMMDD and currently 180717 and 181016 are valid)"
  echo "  -doDatapatch|-dp - Optional. Setting this option this will run OPatch/datapatch after attaching the new Oracle Home (the default is not to run datapatch)"
  echo "  -noGrid|-ng      - Optional. Setting this option this will NOT use any Grid Infrastructure commands (ignored if RAC is detected and the default is to test if GI is present)"
  echo "  -PDB|-pdb        - Optional. Setting this option adds the step to open all pluggable databases (not set by default)"
  echo "  -noPrompt|-np    - Optional. Set this option to run with no prompts to the user (not set by default)"
  echo "  -dryRun|-dr      - Optional. Set this option to not apply any patches but may attempt to restart services (not set by default)"
  echo "  -testRun|-tr     - Optional. Set this option to only display the apply scripts usage message on each remote host (not set by default)"
  echo "  -debug|-d        - Optional. Display additional debug output to screen (not set by default)"
  echo "  -help|-h         - Optional. Display this usage message and exit"
  echo 
  echo "Example:"
  echo "  $THIS_SCRIPT -hostList=/tmp/RDBMS_12.1.0.2_180717_host.lst -c=RDBMS -v=12.1.0.2 -psu=180717 -d -np -dr -tr"
  echo "  $THIS_SCRIPT -hostList=/tmp/RDBMS_12.2.0.1_181016_host.lst -c=RDBMS -v=12.2.0.1 -psu=181016 -d -dr -np -tr"
  echo 

  # remove any log files created
  rm $MAIN_LOG_FILE > /dev/null 2>&1
  rm $TEMP_LOG_FILE > /dev/null 2>&1

}


function prompt_if_interactive(){
fd=0
if [[ -t "$fd" || -p /dev/stdin ]] && [[ ! "$NO_PROMPT" == "TRUE" ]]; then
  echo -e -e "\nPress Y to continue or any other key to break and exit\n"
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

# --- End Functions ---

##
## Main
##

# check for at least 4 input parameters
if [[ $# -lt 4 ]]; then
  usage $0
  exit
fi

while [[ $# -gt 0 ]]
do
  param=$(echo -e $1|cut -d= -f1)
  value=$(echo -e $1|cut -d= -f2)
  #echo -e param = $param
  #echo -e value = $value
  case $param in
        -help|-h)
                #doUsage="true"
                usage $0
                exit
                ;;
        -debug|-d)
                DEBUG=TRUE
                ;;
        -noPrompt|-np)
                NO_PROMPT=TRUE
                ;;
        -dryRun|-dr)
                DRY_RUN=TRUE
                ;;
        -testRun|-tr)
                TEST_RUN=TRUE
                ;;
        -hostList|-hl)
                HOST_LIST_FILE="$value"
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
        -doDatapatch|-dp)
                DO_DATAPATCH=TRUE
                ;;
        -noGrid|-ng)
                NO_GRID=TRUE
                ;;
        -PDB|-pdb)
                PDB=TRUE
                ;;
        *)
                echo -e "Invalid parameter: $param"
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

if [[ -z $HOST_LIST_FILE ]]; then
  echo -e "\nFATAL: The parameter hosts is required\n"
  usage $0
  exit 1
elif [[ ! -r $HOST_LIST_FILE ]]; then
  echo -e "\nFATAL: The file $HOST_LIST_FILE cannot be read"
  usage $0
  exit 1
else
  echo -e "\nINFO: Found host list file $HOST_LIST_FILE with $(grep -v ^# $HOST_LIST_FILE|grep -c .) entries"
  #prompt_if_interactive
fi

if [[ -z $COMP_TYPE ]]; then
  echo -e "\nFATAL: component type is required\n"
  usage $0
  exit 1
elif [[ $COMP_TYPE == RDBMS ]]; then
  echo -e "\nINFO: component type $COMP_TYPE is supported"
else
  echo -e "\nFATAL: COMP_TYPE $COMP_TYPE unsupported"
  exit 1
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

# determine where to find the patches from the 3 variables COMP_TYPE, ORA_VER and PSU_VER
APPLY_PSU_DIR=${COMP_TYPE}_${ORA_VER}_${PSU_VER}

# this directory should already exist and contain the unzipped patches
NFS_APPLY_PSU_DIR=$PSU_DIR/$APPLY_PSU_DIR

if [[ ! -d $NFS_APPLY_PSU_DIR ]]; then
  echo -e "\nFATAL: Cannot find directory $NFS_APPLY_PSU_DIR"
  exit 1
fi

CMD="unzip -q -o -u -d $NFS_APPLY_PSU_DIR $NFS_APPLY_PSU_DIR/p\*.zip"
echo -e "\nCMD: $CMD $CMD_REDIR"
eval "$CMD $CMD_REDIR"
if [[ ! $? -eq 0 ]]; then
  echo -e "\nINFO: Problem unzipping patches within $NFS_APPLY_PSU_DIR"
  exit 1
fi

APPLY_PSU_DIR_MB=$(du -smL $NFS_APPLY_PSU_DIR|awk {'print$1'})
for ZIP_FILE in $(ls -1 $NFS_APPLY_PSU_DIR/p*.zip)
do
  ZIP_FILE_LIST="$ZIP_FILE_LIST "$(basename $ZIP_FILE)
done
echo -e "\nINFO: List of patch zip files is: "$ZIP_FILE_LIST

if [[ "$NO_PROMPT" == "TRUE" ]]; then
  echo -e "\nINFO: The noPrompt option is enabled"
fi

if [[ "$DRY_RUN" == "TRUE" ]]; then
  echo -e "\nINFO: The dryRun option is enabled (no patches will be applied but services will be restarted on all hosts)"
fi
if [[ "$TEST_RUN" == "TRUE" ]]; then
  echo -e "\nINFO: The testRun option is enabled (a usage message will be displayed on each host successfully connected to and nothing run)"
fi


## 
## loop through each uncommented and non-blank line in $HOST_LIST_FILE
##
for LINE in $(grep -v ^# $HOST_LIST_FILE|grep .); do 
prompt_if_interactive

if [[ "$DEBUG" == "TRUE" ]]; then
  echo -e "\nDEBUG: Line from $HOST_LIST_FILE is:"
  echo -e "DEBUG: "$LINE
fi

HOST=$(echo $LINE|cut -d: -f1)
SID=$(echo $LINE|cut -d: -f2)
SSH_USER=$(echo $LINE|cut -d: -f3)

if [[ ! "$SID" == "" ]]; then
  echo -e "\nINFO: SID is $SID"
else
  echo -e "\nWARNING: SID undefined in line $LINE"
  break
fi

if [[ ! "$HOST" == "" ]]; then
  echo -e "\nINFO: HOST is $HOST"
else
  echo -e "\nWARNING: HOST undefined in line $LINE"
  break
fi

if [[ ! "$SSH_USER" == "" ]]; then
  echo -e "\nINFO: SSH_USER is $SSH_USER"
else
  SSH_USER=$SSH_USER_DEF
  echo -e "\nINFO: Default SSH_USER $SSH_USER_DEF to be used"
fi



RESULT=FAILED
COUNT=0

while [[ $RESULT == FAILED ]] && [[ $COUNT -lt $MAX_ATTEMPTS_PER_HOST ]]; do
  # wipe the TEMP_LOG_FILE 
  cp /dev/null $TEMP_LOG_FILE > /dev/null
  # set HOST_LOG_FILE to correct value for this host and activity
  HOST_LOG_FILE=$(echo $MAIN_LOG_FILE|cut -d. -f1)_${HOST}_${COMP_TYPE}_${ORA_VER}_${PSU_VER}_${SID}.log
  echo -e "\n$HOST - INFO: Log file for this host is $HOST_LOG_FILE"
  if [[ -r $HOST_LOG_FILE ]]; then
    LOG_COUNT=$(ls -1 ${HOST_LOG_FILE}*|wc -l)
    mv $HOST_LOG_FILE ${HOST_LOG_FILE}_$LOG_COUNT
  fi
  touch $HOST_LOG_FILE
  if [[ ! -r $HOST_LOG_FILE ]]; then
    echo -e "\n$HOST - WARN: Problem creating host log file $HOST_LOG_FILE"
  fi

  CONTINUE=TRUE
  ((COUNT++))
  echo -e "\n$HOST - INFO: Attempt $COUNT started at "$(date +'%H:%M:%S') 

  SSH_CMD="ssh -q -n -o NumberOfPasswordPrompts=0 $SSH_USER@$HOST"

  CMD="uname"
  echo -e "\n$HOST - CMD: $CMD $CMD_REDIR"
  #eval "$SSH_CMD $CMD $CMD_REDIR"
  HOST_UNAME=$(eval "$SSH_CMD $CMD")
  if [[ ! $? -eq 0 ]]; then
    CONTINUE=FALSE
    echo -e "\n$HOST - ERR: SSH to $HOST as $SSH_USER failed"
  else
    CONTINUE=TRUE
    echo -e "\n$HOST - PASS: SSH to $HOST_UNAME host $HOST as $SSH_USER OK"
  fi

  # check if the patches are available via the NFS share on the remote host
  CMD="if [ -d $NFS_APPLY_PSU_DIR ]\; then echo 1\; else echo 0\; fi"
  echo -e "\n$HOST - CMD: $CMD "
  #HOST_NFS_CHECK=0
  HOST_NFS_CHECK=$(eval "$SSH_CMD $CMD")
  if [[ ! $? -eq 0 ]]; then
    CONTINUE=FALSE
    echo -e "\n$HOST - ERR: SSH to $HOST as $SSH_USER failed to execute $CMD"
  elif [[ $HOST_NFS_CHECK -gt 0 ]]; then
    # NFS share available
    CONTINUE=TRUE
    echo -e "\n$HOST - PASS: $HOST has the NFS share mounted and user $SSH_USER can access directory $NFS_APPLY_PSU_DIR"
    # set FULL_APPLY_PSU_DIR to the full path to the available NFS served directory as this can be used as the stageDir parameter for the apply script
    FULL_APPLY_PSU_DIR=$NFS_APPLY_PSU_DIR
  else
    # NFS share unavailable
    echo -e "\n$HOST - WARN: $HOST does not have the NFS share mounted as the user $SSH_USER cannot access directory $NFS_APPLY_PSU_DIR"
    echo -e "\n$HOST - INFO: Will attempt to SCP each patch zip file to $HOST as $SSH_USER and unzip all remotely"
    # check if there is free space in the ORACLE_HOME file system to also stage all patch zip files then unpatch
    #CMD="grep ^${SID}: /etc/oratab|cut -d: -f2|tail -1"
    #CMD="export ORACLE_SID=$SID\; export ORAENV_ASK=NO\; . /usr/local/bin/oraenv \; echo $ORACLE_HOME"
    CMD="export ORACLE_SID=$SID\; export ORAENV_ASK=NO\; . /usr/local/bin/oraenv \; env|grep ^ORACLE_HOME=|cut -d= -f2"
    echo -e "\n$HOST - CMD: $CMD"
    echo -e "\n$HOST - CMD: $SSH_CMD $CMD"
    ORACLE_HOME=$(eval "$SSH_CMD $CMD")
    if [[ ! $? -eq 0 ]]; then
      CONTINUE=FALSE
      echo -e "\n$HOST - ERR: SSH to $HOST as $SSH_USER failed to execute $CMD"
    elif [[ "$ORACLE_HOME" == "" ]]; then
      CONTINUE=FALSE
      echo -e "\n$HOST - ERR: Problem determining ORACLE_HOME on $HOST as $SSH_USER"
    else
      CONTINUE=TRUE
      echo -e "\n$HOST - INFO: ORACLE_HOME on $HOST is $ORACLE_HOME"
    fi
    CMD="df -m $ORACLE_HOME |tail -1|awk {'print\$3'}"
    echo -e "\n$HOST - CMD: $CMD $CMD_REDIR"
    HOST_FREE_SPACE_MB=$(eval "$SSH_CMD $CMD")
    REQD_FREE_SPACE_MB=$(( 2*APPLY_PSU_DIR_MB ))
    if [[ ! $? -eq 0 ]]; then
      CONTINUE=FALSE
      echo -e "\n$HOST - ERR: SSH to $HOST as $SSH_USER failed to execute $CMD"
    elif [[ $REQD_FREE_SPACE_MB -ge $HOST_FREE_SPACE_MB ]]; then
      CONTINUE=FALSE
      echo -e "\n$HOST - ERR: $HOST has only $HOST_FREE_SPACE_MB Mbytes of free space in the "$(echo $ORACLE_HOME|cut -d/ -f1,2)" file system but $REQD_FREE_SPACE_MB Mbytes is required"
    else
      CONTINUE=TRUE
      echo -e "\n$HOST - PASS: $HOST has $HOST_FREE_SPACE_MB Mbytes of free space in the "$(echo $ORACLE_HOME|cut -d/ -f1,2)" file system which is more than the required $REQD_FREE_SPACE_MB Mbytes"
    fi

    if [[ "$CONTINUE" == "TRUE" ]]; then
      CMD="mkdir $(dirname $ORACLE_HOME)/$APPLY_PSU_DIR"
      eval "$SSH_CMD $CMD $CMD_REDIR"
      CMD="ls -d $(dirname $ORACLE_HOME)/$APPLY_PSU_DIR"
      eval "$SSH_CMD $CMD $CMD_REDIR"
      if [[ ! $? -eq 0 ]]; then
        echo -e "\n$HOST - ERR: directory $(dirname $ORACLE_HOME)/$APPLY_PSU_DIR does not exist on remote host"
        CONTINUE=FALSE
      else
        echo -e "\n$HOST - PASS: directory $(dirname $ORACLE_HOME)/$APPLY_PSU_DIR does exist on remote host"
        CMD="cd $(dirname $ORACLE_HOME)/$APPLY_PSU_DIR \; pwd"
        FULL_APPLY_PSU_DIR=$(eval "$SSH_CMD $CMD")
        echo -e "\n$HOST - INFO: Full path to $APPLY_PSU_DIR is $FULL_APPLY_PSU_DIR"
        CONTINUE=TRUE
      fi
    fi

    # SCP all patch zip files to the remote host
    if [[ "$CONTINUE" == "TRUE" ]]; then
      for FILE in $(ls -1 $NFS_APPLY_PSU_DIR/p*.zip)
      do
        REMOTE_FILE=$(basename $FILE)
        CMD="scp -q -r $FILE $SSH_USER@$HOST:$FULL_APPLY_PSU_DIR/$REMOTE_FILE"
        echo -e "\n$HOST - CMD: $CMD $CMD_REDIR"
        eval "$CMD $CMD_REDIR"
        if [[ ! $? -eq 0 ]]; then
          echo -e "\n$HOST - ERR: SCP to $HOST as $SSH_USER of file $REMOTE_FILE failed"
          CONTINUE=FALSE
        else
          echo -e "\n$HOST - PASS: SCP to $HOST as $SSH_USER of file $REMOTE_FILE done"
          CONTINUE=TRUE
        fi
      done
    fi

    # unzip all patches remotely
    if [[ "$CONTINUE" == "TRUE" ]]; then
      CMD="unzip -q -o -u -d $FULL_APPLY_PSU_DIR '$FULL_APPLY_PSU_DIR/p\*.zip'"
      echo -e "\n$HOST - CMD: $CMD "
      eval "$SSH_CMD $CMD $CMD_REDIR"
      if [[ ! $? -eq 0 ]]; then
        echo -e "\n$HOST - ERR: unzip of patches in directory $FULL_APPLY_PSU_DIR on $HOST failed"
        CONTINUE=FALSE
      else
        echo -e "\n$HOST - PASS: unzip of patches in directory $FULL_APPLY_PSU_DIR on $HOST OK"
        CONTINUE=TRUE
      fi
    fi

  fi # if NFS share available or not
  
  # SCP the apply script to the SSH_USER home directory
  if [[ "$CONTINUE" == "TRUE" ]]; then
    REMOTE_FILE=$(basename $APPLY_PSU_SCRIPT)
    CMD="scp -q -r $APPLY_PSU_SCRIPT $SSH_USER@$HOST:$REMOTE_FILE"
    echo -e "\n$HOST - CMD: $CMD $CMD_REDIR"
    eval "$CMD $CMD_REDIR"
    if [[ ! $? -eq 0 ]]; then
      echo -e "\n$HOST - ERR: SCP to $HOST as $SSH_USER of file $REMOTE_FILE failed"
      CONTINUE=FALSE
    else
      echo -e "\n$HOST - PASS: SCP to $HOST as $SSH_USER of file $REMOTE_FILE done"
      CONTINUE=TRUE
    fi
  fi

  if [[ "$CONTINUE" == "TRUE" ]]; then
    SSH_CMD="ssh -q -o NumberOfPasswordPrompts=0 $SSH_USER@$HOST"
    echo -e "\n$HOST - INFO: About to run script $(basename $APPLY_PSU_SCRIPT) on $HOST as $SSH_USER"
    CMD="sh ./$(basename $APPLY_PSU_SCRIPT) -component=$COMP_TYPE -version=$ORA_VER -PSU=$PSU_VER -SID=$SID -stageDir=$FULL_APPLY_PSU_DIR "
    if [[ "$DO_DATAPATCH" == "TRUE" ]]; then
      CMD="$CMD -doDatapatch"
    fi
    if [[ "$NO_GRID" == "TRUE" ]]; then
      CMD="$CMD -noGrid"
    fi
    if [[ "$PDB" == "TRUE" ]]; then
      CMD="$CMD -PDB"
    fi
    if [[ "$NO_PROMPT" == "TRUE" ]]; then
      CMD="$CMD -noPrompt"
    fi
    if [[ "$DEBUG" == "TRUE" ]]; then
      CMD="$CMD -debug"
    fi
    if [[ "$DRY_RUN" == "TRUE" ]]; then
      CMD="$CMD -dryRun"
    fi
    if [[ "$TEST_RUN" == "TRUE" ]]; then
      CMD="$CMD -help"
    fi
    echo -e "\n$HOST - CMD: $CMD "
    eval "$SSH_CMD $CMD"
    if [[ ! $? -eq 0 ]]; then
      echo -e "\n$HOST - ERR: $(basename $APPLY_PSU_SCRIPT) failed after $COUNT attempts"
      RESULT=FAILED
    else
      echo -e "\n$HOST - PASS: $(basename $APPLY_PSU_SCRIPT) succeeded after $COUNT attempts"
      RESULT=SUCCESS
    fi
  else
    echo -e "\n$HOST - ERR: Something previously failed so the patch apply script $(basename $APPLY_PSU_SCRIPT) was not run on $HOST as $SSH_USER"
  fi

  # cleanup
  if [[ $HOST_NFS_CHECK -gt 0 ]]; then
    CMD="rm -f $(basename $APPLY_PSU_SCRIPT)"
  else
    CMD="rm -rf $(basename $APPLY_PSU_SCRIPT) $FULL_APPLY_PSU_DIR"
  fi
  echo -e "\n$HOST - CMD: $CMD $CMD_REDIR"
  eval "$SSH_CMD $CMD $CMD_REDIR"
  if [[ ! $? -eq 0 ]]; then
    echo -e "\n$HOST - WARN: cleanup on $HOST as $SSH_USER failed"
  else
    echo -e "\n$HOST - PASS: cleanup on $HOST as $SSH_USER done"
  fi
  
  echo -e "\n$HOST - INFO: $(date)"
  echo -e "\n$HOST - INFO: $RESULT"

  if [[ -r $TEMP_LOG_FILE ]]; then
    cat $TEMP_LOG_FILE >> $HOST_LOG_FILE
  else
    echo -e "\n$HOST - WARN: Problem reading temp log file $TEMP_LOG_FILE"
  fi

done | tee -a $TEMP_LOG_FILE 
# while loop for each host

done 
# for loop of all hosts

# remove temp log file
rm $TEMP_LOG_FILE > /dev/null

echo 
echo "INFO: $(date)"
echo "INFO: End of $THIS_SCRIPT"
echo "INFO: Main log file $MAIN_LOG_FILE"
echo "INFO: Done!"
exit 0
} | tee -a $MAIN_LOG_FILE
exit ${PIPESTATUS[0]}
