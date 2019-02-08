#!/bin/bash

# default options that can be set by command line parameters (see usage)
COMP_TYPE=OHS            # component - WLS or OHS
ORA_VER=12.1.3.0         # version   - only 12.1.3.0 accepted
PSU_VER=180717           # PSU       - only 180717 accepted
DEBUG=FALSE              # debug     - the default is for no additional debug output
DRY_RUN=FALSE            # dryRun    - the default is not to perform a dry run 
TEST_RUN=FALSE           # testRun   - the default is not to perform a test run
NO_PROMPT=FALSE          # noPrompt  - the default is to prompt the user if run interactively
NM_UNAME="weblogic"      # NMUname   - the default NM and Admin Server username
NM_PWORD="weblog1c"      # NMPword   - this is the default for most dev/test Node Managers and Admin Servers
#NM_PWORD="Log1cweb!"    # NMPword   - alternative default

# the file name of the Apply script that is copied to the host then executed remotely
APPLY_PSU_SCRIPT=apply_PSU_12c_WLS_OHS.sh

# other defaults
THIS_SCRIPT=$(basename $0)
THIS_DIR=$(dirname $0)
TODAY=$(date +'%Y%m%d')
MAX_ATTEMPTS_PER_HOST=2
CMD_REDIR=" > /dev/null 2>&1"

# define local directory structure
BASE_DIR=/share/dbadir/PSU_deploy
BIN_DIR=$BASE_DIR/bin
PSU_DIR=$BASE_DIR/psu
LOG_DIR=$BASE_DIR/log

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
    echo -e "\nFATAL: Cannot write temp log file $TEMP_LOG_FILE"
    exit 1
  fi
fi

##
# start logging to MAIN_LOG_FILE from here
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

if [[ ! -r $BIN_DIR/$APPLY_PSU_SCRIPT ]]; then
  echo -e "\nFATAL: Cannot find script $BIN_DIR/$APPLY_PSU_SCRIPT"
  exit 1
fi

##
# --- Start Functions ---
##

function usage()
{
  echo
  echo "Usage:"
  echo "$THIS_SCRIPT [-hostList=HOST_LIST_FILE] [-component=COMP_TYPE] [-version=ORA_VER] [-PSU=PSU_VER] {-NMUname=NM_UNAME} {-NMPword=NM_PWORD} {-noPrompt} {-debug} {-dryRun} {-testRun} {-help} "
  echo
  echo "Where:"
  echo "  -hostList|-hl    - Required. Full path to a file listing all hosts to apply patches to"
  echo "  -component|-c    - Required. Specify the Oracle component to stop and apply patches to (either WLS or OHS)"
  echo "  -version|-v      - Required. Specify the Oracle 12c WLS/OHS version (currently only 12.1.3.0 is valid)"
  echo "  -PSU|-psu        - Required. Specify the Oracle PSU date to apply to the Oracle Home (format must be YYMMDD and currently only 180717 is valid)"
  echo "  -NMUname|-u      - Optional. Node Manager / Admin Server username (usually the same for both)"
  echo "  -NMPword|-p      - Optional. Node Manager / Admin Server password (usually the same for both)"
  echo "  -noPrompt|-np    - Optional. Do not prompt the user (not set by default)"
  echo "  -dryRun|-dr      - Optional. Do not apply any patches but attempt to restart services (not set by default)"
  echo "  -testRun|-tr     - Optional. Only display the apply scripts usage message on each host (not set by default)" 
  echo "  -debug|-d        - Optional. Display additional debug output to screen  (not set by default)"
  echo "  -help|-h         - Optional. Display this usage message and exit"
  echo 
  echo "Example:"
  echo "  $THIS_SCRIPT -hostList=/tmp/OHS_12.1.3.0_180717_host.lst -c=OHS -v=12.1.3.0 -psu=180717 -d -np -dr -tr"
  echo "  $THIS_SCRIPT -hostList=/tmp/WLS_12.1.3.0_180717_host.lst -c=WLS -v=12.1.3.0 -psu=180717 -np -dr"
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
        -NMUname|-u)
                NM_UNAME="$value"
                ;;
        -NMPword|-p)
                NM_PWORD="$value"
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
elif [[ $COMP_TYPE == OHS ]]; then
  echo -e "\nINFO: component type $COMP_TYPE is supported"
  SSH_USER=oraweb
elif [[ $COMP_TYPE == WLS ]]; then
  echo -e "\nINFO: component type $COMP_TYPE is supported"
  SSH_USER=oracleas
else
  echo -e "\nFATAL: COMP_TYPE $COMP_TYPE unsupported"
  exit 1
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
for HOST in $(grep -v ^# $HOST_LIST_FILE|grep .); do 
prompt_if_interactive

RESULT=FAILED
COUNT=0

while [[ $RESULT == FAILED ]] && [[ $COUNT -lt $MAX_ATTEMPTS_PER_HOST ]]; do
  # wipe the TEMP_LOG_FILE 
  cp /dev/null $TEMP_LOG_FILE > /dev/null
  # set HOST_LOG_FILE to correct value for this host and activity
  HOST_LOG_FILE=$(echo $MAIN_LOG_FILE|cut -d. -f1)_${HOST}_${COMP_TYPE}_${ORA_VER}_${PSU_VER}.log
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
  #CMD="ls -1 $PSU_DIR/$APPLY_PSU_DIR/|wc -l"
  CMD="if [ -d $NFS_APPLY_PSU_DIR ]\; then echo 1\; else echo 0\; fi"
  echo -e "\n$HOST - CMD: $CMD "
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
    # check if there is free space in the MW_BASE_DIR file system to also stage all patch zip files then unpatch
    #CMD=". .bash_profile \; env|grep ^WL_HOME=|cut -d= -f2"
    #CMD=". .bash_profile \; env|grep ^MW_HOME=|cut -d= -f2"
    CMD=". .bash_profile \; env|grep ^DOMAIN_HOME=|cut -d= -f2"
    echo -e "\n$HOST - CMD: $CMD"
    echo -e "\n$HOST - CMD: $SSH_CMD $CMD"
    DOMAIN_HOME=$(eval "$SSH_CMD $CMD")
    if [[ ! $? -eq 0 ]]; then
      CONTINUE=FALSE
      echo -e "\n$HOST - ERR: SSH to $HOST as $SSH_USER failed to execute $CMD"
    elif [[ "$DOMAIN_HOME" == "" ]]; then
      CONTINUE=FALSE
      echo -e "\n$HOST - ERR: Problem determining DOMAIN_HOME on $HOST as $SSH_USER"
    else
      CONTINUE=TRUE
      #MW_BASE_DIR=$MW_BASE_DIR/../../
      MW_BASE_DIR=${DOMAIN_HOME%/user_projects/*}
      echo -e "\n$HOST - INFO: MW_BASE_DIR on $HOST is $MW_BASE_DIR"
    fi
    CMD="df -m $MW_BASE_DIR |tail -1|awk {'print\$3'}"
    echo -e "\n$HOST - CMD: $CMD $CMD_REDIR"
    HOST_FREE_SPACE_MB=$(eval "$SSH_CMD $CMD")
    REQD_FREE_SPACE_MB=$(( 2*APPLY_PSU_DIR_MB ))
    if [[ ! $? -eq 0 ]]; then
      CONTINUE=FALSE
      echo -e "\n$HOST - ERR: SSH to $HOST as $SSH_USER failed to execute $CMD"
    elif [[ $REQD_FREE_SPACE_MB -ge $HOST_FREE_SPACE_MB ]]; then
      CONTINUE=FALSE
      echo -e "\n$HOST - ERR: $HOST has only $HOST_FREE_SPACE_MB Mbytes of free space in the "$(echo $MW_BASE_DIR|cut -d/ -f1,2)" file system but $REQD_FREE_SPACE_MB Mbytes is required"
    else
      CONTINUE=TRUE
      echo -e "\n$HOST - PASS: $HOST has $HOST_FREE_SPACE_MB Mbytes of free space in the "$(echo $MW_BASE_DIR|cut -d/ -f1,2)" file system which is more than the required $REQD_FREE_SPACE_MB Mbytes"
    fi

    if [[ "$CONTINUE" == "TRUE" ]]; then
      CMD="mkdir $MW_BASE_DIR/$APPLY_PSU_DIR"
      eval "$SSH_CMD $CMD $CMD_REDIR"
      CMD="ls -d $MW_BASE_DIR/$APPLY_PSU_DIR"
      eval "$SSH_CMD $CMD $CMD_REDIR"
      if [[ ! $? -eq 0 ]]; then
        echo -e "\n$HOST - ERR: directory $MW_BASE_DIR/$APPLY_PSU_DIR does not exist on remote host"
        CONTINUE=FALSE
      else
        echo -e "\n$HOST - PASS: directory $MW_BASE_DIR/$APPLY_PSU_DIR does exist on remote host"
        CMD="cd $MW_BASE_DIR/$APPLY_PSU_DIR \; pwd"
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
    CMD="sh ./$(basename $APPLY_PSU_SCRIPT) -component=$COMP_TYPE -version=$ORA_VER -PSU=$PSU_VER -stageDir=$FULL_APPLY_PSU_DIR -NMUname=$NM_UNAME -NMPword=$NM_PWORD "
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
    echo -e "\n$HOST - ERR: Something previously failed so script $(basename $APPLY_PSU_SCRIPT) was not run on $HOST as $SSH_USER"
  fi


  # cleanup
  if [[ $HOST_NFS_CHECK -gt 0 ]]; then
    CMD="rm -f $(basename $APPLY_PSU_SCRIPT)"
  else
    CMD="rm -rf $(basename $APPLY_PSU_SCRIPT) $FULL_APPLY_PSU_DIR"
  fi
  echo -e "\n$HOST - CMD: $CMD $CMD_REDIR"
  #eval "$SSH_CMD $CMD $CMD_REDIR"
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
